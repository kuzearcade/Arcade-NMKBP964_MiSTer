// Arcade-NMKMacPlus_MiSTer -- MiSTer top level for the Banpresto BP964A /
// BP965A board: Macross Plus (1996) and Quiz Bishoujo Senshi Sailor Moon (1997).
//
// Derived from Arcade-JalecoMS1Z_MiSTer's MS1Z.sv (docs/provenance.md): the
// reset chain (MS1-53, SS-15), keyboard map, autofire, high scores, cheats,
// CRT Adjust, orientation and the video chain are that file's. What differs:
//   * The ROM image (62 MB) is loaded into DDR3 at 0x30000000 by the .mra's
//     `address=` and copied in part into SDRAM (macplus_rom_hw, PLAN D1). The
//     core stays in reset until that copy is done.
//   * <switches> byte 2 is the game mode: bit 0 = quizmoon, bit 7 = Autofire.
//   * Four buttons; the INPUTS word is MAME's (PLAN 1.6).
//   * The raster is MAME's 512 x 256 at exactly 60 Hz (D4). video_retime
//     re-times it onto 96 MHz as 625 dots x 10 clocks = 6,250 per line, the
//     only exact fit (MP-7).
//   * Stereo audio from the ES5506.
//   * Savestates are not in this build (the core's park and restore are M5).
module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1; // signed PCM
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

