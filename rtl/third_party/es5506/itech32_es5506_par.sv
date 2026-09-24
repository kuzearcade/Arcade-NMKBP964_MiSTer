// SPDX-License-Identifier: GPL-3.0-or-later
//
// ES5506 PAR conversion sequencer. The digital timing follows the ENSONIQ
// OTTO Rev. 2.3 PAR description; the board-level comparator polarity, RC
// network and physical pin routing remain integration responsibilities.

`timescale 1ns/1ps

module itech32_es5506_par (
	input  logic       clk,
	input  logic       reset,
	input  logic       ce_16m,
	input  logic       read_byte0,
	input  logic       comparator_tripped,
	output logic [9:0] value,
	output logic       discharge_active
);
	typedef enum logic [1:0] {
		PAR_IDLE,
		PAR_DISCHARGE,
		PAR_MEASURE
	} par_state_t;

	localparam logic [12:0] DISCHARGE_CE_EVENTS = 13'd4096;
	localparam logic [9:0]  PAR_MAX_VALUE       = 10'h3ff;

	par_state_t  state_q;
	logic        read_seen_q;
	logic [12:0] discharge_remaining_q;
	logic [1:0]  measure_divider_q;
	logic [9:0]  measure_count_q;
	logic        read_start;

	assign read_start = read_byte0 && !read_seen_q;
	assign discharge_active = (state_q == PAR_DISCHARGE);

	// Interpretation choices where Rev. 2.3 does not define an FPGA edge:
	//
	// - an accepted byte-zero read arms discharge immediately, and the next
	//   4096 ce_16m events form the complete discharge interval;
	// - measurement samples once per four subsequent ce_16m events;
	// - comparison precedes increment, so a comparator already asserted at the
	//   first measurement event produces zero;
	// - a simultaneous read and phase/completion event restarts conversion;
	// - reset aborts a conversion and selects a deterministic maximum; the
	//   manual defines the post-read maximum but not the RESB value itself.
	always_ff @(posedge clk) begin
		if (reset) begin
			state_q               <= PAR_IDLE;
			read_seen_q           <= 1'b0;
			discharge_remaining_q <= 13'd0;
			measure_divider_q     <= 2'd0;
			measure_count_q       <= 10'd0;
			value                 <= PAR_MAX_VALUE;
		end else begin
			if (!read_byte0)
				read_seen_q <= 1'b0;

			if (read_start) begin
				state_q               <= PAR_DISCHARGE;
				read_seen_q           <= 1'b1;
				discharge_remaining_q <= DISCHARGE_CE_EVENTS;
				measure_divider_q     <= 2'd0;
				measure_count_q       <= 10'd0;
				value                 <= PAR_MAX_VALUE;
			end else if (ce_16m) begin
				case (state_q)
					PAR_IDLE: begin
						discharge_remaining_q <= 13'd0;
						measure_divider_q <= 2'd0;
						measure_count_q <= 10'd0;
					end

					PAR_DISCHARGE: begin
						if (discharge_remaining_q == 13'd1) begin
							discharge_remaining_q <= 13'd0;
							measure_divider_q <= 2'd0;
							measure_count_q <= 10'd0;
							state_q <= PAR_MEASURE;
						end else if (discharge_remaining_q != 13'd0) begin
							discharge_remaining_q <=
								discharge_remaining_q - 13'd1;
						end else begin
							// Defensive recovery from an illegal zero remainder.
							measure_divider_q <= 2'd0;
							measure_count_q <= 10'd0;
							state_q <= PAR_MEASURE;
						end
					end

					PAR_MEASURE: begin
						if (measure_divider_q == 2'd3) begin
							measure_divider_q <= 2'd0;
							if (comparator_tripped) begin
								value <= measure_count_q;
								state_q <= PAR_IDLE;
							end else if (measure_count_q == PAR_MAX_VALUE) begin
								value <= PAR_MAX_VALUE;
								state_q <= PAR_IDLE;
							end else begin
								measure_count_q <= measure_count_q + 10'd1;
							end
						end else begin
							measure_divider_q <= measure_divider_q + 2'd1;
						end
					end

					default: begin
						state_q <= PAR_IDLE;
						discharge_remaining_q <= 13'd0;
						measure_divider_q <= 2'd0;
						measure_count_q <= 10'd0;
						value <= PAR_MAX_VALUE;
					end
				endcase
			end
		end
	end
endmodule
