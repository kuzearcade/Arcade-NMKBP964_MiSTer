// Macross Plus sprites: the three sprite RAMs, the vblank buffer copy, and a
// line renderer (docs/PLAN.md 1.5, 2.6.3-2.6.4; MP-1 proved the rules below
// against MAME's pictures, MP-3 measured the load).
//
// RAM. `live` is the CPU's 0x800000-0x802FFF (3,072 longwords, 1,024 entries of
// three). At the start of vblank MAME does old2 <- old <- live and draws old2
// (macrossp.cpp:752-753). STAGES=2 reproduces that; STAGES=1 draws a copy of
// live taken at the same instant (MP-4: the whole-board gate decides). While
// old2 is written each entry's vertical extent goes into a table the renderer
// scans at four entries a clock. `rebuild` recomputes the table from old2
// without copying (after a savestate load).
//
// Entry (3 x 32 bits):
//   w0: high[29:26] y[25:16] colmode[15:14] wide[13:10] x[9:0]
//   w1: yzoom[25:16] xzoom[9:0]                   0x100 = 1.0
//   w2: flipy[31] flipx[30] alpha[29] pri[27:26] col[23:19] tile[15:0]
// MAME draws entry 1023 first and entry 0 last with an unconditional
// priority-31 claim, so the HIGHEST index owns a pixel even where a layer then
// hides it: the line buffer is first-writer-wins in that order and the mixer
// applies the layer test. Zoom (drawgfxzoom_core): scale = zoom<<8 (+0x600
// below 1.0); dst = (scale*16 + 0x8000) >> 16; d = 0x100000 / dst; tile slot i
// sits at pos + ((i*zoom) >> 4); destination pixel k of a tile reads source
// column (k*d) >> 16, flipped ((dst-1-k)*d) >> 16; the tile code is tile plus
// the draw-order index, mod 65536.
//
// Per line three decoupled processes:
//   SCAN   the extent table, word 255 down to 0, one word a clock; words with
//          a hit go into a queue
//   JOBS   for each hit, highest entry first: read the entry, walk its tile
//          rows in draw order, and for every row on the line emit one job per
//          tile column (a 16-byte ROM row request plus the run's parameters)
//   WRITE  per job: clip, then one destination pixel a clock, first writer wins
module macplus_sprites #(
	parameter STAGES = 2
) (
	input             clk,
	input             reset,
	// CPU port (sprite RAM, 32-bit, registered read)
	input      [11:0] cpu_addr,      // longword index 0..3071
	input             cpu_we,
	input      [3:0]  cpu_be,
	input      [31:0] cpu_din,
	output reg [31:0] cpu_dout,     // registered (the lane RAMs' outputs)
	// frame control
	input             copy,          // one clock at vblank start
	input             rebuild,       // recompute the extent table from old2
	output            copy_busy,
	// line control
	input             start,
	input      [7:0]  line,
	output reg        busy,
	// sprite ROM row stream (byte address of a 16-byte row)
	output reg        rom_req,
	output reg [23:0] rom_addr,
	input             rom_ready,
	input             rom_valid,
	input     [127:0] rom_data,
	// display side: {valid, alpha, pri[1:0], pen[11:0]}, one clock after rd_x
	input      [8:0]  rd_x,
	input             rd_half,
	output     [15:0] rd_q,
	output reg [15:0] dbg_max_cycles,
	output reg [15:0] dbg_overruns,
	output reg [7:0]  dbg_max_hits
);
	// ================================================================ RAMs
	// live: CPU writes by byte lane (four lane arrays, MS1Z-6); the copy reads it
	reg  [7:0]  live0 [0:3071], live1 [0:3071], live2 [0:3071], live3 [0:3071];
	reg  [11:0] live_ra;
	reg  [31:0] live_q;
	// true-dual-port per lane: port A the CPU (write + read), port B the copy read
	reg  [7:0]  cq0, cq1, cq2, cq3, lq0, lq1, lq2, lq3;
	always @(posedge clk) begin if (cpu_we & cpu_be[0]) live0[cpu_addr] <= cpu_din[7:0];   cq0 <= live0[cpu_addr]; end
	always @(posedge clk) begin if (cpu_we & cpu_be[1]) live1[cpu_addr] <= cpu_din[15:8];  cq1 <= live1[cpu_addr]; end
	always @(posedge clk) begin if (cpu_we & cpu_be[2]) live2[cpu_addr] <= cpu_din[23:16]; cq2 <= live2[cpu_addr]; end
	always @(posedge clk) begin if (cpu_we & cpu_be[3]) live3[cpu_addr] <= cpu_din[31:24]; cq3 <= live3[cpu_addr]; end
	always @(posedge clk) lq0 <= live0[live_ra];
	always @(posedge clk) lq1 <= live1[live_ra];
	always @(posedge clk) lq2 <= live2[live_ra];
	always @(posedge clk) lq3 <= live3[live_ra];
	always @(*) begin cpu_dout = {cq3, cq2, cq1, cq0}; live_q = {lq3, lq2, lq1, lq0}; end

	// old: 3,072 x 32 (STAGES=2 only)
	reg  [31:0] old [0:3071];
	reg  [11:0] old_ra, old_wa;
	reg         old_we;
	reg  [31:0] old_wd, old_q;
	always @(posedge clk) begin
		if (old_we) old[old_wa] <= old_wd;
		old_q <= old[old_ra];
	end

	// old2: 1,024 x 96, a whole entry per word
	reg  [95:0] old2 [0:1023];
	wire [9:0]  o2_ra;
	reg  [9:0]  o2_wa;
	reg         o2_we;
	reg  [95:0] o2_wd, o2_q;
	always @(posedge clk) begin
		if (o2_we) old2[o2_wa] <= o2_wd;
		o2_q <= old2[o2_ra];
	end

	// extent table: 256 words of four {valid, top[10:0], end[11:0]}
	reg  [95:0] ext [0:255];
	reg  [7:0]  ext_ra, ext_wa;
	reg         ext_we;
	reg  [95:0] ext_wd, ext_q;
	always @(posedge clk) begin
		if (ext_we) ext[ext_wa] <= ext_wd;
		ext_q <= ext[ext_ra];
	end

	function [10:0] fold(input [9:0] v);          // > 0x1FF means - 0x400
		fold = (v > 10'h1FF) ? ({1'b0, v} - 11'h400) : {1'b0, v};
	endfunction
	function [6:0] dst(input [9:0] z);            // (scale*16 + 0x8000) >> 16
		reg [22:0] s16;
		begin
			s16 = {1'b0, z, 12'd0} + ((z < 10'h100) ? 23'h6000 : 23'd0);
			dst = (s16 + 23'h8000) >> 16;
		end
	endfunction
	function [23:0] extent(input [31:0] w0, input [31:0] w1);
		reg [10:0] ys; reg [13:0] span; reg [6:0] dh; reg [11:0] ye;
		begin
			ys   = fold(w0[25:16]);
			dh   = dst(w1[25:16]);
			span = (w0[29:26] * w1[25:16]) >> 4;
			ye   = {ys[10], ys} + {1'b0, span[10:0]} + {5'd0, dh};
			extent = {dh != 7'd0, ys, ye};
		end
	endfunction

	// ================================================================ vblank copy / rebuild
	// STAGES=2: pass A old2 <- old (+ extents), then pass B old <- live.
	// STAGES=1: pass A old2 <- live (+ extents).  Rebuild: pass R extents from old2.
	localparam C_IDLE = 2'd0, C_A = 2'd1, C_B = 2'd2, C_R = 2'd3;
	reg  [1:0]  cst;
	reg  [12:0] ci;
	reg         cv1, cv2;
	reg  [11:0] cwa1, cwa2;
	reg  [1:0]  cw;
	reg  [31:0] e0, e1;
	reg  [71:0] extacc;
	reg  [9:0]  cent;            // entry index being completed
	reg  [9:0]  cr_ra;
	assign copy_busy = cst != C_IDLE;
	wire        from_old = (STAGES == 2) && cst == C_A;
	wire [31:0] srcq = from_old ? old_q : live_q;
	wire [23:0] ext_new = (cst == C_R) ? extent(o2_q[31:0], o2_q[63:32]) : extent(e0, e1);

	always @(posedge clk) begin
		old_we <= 1'b0; o2_we <= 1'b0; ext_we <= 1'b0;
		if (reset) begin
			cst <= C_IDLE; cv1 <= 1'b0; cv2 <= 1'b0;
		end else begin
			cv2 <= cv1; cwa2 <= cwa1; cv1 <= 1'b0;
			case (cst)
			C_IDLE: begin
				cw <= 2'd0; cent <= 10'd0; ci <= 13'd0;
				if (copy) cst <= C_A; else if (rebuild) cst <= C_R;
			end
			C_A, C_B: begin
				if (ci < 13'd3072) begin
					if (from_old) old_ra <= ci[11:0]; else live_ra <= ci[11:0];
					cv1 <= 1'b1; cwa1 <= ci[11:0]; ci <= ci + 13'd1;
				end else if (!cv1 && !cv2) begin
					ci <= 13'd0;
					cst <= (cst == C_A && STAGES == 2) ? C_B : C_IDLE;
				end
			end
			C_R: begin
				if (ci < 13'd1024) begin
					cr_ra <= ci[9:0]; cv1 <= 1'b1; ci <= ci + 13'd1;
				end else if (!cv1 && !cv2) cst <= C_IDLE;
			end
			endcase
			// the read data arrives two clocks after the address is chosen
			if (cv2 && cst == C_B) begin
				old_we <= 1'b1; old_wa <= cwa2; old_wd <= srcq;
			end
			if (cv2 && cst == C_A) begin
				case (cw)
				2'd0: begin e0 <= srcq; cw <= 2'd1; end
				2'd1: begin e1 <= srcq; cw <= 2'd2; end
				default: begin
					cw <= 2'd0;
					o2_we <= 1'b1; o2_wa <= cent; o2_wd <= {srcq, e1, e0};
				end
				endcase
			end
			// extents: one clock after the entry is complete (e0/e1 or o2_q valid)
			if ((cst == C_A && cv2 && cw == 2'd2) || (cst == C_R && cv2)) begin
				case (cent[1:0])
				2'd0: extacc[23:0]  <= ext_new;
				2'd1: extacc[47:24] <= ext_new;
				2'd2: extacc[71:48] <= ext_new;
				2'd3: begin ext_we <= 1'b1; ext_wa <= cent[9:2]; ext_wd <= {ext_new, extacc}; end
				endcase
				cent <= cent + 10'd1;
			end
		end
	end

	// ================================================================ line renderer
	reg  [511:0] occ0, occ1;
	reg  [15:0]  lb [0:1023];
	reg          lb_we;
	reg  [9:0]   lb_wa;
	reg  [15:0]  lb_wd, lb_q;
	reg          occ_q;
	always @(posedge clk) begin
		if (lb_we) lb[lb_wa] <= lb_wd;
		lb_q  <= lb[{rd_half, rd_x}];
		occ_q <= rd_half ? occ1[rd_x] : occ0[rd_x];
	end
	assign rd_q = {occ_q, lb_q[14:0]};

	// 0x100000 / d for d = 1..64 as a table: a combinational 21-bit divider
	// straight from the old2 RAM was a 51 ns path (first full compile, 2026-09-24)
	function [20:0] recip(input [6:0] d);
		integer k;
		begin
			recip = 21'd0;
			for (k = 1; k <= 64; k = k + 1) if (d == k[6:0]) recip = 21'h100000 / k;
		end
	endfunction

	reg  [7:0]  y;
	reg         half;
	reg  [15:0] cyc;
	reg  [7:0]  hits;
	wire signed [12:0] yl = {5'd0, y};
	function hit(input [23:0] e);
		hit = e[23] && ($signed({e[22], e[22], e[22:12]}) <= yl) && ($signed({e[11], e[11:0]}) > yl);
	endfunction

	// ---------------------------------------------------------------- SCAN
	reg         scanning;
	reg  [7:0]  sw;                 // next word to address
	reg         sv1, sv2;           // pipeline valid
	reg  [7:0]  sw1, sw2;
	reg  [11:0] hq [0:15];          // {word, mask}
	reg  [3:0]  hq_wr, hq_rd;
	wire [4:0]  hq_n = {1'b0, hq_wr} - {1'b0, hq_rd};
	wire [3:0]  hv = {hit(ext_q[95:72]), hit(ext_q[71:48]), hit(ext_q[47:24]), hit(ext_q[23:0])};
	wire        scan_done = !scanning && !sv1 && !sv2;

	// ---------------------------------------------------------------- JOBS
	localparam J_IDLE = 3'd0, J_PICK = 3'd1, J_LOAD = 3'd2, J_WAIT = 3'd3, J_ENT = 3'd4, J_ROW = 3'd5, J_COL = 3'd6, J_ENT2 = 3'd7;
	reg  [2:0]  jst;
	reg  [7:0]  jw;
	reg  [3:0]  jmask;
	reg  [9:0]  ren_ra;
	assign o2_ra = (cst == C_R) ? cr_ra : ren_ra;
	reg  [3:0]  wide, high, k, j;
	reg  [10:0] xs, ys;
	reg  [9:0]  xz, yz;
	reg  [15:0] tile;
	reg         fx, fy, alpha;
	reg  [1:0]  pri;
	reg  [4:0]  col;
	reg  [6:0]  dw, dh;
	reg  [20:0] ddx, ddy;
	reg  [3:0]  srow;
	wire [3:0]  slot_y = fy ? (high - k) : k;
	wire [13:0] yoff   = (slot_y * yz) >> 4;
	wire [10:0] rtop   = ys + yoff[10:0];
	wire signed [12:0] rel = yl - $signed({rtop[10], rtop[10], rtop});
	wire        row_on = (rel >= 13'sd0) && (rel < $signed({6'd0, dh}));
	wire [6:0]  rsel   = fy ? (dh - 7'd1 - rel[6:0]) : rel[6:0];
	wire [27:0] ry     = rsel * ddy;
	wire [3:0]  slot_x = fx ? (wide - j) : j;
	wire [13:0] xoff   = (slot_x * xz) >> 4;
	wire [10:0] left   = xs + xoff[10:0];
	wire [15:0] code   = tile + ({4'd0, k} * ({3'd0, wide} + 8'd1)) + {12'd0, j};
	// job and row queues, both in request order
	reg  [52:0] jq [0:15];          // {left, dw, ddx, fx, alpha, pri, col}
	reg  [3:0]  jq_wr, jq_rd;
	reg [127:0] dq [0:15];
	reg  [3:0]  dq_wr, dq_rd;
	wire [4:0]  jq_n = {1'b0, jq_wr} - {1'b0, jq_rd};
	wire        jq_room = jq_n < 5'd14;

	// ---------------------------------------------------------------- WRITE
	reg         w_busy, w_setup;
	reg  [10:0] w_left;
	reg  [6:0]  w_dw;
	reg  [20:0] w_dx;
	reg         w_fx, w_alpha;
	reg  [1:0]  w_pri;
	reg  [4:0]  w_col;
	reg [127:0] w_row;
	reg  [8:0]  w_x, w_xl;
	reg  [27:0] w_s;
	wire [3:0]  w_sc = w_s[19:16];
	wire [7:0]  w_p  = w_row[{w_sc, 3'b000} +: 8];
	wire        w_occ = half ? occ1[w_x] : occ0[w_x];

	always @(posedge clk) begin
		lb_we <= 1'b0;
		if (reset) begin
			busy <= 1'b0; scanning <= 1'b0; sv1 <= 1'b0; sv2 <= 1'b0; jst <= J_IDLE;
			rom_req <= 1'b0; w_busy <= 1'b0; w_setup <= 1'b0;
			hq_wr <= 4'd0; hq_rd <= 4'd0; jq_wr <= 4'd0; jq_rd <= 4'd0; dq_wr <= 4'd0; dq_rd <= 4'd0;
			dbg_max_cycles <= 16'd0; dbg_overruns <= 16'd0; dbg_max_hits <= 8'd0;
		end else begin
			if (busy) cyc <= cyc + 16'd1;
			if (start && busy) dbg_overruns <= dbg_overruns + 16'd1;
			if (rom_req && rom_ready) rom_req <= 1'b0;
			if (rom_valid) begin dq[dq_wr] <= rom_data; dq_wr <= dq_wr + 4'd1; end

			// ---------------- line start
			if (start && !busy) begin
				y <= line; half <= line[0]; busy <= 1'b1; cyc <= 16'd0; hits <= 8'd0;
				if (line[0]) occ1 <= 512'd0; else occ0 <= 512'd0;
				scanning <= 1'b1; sw <= 8'd255;
			end

			// ---------------- SCAN: address a word a clock; ext_q arrives two clocks later
			sv1 <= 1'b0; sv2 <= sv1; sw2 <= sw1;
			if (scanning && hq_n < 5'd13) begin
				ext_ra <= sw; sv1 <= 1'b1; sw1 <= sw;
				if (sw == 8'd0) scanning <= 1'b0; else sw <= sw - 8'd1;
			end
			if (sv2 && hv != 4'd0) begin hq[hq_wr] <= {sw2, hv}; hq_wr <= hq_wr + 4'd1; end

			// ---------------- JOBS
			case (jst)
			J_IDLE: if (hq_rd != hq_wr) begin
				{jw, jmask} <= hq[hq_rd]; hq_rd <= hq_rd + 4'd1; jst <= J_PICK;
			end
			J_PICK: begin
				if (jmask == 4'd0) jst <= J_IDLE;
				else begin
					if (jmask[3])      begin ren_ra <= {jw, 2'd3}; jmask[3] <= 1'b0; end
					else if (jmask[2]) begin ren_ra <= {jw, 2'd2}; jmask[2] <= 1'b0; end
					else if (jmask[1]) begin ren_ra <= {jw, 2'd1}; jmask[1] <= 1'b0; end
					else               begin ren_ra <= {jw, 2'd0}; jmask[0] <= 1'b0; end
					hits <= hits + 8'd1;
					jst <= J_LOAD;
				end
			end
			J_LOAD: jst <= J_WAIT;         // the RAM samples ren_ra
			J_WAIT: jst <= J_ENT;          // o2_q valid
			J_ENT: begin
				wide <= o2_q[13:10]; high <= o2_q[29:26];
				xs <= fold(o2_q[9:0]); ys <= fold(o2_q[25:16]);
				xz <= o2_q[41:32]; yz <= o2_q[57:48];
				tile <= o2_q[79:64];
				fy <= o2_q[95]; fx <= o2_q[94]; alpha <= o2_q[93]; pri <= o2_q[91:90];
				col <= (o2_q[15:14] == 2'b10) ? {o2_q[85:83], 2'b00} : (o2_q[15:14] == 2'b01) ? o2_q[87:83] : 5'd0;
				dw <= dst(o2_q[41:32]); dh <= dst(o2_q[57:48]);
				k <= 4'd0; jst <= J_ENT2;
			end
			J_ENT2: begin                      // the reciprocals from the registered sizes
				ddx <= recip(dw); ddy <= recip(dh);
				jst <= J_ROW;
			end
			J_ROW: begin
				if (dw == 7'd0 || dh == 7'd0) jst <= J_PICK;
				else if (row_on) begin srow <= ry[19:16]; j <= 4'd0; jst <= J_COL; end
				else if (k == high) jst <= J_PICK;
				else k <= k + 4'd1;
			end
			J_COL: if (jq_room && (!rom_req || rom_ready)) begin
				jq[jq_wr] <= {left, dw, ddx, fx, alpha, pri, col};
				jq_wr <= jq_wr + 4'd1;
				rom_req <= 1'b1; rom_addr <= {code, srow, 4'd0};
				if (j == wide) begin
					if (k == high) jst <= J_PICK; else begin k <= k + 4'd1; jst <= J_ROW; end
				end else j <= j + 4'd1;
			end
			default: jst <= J_IDLE;
			endcase

			// ---------------- WRITE
			if (!w_busy) begin
				if (jq_rd != jq_wr && dq_rd != dq_wr) begin
					{w_left, w_dw, w_dx, w_fx, w_alpha, w_pri, w_col} <= jq[jq_rd];
					w_row <= dq[dq_rd];
					jq_rd <= jq_rd + 4'd1; dq_rd <= dq_rd + 4'd1;
					w_setup <= 1'b1; w_busy <= 1'b1;
				end
			end else if (w_setup) begin
				w_setup <= 1'b0;
				begin : clip
					reg signed [12:0] l, r, xa;
					reg [6:0] skip;
					l  = $signed({w_left[10], w_left[10], w_left});
					r  = l + $signed({6'd0, w_dw}) - 13'sd1;
					xa = (l < 13'sd0) ? 13'sd0 : l;
					skip = xa[6:0] - l[6:0];
					if (l > 13'sd383 || r < 13'sd0) w_busy <= 1'b0;
					else begin
						w_x  <= xa[8:0];
						w_xl <= (r > 13'sd383) ? 9'd383 : r[8:0];
						w_s  <= w_fx ? (({21'd0, w_dw} - 28'd1) * w_dx) - ({21'd0, skip} * w_dx)
						             : ({21'd0, skip} * w_dx);
					end
				end
			end else begin
				if (w_p != 8'd0 && !w_occ) begin
					if (half) occ1[w_x] <= 1'b1; else occ0[w_x] <= 1'b1;
					lb_we <= 1'b1; lb_wa <= {half, w_x};
					lb_wd <= {1'b1, w_alpha, w_pri, {1'b0, w_col, 6'd0} + {4'd0, w_p}};
				end
				w_s <= w_fx ? (w_s - {7'd0, w_dx}) : (w_s + {7'd0, w_dx});
				w_x <= w_x + 9'd1;
				if (w_x == w_xl) w_busy <= 1'b0;
			end

			// ---------------- line end
			if (busy && !(start && !busy) && scan_done && hq_rd == hq_wr && jst == J_IDLE &&
			    !rom_req && jq_rd == jq_wr && !w_busy) begin
				busy <= 1'b0;
				if (cyc > dbg_max_cycles) dbg_max_cycles <= cyc;
				if (hits > dbg_max_hits) dbg_max_hits <= hits;
			end
		end
	end
endmodule
