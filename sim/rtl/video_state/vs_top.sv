// M1 harness top: the raster and the whole video block, driven from C++.
module vs_top (
	input             clk,
	input             reset,
	input             quiz,
	input             cpu_sel, cpu_we,
	input      [21:0] cpu_addr,
	input      [3:0]  cpu_be,
	input      [31:0] cpu_din,
	output     [31:0] cpu_dout,
	output            cpu_ack,
	output     [3:0]  bg_req,
	output     [91:0] bg_addr,
	input      [3:0]  bg_ready, bg_valid,
	input     [127:0] bg_data,
	output            spr_req,
	output     [23:0] spr_addr,
	input             spr_ready, spr_valid,
	input     [127:0] spr_data,
	output            ce_pix,
	output     [8:0]  hcount, vcount,
	output     [23:0] rgb,
	output     [15:0] dbg_spr_max_cycles, dbg_spr_overruns,
	output     [7:0]  dbg_spr_max_hits,
	output     [63:0] dbg_bg_max_cycles, dbg_bg_overruns, dbg_bg_unknown
);
	wire vtick, vblank_start, hb, vb, hs, vs, fs;
	macplus_timing u_t (.clk(clk), .reset(reset), .quiz(quiz), .hold(1'b0), .ce_pix(ce_pix),
		.hcount(hcount), .vcount(vcount), .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs),
		.vtick(vtick), .vblank_start(vblank_start), .frame_start(fs));
	wire [23:0] rgbf; wire [11:0] pen;
	macplus_video u_v (.clk(clk), .reset(reset), .quiz(quiz), .flip(1'b0),
		.ce_pix(ce_pix), .hcount(hcount), .vcount(vcount), .vtick(vtick), .vblank_start(vblank_start),
		.cpu_sel(cpu_sel), .cpu_addr(cpu_addr), .cpu_we(cpu_we), .cpu_be(cpu_be), .cpu_din(cpu_din),
		.cpu_dout(cpu_dout), .cpu_ack(cpu_ack), .fade(8'hFF), .spr_rebuild(1'b0),
		.bg_req(bg_req), .bg_addr(bg_addr), .bg_ready(bg_ready), .bg_valid(bg_valid), .bg_data(bg_data),
		.spr_req(spr_req), .spr_addr(spr_addr), .spr_ready(spr_ready), .spr_valid(spr_valid), .spr_data(spr_data),
		.rgb(rgb), .rgb_fade(rgbf), .dbg_pen(pen),
		.dbg_spr_max_cycles(dbg_spr_max_cycles), .dbg_spr_overruns(dbg_spr_overruns), .dbg_spr_max_hits(dbg_spr_max_hits),
		.dbg_bg_max_cycles(dbg_bg_max_cycles), .dbg_bg_overruns(dbg_bg_overruns), .dbg_bg_unknown(dbg_bg_unknown));
endmodule
