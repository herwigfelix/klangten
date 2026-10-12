/*
 * A part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).
 * Klangten is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free
 * Software Foundation, version 3. See the file "license" in the repository.
 *
 * klangten_audio - Klangten's own sound engine (replaces BASS).
 *
 * Internal structures shared by the parts of the engine:
 *   ka_core.c     handles, errors, configuration, devices, the mixer,
 *                 channel state, attributes, slides, positions, GetData
 *   ka_decoder.c  file, memory and internet streams through FFmpeg
 *   ka_sources.c  push streams, samples, recording, the format converter
 *                 ("mixer" with one input) and the tempo stream (WSOLA)
 *   ka_fx.c       the effects (echo, reverb, chorus, ...)
 *   ka_encode.c   MP3 recording of a channel through LAME
 *
 * Everything inside the engine is 32-bit float, interleaved, at the
 * channel's own sample rate. Integer PCM exists only at the edges
 * (GetData without the FLOAT flag, push streams created without it).
 *
 * Threads: the audio callback of a device never blocks and never decodes.
 * It reads ring buffers (decoder, push and record channels) or sample
 * memory. Decoding happens in a feeder thread per playing stream, or in the
 * caller's thread for decode-only channels (KA_ChannelGetData).
 */
#ifndef KA_INTERNAL_H
#define KA_INTERNAL_H

#include <stdint.h>
#include <stddef.h>
#include "miniaudio.h"
#include "klangten_audio.h"

#define KA_MAX_DEVICES 64
#define KA_MAX_FX 16

/* ---- small portability layer (ka_core.c) ---- */
#ifdef _WIN32
#include <windows.h>
typedef CRITICAL_SECTION kmutex;
typedef HANDLE kthread;
typedef struct { CRITICAL_SECTION cs; CONDITION_VARIABLE cv; int signaled; } kevent;
#else
#include <pthread.h>
typedef pthread_mutex_t kmutex;
typedef pthread_t kthread;
typedef struct { pthread_mutex_t m; pthread_cond_t c; int signaled; } kevent;
#endif
void kmutex_init(kmutex *m);
void kmutex_free(kmutex *m);
void kmutex_lock(kmutex *m);
int kmutex_trylock(kmutex *m);
void kmutex_unlock(kmutex *m);
int kthread_start(kthread *t, void *(*fn)(void *), void *arg);
void kthread_join(kthread t);
void kevent_init(kevent *e);
void kevent_free(kevent *e);
void kevent_signal(kevent *e);
void kevent_wait(kevent *e, int ms);
void ksleep_ms(int ms);

typedef struct ka_channel ka_channel;
typedef struct ka_fx ka_fx;

/* A source delivers float frames at the channel's rate and channel count.
 * read: returns frames written (0 = nothing now), sets *ended when no more
 * data will ever come. seek: frame position, returns 0 on failure. */
typedef struct ka_source_ops {
    int (*read)(ka_channel *ch, float *out, int frames, int *ended);
    int (*seek)(ka_channel *ch, int64_t frame);
    int64_t (*length)(ka_channel *ch);          /* frames, -1 = unknown */
    void (*destroy)(ka_channel *ch);
    const char *(*tags)(ka_channel *ch, uint32_t type);
    uint64_t (*file_position)(ka_channel *ch, uint32_t mode);
} ka_source_ops;

typedef enum {
    KA_KIND_STREAM = 1,   /* decoder (file, memory, url) */
    KA_KIND_PUSH,
    KA_KIND_SAMPLE,       /* playback channel of a sample */
    KA_KIND_RECORD,
    KA_KIND_CONVERTER,    /* "mixer" stream with one input */
    KA_KIND_TEMPO
} ka_kind;

typedef struct ka_slide {
    int active;
    float from, to;
    double start, duration;   /* seconds of the engine clock */
    int logarithmic;
} ka_slide;

typedef struct ka_sample {
    uint32_t handle;
    float *data;              /* interleaved */
    int64_t frames;
    int rate, chans;
    uint32_t flags;
    int max_channels;
} ka_sample;

struct ka_channel {
    uint32_t handle;
    ka_kind kind;
    uint32_t flags;           /* KA_SAMPLE_*, KA_STREAM_* */
    int rate, chans;
    int device;               /* output device index; -1 = decode only */
    const ka_source_ops *ops;
    void *impl;               /* source specific */

    kmutex lock;              /* protects source state (decode, seek) */

