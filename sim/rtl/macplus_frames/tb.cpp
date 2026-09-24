// M2: the whole board from reset against MAME. ROMs are served from the
// images tools/mk_macplus_images.py builds, at small fixed latencies.
//   ./obj_dir/Vmacplus_core IMAGES_DIR FRAMES
// Environment:
//   MP_GAME=quizmoon     (default macrossp)
//   MP_FRAMEDIR=dir      dump frames as fNNNNN.raw (u32 0x00RRGGBB, MAME's layout)
//   MP_FROM=n            first frame dumped (default 0)
//   MP_EVERY=n           print a status line every n frames (default 60)
//   MP_LAT=n             graphics/sample ROM latency in clocks (default 30)
//   MP_MLAT=n            program ROM latency (default 2)
//   MP_WAV=file          raw 16-bit stereo PCM at 48 kHz (the ES5506 output, sampled)
//   MP_PLAY=1            scripted play as sim/oracle/macplus_play.lua (coin at MP_PLAY_FROM,
//                        default 600; start +60; fire, bomb and moves from +120) and, for
//                        macrossp, its two cheat pokes each frame through the RAM back door
//   MP_SS=T,K            (obj_ss build, top ss_top) SS-13's savestate gate: save slot 0 at
//                        frame T; slot 1 K frames after it resumes; load slot 0; slot 2 K
//                        frames after that resumes. Slots 1 and 2 are one state reached two
//                        ways: every differing word is named per region, and the K pictures
//                        after each resume are compared. MP_SS_DUMP=dir writes the slots.
#ifdef MP_SS
#include "Vss_top.h"
typedef Vss_top Top;
#else
#include "Vmacplus_core.h"
typedef Vmacplus_core Top;
#endif
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
static int env(const char *n, int d) { const char *v = getenv(n); return v ? atoi(v) : d; }
struct Req { uint64_t due; int src; uint32_t addr; };
int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (argc < 3) { fprintf(stderr, "usage: IMAGES FRAMES\n"); return 1; }
	std::string img = argv[1];
	int frames = atoi(argv[2]);
	std::string game = getenv("MP_GAME") ? getenv("MP_GAME") : "macrossp";
	bool quiz = game == "quizmoon";
	int H = quiz ? 224 : 240;
	int LAT = env("MP_LAT", 30), MLAT = env("MP_MLAT", 2), EVERY = env("MP_EVERY", 60), FROM = env("MP_FROM", 0);
	const char *fdir = getenv("MP_FRAMEDIR");
	std::vector<uint8_t> mainr = slurp(img + "/main.bin"), snd = slurp(img + "/snd.bin"), spr = slurp(img + "/spr.bin"),
	                     fg = slurp(img + "/fg.bin"), smp = slurp(img + "/smp.bin");
	std::vector<uint8_t> bg[3] = {slurp(img + "/bg0.bin"), slurp(img + "/bg1.bin"), slurp(img + "/bg2.bin")};
	FILE *wav = getenv("MP_WAV") ? fopen(getenv("MP_WAV"), "wb") : nullptr;
	bool play = getenv("MP_PLAY") != nullptr;
	int F0 = env("MP_PLAY_FROM", 600);
	int TRF = env("MP_TRACE_FRAME", -1);   // with +mptrace and a +define+MP_TRACE build

	Top *t = new Top;
#ifdef MP_SS
	// DDR: four slots of 0x10000 64-bit words from 0; reads answer after 8 clocks
	std::vector<uint64_t> ddr(4 * 0x10000, 0);
	std::deque<std::pair<uint64_t, uint32_t>> ddrq;
	int SS_T = 300, SS_K = 60;
	if (getenv("MP_SS")) sscanf(getenv("MP_SS"), "%d,%d", &SS_T, &SS_K);
	int ss_step = 0, ss_mark = -1;            // step: 0 save0 1 wait 2 save1 3 wait 4 load0 5 wait 6 save2 7 wait 8 done
	std::vector<uint64_t> hash_a, hash_b;
	t->save_req = 0; t->load_req = 0; t->slot = 0;
