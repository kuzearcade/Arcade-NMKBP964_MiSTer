// Savestate support (NMKMacPlus, 2026-09-24): park the TG68K (68EC020 mode)
// at an instruction boundary and get every register out. The 68020 sibling of
// ss_m68k_park.sv; the monitor, the state registers and the protocol are the
// same, only the bus differs.
//
// The TG68K does not drive pins here: macplus_cpu_bus captures each bus cycle
// (cyc = the capture clock, c_* the cycle) and answers it from its ROM cache,
// its RAM, or the board bus. When `ovl_hit` is high on the capture clock the
// cycle is the overlay's: a read returns `ovl_rdata`, a write is taken here.
//
// Mechanism:
//   1. park_req raises a level-7 interrupt. TG68K finishes its instruction,
//      pushes a format-0 frame (SR, PC, format/vector word) on the supervisor
//      stack and acknowledges; macplus_cpu_bus autovectors it, so the CPU
//      reads vector 31 at VBR + 0x7C. VBR stays 0 on this board: Q1 found no
//      MOVEC in the code either game executes, so VBR, CACR, SFC and DFC keep
//      their reset values and need no saving (docs/known-issues.md MP-12).
//      While park_req is high the two words at 0x7C/0x7E are MON_BASE.
//   2. The 52-byte monitor at MON_BASE (the 68000 one, unchanged: every
//      instruction is a 68000 encoding the 68020 runs identically) pushes
//      D0-D7/A0-A6 on the game's stack, stores USP and SSP in the state
//      registers at MON_BASE+0x104/+0x100, writes DONE (+0x108) and spins on
//      RESUME (+0x10A).
//   3. On resume it reloads A7 and USP from the state registers, pops the
//      registers and RTEs; the RTE reads the format word and pops the 4-word
//      frame. The level-7 request was dropped at its acknowledge.
//
// MON_BASE must be unmapped on the board: 0x7F8000 is in 400000-7FFFFF, which
// macrossp.cpp:812-844 leaves empty.
//
// State registers on the word bus: 0 SSP[31:16] 1 SSP[15:0] 2 USP[31:16] 3 USP[15:0]
module ss_tg68_park #(
	parameter [23:9] MON_BASE = 15'h3FC0   // 0x7F8000: the 512-byte overlay window
) (
	input             clk,
	input             reset,

	input             park_req,     // level: hold the CPU in the monitor
	output reg        parked,       // the monitor has written DONE
	input             resume,       // level: let the monitor RTE

	// the captured cycle (macplus_cpu_bus)
	input             cyc,          // one clock: the cycle below is being decoded
	input             between,      // no cycle in progress (the FSM is idle)
	input      [23:0] c_addr,
	input             c_we,
	input      [15:0] c_wdata,
	input             iack7,        // one clock: a level-7 acknowledge

	output      [2:0] ipl_park,     // max'ed into the CPU's IPL: 7 while requesting
	output            ovl_hit,      // the captured cycle is the overlay's
	output reg [15:0] ovl_rdata,

	// state registers
	input       [1:0] ss_sel,
	input             ss_wr,
	input      [15:0] ss_wdata,
	output reg [15:0] ss_rdata
);
	// level-7 request: raised once per park request, dropped at its acknowledge
	reg ipl7 = 1'b0, armed = 1'b0;
	always @(posedge clk) begin
		if (reset | ~park_req) begin
			ipl7 <= 1'b0; armed <= 1'b0;
		end else begin
			if (~parked & ~ipl7 & ~armed) ipl7 <= 1'b1;
			if (iack7) begin ipl7 <= 1'b0; armed <= 1'b1; end
		end
	end
	assign ipl_park = ipl7 ? 3'd7 : 3'd0;

	// The overlay enable changes only between bus cycles (the ss_m68k_park
	// lesson, 2026-09-18). `left` is set once the RTE's fetch has been answered.
	reg left = 1'b0, rte_seen = 1'b0, ovl_on = 1'b0;
	always @(posedge clk) if (between) ovl_on <= park_req & ~left;

	wire sel_win  = ovl_on & (c_addr[23:9] == MON_BASE);
	wire sel_code = sel_win & ~c_addr[8];
	wire sel_regs = sel_win &  c_addr[8];
	wire sel_vec7 = ovl_on & (c_addr[23:2] == 22'h1F) & ~c_we;   // 0x7C/0x7E: vector 31
	assign ovl_hit = sel_win | sel_vec7;

	// monitor code, 26 words (ss_m68k_park.sv, unidasm-verified in sim/rtl/ss_m68k)
	wire [15:0] mb_hi = {8'h00, MON_BASE[23:16]};
	wire [15:0] mb_lo = {MON_BASE[15:9], 9'd0};
	reg  [15:0] mon;
	always @(*) begin
		case (c_addr[5:1])
			5'd0:  mon = 16'h48E7; 5'd1:  mon = 16'hFFFE;              // movem.l d0-d7/a0-a6,-(sp)
			5'd2:  mon = 16'h4E68;                                     // move usp,a0
			5'd3:  mon = 16'h23C8; 5'd4:  mon = mb_hi; 5'd5:  mon = mb_lo | 16'h0104;   // move.l a0,USP_REG
			5'd6:  mon = 16'h23CF; 5'd7:  mon = mb_hi; 5'd8:  mon = mb_lo | 16'h0100;   // move.l a7,SSP_REG
			5'd9:  mon = 16'h33FC; 5'd10: mon = 16'h0001; 5'd11: mon = mb_hi; 5'd12: mon = mb_lo | 16'h0108; // move.w #1,DONE
			5'd13: mon = 16'h4A79; 5'd14: mon = mb_hi; 5'd15: mon = mb_lo | 16'h010A;  // loop: tst.w RESUME
			5'd16: mon = 16'h67F8;                                     // beq loop
			5'd17: mon = 16'h2E79; 5'd18: mon = mb_hi; 5'd19: mon = mb_lo | 16'h0100;  // move.l SSP_REG,a7
			5'd20: mon = 16'h2079; 5'd21: mon = mb_hi; 5'd22: mon = mb_lo | 16'h0104;  // move.l USP_REG,a0
			5'd23: mon = 16'h4E60;                                     // move a0,usp
			5'd24: mon = 16'h4CDF; 5'd25: mon = 16'h7FFF;              // movem.l (sp)+,d0-d7/a0-a6
			5'd26: mon = 16'h4E73;                                     // rte
			default: mon = 16'h4E71;                                   // nop
		endcase
	end

	reg [31:0] ssp_reg = 32'd0, usp_reg = 32'd0;
	always @(*) begin
		if (sel_code) ovl_rdata = mon;
		else if (sel_regs) begin
			case (c_addr[3:1])
				3'd0: ovl_rdata = ssp_reg[31:16];
				3'd1: ovl_rdata = ssp_reg[15:0];
				3'd2: ovl_rdata = usp_reg[31:16];
				3'd3: ovl_rdata = usp_reg[15:0];
				3'd4: ovl_rdata = {15'd0, parked};
				3'd5: ovl_rdata = {15'd0, resume};
				default: ovl_rdata = 16'h0000;
			endcase
		end else ovl_rdata = c_addr[1] ? mb_lo : mb_hi;          // vector 31 -> MON_BASE
	end

	always @(posedge clk) begin
		if (ss_wr) begin
			case (ss_sel)
				2'd0: ssp_reg[31:16] <= ss_wdata;
				2'd1: ssp_reg[15:0]  <= ss_wdata;
				2'd2: usp_reg[31:16] <= ss_wdata;
				2'd3: usp_reg[15:0]  <= ss_wdata;
			endcase
		end else if (cyc & c_we & sel_regs) begin
			case (c_addr[3:1])
				3'd0: ssp_reg[31:16] <= c_wdata;
				3'd1: ssp_reg[15:0]  <= c_wdata;
				3'd2: usp_reg[31:16] <= c_wdata;
				3'd3: usp_reg[15:0]  <= c_wdata;
				3'd4: parked <= c_wdata[0];
				default: ;
			endcase
		end
		if (cyc & ~c_we & resume & sel_code & (c_addr[5:1] == 5'd26)) rte_seen <= 1'b1;
		if (rte_seen & between) begin rte_seen <= 1'b0; parked <= 1'b0; left <= 1'b1; end
		if (reset | ~park_req) begin parked <= 1'b0; left <= 1'b0; rte_seen <= 1'b0; end
	end
	always @(*) begin
		case (ss_sel)
			2'd0: ss_rdata = ssp_reg[31:16];
			2'd1: ss_rdata = ssp_reg[15:0];
			2'd2: ss_rdata = usp_reg[31:16];
			2'd3: ss_rdata = usp_reg[15:0];
		endcase
	end
endmodule
