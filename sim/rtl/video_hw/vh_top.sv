// M1 through the real memory front end (MP-20): the video block as in
// sim/rtl/video_state, its ROM rows served by macplus_rom_hw -- BG and
// sprite rows from a DDR3 model on clk_ddr, text rows from an SDRAM stub --
// so the clock crossings and the DDR3 latency are in the loop.
module vh_top (
	input             clk,            // 48 MHz
	input             clk_ddr,        // 96 MHz
	input             pwr_reset,
	input             reset,
	input             quiz,
	input             ioctl_download,
	output            rom_ready,
	input             cpu_sel, cpu_we,
	input      [21:0] cpu_addr,
	input      [3:0]  cpu_be,
	input      [31:0] cpu_din,
	output     [31:0] cpu_dout,
	output            cpu_ack,
	// DDR3 (clk_ddr)
	input             ddr_busy,
	output            ddr_rd, ddr_we,
	output     [28:0] ddr_addr,
	output     [7:0]  ddr_burstcnt, ddr_be,
	output     [63:0] ddr_din,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready,
	// SDRAM ports (toggle req / ack, as rtl/sdram.sv)
	output     [24:1] sd_addr0, sd_addr1, sd_addr3,
	output            sd_req0, sd_req1, sd_req3,
	input             sd_ack0, sd_ack1, sd_ack3,
	input      [31:0] sd_pair0, sd_pair1, sd_pair3,
	// picture
	output            ce_pix,
	output     [8:0]  hcount, vcount,
	output     [23:0] rgb,
	output     [15:0] dbg_spr_max_cycles, dbg_spr_overruns,
	output     [7:0]  dbg_spr_max_hits,
	output     [63:0] dbg_bg_max_cycles, dbg_bg_overruns, dbg_bg_unknown
);
	wire        vreset = reset | ~rom_ready;
	wire vtick, vblank_start, hb, vb, hs, vs, fs;
	macplus_timing u_t (.clk(clk), .reset(vreset), .quiz(quiz), .hold(1'b0), .ce_pix(ce_pix),
		.hcount(hcount), .vcount(vcount), .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs),
		.vtick(vtick), .vblank_start(vblank_start), .frame_start(fs));
	wire [3:0]  bg_req, bg_ready, bg_valid;
	wire [91:0] bg_addr;    wire [127:0] bg_data, spr_data;
	wire        spr_req, spr_ready, spr_valid;
	wire [23:0] spr_addr;
	wire [23:0] rgbf; wire [11:0] pen;
	macplus_video u_v (.clk(clk), .reset(vreset), .quiz(quiz), .flip(1'b0),
		.ce_pix(ce_pix), .hcount(hcount), .vcount(vcount), .vtick(vtick), .vblank_start(vblank_start),
		.cpu_sel(cpu_sel), .cpu_addr(cpu_addr), .cpu_we(cpu_we), .cpu_be(cpu_be), .cpu_din(cpu_din),
		.cpu_dout(cpu_dout), .cpu_ack(cpu_ack), .fade(8'hFF), .spr_rebuild(1'b0),
		.bg_req(bg_req), .bg_addr(bg_addr), .bg_ready(bg_ready), .bg_valid(bg_valid), .bg_data(bg_data),
		.spr_req(spr_req), .spr_addr(spr_addr), .spr_ready(spr_ready), .spr_valid(spr_valid), .spr_data(spr_data),
		.rgb(rgb), .rgb_fade(rgbf), .dbg_pen(pen),
		.dbg_spr_max_cycles(dbg_spr_max_cycles), .dbg_spr_overruns(dbg_spr_overruns), .dbg_spr_max_hits(dbg_spr_max_hits),
		.dbg_bg_max_cycles(dbg_bg_max_cycles), .dbg_bg_overruns(dbg_bg_overruns), .dbg_bg_unknown(dbg_bg_unknown));
	wire [15:0] sd_dout [0:3];
	assign sd_dout[0] = 16'd0; assign sd_dout[1] = 16'd0; assign sd_dout[2] = 16'd0; assign sd_dout[3] = 16'd0;
	wire [24:1] sd_addr2; wire sd_req2;
	wire        mrom_ack, srom_ack, smp_ack;
	wire [31:0] mrom_data; wire [15:0] srom_data, smp_data;
	macplus_rom_hw #(.COPY_BYTES(25'd64)) u_rom (
		.clk(clk), .clk_ddr(clk_ddr), .pwr_reset(pwr_reset), .reset(vreset), .quiz(quiz),
		.ioctl_download(ioctl_download), .ioctl_index(16'd0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(8'd0),
		.ioctl_wait(), .rom_ready(rom_ready),
		.mrom_req(1'b0), .mrom_addr(20'd0), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
		.srom_req(1'b0), .srom_addr(19'd0), .srom_ack(srom_ack), .srom_data(srom_data),
		.bg_req(bg_req), .bg_addr(bg_addr), .bg_ready(bg_ready), .bg_valid(bg_valid), .bg_data(bg_data),
		.spr_req(spr_req), .spr_addr(spr_addr), .spr_ready(spr_ready), .spr_valid(spr_valid), .spr_data(spr_data),
		.smp_req(1'b0), .smp_bank(2'd0), .smp_word(21'd0), .smp_ack(smp_ack), .smp_data(smp_data),
		.sdram_addr0(sd_addr0), .sdram_addr1(sd_addr1), .sdram_addr2(sd_addr2), .sdram_addr3(sd_addr3),
		.sdram_wrl0(), .sdram_wrl1(), .sdram_wrl2(), .sdram_wrl3(),
		.sdram_wrh0(), .sdram_wrh1(), .sdram_wrh2(), .sdram_wrh3(),
		.sdram_din0(), .sdram_din1(), .sdram_din2(), .sdram_din3(),
		.sdram_dout0(sd_dout[0]), .sdram_dout1(sd_dout[1]), .sdram_dout2(sd_dout[2]), .sdram_dout3(sd_dout[3]),
		.sdram_pair0(sd_pair0), .sdram_pair1(sd_pair1), .sdram_pair2(32'd0), .sdram_pair3(sd_pair3),
		.sdram_req0(sd_req0), .sdram_req1(sd_req1), .sdram_req2(sd_req2), .sdram_req3(sd_req3),
		.sdram_ack0(sd_ack0), .sdram_ack1(sd_ack1), .sdram_ack2(sd_req2), .sdram_ack3(sd_ack3),
		.ddr_yield(1'b0), .ddr_busy(ddr_busy), .ddr_rd(ddr_rd), .ddr_we(ddr_we), .ddr_addr(ddr_addr),
		.ddr_burstcnt(ddr_burstcnt), .ddr_din(ddr_din), .ddr_be(ddr_be), .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready),
		.ss_ddr_we(1'b0), .ss_ddr_rd(1'b0), .ss_ddr_addr(29'd0), .ss_ddr_din(64'd0), .ss_ddr_grant(), .ss_ddr_q(), .ss_ddr_ready(),
		.dbg_copy_words(), .dbg_dl_bytes());
endmodule
