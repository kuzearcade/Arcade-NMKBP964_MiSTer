// M1 gate: the video block from a MAME state (sim/oracle/macplus_capture.lua)
// against MAME's picture F+1 (MP-1). The state is written through the CPU port;
// two vblank copies carry the sprite list into old2 (STAGES=2); frame 3 is
// captured. ROM rows are served with a latency of MP_LAT clocks (default 40),
// one BG response a clock, as the DDR3 arbiter will.
//   ./obj_dir/Vvs_top GAME IMAGES_DIR TRACE_DIR F [F2 ...]
#include "Vvs_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>
static std::vector<uint8_t> slurp(const std::string &p) {
	FILE *f = fopen(p.c_str(), "rb"); if (!f) { fprintf(stderr, "no %s\n", p.c_str()); exit(1); }
	fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
	std::vector<uint8_t> v(n); if (n && fread(v.data(), 1, n, f) != (size_t)n) exit(1); fclose(f); return v;
}
struct Req { uint64_t due; int src; uint32_t addr; };
int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 5) { fprintf(stderr, "usage: GAME IMAGES TRACE F...\n"); return 1; }
	std::string game = argv[1], img = argv[2], tr = argv[3];
	bool quiz = game == "quizmoon";
	int H = quiz ? 224 : 240;
	int LAT = getenv("MP_LAT") ? atoi(getenv("MP_LAT")) : 40;
	std::vector<uint8_t> bg[3] = {slurp(img + "/bg0.bin"), slurp(img + "/bg1.bin"), slurp(img + "/bg2.bin")};
	std::vector<uint8_t> fg = slurp(img + "/fg.bin"), spr = slurp(img + "/spr.bin");
	int total_bad = 0;
	for (int ai = 4; ai < argc; ai++) {
		int F = atoi(argv[ai]);
		char fn[512]; snprintf(fn, sizeof fn, "%s/s%05d.bin", tr.c_str(), F);
		std::vector<uint8_t> st = slurp(fn);
		snprintf(fn, sizeof fn, "%s/p%05d.raw", tr.c_str(), F + 1);
		std::vector<uint8_t> pic = slurp(fn);
		Vvs_top *t = new Vvs_top;
		uint64_t now = 0;
		std::deque<Req> bgq, sq;
		auto rd32 = [&](size_t off) { return (uint32_t)st[off] | st[off+1] << 8 | st[off+2] << 16 | (uint32_t)st[off+3] << 24; };
		auto row = [&](int src, uint32_t a, uint8_t *o) {
			memset(o, 0, 16);
			const std::vector<uint8_t> &r = src < 3 ? bg[src] : src == 3 ? fg : spr;
			for (int i = 0; i < 16; i++) if (a + i < r.size()) o[i] = r[a + i];
		};
		auto tick = [&]() {
			// requests: accept each stream's request every clock it is raised
			t->bg_ready = 0xF; t->spr_ready = 1;
			t->clk = 0; t->eval();
			for (int s = 0; s < 4; s++) if (t->bg_req >> s & 1) {
				uint32_t a = 0; for (int b = 0; b < 23; b++) a |= ((t->bg_addr[(s*23+b)/32] >> ((s*23+b)%32)) & 1u) << b;
				bgq.push_back({now + LAT, s, a});
			}
			if (t->spr_req) sq.push_back({now + LAT, 4, t->spr_addr});
			// responses (set up before the rising edge)
			t->bg_valid = 0; t->spr_valid = 0;
			if (!bgq.empty() && bgq.front().due <= now) {
				uint8_t o[16]; row(bgq.front().src, bgq.front().addr, o);
				for (int w = 0; w < 4; w++) t->bg_data[w] = o[w*4] | o[w*4+1] << 8 | o[w*4+2] << 16 | (uint32_t)o[w*4+3] << 24;
				t->bg_valid = 1 << bgq.front().src; bgq.pop_front();
			}
			if (!sq.empty() && sq.front().due <= now) {
				uint8_t o[16]; row(4, sq.front().addr, o);
				for (int w = 0; w < 4; w++) t->spr_data[w] = o[w*4] | o[w*4+1] << 8 | o[w*4+2] << 16 | (uint32_t)o[w*4+3] << 24;
				t->spr_valid = 1; sq.pop_front();
			}
			t->clk = 1; t->eval(); now++;
		};
		t->quiz = quiz; t->reset = 1; t->cpu_sel = 0;
		for (int i = 0; i < 20; i++) tick();
		t->reset = 0;
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
		// run until the third frame after two copies, capture it
		std::vector<uint32_t> got(384 * H, 0);
		int frames = 0; bool cap = false; int prevv = t->vcount;
		while (frames < 4) {
			tick();
			if (t->ce_pix) {
				int h = t->hcount, v = t->vcount;
				if (cap && h >= 2 && h <= 385 && v < H) got[v * 384 + h - 2] = t->rgb;   // rgb is two pixels behind hcount here (measured)
				if (v == 0 && prevv == 255) { frames++; cap = frames == 3; }
				prevv = v;
			}
		}
		int diff = 0, nb = 0;
		for (int i = 0; i < 384 * H; i++) {
			uint32_t e = (pic[i*4] | pic[i*4+1] << 8 | pic[i*4+2] << 16) & 0xFFFFFF;
			if (e) nb++;
			if (e != (got[i] & 0xFFFFFF)) diff++;
		}
		auto u16 = [](uint64_t v, int k) { return (unsigned)((v >> (16*k)) & 0xFFFF); };
		printf("state %d vs MAME picture %d: %d differing of %d (MAME non-black %d)  %s | spr max %u clk, %u hits, %u overruns | bg max %u/%u/%u/%u clk, overruns %u/%u/%u/%u, unknown %u\n",
		       F, F + 1, diff, 384 * H, nb, diff ? "DIFFERS" : "MATCH",
		       t->dbg_spr_max_cycles, t->dbg_spr_max_hits, t->dbg_spr_overruns,
		       u16(t->dbg_bg_max_cycles,0), u16(t->dbg_bg_max_cycles,1), u16(t->dbg_bg_max_cycles,2), u16(t->dbg_bg_max_cycles,3),
		       u16(t->dbg_bg_overruns,0), u16(t->dbg_bg_overruns,1), u16(t->dbg_bg_overruns,2), u16(t->dbg_bg_overruns,3),
		       u16(t->dbg_bg_unknown,0) + u16(t->dbg_bg_unknown,1) + u16(t->dbg_bg_unknown,2));
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
