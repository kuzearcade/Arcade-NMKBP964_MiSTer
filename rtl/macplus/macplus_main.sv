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
// The CPU advances on cpu_ce, a rational fraction CE_NUM/CE_DEN of clk_sys:
// 25/48 is a 25 MHz 68EC020's clock, but TG68K is not cycle-exact, and D3 sets
// the ratio from the per-frame CPU work measured against MAME (M2 gate 3).
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
	output     [31:0] dbg_cache_miss
);
	// ---------------------------------------------------------------- clock enable
	reg  [7:0] ce_acc;
	reg        cpu_ce;
	always @(posedge clk) begin
		cpu_ce <= 1'b0;
		if (reset) ce_acc <= 8'd0;
		else if (!pause) begin
			if (ce_acc + CE_NUM >= CE_DEN) begin ce_acc <= ce_acc + CE_NUM - CE_DEN; cpu_ce <= 1'b1; end
			else ce_acc <= ce_acc + CE_NUM;
		end
	end

	// ---------------------------------------------------------------- CPU (MP-6: macplus_cpu_bus)
	// Main RAM and the program-ROM cache live inside macplus_cpu_bus; the board
	// bus below carries video, I/O, the latch and unmapped addresses only.
	reg  [2:0]  ipl;
	wire        b_req, b_we, iack;
	wire [23:0] b_addr;
	wire [31:0] b_wdata;
	wire [3:0]  b_be;
	reg         b_ack;
	reg  [31:0] b_rdata;
	wire [2:0]  iack_level;
	wire        c_rom_req;
	wire [19:0] c_rom_addr;
	macplus_cpu_bus u_cpu (
		.clk(clk), .reset(reset), .cpu_ce(cpu_ce), .irq_level(ipl), .iack(iack), .iack_level(iack_level),
		.rom_req(c_rom_req), .rom_addr(c_rom_addr), .rom_ack(rom_ack), .rom_data(rom_data),
		.ram2_sel(ram2_sel), .ram2_addr(ram2_addr), .ram2_we(ram2_we), .ram2_be(ram2_be), .ram2_din(ram2_din), .ram2_dout(ram2_dout),
		.board_req(b_req), .board_we(b_we), .board_addr(b_addr), .board_wdata(b_wdata), .board_be(b_be),
		.board_ack(b_ack), .board_rdata(b_rdata),
		.dbg_addr(dbg_pc_addr), .dbg_idle_writes(dbg_idle), .dbg_cache_miss(dbg_cache_miss));
	always @(*) rom_req = c_rom_req;

	// ---------------------------------------------------------------- IRQ3
	reg irq3;
	always @(posedge clk) begin
		if (reset) begin irq3 <= 1'b0; dbg_irq3 <= 32'd0; dbg_iack3 <= 32'd0; end
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
	assign rom_addr = c_rom_addr;
	assign vid_sel  = b_req && s_vid && !b_ack;
	assign vid_addr = b_addr[23:2];
	assign vid_we   = b_we;
	assign vid_be   = b_be;
	assign vid_din  = b_wdata;

	// ---------------------------------------------------------------- bus cycle
	reg        toggle;
	always @(posedge clk) begin
		b_ack <= 1'b0;
		snd_cmd_we <= 1'b0;
		if (reset) begin
			toggle <= 1'b0; fade <= 8'hFF;
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
