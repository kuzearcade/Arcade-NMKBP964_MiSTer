// Macross Plus sound board: 68000 @ 16 MHz (fx68k), 32 KB RAM, the 16-bit
// sound latch, and the Ensoniq ES5506 (vendored from Arcade-ITech32_MiSTer,
// rtl/third_party/es5506) (docs/PLAN.md 1.4, 2.5).
//
// Map (macrossp.cpp:843-849):
//   000000-0FFFFF  program ROM (rom_* port, 16-bit)
//   200000-207FFF  RAM
//   400000-40007F  ES5506 on the LOW byte of each word: register (A >> 1) & 0x3F
//   600000-600001  sound latch read; clears the main CPU's pending bit
// IRQ2 on every latch write (HOLD_LINE), retired by its acknowledge. The ES5506
// IRQ is MAME's "never seen" line (Q12): it is counted, not wired, until
// measured.
//
// ES5506 sample space: four banks of 2M words. The core maps a bank and word
// to its image; `smp_*` is the held request/ack the module expects.
// Output: the ES5506's channel 0, 20-bit stereo, at MAME's level. MAME puts
// the sample out as sample / 2^19 (es5506.cpp put_int_clamp(..., 1 << 19)),
// routes it at 1.6, and a 16-bit WAV is that times 32768: sample * 0.1. Here
// (sample * 205) >> 11 = sample * 0.10010, saturated to 16 bits (the level is
// then confirmed against MAME's WAV, MS1Z-13).
//
// Savestates (docs/PLAN.md 2.9, Appendix C): ss_m68k_park parks the 68000;
// once it is parked the ES5506's 16 MHz enable stops, and when the engine has
// finished its voice (es_quiet) the chip's voice rows and globals are read and
// written through its savestate port. Image word addresses:
//   20000-23FFF  sound RAM
//   24000-2441F  ES5506: row r (0-31 voices, 32 globals) at 24000 + r*32; a
//                voice is 27 words (431 bits), the globals 29 words (460),
//                MSB first, padded; the rest of each 32-word row is padding
//   24810-24811  {irq2, pending}, the latched command
//   24884-24887  SSP, USP of the park frame
module macplus_sound (
	input             clk,
	input             reset,
	input             pause,
	// program ROM (16-bit words), held request until ack
	output reg        rom_req,
	output     [18:0] rom_addr,      // word address
	input             rom_ack,
	input      [15:0] rom_data,
	// latch from the main CPU
	input             cmd_we,
	input      [15:0] cmd,
	output reg        pending,
	// ES5506 sample memory
	output            smp_req,
	output     [1:0]  smp_bank,
	output     [20:0] smp_word,
	input             smp_ack,
	input      [15:0] smp_data,
	// audio
	output reg signed [15:0] snd_l,
	output reg signed [15:0] snd_r,
	// debug
	output reg [31:0] dbg_es_writes,
	output reg [31:0] dbg_es_irq,
	output reg [31:0] dbg_latch_reads,
	// savestate
	input             ss_park_req,
	input             ss_resume,
	input             ss_active,
	input      [19:0] ss_addr,
	input             ss_rd,
	input             ss_wr,
	input      [15:0] ss_wdata,
	output reg [15:0] ss_rdata,
	output reg        ss_ack,
	output            ss_owns,
	output            ss_parked,
	output reg        es_quiet       // the ES5506 is stopped between voices
);
	// savestate signals used throughout (the logic is above the ES5506)
	wire [2:0]  ipl_park;
	wire        sel_mon;
	wire [15:0] mon_data, pk_rdata;
	reg  [1:0]  ss_st;
	wire        ss_es = ss_addr[19:11] == 9'h048;              // 24000-247FF
	wire        ss_sc = ss_addr[19:1] == 19'h12408;            // 24810-24811
	wire        ss_pk = ss_addr[19:2] == 18'h09221;            // 24884-24887
	wire        ss_go    = ss_active && (ss_rd || ss_wr) && ss_st == 2'd0;
	wire        ss_sc_we = ss_go && ss_wr && ss_sc;
	wire        es_hold  = ss_active | (ss_park_req & ss_parked);

	// ---------------------------------------------------------------- clocks
	// 16 MHz from 48: fx68k wants phi1 and phi2 on alternate enables, so the
	// pattern is phi1, phi2, idle. The ES5506's 16 MHz enable is 1 in 3.
	reg [1:0] div3;
	reg       enPhi1, enPhi2, ce_16m;
	reg       pause_68k = 1'b0;
	always @(posedge clk) begin
		enPhi1 <= 1'b0; enPhi2 <= 1'b0; ce_16m <= 1'b0;
		if (reset) div3 <= 2'd0;
		else begin
			div3 <= (div3 == 2'd2) ? 2'd0 : div3 + 2'd1;
			if (div3 == 2'd0) begin enPhi1 <= 1'b1; ce_16m <= !pause && !es_hold; end
			if (div3 == 2'd1) enPhi2 <= 1'b1;
		end
		if (enPhi2) pause_68k <= pause | ss_active;   // pause only on a phi2 boundary (NMK-24)
	end

	// ---------------------------------------------------------------- 68000
	wire        eRWn, ASn, LDSn, UDSn, VMAn, FC0, FC1, FC2, BGn, oRESETn, oHALTEDn;
	wire [15:0] oEdb;
	wire [23:1] eab;
	reg  [15:0] iEdb;
	wire [23:0] a = {eab, 1'b0};
	wire        as_active = ~ASn & (~LDSn | ~UDSn);
	wire        iack = ~ASn & FC0 & FC1 & FC2;
	wire        sel_rom   = a < 24'h100000;
	wire        sel_ram   = a >= 24'h200000 && a < 24'h208000;
	wire        sel_es    = a >= 24'h400000 && a < 24'h400080;
	wire        sel_latch = a[23:1] == 23'h300000;          // 600000-600001

	// ROM: the address is held while the bus is not selecting ROM (MS1-50)
	reg  [18:0] rom_held;
	always @(posedge clk) if (as_active && sel_rom) rom_held <= a[19:1];
	assign rom_addr = (as_active && sel_rom) ? a[19:1] : rom_held;

	// RAM 16K words, byte lanes
	reg [7:0] rl [0:16383], rh [0:16383];
	reg [15:0] ram_q;
	wire        ss_ram = ss_addr[19:14] == 6'h08;             // 20000-23FFF
	wire [13:0] ri = ss_active ? ss_addr[13:0] : a[14:1];
	wire ram_we  = as_active && !eRWn && sel_ram && !ss_active;
	wire ss_rwe  = ss_active && ss_wr && ss_ram && ss_st == 2'd0;
	always @(posedge clk) begin
		if ((ram_we && !LDSn) || ss_rwe) rl[ri] <= ss_rwe ? ss_wdata[7:0]  : oEdb[7:0];
		if ((ram_we && !UDSn) || ss_rwe) rh[ri] <= ss_rwe ? ss_wdata[15:8] : oEdb[15:8];
		ram_q <= {rh[ri], rl[ri]};
	end

	// ---------------------------------------------------------------- bus cycle
	// DTACK: ROM when the fetch returns, RAM one clock after the address,
	// ES5506 when the chip acknowledges, the latch at once.
	reg        as_d, ram_ok, dtack;
	reg        es_req, es_done;
	reg [15:0] rd_hold;
	wire [7:0] es_rdata;
	wire       es_ack;
	always @(posedge clk) begin
		as_d <= as_active;
		if (reset || !as_active) begin
			rom_req <= 1'b0; ram_ok <= 1'b0; dtack <= 1'b0; es_req <= 1'b0; es_done <= 1'b0;
		end else if (!dtack) begin
			if (sel_rom) begin
				rom_req <= 1'b1;
				if (rom_ack) begin rom_req <= 1'b0; rd_hold <= rom_data; dtack <= 1'b1; end
			end else if (sel_ram) begin
				if (ram_ok) begin rd_hold <= ram_q; dtack <= 1'b1; end
				ram_ok <= 1'b1;
			end else if (sel_es) begin
				if (!es_done) begin
					es_req <= 1'b1;
					if (es_ack) begin es_req <= 1'b0; es_done <= 1'b1; rd_hold <= {8'h00, es_rdata}; dtack <= 1'b1; end
				end
			end else if (sel_latch) begin
				rd_hold <= cmd_q; dtack <= 1'b1;
			end else if (!iack) begin
				rd_hold <= 16'h0000; dtack <= 1'b1;          // unmapped
			end
		end
	end
	always @* iEdb = sel_mon ? mon_data : rd_hold;

	// ---------------------------------------------------------------- latch, IRQ2
	reg [15:0] cmd_q;
	reg        irq2;
	reg        iack_d, latch_d;
	wire       latch_rd = as_active && eRWn && sel_latch && !latch_d;
	always @(posedge clk) begin
		iack_d <= iack; latch_d <= as_active && sel_latch;
		if (reset) begin pending <= 1'b0; irq2 <= 1'b0; cmd_q <= 16'd0; dbg_latch_reads <= 32'd0; end
		else begin
			if (ss_sc_we && ss_addr[0] == 1'b0) begin irq2 <= ss_wdata[1]; pending <= ss_wdata[0]; end
			else if (ss_sc_we) cmd_q <= ss_wdata;
			else if (cmd_we) begin cmd_q <= cmd; pending <= 1'b1; irq2 <= 1'b1; end
			else if (latch_rd) begin pending <= 1'b0; dbg_latch_reads <= dbg_latch_reads + 32'd1; end
			if (iack && !iack_d && eab[3:1] == 3'd2) irq2 <= 1'b0;
		end
	end

	fx68k u_cpu (
		.clk(clk), .HALTn(1'b1), .extReset(reset), .pwrUp(reset),
		.enPhi1(enPhi1 & ~pause_68k), .enPhi2(enPhi2 & ~pause_68k),
		.eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn), .E(), .VMAn(VMAn),
		.FC0(FC0), .FC1(FC1), .FC2(FC2), .BGn(BGn),
		.oRESETn(oRESETn), .oHALTEDn(oHALTEDn),
		.DTACKn(~(as_active & ~iack & dtack)), .VPAn(~iack),
		.BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
		.IPL0n(~ipl_park[0]), .IPL1n(~(irq2 | ipl_park[1])), .IPL2n(~ipl_park[2]),
		.iEdb(iEdb), .oEdb(oEdb), .eab(eab)
	);

	// ---------------------------------------------------------------- savestate
	assign ss_owns = ss_ram | ss_es | ss_sc | ss_pk;
	ss_m68k_park u_park (
		.clk(clk), .reset(reset), .phi(enPhi2),
		.park_req(ss_park_req), .parked(ss_parked), .resume(ss_resume),
		.eab(eab), .ASn(ASn), .eRWn(eRWn), .FC0(FC0), .FC1(FC1), .FC2(FC2), .oEdb(oEdb),
		.ipl_park(ipl_park), .sel_mon(sel_mon), .mon_data(mon_data),
		.ss_sel(ss_addr[1:0]), .ss_wr(ss_go && ss_wr && ss_pk), .ss_wdata(ss_wdata), .ss_rdata(pk_rdata));

	// the ES5506 stops once the 68000 is parked; quiet = not busy for 8 clocks
	// (with ce_16m held, a slot already due can still launch one voice)
	wire        es_busy;
	reg  [3:0]  es_q_cnt;
	always @(posedge clk) begin
		if (!es_hold || es_busy) begin es_q_cnt <= 4'd0; es_quiet <= 1'b0; end
		else if (es_q_cnt != 4'd8) es_q_cnt <= es_q_cnt + 4'd1;
		else es_quiet <= 1'b1;
	end
	// a row read: the address, two clocks for the voice RAM, then its word
	wire [430:0] es_row_q;
	wire [459:0] es_glob_q;
	reg  [463:0] es_stage;
	reg          es_row_we, es_glob_we;
	reg  [5:0]   ss_row;
	reg  [4:0]   ss_w;
	reg  [1:0]   ss_wait;
	wire [431:0] es_row_pad  = {es_row_q, 1'b0};
	wire [463:0] es_glob_pad = {es_glob_q, 4'b0};
	always @(posedge clk) begin
		ss_ack <= 1'b0; es_row_we <= 1'b0; es_glob_we <= 1'b0;
		if (reset || !ss_active) ss_st <= 2'd0;
		else case (ss_st)
		2'd0: if ((ss_rd || ss_wr) && ss_owns) begin
			if (ss_ram) begin
				if (ss_wr) ss_ack <= 1'b1; else ss_st <= 2'd1;      // ram_q samples the address this clock
			end else if (ss_es) begin
				ss_row <= ss_addr[10:5]; ss_w <= ss_addr[4:0];
				if (ss_wr) begin
					ss_ack <= 1'b1;
					// staged MSB first; a row commits on its last word
					es_stage[463 - 16*ss_addr[4:0] -: 16] <= ss_wdata;
					if (ss_addr[10:5] < 6'd32 && ss_addr[4:0] == 5'd26) es_row_we <= 1'b1;
					if (ss_addr[10:5] == 6'd32 && ss_addr[4:0] == 5'd28) es_glob_we <= 1'b1;
				end else begin ss_wait <= 2'd2; ss_st <= 2'd2; end
			end else if (ss_sc) begin
				ss_rdata <= ss_addr[0] ? cmd_q : {14'd0, irq2, pending}; ss_ack <= 1'b1;
			end else begin
				ss_rdata <= pk_rdata; ss_ack <= 1'b1;
			end
		end
		2'd1: begin ss_rdata <= ram_q; ss_ack <= 1'b1; ss_st <= 2'd0; end
		2'd2: if (ss_wait != 2'd0) ss_wait <= ss_wait - 2'd1;
		      else begin
			ss_ack <= 1'b1; ss_st <= 2'd0;
			if (ss_row == 6'd32) ss_rdata <= (ss_w < 5'd29) ? es_glob_pad[463 - 16*ss_w -: 16] : 16'h0000;
			else if (ss_row < 6'd32) ss_rdata <= (ss_w < 5'd27) ? es_row_pad[431 - 16*ss_w -: 16] : 16'h0000;
			else ss_rdata <= 16'h0000;
		end
		default: ss_st <= 2'd0;
		endcase
	end

	// ---------------------------------------------------------------- ES5506
	wire signed [19:0] es_l, es_r;
	wire        es_irq, es_strobe;
	wire [21:0] smp_addr_b;
	itech32_es5506 u_es (
		.clk(clk), .reset(reset), .ce_16m(ce_16m),
		.host_req(es_req), .host_write(!eRWn), .host_addr(a[6:1]), .host_wdata(oEdb[7:0]),
		.host_rdata(es_rdata), .host_ack(es_ack),
		.par_comparator_tripped(1'b0), .par_discharge(),
		.sample_req(smp_req), .sample_bank(smp_bank), .sample_addr(smp_addr_b), .sample_companded(),
		.sample_voice(), .sample_rdata(smp_data), .sample_ack(smp_ack),
		.audio_left(es_l), .audio_right(es_r), .audio_left_channels(), .audio_right_channels(),
		.audio_strobe(es_strobe), .irq(es_irq), .irq_vector(), .current_page(), .active_voices(),
		.scan_voice(), .engine_busy(es_busy),
		.ss_en(ss_active), .ss_voice(ss_row[4:0]), .ss_row_q(es_row_q), .ss_row_we(es_row_we), .ss_row_d(es_stage[463:33]),
		.ss_glob_q(es_glob_q), .ss_glob_we(es_glob_we), .ss_glob_d(es_stage[463:4]));
	assign smp_word = smp_addr_b[21:1];

	function signed [15:0] gain(input signed [19:0] v);
		reg signed [31:0] p;
		begin
			p = ($signed(v) * 32'sd205) >>> 11;
			gain = (p > 32'sd32767) ? 16'sh7FFF : (p < -32'sd32768) ? 16'sh8000 : p[15:0];
		end
	endfunction
	reg es_irq_d;
	always @(posedge clk) begin
		es_irq_d <= es_irq;
		if (reset) begin dbg_es_writes <= 32'd0; dbg_es_irq <= 32'd0; end
		else begin
			if (es_req && es_ack && !eRWn) dbg_es_writes <= dbg_es_writes + 32'd1;
			if (es_irq && !es_irq_d) dbg_es_irq <= dbg_es_irq + 32'd1;
		end
		if (es_strobe) begin snd_l <= gain(es_l); snd_r <= gain(es_r); end
	end
endmodule
