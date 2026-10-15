# M1 through macplus_rom_hw (MP-20): MAME's video state, ROM rows through the
# real front end and a DDR3 model with board-like latency.
#   make && MP_DLAT=100 ./obj_dir/Vvh_top macrossp ~/mp_images/macrossp/ddr_image.bin ../../oracle/traces/macrossp_stage2 16900
RTL := ../../../rtl
SRCS := $(wildcard $(RTL)/macplus/*.sv) $(RTL)/sdram_arb.sv $(RTL)/sdram_req.sv $(RTL)/rom_cache_n.sv
all: obj_dir/Vvh_top
obj_dir/Vvh_top: vh_top.sv tb.cpp $(SRCS)
	verilator --cc --exe --build -O3 -j 8 -Wno-fatal -Wno-WIDTH -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT -Wno-MULTIDRIVEN \
		--top-module vh_top -y $(RTL)/macplus -y $(RTL)/savestate -y $(RTL) vh_top.sv tb.cpp -o Vvh_top
clean:
	rm -rf obj_dir
