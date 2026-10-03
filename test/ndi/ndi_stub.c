// Stand-in for the NDI runtime, used only by test/ndi_test.dart when the
// real SDK isn't installed. Struct layouts follow Processing.NDI.Lib.h
// (v5/v6), so the Dart FFI bindings are exercised exactly as with the real
// library. Sent video is looped back to receivers.
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct { const char* p_ndi_name; const char* p_groups; bool clock_video; bool clock_audio; } NDIlib_send_create_t;
typedef struct {
  int xres, yres; int FourCC; int frame_rate_N, frame_rate_D; float picture_aspect_ratio;
  int frame_format_type; int64_t timecode; uint8_t* p_data;
  union { int line_stride_in_bytes; int data_size_in_bytes; };
  const char* p_metadata; int64_t timestamp;
} NDIlib_video_frame_v2_t;
typedef struct {
  int sample_rate, no_channels, no_samples; int64_t timecode; float* p_data;
  int channel_stride_in_bytes; const char* p_metadata; int64_t timestamp;
} NDIlib_audio_frame_v2_t;
typedef struct { const char* p_ndi_name; union { const char* p_url_address; const char* p_ip_address; }; } NDIlib_source_t;
typedef struct { bool show_local_sources; const char* p_groups; const char* p_extra_ips; } NDIlib_find_create_t;
typedef struct { NDIlib_source_t source_to_connect_to; int color_format; int bandwidth; bool allow_video_fields; const char* p_ndi_recv_name; } NDIlib_recv_create_v3_t;

static char g_name[256];
static NDIlib_video_frame_v2_t g_last;
static uint8_t* g_data;
static int g_have_video;
static int g_audio_samples;
static NDIlib_source_t g_source;

bool NDIlib_initialize(void) { return true; }
const char* NDIlib_version(void) { return "NDI stub 1.0"; }

void* NDIlib_send_create(const NDIlib_send_create_t* c) {
  snprintf(g_name, sizeof g_name, "STUBHOST (%s)", c && c->p_ndi_name ? c->p_ndi_name : "unnamed");
  return (void*)1;
}
void NDIlib_send_destroy(void* s) { (void)s; }
void NDIlib_send_send_video_v2(void* s, const NDIlib_video_frame_v2_t* f) {
  (void)s;
  size_t n = (size_t)f->line_stride_in_bytes * f->yres;
  free(g_data); g_data = malloc(n); memcpy(g_data, f->p_data, n);
  g_last = *f; g_last.p_data = g_data; g_have_video = 1;
}
void NDIlib_send_send_audio_v2(void* s, const NDIlib_audio_frame_v2_t* f) { (void)s; g_audio_samples += f->no_samples; }
int NDIlib_send_get_no_connections(void* s, uint32_t t) { (void)s; (void)t; return 0; }

void* NDIlib_find_create_v2(const NDIlib_find_create_t* c) { (void)c; return (void*)2; }
void NDIlib_find_destroy(void* f) { (void)f; }
bool NDIlib_find_wait_for_sources(void* f, uint32_t t) { (void)f; (void)t; return g_name[0] != 0; }
const NDIlib_source_t* NDIlib_find_get_current_sources(void* f, uint32_t* n) {
  (void)f; g_source.p_ndi_name = g_name; g_source.p_url_address = "127.0.0.1:5961";
  *n = g_name[0] ? 1 : 0; return &g_source;
}
void* NDIlib_recv_create_v3(const NDIlib_recv_create_v3_t* c) { return strcmp(c->source_to_connect_to.p_ndi_name, g_name) == 0 ? (void*)3 : NULL; }
void NDIlib_recv_destroy(void* r) { (void)r; }
int NDIlib_recv_capture_v2(void* r, NDIlib_video_frame_v2_t* v, NDIlib_audio_frame_v2_t* a, void* m, uint32_t t) {
  (void)r; (void)a; (void)m; (void)t;
  if (!g_have_video || !v) return 0;
  *v = g_last;
  size_t n = (size_t)g_last.line_stride_in_bytes * g_last.yres;
  v->p_data = malloc(n); memcpy(v->p_data, g_data, n);
  return 1;
}
void NDIlib_recv_free_video_v2(void* r, const NDIlib_video_frame_v2_t* v) { (void)r; free(v->p_data); }
int ndi_stub_audio_samples(void) { return g_audio_samples; }
