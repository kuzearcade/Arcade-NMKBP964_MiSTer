// Macross Plus / Quiz Sailor Moon board: raster, video, main board and sound
// board, with every ROM as an external port so the reference simulation
// (arrays) and the hardware path (SDRAM + DDR3, macplus_rom_hw) serve the
// same core (docs/PLAN.md 2.1).
//
// Savestates (docs/PLAN.md 2.9, Appendix C): the engine (rtl/savestate/
// savestate.sv, VARLAT=1) parks both CPUs, stops the ES5506, and reads or
// writes the image a 16-bit word at a time; main, video and sound each answer
// the words they own (see each module for its part of the map) and the core
// answers the holes with 0. Everything the vblank edge starts (IRQ3, the
// sprite copy) is gated while the engine holds the machine, so a save taken
// and a load released at a vblank edge see the same machine. After a load the
// replay step rebuilds the sprite extent table from the restored old2.
// SS_WORDS = 0x24900.
module macplus_core #(
	parameter [7:0] CE_NUM = 8'd25,
	parameter [7:0] CE_DEN = 8'd48,
	parameter       SPR_STAGES = 2
) (
	input             clk,
	input             reset,
	input             quiz,          // quizmoon: 224 lines, sample banks 2/3
	input             pause,
	input             flip,          // OSD Flip (rot180, in the video block)
	input      [31:0] inputs,
	input      [15:0] dsw,
	// main RAM back door (hiscore, cheats; later savestate), longword address;
	// it owns the RAM while ram2_sel, which its users raise only with the CPU paused
	input             ram2_sel,
	input      [14:0] ram2_addr,
	input             ram2_we,
	input      [3:0]  ram2_be,
	input      [31:0] ram2_din,
	output     [31:0] ram2_dout,
	// program ROMs
	output            mrom_req,
	output     [19:0] mrom_addr,     // longword
	input             mrom_ack,
	input      [31:0] mrom_data,
	output            srom_req,
	output     [18:0] srom_addr,     // word
	input             srom_ack,
	input      [15:0] srom_data,
	// graphics row streams
	output     [3:0]  bg_req,
	output     [91:0] bg_addr,
	input      [3:0]  bg_ready,
	input      [3:0]  bg_valid,
	input     [127:0] bg_data,
	output            spr_req,
	output     [23:0] spr_addr,
	input             spr_ready,
	input             spr_valid,
	input     [127:0] spr_data,
	// ES5506 samples
	output            smp_req,
	output     [1:0]  smp_bank,
	output     [20:0] smp_word,
	input             smp_ack,
	input      [15:0] smp_data,
	// video
	output            ce_pix,
	output     [8:0]  hcount,
	output     [8:0]  vcount,
	output            hblank,
	output            vblank,
	output            hsync,
	output            vsync,
	output     [23:0] rgb,
	output     [23:0] rgb_fade,
	// audio
	output signed [15:0] snd_l,
	output signed [15:0] snd_r,
	// debug
	output     [31:0] dbg_irq3,
	output     [31:0] dbg_iack3,
	output     [31:0] dbg_idle,
	output     [31:0] dbg_work,
	output     [31:0] dbg_busy,
	input             trace_on,      // simulation only: log main-CPU bus cycles
	output     [31:0] dbg_es_writes,
	output     [31:0] dbg_es_irq,
	output     [31:0] dbg_latch_reads,
	output reg [31:0] dbg_latch_writes,
	output     [31:0] dbg_cpu_addr,
	output     [15:0] dbg_spr_max_cycles,
	output     [15:0] dbg_spr_overruns,
	output     [63:0] dbg_bg_overruns,
	// savestate engine
	input             ss_freeze,
	input             ss_resume,
	input             ss_active,
	input      [19:0] ss_addr,
	input             ss_rd,
	input             ss_wr,
	input      [15:0] ss_wdata,
	output     [15:0] ss_rdata,
	output            ss_ack,
	output            ss_frozen,
	output            ss_parked,
	input             ss_replay,
	output reg        ss_replay_done
);
	wire        ss_hold = ss_freeze | ss_active | ss_resume;
	wire        m_ack, s_ack, v_ack, m_owns, s_owns, v_owns, m_parked, s_parked, es_quiet, spr_copy_busy;
	wire [15:0] m_rdata, s_rdata, v_rdata;
	reg         h_ack;
	always @(posedge clk) h_ack <= ss_active && (ss_rd || ss_wr) && !(m_owns || s_owns || v_owns);
	assign ss_ack    = m_ack | s_ack | v_ack | h_ack;
	assign ss_rdata  = m_ack ? m_rdata : s_ack ? s_rdata : v_ack ? v_rdata : 16'h0000;
	assign ss_frozen = m_parked & s_parked & es_quiet & ~spr_copy_busy;
	assign ss_parked = m_parked | s_parked;
	// replay: rebuild the sprite extents from old2 and wait for it
	reg  [1:0]  rp_st;
	reg         spr_rebuild;
	always @(posedge clk) begin
		spr_rebuild <= 1'b0;
		if (reset || !ss_replay) begin rp_st <= 2'd0; ss_replay_done <= 1'b0; end
		else case (rp_st)
		2'd0: begin spr_rebuild <= 1'b1; rp_st <= 2'd1; end
		2'd1: if (spr_copy_busy) rp_st <= 2'd2;
		2'd2: if (!spr_copy_busy) begin ss_replay_done <= 1'b1; rp_st <= 2'd3; end
		default: ;
		endcase
	end
	wire vtick, vblank_start, frame_start;
	wire vblank_start_g = vblank_start & ~ss_hold;
	macplus_timing u_timing (
		.clk(clk), .reset(reset), .quiz(quiz), .hold(1'b0),
		.ce_pix(ce_pix), .hcount(hcount), .vcount(vcount), .hblank(hblank), .vblank(vblank),
		.hsync(hsync), .vsync(vsync), .vtick(vtick), .vblank_start(vblank_start), .frame_start(frame_start));

	wire        vid_sel, vid_we, vid_ack;
	wire [21:0] vid_addr;
	wire [3:0]  vid_be;
	wire [31:0] vid_din, vid_dout;
	wire [7:0]  fade;
	wire        snd_cmd_we, snd_pending;
	wire [15:0] snd_cmd;

	macplus_main #(.CE_NUM(CE_NUM), .CE_DEN(CE_DEN)) u_main (
		.clk(clk), .reset(reset), .pause(pause),
		.rom_req(mrom_req), .rom_addr(mrom_addr), .rom_ack(mrom_ack), .rom_data(mrom_data),
		.vid_sel(vid_sel), .vid_addr(vid_addr), .vid_we(vid_we), .vid_be(vid_be), .vid_din(vid_din),
		.vid_dout(vid_dout), .vid_ack(vid_ack), .fade(fade),
		.inputs(inputs), .dsw(dsw), .vblank_start(vblank_start_g),
		.snd_cmd_we(snd_cmd_we), .snd_cmd(snd_cmd), .snd_pending(snd_pending),
		.ram2_sel(ram2_sel), .ram2_addr(ram2_addr), .ram2_we(ram2_we), .ram2_be(ram2_be), .ram2_din(ram2_din), .ram2_dout(ram2_dout),
		.dbg_pc_addr(dbg_cpu_addr), .dbg_irq3(dbg_irq3), .dbg_iack3(dbg_iack3), .dbg_idle(dbg_idle), .dbg_cache_miss(), .dbg_work(dbg_work), .dbg_busy(dbg_busy), .trace_on(trace_on),
		.ss_park_req(ss_freeze), .ss_resume(ss_resume), .ss_active(ss_active), .ss_addr(ss_addr), .ss_rd(ss_rd), .ss_wr(ss_wr),
		.ss_wdata(ss_wdata), .ss_rdata(m_rdata), .ss_ack(m_ack), .ss_owns(m_owns), .ss_parked(m_parked));

	wire [11:0] dbg_pen;
	wire [7:0]  dbg_spr_hits;
	macplus_video #(.SPR_STAGES(SPR_STAGES)) u_video (
		.clk(clk), .reset(reset), .quiz(quiz), .flip(flip),
		.ce_pix(ce_pix), .hcount(hcount), .vcount(vcount), .vtick(vtick), .vblank_start(vblank_start_g),
		.cpu_sel(vid_sel), .cpu_addr(vid_addr), .cpu_we(vid_we), .cpu_be(vid_be), .cpu_din(vid_din),
		.cpu_dout(vid_dout), .cpu_ack(vid_ack), .fade(fade), .spr_rebuild(spr_rebuild), .spr_copy_busy(spr_copy_busy),
		.ss_active(ss_active), .ss_addr(ss_addr), .ss_rd(ss_rd), .ss_wr(ss_wr), .ss_wdata(ss_wdata),
		.ss_rdata(v_rdata), .ss_ack(v_ack), .ss_owns(v_owns),
		.bg_req(bg_req), .bg_addr(bg_addr), .bg_ready(bg_ready), .bg_valid(bg_valid), .bg_data(bg_data),
		.spr_req(spr_req), .spr_addr(spr_addr), .spr_ready(spr_ready), .spr_valid(spr_valid), .spr_data(spr_data),
		.rgb(rgb), .rgb_fade(rgb_fade), .dbg_pen(dbg_pen),
		.dbg_spr_max_cycles(dbg_spr_max_cycles), .dbg_spr_overruns(dbg_spr_overruns), .dbg_spr_max_hits(dbg_spr_hits),
		.dbg_bg_max_cycles(), .dbg_bg_overruns(dbg_bg_overruns), .dbg_bg_unknown());

	macplus_sound u_sound (
		.clk(clk), .reset(reset), .pause(pause),
		.rom_req(srom_req), .rom_addr(srom_addr), .rom_ack(srom_ack), .rom_data(srom_data),
		.cmd_we(snd_cmd_we), .cmd(snd_cmd), .pending(snd_pending),
		.smp_req(smp_req), .smp_bank(smp_bank), .smp_word(smp_word), .smp_ack(smp_ack), .smp_data(smp_data),
		.snd_l(snd_l), .snd_r(snd_r),
		.dbg_es_writes(dbg_es_writes), .dbg_es_irq(dbg_es_irq), .dbg_latch_reads(dbg_latch_reads),
		.ss_park_req(ss_freeze), .ss_resume(ss_resume), .ss_active(ss_active), .ss_addr(ss_addr), .ss_rd(ss_rd), .ss_wr(ss_wr),
		.ss_wdata(ss_wdata), .ss_rdata(s_rdata), .ss_ack(s_ack), .ss_owns(s_owns), .ss_parked(s_parked), .es_quiet(es_quiet));

	always @(posedge clk)
		if (reset) dbg_latch_writes <= 32'd0;
		else if (snd_cmd_we) dbg_latch_writes <= dbg_latch_writes + 32'd1;
endmodule
