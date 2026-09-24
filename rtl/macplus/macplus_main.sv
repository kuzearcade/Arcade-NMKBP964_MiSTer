// Macross Plus main board: 68EC020 (TG68K.C via ITech32's adapter), bus
// decode, main RAM, I/O, the sound latch and IRQ3 (docs/PLAN.md 1.2, 1.3, 2.4).
//
// Map (byte addresses, macrossp.cpp:807-841):
//   000000-3FFFFF  program ROM (rom_* port; the core supplies SDRAM or an array)
//   800000-A03FFF  video (macplus_video's CPU port)
//   B00000         INPUTS (32-bit, active low)
//   B00004         sound status: bit 1 = command pending, bit 0 toggles on every
//                  read (MAME's guess, kept while Q11 is open). The games read
//                  it with btst on B00007, one access per read (MP-5).
//   B0000C         DSW in [31:16]; [15:0] read FFFF
//   B00012         fade: high byte of a 16-bit write (0xFF is ignored, as MAME)
//   B00008, B00020 written, ignored
//   C00000         sound command: a write to the upper halfword latches it,
//                  sets pending and raises the sound CPU's IRQ2. MAME also
//                  stalls the main CPU 50 us here; the board does not.
//   F00000-F1FFFF  main RAM, 128 KB
// Unmapped reads return 0 (Q13 open).
//
// IRQ3 is raised at vblank start and held until the CPU acknowledges level 3
// (irq3_line_hold; one acknowledge retires one interrupt, MS1-23).
//
// Savestates (docs/PLAN.md 2.9, Appendix C). ss_tg68_park parks the CPU in
// its monitor; while the engine streams (ss_active) the CPU is held and this
// module answers the image words it owns, as a handshake (ss_rd/ss_wr ->
// ss_ack): main RAM through the RAM's back-door port, the video's CPU-visible
// memories (VRAM, line zoom, layer registers, live sprite RAM, palette) as
// ordinary cycles on the board bus, which reads back everything it writes;
// its scalars; and the park frame. Image word addresses:
//   00000-0FFFF  main RAM, big-endian halves of F00000-F1FFFF
//   10000-17FFF  VRAM, layer = a[14:13]      18000-183FF  line zoom, a[9:8]
//   18400-1847F  layer registers, a[6:5], 6 words each (the rest pad)
//   18800-19FFF  live sprite RAM             1E000-1FFFF  palette
//   24800        {toggle, irq3, fade}        24880-24883  SSP, USP
//
// The CPU advances on cpu_ce, a rational fraction CE_NUM/CE_DEN of clk_sys:
// 25/48 is a 25 MHz 68EC020's clock, but TG68K is not cycle-exact. D3 set the
// board's value, 33/48 (MacPlus.sv), from busy time against MAME on injected
// MAME states (docs/known-issues.md MP-13); the default here is only nominal.
module macplus_main #(
	parameter [7:0] CE_NUM = 8'd25,
	parameter [7:0] CE_DEN = 8'd48
) (
	input             clk,
	input             reset,
	input             pause,
	// program ROM: 32-bit longword reads, held request until ack
	output reg        rom_req,       // driven by macplus_cpu_bus's cache fills
	output     [19:0] rom_addr,      // longword address
	input             rom_ack,
	input      [31:0] rom_data,
	// video CPU port
	output            vid_sel,
	output     [21:0] vid_addr,
	output            vid_we,
	output     [3:0]  vid_be,
	output     [31:0] vid_din,
	input      [31:0] vid_dout,
	input             vid_ack,
	output reg [7:0]  fade,
	// I/O
	input      [31:0] inputs,        // active low, MAME's INPUTS layout
	input      [15:0] dsw,           // MAME's DSW[31:16]
	input             vblank_start,
	// sound board
	output reg        snd_cmd_we,    // one clock
	output reg [15:0] snd_cmd,
	input             snd_pending,   // cleared by the sound CPU's read
	// main RAM back door (hiscore, cheats, savestate); owns the RAM while ram2_sel
	input             ram2_sel,
	input      [14:0] ram2_addr,
	input             ram2_we,
	input      [3:0]  ram2_be,
	input      [31:0] ram2_din,
	output     [31:0] ram2_dout,
	// debug
	output     [31:0] dbg_pc_addr,
	output reg [31:0] dbg_irq3,
	output reg [31:0] dbg_iack3,
	output     [31:0] dbg_idle,
	output     [31:0] dbg_cache_miss,
	// D3: clk_sys cycles from vblank start to the game's first idle-loop write
	// that frame (its work time); 0 if it never idled
	output reg [31:0] dbg_work,
	output reg [31:0] dbg_busy,      // clocks outside the idle loop, cumulative (D3, MP-13)
	input             trace_on,
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
	output            ss_owns,       // ss_addr is one of this module's words
	output            ss_parked
);
	// ---------------------------------------------------------------- clock enable
	reg  [7:0] ce_acc;
	reg        cpu_ce;
	always @(posedge clk) begin
		cpu_ce <= 1'b0;
		if (reset) ce_acc <= 8'd0;
		else if (!pause && !ss_active) begin
			if (ce_acc + CE_NUM >= CE_DEN) begin ce_acc <= ce_acc + CE_NUM - CE_DEN; cpu_ce <= 1'b1; end
			else ce_acc <= ce_acc + CE_NUM;
		end
	end

	// ---------------------------------------------------------------- CPU (MP-6: macplus_cpu_bus)
	// Main RAM and the program-ROM cache live inside macplus_cpu_bus; the board
	// bus below carries video, I/O, the latch and unmapped addresses only.
	reg  [2:0]  ipl;
	reg         irq3, toggle;
	wire        cb_req, cb_we, iack;
	wire [23:0] cb_addr;
	wire [31:0] cb_wdata;
	wire [3:0]  cb_be;
	wire [2:0]  ipl_park;
	wire        cap_cyc, cap_between, cap_we, ovl_hit;
	wire [23:0] cap_addr;
	wire [15:0] cap_wdata, ovl_rdata;
	// the savestate master drives the board bus and the RAM port while the CPU is held
	reg         sb_req, sb_we;
	reg  [23:0] sb_addr;
	reg  [31:0] sb_wdata;
	reg  [3:0]  sb_be;
	wire        b_req   = ss_active ? sb_req   : cb_req;
	wire        b_we    = ss_active ? sb_we    : cb_we;
	wire [23:0] b_addr  = ss_active ? sb_addr  : cb_addr;
	wire [31:0] b_wdata = ss_active ? sb_wdata : cb_wdata;
	wire [3:0]  b_be    = ss_active ? sb_be    : cb_be;
	reg         sr_we;
	reg  [14:0] sr_addr;
	reg  [3:0]  sr_be;
	reg  [31:0] sr_din;
	reg         b_ack;
	reg  [31:0] b_rdata;
	wire [2:0]  iack_level;
	wire        c_rom_req;
	wire [19:0] c_rom_addr;
	macplus_cpu_bus u_cpu (
		.clk(clk), .reset(reset), .cpu_ce(cpu_ce), .irq_level(ipl_park[2] ? ipl_park : ipl), .iack(iack), .iack_level(iack_level),
		.rom_req(c_rom_req), .rom_addr(c_rom_addr), .rom_ack(rom_ack), .rom_data(rom_data),
		.ram2_sel(ss_active | ram2_sel), .ram2_addr(ss_active ? sr_addr : ram2_addr), .ram2_we(ss_active ? sr_we : ram2_we),
		.ram2_be(ss_active ? sr_be : ram2_be), .ram2_din(ss_active ? sr_din : ram2_din), .ram2_dout(ram2_dout),
		.board_req(cb_req), .board_we(cb_we), .board_addr(cb_addr), .board_wdata(cb_wdata), .board_be(cb_be),
		.board_ack(b_ack), .board_rdata(b_rdata),
		.dbg_addr(dbg_pc_addr), .dbg_idle_writes(dbg_idle), .dbg_cache_miss(dbg_cache_miss), .dbg_idle_pulse(idle_pulse), .trace_on(trace_on),
		.cap_cyc(cap_cyc), .cap_between(cap_between), .cap_addr(cap_addr), .cap_we(cap_we), .cap_wdata(cap_wdata),
		.ovl_hit(ovl_hit), .ovl_rdata(ovl_rdata));

	// ---------------------------------------------------------------- savestate
	reg  [1:0]  sst;
	reg         sa0;
	wire r_ram  = ss_addr < 20'h10000;
	wire r_vid  = (ss_addr >= 20'h10000 && ss_addr < 20'h1A000) || (ss_addr >= 20'h1E000 && ss_addr < 20'h20000);
	wire r_hole = (ss_addr >= 20'h18400 && ss_addr < 20'h18800) && (ss_addr >= 20'h18480 || ss_addr[4:0] >= 5'd6);
	wire r_sc   = ss_addr[19:4] == 16'h2480;
	wire r_pk   = ss_addr[19:2] == 18'h09220;             // 24880-24883
	assign ss_owns = r_ram | r_vid | r_sc | r_pk;
	wire ss_go     = ss_active && (ss_rd || ss_wr) && sst == 2'd0;
	wire ss_sc_we  = ss_go && ss_wr && r_sc && ss_addr[3:0] == 4'd0;
	wire ss_pk_we  = ss_go && ss_wr && r_pk;
	wire [15:0] pk_rdata;
	ss_tg68_park u_park (
		.clk(clk), .reset(reset), .park_req(ss_park_req), .parked(ss_parked), .resume(ss_resume),
		.cyc(cap_cyc), .between(cap_between), .c_addr(cap_addr), .c_we(cap_we), .c_wdata(cap_wdata),
		.iack7(iack && iack_level == 3'd7), .ipl_park(ipl_park), .ovl_hit(ovl_hit), .ovl_rdata(ovl_rdata),
		.ss_sel(ss_addr[1:0]), .ss_wr(ss_pk_we), .ss_wdata(ss_wdata), .ss_rdata(pk_rdata));

	// a video word's CPU byte address (macplus_video's map)
	function [23:0] vaddr(input [19:0] a);
		reg [19:0] o;
		begin
			o = a - 20'h18800;
			if (a < 20'h18000)      vaddr = {7'h48, a[14:13], 1'b0, a[12:0], 1'b0};           // 900000 + L*8000 + i*2
			else if (a < 20'h18400) vaddr = {7'h48, a[9:8], 1'b1, 4'h0, 1'b1, a[7:0], 1'b0};   //  + 4200 + i*2
			else if (a < 20'h18800) vaddr = {7'h48, a[6:5], 3'b101, 6'd0, a[4:0], 1'b0};       //  + 5000 + i*2
			else if (a < 20'h1A000) vaddr = {8'h80, 2'b00, o[12:0], 1'b0};                     // 800000 + i*2
			else                    vaddr = {8'hA0, 2'b00, a[12:0], 1'b0};                     // A00000 + i*2
		end
	endfunction
	always @(posedge clk) begin
		ss_ack <= 1'b0; sr_we <= 1'b0;
		if (reset || !ss_active) begin
			sst <= 2'd0; sb_req <= 1'b0;
		end else case (sst)
		2'd0: if ((ss_rd || ss_wr) && ss_owns) begin
			sa0 <= ss_addr[0];
			if (r_ram) begin
				sr_addr <= ss_addr[15:1]; sr_be <= ss_addr[0] ? 4'b0011 : 4'b1100;
				sr_din <= {ss_wdata, ss_wdata}; sr_we <= ss_wr; sst <= 2'd1;
			end else if (r_hole) begin
				ss_rdata <= 16'h0000; ss_ack <= 1'b1;
			end else if (r_vid) begin
				sb_req <= 1'b1; sb_we <= ss_wr; sb_addr <= vaddr(ss_addr);
				sb_be <= ss_addr[0] ? 4'b0011 : 4'b1100; sb_wdata <= {ss_wdata, ss_wdata}; sst <= 2'd3;
			end else if (r_sc) begin
				ss_rdata <= (ss_addr[3:0] == 4'd0) ? {6'd0, toggle, irq3, fade} : 16'h0000; ss_ack <= 1'b1;
			end else begin
				ss_rdata <= pk_rdata; ss_ack <= 1'b1;
			end
		end
		2'd1: sst <= 2'd2;                        // the RAM samples the address this clock
		2'd2: begin ss_rdata <= sa0 ? ram2_dout[15:0] : ram2_dout[31:16]; ss_ack <= 1'b1; sst <= 2'd0; end
		2'd3: if (b_ack) begin
			sb_req <= 1'b0; ss_rdata <= sa0 ? b_rdata[15:0] : b_rdata[31:16]; ss_ack <= 1'b1; sst <= 2'd0;
		end
		endcase
	end
	wire idle_pulse;
	// D3's work time is measured from the level-3 ACKNOWLEDGE, not from vblank
	// start: the idle loop runs on until the interrupt is taken at an instruction
	// boundary, and its next counter write could end the window before the
	// handler began (0.4 us "frames", 2026-09-24). MAME's window starts at the
	// vector fetch, which is the same instant.
	reg [31:0] work_cnt;
	reg        work_armed;
	always @(posedge clk) begin
		if (reset) begin work_armed <= 1'b0; dbg_work <= 32'd0; end
		else if (iack && iack_level == 3'd3) begin
			if (work_armed) dbg_work <= 32'd0;           // never idled last frame
			work_cnt <= 32'd0; work_armed <= 1'b1;
		end else if (work_armed) begin
			work_cnt <= work_cnt + 32'd1;
			if (idle_pulse) begin dbg_work <= work_cnt; work_armed <= 1'b0; end
		end
	end

	// D3's busy time (MP-13): the sum of the gaps between idle-loop counter
	// writes longer than 5 us (240 clocks; the loop writes about every 1 us),
	// a gap still open at vblank split there. macplus_inject.lua measures
	// MAME the same way. Unlike dbg_work it does not depend on where the
	// interrupt lands in the game's logic.
	reg [31:0] busy_gap;
	always @(posedge clk) begin
		if (reset) begin busy_gap <= 32'd0; dbg_busy <= 32'd0; end
		else if (ss_park_req) busy_gap <= 32'd0;      // a savestate hold is not work
		else if (idle_pulse || vblank_start) begin
			if (busy_gap > 32'd240) dbg_busy <= dbg_busy + busy_gap;
			busy_gap <= 32'd0;
		end else busy_gap <= busy_gap + 32'd1;
	end

	// ---------------------------------------------------------------- IRQ3

	always @(posedge clk) begin
		if (reset) begin irq3 <= 1'b0; dbg_irq3 <= 32'd0; dbg_iack3 <= 32'd0; end
		else if (ss_sc_we) irq3 <= ss_wdata[8];
		else begin
			if (vblank_start) begin irq3 <= 1'b1; dbg_irq3 <= dbg_irq3 + 32'd1; end
			else if (iack && iack_level == 3'd3) begin irq3 <= 1'b0; dbg_iack3 <= dbg_iack3 + 32'd1; end
		end
		ipl <= irq3 ? 3'd3 : 3'd0;
	end

	// ---------------------------------------------------------------- decode
	wire s_vid = b_addr >= 24'h800000 && b_addr < 24'hA04000;
	wire s_io  = b_addr[23:8] == 16'hB000;
	wire s_snd = b_addr[23:2] == 22'h300000;          // C00000-C00003
	always @(*) rom_req = c_rom_req;
	assign rom_addr = c_rom_addr;
	assign vid_sel  = b_req && s_vid && !b_ack;
	assign vid_addr = b_addr[23:2];
	assign vid_we   = b_we;
	assign vid_be   = b_be;
	assign vid_din  = b_wdata;

	// ---------------------------------------------------------------- bus cycle

	always @(posedge clk) begin
		b_ack <= 1'b0;
		snd_cmd_we <= 1'b0;
		if (reset) begin
			toggle <= 1'b0; fade <= 8'hFF;
		end else if (ss_sc_we) begin
			toggle <= ss_wdata[9]; fade <= ss_wdata[7:0];
		end else if (b_req && !b_ack) begin
			if (s_vid) begin
				if (vid_ack) begin b_rdata <= vid_dout; b_ack <= 1'b1; end
			end else if (s_io) begin
				b_ack <= 1'b1;
				case (b_addr[7:2])
				6'h00: b_rdata <= inputs;
				6'h01: begin b_rdata <= {30'd0, snd_pending, toggle}; if (!b_we) toggle <= ~toggle; end
				6'h03: b_rdata <= {dsw, 16'hFFFF};
				6'h04: begin
					b_rdata <= 32'd0;
					// B00012 is the low halfword of the B00010 longword; its high byte is b_wdata[15:8]
					if (b_we && b_be[1] && b_wdata[15:8] != 8'hFF) fade <= b_wdata[15:8];
				end
				default: b_rdata <= 32'd0;
				endcase
			end else if (s_snd) begin
				b_ack <= 1'b1; b_rdata <= 32'd0;
				if (b_we && (b_be[3] || b_be[2])) begin snd_cmd <= b_wdata[31:16]; snd_cmd_we <= 1'b1; end
			end else begin
				b_ack <= 1'b1; b_rdata <= 32'd0;           // unmapped
			end
		end
	end
endmodule
