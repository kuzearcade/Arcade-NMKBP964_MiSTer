// SPDX-License-Identifier: GPL-2.0-or-later
//
// The 68EC020 (TG68K.C) and its fast paths: main RAM and a program-ROM cache
// answer inside this module; everything else goes out on the board bus.
//
// Derived from Arcade-ITech32_MiSTer's itech32_tg68_cpu.sv and
// itech32_tg68_bus_adapter.sv (TheJesusFish, d461e21d): the same 16-bit TG68K
// cycle capture, byte-lane mapping and local IACK completion. What is new is
// the timing (MP-6): ITech32's adapter spends about eight fabric clocks on
// every 16-bit access, which made TG68K 2.4x slower than MAME's 68020 here.
//   RAM write            2 clocks  (capture, write + advance)
//   RAM read, cache hit  3 clocks  (capture, read, advance with the data)
//   other                capture, board request, board ack, advance
// The cache is direct-mapped, 256 lines of 16 bytes (4 KB), filled four
// longwords at a time from the program ROM port. The ROM is read-only, so it
// never needs invalidating after reset.
//
// TG68K.C advances one microstep per clkena; a memory microstep completes on
// the clkena that sees its data. cpu_ce paces the whole CPU (D3).
module macplus_cpu_bus (
	input             clk,
	input             reset,
	input             cpu_ce,
	input      [2:0]  irq_level,
	output reg        iack,          // one clock, with the acknowledged level
	output reg [2:0]  iack_level,
	// program ROM (longword reads, held request until ack)
	output reg        rom_req,
	output reg [19:0] rom_addr,
	input             rom_ack,
	input      [31:0] rom_data,
	// main RAM back door (hiscore, cheats, savestate): owns the RAM while
	// ram2_sel, which its users only raise with the CPU paused
	input             ram2_sel,
	input      [14:0] ram2_addr,
	input             ram2_we,
	input      [3:0]  ram2_be,
	input      [31:0] ram2_din,
	output reg [31:0] ram2_dout,
	// board bus: everything but ROM and main RAM
	output reg        board_req,
	output reg        board_we,
	output reg [23:0] board_addr,
	output reg [31:0] board_wdata,
	output reg [3:0]  board_be,
	input             board_ack,
	input      [31:0] board_rdata,
	// debug
	output     [31:0] dbg_addr,
	output reg [31:0] dbg_idle_writes,
	output reg [31:0] dbg_cache_miss
);
	// ================================================================ TG68K
	wire        tg_clkena;
	reg  [15:0] tg_rdata;
	wire [15:0] tg_rdata_mux;      // live data in the one-clock paths, tg_rdata otherwise
	wire [31:0] tg_addr;
	wire [15:0] tg_wdata;
	wire        tg_nwr, tg_nuds, tg_nlds;
	wire [1:0]  tg_busstate;
	wire [2:0]  tg_fc;
	reg  [1:0]  rst_pipe;
	wire        lreset = rst_pipe[1];
	always @(posedge clk or posedge reset)
		if (reset) rst_pipe <= 2'b11; else rst_pipe <= {rst_pipe[0], 1'b0};
	reg  [2:0]  ipl_q;
	always @(posedge clk) ipl_q <= lreset ? 3'd0 : irq_level;
`ifdef VERILATOR
	TG68KdotC_Kernel tg68k (
`else
	TG68KdotC_Kernel #(.MUL_Hardware(0)) tg68k (
