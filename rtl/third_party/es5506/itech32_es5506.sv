// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ensoniq ES5506 (OTTO) functional foundation for Incredible Technologies
// sound boards.  The register protocol and sample-generation order follow
// MAME's BSD-3-Clause es5506 device.  This is original RTL, not translated
// MAME source.

`timescale 1ns/1ps

module itech32_es5506 #(
	parameter integer SLOT_TICKS = 16,
	parameter bit ENABLE_PROGRAM_PREWARM = 1'b1
) (
	input  logic               clk,
	input  logic               reset,
	input  logic               ce_16m,

	// ES5506's 8-bit asynchronous host window. Addresses are byte offsets
	// 0x00..0x3f; four big-endian byte transfers form each register.
	input  logic               host_req,
	input  logic               host_write,
	input  logic [5:0]         host_addr,
	input  logic [7:0]         host_wdata,
	output logic [7:0]         host_rdata,
	output logic               host_ack,
	input  logic               par_comparator_tripped,
	output logic               par_discharge,

	// Byte-addressed, even-aligned, big-endian sample-ROM transaction. The
	// payload is held stable until sample_ack is observed high.
	output logic               sample_req,
	output logic [1:0]         sample_bank,
	output logic [21:0]        sample_addr,
	output logic               sample_companded,
	output logic [4:0]         sample_voice,
	input  logic [15:0]        sample_rdata,
	input  logic               sample_ack,

	// Six native stereo channels, channel0 in bits19:0. The scalar outputs
	// are aliases of channel0 (SER0), not a second compatibility mixer.
	// ITech32 swaps left/right at board routing level.
	output logic signed [19:0] audio_left,
	output logic signed [19:0] audio_right,
	output logic [119:0]       audio_left_channels,
	output logic [119:0]       audio_right_channels,
	output logic               audio_strobe,

	output logic               irq,
	output logic [7:0]         irq_vector,
	output logic [6:0]         current_page,
	output logic [4:0]         active_voices,
	output logic [4:0]         scan_voice,
	output logic               engine_busy
);

	localparam logic [15:0] CONTROL_CMPD     = 16'h2000;
	localparam logic [15:0] CONTROL_IRQ      = 16'h0080;
	localparam logic [15:0] CONTROL_DIR      = 16'h0040;
	localparam logic [15:0] CONTROL_IRQE     = 16'h0020;
	localparam logic [15:0] CONTROL_BLE      = 16'h0010;
	localparam logic [15:0] CONTROL_LPE      = 16'h0008;
	localparam logic [15:0] CONTROL_LEI      = 16'h0004;
	localparam logic [15:0] CONTROL_STOPMASK = 16'h0003;
	localparam logic [15:0] CONTROL_LOOPMASK = 16'h0018;
	localparam integer SLOT_COUNT_WIDTH = (SLOT_TICKS <= 1) ? 1 : $clog2(SLOT_TICKS);
	localparam logic [SLOT_COUNT_WIDTH-1:0] SLOT_LAST =
		SLOT_COUNT_WIDTH'(SLOT_TICKS - 1);
	// Launch is T0; the fully pipelined running path reaches its terminal
	// commit at T28.  Short terminal paths are padded to that same phase so
	// run/stop/underrun transitions cannot move the scan's output phase.
	localparam logic [5:0] RUNNING_TERMINAL_LATENCY = 6'd28;
	localparam logic [5:0] UNDERRUN_WAIT_CYCLES =
		RUNNING_TERMINAL_LATENCY - 6'd7;

	// The sample datapath is deliberately serialized into short registered
	// stages.  A single-cycle implementation chains decode, interpolation,
	// four filter poles, volume and clamp into a roughly 100 ns path on
	// Cyclone V.  OTTO already time-multiplexes this arithmetic by voice, so
	// staging it preserves the observable register/sample order while making
	// the implementation practical in MiSTer's shared fabric clock domain.
	typedef enum logic [5:0] {
		ENGINE_IDLE,
		ENGINE_LAUNCH,
		ENGINE_CACHE_READ0,
		ENGINE_CACHE_SELECT0,
		ENGINE_CACHE_READ1,
		ENGINE_CACHE_SELECT1,
		ENGINE_DECODE,
		ENGINE_STEP_DECIDE,
		ENGINE_STEP_FINISH,
		ENGINE_INTERP_PREP,
		ENGINE_INTERP_MUL,
		ENGINE_INTERP_SUM,
		ENGINE_POLE1_PREP,
		ENGINE_POLE1_MUL,
		ENGINE_POLE1_FINISH,
		ENGINE_POLE2_PREP,
		ENGINE_POLE2_MUL,
		ENGINE_POLE2_FINISH,
		ENGINE_POLE3_PREP,
		ENGINE_POLE3_MUL,
		ENGINE_POLE3_FINISH,
		ENGINE_POLE4_PREP,
		ENGINE_POLE4_MUL,
		ENGINE_POLE4_FINISH,
		ENGINE_POLE4_APPLY,
		ENGINE_VOLUME_GAIN,
		ENGINE_VOLUME_MUL,
		ENGINE_VOLUME_FINISH,
		ENGINE_COMMIT,
		ENGINE_STOPPED,
		ENGINE_UNDERRUN_WAIT,
		ENGINE_UNDERRUN
	} engine_state_t;

	// Eight 64-bit sample-ROM lines per voice and bank cover the interpolation
	// line and six lines of directional lookahead.  The cache is a latency absorber,
	// not a speculative replacement for external ROM: a single background
	// fetcher fills one aligned qword at a time through the existing held
	// request/acknowledge contract.  At ACTV=0 the far refill line is still
	// more than 1,000 fabric clocks ahead, safely beyond the measured 665-clock
	// DDR tail.  Tags/valid bits, rather than RAM contents, define reset state.
	localparam integer SAMPLE_CACHE_LINES = 8;
	localparam integer SAMPLE_CACHE_ENTRIES = 32 * 4 * SAMPLE_CACHE_LINES;
	typedef enum logic [2:0] {
		PREFETCH_INIT,
		PREFETCH_SCAN,
		PREFETCH_TARGET,
		PREFETCH_LOOKUP,
		PREFETCH_FETCH,
		PREFETCH_URGENT_GATHER,
		PREFETCH_URGENT_SELECT,
		PREFETCH_ROW_READY
	} prefetch_state_t;

	engine_state_t engine_state;

	// A voice is one coherent synchronous RAM row. The engine/host pipeline and
	// the independent prefetch scanner each need one registered read port, so
	// two identical 1R1W M10K banks are maintained from the same write bundle.
	// Only the validity metadata resets; unread payload bits are don't-care.
	typedef struct packed {
		logic [15:0] control;
		logic [16:0] freq;
		logic [31:0] start_addr;
		logic [31:0] end_addr;
		logic [31:0] accum;
		logic [15:0] lvol;
		logic [15:0] rvol;
		logic [7:0]  lvramp;
		logic [7:0]  rvramp;
		logic [8:0]  ecount;
		logic [15:0] k1;
		logic [15:0] k2;
		logic [8:0]  k1ramp;
		logic [8:0]  k2ramp;
		logic [2:0]  filtcnt;
		// Retain signed internal guard bits while preserving the documented
		// 18-bit host-register view. See docs/SOUND.md for the evidence boundary.
		logic signed [31:0] o1n1;
		logic signed [31:0] o2n1;
		logic signed [31:0] o2n2;
		logic signed [31:0] o3n1;
		logic signed [31:0] o3n2;
		logic signed [31:0] o4n1;
	} voice_state_t;

	(* ramstyle = "M10K, no_rw_check" *)
	voice_state_t voice_state_engine_mem [0:31];
	(* ramstyle = "M10K, no_rw_check" *)
	voice_state_t voice_state_prefetch_mem [0:31];
	voice_state_t voice_engine_q;
	voice_state_t voice_prefetch_q;
	voice_state_t voice_engine_data;
	voice_state_t voice_prefetch_data;
	voice_state_t voice_write_data;
	logic [31:0] voice_state_valid;
	logic        voice_engine_valid_q;
	logic        voice_prefetch_valid_q;
	logic        voice_prefetch_collision_q;
	logic [4:0]  voice_engine_read_addr;
	logic [4:0]  voice_prefetch_read_addr;
	logic [4:0]  voice_write_addr;
	logic        voice_write_en;

	logic [31:0] write_latch;
	logic [23:0] read_latch;
	logic [31:0] assembled_write;
	logic [31:0] register_read_value;
	logic        host_seen;
	logic        host_req_q;
	logic        host_write_q;
	logic [5:0]  host_addr_q;
	logic [7:0]  host_wdata_q;
	logic [6:0]  host_page_q;
	logic        host_access_pending;
	logic        host_latch_only;
	logic        host_latch_accept;
	logic        host_pipeline_busy;
	logic        host_arch_request;
	logic        host_idle_reserve;
	logic        host_overlap_kind;
	logic        host_overlap_window;
	logic        host_overlap_reserve;
	logic        host_overlap_q;
	logic        host_engine_hold;
	logic        host_write_execute_pending;
	logic        start_prefetch_hint;
	logic        host_write_low_page_q;
	logic        host_write_voice_page_q;
	logic        host_write_test_page_q;
	logic [31:0] host_write_voice_select_q;
	logic [15:0] host_write_slot_select_q;
	logic [31:0] host_write_value_q;
	logic        host_read_select_pending;
	// This one-cycle host-response state is an architectural priority control
	// for every voice-history bank.
	logic host_read_response_pending;
	logic [15:0] host_read_slot_select_q;
	logic [31:0] host_read_slot_value [0:15];
	logic [6:0]  host_read_page_q;
	logic        host_read_low_page_q;
	logic        host_read_voice_page_q;
	logic [15:0] host_read_control_q;
	logic [16:0] host_read_freq_q;
	logic [15:0] host_read_lvol_q;
	logic [7:0]  host_read_lvramp_q;
	logic [15:0] host_read_rvol_q;
	logic [7:0]  host_read_rvramp_q;
	logic [8:0]  host_read_ecount_q;
	logic [15:0] host_read_k1_q;
	logic [15:0] host_read_k2_q;
	logic [8:0]  host_read_k1ramp_q;
	logic [8:0]  host_read_k2ramp_q;
	logic [31:0] host_read_start_q;
	logic [31:0] host_read_end_q;
	logic [31:0] host_read_accum_q;
	logic [17:0] host_read_o1n1_q;
	logic [17:0] host_read_o2n1_q;
	logic [17:0] host_read_o2n2_q;
	logic [17:0] host_read_o3n1_q;
	logic [17:0] host_read_o3n2_q;
	logic [17:0] host_read_o4n1_q;
	logic [4:0]  host_read_active_q;
	logic [4:0]  host_read_mode_q;
	logic [9:0]  host_read_par_q;
	logic [9:0]  par_value;
	logic        par_read_start;
	logic [7:0]  host_read_irq_vector_q;
	logic [6:0]  host_read_w_st_q;
	logic [6:0]  host_read_w_end_q;
	logic [6:0]  host_read_lr_end_q;
	logic [4:0]  mode;
	logic [6:0]  w_st;
	logic [6:0]  w_end;
	logic [6:0]  lr_end;

	// PAR is a common register on every page. The byte-zero execution edge
	// snapshots the previous conversion result while starting or restarting the
	// next conversion; nonblocking assignment ordering preserves that contract.
	assign par_read_start = host_access_pending && !host_write_q &&
		(host_addr_q == 6'h34);

	itech32_es5506_par par_converter (
		.clk                (clk),
		.reset              (local_reset),
		.ce_16m             (ce_16m),
		.read_byte0         (par_read_start),
		.comparator_tripped (par_comparator_tripped),
		.value              (par_value),
		.discharge_active   (par_discharge)
	);

	logic [SLOT_COUNT_WIDTH-1:0] slot_count;
	logic [4:0] work_voice;
	// Preserve the accepted voice as one-hot write enables so the binary
	// work_voice decoder is not rebuilt on every voice-history array port.
	logic [31:0] work_voice_select;
	logic [15:0] fetched_sample0;
	logic [15:0] fetched_sample1;
	// One canonical channel store, as specified in Rev2.3 sections6/12.
	// Capture the selected channel at launch so the shared terminal add does
	// not contain a six-way read mux in front of its carry/clip path.
	logic signed [22:0] channel_mix_left [0:5];
	logic signed [22:0] channel_mix_right [0:5];
	logic signed [22:0] work_mix_left;
	logic signed [22:0] work_mix_right;
	logic [5:0] work_channel_select;
	logic engine_terminal;
	logic signed [22:0] terminal_input_left;
	logic signed [22:0] terminal_input_right;
	logic signed [22:0] terminal_sum_left;
	logic signed [22:0] terminal_sum_right;

	// Per-voice snapshot.  Host access is held off while the engine is busy,
	// and these registers remove the 32:1 voice-array muxes from every DSP
	// stage while guaranteeing one coherent voice transaction.
	logic [15:0] work_control;
	logic [16:0] work_freq;
	logic [31:0] work_start;
	logic [31:0] work_end;
	logic [31:0] work_accum;
	logic [15:0] work_lvol;
	logic [15:0] work_rvol;
	logic [7:0]  work_lvramp;
	logic [7:0]  work_rvramp;
	logic [8:0]  work_ecount;
	logic [15:0] work_k1;
	logic [15:0] work_k2;
	logic [8:0]  work_k1ramp;
	logic [8:0]  work_k2ramp;
	logic [2:0]  work_filtcnt;
	logic signed [31:0] work_o1n1;
	logic signed [31:0] work_o2n1;
	logic signed [31:0] work_o2n2;
	logic signed [31:0] work_o3n1;
	logic signed [31:0] work_o3n2;
	logic signed [31:0] work_o4n1;
	logic signed [15:0] decoded_sample0_reg;
	logic signed [15:0] decoded_sample1_reg;
	logic [9:0]         interp_weight0_reg;
	logic [9:0]         interp_weight1_reg;
	logic signed [26:0] interp_product0_reg;
	logic signed [26:0] interp_product1_reg;
	logic signed [17:0] interpolated_sample_reg;
	logic signed [31:0] filter_operand_reg;
	logic [11:0]        filter_cutoff_reg;
	logic signed [28:0] filter_product_high_reg;
	logic        [27:0] filter_product_low_reg;
	logic signed [47:0] filter_product_combined;
	logic signed [47:0] filter_quotient_reg;
	logic signed [31:0] filter_pole1_reg;
	logic signed [31:0] filter_pole2_reg;
	logic signed [31:0] filter_pole3_reg;
	logic signed [31:0] filter_pole4_reg;
	logic [8:0]         volume_gain_left_reg;
	logic [8:0]         volume_gain_right_reg;
	logic [3:0]         volume_exponent_left_reg;
	logic [3:0]         volume_exponent_right_reg;
	logic signed [41:0] volume_product_left_reg;
	logic signed [41:0] volume_product_right_reg;
	logic signed [31:0] voice_mix_left_reg;
	logic signed [31:0] voice_mix_right_reg;

	// Keep the wide sample payload on a 1W1R simple-dual-port RAM and the
	// independently inspected valid/bank/line metadata on a bidirectional
	// tag RAM. The bank is part of the direct-map index, so programming a voice
	// while stopped can retain the exact interpolation pair for every possible
	// bank until the final RUN control reveals which bank the chip will use.
	// The 1,024-entry payload maps to seven M10Ks and the tag RAM to two M10Ks.
	// Four returned words are assembled before payload and tag are committed
	// together on one fill edge.
	(* ramstyle = "M10K, no_rw_check" *)
	logic [63:0] sample_cache_data_mem [0:SAMPLE_CACHE_ENTRIES-1];
	// Quartus 17 cannot infer the required 2R1W tag topology without retaining
	// an asynchronous logic shadow. Keep the portable array model for RTL
	// simulation and use the framework's explicit bidirectional-dual-port M10K
	// shape for synthesis.
`ifdef VERILATOR
	logic [18:0] sample_cache_tag_mem [0:SAMPLE_CACHE_ENTRIES-1];
