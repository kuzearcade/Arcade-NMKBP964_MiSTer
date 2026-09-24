// M3: the core on the real memory path. The DDR3 port is modelled here:
// MP_DLAT clk_ram cycles of read latency (default 24 = 250 ns), BUSY
// back-pressure one cycle in MP_DBUSY (default 0 = never), and optional
// screen_rotate-like write pressure (MP_ROT=1: a one-cycle write every 10
// clk_ram, the rate of 384x240 at 60 Hz rotated through 64-bit words, plus
// margin). The image is preloaded (Main_MiSTer's address= path) and the
// download is signalled by toggling ioctl_download, so the copier runs.
//   ./obj_dir/Vhw_top IMAGE_BIN FRAMES      (MP_GAME, MP_FRAMEDIR, MP_EVERY as macplus_frames)
#include "Vhw_top.h"
#include "Vhw_top___024root.h"
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
	if (getenv("MP_PRELOAD")) {   // the fast build: SDRAM holds the image already
		auto &mem = t->rootp->hw_top__DOT__u_model__DOT__mem;
		for (long k = 0; k < 0x1600000 / 2; k++) mem[k] = ddr[2*k] | ddr[2*k+1] << 8;
	}
	for (int i = 0; i < 200; i++) tick();
	t->pwr_reset = 0;
	for (int i = 0; i < 2000; i++) tick();
	// the download: the image is already in DDR3; toggle ioctl_download
	t->ioctl_download = 1; for (int i = 0; i < 100; i++) tick(); t->ioctl_download = 0;
	t->reset = 0; copy_start = cyc;
	// response check: each stream's requests are recorded when accepted (req & ready)
	// and its responses compared, in order, with the image's bytes
	std::deque<uint32_t> spr_q, bg_qs[4];
	long spr_bad = 0, spr_n = 0, bg_bad[4] = {0,0,0,0}, bg_n[4] = {0,0,0,0};
	auto img16 = [&](uint32_t off, uint32_t *w) { for (int k = 0; k < 4; k++) { uint32_t v = 0; for (int b = 3; b >= 0; b--) v = v << 8 | ddr[off + 4*k + b]; w[k] = v; } };
	auto check_streams = [&]() {
		if (t->t_spr_req && t->t_spr_ready) spr_q.push_back(t->t_spr_addr);
		if (t->t_spr_valid && !spr_q.empty()) {
			uint32_t w[4]; img16(0x600000 + spr_q.front(), w); spr_n++;
			bool ok = true; for (int k = 0; k < 4; k++) ok &= t->t_spr_data[k] == w[k];
			if (!ok && spr_bad++ < 5) printf("SPR mismatch #%ld addr %06x got %08x.. want %08x..\n", spr_n, spr_q.front(), t->t_spr_data[0], w[0]);
			spr_q.pop_front();
		}
		for (int L = 0; L < 4; L++) {
			if ((t->t_bg_req >> L & 1) && (t->t_bg_ready >> L & 1)) {
				uint32_t a = 0; for (int b = 0; b < 23; b++) a |= ((t->t_bg_addr[(L*23+b)/32] >> ((L*23+b)%32)) & 1u) << b;
				bg_qs[L].push_back(a);
			}
			if ((t->t_bg_valid >> L & 1) && !bg_qs[L].empty()) {
				uint32_t base = L < 3 ? 0x1600000 + L * 0x800000 : 0x500000;
				uint32_t w[4]; img16(base + bg_qs[L].front(), w); bg_n[L]++;
				int nw = L < 3 ? 4 : 2; bool ok = true; for (int k = 0; k < nw; k++) ok &= t->t_bg_data[k] == w[k];
				if (!ok && bg_bad[L]++ < 3) printf("BG%d mismatch #%ld addr %06x got %08x %08x want %08x %08x\n", L, bg_n[L], bg_qs[L].front(), t->t_bg_data[0], t->t_bg_data[1], w[0], w[1]);
				bg_qs[L].pop_front();
			}
		}
	};
	while (frame < frames) {
		tick(); if (t->rom_ready) check_streams();
		if (!copied && t->rom_ready) {
			copied = true; printf("copy done: %u words in %.2f ms of board time\n", t->dbg_copy_words, (cyc - copy_start) / 96000.0);
			// the copy's integrity: SDRAM word k must be {image[2k+1], image[2k]}
			// (with MP_PRELOAD this checks the preload)
			auto &mem = t->rootp->hw_top__DOT__u_model__DOT__mem;
			long bad = 0, first = -1;
			for (long k = 0; k < 0x600000 / 2; k++) {
				uint16_t want = ddr[2*k] | ddr[2*k+1] << 8;
				if (mem[k] != want) { if (first < 0) first = k; bad++; }
			}
			printf("copy check: %ld of %d words differ, first at byte 0x%lx\n", bad, 0x600000 / 2, first * 2);
			if (first >= 0) for (long k = first; k < first + 8; k++) printf("  byte 0x%lx: sdram %04x image %02x%02x\n", k*2, mem[k], ddr[2*k+1], ddr[2*k]);
			fflush(stdout);
		}
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
				if (getenv("MP_PLAY")) {
					// macplus_play.lua's inputs for the frame about to start (no cheat pokes)
					int F = frame, F0 = env("MP_PLAY_FROM", 600); uint32_t in = 0xFFFFFFFF;
					if (F >= F0 && F < F0 + 6) in &= ~(1u << 2);
					if (F >= F0 + 60 && F < F0 + 66) in &= ~(1u << 0);
					if (F >= F0 + 120) {
						if ((F % 8) < 4) in &= ~(1u << 20);
						if ((F % 300) < 4) in &= ~(1u << 21);
						static const int mv[7][2] = {{-1,-1},{16,-1},{18,-1},{17,-1},{19,-1},{16,19},{17,18}};
						const int *m = mv[(F / 60) % 7];
						for (int k = 0; k < 2; k++) if (m[k] >= 0) in &= ~(1u << m[k]);
					}
					t->inputs = in;
				}
			}
			prevv = v;
		}
	}
	printf("program ROM: %u requests, mean latency %.2f clocks, max %u\n", t->dbg_mlat_n,
	       t->dbg_mlat_n ? (double)t->dbg_mlat_sum / t->dbg_mlat_n : 0.0, t->dbg_mlat_max);
	printf("stream check: sprite %ld of %ld bad; BG %ld/%ld %ld/%ld %ld/%ld, text %ld/%ld bad\n", spr_bad, spr_n,
	       bg_bad[0], bg_n[0], bg_bad[1], bg_n[1], bg_bad[2], bg_n[2], bg_bad[3], bg_n[3]);
	delete t;
	return 0;
}
