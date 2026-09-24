# M2: the whole board from reset (TG68K netlist, fx68k, ES5506), ROMs from arrays.
#   make && ./obj_dir/Vmacplus_core IMAGES_DIR FRAMES
# The rule depends on every RTL file Verilator pulls in through -y (MS1-58).
RTL := ../../../rtl
SRCS := $(wildcard $(RTL)/macplus/*.sv) $(RTL)/third_party_gen/tg68k/TG68KdotC_Kernel.v \
        $(wildcard $(RTL)/third_party/es5506/*.sv) $(RTL)/third_party/fx68k/fx68k.sv $(RTL)/third_party/fx68k/fx68kAlu.sv $(RTL)/third_party/fx68k/uaddrPla.sv
all: obj_dir/Vmacplus_core microrom.mem nanorom.mem
microrom.mem nanorom.mem:
	cp $(RTL)/third_party/fx68k/$@ .
obj_dir/Vmacplus_core: tb.cpp $(SRCS)
	verilator --cc --exe --build -O3 -j 8 -CFLAGS -O3 --x-assign fast --x-initial fast -Wno-fatal \
		-Wno-WIDTH -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT -Wno-LATCH -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE \
		-Wno-IMPLICIT -Wno-SELRANGE -Wno-UNSIGNED -Wno-BLKANDNBLK -Wno-COMBDLY -Wno-CASEOVERLAP -Wno-TIMESCALEMOD \
		--top-module macplus_core -y $(RTL)/macplus -y $(RTL)/third_party/es5506 -y $(RTL)/third_party/fx68k \
		$(RTL)/third_party_gen/tg68k/TG68KdotC_Kernel.v $(RTL)/third_party/fx68k/fx68k.sv $(RTL)/third_party/fx68k/fx68kAlu.sv $(RTL)/third_party/fx68k/uaddrPla.sv \
		$(RTL)/macplus/macplus_core.sv tb.cpp -o Vmacplus_core
clean:
	rm -rf obj_dir
