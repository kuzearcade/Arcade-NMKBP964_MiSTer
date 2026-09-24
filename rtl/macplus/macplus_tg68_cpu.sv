// SPDX-License-Identifier: GPL-2.0-or-later
//
// From Arcade-ITech32_MiSTer (TheJesusFish), rtl/itech32/itech32_tg68_cpu.sv at
// d461e21d. Local changes: renamed; passes the adapter's `iack`/`iack_level`
// out; the adapter's vector shadow is off.
//
// ITech32-facing 68EC020 wrapper.  The canonical TG68K.C implementation is
// VHDL in rtl/cpu/tg68k; Verilator uses the reproducibly generated Verilog
// equivalent produced by sim/generate_tg68_verilog.ps1.

module macplus_tg68_cpu (
	input  logic        clk,
	input  logic        reset,
	input  logic        cpu_68000,
	input  logic        cpu_ce,
	input  logic [2:0]  irq_level,

	input  logic        vector_load_we,
	input  logic [4:0]  vector_load_addr,
	input  logic [31:0] vector_load_wdata,
	input  logic [3:0]  vector_load_be,

	output logic        board_req,
	output logic        board_we,
	output logic [23:0] board_addr,
	output logic [31:0] board_wdata,
	output logic [3:0]  board_be,
	input  logic        board_ack,
	input  logic [31:0] board_rdata,
	output logic        iack,
	output logic [2:0]  iack_level,

	output logic [31:0] debug_addr,
	output logic [1:0]  debug_busstate,
	output logic        debug_nwr,
	output logic        debug_nuds,
	output logic        debug_nlds,
	output logic [2:0]  debug_fc
);

	logic        tg_clkena;
	logic [15:0] tg_rdata;
	logic [31:0] tg_addr;
	logic [15:0] tg_wdata;
	logic        tg_nwr;
	logic        tg_nuds;
	logic        tg_nlds;
	logic [1:0]  tg_busstate;
	logic [2:0]  tg_fc;

	logic        unused_longword;
	logic        unused_nresetout;
	logic        unused_clr_berr;
	logic        unused_skip_fetch;
	logic [31:0] unused_regin;
	logic [3:0]  unused_cacr;
	logic [31:0] unused_vbr;
	logic [1:0]  local_reset_pipe;
	logic        local_reset;
	// This architectural boundary register must remain in RTL, but it must not
	// be preserve-locked. The maximum-effort route measured 81% interconnect on
	// irq_level_q -> TG68 opcode decode; allowing legal fitter retiming and
	// replication keeps the exact one-edge IRQ contract while avoiding a fixed,
	// cross-die placement anchor.
	logic [2:0] irq_level_q;

	// platform_reset also includes the HPS ROM-download qualifier.  Localize
	// its very high fanout at the CPU boundary: assertion remains immediate,
	// while release is synchronous and cannot feed TG68's internal clock-enable
	// cone directly from HPS decode logic.
	always_ff @(posedge clk or posedge reset) begin
		if (reset)
			local_reset_pipe <= 2'b11;
		else
			local_reset_pipe <= {local_reset_pipe[0], 1'b0};
	end
	assign local_reset = local_reset_pipe[1];

	// Interrupt sources are spread across the video subsystem, while TG68's
	// IPL input feeds its instruction-boundary decode directly.  Register the
	// encoded level at the CPU boundary so that cross-hierarchy IRQ priority
	// and routing are not part of that decode cone.  TG68 advances only on the
	// slower cpu_ce cadence, so this one fabric-clock latency cannot defer a
	// legal CPU interrupt sampling point.
	always_ff @(posedge clk) begin
		if (local_reset)
			irq_level_q <= 3'd0;
		else
			irq_level_q <= irq_level;
	end

	// CPU="00" selects 68000 semantics and "11" the implemented 68020 subset.
	// The game selector is stable while the CPU is out of reset. IPL is active low;
	// irq_level is the conventional active-high encoded interrupt level.
	// ITech32 uses autovectored interrupts. TG68K.C still emits the CPU-space
	// acknowledge cycle; the adapter completes it locally rather than exposing
	// it to the board bus.
	// Production mixed-language synthesis overrides the upstream VHDL generic
	// to select TG68K.C's iterative multiplier.  GHDL bakes the same generic
	// into Verilator's generated model, which therefore has no parameter left
	// to override at the SystemVerilog boundary.
`ifdef VERILATOR
	TG68KdotC_Kernel tg68k (
`else
	TG68KdotC_Kernel #(
		.MUL_Hardware (0)
	) tg68k (
`endif
		.clk            (clk),
		.nReset         (~local_reset),
		.clkena_in      (tg_clkena),
		.data_in        (tg_rdata),
		.IPL            (~irq_level_q),
		.IPL_autovector (1'b1),
		.berr           (1'b0),
		.CPU            (cpu_68000 ? 2'b00 : 2'b11),
		.addr_out       (tg_addr),
		.data_write     (tg_wdata),
		.nWr            (tg_nwr),
		.nUDS           (tg_nuds),
		.nLDS           (tg_nlds),
		.busstate       (tg_busstate),
		.longword       (unused_longword),
		.nResetOut      (unused_nresetout),
		.FC             (tg_fc),
		.clr_berr       (unused_clr_berr),
		.skipFetch      (unused_skip_fetch),
		.regin_out      (unused_regin),
		.CACR_out       (unused_cacr),
		.VBR_out        (unused_vbr)
	);

	macplus_tg68_bus_adapter #(.VECTOR_SHADOW(0)) bus_adapter (
		.clk               (clk),
		.reset             (local_reset),
		.cpu_ce            (cpu_ce),
		.tg_busstate       (tg_busstate),
		.tg_fc             (tg_fc),
		.tg_addr           (tg_addr),
		.tg_wdata          (tg_wdata),
		.tg_nuds           (tg_nuds),
		.tg_nlds           (tg_nlds),
		.tg_clkena         (tg_clkena),
		.tg_rdata          (tg_rdata),
		.vector_load_we    (vector_load_we),
		.vector_load_addr  (vector_load_addr),
		.vector_load_wdata (vector_load_wdata),
		.vector_load_be    (vector_load_be),
		.board_req         (board_req),
		.board_we          (board_we),
		.board_addr        (board_addr),
		.board_wdata       (board_wdata),
		.board_be          (board_be),
		.board_ack         (board_ack),
		.board_rdata       (board_rdata),
		.iack              (iack),
		.iack_level        (iack_level)
	);

	assign debug_addr     = tg_addr;
	assign debug_busstate = tg_busstate;
	assign debug_nwr      = tg_nwr;
	assign debug_nuds     = tg_nuds;
	assign debug_nlds     = tg_nlds;
	assign debug_fc       = tg_fc;

endmodule
