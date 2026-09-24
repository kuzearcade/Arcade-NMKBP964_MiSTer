// M3: the core on the real memory path. The DDR3 port is modelled here:
// MP_DLAT clk_ram cycles of read latency (default 24 = 250 ns), BUSY
// back-pressure one cycle in MP_DBUSY (default 0 = never), and optional
// screen_rotate-like write pressure (MP_ROT=1: a one-cycle write every 10
// clk_ram, the rate of 384x240 at 60 Hz rotated through 64-bit words, plus
// margin). The image is preloaded (Main_MiSTer's address= path) and the
// download is signalled by toggling ioctl_download, so the copier runs.
//   ./obj_dir/Vhw_top IMAGE_BIN FRAMES      (MP_GAME, MP_FRAMEDIR, MP_EVERY as macplus_frames)
#include "Vhw_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>
static int env(const char *n, int d) { const char *v = getenv(n); return v ? atoi(v) : d; }
struct Beat { uint64_t due; uint64_t data; };
int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 3) { fprintf(stderr, "usage: IMAGE FRAMES\n"); return 1; }
	FILE *f = fopen(argv[1], "rb"); if (!f) { perror(argv[1]); return 1; }
	std::vector<uint8_t> ddr(0x4000000, 0);
	size_t n = fread(ddr.data(), 1, ddr.size(), f); fclose(f);
	int frames = atoi(argv[2]);
	bool quiz = getenv("MP_GAME") && std::string(getenv("MP_GAME")) == "quizmoon";
	int H = quiz ? 224 : 240, DLAT = env("MP_DLAT", 24), DBUSY = env("MP_DBUSY", 0), ROT = env("MP_ROT", 0);
	int EVERY = env("MP_EVERY", 60), FROM = env("MP_FROM", 0);
	const char *fdir = getenv("MP_FRAMEDIR");
	Vhw_top *t = new Vhw_top;
	std::deque<Beat> beats;
	uint64_t cyc = 0;           // clk_ram cycles
	std::vector<uint32_t> fb(384 * 256, 0);
	int frame = 0, prevv = 0; bool copied = false; uint64_t copy_start = 0;
	unsigned last_idle = 0, last_es = 0;
	t->quiz = quiz; t->inputs = 0xFFFFFFFF; t->dsw = quiz ? 0xFFFF : 0xBFFF;
	t->pwr_reset = 1; t->reset = 1; t->ioctl_download = 0; t->ddr_busy = 0; t->ddr_dout_ready = 0;
	auto half = [&](bool ram_rise, bool sys_rise) {
		t->clk_ram = ram_rise; t->clk_sys = sys_rise ? 1 : (ram_rise ? t->clk_sys : 0);
		t->eval();
	};
	// DDR model, evaluated on each clk_ram rising edge
	auto ddr_step = [&]() {
		t->ddr_dout_ready = 0;
		bool rot = ROT && (cyc % 10 == 0);
		t->ddr_busy = rot || (DBUSY && (cyc % DBUSY == 0));
		if (!t->ddr_busy) {
			if (t->ddr_rd) {
				uint64_t a = (uint64_t)t->ddr_addr * 8 - 0x30000000ull;
				for (int b = 0; b < t->ddr_burstcnt; b++) {
					uint64_t q = 0; for (int k = 7; k >= 0; k--) q = q << 8 | (a + b*8 + k < ddr.size() ? ddr[a + b*8 + k] : 0);
					beats.push_back({cyc + DLAT + b, q});
				}
			} else if (t->ddr_we) {
				uint64_t a = (uint64_t)t->ddr_addr * 8 - 0x30000000ull;
				for (int k = 0; k < 8; k++) if ((t->ddr_be >> k & 1) && a + k < ddr.size()) ddr[a + k] = (t->ddr_din >> (8*k)) & 0xFF;
			}
		}
		if (!beats.empty() && beats.front().due <= cyc) { t->ddr_dout = beats.front().data; t->ddr_dout_ready = 1; beats.pop_front(); }
	};
	// clk_ram = 2x clk_sys: four half-steps per clk_sys period
	auto tick = [&]() {
		for (int p = 0; p < 2; p++) {
			t->clk_ram = 0; t->eval();
			ddr_step();
			t->clk_ram = 1; if (p == 0) t->clk_sys = 1; else t->clk_sys = 0;   // clk_sys rises with the first clk_ram rise
			t->eval(); cyc++;
		}
	};
	for (int i = 0; i < 200; i++) tick();
	t->pwr_reset = 0;
	for (int i = 0; i < 2000; i++) tick();
	// the download: the image is already in DDR3; toggle ioctl_download
	t->ioctl_download = 1; for (int i = 0; i < 100; i++) tick(); t->ioctl_download = 0;
	t->reset = 0; copy_start = cyc;
	while (frame < frames) {
		tick();
		if (!copied && t->rom_ready) { copied = true; printf("copy done: %u words in %.2f ms of board time\n", t->dbg_copy_words, (cyc - copy_start) / 96000.0); fflush(stdout); }
		if (t->ce_pix && t->rom_ready) {
			int h = t->hcount, v = t->vcount;
			if (h >= 2 && h <= 385 && v < H) fb[v * 384 + h - 2] = t->rgb;
			if (v == 0 && prevv == 255) {
				if (fdir && frame >= FROM) { char fn[512]; snprintf(fn, sizeof fn, "%s/f%05d.raw", fdir, frame);
					FILE *o = fopen(fn, "wb"); fwrite(fb.data(), 4, 384 * H, o); fclose(o); }
				if (frame % EVERY == 0) {
					int nb = 0; for (int i = 0; i < 384 * H; i++) nb += (fb[i] & 0xFFFFFF) != 0;
					printf("f=%d nonblack=%d irq3=%u idle=+%u es_w=+%u latch_w=%u spr_over=%u bg_over=%llx cpu=%06x\n", frame, nb, t->dbg_irq3,
					       t->dbg_idle - last_idle, t->dbg_es_writes - last_es, t->dbg_latch_writes, t->dbg_spr_overruns,
					       (unsigned long long)t->dbg_bg_overruns, t->dbg_cpu_addr & 0xFFFFFF);
					fflush(stdout); last_idle = t->dbg_idle; last_es = t->dbg_es_writes;
				}
				frame++;
			}
			prevv = v;
		}
	}
	delete t;
	return 0;
}
