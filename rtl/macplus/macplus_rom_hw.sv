// The memory side of the Macross Plus core (docs/PLAN.md 2.3, D1): the ROM
// image in DDR3, the boot copy into SDRAM, and the port adapters the core's
// ROM interfaces talk to.
//
// Load. The .mra loads one image at 0x30000000 (Appendix D). With `address=`
// Main_MiSTer writes it straight into DDR3 and only toggles ioctl_download;
// if it streams bytes instead (ioctl_wr on index 0), this module writes them
// to the same place itself. Either way, when the download ends the COPIER
// moves image bytes 0x0000000-0x15FFFFF (main program 4 MB, sound program
// 1 MB, text 512 KB + pad, sprites 16 MB) into SDRAM at the same offsets, and
// `rom_ready` rises only after that; the core stays in reset until then.
//
// SDRAM (rtl/sdram.sv, 16-bit words; word k = {byte 2k+1, byte 2k}, the
// siblings' convention; a read returns the aligned pair {word|1, word&~1}):
//   port 0  main-CPU cache fills (one pair = one big-endian longword) + copier
//   port 1  sound-CPU program, through rom_cache_n
//   port 2  sprite rows, 16 bytes = four pair reads
//   port 3  text rows, 8 bytes = two pair reads
// DDR3 (64-bit words, byte k in bits [8k+7:8k]), on clk_ddr (96 MHz, the
// video clock screen_rotate drives DDRAM with):
//   BG rows (16 bytes = 2 beats), ES5506 sample words (the containing qword,
//   kept in a one-qword buffer per bank, since the ES5506 fetches four words
//   of a line in a row), the copier's reads and the fallback download's
//   writes. Reads are pipelined (up to 8 in flight) and return in order.
//   The DDR port yields while `ddr_yield` is high (screen_rotate's write or
//   the savestate engine).
// The 48 MHz clients cross to clk_ddr through held request / held
// acknowledge (4-phase) handshakes with two-flop synchronisers on both
// levels: the SDC puts the two clocks in exclusive groups (as the siblings'
// SDRAM handshake), so nothing between them is timed. Payloads are stable
// whenever the level that announces them is.
module macplus_rom_hw #(
	parameter [31:0] DDR_BASE = 32'h3000_0000,
	parameter [24:0] COPY_BYTES = 25'h1600000
) (
	input             clk,            // 48 MHz
	input             clk_ddr,        // 96 MHz
	input             pwr_reset,      // power-on only (SS-15)
	input             reset,          // core reset
	input             quiz,
	// download
	input             ioctl_download,
	input      [15:0] ioctl_index,
	input             ioctl_wr,
	input      [26:0] ioctl_addr,
	input      [7:0]  ioctl_dout,
	output            ioctl_wait,
	output reg        rom_ready,
	// main CPU (longword)
	input             mrom_req,
	input      [19:0] mrom_addr,
	output reg        mrom_ack,
	output reg [31:0] mrom_data,
	// sound CPU (word)
	input             srom_req,
	input      [18:0] srom_addr,
	output            srom_ack,
	output     [15:0] srom_data,
	// BG / text row streams
	input      [3:0]  bg_req,
	input      [91:0] bg_addr,
	output reg [3:0]  bg_ready,
	output reg [3:0]  bg_valid,
	output reg [127:0] bg_data,
	// sprite rows
	input             spr_req,
	input      [23:0] spr_addr,
	output reg        spr_ready,
	output reg        spr_valid,
	output reg [127:0] spr_data,
	// ES5506
	input             smp_req,
	input      [1:0]  smp_bank,
	input      [20:0] smp_word,
	output reg        smp_ack,
	output reg [15:0] smp_data,
	// SDRAM ports
	output     [24:1] sdram_addr0, sdram_addr1, sdram_addr2, sdram_addr3,
	output            sdram_wrl0,  sdram_wrl1,  sdram_wrl2,  sdram_wrl3,
	output            sdram_wrh0,  sdram_wrh1,  sdram_wrh2,  sdram_wrh3,
	output     [15:0] sdram_din0,  sdram_din1,  sdram_din2,  sdram_din3,
	input      [15:0] sdram_dout0, sdram_dout1, sdram_dout2, sdram_dout3,
	input      [31:0] sdram_pair0, sdram_pair1, sdram_pair2, sdram_pair3,
	output            sdram_req0,  sdram_req1,  sdram_req2,  sdram_req3,
	input             sdram_ack0,  sdram_ack1,  sdram_ack2,  sdram_ack3,
	// DDR3 master (clk_ddr)
	input             ddr_yield,
	input             ddr_busy,
	output reg        ddr_rd,
	output reg        ddr_we,
	output reg [28:0] ddr_addr,
	output reg [7:0]  ddr_burstcnt,
	output reg [63:0] ddr_din,
	output reg [7:0]  ddr_be,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready,
	// debug
	output reg [31:0] dbg_copy_words,
	output reg [31:0] dbg_dl_bytes
);
	// ================================================================ download
	wire dl_rom = ioctl_download && ioctl_index[7:0] == 8'd0;
	reg  dl_prev;
	reg  copy_start;
	reg  [23:0] dl_tail;
	always @(posedge clk) begin
		copy_start <= 1'b0;
		if (pwr_reset) begin dl_prev <= 1'b0; rom_ready <= 1'b0; end
		else begin
			dl_prev <= dl_rom;
			if (dl_rom) rom_ready <= 1'b0;
			if (dl_prev && !dl_rom) copy_start <= 1'b1;    // the image is in DDR3: copy
			if (copy_done_48) rom_ready <= 1'b1;
		end
	end

	// fallback byte stream -> DDR3 byte writes (48 MHz side, one outstanding)
	reg        fb_req;          // held until fb_ack
	reg [26:0] fb_addr;
	reg [7:0]  fb_byte;
	always @(posedge clk) begin
		if (pwr_reset) begin fb_req <= 1'b0; dbg_dl_bytes <= 32'd0; end
		else begin
			if (fb_req && fb_ack_s) fb_req <= 1'b0;
			if (dl_rom && ioctl_wr && !fb_req && !fb_ack_s) begin
				fb_req <= 1'b1; fb_addr <= ioctl_addr; fb_byte <= ioctl_dout;
				dbg_dl_bytes <= dbg_dl_bytes + 32'd1;
			end
		end
	end
	assign ioctl_wait = fb_req || fb_ack_s;

	// ================================================================ 48 -> 96 request channels
	// Each channel: a 48 MHz held request with its payload, a 96 MHz held ack.
	//   ch 0  BG row (16 bytes, 2 beats)    payload: byte address in DDR, layer
	//   ch 1  sample word (1 beat)          payload: byte address
	//   ch 2  copier burst read (8 beats)   payload: byte address
	//   ch 3  fallback download byte write  payload: byte address, byte
	// Acks come back as 96 MHz levels; the 48 MHz side re-registers them.
	reg        bg_ch_req, smp_ch_req, cp_ch_req;
	reg [31:0] bg_ch_addr, smp_ch_addr, cp_ch_addr;
	reg        bg_ch_ack, smp_ch_ack, cp_ch_ack, fb_ack;
	reg [127:0] bg_ch_data;
	reg [63:0] smp_ch_q;
	reg        fb_ack_s, bg_ack_s, smp_ack_s, cp_ack_s;
	reg        fb_ack_m, bg_ack_m, smp_ack_m, cp_ack_m;
	always @(posedge clk) begin
		{fb_ack_s, fb_ack_m}   <= {fb_ack_m, fb_ack};
		{bg_ack_s, bg_ack_m}   <= {bg_ack_m, bg_ch_ack};
		{smp_ack_s, smp_ack_m} <= {smp_ack_m, smp_ch_ack};
		{cp_ack_s, cp_ack_m}   <= {cp_ack_m, cp_ch_ack};
	end
	// ...and the requests into clk_ddr
	reg [1:0] bg_rq_s, smp_rq_s, cp_rq_s, fb_rq_s, por_s;
	always @(posedge clk_ddr) begin
		bg_rq_s  <= {bg_rq_s[0], bg_ch_req};
		smp_rq_s <= {smp_rq_s[0], smp_ch_req};
		cp_rq_s  <= {cp_rq_s[0], cp_ch_req};
		fb_rq_s  <= {fb_rq_s[0], fb_req};
		por_s    <= {por_s[0], pwr_reset};
	end
	wire bg_rq = bg_rq_s[1], smp_rq = smp_rq_s[1], cp_rq = cp_rq_s[1], fb_rq = fb_rq_s[1], ddr_por = por_s[1];

	// ================================================================ BG front end (48 MHz)
	// Accept one layer request a clock into an in-order queue; one row in
	// flight to the DDR side at a time from this queue (the DDR side pipelines
	// across channels); responses leave in queue order with the layer's bit.
	reg [24:0] bq_addr [0:15];
	reg [1:0]  bq_lay  [0:15];
	reg [3:0]  bq_wr, bq_rd;
	wire [4:0] bq_n = {1'b0, bq_wr} - {1'b0, bq_rd};
	reg [1:0]  rr;
	wire [22:0] la [0:3];
	assign la[0] = bg_addr[22:0];  assign la[1] = bg_addr[45:23];
	assign la[2] = bg_addr[68:46]; assign la[3] = bg_addr[91:69];
	// BG layer L lives at image offset 0x1600000 + L*0x800000 (Appendix D)
	function [24:0] bg_off(input [1:0] L, input [22:0] a);
		bg_off = 25'h1600000 + {L, 23'd0} + {2'd0, a};
	endfunction
	reg        bg_busy;
	reg [1:0]  bg_cur;
	always @(posedge clk) begin
		bg_ready <= 4'd0; bg_valid <= 4'd0;
		if (reset || !rom_ready) begin
			bq_wr <= 4'd0; bq_rd <= 4'd0; bg_ch_req <= 1'b0; bg_busy <= 1'b0; rr <= 2'd0;
			tqw <= 3'd0; tx_pend <= 1'b0;
		end else begin
			// accept one of layers 0..2 a clock (round robin) into the DDR3 queue
			if (bq_n < 5'd14) begin
				if (bg_req[rr] && !bg_ready[rr]) begin
					bq_addr[bq_wr] <= bg_off(rr, la[rr]); bq_lay[bq_wr] <= rr; bq_wr <= bq_wr + 4'd1; bg_ready[rr] <= 1'b1;
				end
				rr <= (rr == 2'd2) ? 2'd0 : rr + 2'd1;
			end
			// the text layer (3) goes to the SDRAM text queue
			if (bg_req[3] && !bg_ready[3] && tq_n < 4'd7) begin
				tq_a[tqw] <= la[3]; tqw <= tqw + 3'd1; bg_ready[3] <= 1'b1;
			end
			// a finished text row is emitted on a clock with no BG response
			if (tx_done) tx_pend <= 1'b1;
			if ((tx_pend || tx_done) && !(bg_busy && bg_ch_req && bg_ack_s)) begin
				bg_data <= {64'd0, tx_row}; bg_valid[3] <= 1'b1; tx_pend <= 1'b0;
			end
			// one in flight
			if (!bg_busy && bq_rd != bq_wr && !bg_ack_s) begin
				bg_ch_req <= 1'b1; bg_ch_addr <= DDR_BASE + {7'd0, bq_addr[bq_rd]}; bg_cur <= bq_lay[bq_rd];
				bq_rd <= bq_rd + 4'd1; bg_busy <= 1'b1;
			end
			if (bg_busy && bg_ch_req && bg_ack_s) begin
				bg_ch_req <= 1'b0; bg_data <= bg_ch_data; bg_valid[bg_cur] <= 1'b1;
			end
			if (bg_busy && !bg_ch_req && !bg_ack_s) bg_busy <= 1'b0;
		end
	end

	// ================================================================ samples (48 MHz)
	// quizmoon: banks 0/1 -> image 0x2E00000 (+4 MB for bank 1), banks 2/3 ->
	// 0x3600000, 16-bit big-endian words. macrossp: banks 0/1 hold one 8-bit
	// ROM (bp964a.u24, ROM_LOAD16_BYTE into an ERASEFF region, PLAN 1.4): the
	// image keeps its 4 MB of raw bytes and the word is {byte, 8'hFF}; banks
	// 2/3 are unmapped and read 0.
	reg [63:0] sq_buf [0:3];
	reg [3:0]  sq_val;
	reg [21:0] sq_tag [0:3];      // qword address within the sample area
	wire [24:0] s_byte = quiz ? (25'h2E00000 + {1'b0, smp_bank, smp_word, 1'b0})
	                          : (25'h2E00000 + {3'd0, smp_bank[0], smp_word});
	wire [21:0] s_q    = s_byte[24:3];
	wire        s_hit  = sq_val[smp_bank] && sq_tag[smp_bank] == s_q;
	wire [63:0] s_line = sq_buf[smp_bank];
	wire [7:0]  s_b0   = s_line[{s_byte[2:0], 3'd0} +: 8];
	wire [7:0]  s_b1   = s_line[{s_byte[2:1], 1'b1, 3'd0} +: 8];
	wire [15:0] s_word = quiz ? {s_b0, s_b1} : {s_b0, 8'hFF};
	reg         s_busy;
	always @(posedge clk) begin
		smp_ack <= 1'b0;
		if (reset || !rom_ready) begin sq_val <= 4'd0; smp_ch_req <= 1'b0; s_busy <= 1'b0; end
		else if (smp_req && !smp_ack) begin
			if (!quiz && smp_bank[1]) begin smp_data <= 16'h0000; smp_ack <= 1'b1; end   // unmapped on macrossp
			else if (s_hit && !s_busy) begin smp_data <= s_word; smp_ack <= 1'b1; end
			else if (!s_busy && !smp_ack_s) begin
				smp_ch_req <= 1'b1; smp_ch_addr <= DDR_BASE + {7'd0, s_byte[24:3], 3'b000}; s_busy <= 1'b1;
			end
		end
		if (s_busy && smp_ch_req && smp_ack_s) begin
			smp_ch_req <= 1'b0;
			sq_buf[smp_bank] <= smp_ch_q; sq_tag[smp_bank] <= s_q; sq_val[smp_bank] <= 1'b1;
		end
		if (s_busy && !smp_ch_req && !smp_ack_s) s_busy <= 1'b0;
	end

	// ================================================================ DDR3 master (96 MHz)
	// Command issue: fixed priority BG > samples > copier > fallback write.
	// Reads are tagged into an in-order queue; beats return in command order.
	reg  [1:0] rq_ch [0:7];
	reg  [3:0] rq_beats [0:7];
	reg  [2:0] rq_wr, rq_rd;
	wire [3:0] rq_n = {1'b0, rq_wr} - {1'b0, rq_rd};
	reg        bg_seen, smp_seen, cp_seen;
	reg  [3:0] beat;
	reg  [63:0] cp_buf [0:7];
	reg  [2:0]  cp_beats_in;
	reg        cp_ready96;          // a copier burst is in cp_buf
	reg        pend_ack_bg, pend_ack_smp;
	always @(posedge clk_ddr) begin
		if (ddr_por) begin
			ddr_rd <= 1'b0; ddr_we <= 1'b0; rq_wr <= 3'd0; rq_rd <= 3'd0; beat <= 4'd0;
			bg_ch_ack <= 1'b0; smp_ch_ack <= 1'b0; cp_ch_ack <= 1'b0; fb_ack <= 1'b0;
			bg_seen <= 1'b0; smp_seen <= 1'b0; cp_seen <= 1'b0;
		end else begin
			// release acks when the requester drops
			if (!bg_rq)  begin bg_ch_ack <= 1'b0; bg_seen <= 1'b0; end
			if (!smp_rq) begin smp_ch_ack <= 1'b0; smp_seen <= 1'b0; end
			if (!cp_rq)  begin cp_ch_ack <= 1'b0; cp_seen <= 1'b0; end
			if (!fb_rq)     fb_ack <= 1'b0;
			// command stage (hold while the port is busy)
			if ((ddr_rd || ddr_we) && !ddr_busy) begin ddr_rd <= 1'b0; ddr_we <= 1'b0; end
			if (!((ddr_rd || ddr_we) && ddr_busy) && !ddr_yield && rq_n < 4'd7) begin
				if (bg_rq && !bg_seen) begin
					ddr_rd <= 1'b1; ddr_we <= 1'b0; ddr_addr <= bg_ch_addr[31:3]; ddr_burstcnt <= 8'd2;
					rq_ch[rq_wr] <= 2'd0; rq_beats[rq_wr] <= 4'd2; rq_wr <= rq_wr + 3'd1; bg_seen <= 1'b1;
				end else if (smp_rq && !smp_seen) begin
					ddr_rd <= 1'b1; ddr_we <= 1'b0; ddr_addr <= smp_ch_addr[31:3]; ddr_burstcnt <= 8'd1;
					rq_ch[rq_wr] <= 2'd1; rq_beats[rq_wr] <= 4'd1; rq_wr <= rq_wr + 3'd1; smp_seen <= 1'b1;
				end else if (cp_rq && !cp_seen && rq_n == 4'd0) begin
					ddr_rd <= 1'b1; ddr_we <= 1'b0; ddr_addr <= cp_ch_addr[31:3]; ddr_burstcnt <= 8'd8;
					rq_ch[rq_wr] <= 2'd2; rq_beats[rq_wr] <= 4'd8; rq_wr <= rq_wr + 3'd1; cp_seen <= 1'b1;
				end else if (fb_rq && !fb_ack && rq_n == 4'd0) begin
					begin : fbw
						reg [31:0] a; a = DDR_BASE + {5'd0, fb_addr};
						ddr_we <= 1'b1; ddr_rd <= 1'b0; ddr_addr <= a[31:3]; ddr_burstcnt <= 8'd1;
						ddr_din <= {8{fb_byte}}; ddr_be <= 8'b1 << a[2:0];
					end
					fb_ack <= 1'b1;
				end
			end
			// data stage
			if (ddr_dout_ready && rq_n != 4'd0) begin
				case (rq_ch[rq_rd])
				2'd0: begin
					if (beat == 4'd0) bg_ch_data[63:0] <= ddr_dout;
					else begin bg_ch_data[127:64] <= ddr_dout; bg_ch_ack <= 1'b1; end
				end
				2'd1: begin smp_ch_q <= ddr_dout; smp_ch_ack <= 1'b1; end
				2'd2: begin
					cp_buf[beat[2:0]] <= ddr_dout;
					if (beat == 4'd7) cp_ch_ack <= 1'b1;
				end
				default: ;
				endcase
				if (beat + 4'd1 == rq_beats[rq_rd]) begin beat <= 4'd0; rq_rd <= rq_rd + 3'd1; end
				else beat <= beat + 4'd1;
			end
		end
	end

	// ================================================================ copier (48 MHz)
	// 64-byte bursts from DDR3, written to SDRAM as 16-bit words on port 0.
	reg        copying;
	reg [24:0] cp_src;             // image byte offset of the current burst
	reg [4:0]  cp_w;               // word within the burst (32 words)
	reg        cp_have;            // cp_buf holds the burst
	reg        cw_req;             // SDRAM write request (held until valid)
	reg [24:1] cw_addr;
	reg [15:0] cw_din;
	wire       cw_valid;
	reg        copy_done_48;
	always @(posedge clk) begin
		copy_done_48 <= 1'b0;
		if (pwr_reset) begin copying <= 1'b0; cp_ch_req <= 1'b0; cw_req <= 1'b0; dbg_copy_words <= 32'd0; end
		else if (copy_start) begin
			copying <= 1'b1; cp_src <= 25'd0; cp_have <= 1'b0; cp_w <= 5'd0; dbg_copy_words <= 32'd0;
		end else if (copying) begin
			if (!cp_have) begin
				if (!cp_ch_req && !cp_ack_s) begin cp_ch_req <= 1'b1; cp_ch_addr <= DDR_BASE + {7'd0, cp_src}; end
				if (cp_ch_req && cp_ack_s) begin cp_ch_req <= 1'b0; cp_have <= 1'b1; cp_w <= 5'd0; end
			end else if (!cw_req) begin
				begin : word
					reg [63:0] q; q = cp_buf[cp_w[4:2]];
					cw_din  <= q[{cp_w[1:0], 4'd0} +: 16];        // little-endian word
				end
				cw_addr <= {cp_src[24:6], cp_w};
				cw_req  <= 1'b1;
			end else if (cw_valid) begin
				cw_req <= 1'b0;
				dbg_copy_words <= dbg_copy_words + 32'd1;
				if (cp_w == 5'd31) begin
					cp_have <= 1'b0;
					if (cp_src + 25'd64 >= COPY_BYTES) begin copying <= 1'b0; copy_done_48 <= 1'b1; end
					else cp_src <= cp_src + 25'd64;
				end else cp_w <= cp_w + 5'd1;
			end
		end
	end

	// ================================================================ SDRAM port 0: main CPU + copier
	wire [24:1] p0_addr [0:1];  wire p0_we [0:1];  wire p0_wrl [0:1]; wire p0_wrh [0:1];
	wire [15:0] p0_din [0:1];   wire p0_req [0:1]; wire p0_busy [0:1]; wire p0_valid [0:1];
	wire [15:0] p0_dout [0:1];  wire [31:0] p0_pair [0:1];
	// main CPU: one pair per longword; image offset 0 (main program region)
	reg m_req;
	assign p0_addr[0] = {3'd0, mrom_addr, 1'b0};
	assign p0_we[0] = 1'b0; assign p0_wrl[0] = 1'b0; assign p0_wrh[0] = 1'b0; assign p0_din[0] = 16'd0;
	assign p0_req[0] = m_req;
	always @(posedge clk) begin
		mrom_ack <= 1'b0;
		if (reset) m_req <= 1'b0;
		else begin
			if (mrom_req && !m_req && !mrom_ack) m_req <= 1'b1;
			if (m_req && p0_valid[0]) begin
				m_req <= 1'b0; mrom_ack <= 1'b1;
				// pair = {b3, b2, b1, b0}; the 68020 wants {b0, b1, b2, b3}
				mrom_data <= {p0_pair[0][7:0], p0_pair[0][15:8], p0_pair[0][23:16], p0_pair[0][31:24]};
			end
		end
	end
	assign p0_addr[1] = cw_addr; assign p0_we[1] = 1'b1; assign p0_wrl[1] = 1'b1; assign p0_wrh[1] = 1'b1;
	assign p0_din[1] = cw_din;   assign p0_req[1] = cw_req; assign cw_valid = p0_valid[1];
	sdram_arb #(.N(2)) u_arb0 (
		.clk(clk), .reset(pwr_reset),
		.i_addr(p0_addr), .i_we(p0_we), .i_wrl(p0_wrl), .i_wrh(p0_wrh), .i_din(p0_din),
		.i_req(p0_req), .i_busy(p0_busy), .i_valid(p0_valid), .i_dout(p0_dout), .i_dout_pair(p0_pair),
		.sdram_addr(sdram_addr0), .sdram_wrl(sdram_wrl0), .sdram_wrh(sdram_wrh0), .sdram_din(sdram_din0),
		.sdram_dout(sdram_dout0), .sdram_dout_pair(sdram_pair0), .sdram_req(sdram_req0), .sdram_ack(sdram_ack0));

	// ================================================================ SDRAM port 1: sound CPU
	wire [24:1] p1_addr [0:0];  wire p1_we [0:0];  wire p1_wrl [0:0]; wire p1_wrh [0:0];
	wire [15:0] p1_din [0:0];   wire p1_req [0:0]; wire p1_busy [0:0]; wire p1_valid [0:0];
	wire [15:0] p1_dout [0:0];  wire [31:0] p1_pair [0:0];
	wire [15:0] s_rom_word;
	wire        s_rom_ready;
	rom_cache_n #(.LINES(16), .PREFETCH(1), .LAST_PAIR(22'h13FFFF)) u_scache (
		.clk(clk), .reset(reset | !rom_ready),
		.addr(23'h200000 + {4'd0, srom_addr}),       // image 0x400000 = word 0x200000
		.data(s_rom_word), .ready(s_rom_ready),
		.sd_addr(p1_addr[0]), .sd_req(p1_req[0]), .sd_busy(p1_busy[0]), .sd_valid(p1_valid[0]),
		.sd_dout(p1_dout[0]), .sd_dout_pair(p1_pair[0]));
	assign p1_we[0] = 1'b0; assign p1_wrl[0] = 1'b0; assign p1_wrh[0] = 1'b0; assign p1_din[0] = 16'd0;
	assign srom_data = {s_rom_word[7:0], s_rom_word[15:8]};    // the 68000 wants the even byte high
	assign srom_ack  = srom_req && s_rom_ready;
	sdram_arb #(.N(1)) u_arb1 (
		.clk(clk), .reset(reset | !rom_ready),
		.i_addr(p1_addr), .i_we(p1_we), .i_wrl(p1_wrl), .i_wrh(p1_wrh), .i_din(p1_din),
		.i_req(p1_req), .i_busy(p1_busy), .i_valid(p1_valid), .i_dout(p1_dout), .i_dout_pair(p1_pair),
		.sdram_addr(sdram_addr1), .sdram_wrl(sdram_wrl1), .sdram_wrh(sdram_wrh1), .sdram_din(sdram_din1),
		.sdram_dout(sdram_dout1), .sdram_dout_pair(sdram_pair1), .sdram_req(sdram_req1), .sdram_ack(sdram_ack1));

	// ================================================================ SDRAM ports 2/3: sprite and text rows
	// A row is N pair reads (sprite 4, text 2), assembled little-endian.
	wire [24:1] p2_addr [0:0];  wire p2_we [0:0];  wire p2_wrl [0:0]; wire p2_wrh [0:0];
	wire [15:0] p2_din [0:0];   wire p2_req [0:0]; wire p2_busy [0:0]; wire p2_valid [0:0];
	wire [15:0] p2_dout [0:0];  wire [31:0] p2_pair [0:0];
	wire [24:1] p3_addr [0:0];  wire p3_we [0:0];  wire p3_wrl [0:0]; wire p3_wrh [0:0];
	wire [15:0] p3_din [0:0];   wire p3_req [0:0]; wire p3_busy [0:0]; wire p3_valid [0:0];
	wire [15:0] p3_dout [0:0];  wire [31:0] p3_pair [0:0];

	// sprite rows: image 0x600000 + addr; queue of up to 8
	reg [23:0] sq_a [0:7];
	reg [2:0]  sqw, sqr;
	wire [3:0] sq_n = {1'b0, sqw} - {1'b0, sqr};
	reg        sp_act, sp_req;
	reg [1:0]  sp_k;
	reg [24:0] sp_base;
	reg [95:0] sp_acc;
	always @(posedge clk) begin
		spr_ready <= 1'b0; spr_valid <= 1'b0;
		if (reset || !rom_ready) begin sqw <= 3'd0; sqr <= 3'd0; sp_act <= 1'b0; sp_req <= 1'b0; end
		else begin
			if (spr_req && !spr_ready && sq_n < 4'd7) begin sq_a[sqw] <= spr_addr; sqw <= sqw + 3'd1; spr_ready <= 1'b1; end
			if (!sp_act && sqr != sqw) begin
				sp_act <= 1'b1; sp_k <= 2'd0; sp_base <= 25'h600000 + {1'b0, sq_a[sqr]}; sqr <= sqr + 3'd1; sp_req <= 1'b1;
			end else if (sp_act && sp_req && p2_valid[0]) begin
				sp_req <= 1'b0;
				case (sp_k)
				2'd0: sp_acc[31:0]  <= p2_pair[0];
				2'd1: sp_acc[63:32] <= p2_pair[0];
				2'd2: sp_acc[95:64] <= p2_pair[0];
				2'd3: begin spr_data <= {p2_pair[0], sp_acc}; spr_valid <= 1'b1; sp_act <= 1'b0; end
				endcase
				sp_k <= sp_k + 2'd1;
			end else if (sp_act && !sp_req) sp_req <= 1'b1;        // next pair (req low one clock between)
		end
	end
	assign p2_addr[0] = {sp_base[24:4], sp_k, 1'b0};
	assign p2_we[0] = 1'b0; assign p2_wrl[0] = 1'b0; assign p2_wrh[0] = 1'b0; assign p2_din[0] = 16'd0;
	assign p2_req[0] = sp_req;

	// text rows: image 0x500000 + addr (8 bytes); accepted and answered by the
	// BG front end on bg_ready[3] / bg_valid[3]
	reg [22:0] tq_a [0:7];
	reg [2:0]  tqw, tqr;
	wire [3:0] tq_n = {1'b0, tqw} - {1'b0, tqr};
	reg        tx_act, tx_req, tx_k, tx_done, tx_pend;
	reg [24:0] tx_base;
	reg [31:0] tx_acc;
	reg [63:0] tx_row;
	wire [63:0] tx_row_n = {p3_pair[0], tx_acc};
	always @(posedge clk) begin
		tx_done <= 1'b0;
		if (reset || !rom_ready) begin tqr <= 3'd0; tx_act <= 1'b0; tx_req <= 1'b0; end
		else begin
			if (!tx_act && tqr != tqw) begin
				tx_act <= 1'b1; tx_k <= 1'b0; tx_base <= 25'h500000 + {2'd0, tq_a[tqr]}; tqr <= tqr + 3'd1; tx_req <= 1'b1;
			end else if (tx_act && tx_req && p3_valid[0]) begin
				tx_req <= 1'b0;
				if (!tx_k) tx_acc <= p3_pair[0];
				else begin tx_row <= tx_row_n; tx_done <= 1'b1; tx_act <= 1'b0; end
				tx_k <= ~tx_k;
			end else if (tx_act && !tx_req) tx_req <= 1'b1;
		end
	end
	assign p3_addr[0] = {tx_base[24:3], tx_k, 1'b0};
	assign p3_we[0] = 1'b0; assign p3_wrl[0] = 1'b0; assign p3_wrh[0] = 1'b0; assign p3_din[0] = 16'd0;
	assign p3_req[0] = tx_req;

	sdram_arb #(.N(1)) u_arb2 (
		.clk(clk), .reset(reset | !rom_ready),
		.i_addr(p2_addr), .i_we(p2_we), .i_wrl(p2_wrl), .i_wrh(p2_wrh), .i_din(p2_din),
		.i_req(p2_req), .i_busy(p2_busy), .i_valid(p2_valid), .i_dout(p2_dout), .i_dout_pair(p2_pair),
		.sdram_addr(sdram_addr2), .sdram_wrl(sdram_wrl2), .sdram_wrh(sdram_wrh2), .sdram_din(sdram_din2),
		.sdram_dout(sdram_dout2), .sdram_dout_pair(sdram_pair2), .sdram_req(sdram_req2), .sdram_ack(sdram_ack2));
	sdram_arb #(.N(1)) u_arb3 (
		.clk(clk), .reset(reset | !rom_ready),
		.i_addr(p3_addr), .i_we(p3_we), .i_wrl(p3_wrl), .i_wrh(p3_wrh), .i_din(p3_din),
		.i_req(p3_req), .i_busy(p3_busy), .i_valid(p3_valid), .i_dout(p3_dout), .i_dout_pair(p3_pair),
		.sdram_addr(sdram_addr3), .sdram_wrl(sdram_wrl3), .sdram_wrh(sdram_wrh3), .sdram_din(sdram_din3),
		.sdram_dout(sdram_dout3), .sdram_dout_pair(sdram_pair3), .sdram_req(sdram_req3), .sdram_ack(sdram_ack3));

endmodule