#endif
	uint64_t now = 0;
	std::deque<Req> bgq, sq;
	int mcount = -1, scount = -1, smpcount = -1;
	auto row = [&](int src, uint32_t a, uint32_t *o) {
		uint8_t b[16]; memset(b, 0, 16);
		const std::vector<uint8_t> &r = src < 3 ? bg[src] : src == 3 ? fg : spr;
		for (int i = 0; i < 16; i++) if (a + i < r.size()) b[i] = r[a + i];
		for (int w = 0; w < 4; w++) o[w] = b[w*4] | b[w*4+1] << 8 | b[w*4+2] << 16 | (uint32_t)b[w*4+3] << 24;
	};
	std::vector<uint32_t> fb(384 * 256, 0);
	int frame = 0, prevv = 0;
	uint64_t next_audio = 0;
	unsigned last_idle = 0, last_es = 0, last_lw = 0, last_irq = 0;
	t->trace_on = 0;
	t->quiz = quiz; t->pause = 0; t->flip = getenv("MP_FLIP") ? 1 : 0; t->ram2_sel = 0; t->ram2_we = 0; t->ram2_addr = 0; t->ram2_be = 0; t->ram2_din = 0;
	t->inputs = 0xFFFFFFFF;
	t->dsw = quiz ? 0xFFFF : 0xBFFF;            // MAME defaults (Language: English on macrossp)
	t->reset = 1;
	auto tick = [&]() {
		t->clk = 0; t->eval();
		// program ROMs: held request, ack after a latency
		t->mrom_ack = 0; t->srom_ack = 0; t->smp_ack = 0;
		if (t->mrom_req) { if (mcount < 0) mcount = MLAT; else if (mcount > 0) mcount--;
			if (mcount == 0) { uint32_t a = t->mrom_addr * 4; t->mrom_data = mainr[a] << 24 | mainr[a+1] << 16 | mainr[a+2] << 8 | mainr[a+3]; t->mrom_ack = 1; mcount = -2; } }
		else mcount = -1;
		if (mcount == -2 && !t->mrom_req) mcount = -1;
		if (t->srom_req) { if (scount < 0) scount = MLAT; else if (scount > 0) scount--;
			if (scount == 0) { uint32_t a = t->srom_addr * 2; t->srom_data = snd[a] << 8 | snd[a+1]; t->srom_ack = 1; scount = -2; } }
		else scount = -1;
		if (t->smp_req) { if (smpcount < 0) smpcount = LAT; else if (smpcount > 0) smpcount--;
			if (smpcount == 0) {
				uint32_t bank = t->smp_bank, w = t->smp_word;
				uint32_t a = (bank * 0x200000u + w) * 2;
				bool mapped = quiz || bank < 2;
				t->smp_data = (mapped && a + 1 < smp.size()) ? (smp[a] << 8 | smp[a+1]) : 0;
				t->smp_ack = 1; smpcount = -2; } }
		else smpcount = -1;
		// graphics streams
		t->bg_ready = 0xF; t->spr_ready = 1;
		for (int s = 0; s < 4; s++) if (t->bg_req >> s & 1) {
			uint32_t a = 0; for (int b = 0; b < 23; b++) a |= ((t->bg_addr[(s*23+b)/32] >> ((s*23+b)%32)) & 1u) << b;
			bgq.push_back({now + LAT, s, a});
		}
		if (t->spr_req) sq.push_back({now + LAT, 4, t->spr_addr});
		t->bg_valid = 0; t->spr_valid = 0;
		if (!bgq.empty() && bgq.front().due <= now) {
			uint32_t o[4]; row(bgq.front().src, bgq.front().addr, o);
			for (int w = 0; w < 4; w++) t->bg_data[w] = o[w];
			t->bg_valid = 1 << bgq.front().src; bgq.pop_front();
		}
		if (!sq.empty() && sq.front().due <= now) {
			uint32_t o[4]; row(4, sq.front().addr, o);
			for (int w = 0; w < 4; w++) t->spr_data[w] = o[w];
			t->spr_valid = 1; sq.pop_front();
		}
#ifdef MP_SS
		if (t->ddr_we) ddr[t->ddr_addr & 0x3FFFF] = t->ddr_din;
		if (t->ddr_rd) ddrq.push_back({now + 8, t->ddr_addr & 0x3FFFF});
		t->ddr_dout_ready = 0;
		if (!ddrq.empty() && ddrq.front().first <= now) { t->ddr_dout = ddr[ddrq.front().second]; t->ddr_dout_ready = 1; ddrq.pop_front(); }
		if (t->ss_done_ok || t->ss_done_fail) {
			printf("SS step %d: %s (fail code %d) at frame %d\n", ss_step, t->ss_done_ok ? "ok" : "FAIL", t->ss_fail_code, frame);
			if (t->ss_done_fail) { printf("SS gate: FAIL\n"); exit(1); }
			ss_step++; ss_mark = frame;
		}
#endif
		t->clk = 1; t->eval(); now++;
#ifdef MP_SS
		t->save_req = 0; t->load_req = 0;       // one-clock pulses: seen by exactly one rising edge
#endif
	};
	for (int i = 0; i < 64; i++) tick();
	t->reset = 0;
	while (frame < frames) {
		tick();
		if (wav && now >= next_audio) { next_audio += 1000; int16_t s[2] = {(int16_t)t->snd_l, (int16_t)t->snd_r}; fwrite(s, 2, 2, wav); }
		if (t->ce_pix) {
			int h = t->hcount, v = t->vcount;
			if (h >= 2 && h <= 385 && v < H) fb[v * 384 + h - 2] = t->rgb;   // rgb is two pixels behind hcount (M1)
			if (v == 0 && prevv == 255) {
				if (play) {
					uint32_t in = 0xFFFFFFFF;
					int F = frame + 1;                          // the frame about to start
					if (F >= F0 && F < F0 + 6) in &= ~(1u << 2);                 // coin 1
					if (F >= F0 + 60 && F < F0 + 66) in &= ~(1u << 0);           // start 1
					if (F >= F0 + 120) {
						if ((F % 8) < 4) in &= ~(1u << 20);                      // button 1
						if ((F % 300) < 4) in &= ~(1u << 21);                    // button 2
						static const int mv[7][2] = {{-1,-1},{16,-1},{18,-1},{17,-1},{19,-1},{16,19},{17,18}};
						const int *m = mv[(F / 60) % 7];
						for (int k = 0; k < 2; k++) if (m[k] >= 0) in &= ~(1u << m[k]);
						if (quiz) in &= ~(1u << (20 + (F / 30) % 4));
					}
					t->inputs = in;
#ifdef MP_SS
					if (!quiz && F >= F0 + 120 && !t->ss_busy) {
#else
					if (!quiz && F >= F0 + 120) {
#endif
						// the cheat pokes: pause, let the CPU block settle, write two bytes
						t->pause = 1; for (int i = 0; i < 16; i++) tick();
						auto poke = [&](uint32_t a, uint8_t b) {
							uint32_t off = a - 0xF00000; int lane = 3 - (off & 3);
							t->ram2_sel = 1; t->ram2_addr = off >> 2; t->ram2_be = 1u << lane;
							t->ram2_din = (uint32_t)b << (8 * lane); t->ram2_we = 1; tick();
							t->ram2_we = 0; tick(); t->ram2_sel = 0;
						};
						poke(0xF173C1, 0x04); poke(0xF07183, 0x0D);
						tick(); t->pause = 0;
					}
				}
				if (fdir && frame >= FROM) {
					char fn[512]; snprintf(fn, sizeof fn, "%s/f%05d.raw", fdir, frame);
					FILE *f = fopen(fn, "wb"); fwrite(fb.data(), 4, 384 * H, f); fclose(f);
				}
				if (frame % EVERY == 0) {
					int nb = 0; for (int i = 0; i < 384 * H; i++) nb += (fb[i] & 0xFFFFFF) != 0;
					printf("f=%d work_us=%.1f nonblack=%d irq3=%u(+%u) iack3=%u idle=+%u es_w=+%u latch_w=+%u latch_r=%u es_irq=%u spr_over=%u bg_over=%llx cpu=%06x\n",
					       frame, t->dbg_work / 48.0, nb, t->dbg_irq3, t->dbg_irq3 - last_irq, t->dbg_iack3, t->dbg_idle - last_idle,
					       t->dbg_es_writes - last_es, t->dbg_latch_writes - last_lw, t->dbg_latch_reads, t->dbg_es_irq,
					       t->dbg_spr_overruns, (unsigned long long)t->dbg_bg_overruns, t->dbg_cpu_addr & 0xFFFFFF);
					fflush(stdout);
					last_idle = t->dbg_idle; last_es = t->dbg_es_writes; last_lw = t->dbg_latch_writes; last_irq = t->dbg_irq3;
				}
#ifdef MP_SS
				{
					// the picture just finished, hashed, K frames after each resume
					uint64_t h = 1469598103934665603ull;
					for (int i = 0; i < 384 * H; i++) { h ^= fb[i] & 0xFFFFFF; h *= 1099511628211ull; }
					if (ss_step == 2 && frame > ss_mark) hash_a.push_back(h);
					if (ss_step == 6 && frame > ss_mark) hash_b.push_back(h);
					auto req = [&](bool load, int sl) { if (load) t->load_req = 1; else t->save_req = 1; t->slot = sl; ss_step++; };
					if (ss_step == 0 && frame + 1 == SS_T) req(false, 0);
					else if (ss_step == 2 && frame == ss_mark + SS_K) req(false, 1);
					else if (ss_step == 4 && frame == ss_mark + 5) req(true, 0);
					else if (ss_step == 6 && frame == ss_mark + SS_K) req(false, 2);
					else if (ss_step == 8) frames = frame + 1;
				}
#endif
				frame++;
				t->trace_on = (frame == TRF);
			}
			prevv = v;
		}
	}
	printf("done: %d frames, %llu clk\n", frame, (unsigned long long)now);
#ifdef MP_SS
	if (ss_step == 8) {
		auto word = [&](int sl, uint32_t w) -> uint16_t { return ddr[sl * 0x10000 + 1 + w / 4] >> (16 * (w % 4)); };
		struct R { const char *name; uint32_t a, b; } regs[] = {
			{"main RAM", 0x00000, 0x10000}, {"VRAM x4", 0x10000, 0x18000}, {"line zoom x4", 0x18000, 0x18400},
			{"layer registers", 0x18400, 0x18800}, {"sprite RAM live", 0x18800, 0x1A000}, {"sprites old", 0x1A000, 0x1B800},
			{"sprites old2", 0x1C000, 0x1E000}, {"palette", 0x1E000, 0x20000}, {"sound RAM", 0x20000, 0x24000},
			{"ES5506 voices", 0x24000, 0x24400}, {"ES5506 globals", 0x24400, 0x24420}, {"scalars", 0x24800, 0x24880},
			{"park frames", 0x24880, 0x24900}};
		int total = 0;
		for (auto &r : regs) {
			int d = 0, d01 = 0;
			for (uint32_t w = r.a; w < r.b; w++) { d += word(1, w) != word(2, w); d01 += word(0, w) != word(1, w); }
			printf("  %-18s %6u words  slot1/slot2 differ %5d   (slot0/slot1 %d)\n", r.name, r.b - r.a, d, d01);
			if (d && getenv("MP_SS_LIST")) for (uint32_t w = r.a; w < r.b; w++) if (word(1, w) != word(2, w))
				printf("    %05x: %04x %04x\n", w, word(1, w), word(2, w));
			total += d;
		}
		int same = 0, n = std::min(hash_a.size(), hash_b.size());
		for (int i = 0; i < n; i++) same += hash_a[i] == hash_b[i];
		printf("SS gate: %d differing words; pictures after resume identical %d/%d\n", total, same, n);
		if (getenv("MP_SS_DUMP")) for (int sl = 0; sl < 3; sl++) {
			char fn[512]; snprintf(fn, sizeof fn, "%s/slot%d.bin", getenv("MP_SS_DUMP"), sl);
			FILE *f = fopen(fn, "wb"); fwrite(&ddr[sl * 0x10000], 8, 0x10000, f); fclose(f);
		}
	} else printf("SS gate: did not finish (step %d)\n", ss_step);
#endif
	if (wav) fclose(wav);
	delete t;
	return 0;
}
