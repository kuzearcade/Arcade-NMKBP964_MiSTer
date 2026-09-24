// Macross Plus raster (docs/PLAN.md 1.5, D4: MAME's timing is what ships).
//
// MAME: 512 x 256 total at 60 Hz, vblank time 0, visible 384 x 240 (macrossp)
// or 384 x 224 (quizmoon). Its dot clock is therefore 512*256*60 = 7,864,320 Hz,
// which from the 48 MHz clk_sys is exactly 512/3125: ce_pix is a rational
// accumulator (+512, modulo 3125), so the frame rate is exactly 60 Hz and every
// line is exactly 3,125 clk_sys cycles -- the line renderers' budget.
//
// vblank begins at the first line after the visible area (MAME raises IRQ3
// there, set_vblank_int), and vtick marks the last pixel of every line, when
// the line renderers swap buffers (as ms1z_sprline). hsync/vsync sit inside
// the blanking; their exact place on the board is unknown (Q4), so they are
// placed like the siblings' and the OSD's CRT Adjust moves them.
module macplus_timing #(
	parameter [8:0] HTOTAL = 9'd511,    // last hcount (512 total)
	parameter [8:0] VTOTAL = 9'd255,    // last vcount (256 total)
	parameter [8:0] HVIS   = 9'd384,
	parameter [8:0] HS_START = 9'd432,
	parameter [8:0] HS_END   = 9'd464,
	parameter [11:0] ACC_ADD = 12'd512,
	parameter [11:0] ACC_MOD = 12'd3125
) (
	input            clk,
	input            reset,
	input            quiz,         // quizmoon: 224 visible lines
	input            hold,         // savestate/pause parking never stops the raster; kept for symmetry
	output reg       ce_pix,
	output reg [8:0] hcount,
	output reg [8:0] vcount,
	output           hblank,
	output           vblank,
	output reg       hsync,
	output reg       vsync,
	output           vtick,        // last clock of the last pixel of each line
	output           vblank_start, // one clock, at the start of the first blank line
	output           frame_start   // one clock, at the start of line 0
);
	reg [11:0] acc;
	wire [12:0] acc_n = {1'b0, acc} + {1'b0, ACC_ADD};
	always @(posedge clk) begin
		if (reset) begin
			acc <= 12'd0; ce_pix <= 1'b0;
		end else if (acc_n >= {1'b0, ACC_MOD}) begin
			acc <= acc_n[11:0] - ACC_MOD; ce_pix <= 1'b1;
		end else begin
			acc <= acc_n[11:0]; ce_pix <= 1'b0;
		end
	end

	wire [8:0] vvis = quiz ? 9'd224 : 9'd240;
	always @(posedge clk) begin
		if (reset) begin
			hcount <= 9'd0; vcount <= 9'd0; hsync <= 1'b0; vsync <= 1'b0;
		end else if (ce_pix) begin
			if (hcount == HTOTAL) begin
				hcount <= 9'd0;
				vcount <= (vcount == VTOTAL) ? 9'd0 : vcount + 9'd1;
			end else
				hcount <= hcount + 9'd1;
			if (hcount == HS_START) hsync <= 1'b1;
			if (hcount == HS_END)   hsync <= 1'b0;
			if (hcount == HS_START) begin
				if (vcount == vvis + 9'd4) vsync <= 1'b1;
				if (vcount == vvis + 9'd7) vsync <= 1'b0;
			end
		end
	end
	assign hblank = hcount >= HVIS;
	assign vblank = vcount >= vvis;
	assign vtick = ce_pix && hcount == HTOTAL;
	assign vblank_start = vtick && vcount == vvis - 9'd1;
	assign frame_start  = vtick && vcount == VTOTAL;
endmodule
