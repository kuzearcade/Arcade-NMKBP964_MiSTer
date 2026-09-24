# Arcade-NMKBP964_MiSTer timing constraints, derived from JalecoMS1Z.sdc.

#
# sys/sys_top.sdc is the MiSTer framework's own base file (root clocks,
# virtual clocks, exclusive groups, OSD/scaler false paths).
source sys/sys_top.sdc

derive_pll_clocks
derive_clock_uncertainty

# ------------------------------------------------------------------
# Core clock groups
# ------------------------------------------------------------------
# The game logic (68EC020, 68000, ES5506, video) runs on clk_sys at 48 MHz and
# rtl/sdram.sv on clk_ram at 96 MHz, both outputs of the hand-written altpll
# in rtl/pll.v, whose names do not match sys_top.sdc's wildcard. Each output
# is its OWN exclusive group: the sdram req/ack is a toggle handshake with
# two-flop synchronisers, not a synchronous path (MS1BCD, same PLL).
set core_pll_groups {}
foreach_in_collection c [get_clocks {emu|pll*|altpll_component|*PLL_OUTPUT_COUNTER|divclk}] {
	lappend core_pll_groups -group [get_clock_info -name $c]
}
set_clock_groups -exclusive \
	{*}$core_pll_groups \
	-group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks {spi_sck}] \
	-group [get_clocks {hdmi_sck}] \
	-group [get_clocks {*|h2f_user0_clk}] \
	-group [get_clocks {FPGA_CLK1_50}] \
	-group [get_clocks {FPGA_CLK2_50}] \
	-group [get_clocks {FPGA_CLK3_50}]

# ------------------------------------------------------------------
# CRT Adjust multicycle (crt_vsize: written on the second clock of an output
# line, consumed on the fourth).
# ------------------------------------------------------------------
set vsz_ac [get_registers {*|crt_chain:crt_chain|crt_vsize:u_vsize|o_active_cyc[*]}]
set vsz_ds [get_registers {*|crt_chain:crt_chain|crt_vsize:u_vsize|o_de_start[*]}]
set_multicycle_path -setup 2 -from $vsz_ac -to $vsz_ds
set_multicycle_path -hold  1 -from $vsz_ac -to $vsz_ds

# The DIP bank changes only while the core is held in reset for the download
# and its tail (MS1-53), so nothing samples it on the clock it changes.
set_false_path -from [get_registers {*|dip_sw[*][*]}]
