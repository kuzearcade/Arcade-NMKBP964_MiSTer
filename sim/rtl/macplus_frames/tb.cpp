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
#include "Vmacplus_core.h"
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

	Vmacplus_core *t = new Vmacplus_core;
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
	t->quiz = quiz; t->pause = 0;
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
		t->clk = 1; t->eval(); now++;
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
				if (fdir && frame >= FROM) {
					char fn[512]; snprintf(fn, sizeof fn, "%s/f%05d.raw", fdir, frame);
					FILE *f = fopen(fn, "wb"); fwrite(fb.data(), 4, 384 * H, f); fclose(f);
				}
				if (frame % EVERY == 0) {
					int nb = 0; for (int i = 0; i < 384 * H; i++) nb += (fb[i] & 0xFFFFFF) != 0;
					printf("f=%d nonblack=%d irq3=%u(+%u) iack3=%u idle=+%u es_w=+%u latch_w=+%u latch_r=%u es_irq=%u spr_over=%u bg_over=%llx cpu=%06x\n",
					       frame, nb, t->dbg_irq3, t->dbg_irq3 - last_irq, t->dbg_iack3, t->dbg_idle - last_idle,
					       t->dbg_es_writes - last_es, t->dbg_latch_writes - last_lw, t->dbg_latch_reads, t->dbg_es_irq,
					       t->dbg_spr_overruns, (unsigned long long)t->dbg_bg_overruns, t->dbg_cpu_addr & 0xFFFFFF);
					fflush(stdout);
					last_idle = t->dbg_idle; last_es = t->dbg_es_writes; last_lw = t->dbg_latch_writes; last_irq = t->dbg_irq3;
				}
				frame++;
			}
			prevv = v;
		}
	}
	printf("done: %d frames, %llu clk\n", frame, (unsigned long long)now);
	if (wav) fclose(wav);
	delete t;
	return 0;
}