`endif
		.clk(clk), .nReset(~lreset), .clkena_in(tg_clkena), .data_in(tg_rdata_mux),
		.IPL(~ipl_q), .IPL_autovector(1'b1), .berr(1'b0), .CPU(2'b11),
		.addr_out(tg_addr), .data_write(tg_wdata), .nWr(tg_nwr), .nUDS(tg_nuds), .nLDS(tg_nlds),
		.busstate(tg_busstate), .longword(), .nResetOut(), .FC(tg_fc), .clr_berr(),
		.skipFetch(), .regin_out(), .CACR_out(), .VBR_out());
	assign dbg_addr = tg_addr;

	// ================================================================ capture
	wire        active  = tg_busstate != 2'b01;
	wire        strobed = active && (!tg_nuds || !tg_nlds);
	reg  [31:0] c_addr;
	reg  [15:0] c_wdata;
	reg         c_we, c_nuds, c_nlds;
	reg  [2:0]  c_fc;
	wire [3:0]  c_be = c_addr[1] ? {2'b00, ~c_nuds, ~c_nlds} : {~c_nuds, ~c_nlds, 2'b00};
	wire [31:0] c_wd32 = c_addr[1] ? {16'h0000, c_wdata} : {c_wdata, 16'h0000};
	wire        c_iack = !c_we && c_fc == 3'b111 && c_addr[31:4] == 28'hFFF_FFFF;
	wire        c_rom  = c_addr[23:22] == 2'b00;
	wire        c_ram  = c_addr[23:17] == 7'b1111_000;   // F00000-F1FFFF

	// ================================================================ main RAM
	// ONE write port and ONE read port, each an address mux (MS1Z's work RAM):
	// the back door (hiscore, cheats; later savestate) only drives it while it
	// holds the CPU paused, so it never needs a port of its own. Two write
	// ports in two always blocks did not infer ("unsupported read-during-write
	// behavior", quartus_map 2026-09-24) and cost a megabit of registers.
	reg  [7:0]  r0 [0:32767], r1 [0:32767], r2 [0:32767], r3 [0:32767];
	wire [14:0] ra = c_addr[16:2];
	reg         ram_we;
	reg  [31:0] ram_q;
	wire [14:0] m_a  = ram2_sel ? ram2_addr : ra;
	wire        m_we = ram2_sel ? ram2_we   : ram_we;
	wire [3:0]  m_be = ram2_sel ? ram2_be   : c_be;
	wire [31:0] m_wd = ram2_sel ? ram2_din  : c_wd32;
	always @(posedge clk) begin
		if (m_we & m_be[0]) r0[m_a] <= m_wd[7:0];
		if (m_we & m_be[1]) r1[m_a] <= m_wd[15:8];
		if (m_we & m_be[2]) r2[m_a] <= m_wd[23:16];
		if (m_we & m_be[3]) r3[m_a] <= m_wd[31:24];
		ram_q <= {r3[m_a], r2[m_a], r1[m_a], r0[m_a]};
	end
	always @(*) ram2_dout = ram_q;

	// ================================================================ ROM cache
	// line = c_addr[11:4], tag = c_addr[21:12], word in line = c_addr[3:2]
	reg  [127:0] cdat [0:255];
	reg  [9:0]   ctag [0:255];
	reg  [255:0] cval;
	reg  [127:0] cdat_q;
	reg  [9:0]   ctag_q;
	reg  [7:0]   cw_line;
	reg  [127:0] cw_data;
	reg          cw_we;
	always @(posedge clk) begin
		if (cw_we) begin cdat[cw_line] <= cw_data; ctag[cw_line] <= fill_tag; end
		cdat_q <= cdat[c_addr[11:4]];
		ctag_q <= ctag[c_addr[11:4]];
	end
	reg  [9:0]   fill_tag;
	wire         hit = cval[c_addr[11:4]] && ctag_q == c_addr[21:12];
	wire [31:0]  hit_long = cdat_q[{c_addr[3:2], 5'b00000} +: 32];

	// ================================================================ cycle FSM
	localparam S_IDLE = 3'd0, S_CAP = 3'd1, S_RAMQ = 3'd2, S_CHK = 3'd3, S_FILL = 3'd4,
	           S_BOARD = 3'd5, S_RESP = 3'd6;
	reg  [2:0]  st;
	reg  [1:0]  fk;             // fill word
	reg  [127:0] fline;
	// data for TG68: a live mux in the one-clock paths, a register otherwise
	reg         live;
	reg  [15:0] live_data;
	assign tg_rdata_mux = live ? live_data : tg_rdata;
	wire [31:0] half_src = (st == S_RAMQ) ? ram_q : hit_long;
	always @(*) begin
		live = 1'b0; live_data = 16'h0000;
		if (st == S_RAMQ || (st == S_CHK && hit)) begin
			live = 1'b1; live_data = c_addr[1] ? half_src[15:0] : half_src[31:16];
		end
	end
	// advance: a non-memory microstep in IDLE, the live paths, a RAM write, or a response
	wire adv_live = (st == S_RAMQ) || (st == S_CHK && hit) || (st == S_CAP && c_we && c_ram);
	assign tg_clkena = !lreset && cpu_ce &&
	                   ((st == S_IDLE && !active) || adv_live || st == S_RESP);

	always @(posedge clk) begin
		iack <= 1'b0; cw_we <= 1'b0; ram_we <= 1'b0;
		if (lreset) begin
			st <= S_IDLE; board_req <= 1'b0; rom_req <= 1'b0; cval <= 256'd0;
			tg_rdata <= 16'hFFFF; dbg_idle_writes <= 32'd0; dbg_cache_miss <= 32'd0;
		end else begin
			case (st)
			S_IDLE: if (strobed) begin
				c_addr <= tg_addr; c_wdata <= tg_wdata; c_we <= !tg_nwr && tg_busstate == 2'b11;
				c_nuds <= tg_nuds; c_nlds <= tg_nlds; c_fc <= tg_fc;
				st <= S_CAP;
			end
			S_CAP: begin
				// the RAM and the cache sample c_addr this clock
				if (c_iack) begin
					iack <= 1'b1; iack_level <= c_addr[3:1]; tg_rdata <= 16'hFFFF; st <= S_RESP;
				end else if (c_ram) begin
					if (c_we) begin
						ram_we <= 1'b1;
						// the idle loop's counter: the word at F1015A, low half of longword F10158
						if (c_addr[23:2] == 22'h3C4056 && c_be[1:0] != 2'b00) dbg_idle_writes <= dbg_idle_writes + 32'd1;
						if (cpu_ce) st <= S_IDLE; else st <= S_RESP;   // advanced this clock if cpu_ce
					end else st <= S_RAMQ;
				end else if (c_rom && !c_we) st <= S_CHK;
				else if (c_rom) st <= S_RESP;                      // ROM writes are dropped
				else begin
					board_req <= 1'b1; board_we <= c_we; board_be <= c_be; board_wdata <= c_wd32;
					board_addr <= (c_nuds && !c_nlds) ? {c_addr[23:1], 1'b1} : {c_addr[23:1], 1'b0};
					st <= S_BOARD;
				end
			end
			S_RAMQ: begin
				if (cpu_ce) st <= S_IDLE;
				else begin tg_rdata <= live_data; st <= S_RESP; end
			end
			S_CHK: begin
				if (hit) begin
					if (cpu_ce) st <= S_IDLE; else begin tg_rdata <= live_data; st <= S_RESP; end
				end else begin
					dbg_cache_miss <= dbg_cache_miss + 32'd1;
					fk <= 2'd0; rom_req <= 1'b1; rom_addr <= {c_addr[21:4], 2'b00};
					fill_tag <= c_addr[21:12]; st <= S_FILL;
				end
			end
			S_FILL: if (rom_ack) begin
				fline[{fk, 5'b00000} +: 32] <= rom_data;
				if (fk == 2'd3) begin
					rom_req <= 1'b0;
					cw_we <= 1'b1; cw_line <= c_addr[11:4];
					cw_data <= {rom_data, fline[95:0]};
					cval[c_addr[11:4]] <= 1'b1;
					// answer from the line just filled (the cache write lands a clock later)
					begin : ans
						reg [127:0] ln; reg [31:0] lw;
						ln = {rom_data, fline[95:0]};
						lw = ln[{c_addr[3:2], 5'b00000} +: 32];
						tg_rdata <= c_addr[1] ? lw[15:0] : lw[31:16];
					end
					st <= S_RESP;
				end else begin
					fk <= fk + 2'd1; rom_addr <= rom_addr + 20'd1;
					rom_req <= 1'b0;       // a new request per longword (held-request protocol)
					st <= S_FILL2;
				end
			end
			S_FILL2: begin rom_req <= 1'b1; st <= S_FILL; end
			S_BOARD: if (board_ack) begin
				board_req <= 1'b0;
				if (!board_we) tg_rdata <= board_addr[1] ? board_rdata[15:0] : board_rdata[31:16];
				st <= S_RESP;
			end
			S_RESP: if (cpu_ce) st <= S_IDLE;
			default: st <= S_IDLE;
			endcase
		end
	end
	localparam S_FILL2 = 3'd7;
endmodule
