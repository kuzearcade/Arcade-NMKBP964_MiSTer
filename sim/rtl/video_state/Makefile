# M1: the video block from a MAME state against MAME's picture (MP-1 pairing).
#   make && ./obj_dir/Vvs_top macrossp ~/mp_images/macrossp ../../oracle/traces/macrossp_play 900
# The rule depends on every RTL file verilator finds through -y (MS1-58).
RTL := ../../../rtl
SRCS := $(wildcard $(RTL)/macplus/*.sv)
all: obj_dir/Vvs_top
obj_dir/Vvs_top: vs_top.sv tb.cpp $(SRCS)
	verilator --cc --exe --build -O3 -j 8 -Wno-fatal -Wno-WIDTH -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT \
		--top-module vs_top -y $(RTL)/macplus vs_top.sv tb.cpp -o Vvs_top
clean:
	rm -rf obj_dir