`endif
	logic [63:0] engine_cache_data_q;
`ifdef VERILATOR
	logic [18:0] engine_cache_tag_q;
`else
	wire [18:0] engine_cache_tag_q;
`endif
	logic [9:0] engine_cache_read_addr;
	logic engine_cache_collision_q;
	logic engine_cache_first_hit_q;
	logic engine_sample_miss;
	logic [5:0] underrun_delay_q;
`ifdef VERILATOR
	logic [18:0] prefetch_cache_tag_q;
`else
	wire [18:0] prefetch_cache_tag_q;
`endif
	logic prefetch_cache_collision_q;
	logic [9:0] prefetch_init_addr;
	logic cache_initialized;
	logic cache_fill_we;
	prefetch_state_t prefetch_state;
	logic [4:0] prefetch_scan_voice;
	logic [2:0] prefetch_target_index;
	logic [4:0] prefetch_voice_q;
	logic [9:0] prefetch_entry_q;
	logic [1:0] prefetch_bank_q;
	logic [18:0] prefetch_line_q;
	logic [1:0] prefetch_word_q;
	logic prefetch_companded_q;
	logic [63:0] prefetch_line_data_q;
	logic [18:0] prefetch_scan_line;
	logic [18:0] prefetch_target_line;
	logic [1:0] prefetch_scan_bank;
	logic [9:0] prefetch_target_entry;
	logic prefetch_scan_running;
	logic [18:0] prefetch_base_line_q;
	logic prefetch_direction_q;
	logic prefetch_running_q;
	logic prefetch_target_hit;
	logic [31:0] prefetch_urgent_pending;
	logic [31:0] prefetch_urgent_set_mask;
	logic [31:0] prefetch_urgent_clear_mask;
	logic prefetch_urgent_dispatch;
	// ACCUM programming normally precedes RUN by hundreds of microseconds in
	// Time Killers, but the stopped control word does not reveal the eventual
	// sample bank. Keep a low-priority per-voice prewarm request and advance one
	// bank per dispatch; normal running/miss urgent work wins between banks.
	logic [31:0] prefetch_program_pending;
	logic [31:0] prefetch_program_set_mask;
	logic [31:0] prefetch_program_clear_mask;
	logic [31:0] prefetch_program_bank_bit0;
	logic [31:0] prefetch_program_bank_bit1;
	logic [31:0] prefetch_program_bank_bit0_next;
	logic [31:0] prefetch_program_bank_bit1_next;
	logic prefetch_program_pair_complete;
	logic prefetch_program_drop;
	logic prefetch_program_dispatch;
	logic [4:0] prefetch_urgent_scan_voice;
	logic [4:0] prefetch_row_voice_q;
	logic prefetch_row_urgent_q;
	logic prefetch_row_program_q;
	logic prefetch_urgent_mode_q;
	logic prefetch_program_mode_q;
	logic prefetch_urgent_upper_q;
	logic prefetch_urgent_need_upper_q;
	logic [24:0] prefetch_urgent_descriptor;
	logic cache_write_we;
	logic [9:0] cache_write_addr;

	// The urgent scan uses the prefetch M10K read port. PREFETCH_SCAN supplies
	// the row address and this following gather state captures its descriptor.
	// The descriptor is payload; state validity makes a reset unnecessary.
	always_ff @(posedge clk) begin
		if (!local_reset &&
		    prefetch_state == PREFETCH_URGENT_GATHER &&
		    !voice_prefetch_collision_q) begin
			prefetch_urgent_descriptor <= {
				voice_prefetch_data.accum[31:13],
				((voice_prefetch_data.control & CONTROL_STOPMASK) != 0),
				(voice_prefetch_data.accum[12:11] == 2'd3) &&
					(voice_prefetch_data.accum[10:2] != 9'd0),
				voice_prefetch_data.control[15:14],
				(prefetch_row_voice_q <= active_voices_reg) &&
				(((voice_prefetch_data.control & CONTROL_STOPMASK) == 0) ||
				 (prefetch_row_program_q &&
				  ((voice_prefetch_data.control & CONTROL_STOPMASK) != 0))),
				voice_prefetch_data.control[13]
			};
		end
	end

`ifndef VERILATOR
	wire [18:0] sample_cache_tag_write_data =
		(prefetch_state == PREFETCH_INIT) ? 19'd0 :
		{1'b1, prefetch_bank_q, prefetch_line_q[18:3]};

	// One physical 1024x20 M10K shape supplies both registered tag lookups. Port A is
	// the engine read. Port B either reads the prefetch target or performs the
	// init/fill write. The unregistered q setting does not make the RAM
	// asynchronous: each port's address is captured by its M10K input register,
	// preserving the existing one-clock lookup latency. Cross-port RDW is
	// deliberately don't-care because the registered collision flags below
	// reject that result and force a clean miss/retry.
	altsyncram sample_cache_tag_ram
	(
		.clock0          (clk),
		.address_a       (engine_cache_read_addr),
		.data_a          (19'd0),
		.wren_a          (1'b0),
		.rden_a          (1'b1),
		.q_a             (engine_cache_tag_q),

		.clock1          (clk),
		.address_b       (cache_write_we ? cache_write_addr :
		                                  prefetch_target_entry),
		.data_b          (sample_cache_tag_write_data),
		.wren_b          (cache_write_we),
		.rden_b          (!cache_write_we),
		.q_b             (prefetch_cache_tag_q),

		.aclr0           (1'b0),
		.aclr1           (1'b0),
		.addressstall_a  (1'b0),
		.addressstall_b  (1'b0),
		.byteena_a       (1'b1),
		.byteena_b       (1'b1),
		.clocken0        (1'b1),
		.clocken1        (1'b1),
		.clocken2        (1'b1),
		.clocken3        (1'b1),
		.eccstatus       ()
	);
	defparam
		sample_cache_tag_ram.address_reg_b = "CLOCK1",
		sample_cache_tag_ram.clock_enable_input_a = "BYPASS",
		sample_cache_tag_ram.clock_enable_input_b = "BYPASS",
		sample_cache_tag_ram.clock_enable_output_a = "BYPASS",
		sample_cache_tag_ram.clock_enable_output_b = "BYPASS",
		sample_cache_tag_ram.indata_reg_b = "CLOCK1",
		sample_cache_tag_ram.intended_device_family = "Cyclone V",
		sample_cache_tag_ram.lpm_type = "altsyncram",
		sample_cache_tag_ram.numwords_a = SAMPLE_CACHE_ENTRIES,
		sample_cache_tag_ram.numwords_b = SAMPLE_CACHE_ENTRIES,
		sample_cache_tag_ram.operation_mode = "BIDIR_DUAL_PORT",
		sample_cache_tag_ram.outdata_aclr_a = "NONE",
		sample_cache_tag_ram.outdata_aclr_b = "NONE",
		sample_cache_tag_ram.outdata_reg_a = "UNREGISTERED",
		sample_cache_tag_ram.outdata_reg_b = "UNREGISTERED",
		sample_cache_tag_ram.power_up_uninitialized = "FALSE",
		sample_cache_tag_ram.ram_block_type = "M10K",
		sample_cache_tag_ram.rdcontrol_reg_b = "CLOCK1",
		sample_cache_tag_ram.read_during_write_mode_mixed_ports = "DONT_CARE",
		sample_cache_tag_ram.read_during_write_mode_port_a = "DONT_CARE",
		sample_cache_tag_ram.read_during_write_mode_port_b = "DONT_CARE",
		sample_cache_tag_ram.width_a = 19,
		sample_cache_tag_ram.width_b = 19,
		sample_cache_tag_ram.widthad_a = 10,
		sample_cache_tag_ram.widthad_b = 10,
		sample_cache_tag_ram.width_byteena_a = 1,
		sample_cache_tag_ram.width_byteena_b = 1,
		sample_cache_tag_ram.wrcontrol_wraddress_reg_b = "CLOCK1";
`endif

	logic [18:0] work_current_line;
	logic [18:0] work_next_line;
	logic [9:0] work_cache_entry1;
	logic sample_underrun;
	logic scan_underrun;
	logic [31:0] sample_underrun_count;

	logic [31:0] raw_stepped_accum_next;
	logic [31:0] raw_stepped_accum_reg;
	logic [31:0] step_accum_reg;
	logic [31:0] step_boundary_delta_reg;
	logic        step_forward_crossed_reg;
	logic        step_reverse_crossed_reg;
	logic [31:0] stepped_accum_next;
	logic [15:0] stepped_control_next;
	logic [31:0] stepped_accum_reg;
	logic [15:0] stepped_control_reg;
	logic [15:0] envelope_lvol_next;
	logic [15:0] envelope_rvol_next;
	logic [15:0] envelope_k1_next;
	logic [15:0] envelope_k2_next;
	logic [8:0]  envelope_ecount_next;
	logic [2:0]  envelope_filtcnt_next;
	logic [15:0] envelope_lvol_reg;
	logic [15:0] envelope_rvol_reg;
	logic [15:0] envelope_k1_reg;
	logic [15:0] envelope_k2_reg;
	logic [8:0]  envelope_ecount_reg;
	logic [2:0]  envelope_filtcnt_reg;
	// Rev2.3 sections4.10/11.5: a host EC0 accepted after voice capture
	// cancels the four envelope-register updates at writeback. Record the
	// actual host commit, not ordinary count1 expiry. No current-PCM rollback
	// is implied: the already-issued volume pipeline remains unchanged.
	logic        work_envelope_cancel_q;
	logic [6:0] current_page_reg;
	logic [4:0] active_voices_reg;
	logic [7:0] irq_vector_reg;
	// IRQV acknowledges the pin immediately; the causative voice clears its
	// CR.IRQ only when next processed (OTTO Rev2.3, section 14). More than one
	// vector can be acknowledged before earlier voices revisit the pipeline.
	logic [31:0] irq_ack_pending;
	logic [4:0] scan_voice_reg;
	logic [1:0] local_reset_pipe;
	logic       local_reset;

	integer host_read_mux_index;

	// Byte-assembler writes (lanes0-2) and snapshot reads (lanes1-3) do
	// not access the voice file or perform architectural register/IRQ work.
	// Decode the captured host payload, then acknowledge these latch-only
	// accesses from a register without reserving/stalling an engine edge.
	assign host_latch_only = host_write_q ? (host_addr_q[1:0] != 2'd3) :
	                                      (host_addr_q[1:0] != 2'd0);
	assign host_latch_accept = host_req_q && !host_seen && host_latch_only &&
	                           !host_access_pending && !host_write_execute_pending &&
	                           !host_read_select_pending && !host_read_response_pending;

	assign host_pipeline_busy = host_access_pending || host_write_execute_pending ||
	                            host_read_select_pending || host_read_response_pending;
	assign host_arch_request = host_req_q && !host_seen && !host_latch_only &&
	                           !host_pipeline_busy;
	assign host_idle_reserve = host_arch_request && (engine_state == ENGINE_IDLE) &&
	                           (slot_count < (SLOT_LAST - 1'b1));
	assign host_overlap_reserve = host_arch_request && host_overlap_kind &&
	                              host_overlap_window;
	assign host_engine_hold = (host_pipeline_busy && !host_overlap_q) ||
	                          host_idle_reserve;
	// Register writes retain the normal host acknowledgement schedule.  A
	// STOP-to-RUN transition merely points the existing urgent scanner at the
	// affected voice; the per-voice pending mask still preserves simultaneous
	// starts, and a held external sample request is never interrupted.
	assign start_prefetch_hint = host_write_execute_pending &&
		(host_write_low_page_q || host_write_voice_page_q) &&
		host_write_slot_select_q[0] &&
		((voice_engine_data.control & CONTROL_STOPMASK) != 0) &&
		((host_write_value_q[15:0] & CONTROL_STOPMASK) == 0);

	// Once LAUNCH captures its row, the DSP uses work_* until writeback. The
	// same registered read port can service a DIFFERENT voice in that interval.
	// Limit overlap to side-effect-free low-page reads and envelope writes.
	// The only same-voice exception is a complete EC0 write: it cancels the
	// pending envelope-register update without replacing other captured fields.
	// All other same-voice accesses, IRQV, PAGE and globals keep boundary order.
	always_comb begin
		host_overlap_kind = 1'b0;
		if ((host_page_q < 7'h20) && (host_page_q[4:0] != work_voice)) begin
			if (host_write_q) begin
				case (host_addr_q[5:2])
					4'd3, 4'd5, 4'd6: host_overlap_kind = 1'b1;
					default: ;
				endcase
			end else begin
				case (host_addr_q[5:2])
					4'd0, 4'd2, 4'd4, 4'd6: host_overlap_kind = 1'b1;
					default: ;
				endcase
			end
		end
		if ((host_page_q < 7'h20) && (host_page_q[4:0] == work_voice) &&
		    host_write_q && (host_addr_q == 6'h1b) &&
		    !write_latch[8] && (host_wdata_q == 8'd0))
			host_overlap_kind = 1'b1;

		// A reservation at POLE4_APPLY writes its row at A+2 or snapshots a
		// read at A+3. DSP COMMIT/STOPPED is A+4, so neither port ownership
		// nor its single write can collide. Keep an explicit state whitelist.
		host_overlap_window = 1'b0;
		case (engine_state)
			ENGINE_DECODE, ENGINE_STEP_DECIDE, ENGINE_STEP_FINISH,
			ENGINE_INTERP_PREP, ENGINE_INTERP_MUL, ENGINE_INTERP_SUM,
			ENGINE_POLE1_PREP, ENGINE_POLE1_MUL, ENGINE_POLE1_FINISH,
			ENGINE_POLE2_PREP, ENGINE_POLE2_MUL, ENGINE_POLE2_FINISH,
			ENGINE_POLE3_PREP, ENGINE_POLE3_MUL, ENGINE_POLE3_FINISH,
			ENGINE_POLE4_PREP, ENGINE_POLE4_MUL, ENGINE_POLE4_FINISH,
			ENGINE_POLE4_APPLY: host_overlap_window = 1'b1;
			default: ;
		endcase
	end

	function automatic voice_state_t reset_voice_state;
		voice_state_t state;
		begin
			state = '0;
			state.control = CONTROL_STOPMASK;
			state.lvol = 16'h8000;
			state.rvol = 16'h8000;
			reset_voice_state = state;
		end
	endfunction

`ifdef VERILATOR
	// Narrow test observability without restoring an asynchronous synthesis read
	// port to the voice RAM.
	wire [31:0] debug_voice0_accum = voice_state_valid[0]
		? voice_state_engine_mem[0].accum : 32'd0;
	wire [15:0] debug_voice0_control = voice_state_valid[0]
		? voice_state_engine_mem[0].control : CONTROL_STOPMASK;
`endif

	function automatic signed [15:0] decode_ulaw(input logic [15:0] code);
		logic [15:0] raw_value;
		logic [15:0] mantissa;
		logic [2:0]  exponent;
		logic signed [15:0] signed_mantissa;
		logic signed [31:0] extended_mantissa;
		logic signed [31:0] decoded_value;
		begin
			// OTTO consumes every sample-bus bit, even in compressed mode.
			// Narrow-ROM wiring, not the chip, supplies unused low zero bits
			// (Rev2.3 section 11.2). Do not inject an emulator midpoint bias.
			raw_value = code;
			exponent = raw_value[15:13];
			mantissa = raw_value << 3;
			if (exponent == 0) begin
				signed_mantissa = mantissa;
				extended_mantissa = {{16{signed_mantissa[15]}}, signed_mantissa};
				decoded_value = extended_mantissa >>> 7;
			end else begin
				mantissa = (mantissa >> 1) | ((~mantissa) & 16'h8000);
				signed_mantissa = mantissa;
				extended_mantissa = {{16{signed_mantissa[15]}}, signed_mantissa};
				decoded_value = extended_mantissa >>> (7 - exponent);
			end
			decode_ulaw = decoded_value[15:0];
		end
	endfunction

	function automatic logic [15:0] sample_line_word(
		input logic [63:0] line_data,
		input logic [1:0]  word_index
	);
		begin
			case (word_index)
				2'd0: sample_line_word = line_data[15:0];
				2'd1: sample_line_word = line_data[31:16];
				2'd2: sample_line_word = line_data[47:32];
				default: sample_line_word = line_data[63:48];
			endcase
		end
	endfunction

	function automatic signed [17:0] interpolation_finish(
		input logic signed [26:0] product0,
		input logic signed [26:0] product1
	);
		logic signed [27:0] total;
		begin
			total = product0 + product1;
			// Nine interpolation fraction bits; retain one output fraction bit.
			interpolation_finish = 18'(total >>> 8);
		end
	endfunction

	function automatic signed [26:0] interpolation_multiply(
		input logic signed [15:0] sample,
		input logic [9:0] weight
	);
		logic signed [10:0] signed_weight;
		begin
			signed_weight = {1'b0, weight};
			interpolation_multiply = sample * signed_weight;
		end
	endfunction

	function automatic signed [28:0] filter_multiply_high(
		input logic signed [15:0] operand_high,
		input logic [11:0] cutoff
	);
		logic signed [12:0] signed_cutoff;
		begin
			signed_cutoff = {1'b0, cutoff};
			filter_multiply_high = operand_high * signed_cutoff;
		end
	endfunction

	function automatic [27:0] filter_multiply_low(
		input logic [15:0] operand_low,
		input logic [11:0] cutoff
	);
		begin
			filter_multiply_low = operand_low * cutoff;
		end
	endfunction

	function automatic signed [31:0] lowpass_finish(
		input logic signed [47:0] product,
		input logic signed [31:0] history
	);
		logic signed [47:0] quotient;
		begin
			quotient = product / 48'sd4096;
			lowpass_finish = $signed(quotient[31:0]) + history;
		end
	endfunction

	function automatic signed [31:0] highpass_finish(
		input logic signed [47:0] product,
		input logic signed [31:0] sample,
		input logic signed [31:0] history,
		input logic signed [31:0] previous
	);
		logic signed [47:0] quotient;
		logic signed [31:0] scaled;
		begin
			quotient = product / 48'sd8192;
			scaled = quotient[31:0];
			highpass_finish = sample - previous + scaled + (history / 32'sd2);
		end
	endfunction

	function automatic signed [31:0] lowpass_apply(
		input logic signed [47:0] quotient,
		input logic signed [31:0] history
	);
		begin
			lowpass_apply = $signed(quotient[31:0]) + history;
		end
	endfunction

	function automatic signed [31:0] highpass_apply(
		input logic signed [47:0] quotient,
		input logic signed [31:0] sample,
		input logic signed [31:0] history,
		input logic signed [31:0] previous
	);
		logic signed [31:0] scaled;
		begin
			scaled = quotient[31:0];
			highpass_apply = sample - previous + scaled + (history / 32'sd2);
		end
	endfunction

	function automatic [15:0] ramp_value(
		input logic [15:0] value,
		input logic [7:0] ramp
	);
		logic signed [17:0] sum;
		begin
			if (ramp == 0) begin
				ramp_value = value;
			end else begin
				sum = $signed({1'b0, value}) + $signed({{10{ramp[7]}}, ramp});
				if (sum < 0)
					ramp_value = 16'h0000;
				else if (sum > 18'sd65535)
					ramp_value = 16'hffff;
				else
					ramp_value = sum[15:0];
			end
		end
	endfunction

	function automatic [8:0] volume_mantissa(input logic [15:0] volume);
		begin
			volume_mantissa = {1'b1, volume[11:4]};
		end
	endfunction

	function automatic signed [41:0] volume_multiply(
		input logic signed [31:0] sample,
		input logic [8:0] gain
	);
		logic signed [9:0] signed_gain;
		begin
			signed_gain = {1'b0, gain};
			volume_multiply = sample * signed_gain;
		end
	endfunction

	function automatic signed [31:0] volume_finish(
		input logic signed [41:0] product,
		input logic [3:0] exponent
	);
		begin
			volume_finish = 32'(product >>> (5'd20 - {1'b0, exponent}));
		end
	endfunction

	function automatic signed [19:0] clamp_20(input logic signed [31:0] sample);
		begin
			if (sample > 32'sd524287)
				clamp_20 = 20'sh7ffff;
			else if (sample < -32'sd524288)
				clamp_20 = 20'sh80000;
			else
				clamp_20 = sample[19:0];
		end
	endfunction

	assign current_page = current_page_reg;
	assign active_voices = active_voices_reg;
	assign irq_vector = irq_vector_reg;
	assign scan_voice = scan_voice_reg;
	assign engine_busy = (engine_state != ENGINE_IDLE);
	assign audio_left = $signed(audio_left_channels[19:0]);
	assign audio_right = $signed(audio_right_channels[19:0]);
	assign engine_terminal = (engine_state == ENGINE_COMMIT) ||
	                         (engine_state == ENGINE_STOPPED) ||
	                         (engine_state == ENGINE_UNDERRUN);
	always_comb begin
		terminal_input_left = 23'sd0;
		terminal_input_right = 23'sd0;
		if (engine_state == ENGINE_COMMIT) begin
			terminal_input_left = 23'(voice_mix_left_reg);
			terminal_input_right = 23'(voice_mix_right_reg);
		end
		// The documented store is23 bits. Arithmetic outside that guard range
		// wraps to its width; final20-bit clipping is per channel, never before
		// summation. Extreme23-bit overflow remains an explicit interpretation.
		terminal_sum_left = work_mix_left + terminal_input_left;
		terminal_sum_right = work_mix_right + terminal_input_right;
	end

	genvar channel_index;
	generate
	for (channel_index = 0; channel_index < 6; channel_index = channel_index + 1) begin : channel_output
		always_ff @(posedge clk) begin
			if (local_reset) begin
				channel_mix_left[channel_index] <= 23'sd0;
				channel_mix_right[channel_index] <= 23'sd0;
				audio_left_channels[channel_index*20 +: 20] <= 20'sd0;
				audio_right_channels[channel_index*20 +: 20] <= 20'sd0;
			end else begin
				// PAGE40 writes the same accumulator used by voice processing.
				// No undocumented test-mode freeze is invented. A write after
				// voice0's clear reaches the next full-scan output, then clears
				// normally on the following scan. Write/clear phase is defined
				// by this FPGA's serialized host interface, not silicon pin timing.
				if (host_write_execute_pending && host_write_test_page_q &&
				    host_write_slot_select_q[channel_index*2])
					channel_mix_left[channel_index] <= $signed(host_write_value_q[22:0]);
				else if ((host_write_execute_pending && host_write_low_page_q &&
				          host_write_slot_select_q[11]) ||
				         ((engine_state == ENGINE_LAUNCH) && (work_voice == 0)))
					channel_mix_left[channel_index] <= 23'sd0;
				else if (engine_terminal && work_channel_select[channel_index])
					channel_mix_left[channel_index] <= terminal_sum_left;

				if (host_write_execute_pending && host_write_test_page_q &&
				    host_write_slot_select_q[channel_index*2+1])
					channel_mix_right[channel_index] <= $signed(host_write_value_q[22:0]);
				else if ((host_write_execute_pending && host_write_low_page_q &&
				          host_write_slot_select_q[11]) ||
				         ((engine_state == ENGINE_LAUNCH) && (work_voice == 0)))
					channel_mix_right[channel_index] <= 23'sd0;
				else if (engine_terminal && work_channel_select[channel_index])
					channel_mix_right[channel_index] <= terminal_sum_right;

				if (engine_terminal && (work_voice == active_voices_reg)) begin
					audio_left_channels[channel_index*20 +: 20] <= clamp_20(32'(
						work_channel_select[channel_index] ? terminal_sum_left :
						channel_mix_left[channel_index]));
					audio_right_channels[channel_index*20 +: 20] <= clamp_20(32'(
						work_channel_select[channel_index] ? terminal_sum_right :
						channel_mix_right[channel_index]));
				end
			end
		end
	end
	endgenerate

`ifndef SYNTHESIS
	// SLOT_TICKS counts ce_16m pulses, while the engine consumes fabric clocks.
	// The native core has47 or48 fabric clocks per voice slot; accelerated TBs must
	// still leave at least T0..T28. Saturating at a due slot while any engine
	// or host micro-pipeline is active would silently stretch device time.
	always_ff @(posedge clk) begin
		if (!local_reset && ce_16m &&
		    (slot_count == SLOT_LAST) &&
		    ((engine_state != ENGINE_IDLE) || host_access_pending ||
		     host_write_execute_pending || host_read_select_pending ||
		     host_read_response_pending))
			$fatal(1, "ES5506 slot deadline missed; ce/SLOT_TICKS budget is unsupported");
	end
`endif

	always_comb begin
		case (host_addr_q[1:0])
			2'd0: assembled_write = {host_wdata_q, write_latch[23:0]};
			2'd1: assembled_write = {write_latch[31:24], host_wdata_q,
				write_latch[15:0]};
			2'd2: assembled_write = {write_latch[31:16], host_wdata_q,
				write_latch[7:0]};
			default: assembled_write = {write_latch[31:8], host_wdata_q};
		endcase
	end

	always_comb begin
		filter_product_combined =
			($signed({{19{filter_product_high_reg[28]}},
			          filter_product_high_reg}) <<< 16) +
			$signed({20'd0, filter_product_low_reg});
	end

	// A lane-zero read uses an idle reservation or the bounded other-voice
	// window. The row snapshot is followed by a one-hot slot
	// selection, avoiding a binary 16-way decoder on the read-latch input.
	// Later byte lanes return that same atomic latch, including accumulator and
	// IRQ state.
	always_comb begin
		for (host_read_mux_index = 0; host_read_mux_index < 16;
		     host_read_mux_index = host_read_mux_index + 1)
			host_read_slot_value[host_read_mux_index] = 32'd0;

		if (host_read_low_page_q) begin
			host_read_slot_value[0] = {16'd0, host_read_control_q};
			host_read_slot_value[1] = {15'd0, host_read_freq_q};
			host_read_slot_value[2] = {16'd0, host_read_lvol_q};
			host_read_slot_value[3] = {16'd0, host_read_lvramp_q, 8'd0};
			host_read_slot_value[4] = {16'd0, host_read_rvol_q};
			host_read_slot_value[5] = {16'd0, host_read_rvramp_q, 8'd0};
			host_read_slot_value[6] = {23'd0, host_read_ecount_q};
			host_read_slot_value[7] = {16'd0, host_read_k2_q};
			host_read_slot_value[8] = {16'd0, host_read_k2ramp_q[7:0],
			                                  7'd0, host_read_k2ramp_q[8]};
			host_read_slot_value[9] = {16'd0, host_read_k1_q};
			host_read_slot_value[10] = {16'd0, host_read_k1ramp_q[7:0],
			                                   7'd0, host_read_k1ramp_q[8]};
			host_read_slot_value[11] = {27'd0, host_read_active_q};
			host_read_slot_value[12] = {27'd0, host_read_mode_q};
		end else if (host_read_voice_page_q) begin
			host_read_slot_value[0] = {16'd0, host_read_control_q};
			host_read_slot_value[1] = host_read_start_q;
			host_read_slot_value[2] = host_read_end_q;
			host_read_slot_value[3] = host_read_accum_q;
			host_read_slot_value[4] = {14'd0, host_read_o4n1_q};
			host_read_slot_value[5] = {14'd0, host_read_o3n1_q};
			host_read_slot_value[6] = {14'd0, host_read_o3n2_q};
			host_read_slot_value[7] = {14'd0, host_read_o2n1_q};
			host_read_slot_value[8] = {14'd0, host_read_o2n2_q};
			host_read_slot_value[9] = {14'd0, host_read_o1n1_q};
			host_read_slot_value[10] = {25'd0, host_read_w_st_q};
			host_read_slot_value[11] = {25'd0, host_read_w_end_q};
			host_read_slot_value[12] = {25'd0, host_read_lr_end_q};
		end

		host_read_slot_value[13] = {22'd0, host_read_par_q};
		host_read_slot_value[14] = {24'd0, host_read_irq_vector_q};
		host_read_slot_value[15] = {25'd0, host_read_page_q};

		register_read_value = 32'd0;
		for (host_read_mux_index = 0; host_read_mux_index < 16;
		     host_read_mux_index = host_read_mux_index + 1)
			register_read_value = register_read_value |
				(host_read_slot_value[host_read_mux_index] &
				 {32{host_read_slot_select_q[host_read_mux_index]}});
	end

	assign sample_req       = (prefetch_state == PREFETCH_FETCH);
	assign sample_bank      = prefetch_bank_q;
	assign sample_addr      = {prefetch_line_q, prefetch_word_q, 1'b0};
	assign sample_companded = prefetch_companded_q;
	assign sample_voice     = prefetch_voice_q;
	assign work_current_line = work_accum[31:13];
	assign work_next_line = work_current_line + 19'd1;
	assign work_cache_entry1 = {
		work_voice, work_control[15:14], work_next_line[2:0]
	};
	assign engine_sample_miss = (engine_state == ENGINE_CACHE_SELECT1) &&
		((work_control & CONTROL_STOPMASK) == 0) &&
		(!engine_cache_first_hit_q ||
		 ((work_accum[12:11] == 2'd3) &&
		  (work_accum[10:2] != 9'd0) &&
		  (!cache_initialized || engine_cache_collision_q ||
		   !engine_cache_tag_q[18] ||
		   (engine_cache_tag_q[17:16] != work_control[15:14]) ||
		   (engine_cache_tag_q[15:0] != work_next_line[18:3]))));
	assign cache_fill_we = (prefetch_state == PREFETCH_FETCH) && sample_ack &&
	                       (prefetch_word_q == 2'd3);
	assign cache_write_we = (prefetch_state == PREFETCH_INIT) || cache_fill_we;
	assign cache_write_addr = (prefetch_state == PREFETCH_INIT) ?
	                          prefetch_init_addr : prefetch_entry_q;
	// A power-of-two per-voice mapping makes both the background tag lookup and
	// the engine RAM address simple concatenations.  Forward playback keeps the
	// current through current+7 qwords; reverse playback keeps current, the +1
	// interpolation line, and six preceding qwords.
	always_comb begin
		prefetch_scan_line = voice_prefetch_data.accum[31:13];
		prefetch_scan_bank = voice_prefetch_data.control[15:14];
		prefetch_scan_running =
			(prefetch_scan_voice <= active_voices_reg) &&
			((voice_prefetch_data.control & CONTROL_STOPMASK) == 0);

		if (prefetch_urgent_mode_q)
			prefetch_target_line = prefetch_base_line_q +
			                       {{18{1'b0}}, prefetch_urgent_upper_q};
		else if (!prefetch_direction_q)
			prefetch_target_line = prefetch_base_line_q +
			                       {{16{1'b0}}, prefetch_target_index};
		else begin
			case (prefetch_target_index)
				3'd0: prefetch_target_line = prefetch_base_line_q;
				3'd1: prefetch_target_line = prefetch_base_line_q + 19'd1;
				default: prefetch_target_line = prefetch_base_line_q -
				                                {16'd0,
				                                 (prefetch_target_index - 3'd1)};
			endcase
		end

		prefetch_target_entry = {prefetch_voice_q, prefetch_bank_q,
		                         prefetch_target_line[2:0]};
		prefetch_target_hit = !prefetch_cache_collision_q &&
			prefetch_cache_tag_q[18] &&
			(prefetch_cache_tag_q[17:16] == prefetch_bank_q) &&
			(prefetch_cache_tag_q[15:0] == prefetch_line_q[18:3]);
	end

	assign prefetch_program_pair_complete = prefetch_program_mode_q &&
		(((prefetch_state == PREFETCH_LOOKUP) && prefetch_target_hit &&
		  (prefetch_urgent_upper_q || !prefetch_urgent_need_upper_q)) ||
		 ((prefetch_state == PREFETCH_FETCH) && sample_ack &&
		  (prefetch_word_q == 2'd3) &&
		  (prefetch_urgent_upper_q || !prefetch_urgent_need_upper_q)));
	assign prefetch_program_drop =
		(prefetch_state == PREFETCH_URGENT_SELECT) &&
		prefetch_row_program_q &&
		(!prefetch_urgent_descriptor[5] || !prefetch_urgent_descriptor[1]);

	// Urgent hints are architectural landing points, never raw START/END
	// guesses: loop correction has already resolved overshoot in
	// stepped_accum_reg. Host writes that can alter the current landing mark
	// their voice, and ACTV writes rescan every voice. Set wins over a same-edge
	// clear so a newer host/loop landing cannot be lost.
	always_comb begin
		prefetch_urgent_set_mask = 32'd0;
		prefetch_program_set_mask = 32'd0;
		// A committed high-page ACCUM write supplies the exact first sample
		// address. The eventual bank is deliberately not guessed here.
		if (ENABLE_PROGRAM_PREWARM && host_write_execute_pending &&
		    host_write_voice_page_q &&
		    host_write_slot_select_q[3])
			prefetch_program_set_mask = host_write_voice_select_q;
		if ((engine_state == ENGINE_COMMIT) &&
		    (step_forward_crossed_reg || step_reverse_crossed_reg))
			prefetch_urgent_set_mask = work_voice_select;
		// Raise the refill hint at the registered miss decision. Waiting for the
		// padded underrun terminal would waste the rest of this voice slot.
		if (engine_sample_miss)
			prefetch_urgent_set_mask = prefetch_urgent_set_mask |
			                           work_voice_select;
		if (host_write_execute_pending && host_write_voice_page_q &&
		    (host_write_slot_select_q[0] || host_write_slot_select_q[1] ||
		     host_write_slot_select_q[2] || host_write_slot_select_q[3]))
			prefetch_urgent_set_mask = prefetch_urgent_set_mask |
			                           host_write_voice_select_q;
		if (host_write_execute_pending && host_write_low_page_q &&
		    host_write_slot_select_q[0])
			prefetch_urgent_set_mask = prefetch_urgent_set_mask |
			                           host_write_voice_select_q;
		if (host_write_execute_pending && host_write_low_page_q &&
		    host_write_slot_select_q[11])
			prefetch_urgent_set_mask = 32'hffff_ffff;

		prefetch_urgent_dispatch =
			(prefetch_state == PREFETCH_SCAN) &&
			prefetch_urgent_pending[prefetch_urgent_scan_voice] &&
			!(|prefetch_urgent_set_mask);
		prefetch_program_dispatch =
			(prefetch_state == PREFETCH_SCAN) &&
			!(|prefetch_urgent_pending) &&
			prefetch_program_pending[prefetch_urgent_scan_voice] &&
			!(|prefetch_urgent_set_mask) &&
			!(|prefetch_program_set_mask);
		prefetch_urgent_clear_mask = 32'd0;
		if (prefetch_urgent_dispatch)
			prefetch_urgent_clear_mask = 32'b1 << prefetch_urgent_scan_voice;

		prefetch_program_clear_mask = 32'd0;
		if (prefetch_program_drop ||
		    (prefetch_program_pair_complete && (prefetch_bank_q == 2'd3)))
			prefetch_program_clear_mask = 32'b1 << prefetch_voice_q;

		prefetch_program_bank_bit0_next = prefetch_program_bank_bit0;
		prefetch_program_bank_bit1_next = prefetch_program_bank_bit1;
		if (prefetch_program_pair_complete && (prefetch_bank_q != 2'd3)) begin
			prefetch_program_bank_bit0_next =
				(prefetch_program_bank_bit0_next &
				 ~(32'b1 << prefetch_voice_q)) |
				({32{~prefetch_bank_q[0]}} & (32'b1 << prefetch_voice_q));
			prefetch_program_bank_bit1_next =
				(prefetch_program_bank_bit1_next &
				 ~(32'b1 << prefetch_voice_q)) |
				({32{prefetch_bank_q[1] ^ prefetch_bank_q[0]}} &
				 (32'b1 << prefetch_voice_q));
		end
		// A newer ACCUM write restarts that voice at bank0 and wins over a
		// same-edge completion of an older prewarm request.
		prefetch_program_bank_bit0_next =
			prefetch_program_bank_bit0_next & ~prefetch_program_set_mask;
		prefetch_program_bank_bit1_next =
			prefetch_program_bank_bit1_next & ~prefetch_program_set_mask;
	end

	always_ff @(posedge clk) begin
		if (local_reset) begin
			prefetch_urgent_pending <= 32'd0;
			prefetch_program_pending <= 32'd0;
			prefetch_program_bank_bit0 <= 32'd0;
			prefetch_program_bank_bit1 <= 32'd0;
		end else begin
			prefetch_urgent_pending <=
				(prefetch_urgent_pending & ~prefetch_urgent_clear_mask) |
				prefetch_urgent_set_mask;
			prefetch_program_pending <=
				(prefetch_program_pending & ~prefetch_program_clear_mask) |
				prefetch_program_set_mask;
			prefetch_program_bank_bit0 <= prefetch_program_bank_bit0_next;
			prefetch_program_bank_bit1 <= prefetch_program_bank_bit1_next;
		end
	end

	// Envelope arithmetic is independent of the filter result.  Running
	// voices capture it in ENGINE_DECODE and use the updated L/R volumes for
	// this sample, while updated K1/K2 take effect on the next sample. Stopped
	// voices capture and commit the same envelope pipeline, with muted output.
	always_comb begin
		envelope_lvol_next = work_lvol;
		envelope_rvol_next = work_rvol;
		envelope_k1_next = work_k1;
		envelope_k2_next = work_k2;
		envelope_ecount_next = work_ecount;
		// Rev2.3 section11.5 increments FILTCOUNT outside the ECOUNT gate.
		// Retain the free-running divide-by-eight phase across zero ECOUNT
		// and host ECOUNT writes; only its low three bits are needed.
		envelope_filtcnt_next = work_filtcnt + 3'd1;
		if (work_ecount != 0) begin
			envelope_ecount_next = work_ecount - 9'd1;
			envelope_lvol_next = ramp_value(work_lvol, work_lvramp);
			envelope_rvol_next = ramp_value(work_rvol, work_rvramp);
			if (!work_k1ramp[8] || (work_filtcnt[2:0] == 0))
				envelope_k1_next = ramp_value(work_k1, work_k1ramp[7:0]);
			if (!work_k2ramp[8] || (work_filtcnt[2:0] == 0))
				envelope_k2_next = ramp_value(work_k2, work_k2ramp[7:0]);
		end
	end

	// Register the raw accumulator step before boundary handling.  Besides
	// keeping DIR -> add/sub -> compare -> loop correction out of one fabric
	// cycle, this preserves the exact strict >END/<START transform order.
	always_comb begin
		if ((work_control & CONTROL_STOPMASK) != 0)
			raw_stepped_accum_next = work_accum;
		else if ((work_control & CONTROL_DIR) != 0)
			raw_stepped_accum_next = work_accum - {15'd0, work_freq};
		else
			raw_stepped_accum_next = work_accum + {15'd0, work_freq};
	end

	always_comb begin
		stepped_accum_next = step_accum_reg;
		stepped_control_next = work_control;
		if (step_forward_crossed_reg) begin
				if ((work_control & CONTROL_IRQE) != 0)
					stepped_control_next = stepped_control_next | CONTROL_IRQ;
				case (work_control & CONTROL_LOOPMASK)
					16'h0000: stepped_control_next = stepped_control_next | 16'h0001;
					CONTROL_LPE:
						stepped_accum_next = work_start
						                     + step_boundary_delta_reg;
					CONTROL_BLE: begin
						stepped_accum_next = work_start
						                     + step_boundary_delta_reg;
						stepped_control_next =
							(stepped_control_next & ~CONTROL_LOOPMASK) | CONTROL_LEI;
					end
					default: begin
						stepped_accum_next = work_end
						                     - step_boundary_delta_reg;
						stepped_control_next = stepped_control_next ^ CONTROL_DIR;
					end
				endcase
		end else if (step_reverse_crossed_reg) begin
				if ((work_control & CONTROL_IRQE) != 0)
					stepped_control_next = stepped_control_next | CONTROL_IRQ;
				case (work_control & CONTROL_LOOPMASK)
					16'h0000: stepped_control_next = stepped_control_next | 16'h0001;
					CONTROL_LPE:
						stepped_accum_next = work_end
						                     - step_boundary_delta_reg;
					CONTROL_BLE: begin
						stepped_accum_next = work_end
						                     - step_boundary_delta_reg;
						stepped_control_next =
							(stepped_control_next & ~CONTROL_LOOPMASK) | CONTROL_LEI;
					end
					default: begin
						stepped_accum_next = work_start
						                     + step_boundary_delta_reg;
						stepped_control_next = stepped_control_next ^ CONTROL_DIR;
					end
				endcase
		end
	end

	// The platform reset includes HPS download decode and fans across the whole
	// core.  Assert locally without delay, then release on two ES fabric clocks
	// so that reset does not sit in every voice-file write-enable cone.
	always_ff @(posedge clk or posedge reset) begin
		if (reset)
			local_reset_pipe <= 2'b11;
		else
			local_reset_pipe <= {local_reset_pipe[0], 1'b0};
	end
	assign local_reset = local_reset_pipe[1];

	// Engine LAUNCH and host row reads share one registered port. A bounded
	// qualified host access may borrow it after LAUNCH and releases it before
	// writeback; other host accesses reserve ENGINE_IDLE. The prefetcher
	// owns the second physical replica and scans concurrently with audio.
	always_comb begin
		voice_engine_read_addr = scan_voice_reg;
		if (host_access_pending || host_write_execute_pending ||
		    host_read_select_pending || host_read_response_pending)
			voice_engine_read_addr = host_page_q[4:0];

		voice_prefetch_read_addr = prefetch_scan_voice;
		if (prefetch_urgent_dispatch || prefetch_program_dispatch)
			voice_prefetch_read_addr = prefetch_urgent_scan_voice;
		else if ((prefetch_state == PREFETCH_ROW_READY) ||
		         (prefetch_state == PREFETCH_URGENT_GATHER))
			voice_prefetch_read_addr = prefetch_row_voice_q;

		voice_engine_data = voice_engine_valid_q ? voice_engine_q :
			reset_voice_state();
		voice_prefetch_data = voice_prefetch_valid_q ? voice_prefetch_q :
			reset_voice_state();

		voice_write_en = 1'b0;
		voice_write_addr = work_voice;
		voice_write_data = reset_voice_state();
		voice_write_data.control = work_control;
		voice_write_data.freq = work_freq;
		voice_write_data.start_addr = work_start;
		voice_write_data.end_addr = work_end;
		voice_write_data.accum = work_accum;
		voice_write_data.lvol = work_lvol;
		voice_write_data.rvol = work_rvol;
		voice_write_data.lvramp = work_lvramp;
		voice_write_data.rvramp = work_rvramp;
		voice_write_data.ecount = work_ecount;
		voice_write_data.k1 = work_k1;
		voice_write_data.k2 = work_k2;
		voice_write_data.k1ramp = work_k1ramp;
		voice_write_data.k2ramp = work_k2ramp;
		voice_write_data.filtcnt = work_filtcnt;
		voice_write_data.o1n1 = work_o1n1;
		voice_write_data.o2n1 = work_o2n1;
		voice_write_data.o2n2 = work_o2n2;
		voice_write_data.o3n1 = work_o3n1;
		voice_write_data.o3n2 = work_o3n2;
		voice_write_data.o4n1 = work_o4n1;

		if (host_write_execute_pending &&
		    (host_write_low_page_q || host_write_voice_page_q)) begin
			voice_write_en = 1'b1;
			voice_write_addr = host_page_q[4:0];
			voice_write_data = voice_engine_data;
			if (host_write_low_page_q) begin
				if (host_write_slot_select_q[0])
					voice_write_data.control = host_write_value_q[15:0];
				if (host_write_slot_select_q[1])
					voice_write_data.freq = host_write_value_q[16:0];
				if (host_write_slot_select_q[2])
					voice_write_data.lvol = host_write_value_q[15:0];
				if (host_write_slot_select_q[3])
					voice_write_data.lvramp = host_write_value_q[15:8];
				if (host_write_slot_select_q[4])
					voice_write_data.rvol = host_write_value_q[15:0];
				if (host_write_slot_select_q[5])
					voice_write_data.rvramp = host_write_value_q[15:8];
				if (host_write_slot_select_q[6])
					voice_write_data.ecount = host_write_value_q[8:0];
				if (host_write_slot_select_q[7])
					voice_write_data.k2 = host_write_value_q[15:0];
				if (host_write_slot_select_q[8])
					voice_write_data.k2ramp =
						{host_write_value_q[0], host_write_value_q[15:8]};
				if (host_write_slot_select_q[9])
					voice_write_data.k1 = host_write_value_q[15:0];
				if (host_write_slot_select_q[10])
					voice_write_data.k1ramp =
						{host_write_value_q[0], host_write_value_q[15:8]};
			end else begin
				if (host_write_slot_select_q[0])
					voice_write_data.control = host_write_value_q[15:0];
				if (host_write_slot_select_q[1])
					voice_write_data.start_addr =
						host_write_value_q & 32'hfffff800;
				if (host_write_slot_select_q[2])
					voice_write_data.end_addr =
						host_write_value_q & 32'hffffff80;
				if (host_write_slot_select_q[3])
					voice_write_data.accum = host_write_value_q;
				if (host_write_slot_select_q[4])
					voice_write_data.o4n1 =
						{{14{host_write_value_q[17]}}, host_write_value_q[17:0]};
				if (host_write_slot_select_q[5])
					voice_write_data.o3n1 =
						{{14{host_write_value_q[17]}}, host_write_value_q[17:0]};
				if (host_write_slot_select_q[6])
					voice_write_data.o3n2 =
						{{14{host_write_value_q[17]}}, host_write_value_q[17:0]};
				if (host_write_slot_select_q[7])
					voice_write_data.o2n1 =
						{{14{host_write_value_q[17]}}, host_write_value_q[17:0]};
				if (host_write_slot_select_q[8])
					voice_write_data.o2n2 =
						{{14{host_write_value_q[17]}}, host_write_value_q[17:0]};
				if (host_write_slot_select_q[9])
					voice_write_data.o1n1 =
						{{14{host_write_value_q[17]}}, host_write_value_q[17:0]};
			end
		end else if (engine_state == ENGINE_COMMIT || engine_state == ENGINE_STOPPED) begin
			voice_write_en = 1'b1;
			voice_write_data.accum = stepped_accum_reg;
			// No other same-voice field write is admitted before this terminal,
			// so the captured values are the four register values to retain.
			voice_write_data.lvol = work_envelope_cancel_q ? work_lvol : envelope_lvol_reg;
			voice_write_data.rvol = work_envelope_cancel_q ? work_rvol : envelope_rvol_reg;
			voice_write_data.k1 = work_envelope_cancel_q ? work_k1 : envelope_k1_reg;
			voice_write_data.k2 = work_envelope_cancel_q ? work_k2 : envelope_k2_reg;
			voice_write_data.ecount = work_envelope_cancel_q ? 9'd0 : envelope_ecount_reg;
			voice_write_data.filtcnt = envelope_filtcnt_reg;
			voice_write_data.o1n1 = filter_pole1_reg;
			voice_write_data.o2n2 = work_o2n1;
			voice_write_data.o2n1 = filter_pole2_reg;
			voice_write_data.o3n2 = work_o3n1;
			voice_write_data.o3n1 = filter_pole3_reg;
			voice_write_data.o4n1 = filter_pole4_reg;
			voice_write_data.control = stepped_control_reg;
		end
	end

	// Canonical synchronous simple-dual-port inference for both replicas.
	// Engine/host ownership separates their row reads from writes. The concurrent
	// prefetch port explicitly rejects a mixed-port collision and rereads its
	// held address; correctness must not depend on simulation's old-data result.
	always_ff @(posedge clk) begin
		voice_engine_q <= voice_state_engine_mem[voice_engine_read_addr];
		voice_prefetch_q <= voice_state_prefetch_mem[voice_prefetch_read_addr];
		if (!local_reset && voice_write_en) begin
			voice_state_engine_mem[voice_write_addr] <= voice_write_data;
			voice_state_prefetch_mem[voice_write_addr] <= voice_write_data;
		end
	end

	always_ff @(posedge clk) begin
		if (local_reset) begin
			voice_state_valid <= 32'd0;
			voice_engine_valid_q <= 1'b0;
			voice_prefetch_valid_q <= 1'b0;
			voice_prefetch_collision_q <= 1'b0;
		end else begin
			voice_engine_valid_q <= voice_state_valid[voice_engine_read_addr];
			voice_prefetch_valid_q <= voice_state_valid[voice_prefetch_read_addr];
			voice_prefetch_collision_q <= voice_write_en &&
				(voice_write_addr == voice_prefetch_read_addr);
			if (voice_write_en)
				voice_state_valid[voice_write_addr] <= 1'b1;
		end
	end

	// The payload RAM has a registered engine read and a fill-only write port.
	// The tag RAM has the matching engine read plus the prefetch read/write
	// port. A fill updates both arrays on the same edge; initialization clears
	// only tag validity, so payload contents are never architecturally observed
	// until their tag is valid. Cyclone V cross-port read-during-write is
	// undefined, so registered collision flags travel with both lookup results
	// and force a clean miss. no_rw_check can therefore remove pass-through
	// logic without making correctness depend on the undefined RAM output.
	always_ff @(posedge clk) begin
		if (local_reset) begin
			engine_cache_data_q <= 64'd0;
`ifdef VERILATOR
			engine_cache_tag_q <= 19'd0;
`endif
			engine_cache_collision_q <= 1'b0;
`ifdef VERILATOR
			prefetch_cache_tag_q <= 19'd0;
`endif
			prefetch_cache_collision_q <= 1'b0;
		end else begin
			engine_cache_data_q <= sample_cache_data_mem[engine_cache_read_addr];
`ifdef VERILATOR
			engine_cache_tag_q <= sample_cache_tag_mem[engine_cache_read_addr];
`endif
			engine_cache_collision_q <= cache_write_we &&
				(cache_write_addr == engine_cache_read_addr);
			if (prefetch_state == PREFETCH_INIT) begin
`ifdef VERILATOR
				sample_cache_tag_mem[prefetch_init_addr] <= 19'd0;
`endif
			end else if (cache_fill_we) begin
				sample_cache_data_mem[prefetch_entry_q] <=
					{sample_rdata, prefetch_line_data_q[47:0]};
`ifdef VERILATOR
				sample_cache_tag_mem[prefetch_entry_q] <=
					{1'b1, prefetch_bank_q, prefetch_line_q[18:3]};
`endif
			end else begin
`ifdef VERILATOR
				prefetch_cache_tag_q <=
					sample_cache_tag_mem[prefetch_target_entry];
`endif
				prefetch_cache_collision_q <= 1'b0;
			end
			if (cache_write_we && (cache_write_addr == prefetch_target_entry))
				prefetch_cache_collision_q <= 1'b1;
		end
	end

	// The fetcher is intentionally independent of the voice DSP.  ROM stalls
	// can delay cache fill progress but can never hold an engine state or its
	// slot timer.  sample_req and every payload bit remain registered until an
	// acknowledge advances the word index.
	always_ff @(posedge clk) begin
		if (local_reset) begin
			prefetch_state <= PREFETCH_INIT;
			prefetch_init_addr <= 10'd0;
			cache_initialized <= 1'b0;
			prefetch_scan_voice <= 5'd0;
			prefetch_target_index <= 3'd0;
			prefetch_voice_q <= 5'd0;
			prefetch_entry_q <= 10'd0;
			prefetch_bank_q <= 2'd0;
			prefetch_line_q <= 19'd0;
			prefetch_word_q <= 2'd0;
			prefetch_companded_q <= 1'b0;
			prefetch_line_data_q <= 64'd0;
			prefetch_base_line_q <= 19'd0;
			prefetch_direction_q <= 1'b0;
			prefetch_running_q <= 1'b0;
			prefetch_urgent_mode_q <= 1'b0;
			prefetch_program_mode_q <= 1'b0;
			prefetch_urgent_upper_q <= 1'b0;
			prefetch_urgent_need_upper_q <= 1'b0;
			prefetch_urgent_scan_voice <= 5'd0;
			prefetch_row_voice_q <= 5'd0;
			prefetch_row_urgent_q <= 1'b0;
			prefetch_row_program_q <= 1'b0;
		end else begin
			if (start_prefetch_hint || (|prefetch_program_set_mask))
				prefetch_urgent_scan_voice <= host_page_q[4:0];
			else if ((|prefetch_urgent_pending)
			         ? !prefetch_urgent_pending[prefetch_urgent_scan_voice]
			         : ((|prefetch_program_pending)
			            ? !prefetch_program_pending[prefetch_urgent_scan_voice]
			            : 1'b1))
				prefetch_urgent_scan_voice <= prefetch_urgent_scan_voice + 5'd1;
			case (prefetch_state)
				PREFETCH_INIT: begin
					if (prefetch_init_addr == 10'h3ff) begin
						cache_initialized <= 1'b1;
						prefetch_state <= PREFETCH_SCAN;
					end else begin
						prefetch_init_addr <= prefetch_init_addr + 10'd1;
					end
				end

				PREFETCH_SCAN: begin
					// Urgent work always wins before another background target.
					// The pointer advances above while its bit is clear, so a
					// nonempty mask reaches a requested voice within 32 carrier
					// clocks without disturbing an already-held sample request.
					if ((|prefetch_urgent_set_mask) ||
					    (|prefetch_program_set_mask) ||
					    ((|prefetch_urgent_pending) &&
					     !prefetch_urgent_pending[prefetch_urgent_scan_voice]) ||
					    (!(|prefetch_urgent_pending) &&
					     (|prefetch_program_pending) &&
					     !prefetch_program_pending[prefetch_urgent_scan_voice])) begin
						prefetch_state <= PREFETCH_SCAN;
					end else begin
						// Issue one synchronous M10K row read and remember which
						// scanner supplied its address. Consumption is one edge later.
						prefetch_row_urgent_q <=
							prefetch_urgent_pending[prefetch_urgent_scan_voice];
						prefetch_row_program_q <=
							!(|prefetch_urgent_pending) &&
							prefetch_program_pending[prefetch_urgent_scan_voice];
						prefetch_row_voice_q <=
							(prefetch_urgent_pending[prefetch_urgent_scan_voice] ||
							 (!(|prefetch_urgent_pending) &&
							  prefetch_program_pending[prefetch_urgent_scan_voice]))
							? prefetch_urgent_scan_voice : prefetch_scan_voice;
						prefetch_state <= PREFETCH_ROW_READY;
					end
				end

				PREFETCH_ROW_READY: begin
					// The rotating urgent scanner may take one fabric edge to
					// reach a set bit. prefetch_row_urgent_q carries the exact
					// dispatch decision across the edge that clears that bit;
					// testing the live vector here would lose that identity.
					if (voice_prefetch_collision_q) begin
						// Keep the row address selected for a clean synchronous
						// reread. A simultaneous host/engine write may have made
						// the preceding M10K read undefined, not merely stale.
						prefetch_state <= PREFETCH_ROW_READY;
					end else if (prefetch_row_urgent_q || prefetch_row_program_q) begin
						prefetch_urgent_mode_q <= 1'b1;
						prefetch_voice_q <= prefetch_row_voice_q;
						prefetch_urgent_upper_q <= 1'b0;
						prefetch_state <= PREFETCH_URGENT_GATHER;
					end else begin
						prefetch_urgent_mode_q <= 1'b0;
						prefetch_program_mode_q <= 1'b0;
						prefetch_voice_q <= prefetch_scan_voice;
						prefetch_base_line_q <= prefetch_scan_line;
						prefetch_bank_q <= prefetch_scan_bank;
						prefetch_direction_q <=
							voice_prefetch_data.control[6];
						prefetch_running_q <= prefetch_scan_running;
						prefetch_companded_q <=
							voice_prefetch_data.control[13];
						prefetch_state <= PREFETCH_TARGET;
					end
				end

				PREFETCH_URGENT_GATHER: begin
					if (!voice_prefetch_collision_q)
						prefetch_state <= PREFETCH_URGENT_SELECT;
				end

				PREFETCH_URGENT_SELECT: begin
					prefetch_base_line_q <=
						prefetch_urgent_descriptor[24:6];
					prefetch_program_mode_q <=
						prefetch_row_program_q &&
						prefetch_urgent_descriptor[5] &&
						prefetch_urgent_descriptor[1];
					if (prefetch_row_program_q &&
					    prefetch_urgent_descriptor[5] &&
					    prefetch_urgent_descriptor[1])
						prefetch_bank_q <= {
							prefetch_program_bank_bit1[prefetch_row_voice_q],
							prefetch_program_bank_bit0[prefetch_row_voice_q]
						};
					else
						prefetch_bank_q <= prefetch_urgent_descriptor[3:2];
					prefetch_running_q <= prefetch_urgent_descriptor[1];
					prefetch_companded_q <= prefetch_urgent_descriptor[0];
					prefetch_urgent_need_upper_q <=
						prefetch_urgent_descriptor[4];
					prefetch_state <= PREFETCH_TARGET;
				end

				PREFETCH_TARGET: begin
					if (!prefetch_running_q) begin
						if (prefetch_urgent_mode_q) begin
							prefetch_urgent_mode_q <= 1'b0;
							prefetch_program_mode_q <= 1'b0;
						end else if (prefetch_scan_voice >= active_voices_reg) begin
							prefetch_scan_voice <= 5'd0;
							prefetch_target_index <= prefetch_target_index + 3'd1;
						end else begin
							prefetch_scan_voice <= prefetch_scan_voice + 5'd1;
						end
						prefetch_state <= PREFETCH_SCAN;
					end else begin
						prefetch_entry_q <= prefetch_target_entry;
						prefetch_line_q <= prefetch_target_line;
						prefetch_state <= PREFETCH_LOOKUP;
					end
				end

				PREFETCH_LOOKUP: begin
					if (prefetch_target_hit) begin
						// Breadth-first refill: make the current qword available
						// for every active voice before extending any one voice's
						// lookahead window. This bounds simultaneous-start recovery.
						if (prefetch_urgent_mode_q &&
						    !prefetch_urgent_upper_q && prefetch_urgent_need_upper_q) begin
							prefetch_urgent_upper_q <= 1'b1;
							prefetch_state <= PREFETCH_TARGET;
						end else if (prefetch_urgent_mode_q) begin
							prefetch_urgent_mode_q <= 1'b0;
							prefetch_program_mode_q <= 1'b0;
							prefetch_state <= PREFETCH_SCAN;
						end else if (prefetch_scan_voice >= active_voices_reg) begin
							prefetch_scan_voice <= 5'd0;
							prefetch_target_index <= prefetch_target_index + 3'd1;
						end else begin
							prefetch_scan_voice <= prefetch_scan_voice + 5'd1;
						end
						if (!prefetch_urgent_mode_q)
							prefetch_state <= PREFETCH_SCAN;
					end else begin
						prefetch_word_q <= 2'd0;
						prefetch_line_data_q <= 64'd0;
						prefetch_state <= PREFETCH_FETCH;
					end
				end

				PREFETCH_FETCH: begin
					if (sample_ack) begin
						case (prefetch_word_q)
							2'd0: prefetch_line_data_q[15:0] <= sample_rdata;
							2'd1: prefetch_line_data_q[31:16] <= sample_rdata;
							2'd2: prefetch_line_data_q[47:32] <= sample_rdata;
							default: ;
						endcase
						if (prefetch_word_q == 2'd3) begin
							if (prefetch_urgent_mode_q &&
							    !prefetch_urgent_upper_q &&
							    prefetch_urgent_need_upper_q) begin
								prefetch_urgent_upper_q <= 1'b1;
								prefetch_state <= PREFETCH_TARGET;
							end else begin
								prefetch_urgent_mode_q <= 1'b0;
								prefetch_program_mode_q <= 1'b0;
								prefetch_state <= PREFETCH_SCAN;
							end
						end
						else
							prefetch_word_q <= prefetch_word_q + 2'd1;
					end
				end
				default: begin
					prefetch_state <= PREFETCH_INIT;
					prefetch_init_addr <= 10'd0;
					cache_initialized <= 1'b0;
				end
			endcase
		end
	end

	always_ff @(posedge clk) begin
		if (local_reset) begin
			host_rdata <= 8'd0;
			host_ack <= 1'b0;
			host_seen <= 1'b0;
			host_access_pending <= 1'b0;
			host_overlap_q <= 1'b0;
			host_req_q <= 1'b0;
			host_write_q <= 1'b0;
			host_addr_q <= 6'd0;
			host_wdata_q <= 8'd0;
			host_page_q <= 7'd0;
			host_write_execute_pending <= 1'b0;
			host_write_low_page_q <= 1'b0;
			host_write_voice_page_q <= 1'b0;
			host_write_test_page_q <= 1'b0;
			host_write_voice_select_q <= 32'd0;
			host_write_slot_select_q <= 16'd0;
			host_write_value_q <= 32'd0;
			host_read_select_pending <= 1'b0;
			host_read_response_pending <= 1'b0;
			host_read_slot_select_q <= 16'd0;
			host_read_page_q <= 7'd0;
			host_read_low_page_q <= 1'b1;
			host_read_voice_page_q <= 1'b1;
			host_read_control_q <= 16'd0;
			host_read_freq_q <= 17'd0;
			host_read_lvol_q <= 16'd0;
			host_read_lvramp_q <= 8'd0;
			host_read_rvol_q <= 16'd0;
			host_read_rvramp_q <= 8'd0;
			host_read_ecount_q <= 9'd0;
			host_read_k1_q <= 16'd0;
			host_read_k2_q <= 16'd0;
			host_read_k1ramp_q <= 9'd0;
			host_read_k2ramp_q <= 9'd0;
			host_read_start_q <= 32'd0;
			host_read_end_q <= 32'd0;
			host_read_accum_q <= 32'd0;
			host_read_o1n1_q <= 18'd0;
			host_read_o2n1_q <= 18'd0;
			host_read_o2n2_q <= 18'd0;
			host_read_o3n1_q <= 18'd0;
			host_read_o3n2_q <= 18'd0;
			host_read_o4n1_q <= 18'd0;
			host_read_active_q <= 5'd0;
			host_read_mode_q <= 5'd0;
			host_read_par_q <= 10'd0;
			host_read_irq_vector_q <= 8'h80;
			host_read_w_st_q <= 7'd0;
			host_read_w_end_q <= 7'd0;
			host_read_lr_end_q <= 7'd0;
			write_latch <= 32'd0;
			read_latch <= 24'd0;
			current_page_reg <= 7'd0;
			active_voices_reg <= 5'h1f;
			mode <= 5'h17;
			w_st <= 7'd0;
			w_end <= 7'd0;
			lr_end <= 7'd0;
			irq <= 1'b0;
			irq_vector_reg <= 8'h80;
			irq_ack_pending <= 32'd0;
			engine_state <= ENGINE_IDLE;
			slot_count <= '0;
			work_voice <= 5'd0;
			work_voice_select <= 32'd0;
			work_control <= CONTROL_STOPMASK;
			work_freq <= 17'd0;
			work_start <= 32'd0;
			work_end <= 32'd0;
			work_accum <= 32'd0;
			work_lvol <= 16'h8000;
			work_rvol <= 16'h8000;
			work_lvramp <= 8'd0;
			work_rvramp <= 8'd0;
			work_ecount <= 9'd0;
			work_k1 <= 16'd0;
			work_k2 <= 16'd0;
			work_k1ramp <= 9'd0;
			work_k2ramp <= 9'd0;
			work_filtcnt <= 3'd0;
			work_o1n1 <= 32'sd0;
			work_o2n1 <= 32'sd0;
			work_o2n2 <= 32'sd0;
			work_o3n1 <= 32'sd0;
			work_o3n2 <= 32'sd0;
			work_o4n1 <= 32'sd0;
			scan_voice_reg <= 5'd0;
			fetched_sample0 <= 16'd0;
			fetched_sample1 <= 16'd0;
			decoded_sample0_reg <= 16'sd0;
			decoded_sample1_reg <= 16'sd0;
			interp_weight0_reg <= 10'd0;
			interp_weight1_reg <= 10'd0;
			interp_product0_reg <= 27'sd0;
			interp_product1_reg <= 27'sd0;
			interpolated_sample_reg <= 18'sd0;
			filter_operand_reg <= 32'sd0;
			filter_cutoff_reg <= 12'd0;
			filter_product_high_reg <= 29'sd0;
			filter_product_low_reg <= 28'd0;
			filter_quotient_reg <= 48'sd0;
			filter_pole1_reg <= 32'sd0;
			filter_pole2_reg <= 32'sd0;
			filter_pole3_reg <= 32'sd0;
			filter_pole4_reg <= 32'sd0;
			volume_gain_left_reg <= 9'd0;
			volume_gain_right_reg <= 9'd0;
			volume_exponent_left_reg <= 4'd0;
			volume_exponent_right_reg <= 4'd0;
			volume_product_left_reg <= 42'sd0;
			volume_product_right_reg <= 42'sd0;
			voice_mix_left_reg <= 32'sd0;
			voice_mix_right_reg <= 32'sd0;
			engine_cache_read_addr <= 10'd0;
			engine_cache_first_hit_q <= 1'b0;
			underrun_delay_q <= 6'd0;
			sample_underrun <= 1'b0;
			scan_underrun <= 1'b0;
			sample_underrun_count <= 32'd0;
			raw_stepped_accum_reg <= 32'd0;
			step_accum_reg <= 32'd0;
			step_boundary_delta_reg <= 32'd0;
			step_forward_crossed_reg <= 1'b0;
			step_reverse_crossed_reg <= 1'b0;
			stepped_accum_reg <= 32'd0;
			stepped_control_reg <= CONTROL_STOPMASK;
			envelope_lvol_reg <= 16'h8000;
			envelope_rvol_reg <= 16'h8000;
			envelope_k1_reg <= 16'd0;
			envelope_k2_reg <= 16'd0;
			envelope_ecount_reg <= 9'd0;
			envelope_filtcnt_reg <= 3'd0;
			work_envelope_cancel_q <= 1'b0;
			work_mix_left <= 23'sd0;
			work_mix_right <= 23'sd0;
			work_channel_select <= 6'd0;
			audio_strobe <= 1'b0;
		end else begin
			host_ack <= 1'b0;
			audio_strobe <= 1'b0;
			sample_underrun <= 1'b0;
			// Device time never stops for host register traffic.  Host accesses
			// use idle or bounded interior reservations, and their registered
			// select/response stages may overlap a 16 MHz enable; advance the
			// slot timer here, outside the host-priority chain, so those stages
			// cannot stretch the audio cadence.
			if (ce_16m && (slot_count != SLOT_LAST))
				slot_count <= slot_count + 1'b1;
			host_req_q <= host_req;
			if (host_req) begin
				host_write_q <= host_write;
				host_addr_q <= host_addr;
				host_wdata_q <= host_wdata;
				host_page_q <= current_page_reg;
			end
			if (!host_req_q)
				host_seen <= 1'b0;

			// This branch is deliberately independent of the engine chain below:
			// accepting a latch-only byte must not steal a DSP/voice/slot edge.
			// No pending architectural access can overlap this response. A held
			// request is still acknowledged once, through the shared host_seen.
			if (host_latch_accept) begin
				host_seen <= 1'b1;
				host_ack <= 1'b1;
				if (host_write_q)
					write_latch <= assembled_write;
				else begin
					case (host_addr_q[1:0])
						2'd1: host_rdata <= read_latch[23:16];
						2'd2: host_rdata <= read_latch[15:8];
						default: host_rdata <= read_latch[7:0];
					endcase
				end
			end

			// The same registered architectural pipeline serves idle reservations
			// and bounded overlap. Only idle reservations hold the
			// DSP below; overlap must not steal any voice/slot/output edge.
			if (host_write_execute_pending) begin
				// The M10K write bundle above commits this registered row update.
				host_write_execute_pending <= 1'b0;
				host_overlap_q <= 1'b0;
				// This edge really writes EC0 to both synchronous RAM replicas.
				// Latest admission is APPLY: this fact is stable two edges before
				// COMMIT/STOPPED; the host write cannot share the terminal edge.
				if (host_overlap_q && host_write_low_page_q &&
				    host_write_slot_select_q[6] &&
				    (host_page_q[4:0] == work_voice) &&
				    (host_write_value_q[8:0] == 9'd0))
					work_envelope_cancel_q <= 1'b1;
				if (host_write_low_page_q && host_write_slot_select_q[11]) begin
					active_voices_reg <= host_write_value_q[4:0];
					scan_voice_reg <= 5'd0;
					slot_count <= '0;
				end
				if (host_write_low_page_q && host_write_slot_select_q[12])
					mode <= host_write_value_q[4:0];
				if (host_write_voice_page_q && host_write_slot_select_q[10])
					w_st <= host_write_value_q[6:0];
				if (host_write_voice_page_q && host_write_slot_select_q[11])
					w_end <= host_write_value_q[6:0];
				if (host_write_voice_page_q && host_write_slot_select_q[12])
					lr_end <= host_write_value_q[6:0];
				if (host_write_slot_select_q[15])
					current_page_reg <= host_write_value_q[6:0];
			end else if (host_read_select_pending) begin
				host_read_select_pending <= 1'b0;
				host_read_response_pending <= 1'b1;
				host_read_control_q <= voice_engine_data.control;
				host_read_freq_q <= voice_engine_data.freq;
				host_read_lvol_q <= voice_engine_data.lvol;
				host_read_lvramp_q <= voice_engine_data.lvramp;
				host_read_rvol_q <= voice_engine_data.rvol;
				host_read_rvramp_q <= voice_engine_data.rvramp;
				host_read_ecount_q <= voice_engine_data.ecount;
				host_read_k1_q <= voice_engine_data.k1;
				host_read_k2_q <= voice_engine_data.k2;
				host_read_k1ramp_q <= voice_engine_data.k1ramp;
				host_read_k2ramp_q <= voice_engine_data.k2ramp;
				host_read_start_q <= voice_engine_data.start_addr;
				host_read_end_q <= voice_engine_data.end_addr;
				host_read_accum_q <= voice_engine_data.accum;
				host_read_o4n1_q <= voice_engine_data.o4n1[17:0];
				host_read_o3n1_q <= voice_engine_data.o3n1[17:0];
				host_read_o3n2_q <= voice_engine_data.o3n2[17:0];
				host_read_o2n1_q <= voice_engine_data.o2n1[17:0];
				host_read_o2n2_q <= voice_engine_data.o2n2[17:0];
				host_read_o1n1_q <= voice_engine_data.o1n1[17:0];
			end else if (host_read_response_pending) begin
				host_read_response_pending <= 1'b0;
				host_overlap_q <= 1'b0;
				host_ack <= 1'b1;
				read_latch <= register_read_value[23:0];
				host_rdata <= register_read_value[31:24];
				if (host_read_slot_select_q[14]) begin
					if (!irq_vector_reg[7])
						irq_ack_pending[irq_vector_reg[4:0]] <= 1'b1;
					irq_vector_reg <= 8'h80;
					irq <= 1'b0;
				end
			end else if (host_access_pending) begin
				// The prior admission edge reserves this host transaction.
				// Execute from the registered reservation so engine_state does
				// not directly drive any voice-file write enables.
				host_access_pending <= 1'b0;
				if (host_write_q) begin
					host_ack <= 1'b1;
					write_latch <= assembled_write;
					if (host_addr_q[1:0] == 2'd3) begin
						write_latch <= 32'd0;
						host_write_execute_pending <= 1'b1;
						host_write_low_page_q <= (host_page_q < 7'h20);
						host_write_voice_page_q <=
							(host_page_q >= 7'h20) && (host_page_q < 7'h40);
						host_write_test_page_q <= host_page_q[6];
						host_write_voice_select_q <= 32'b1 << host_page_q[4:0];
						host_write_slot_select_q <= 16'b1 << host_addr_q[5:2];
						host_write_value_q <= assembled_write;
					end
				end else begin
					if (host_addr_q[1:0] == 2'd0) begin
						host_read_select_pending <= 1'b1;
						host_read_slot_select_q <= 16'b1 << host_addr_q[5:2];
						host_read_page_q <= host_page_q;
						host_read_low_page_q <= (host_page_q < 7'h20);
						host_read_voice_page_q <= (host_page_q < 7'h40);
						host_read_active_q <= active_voices_reg;
						host_read_mode_q <= mode;
						host_read_par_q <= par_value;
						host_read_irq_vector_q <= irq_vector_reg;
						host_read_w_st_q <= w_st;
						host_read_w_end_q <= w_end;
						host_read_lr_end_q <= lr_end;
					end else begin
						host_ack <= 1'b1;
						case (host_addr_q[1:0])
							2'd1: host_rdata <= read_latch[23:16];
							2'd2: host_rdata <= read_latch[15:8];
							default: host_rdata <= read_latch[7:0];
						endcase
					end
				end
			end else if (host_idle_reserve || host_overlap_reserve) begin
				// The held request keeps PAGE/address/data stable through commit.
				// Idle reservations still leave two ES ticks before next T0;
				// overlap has its separate, strictly interior completion bound.
				host_seen <= 1'b1;
				host_access_pending <= 1'b1;
				host_overlap_q <= host_overlap_reserve;
			end

			if (!host_engine_hold) begin
				case (engine_state)
					ENGINE_IDLE: begin
						if (ce_16m) begin
							if (slot_count == SLOT_LAST) begin
								slot_count <= '0;
								work_voice <= scan_voice_reg;
								work_voice_select <= 32'b1 << scan_voice_reg;
								if (scan_voice_reg == 0) begin
									scan_underrun <= 1'b0;
								end
								// The next state consumes the registered M10K row.
								engine_state <= ENGINE_LAUNCH;
							end else begin
								slot_count <= slot_count + 1'b1;
							end
						end
					end

					ENGINE_LAUNCH: begin
						work_envelope_cancel_q <= 1'b0;
						// Undefined CA6/7 decode to no channel. All six documented
						// channels share the same arithmetic and canonical store.
						work_channel_select <= 6'b000001 << voice_engine_data.control[12:10];
						if ((work_voice == 0) || (voice_engine_data.control[12:10] >= 6)) begin
							work_mix_left <= 23'sd0;
							work_mix_right <= 23'sd0;
						end else begin
							work_mix_left <= channel_mix_left[voice_engine_data.control[12:10]];
							work_mix_right <= channel_mix_right[voice_engine_data.control[12:10]];
						end
						work_control <= irq_ack_pending[work_voice]
							? voice_engine_data.control & ~CONTROL_IRQ
							: voice_engine_data.control;
						work_freq <= voice_engine_data.freq;
						work_start <= voice_engine_data.start_addr;
						work_end <= voice_engine_data.end_addr;
						work_accum <= voice_engine_data.accum;
						work_lvol <= voice_engine_data.lvol;
						work_rvol <= voice_engine_data.rvol;
						work_lvramp <= voice_engine_data.lvramp;
						work_rvramp <= voice_engine_data.rvramp;
						work_ecount <= voice_engine_data.ecount;
						work_k1 <= voice_engine_data.k1;
						work_k2 <= voice_engine_data.k2;
						work_k1ramp <= voice_engine_data.k1ramp;
						work_k2ramp <= voice_engine_data.k2ramp;
						work_filtcnt <= voice_engine_data.filtcnt;
						work_o1n1 <= voice_engine_data.o1n1;
						work_o2n1 <= voice_engine_data.o2n1;
						work_o2n2 <= voice_engine_data.o2n2;
						work_o3n1 <= voice_engine_data.o3n1;
						work_o3n2 <= voice_engine_data.o3n2;
						work_o4n1 <= voice_engine_data.o4n1;
						// START==END is not a stop condition. Rev2.3 section11.1
						// uses strict crossing after the FC step; FC0 can hold an
						// exact endpoint, and STOP1 must not manufacture STOP0.
						// Stopped voices still run their filters (Rev2.3 section5).
						// Keep the identical pipeline phase; these are harmless RAM
						// reads, not external sample requests for a stopped voice.
						engine_cache_read_addr <= {
							work_voice,
							voice_engine_data.control[15:14],
							voice_engine_data.accum[15:13]
						};
						engine_state <= ENGINE_CACHE_READ0;
					end

					ENGINE_CACHE_READ0:
						engine_state <= ENGINE_CACHE_SELECT0;

					ENGINE_CACHE_SELECT0: begin
						engine_cache_first_hit_q <= cache_initialized &&
							!engine_cache_collision_q &&
							engine_cache_tag_q[18] &&
							(engine_cache_tag_q[17:16] == work_control[15:14]) &&
							(engine_cache_tag_q[15:0] == work_current_line[18:3]);
						if (cache_initialized && !engine_cache_collision_q &&
						    engine_cache_tag_q[18] &&
						    (engine_cache_tag_q[17:16] == work_control[15:14]) &&
						    (engine_cache_tag_q[15:0] == work_current_line[18:3])) begin
							fetched_sample0 <= sample_line_word(
								engine_cache_data_q, work_accum[12:11]);
							if (work_accum[12:11] != 2'd3)
								fetched_sample1 <= sample_line_word(
									engine_cache_data_q, work_accum[12:11] + 2'd1);
						end
						// Always perform the second registered read.  For words 0..2
						// it is a timing-equivalent dummy. Word 3 only needs its word 0
						// when the nine-bit interpolation fraction is nonzero.
						engine_cache_read_addr <= work_cache_entry1;
						engine_state <= ENGINE_CACHE_READ1;
					end

					ENGINE_CACHE_READ1:
						engine_state <= ENGINE_CACHE_SELECT1;

					ENGINE_CACHE_SELECT1: begin
						if ((work_control & CONTROL_STOPMASK) != 0) begin
							// The stopped physical memory bus is unspecified. Zero is
							// a deterministic substitute; output is muted regardless.
							fetched_sample0 <= 16'd0;
							fetched_sample1 <= 16'd0;
							engine_state <= ENGINE_DECODE;
						end else if (engine_sample_miss) begin
							underrun_delay_q <= UNDERRUN_WAIT_CYCLES;
							engine_state <= ENGINE_UNDERRUN_WAIT;
						end else begin
							if (work_accum[12:11] == 2'd3) begin
								// Section11.2 weights the upper sample by ACCUM[10:2].
								// At zero weight the already validated first word is an
								// exact substitute; never consume an unqualified RAM read.
								// Keep both RAM cycles and every DSP/terminal phase intact.
								if (work_accum[10:2] == 9'd0)
									fetched_sample1 <= fetched_sample0;
								else
									fetched_sample1 <= sample_line_word(
										engine_cache_data_q, 2'd0);
							end
							engine_state <= ENGINE_DECODE;
						end
					end

					ENGINE_DECODE: begin
						if ((work_control & CONTROL_CMPD) != 0) begin
							decoded_sample0_reg <= decode_ulaw(fetched_sample0);
							decoded_sample1_reg <= decode_ulaw(fetched_sample1);
						end else begin
							decoded_sample0_reg <= $signed(fetched_sample0);
							decoded_sample1_reg <= $signed(fetched_sample1);
						end
						envelope_lvol_reg <= envelope_lvol_next;
						envelope_rvol_reg <= envelope_rvol_next;
						envelope_k1_reg <= envelope_k1_next;
						envelope_k2_reg <= envelope_k2_next;
						envelope_ecount_reg <= envelope_ecount_next;
						envelope_filtcnt_reg <= envelope_filtcnt_next;
						raw_stepped_accum_reg <= raw_stepped_accum_next;
						engine_state <= ENGINE_STEP_DECIDE;
					end

					ENGINE_STEP_DECIDE: begin
						step_accum_reg <= raw_stepped_accum_reg;
						step_forward_crossed_reg <=
							((work_control & CONTROL_STOPMASK) == 0) &&
							((work_control & CONTROL_LEI) == 0) &&
							((work_control & CONTROL_DIR) == 0) &&
							(raw_stepped_accum_reg > work_end);
						step_reverse_crossed_reg <=
							((work_control & CONTROL_STOPMASK) == 0) &&
							((work_control & CONTROL_LEI) == 0) &&
							((work_control & CONTROL_DIR) != 0) &&
							(raw_stepped_accum_reg < work_start);
						if ((work_control & CONTROL_DIR) != 0)
							step_boundary_delta_reg <= work_start - raw_stepped_accum_reg;
						else
							step_boundary_delta_reg <= raw_stepped_accum_reg - work_end;
						engine_state <= ENGINE_STEP_FINISH;
					end

					ENGINE_STEP_FINISH: begin
						stepped_accum_reg <= stepped_accum_next;
						stepped_control_reg <= stepped_control_next;
						engine_state <= ENGINE_INTERP_PREP;
					end

					ENGINE_INTERP_PREP: begin
						interp_weight0_reg <= 10'd512 - {1'b0, work_accum[10:2]};
						interp_weight1_reg <= {1'b0, work_accum[10:2]};
						engine_state <= ENGINE_INTERP_MUL;
					end

					ENGINE_INTERP_MUL: begin
						interp_product0_reg <= interpolation_multiply(
							decoded_sample0_reg, interp_weight0_reg);
						interp_product1_reg <= interpolation_multiply(
							decoded_sample1_reg, interp_weight1_reg);
						engine_state <= ENGINE_INTERP_SUM;
					end

					ENGINE_INTERP_SUM: begin
						interpolated_sample_reg <=
							interpolation_finish(interp_product0_reg, interp_product1_reg);
						engine_state <= ENGINE_POLE1_PREP;
					end

					ENGINE_POLE1_PREP: begin
						filter_operand_reg <= 32'(interpolated_sample_reg) - work_o1n1;
						filter_cutoff_reg <= work_k1[15:4];
						engine_state <= ENGINE_POLE1_MUL;
					end

					ENGINE_POLE1_MUL: begin
						filter_product_high_reg <= filter_multiply_high(
							filter_operand_reg[31:16], filter_cutoff_reg);
						filter_product_low_reg <= filter_multiply_low(
							filter_operand_reg[15:0], filter_cutoff_reg);
						engine_state <= ENGINE_POLE1_FINISH;
					end

					ENGINE_POLE1_FINISH: begin
						filter_pole1_reg <= lowpass_finish(
							filter_product_combined, work_o1n1);
						engine_state <= ENGINE_POLE2_PREP;
					end

					ENGINE_POLE2_PREP: begin
						filter_operand_reg <= filter_pole1_reg - work_o2n1;
						filter_cutoff_reg <= work_k1[15:4];
						engine_state <= ENGINE_POLE2_MUL;
					end

					ENGINE_POLE2_MUL: begin
						filter_product_high_reg <= filter_multiply_high(
							filter_operand_reg[31:16], filter_cutoff_reg);
						filter_product_low_reg <= filter_multiply_low(
							filter_operand_reg[15:0], filter_cutoff_reg);
						engine_state <= ENGINE_POLE2_FINISH;
					end

					ENGINE_POLE2_FINISH: begin
						filter_pole2_reg <= lowpass_finish(
							filter_product_combined, work_o2n1);
						engine_state <= ENGINE_POLE3_PREP;
					end

					ENGINE_POLE3_PREP: begin
						case (work_control[9:8])
							2'b00: begin
								filter_operand_reg <= work_o3n1;
								filter_cutoff_reg <= work_k2[15:4];
							end
							2'b10: begin
								filter_operand_reg <= filter_pole2_reg - work_o3n1;
								filter_cutoff_reg <= work_k2[15:4];
							end
							default: begin
								filter_operand_reg <= filter_pole2_reg - work_o3n1;
								filter_cutoff_reg <= work_k1[15:4];
							end
						endcase
						engine_state <= ENGINE_POLE3_MUL;
					end

					ENGINE_POLE3_MUL: begin
						filter_product_high_reg <= filter_multiply_high(
							filter_operand_reg[31:16], filter_cutoff_reg);
						filter_product_low_reg <= filter_multiply_low(
							filter_operand_reg[15:0], filter_cutoff_reg);
						engine_state <= ENGINE_POLE3_FINISH;
					end

					ENGINE_POLE3_FINISH: begin
						if (work_control[9:8] == 2'b00)
							filter_pole3_reg <= highpass_finish(filter_product_combined,
								filter_pole2_reg, work_o3n1, work_o2n2);
						else
							filter_pole3_reg <= lowpass_finish(
								filter_product_combined, work_o3n1);
						engine_state <= ENGINE_POLE4_PREP;
					end

					ENGINE_POLE4_PREP: begin
						if (work_control[9] == 1'b0)
							filter_operand_reg <= work_o4n1;
						else
							filter_operand_reg <= filter_pole3_reg - work_o4n1;
						filter_cutoff_reg <= work_k2[15:4];
						engine_state <= ENGINE_POLE4_MUL;
					end

					ENGINE_POLE4_MUL: begin
						filter_product_high_reg <= filter_multiply_high(
							filter_operand_reg[31:16], filter_cutoff_reg);
						filter_product_low_reg <= filter_multiply_low(
							filter_operand_reg[15:0], filter_cutoff_reg);
						engine_state <= ENGINE_POLE4_FINISH;
					end

					ENGINE_POLE4_FINISH: begin
						if (work_control[9] == 1'b0)
							filter_quotient_reg <= filter_product_combined / 48'sd8192;
						else
							filter_quotient_reg <= filter_product_combined / 48'sd4096;
						engine_state <= ENGINE_POLE4_APPLY;
					end

					ENGINE_POLE4_APPLY: begin
						if (work_control[9] == 1'b0)
							filter_pole4_reg <= highpass_apply(filter_quotient_reg,
								filter_pole3_reg, work_o4n1, work_o3n2);
						else
							filter_pole4_reg <= lowpass_apply(filter_quotient_reg, work_o4n1);
						engine_state <= ENGINE_VOLUME_GAIN;
					end

					ENGINE_VOLUME_GAIN: begin
						volume_gain_left_reg <= volume_mantissa(envelope_lvol_reg);
						volume_gain_right_reg <= volume_mantissa(envelope_rvol_reg);
						volume_exponent_left_reg <= envelope_lvol_reg[15:12];
						volume_exponent_right_reg <= envelope_rvol_reg[15:12];
						engine_state <= ENGINE_VOLUME_MUL;
					end

					ENGINE_VOLUME_MUL: begin
						volume_product_left_reg <= volume_multiply(
							filter_pole4_reg >>> 1, volume_gain_left_reg);
						volume_product_right_reg <= volume_multiply(
							filter_pole4_reg >>> 1, volume_gain_right_reg);
						engine_state <= ENGINE_VOLUME_FINISH;
					end

					ENGINE_VOLUME_FINISH: begin
						if ((work_control & CONTROL_STOPMASK) != 0) begin
							voice_mix_left_reg <= 32'sd0;
							voice_mix_right_reg <= 32'sd0;
							engine_state <= ENGINE_STOPPED;
						end else begin
							voice_mix_left_reg <= 32'(volume_finish(
								volume_product_left_reg, volume_exponent_left_reg));
							voice_mix_right_reg <= 32'(volume_finish(
								volume_product_right_reg, volume_exponent_right_reg));
							engine_state <= ENGINE_COMMIT;
						end
					end

					ENGINE_COMMIT: begin
						work_envelope_cancel_q <= 1'b0;
						irq_ack_pending[work_voice] <= 1'b0;

						if (((stepped_control_reg & CONTROL_IRQ) != 0) && irq_vector_reg[7]) begin
							irq_vector_reg <= {3'd0, work_voice};
							irq <= 1'b1;
						end

						if (work_voice == active_voices_reg) begin
							audio_strobe <= 1'b1;
							scan_voice_reg <= 5'd0;
						end else begin
							scan_voice_reg <= work_voice + 5'd1;
						end
						engine_state <= ENGINE_IDLE;
					end

					ENGINE_STOPPED: begin
						work_envelope_cancel_q <= 1'b0;
						irq_ack_pending[work_voice] <= 1'b0;
						if (((work_control & CONTROL_IRQ) != 0) && irq_vector_reg[7]) begin
							irq_vector_reg <= {3'd0, work_voice};
							irq <= 1'b1;
						end
						if (work_voice == active_voices_reg) begin
							audio_strobe <= 1'b1;
							scan_voice_reg <= 5'd0;
						end else begin
							scan_voice_reg <= work_voice + 5'd1;
						end
						engine_state <= ENGINE_IDLE;
					end

					ENGINE_UNDERRUN: begin
					// Cache misses are an FPGA integration condition, not an OTTO
					// voice operation. Preserve global cadence and freeze this
					// voice's complete state, but contribute zero rather than
					// replaying audio computed from an older register/sample state.
						sample_underrun <= 1'b1;
						scan_underrun <= 1'b1;
						sample_underrun_count <= sample_underrun_count + 32'd1;
						if (work_voice == active_voices_reg) begin
							audio_strobe <= 1'b1;
							scan_voice_reg <= 5'd0;
						end else begin
							scan_voice_reg <= work_voice + 5'd1;
						end
						engine_state <= ENGINE_IDLE;
					end

					ENGINE_UNDERRUN_WAIT: begin
						if (underrun_delay_q == 0)
							engine_state <= ENGINE_UNDERRUN;
						else
							underrun_delay_q <= underrun_delay_q - 6'd1;
					end

					default: engine_state <= ENGINE_IDLE;
				endcase
			end
		end
	end

endmodule
