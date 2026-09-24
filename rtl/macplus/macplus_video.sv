// Macross Plus video: tile layers, text, sprites, palette and mixer, with the
// CPU's view of their RAMs (docs/PLAN.md 1.2, 1.5, 2.6).
//
// CPU map (longword addresses; cpu_addr is the byte address >> 2):
//   800000-802FFF  sprite RAM (macplus_sprites)
//   900000 + L*8000, L = 0..3 (SCR A, B, C, text):
//     +0000-3FFF   VRAM, 4,096 longwords        (64x64 map)
//     +4200-43FF   line zoom, 128 longwords     (one halfword per line)
//     +5000-500B   registers vr0..vr2
//   A00000-A03FFF  palette, 4,096 longwords, RGBx_888 (R=[31:24] G=[23:16] B=[15:8])
// Reads of holes inside the window return 0 (Q13 is open).
//
// Composition per pixel (MP-1 proved it against MAME's pictures):
//   layer colour = text if opaque, else the first opaque SCR layer in
//                  (priority descending, index ascending) order, else black
//   layer bits   = OR of (1 << pri) over opaque SCR layers, | 8 if text opaque
//   the sprite   = the frontmost sprite pixel (the line buffer); shown unless a
//                  layer bit b >= its priority is set
//   out          = shown ? (alpha ? (layer + sprite) >> 1 : sprite) : layer
// The palette has one read port shared by the layer pen, the sprite pen and the
// CPU, which a 7.9 MHz pixel at 48 MHz leaves room for. `rgb` is the picture
// MAME's screen:pixels() returns (no brightness); `rgb_fade` has the fade
// register applied (Q10 fixes its exact curve).
module macplus_video #(
	parameter SPR_STAGES = 2
) (
	input             clk,
	input             reset,
	input             quiz,
	input             flip,          // OSD Flip: rot180 of the finished frame (NMK-21, MS1-13)
	// raster
	input             ce_pix,
	input      [8:0]  hcount,
	input      [8:0]  vcount,
	input             vtick,
	input             vblank_start,
	// CPU
	input             cpu_sel,       // address in 800000-A03FFF
	input      [21:0] cpu_addr,      // byte address >> 2
	input             cpu_we,
	input      [3:0]  cpu_be,
	input      [31:0] cpu_din,
	output reg [31:0] cpu_dout,
	output reg        cpu_ack,       // one clock; reads have variable latency
	input      [7:0]  fade,          // B00012 high byte (0xFF: never written)
	input             spr_rebuild,
	output            spr_copy_busy,
	// savestate: the sprite stages (macplus_sprites); everything else here is
	// reached through the CPU port
	input             ss_active,
	input      [19:0] ss_addr,
	input             ss_rd,
	input             ss_wr,
	input      [15:0] ss_wdata,
	output     [15:0] ss_rdata,
	output            ss_ack,
	output            ss_owns,
	// ROM streams
	output     [3:0]  bg_req,
	output     [91:0] bg_addr,       // 4 x 23-bit byte addresses (text in the fourth)
	input      [3:0]  bg_ready,
	input      [3:0]  bg_valid,
	input     [127:0] bg_data,       // shared: the arbiter returns one response a clock
	output            spr_req,
	output     [23:0] spr_addr,
	input             spr_ready,
	input             spr_valid,
	input     [127:0] spr_data,
	// video out, one pixel behind hcount (aligned by the caller)
	output reg [23:0] rgb,
	output reg [23:0] rgb_fade,
	output reg [11:0] dbg_pen,
	// debug
	output     [15:0] dbg_spr_max_cycles,
	output     [15:0] dbg_spr_overruns,
	output     [7:0]  dbg_spr_max_hits,
	output     [63:0] dbg_bg_max_cycles,
	output     [63:0] dbg_bg_overruns,
	output     [63:0] dbg_bg_unknown
);
	// ================================================================ CPU decode
	// cpu_addr is the byte address >> 2
	wire in_spr = cpu_addr[21:12] == 10'h200 && cpu_addr[11:0] < 12'hC00;   // 800000-802FFF
	wire in_scr = cpu_addr[21:15] == 7'h48;                                 // 900000-91FFFF
	wire in_pal = cpu_addr[21:12] == 10'h280;                               // A00000-A03FFF
	// a layer window is 0x8000 bytes = 0x2000 longwords: VRAM 0x0000-0x0FFF,
	// line zoom 0x1080-0x10FF, registers 0x1400-0x1402
	wire [1:0]  layer = cpu_addr[14:13];
	wire [12:0] lw = cpu_addr[12:0];
	wire v_vram = in_scr && lw < 13'h1000;
	wire v_lz   = in_scr && lw >= 13'h1080 && lw < 13'h1100;
	wire v_reg  = in_scr && lw >= 13'h1400 && lw < 13'h1403;

	// ================================================================ VRAM x4, line zoom x4, registers
	// each VRAM: four byte-lane arrays; port A CPU, port B the layer engine
	wire [11:0] eng_vaddr [0:3];
	wire [6:0]  eng_lzaddr [0:3];
	reg  [31:0] vram_q [0:3], vram_cq [0:3];
	reg  [31:0] lz_q [0:3], lz_cq [0:3];
	reg  [31:0] vr [0:3][0:2];
	genvar g;
	generate for (g = 0; g < 4; g = g + 1) begin : lay
		reg [7:0] v0 [0:4095], v1 [0:4095], v2 [0:4095], v3 [0:4095];
		wire wv = cpu_sel && cpu_we && v_vram && layer == g;
		wire wz = cpu_sel && cpu_we && v_lz   && layer == g;
		// Quartus's true-dual-port template, one array per byte lane: port A is
		// the CPU (write and read at one address, one always block), port B the
		// layer engine's read in a block of its own. Written as one block with
		// both reads, each lane was built twice (quartus_map, 2026-09-24; NMK-10).
		always @(posedge clk) begin if (wv & cpu_be[0]) v0[lw[11:0]] <= cpu_din[7:0];   vcq0 <= v0[lw[11:0]]; end
		always @(posedge clk) begin if (wv & cpu_be[1]) v1[lw[11:0]] <= cpu_din[15:8];  vcq1 <= v1[lw[11:0]]; end
		always @(posedge clk) begin if (wv & cpu_be[2]) v2[lw[11:0]] <= cpu_din[23:16]; vcq2 <= v2[lw[11:0]]; end
		always @(posedge clk) begin if (wv & cpu_be[3]) v3[lw[11:0]] <= cpu_din[31:24]; vcq3 <= v3[lw[11:0]]; end
		always @(posedge clk) vq0 <= v0[eng_vaddr[g]];
		always @(posedge clk) vq1 <= v1[eng_vaddr[g]];
		always @(posedge clk) vq2 <= v2[eng_vaddr[g]];
		always @(posedge clk) vq3 <= v3[eng_vaddr[g]];
		reg [7:0] vcq0, vcq1, vcq2, vcq3, vq0, vq1, vq2, vq3;
		always @(*) begin vram_cq[g] = {vcq3, vcq2, vcq1, vcq0}; vram_q[g] = {vq3, vq2, vq1, vq0}; end
		// line zoom: 128 x 32 per layer, too small for an M10K each; MLAB
		(* ramstyle = "MLAB" *) reg [31:0] zm [0:127];
		always @(posedge clk) begin
			if (wz) zm[lw[6:0]] <= {cpu_be[3] ? cpu_din[31:24] : zm[lw[6:0]][31:24], cpu_be[2] ? cpu_din[23:16] : zm[lw[6:0]][23:16],
			                        cpu_be[1] ? cpu_din[15:8]  : zm[lw[6:0]][15:8],  cpu_be[0] ? cpu_din[7:0]   : zm[lw[6:0]][7:0]};
			lz_cq[g] <= zm[lw[6:0]];
			lz_q[g]  <= zm[eng_lzaddr[g]];
		end
		integer r;
		always @(posedge clk) begin
			if (reset) for (r = 0; r < 3; r = r + 1) vr[g][r] <= 32'd0;
			else if (cpu_sel && cpu_we && v_reg && layer == g) begin
				if (cpu_be[0]) vr[g][lw[1:0]][7:0]   <= cpu_din[7:0];
				if (cpu_be[1]) vr[g][lw[1:0]][15:8]  <= cpu_din[15:8];
				if (cpu_be[2]) vr[g][lw[1:0]][23:16] <= cpu_din[23:16];
				if (cpu_be[3]) vr[g][lw[1:0]][31:24] <= cpu_din[31:24];
			end
		end
	end endgenerate

	// ================================================================ line control
	wire [8:0] vvis  = quiz ? 9'd224 : 9'd240;
	// vtick is the last clock of a line, before vcount advances: vcount + 1 is
	// the line about to be displayed, so the engines draw vcount + 2 (MS1Z's
	// sprline lesson; measured here as a latency-dependent tear before the fix).
	wire [8:0] vnext = (vcount == 9'd254) ? 9'd0 : (vcount == 9'd255) ? 9'd1 : vcount + 9'd2;
	wire       lstart = vtick && vnext < vvis;
	// Flip: the engines draw the mirrored source line into the target line's
	// buffer half, and the display reads each buffer mirrored. Whole lines are
	// drawn ahead of the beam, so there is no per-pixel prefetch whose
	// direction a mirror could reverse (NMK-21b).
	wire [8:0] vsrc   = flip ? (vvis - 9'd1 - vnext) : vnext;
	wire [7:0] tline  = vsrc[7:0];

	// ================================================================ layers
	wire [12:0] l_q [0:3];
	wire [1:0]  l_pri [0:3];
	wire [3:0]  l_busy;
	wire [8:0]  rd_x = (flip && hcount < 9'd384) ? (9'd383 - hcount) : hcount;
	wire [8:0]  vdisp = flip ? (vvis - 9'd1 - vcount) : vcount;
	wire        rd_half = vdisp[0];     // the half the source line was drawn into
	wire [14:0] bg_mask [0:2];
	assign bg_mask[0] = 15'h7FFF;
	assign bg_mask[1] = quiz ? 15'h3FFF : 15'h7FFF;
	assign bg_mask[2] = quiz ? 15'h1FFF : 15'h7FFF;
	generate for (g = 0; g < 4; g = g + 1) begin : eng
		macplus_bgline #(.TEXT(g == 3)) u (
			.clk(clk), .reset(reset),
			.start(lstart), .line(tline), .busy(l_busy[g]),
			.vr0(vr[g][0]), .vr2(vr[g][2]),
			.code_mask(g == 3 ? 15'h7FFF : bg_mask[g]),
			.code_limit(g == 3 ? (quiz ? 16'd0 : 16'd4096) : 16'hFFFF),
			.lz_addr(eng_lzaddr[g]), .lz_q(lz_q[g]),
			.vram_addr(eng_vaddr[g]), .vram_q(vram_q[g]),
			.rom_req(bg_req[g]), .rom_addr(bg_addr[g*23 +: 23]),
			.rom_ready(bg_ready[g]), .rom_valid(bg_valid[g]), .rom_data(bg_data),
			.rd_x(rd_x), .rd_half(rd_half), .rd_q(l_q[g]), .pri_out(l_pri[g]),
			.dbg_unknown(dbg_bg_unknown[g*16 +: 16]),
			.dbg_max_cycles(dbg_bg_max_cycles[g*16 +: 16]),
			.dbg_overruns(dbg_bg_overruns[g*16 +: 16]));
	end endgenerate

	// ================================================================ sprites
	wire [15:0] s_q;
	wire        s_busy, s_copy_busy;
	wire [31:0] spr_cpu_q;
	macplus_sprites #(.STAGES(SPR_STAGES)) u_spr (
		.clk(clk), .reset(reset),
		.cpu_addr(cpu_addr[11:0]), .cpu_we(cpu_sel && cpu_we && in_spr), .cpu_be(cpu_be),
		.cpu_din(cpu_din), .cpu_dout(spr_cpu_q),
		.copy(vblank_start), .rebuild(spr_rebuild), .copy_busy(s_copy_busy),
		.start(lstart), .line(tline), .busy(s_busy),
		.rom_req(spr_req), .rom_addr(spr_addr), .rom_ready(spr_ready), .rom_valid(spr_valid), .rom_data(spr_data),
		.rd_x(rd_x), .rd_half(rd_half), .rd_q(s_q),
		.dbg_max_cycles(dbg_spr_max_cycles), .dbg_overruns(dbg_spr_overruns), .dbg_max_hits(dbg_spr_max_hits),
		.ss_active(ss_active), .ss_addr(ss_addr), .ss_rd(ss_rd), .ss_wr(ss_wr), .ss_wdata(ss_wdata),
		.ss_rdata(ss_rdata), .ss_ack(ss_ack), .ss_owns(ss_owns));
	assign spr_copy_busy = s_copy_busy;

	// ================================================================ palette (one read port, three users)
	reg  [7:0]  p0 [0:4095], p1 [0:4095], p2 [0:4095], p3 [0:4095];
	reg  [11:0] pal_ra;
	reg  [31:0] pal_q;
	wire        wp = cpu_sel && cpu_we && in_pal;
	always @(posedge clk) begin
		if (wp & cpu_be[0]) p0[cpu_addr[11:0]] <= cpu_din[7:0];
		if (wp & cpu_be[1]) p1[cpu_addr[11:0]] <= cpu_din[15:8];
		if (wp & cpu_be[2]) p2[cpu_addr[11:0]] <= cpu_din[23:16];
		if (wp & cpu_be[3]) p3[cpu_addr[11:0]] <= cpu_din[31:24];
		pal_q <= {p3[pal_ra], p2[pal_ra], p1[pal_ra], p0[pal_ra]};
	end

	// ================================================================ mixer pipeline
	// t0: ce_pix, rd_x = hcount.  t1: line buffer data.  t2: palette addr = layer pen.
	// t3: addr = sprite pen.  t4: pal_q = layer colour.  t5: pal_q = sprite colour -> blend.
	reg  [5:0]  ph;                        // one-hot pipeline phase after ce_pix
	reg  [11:0] m_lpen, m_spen;
	reg         m_lvalid, m_shown, m_alpha, m_text;
	reg  [23:0] m_lrgb;
	reg  [23:0] out_rgb;
	// composition at t1: the text, else the opaque SCR layer with the largest
	// key {priority, 2 - index} (priority descending, then index ascending)
	wire [3:0] key0 = {l_pri[0], 2'd2}, key1 = {l_pri[1], 2'd1}, key2 = {l_pri[2], 2'd0};
	wire       o0 = l_q[0][12], o1 = l_q[1][12], o2 = l_q[2][12], ot = l_q[3][12];
	wire       w0 = o0 && (!o1 || key0 > key1) && (!o2 || key0 > key2);
	wire       w1 = o1 && !w0 && (!o2 || key1 > key2);
	wire       w2 = o2 && !w0 && !w1;
	wire       c_valid = ot | o0 | o1 | o2;
	wire [11:0] c_pen = ot ? l_q[3][11:0] : w0 ? l_q[0][11:0] : w1 ? l_q[1][11:0] : l_q[2][11:0];
	wire [3:0] c_bits = (ot ? 4'b1000 : 4'b0000) | (o0 ? (4'b0001 << l_pri[0]) : 4'b0000)
	                  | (o1 ? (4'b0001 << l_pri[1]) : 4'b0000) | (o2 ? (4'b0001 << l_pri[2]) : 4'b0000);
	wire s_hide = |(c_bits >> s_q[13:12]);
	wire s_show = s_q[15] && !s_hide;

	always @(posedge clk) begin
		ph <= {ph[4:0], ce_pix};
		pal_ra <= 12'd0;
		cpu_ack <= 1'b0;
		if (ph[0]) begin                              // t1
			m_lvalid <= c_valid; m_lpen <= c_pen; m_shown <= s_show;
			m_alpha <= s_q[14]; m_spen <= s_q[11:0]; m_text <= l_q[3][12];
			dbg_pen <= c_valid ? c_pen : 12'd0;
		end
		if (ph[1]) pal_ra <= m_lpen;                  // t2
		if (ph[2]) pal_ra <= m_spen;                  // t3
		if (ph[3]) m_lrgb <= m_lvalid ? pal_q[31:8] : 24'd0;   // t4: layer colour
		if (ph[4]) begin                              // t5: sprite colour
			if (m_shown) begin
				if (m_alpha) out_rgb <= {avg(pal_q[31:24], m_lrgb[23:16]), avg(pal_q[23:16], m_lrgb[15:8]),
				                         avg(pal_q[15:8], m_lrgb[7:0])};
				else out_rgb <= pal_q[31:8];
			end else out_rgb <= m_lrgb;
		end
		if (ce_pix) begin rgb <= out_rgb; rgb_fade <= faded(out_rgb); end
		// CPU access. Writes ack at once. VRAM, zoom, register and sprite reads
		// have their own registered port: data the clock after. Palette reads take
		// the shared port on a clock the mixer does not use (not t2/t3) and have
		// the data two clocks later.
		if (cpu_sel && !cpu_ack) begin
			if (cpu_we) cpu_ack <= 1'b1;
			else if (in_pal) begin
				if (pal_cnt == 2'd0 && !(ph[1] | ph[2])) begin pal_ra <= cpu_addr[11:0]; pal_cnt <= 2'd2; end
				else if (pal_cnt == 2'd2) pal_cnt <= 2'd1;
				else if (pal_cnt == 2'd1) begin cpu_dout <= pal_q; cpu_ack <= 1'b1; pal_cnt <= 2'd0; end
			end else if (!rd_pend) rd_pend <= 1'b1;
			else begin
				cpu_ack <= 1'b1; rd_pend <= 1'b0;
				cpu_dout <= in_spr ? spr_cpu_q : v_vram ? vram_cq[layer] : v_lz ? lz_cq[layer]
				          : v_reg ? vr[layer][lw[1:0]] : 32'd0;
			end
		end
		if (reset) begin pal_cnt <= 2'd0; rd_pend <= 1'b0; end
	end
	reg [1:0] pal_cnt;
	reg       rd_pend;

	// alpha_blend_r32(d, s, 0x80) = (s*128 + d*128) >> 8 = (s + d) >> 1, per channel.
	// (Written as a function: a 9-bit sum shifted inside a concatenation stays
	// 9 bits wide and misaligns the channels -- measured, frame 900.)
	function [7:0] avg(input [7:0] a, input [7:0] b);
		reg [8:0] s9;
		begin s9 = {1'b0, a} + {1'b0, b}; avg = s9[8:1]; end
	endfunction

	// fade: MAME scales by (255 - fade) / 255 where fade = u8((d - 40) / 212 * 255);
	// d = 0xFF leaves it alone. Exact curve: Q10. Full brightness until then.
	function [23:0] faded(input [23:0] c);
		faded = c;
	endfunction
endmodule
