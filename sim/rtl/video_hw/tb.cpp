// M1 through macplus_rom_hw (MP-20): a MAME state (sim/oracle/macplus_capture.lua)
// is written through the CPU port as in sim/rtl/video_state, the ROM rows come
// through the real front end, and frame 3 is compared with MAME's picture F+1.
// DDR3 model on clk_ddr (2x clk): MP_DLAT clk_ddr cycles of read latency
// (default 24), MP_DBUSY=n busy one cycle in n, MP_ROT=1 a one-cycle
// screen_rotate-like write every 10 cycles. SDRAM stub: ack MP_SLAT clk_ddr
// cycles after a request toggle (default 16).
//   ./obj_dir/Vvh_top GAME DDR_IMAGE TRACE_DIR F [F2 ...]
#include "Vvh_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <string>
#include <vector>
static std::vector<uint8_t> slurp(const std::string &p) {
	FILE *f = fopen(p.c_str(), "rb"); if (!f) { fprintf(stderr, "no %s\n", p.c_str()); exit(1); }
	fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
	std::vector<uint8_t> v(n); if (n && fread(v.data(), 1, n, f) != (size_t)n) exit(1); fclose(f); return v;
}
static int env(const char *n, int d) { return getenv(n) ? atoi(getenv(n)) : d; }
struct Beat { uint64_t due; uint64_t data; };
struct Sd { int lat; bool req_prev; uint64_t due; bool pend; };
int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 5) { fprintf(stderr, "usage: GAME DDR_IMAGE TRACE F...\n"); return 1; }
	std::string game = argv[1], tr = argv[3];
	bool quiz = game == "quizmoon";
	int H = quiz ? 224 : 240;
	int DLAT = env("MP_DLAT", 24), DBUSY = env("MP_DBUSY", 0), ROT = env("MP_ROT", 0), SLAT = env("MP_SLAT", 16);
	std::vector<uint8_t> ddr = slurp(argv[2]);
	auto W = [&](uint32_t w) -> uint32_t { size_t b = 2ull * w; return b + 1 < ddr.size() ? (ddr[b] | ddr[b+1] << 8) : 0; };
	int total_bad = 0;
	for (int ai = 4; ai < argc; ai++) {
		int F = atoi(argv[ai]);
		char fn[512]; snprintf(fn, sizeof fn, "%s/s%05d.bin", tr.c_str(), F);
		std::vector<uint8_t> st = slurp(fn);
		snprintf(fn, sizeof fn, "%s/p%05d.raw", tr.c_str(), F + 1);
		std::vector<uint8_t> pic = slurp(fn);
		Vvh_top *t = new Vvh_top;
		std::deque<Beat> beats;
		uint64_t cyc = 0;
		Sd sd[3] = {{SLAT, false, 0, false}, {SLAT, false, 0, false}, {SLAT, false, 0, false}};
		auto ddr_step = [&]() {
			t->ddr_dout_ready = 0;
			t->ddr_busy = (ROT && cyc % 10 == 0) || (DBUSY && cyc % DBUSY == 0);
			if (!t->ddr_busy) {
				if (t->ddr_rd) {
					uint64_t a = (uint64_t)t->ddr_addr * 8 - 0x30000000ull;
					uint64_t due = cyc + DLAT; if (!beats.empty() && beats.back().due >= due) due = beats.back().due + 1;
					for (int b = 0; b < t->ddr_burstcnt; b++) {
						uint64_t q = 0; for (int k = 7; k >= 0; k--) q = q << 8 | (a + b*8 + k < ddr.size() ? ddr[a + b*8 + k] : 0);
						beats.push_back({due + b, q});
					}
				}
			}
			if (!beats.empty() && beats.front().due <= cyc) { t->ddr_dout = beats.front().data; t->ddr_dout_ready = 1; beats.pop_front(); }
			// SDRAM stub: ports 0, 1, 3 (toggle protocol); reads return the aligned pair
			bool rq[3] = {(bool)t->sd_req0, (bool)t->sd_req1, (bool)t->sd_req3};
			uint32_t ad[3] = {t->sd_addr0, t->sd_addr1, t->sd_addr3};
			for (int p = 0; p < 3; p++) {
				if (rq[p] != sd[p].req_prev) { sd[p].req_prev = rq[p]; sd[p].pend = true; sd[p].due = cyc + sd[p].lat; }
				if (sd[p].pend && cyc >= sd[p].due) {
					uint32_t w = ad[p];   // word address
					uint32_t pair = W(w | 1) << 16 | W(w & ~1u);
					if (p == 0) { t->sd_pair0 = pair; t->sd_ack0 = rq[p]; }
					if (p == 1) { t->sd_pair1 = pair; t->sd_ack1 = rq[p]; }
					if (p == 2) { t->sd_pair3 = pair; t->sd_ack3 = rq[p]; }
					sd[p].pend = false;
				}
			}
		};
		auto tick = [&]() {
			for (int p = 0; p < 2; p++) {
				t->clk_ddr = 0; t->eval();
				ddr_step();
				t->clk_ddr = 1; t->clk = p == 0; t->eval(); cyc++;
			}
		};
		t->quiz = quiz; t->pwr_reset = 1; t->reset = 1; t->ioctl_download = 0; t->cpu_sel = 0;
		for (int i = 0; i < 200; i++) tick();
		t->pwr_reset = 0;
		for (int i = 0; i < 200; i++) tick();
		t->ioctl_download = 1; for (int i = 0; i < 100; i++) tick(); t->ioctl_download = 0;
		int guard = 0; while (!t->rom_ready && guard++ < 200000) tick();
		if (!t->rom_ready) { fprintf(stderr, "rom_ready never rose\n"); return 1; }
		t->reset = 0; for (int i = 0; i < 20; i++) tick();
		auto rd32 = [&](size_t off) { return (uint32_t)st[off] | st[off+1] << 8 | st[off+2] << 16 | (uint32_t)st[off+3] << 24; };
		auto wr = [&](uint32_t byteaddr, uint32_t v) {
			t->cpu_sel = 1; t->cpu_we = 1; t->cpu_addr = byteaddr >> 2; t->cpu_be = 0xF; t->cpu_din = v;
			do tick(); while (!t->cpu_ack);
			t->cpu_sel = 0; t->cpu_we = 0; tick();
		};
		const uint32_t base[4] = {0x900000, 0x908000, 0x910000, 0x918000};
		for (int L = 0; L < 4; L++) {
			for (int i = 0; i < 4096; i++) wr(base[L] + i*4, rd32(L*0x4000 + i*4));
			for (int i = 0; i < 128; i++)  wr(base[L] + 0x4200 + i*4, rd32(0x10000 + L*0x200 + i*4));
			for (int i = 0; i < 3; i++)    wr(base[L] + 0x5000 + i*4, rd32(0x10800 + L*12 + i*4));
		}
		for (int i = 0; i < 4096; i++) wr(0xA00000 + i*4, rd32(0x10840 + i*4));
		for (int i = 0; i < 3072; i++) wr(0x800000 + i*4, rd32(0x1A840 + i*4));   // old2 -> live; two copies
		std::vector<uint32_t> got(384 * H, 0);
		int frames = 0; bool cap = false; int prevv = t->vcount;
		while (frames < 4) {
			tick();
			if (t->ce_pix) {
				int h = t->hcount, v = t->vcount;
				if (cap && h >= 2 && h <= 385 && v < H) got[v * 384 + h - 2] = t->rgb;   // as video_state
				if (v == 0 && prevv == 255) { frames++; cap = frames == 3; }
				prevv = v;
			}
		}
		int diff = 0;
		for (int i = 0; i < 384 * H; i++) {
			uint32_t e = (pic[i*4] | pic[i*4+1] << 8 | pic[i*4+2] << 16) & 0xFFFFFF;
			if (e != (got[i] & 0xFFFFFF)) diff++;
		}
		auto u16 = [](uint64_t v, int k) { return (unsigned)((v >> (16*k)) & 0xFFFF); };
		printf("state %d vs MAME %d: %d differing  %s | spr max %u clk, %u overruns | bg max %u/%u/%u/%u clk, overruns %u/%u/%u/%u\n",
		       F, F + 1, diff, diff ? "DIFFERS" : "MATCH", t->dbg_spr_max_cycles, t->dbg_spr_overruns,
		       u16(t->dbg_bg_max_cycles,0), u16(t->dbg_bg_max_cycles,1), u16(t->dbg_bg_max_cycles,2), u16(t->dbg_bg_max_cycles,3),
		       u16(t->dbg_bg_overruns,0), u16(t->dbg_bg_overruns,1), u16(t->dbg_bg_overruns,2), u16(t->dbg_bg_overruns,3));
		fflush(stdout);
		if (getenv("MP_PPM")) {
			FILE *f = fopen(getenv("MP_PPM"), "wb"); fprintf(f, "P6\n384 %d\n255\n", H);
			for (int i = 0; i < 384 * H; i++) { uint8_t c[3] = {(uint8_t)(got[i] >> 16), (uint8_t)(got[i] >> 8), (uint8_t)got[i]}; fwrite(c, 1, 3, f); }
			fclose(f);
		}
		total_bad += diff != 0;
		delete t;
	}
	return total_bad ? 2 : 0;
}
