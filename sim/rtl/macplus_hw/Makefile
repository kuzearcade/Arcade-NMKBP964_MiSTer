# M3: the core on the real memory path (macplus_rom_hw + rtl/sdram.sv + model + DDR3 model).
#   make && ./obj_dir/Vhw_top ~/mp_images/macrossp/ddr_image.bin FRAMES
RTL := ../../../rtl
SRCS := $(wildcard $(RTL)/macplus/*.sv) $(wildcard $(RTL)/savestate/*.sv) $(RTL)/sdram.sv $(RTL)/sdram_arb.sv $(RTL)/sdram_req.sv $(RTL)/rom_cache_n.sv \
        ../../models/sdram_model.sv $(RTL)/third_party_gen/tg68k/TG68KdotC_Kernel.v $(wildcard $(RTL)/third_party/es5506/*.sv)
all: obj_dir/Vhw_top microrom.mem nanorom.mem
microrom.mem nanorom.mem:
	cp $(RTL)/third_party/fx68k/$@ .
obj_dir/Vhw_top: tb.cpp hw_top.sv $(SRCS)
	verilator --cc --exe --build -O3 -j 8 -CFLAGS -O3 --x-assign fast --x-initial fast +define+SIMULATION -Wno-fatal \
		-Wno-WIDTH -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT -Wno-LATCH -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE \
		-Wno-IMPLICIT -Wno-SELRANGE -Wno-UNSIGNED -Wno-BLKANDNBLK -Wno-COMBDLY -Wno-CASEOVERLAP -Wno-TIMESCALEMOD \
		--top-module hw_top -y $(RTL)/macplus -y $(RTL)/savestate -y $(RTL) -y $(RTL)/third_party/es5506 -y $(RTL)/third_party/fx68k -y ../../models \
		$(RTL)/third_party_gen/tg68k/TG68KdotC_Kernel.v $(RTL)/third_party/fx68k/fx68k.sv $(RTL)/third_party/fx68k/fx68kAlu.sv \
		$(RTL)/third_party/fx68k/uaddrPla.sv hw_top.sv tb.cpp -o Vhw_top
clean:
	rm -rf obj_dir

# fast build: copies one burst; run with MP_PRELOAD=1 (the testbench preloads SDRAM)
fast: obj_fast/Vhw_top microrom.mem nanorom.mem
obj_fast/Vhw_top: tb.cpp hw_top.sv $(SRCS)
	verilator --cc --exe --build -O3 -j 8 -CFLAGS -O3 --x-assign fast --x-initial fast +define+SIMULATION -Wno-fatal \
		-Wno-WIDTH -Wno-PINCONNECTEMPTY -Wno-UNOPTFLAT -Wno-LATCH -Wno-MULTIDRIVEN -Wno-CASEINCOMPLETE \
		-Wno-IMPLICIT -Wno-SELRANGE -Wno-UNSIGNED -Wno-BLKANDNBLK -Wno-COMBDLY -Wno-CASEOVERLAP -Wno-TIMESCALEMOD \
		--Mdir obj_fast -GCOPY_BYTES=64 --top-module hw_top -y $(RTL)/macplus -y $(RTL)/savestate -y $(RTL) -y $(RTL)/third_party/es5506 \
		-y $(RTL)/third_party/fx68k -y ../../models \
		$(RTL)/third_party_gen/tg68k/TG68KdotC_Kernel.v $(RTL)/third_party/fx68k/fx68k.sv $(RTL)/third_party/fx68k/fx68kAlu.sv \
		$(RTL)/third_party/fx68k/uaddrPla.sv hw_top.sv tb.cpp -o Vhw_top
