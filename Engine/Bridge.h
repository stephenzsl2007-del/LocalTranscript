#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void * lt_create(const char *path, int gpu);
void lt_destroy(void *ctx);
int lt_run(void *ctx, const float *audio, int count, const char *language);
const char *lt_text(void *ctx, int index);
double lt_start(void *ctx, int index);
double lt_end(void *ctx, int index);
#ifdef __cplusplus
}
#endif
