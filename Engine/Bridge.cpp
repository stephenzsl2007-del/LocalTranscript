#include "Bridge.h"
#include "whisper.h"
#include <algorithm>
#include <thread>
void *lt_create(const char *path, int gpu) {
    auto p = whisper_context_default_params();
    p.use_gpu = gpu != 0;
    return whisper_init_from_file_with_params(path, p);
}
void lt_destroy(void *ctx) { if (ctx) whisper_free((whisper_context *)ctx); }
int lt_run(void *ctx, const float *audio, int count, const char *language) {
    auto p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.n_threads = std::min(4u, std::max(1u, std::thread::hardware_concurrency()));
    p.language = language;
    p.translate = false;
    p.no_context = true;
    p.print_progress = p.print_realtime = p.print_timestamps = false;
    p.suppress_blank = true;
    p.suppress_nst = true;
    p.temperature = 0;
    p.temperature_inc = 0;
    p.greedy.best_of = 1;
    int result = whisper_full((whisper_context *)ctx, p, audio, count);
    return result == 0 ? whisper_full_n_segments((whisper_context *)ctx) : -1;
}
const char *lt_text(void *ctx, int i) { return whisper_full_get_segment_text((whisper_context *)ctx, i); }
double lt_start(void *ctx, int i) { return whisper_full_get_segment_t0((whisper_context *)ctx, i) * 0.01; }
double lt_end(void *ctx, int i) { return whisper_full_get_segment_t1((whisper_context *)ctx, i) * 0.01; }