    /* playback */
    volatile int state;       /* KA_ACTIVE_* */
    volatile int ended;       /* source ended (feeder) */
    volatile int freeing;
    int in_mixer;             /* listed on its device */
    ma_pcm_rb rb;             /* decoded frames waiting for the callback */
    int rb_ready;
    kthread feeder;
    int feeder_running;
    volatile int feeder_stop;
    volatile int seek_pending;
    volatile int64_t seek_frame;
    kevent feeder_wake;
    int stalled;

    /* position: source frames handed out (heard) */
    volatile int64_t position;
    int64_t loop_length;      /* frames of one pass when looping, 0 = unknown */
    int64_t sample_pos;       /* sample channels */
    ka_sample *sample;

    /* attributes */
    float volume, pan, freq;  /* freq 0 = native rate */
    float tempo, tempo_pitch, tempo_freq;
    float attr_misc[32];
    ka_slide slide_vol, slide_pan, slide_freq;

    /* conversion for the device */
    ma_linear_resampler resampler;
    int resampler_ready;
    int resampler_in_rate, resampler_out_rate;
    float *scratch;           /* source frames */
    size_t scratch_frames;
    float *scratch2;          /* resampled frames */
    size_t scratch2_frames;

    /* effects (sorted by priority, highest first) */
    ka_fx *fx[KA_MAX_FX];
    int fx_count;

    /* MP3 recording of what this channel plays */
    void *encoder;

    /* converter / tempo input */
    uint32_t input;
};

/* ---- core helpers (ka_core.c) ---- */
int ka_set_error(int code);
int ka_ok(void);
uint32_t ka_new_handle(void);
ka_channel *ka_channel_new(ka_kind kind, int rate, int chans, uint32_t flags, const ka_source_ops *ops, void *impl);
ka_channel *ka_channel_get(uint32_t handle);  /* NULL with KA_ERROR_HANDLE */
void ka_channel_release(ka_channel *ch);       /* after ka_channel_get */
int ka_channel_read_float(ka_channel *ch, float *out, int frames, int *ended);
double ka_clock(void);
const char *ka_config_string(int option);
int ka_config_int(int option, int fallback);
int ka_null_forced(void);

/* ---- ring buffer helpers (ka_core.c) ---- */
int ka_rb_init(ka_channel *ch, int seconds_x10);
int ka_rb_write(ka_channel *ch, const float *frames, int count);
int ka_rb_read(ka_channel *ch, float *frames, int count);
int ka_rb_available(ka_channel *ch);
void ka_rb_clear(ka_channel *ch);

/* ---- decoder (ka_decoder.c) ---- */
uint32_t ka_decoder_open_file(const char *path, uint64_t offset, uint64_t length, uint32_t flags);
uint32_t ka_decoder_open_memory(const void *data, uint64_t length, uint32_t flags);
uint32_t ka_decoder_open_url(const char *url, uint64_t offset, uint32_t flags);
int ka_decoder_probe_sample(const char *path, const void *mem, uint64_t length, float **data, int64_t *frames, int *rate, int *chans);

/* ---- sources (ka_sources.c) ---- */
extern const ka_source_ops ka_push_ops;
extern const ka_source_ops ka_sample_ops;
extern const ka_source_ops ka_record_ops;
extern const ka_source_ops ka_converter_ops;
extern const ka_source_ops ka_tempo_ops;
void ka_record_shutdown(void);
ka_sample *ka_sample_get(uint32_t handle);
int ka_tempo_set(ka_channel *ch, uint32_t attrib, float value);

/* ---- effects (ka_fx.c) ---- */
struct ka_fx {
    uint32_t handle;
    uint32_t type;
    int priority;
    int bypass;
    uint32_t channel;          /* owner */
    int rate, chans;
    unsigned char params[256];
    size_t params_size;
    void *state;
};
ka_fx *ka_fx_create(uint32_t type, int rate, int chans);
int ka_fx_set_params(ka_fx *fx, const void *params);
int ka_fx_get_params(ka_fx *fx, void *params);
void ka_fx_reset(ka_fx *fx);
void ka_fx_destroy(ka_fx *fx);
void ka_fx_process(ka_fx *fx, float *frames, int count);
ka_fx *ka_fx_lookup(uint32_t handle);

/* ---- shared between the parts ---- */
void ka_channel_prebuffer(ka_channel *ch);
int ka_register_encoder(uint32_t handle, void *enc);
void *ka_encoder_lookup(uint32_t handle);
void ka_unregister(uint32_t handle);
void ka_free_channel(uint32_t handle);

/* ---- encoder (ka_encode.c) ---- */
void ka_encoder_feed(ka_channel *ch, const float *frames, int count);
void ka_encoder_close_for(ka_channel *ch);

#endif