wire [1:0] ar = status[122:121];
assign VIDEO_ARX = (!ar) ? (video_rotated ? 12'd3 : 12'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (video_rotated ? 12'd4 : 12'd3) : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"NMKMacPlus;;",
	"-;",
	"HBO[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"HBO[3:1],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"H0O[9:8],Orientation,Horz,Vert 90,Vert 270;",
	"O[17],Flip screen,Off,On;",
	"P3,CRT Adjust;",
	"P3O[101],CRT Adjust,Off,On;",
	"P3O[100:96],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P3O[85:79],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P3O[78:74],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"P3O[107:104],CRT V-Size,0,+1,+2,+3,+4,-4,-3,-2,-1;",
	"P3O[108],CRT V-Size Mode,PVM,Cabinet;",
	// Autofire on button 1, clocked by the game's own frame; hidden unless the
	// .mra's third <switches> byte sets bit 7 (macrossp only).
	"h1O[12:10],P1 Autofire,Off,10Hz,12Hz,15Hz,20Hz,30Hz;",
	"h1O[15:13],P2 Autofire,Off,10Hz,12Hz,15Hz,20Hz,30Hz;",
	"-;",
	"DIP;",
	"-;",
	"O[29],Pause,Off,On;",
	"P1,Scores;",
	"P1O[39],High Scores,Off,On;",
	"P1-;",
	"dAP1R[30],Save Scores;",
	"dAP1R[31],Reset Scores;",
	// The cheat slots are named generically; each .mra names its cheats in
	// its <cheats> comment and hides the slots it has none for (Q16).
	"P2,Cheats;",
	"P2-;",
	"h3P2O[32],Cheat 1,Off,On;",
	"h4P2O[33],Cheat 2,Off,On;",
	"h5P2O[34],Cheat 3,Off,On;",
	"h6P2O[35],Cheat 4,Off,On;",
	"h7P2O[36],Cheat 5,Off,On;",
	"h8P2O[37],Cheat 6,Off,On;",
	"h9P2O[38],Cheat 7,Off,On;",
	"-;",
	"R[0],Reset;",
	"J1,Button 1,Button 2,Button 3,Button 4,Start,Coin;",
	"V,v",`BUILD_DATE
};

wire         forced_scandoubler;
wire         direct_video;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [31:0] joystick_0, joystick_1;

wire         ioctl_download;
wire         ioctl_wr;
wire  [26:0] ioctl_addr_full;
wire   [7:0] ioctl_dout;
wire         ioctl_wait;
wire  [15:0] ioctl_index;
wire         ioctl_upload, ioctl_upload_req;
wire   [7:0] ioctl_din;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(vm_gamma_bus),
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.buttons(buttons),
	.status(status),
	// [11] hides Aspect/Fx under direct video; [10] greys Save/Reset Scores while
	// High Scores is Off; [9:3] hide the unused cheat slots; [1] shows Autofire;
	// [0] hides Orientation under direct video.
	.status_menumask({4'd0, direct_video, hs_enable, ch_avail, 1'b0, autofire_unlock, direct_video}),
	.status_in(status), .status_set(1'b0),
	.info_req(1'b0), .info(8'd0),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr_full),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ioctl_index(ioctl_index),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd4),
	.ioctl_din(ioctl_din),
	.ps2_key(ps2_key)
);
wire [24:0] ioctl_addr = ioctl_addr_full[24:0];

///////////////////////   CLOCKS   ///////////////////////////////
// clk_sys 48 MHz: the ES5506 and the sound 68000 are exact thirds (16 MHz);
// the 68EC020 and the pixel are rational enables (D3, D4). clk_ram 96 MHz:
// the SDRAM controller and, as CLK_VIDEO, the DDR3 port and the video out.
wire clk_sys;
wire clk_ram;
wire pll_locked;
pll pll (.refclk(CLK_50M), .rst(0), .outclk_0(clk_sys), .outclk_1(clk_ram), .locked(pll_locked));

// Reset: held for the download and a tail after EVERY ioctl session, and until
// the <switches> block has arrived (MS1-53).
reg [23:0] dl_tail = {24{1'b1}};
always @(posedge clk_sys) begin
	if (ioctl_download)              dl_tail <= 24'd0;
	else if (dl_tail != {24{1'b1}})  dl_tail <= dl_tail + 1'd1;
end
wire dl_settling = (dl_tail != {24{1'b1}});
reg         sw_seen  = 1'b0;
reg  [27:0] sw_tmo   = 28'd0;
always @(posedge clk_sys) begin
	if (ioctl_download) begin
		sw_tmo <= 28'd0;
		if (ioctl_wr && ioctl_index == 16'd254) sw_seen <= 1'b1;
	end else if (~&sw_tmo) sw_tmo <= sw_tmo + 1'd1;
end
wire wait_switches = ~sw_seen & ~&sw_tmo;

reg [28:0] hs_rst_cnt = 29'd0;
always @(posedge clk_sys) begin
	if (status[31])       hs_rst_cnt <= 29'd288000000;
	else if (|hs_rst_cnt) hs_rst_cnt <= hs_rst_cnt - 1'b1;
end
wire hs_hold     = |hs_rst_cnt;
wire hs_core_rst = (hs_rst_cnt > 29'd283000000);

wire rom_ready, sdram_ready;
wire reset = RESET | status[0] | buttons[1] | ioctl_download | dl_settling | wait_switches | ~pll_locked | hs_core_rst;

// The loader's reset is power-on only (SS-15): macplus_rom_hw IS the load and
// the copy, and must keep working through every window `reset` covers.
reg [3:0] por_cnt = 4'd0;
reg       por_rst = 1'b1;
always @(posedge clk_sys) begin
	if (~pll_locked) begin por_cnt <= 4'd0; por_rst <= 1'b1; end
	else if (por_rst) begin
		if (por_cnt == 4'd15) por_rst <= 1'b0; else por_cnt <= por_cnt + 4'd1;
	end
end

// <switches>, ioctl index 254: bytes 0/1 are DSW1/DSW2 (MAME's DSW[23:16] and
// [31:24]); byte 2 is the game mode (bit 0 quizmoon, bit 7 Autofire unlock).
reg [7:0] dip_sw [0:7];
integer dip_i;
initial for (dip_i = 0; dip_i < 8; dip_i = dip_i + 1) dip_sw[dip_i] = 8'hFF;
always @(posedge clk_sys)
	if (ioctl_download && ioctl_wr && (ioctl_index == 16'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
reg sw_byte2_seen = 1'b0;
always @(posedge clk_sys)
	if (ioctl_download && ioctl_wr && (ioctl_index == 16'd254) && ioctl_addr[24:0] == 25'd2)
		sw_byte2_seen <= 1'b1;
wire quiz            = sw_byte2_seen & dip_sw[2][0];
wire autofire_unlock = sw_byte2_seen & dip_sw[2][7];

// ------------------------------------------------------------------
// Keyboard: MAME's default keys, ORed with the pads.
//   P1: arrows, LCtrl B1, LAlt B2, Space B3, LShift B4
//   P2: R/F/D/G, A B1, S B2, Q B3, W B4
//   Coin 1/2 = 5/6, Start 1/2 = 1/2, Service 1 = 9 and F2
// ------------------------------------------------------------------
reg [7:0] kb_p1 = 8'd0, kb_p2 = 8'd0;   // [0]R [1]L [2]D [3]U [4]B1 [5]B2 [6]B3 [7]B4
reg kb_start1 = 1'b0, kb_start2 = 1'b0, kb_coin1 = 1'b0, kb_coin2 = 1'b0, kb_service = 1'b0, kb_f2 = 1'b0;
reg kb_toggle_d = 1'b0;
always @(posedge clk_sys) begin
	kb_toggle_d <= ps2_key[10];
	if (kb_toggle_d != ps2_key[10]) begin
		case (ps2_key[8:0])
			9'h175: kb_p1[3] <= ps2_key[9];
			9'h172: kb_p1[2] <= ps2_key[9];
			9'h16B: kb_p1[1] <= ps2_key[9];
			9'h174: kb_p1[0] <= ps2_key[9];
			9'h014: kb_p1[4] <= ps2_key[9];
			9'h011: kb_p1[5] <= ps2_key[9];
			9'h029: kb_p1[6] <= ps2_key[9];
			9'h012: kb_p1[7] <= ps2_key[9];
			9'h02D: kb_p2[3] <= ps2_key[9];
			9'h02B: kb_p2[2] <= ps2_key[9];
			9'h023: kb_p2[1] <= ps2_key[9];
			9'h034: kb_p2[0] <= ps2_key[9];
			9'h01C: kb_p2[4] <= ps2_key[9];
			9'h01B: kb_p2[5] <= ps2_key[9];
			9'h015: kb_p2[6] <= ps2_key[9];
			9'h01D: kb_p2[7] <= ps2_key[9];
			9'h016: kb_start1  <= ps2_key[9];
			9'h01E: kb_start2  <= ps2_key[9];
			9'h02E: kb_coin1   <= ps2_key[9];
			9'h036: kb_coin2   <= ps2_key[9];
			9'h046: kb_service <= ps2_key[9];
			9'h006: kb_f2      <= ps2_key[9];
			default: ;
		endcase
	end
end

// ------------------------------------------------------------------
// Autofire (button 1), paced by the game's frame (MS1Z's).
// ------------------------------------------------------------------
wire        vblank_core;
wire  [7:0] p1_raw = {joystick_0[7:4], joystick_0[3:0]} | kb_p1;
wire  [7:0] p2_raw = {joystick_1[7:4], joystick_1[3:0]} | kb_p2;
reg  vbl_d = 1'b0;
wire frame_tick = vblank_core & ~vbl_d;
always @(posedge clk_sys) vbl_d <= vblank_core;
function automatic [3:0] af_on(input [2:0] m);
	case (m) 3'd1: af_on = 4'd3; 3'd2: af_on = 4'd2; 3'd3: af_on = 4'd2; 3'd4: af_on = 4'd1; 3'd5: af_on = 4'd1; default: af_on = 4'd0; endcase
endfunction
function automatic [3:0] af_len(input [2:0] m);
	case (m) 3'd1: af_len = 4'd6; 3'd2: af_len = 4'd5; 3'd3: af_len = 4'd4; 3'd4: af_len = 4'd3; 3'd5: af_len = 4'd2; default: af_len = 4'd1; endcase
endfunction
reg  [3:0] af1_phase = 4'd0, af2_phase = 4'd0;
reg        af1_held_d = 1'b0, af2_held_d = 1'b0;
wire [2:0] af1_mode = autofire_unlock ? status[12:10] : 3'd0;
wire [2:0] af2_mode = autofire_unlock ? status[15:13] : 3'd0;
always @(posedge clk_sys) begin
	af1_held_d <= p1_raw[4];
	af2_held_d <= p2_raw[4];
	if (p1_raw[4] & ~af1_held_d) af1_phase <= 4'd0;
	else if (frame_tick) af1_phase <= (af1_phase + 4'd1 >= af_len(af1_mode)) ? 4'd0 : af1_phase + 4'd1;
	if (p2_raw[4] & ~af2_held_d) af2_phase <= 4'd0;
	else if (frame_tick) af2_phase <= (af2_phase + 4'd1 >= af_len(af2_mode)) ? 4'd0 : af2_phase + 4'd1;
end
wire p1_b1 = (af1_mode != 3'd0) ? (p1_raw[4] & (af1_phase < af_on(af1_mode))) : p1_raw[4];
wire p2_b1 = (af2_mode != 3'd0) ? (p2_raw[4] & (af2_phase < af_on(af2_mode))) : p2_raw[4];

// ------------------------------------------------------------------
// INPUTS (MAME, active low): [0] start 1, [1] start 2, [2] coin 1, [3] coin 2,
// [5] service 1; [19:16] P1 up/down/left/right, [23:20] P1 B1..B4; [31:24] P2.
// Pad bits: 0 R, 1 L, 2 D, 3 U, 4-7 B1-B4, 8 Start, 9 Coin (the .mra order).
// ------------------------------------------------------------------
wire p1_start = joystick_0[8] | kb_start1, p2_start = joystick_1[8] | kb_start2;
wire p1_coin  = joystick_0[9] | kb_coin1,  p2_coin  = joystick_1[9] | kb_coin2;
wire [7:0] pl1 = {p1_raw[7:5], p1_b1, p1_raw[0], p1_raw[1], p1_raw[2], p1_raw[3]};   // B4 B3 B2 B1 R L D U
wire [7:0] pl2 = {p2_raw[7:5], p2_b1, p2_raw[0], p2_raw[1], p2_raw[2], p2_raw[3]};
wire [31:0] inputs = ~{pl2, pl1, 8'd0, 2'b00, kb_service | kb_f2, 1'b0, p2_coin, p1_coin, p2_start, p1_start};
wire [15:0] dsw = {dip_sw[1], dip_sw[0]};

// ------------------------------------------------------------------
// SDRAM and the ROM image (macplus_rom_hw)
// ------------------------------------------------------------------
wire [24:1] sd0_addr, sd1_addr, sd2_addr, sd3_addr;
wire        sd0_wrl, sd0_wrh, sd1_wrl, sd1_wrh, sd2_wrl, sd2_wrh, sd3_wrl, sd3_wrh;
wire [15:0] sd0_din, sd1_din, sd2_din, sd3_din;
wire [15:0] sd0_dout, sd1_dout, sd2_dout, sd3_dout;
wire [31:0] sd0_pair, sd1_pair, sd2_pair, sd3_pair;
wire        sd0_req, sd1_req, sd2_req, sd3_req, sd0_ack, sd1_ack, sd2_ack, sd3_ack;
sdram #(.REFRESH_CYCLES(10'd740)) sdram_inst
(
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .ready(sdram_ready),
	.init(~pll_locked), .clk(clk_ram), .prio_mode(2'd0),
	.addr0(sd0_addr), .wrl0(sd0_wrl), .wrh0(sd0_wrh), .din0(sd0_din), .dout0(sd0_dout), .dout0_pair(sd0_pair), .req0(sd0_req), .ack0(sd0_ack),
	.addr1(sd1_addr), .wrl1(sd1_wrl), .wrh1(sd1_wrh), .din1(sd1_din), .dout1(sd1_dout), .dout1_pair(sd1_pair), .req1(sd1_req), .ack1(sd1_ack),
	.addr2(sd2_addr), .wrl2(sd2_wrl), .wrh2(sd2_wrh), .din2(sd2_din), .dout2(sd2_dout), .dout2_pair(sd2_pair), .req2(sd2_req), .ack2(sd2_ack),
	.addr3(sd3_addr), .wrl3(sd3_wrl), .wrh3(sd3_wrh), .din3(sd3_din), .dout3(sd3_dout), .dout3_pair(sd3_pair), .req3(sd3_req), .ack3(sd3_ack)
);

wire        mrom_req, mrom_ack, srom_req, srom_ack, spr_req, spr_ready, spr_valid, smp_req, smp_ack;
wire [19:0] mrom_addr;  wire [31:0] mrom_data;
wire [18:0] srom_addr;  wire [15:0] srom_data;
wire [3:0]  bg_req, bg_ready, bg_valid;
wire [91:0] bg_addr;    wire [127:0] bg_data, spr_data;
wire [23:0] spr_addr;
wire [1:0]  smp_bank;   wire [20:0] smp_word;  wire [15:0] smp_data;
wire        rh_rd, rh_we;
wire [28:0] rh_addr;    wire [7:0] rh_burst, rh_be;  wire [63:0] rh_din;
wire        rot_we;

macplus_rom_hw rom_hw (
	.clk(clk_sys), .clk_ddr(CLK_VIDEO), .pwr_reset(por_rst), .reset(reset), .quiz(quiz),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
	.ioctl_addr({2'd0, ioctl_addr}), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait), .rom_ready(rom_ready),
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
	.ddr_yield(1'b0), .ddr_busy(DDRAM_BUSY | rot_we),
	.ddr_rd(rh_rd), .ddr_we(rh_we), .ddr_addr(rh_addr), .ddr_burstcnt(rh_burst), .ddr_din(rh_din), .ddr_be(rh_be),
	.ddr_dout(DDRAM_DOUT), .ddr_dout_ready(DDRAM_DOUT_READY),
	.dbg_copy_words(), .dbg_dl_bytes()
);

// ------------------------------------------------------------------
// High scores and cheats: byte accesses into the 32-bit big-endian main RAM
// through the core's back door (byte address A -> longword (A-0xF00000)>>2,
// lane 3 - A[1:0]).
// ------------------------------------------------------------------
wire [23:0] hs_addr;
wire  [7:0] hs_din;
wire  [7:0] hs_dout;
wire        hs_write, hs_access;
wire [23:0] hi_addr;
wire  [7:0] hi_din;
wire        hi_write;
wire        hs_pause_raw, hs_upload_req_raw;
wire        hs_enable = status[39];
wire        hs_active = hs_enable & ~hs_hold;
wire        hs_pause  = hs_pause_raw & hs_active;
reg  [23:0] hs_save_cnt = 24'd0;
always @(posedge clk_sys) begin
	if (status[30])        hs_save_cnt <= 24'd4800000;
	else if (|hs_save_cnt) hs_save_cnt <= hs_save_cnt - 1'b1;
end
wire hs_osd = OSD_STATUS & ~(|hs_save_cnt) & hs_active;
assign ioctl_upload_req = hs_upload_req_raw & hs_active;
hiscore #(.HS_ADDRESSWIDTH(24), .HS_SCOREWIDTH(8), .CFG_ADDRESSWIDTH(4), .CFG_LENGTHWIDTH(2)) hi (
	.clk(clk_sys), .reset(reset | hs_hold | ~hs_enable), .paused(hs_pause_raw), .autosave(1'b1),
	.OSD_STATUS(hs_osd), .ioctl_upload(ioctl_upload), .ioctl_upload_req(hs_upload_req_raw),
	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_index(ioctl_index[7:0]),
	.data_from_hps(ioctl_dout), .data_to_hps(ioctl_din), .data_from_ram(hs_dout), .data_to_ram(hi_din),
	.ram_address(hi_addr), .ram_write(hi_write), .ram_intent_read(), .ram_intent_write(),
	.pause_cpu(hs_pause_raw), .configured());
wire [23:0] ch_addr;
wire  [7:0] ch_din;
wire        ch_write, ch_access, ch_pause;
wire  [6:0] ch_avail;
cheats ch (
	.clk(clk_sys), .reset(reset),
	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_index(ioctl_index), .ioctl_dout(ioctl_dout),
	.enable(status[38:32]), .available(ch_avail), .vblank(vblank_core),
	.ram_addr(ch_addr), .ram_din(ch_din), .ram_write(ch_write), .ram_access(ch_access), .ram_dout(hs_dout), .pause_cpu(ch_pause));
assign hs_addr   = hs_pause ? hi_addr  : ch_addr;
assign hs_din    = hs_pause ? hi_din   : ch_din;
assign hs_write  = hs_pause ? hi_write : ch_write;
assign hs_access = hs_pause ? 1'b1     : ch_access;
wire [23:0] hs_off  = hs_addr - 24'hF00000;
wire [1:0]  hs_lane = 2'd3 - hs_addr[1:0];
wire [31:0] ram2_dout;
assign hs_dout = ram2_dout[{hs_lane, 3'b000} +: 8];

// ------------------------------------------------------------------
// The board
// ------------------------------------------------------------------
wire        ce_pix_core, hb_core, vb_core, hs_core, vs_core;
wire  [8:0] hcount_core, vcount_core;
wire [23:0] core_rgb, core_rgb_fade;
wire signed [15:0] snd_l, snd_r;
macplus_core #(.CE_NUM(8'd29)) core (
	.clk(clk_sys), .reset(reset | ~rom_ready | ~sdram_ready), .quiz(quiz),
	.pause(status[29] | hs_pause | ch_pause), .flip(status[17]),
	.inputs(inputs), .dsw(dsw),
	.ram2_sel(hs_access), .ram2_addr(hs_off[16:2]), .ram2_we(hs_write & hs_access), .ram2_be(4'b0001 << hs_lane),
	.ram2_din({4{hs_din}}), .ram2_dout(ram2_dout),
	.mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
	.srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_data(srom_data),
	.bg_req(bg_req), .bg_addr(bg_addr), .bg_ready(bg_ready), .bg_valid(bg_valid), .bg_data(bg_data),
	.spr_req(spr_req), .spr_addr(spr_addr), .spr_ready(spr_ready), .spr_valid(spr_valid), .spr_data(spr_data),
	.smp_req(smp_req), .smp_bank(smp_bank), .smp_word(smp_word), .smp_ack(smp_ack), .smp_data(smp_data),
	.ce_pix(ce_pix_core), .hcount(hcount_core), .vcount(vcount_core), .hblank(hb_core), .vblank(vb_core),
	.hsync(hs_core), .vsync(vs_core), .rgb(core_rgb), .rgb_fade(core_rgb_fade),
	.snd_l(snd_l), .snd_r(snd_r),
	.dbg_irq3(), .dbg_iack3(), .dbg_idle(), .dbg_es_writes(), .dbg_es_irq(), .dbg_latch_reads(),
	.dbg_latch_writes(), .dbg_cpu_addr(), .dbg_spr_max_cycles(), .dbg_spr_overruns(), .dbg_bg_overruns());
assign AUDIO_L = snd_l;
assign AUDIO_R = snd_r;
assign vblank_core = vb_core;

// ------------------------------------------------------------------
// Video. The core's pixel is two pixel ticks behind its raster position (M1,
// MP-5); the position handed to video_retime is delayed to match (MS1-59).
// The raster is 512 x 256 at 7.864 MHz; video_retime reads it back at 9.6 MHz
// (96 MHz / 10), 625 dots a line -- 6,250 clocks, exactly the core's line --
// with the picture in dots 0..383 and the same 256 lines (MP-7).
// OSD Flip is rot180 of the finished frame, done in the video block (NMK-21,
// MS1-13), so it reaches every output and does not need the framebuffer.
// ------------------------------------------------------------------
localparam integer RGB_LAT = 2;
reg [8:0] hc_lat [0:RGB_LAT-1];
reg [8:0] vc_lat [0:RGB_LAT-1];
integer rl;
always @(posedge clk_sys) if (ce_pix_core) begin
	hc_lat[0] <= hcount_core; vc_lat[0] <= vcount_core;
	for (rl = 1; rl < RGB_LAT; rl = rl + 1) begin hc_lat[rl] <= hc_lat[rl-1]; vc_lat[rl] <= vc_lat[rl-1]; end
end

wire        rt_ce, rt_hs, rt_vs, rt_hb, rt_vb, rt_vb_hs;
wire [23:0] rt_rgb;
video_retime #(
	.M0_X0(10'd0), .M0_HT(10'd625), .M0_HS(10'd452), .M0_HW(10'd45), .M0_AW(10'd384), .M0_DIV(5'd10),
	.M1_X0(10'd0), .M1_HT(10'd625), .M1_HS(10'd452), .M1_HW(10'd45), .M1_AW(10'd384), .M1_DIV(5'd10),
	.LINE_CLKS(6250), .VTOTAL_P(256),
	.VS_A(10'd0), .VE_A(10'd240), .VS_B(10'd0), .VE_B(10'd224), .VS_REL(10'd4)
) video_retime (
	.clk_w(clk_sys), .reset_w(reset), .ce_w(ce_pix_core),
	.hcount_w({1'b0, hc_lat[RGB_LAT-1]}), .vcount_w({1'b0, vc_lat[RGB_LAT-1]}), .rgb_w(core_rgb_fade),
	.mode1(1'b0), .tall240(quiz),
	.clk_r(clk_ram),
	.ce_r(rt_ce), .rgb_r(rt_rgb), .hs_r(rt_hs), .vs_r(rt_vs), .de_r(),
	.hb_r(rt_hb), .vb_r(rt_vb), .vb_hs_r(rt_vb_hs)
);
assign CLK_VIDEO = clk_ram;

wire       fb_rotating = ~((status[9:8] == 2'd0) | direct_video);
wire [2:0] fx = direct_video ? 3'd0 : status[3:1];
wire       scandoubler_en = ((fx != 3'd0) || forced_scandoubler) && ~fb_rotating;
assign VGA_SL = fx[2:1];

wire        vm_ce_pix, vm_hs, vm_vs, vm_hb, vm_vb;
wire [23:0] retimed_rgb;
wire [21:0] vm_gamma_bus;
wire        crt_on = status[101] & ~scandoubler_en & ~fb_rotating;
crt_chain #(
	.HTOTAL0(10'd625), .HTOTAL1(10'd625), .DIV0(5'd10), .DIV1(5'd10),
	.VTOTAL(256), .LINE_PX(400), .VSIZE_MAX(4)
) crt_chain (
	.clk(clk_ram), .ce_in(rt_ce), .rgb_in(rt_rgb),
	.hs_in(rt_hs), .vs_in(rt_vs), .hb_in(rt_hb), .vb_in(rt_vb), .vb_hs_in(rt_vb_hs),
	.mode1(1'b0), .enable(crt_on),
	.hsize($signed(status[100:96])), .hpos_raw(status[85:79]),
	.vshift($signed(status[78:74])), .vsize_code(status[107:104]),
	.vsize_mode(status[108]),
	.ce_out(vm_ce_pix), .rgb_out(retimed_rgb),
	.hs_out(vm_hs), .vs_out(vm_vs), .hb_out(vm_hb), .vb_out(vm_vb)
);
video_mixer #(.LINE_LENGTH(400), .HALF_DEPTH(0), .GAMMA(0)) video_mixer (
	.CLK_VIDEO(CLK_VIDEO), .ce_pix(vm_ce_pix), .CE_PIXEL(CE_PIXEL),
	.scandoubler(scandoubler_en), .hq2x(fx == 3'd1), .gamma_bus(vm_gamma_bus),
	.R(retimed_rgb[23:16]), .G(retimed_rgb[15:8]), .B(retimed_rgb[7:0]),
	.HSync(vm_hs), .VSync(vm_vs), .HBlank(vm_hb), .VBlank(vm_vb),
	.HDMI_FREEZE(1'b0), .freeze_sync(),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_VS(VGA_VS), .VGA_HS(VGA_HS), .VGA_DE(VGA_DE)
);

// ------------------------------------------------------------------
// Orientation and flip through screen_rotate (the framework's framebuffer);
// its DDR3 writes win every cycle they appear on (NMK-28), and macplus_rom_hw
// sees them as busy.
// ------------------------------------------------------------------
wire  [1:0] orientation = status[9:8];
wire        video_rotated;
wire        no_rotate  = (orientation == 2'd0) | direct_video;
wire        rotate_ccw = (orientation == 2'd2);
wire [28:0] rot_addr;
wire [63:0] rot_din;
wire  [7:0] rot_be;
screen_rotate screen_rotate (
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
	.rotate_ccw(rotate_ccw), .no_rotate(no_rotate), .flip(1'b0), .video_rotated(video_rotated),
	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE), .FB_VBL(FB_VBL), .FB_LL(FB_LL),
	.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(), .DDRAM_ADDR(rot_addr),
	.DDRAM_DIN(rot_din), .DDRAM_BE(rot_be), .DDRAM_WE(rot_we), .DDRAM_RD()
);
assign DDRAM_BURSTCNT = rot_we ? 8'd1    : rh_burst;
assign DDRAM_ADDR     = rot_we ? rot_addr : rh_addr;
assign DDRAM_DIN      = rot_we ? rot_din  : rh_din;
assign DDRAM_BE       = rot_we ? rot_be   : rh_be;
assign DDRAM_WE       = rot_we | rh_we;
assign DDRAM_RD       = ~rot_we & rh_rd;
assign FB_FORCE_BLANK = 1'b0;

reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = act_cnt[26] ? act_cnt[25:18] > act_cnt[7:0] : act_cnt[25:18] <= act_cnt[7:0];

endmodule
