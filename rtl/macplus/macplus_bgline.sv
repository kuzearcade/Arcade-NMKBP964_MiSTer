// One Macross Plus tilemap layer, drawn one line ahead into a ping-pong line
// buffer (docs/PLAN.md 2.6.2; the design follows MP-3).
//
// SCR A/B/C (TEXT=0): 64x64 tiles of 16x16 at 8 bpp, 32-bit tile words, scroll
// from vr0, and the per-line zoom MAME guesses at (vr2[31:28] == 0xE):
//     incx   = (line even ? lz[31:16] : lz[15:0]) << 10          per line
//     incy   = vr2[24:16] << 10                                  per frame
//     startx = (vr0[9:0]   << 16) - 184 * (incx - 0x10000)
//     starty = (vr0[25:16] << 16) - 120 * (incy - 0x10000)
//     source = ((startx + x*incx) >> 16 & 1023, (starty + y*incy) >> 16 & 1023)
// Unzoomed is the same walk with incx = 1.0 and the plain scroll.
// TEXT (TEXT=1): 4 bpp packed MSB-first, no scroll, no zoom, no flip,
// colour = attr[23:17] in banks of 16, priority value 8 (the mixer's job).
//
// With no shear a line reads one map row, and a row has 64 tile columns, so a
// line needs at most 64 tile rows whatever incx is (MP-3). Each line:
//   MARK   walk x = 0..383, mark the tile columns the line touches
//   FETCH  for each marked column: read its tile word, request its ROM row
//          (pipelined; responses return in order into a 64-entry column cache)
//   DRAW   walk x again, write {opaque, pen[11:0]} into the line buffer
// About 800 clocks plus the fetch latency, against a 3,125-clock line.
//
// The line buffer half is the target line's parity; the display reads the half
// of the line it is on. Tile codes wrap with a power-of-two mask (code %=
// elements(), NMK-25). Text codes at or above code_limit lie in the zero-filled
// part of MAME's 4 MB region and are transparent without a fetch. Colour modes
// other than 01/10 (MAME: rand(), Q2) draw colour 0 and are counted.
module macplus_bgline #(
	parameter TEXT = 0
) (
	input             clk,
	input             reset,
	// line control
	input             start,        // begin rendering line `line`
	input      [7:0]  line,         // target visible line
	output reg        busy,
	// registers (live)
	input      [31:0] vr0,
	input      [31:0] vr2,
	input      [14:0] code_mask,    // elements - 1 (power of two)
	input      [15:0] code_limit,   // text: codes >= limit are transparent
	// line-zoom RAM read (registered, 1 clock)
	output     [6:0]  lz_addr,
	input      [31:0] lz_q,
	// VRAM read (registered, 1 clock)
	output reg [11:0] vram_addr,
	input      [31:0] vram_q,
	// ROM row stream: byte address of a 16-byte (8 bpp) or 8-byte (text) row
	output reg        rom_req,
	output reg [22:0] rom_addr,
	input             rom_ready,    // request accepted on a clock with rom_req & rom_ready
	input             rom_valid,    // one response per request, in request order
	input     [127:0] rom_data,     // byte k of the row in [8k+7:8k]
	// display side
	input      [8:0]  rd_x,
	input             rd_half,
	output reg [12:0] rd_q,         // {opaque, pen[11:0]}, one clock after rd_x
	output reg [1:0]  pri_out,      // this layer's priority for the half read
	// debug
	output reg [15:0] dbg_unknown,  // opaque pixels drawn in an undefined colour mode
	output reg [15:0] dbg_max_cycles,
	output reg [15:0] dbg_overruns
);
	localparam S_IDLE = 3'd0, S_SETUP = 3'd1, S_SETUP2 = 3'd2, S_MARK = 3'd3,
	           S_FETCH = 3'd4, S_WAIT = 3'd5, S_DRAW = 3'd6, S_DRAIN = 3'd7;
	reg [2:0]  st;
	reg [7:0]  y;
	reg        half;
	reg [8:0]  x;
	reg [31:0] cx0, cx, incx;
	reg [9:0]  sy;
	reg [63:0] need;
	reg [5:0]  fc;
	reg        fetching;
	reg [15:0] cyc;
	reg [1:0]  mode;
	reg [1:0]  pri0, pri1;     // this layer's priority, per line-buffer half

	assign lz_addr = y[7:1];
	wire zoom = !TEXT && vr2[31:28] == 4'hE;

	// ---------------------------------------------------------------- per-line maths
	wire [31:0] incx_l = {6'd0, (y[0] ? lz_q[15:0] : lz_q[31:16]), 10'd0};
	wire [31:0] incy_l = {7'd0, vr2[24:16], 16'd0} >> 6;
	wire [31:0] startx = {6'd0, vr0[9:0], 16'd0} - 32'd184 * (incx_l - 32'h10000);
	wire [31:0] starty = {6'd0, vr0[25:16], 16'd0} - 32'd120 * (incy_l - 32'h10000);
	wire [31:0] cy_l   = starty + {24'd0, y} * incy_l;
	wire [31:0] cx0_n  = TEXT ? 32'd0 : zoom ? startx : {6'd0, vr0[9:0], 16'd0};
	wire [31:0] incx_n = zoom ? incx_l : 32'h10000;
	wire [9:0]  sy_n   = TEXT ? {2'd0, y} : zoom ? cy_l[25:16] : ({2'd0, y} + vr0[25:16]);

	wire [9:0]  sx = cx[25:16];
	wire [5:0]  tc = sx[9:4];

	// ---------------------------------------------------------------- column cache and attributes
	reg  [127:0] cache [0:63];
	reg  [127:0] cache_q;
	always @(posedge clk) cache_q <= cache[tc];
	reg  [6:0]  c_col [0:63];      // BG: 0..31 (mode applied); text: 0..127
	reg  [63:0] c_fx, c_zero;
	reg  [5:0]  q_tc [0:63];       // columns in flight, in request order
	reg  [5:0]  q_wr, q_rd;

	// ---------------------------------------------------------------- line buffer
	reg  [12:0] lb [0:1023];
	reg         lb_we;
	reg  [9:0]  lb_wa;
	reg  [12:0] lb_wd;
	always @(posedge clk) begin
		if (lb_we) lb[lb_wa] <= lb_wd;
		rd_q <= lb[{rd_half, rd_x}];
		pri_out <= rd_half ? pri1 : pri0;
	end

	// ---------------------------------------------------------------- draw stage (cache_q belongs to d_*)
	reg         d_v;
	reg  [8:0]  d_x;
	reg  [3:0]  d_c;
	reg  [5:0]  d_tc;
	wire [3:0]  col   = d_c ^ (c_fx[d_tc] ? 4'hF : 4'h0);
	wire [7:0]  b8    = cache_q[{col, 3'b000} +: 8];
	wire [7:0]  b4    = cache_q[{1'b0, col[3:1], 3'b000} +: 8];
	wire [7:0]  px    = TEXT ? {4'd0, col[0] ? b4[3:0] : b4[7:4]} : b8;
	wire        opq   = px != 8'd0 && !c_zero[d_tc];
	wire [6:0]  cc    = c_col[d_tc];
	wire [11:0] pen   = TEXT ? (12'h800 + {1'b0, cc, 4'd0} + {8'd0, px[3:0]})
	                         : (12'h800 + {1'b0, cc[4:0], 6'd0} + {4'd0, px});

	// ---------------------------------------------------------------- fetch stage
	// One VRAM read in flight. Its word is LATCHED the clock it arrives, whether
	// or not a ROM request is waiting: the RAM's output register does not freeze
	// while this FSM does, and consuming it after a stall paired column C with
	// column C+1's tile word -- the whole layer one tile to the left, seen only
	// on the hardware path, where `rom_ready` comes a clock after the request
	// (M3, 2026-09-24; the NMK-21b class: an address trace could not see it).
	reg         rd_busy, rd_t1, rd_t2;
	reg  [5:0]  rd_tc;
	reg         w_full;               // f_word holds column w_tc's tile word
	reg  [31:0] f_word;
	reg  [5:0]  w_tc;
	wire [14:0] code_m = f_word[14:0] & code_mask;
	wire        f_zero = TEXT && ({1'b0, f_word[14:0]} >= code_limit);
	wire [3:0]  frow   = sy[3:0] ^ ((!TEXT && f_word[31]) ? 4'hF : 4'h0);
	wire [6:0]  f_col  = TEXT ? f_word[23:17]
	                   : (mode == 2'b10) ? {2'd0, f_word[19:17], 2'b00}
	                   : (mode == 2'b01) ? {2'd0, f_word[21:17]} : 7'd0;

	always @(posedge clk) begin
		lb_we <= 1'b0;
		if (reset) begin
			st <= S_IDLE; busy <= 1'b0; rom_req <= 1'b0; d_v <= 1'b0; rd_busy <= 1'b0; rd_t1 <= 1'b0; rd_t2 <= 1'b0; w_full <= 1'b0;
			q_wr <= 6'd0; q_rd <= 6'd0;
			dbg_unknown <= 16'd0; dbg_max_cycles <= 16'd0; dbg_overruns <= 16'd0;
		end else begin
			if (busy) cyc <= cyc + 16'd1;
			if (start && busy) dbg_overruns <= dbg_overruns + 16'd1;
			if (rom_valid) begin
				cache[q_tc[q_rd]] <= rom_data;
				q_rd <= q_rd + 6'd1;
			end
			if (rom_req && rom_ready) rom_req <= 1'b0;
			d_v <= 1'b0;
			case (st)
			S_IDLE: if (start) begin
				y <= line; half <= line[0]; busy <= 1'b1; cyc <= 16'd0; st <= S_SETUP;
			end
			S_SETUP: st <= S_SETUP2;          // lz_q for this y arrives now
			S_SETUP2: begin
				cx0 <= cx0_n; cx <= cx0_n; incx <= incx_n; sy <= sy_n;
				mode <= vr0[11:10];
				if (half) pri1 <= TEXT ? 2'd3 : vr0[15:14]; else pri0 <= TEXT ? 2'd3 : vr0[15:14];
				need <= 64'd0; x <= 9'd0; st <= S_MARK;
			end
			S_MARK: begin
				need[tc] <= 1'b1;
				cx <= cx + incx;
				x <= x + 9'd1;
				if (x == 9'd383) begin
					fc <= 6'd0; fetching <= 1'b1; rd_busy <= 1'b0; rd_t1 <= 1'b0; rd_t2 <= 1'b0; w_full <= 1'b0;
					st <= S_FETCH;
				end
			end
			S_FETCH: begin
				// the tile word arrives two clocks after its address (address
				// register, then the RAM); latch it whatever the request stage does
				rd_t1 <= 1'b0; rd_t2 <= rd_t1;
				if (rd_t2) begin f_word <= vram_q; w_tc <= rd_tc; w_full <= 1'b1; rd_busy <= 1'b0; end
				// a latched word becomes a ROM request when the request slot is free
				if (w_full && (!rom_req || rom_ready)) begin
					w_full <= 1'b0;
					c_col[w_tc] <= f_col;
					c_fx[w_tc] <= !TEXT && f_word[30];
					c_zero[w_tc] <= f_zero;
					if (!f_zero) begin
						rom_req <= 1'b1;
						rom_addr <= TEXT ? {1'b0, code_m, frow, 3'b000} : {code_m, frow, 4'b0000};
						q_tc[q_wr] <= w_tc; q_wr <= q_wr + 6'd1;
					end
				end
				// read the next needed column's tile word: one in flight, and only
				// when the word slot will be free by the time it arrives
				if (!rd_busy && !rd_t1 && !rd_t2 && (!w_full || (!rom_req || rom_ready))) begin
					if (fetching) begin
						if (need[fc]) begin
							vram_addr <= {sy[9:4], fc}; rd_t1 <= 1'b1; rd_busy <= 1'b1; rd_tc <= fc;
						end
						fc <= fc + 6'd1;
						if (fc == 6'd63) fetching <= 1'b0;
					end
				end
				if (!fetching && !rd_busy && !rd_t1 && !rd_t2 && !w_full) st <= S_WAIT;
			end
			S_WAIT: if (!rom_req && q_rd == q_wr && !rom_valid) begin
				cx <= cx0; x <= 9'd0; st <= S_DRAW;
			end
			S_DRAW: begin
				d_v <= 1'b1; d_x <= x; d_c <= sx[3:0]; d_tc <= tc;   // cache_q for tc arrives with d_*
				cx <= cx + incx;
				x <= x + 9'd1;
				if (x == 9'd383) st <= S_DRAIN;
			end
			S_DRAIN: begin
				busy <= 1'b0; st <= S_IDLE;
				if (cyc > dbg_max_cycles) dbg_max_cycles <= cyc;
			end
			default: st <= S_IDLE;
			endcase
			if (d_v) begin
				lb_we <= 1'b1; lb_wa <= {half, d_x}; lb_wd <= {opq, pen};
				if (opq && !TEXT && mode != 2'b01 && mode != 2'b10) dbg_unknown <= dbg_unknown + 16'd1;
			end
		end
	end
endmodule
