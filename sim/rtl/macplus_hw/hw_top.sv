// M3: the core on its real memory path -- macplus_rom_hw, rtl/sdram.sv against
// sim/models/sdram_model.sv, and a DDR3 port served by the C++ testbench
// (latency, BUSY and bursts, image preloaded as Main_MiSTer's address= load).
module hw_top #(
	// COPY_BYTES < 0x1600000 (the "fast" build): the testbench preloads the SDRAM
	// model with the image instead; the full copy is checked word for word in
	// the normal build (MP-9 notes).
	parameter [24:0] COPY_BYTES = 25'h1600000
) (
	input             clk_sys,
	input             clk_ram,
	input             pwr_reset,
	input             reset,
	input             quiz,
	input             ioctl_download,
	input      [31:0] inputs,
	input      [15:0] dsw,
	// DDR3 (clk_ram)
	input             ddr_busy,
	output            ddr_rd, ddr_we,
	output     [28:0] ddr_addr,
	output     [7:0]  ddr_burstcnt, ddr_be,
	output     [63:0] ddr_din,
	input      [63:0] ddr_dout,
	input             ddr_dout_ready,
	// video / audio / status
	output            ce_pix,
	output     [8:0]  hcount, vcount,
	output     [23:0] rgb,
	output signed [15:0] snd_l, snd_r,
	output            rom_ready,
	output            sdram_ready,
	output     [31:0] dbg_copy_words, dbg_irq3, dbg_idle, dbg_es_writes, dbg_latch_writes, dbg_cpu_addr,
	output     [15:0] dbg_spr_overruns,
	output     [63:0] dbg_bg_overruns,
	// the ROM streams, for the testbench's response check
	output            t_spr_req, t_spr_ready, t_spr_valid,
	output     [23:0] t_spr_addr,
	output    [127:0] t_spr_data, t_bg_data,
	output     [3:0]  t_bg_req, t_bg_ready, t_bg_valid,
	output     [91:0] t_bg_addr
);
	assign t_spr_req = spr_req; assign t_spr_ready = spr_ready; assign t_spr_valid = spr_valid;
	assign t_spr_addr = spr_addr; assign t_spr_data = spr_data; assign t_bg_data = bg_data;
	assign t_bg_req = bg_req; assign t_bg_ready = bg_ready; assign t_bg_valid = bg_valid; assign t_bg_addr = bg_addr;
	wire [15:0] SDRAM_DQ; wire [12:0] SDRAM_A; wire [1:0] SDRAM_BA;
	wire SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;
	sdram_model u_model (.SDRAM_CLK(SDRAM_CLK), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
		.SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS),
		.SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE));
	wire [24:1] sd0_addr, sd1_addr, sd2_addr, sd3_addr;
	wire        sd0_wrl, sd0_wrh, sd1_wrl, sd1_wrh, sd2_wrl, sd2_wrh, sd3_wrl, sd3_wrh;
	wire [15:0] sd0_din, sd1_din, sd2_din, sd3_din, sd0_dout, sd1_dout, sd2_dout, sd3_dout;
	wire [31:0] sd0_pair, sd1_pair, sd2_pair, sd3_pair;
	wire        sd0_req, sd1_req, sd2_req, sd3_req, sd0_ack, sd1_ack, sd2_ack, sd3_ack;
	sdram #(.REFRESH_CYCLES(10'd740)) u_sdram (
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .ready(sdram_ready),
		.init(pwr_reset), .clk(clk_ram), .prio_mode(2'd0),
		.addr0(sd0_addr), .wrl0(sd0_wrl), .wrh0(sd0_wrh), .din0(sd0_din), .dout0(sd0_dout), .dout0_pair(sd0_pair), .req0(sd0_req), .ack0(sd0_ack),
		.addr1(sd1_addr), .wrl1(sd1_wrl), .wrh1(sd1_wrh), .din1(sd1_din), .dout1(sd1_dout), .dout1_pair(sd1_pair), .req1(sd1_req), .ack1(sd1_ack),
		.addr2(sd2_addr), .wrl2(sd2_wrl), .wrh2(sd2_wrh), .din2(sd2_din), .dout2(sd2_dout), .dout2_pair(sd2_pair), .req2(sd2_req), .ack2(sd2_ack),
		.addr3(sd3_addr), .wrl3(sd3_wrl), .wrh3(sd3_wrh), .din3(sd3_din), .dout3(sd3_dout), .dout3_pair(sd3_pair), .req3(sd3_req), .ack3(sd3_ack));

	wire        mrom_req, mrom_ack, srom_req, srom_ack, spr_req, spr_ready, spr_valid, smp_req, smp_ack;
	wire [19:0] mrom_addr;  wire [31:0] mrom_data;
	wire [18:0] srom_addr;  wire [15:0] srom_data;
	wire [3:0]  bg_req, bg_ready, bg_valid;
	wire [91:0] bg_addr;    wire [127:0] bg_data, spr_data;
	wire [23:0] spr_addr;
	wire [1:0]  smp_bank;   wire [20:0] smp_word;  wire [15:0] smp_data;
	macplus_rom_hw #(.COPY_BYTES(COPY_BYTES)) u_rom (
		.clk(clk_sys), .clk_ddr(clk_ram), .pwr_reset(pwr_reset), .reset(reset), .quiz(quiz),
		.ioctl_download(ioctl_download), .ioctl_index(16'd0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(8'd0),
		.ioctl_wait(), .rom_ready(rom_ready),
		.mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
		.srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_data(srom_data),
		.bg_req(bg_req), .bg_addr(bg_addr), .bg_ready(bg_ready), .bg_valid(bg_valid), .bg_data(bg_data),
		.spr_req(spr_req), .spr_addr(spr_addr), .spr_ready(spr_ready), .spr_valid(spr_valid), .spr_data(spr_data),
		.smp_req(smp_req), .smp_bank(smp_bank), .smp_word(smp_word), .smp_ack(smp_ack), .smp_data(smp_data),
		.sdram_addr0(sd0_addr), .sdram_addr1(sd1_addr), .sdram_addr2(sd2_addr), .sdram_addr3(sd3_addr),
		.sdram_wrl0(sd0_wrl), .sdram_wrl1(sd1_wrl), .sdram_wrl2(sd2_wrl), .sdram_wrl3(sd3_wrl),
		.sdram_wrh0(sd0_wrh), .sdram_wrh1(sd1_wrh), .sdram_wrh2(sd2_wrh), .sdram_wrh3(sd3_wrh),
		.sdram_din0(sd0_din), .sdram_din1(sd1_din), .sdram_din2(sd2_din), .sdram_din3(sd3_din),
		.sdram_dout0(sd0_dout), .sdram_dout1(sd1_dout), .sdram_dout2(sd2_dout), .sdram_dout3(sd3_dout),
		.sdram_pair0(sd0_pair), .sdram_pair1(sd1_pair), .sdram_pair2(sd2_pair), .sdram_pair3(sd3_pair),
		.sdram_req0(sd0_req), .sdram_req1(sd1_req), .sdram_req2(sd2_req), .sdram_req3(sd3_req),
		.sdram_ack0(sd0_ack), .sdram_ack1(sd1_ack), .sdram_ack2(sd2_ack), .sdram_ack3(sd3_ack),
		.ddr_yield(1'b0), .ddr_busy(ddr_busy), .ddr_rd(ddr_rd), .ddr_we(ddr_we), .ddr_addr(ddr_addr),
		.ddr_burstcnt(ddr_burstcnt), .ddr_din(ddr_din), .ddr_be(ddr_be), .ddr_dout(ddr_dout), .ddr_dout_ready(ddr_dout_ready),
		.dbg_copy_words(dbg_copy_words), .dbg_dl_bytes());

	wire hb, vb, hs, vs; wire [23:0] rgbf; wire [31:0] r2q;
	macplus_core #(.CE_NUM(8'd29)) u_core (
		.clk(clk_sys), .reset(reset | ~rom_ready | ~sdram_ready), .quiz(quiz), .pause(1'b0), .flip(1'b0), .trace_on(1'b0),
		.inputs(inputs), .dsw(dsw),
		.ram2_sel(1'b0), .ram2_addr(15'd0), .ram2_we(1'b0), .ram2_be(4'd0), .ram2_din(32'd0), .ram2_dout(r2q),
		.mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
		.srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_data(srom_data),
		.bg_req(bg_req), .bg_addr(bg_addr), .bg_ready(bg_ready), .bg_valid(bg_valid), .bg_data(bg_data),
		.spr_req(spr_req), .spr_addr(spr_addr), .spr_ready(spr_ready), .spr_valid(spr_valid), .spr_data(spr_data),
		.smp_req(smp_req), .smp_bank(smp_bank), .smp_word(smp_word), .smp_ack(smp_ack), .smp_data(smp_data),
		.ce_pix(ce_pix), .hcount(hcount), .vcount(vcount), .hblank(hb), .vblank(vb), .hsync(hs), .vsync(vs),
		.rgb(rgb), .rgb_fade(rgbf), .snd_l(snd_l), .snd_r(snd_r),
		.dbg_irq3(dbg_irq3), .dbg_iack3(), .dbg_idle(dbg_idle), .dbg_es_writes(dbg_es_writes), .dbg_es_irq(),
		.dbg_latch_reads(), .dbg_latch_writes(dbg_latch_writes), .dbg_cpu_addr(dbg_cpu_addr),
		.dbg_spr_max_cycles(), .dbg_spr_overruns(dbg_spr_overruns), .dbg_bg_overruns(dbg_bg_overruns));
endmodule
