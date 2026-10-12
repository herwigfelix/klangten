/*
 * A part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).
 * Klangten is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free
 * Software Foundation, version 3. See the file "license" in the repository.
 *
 * ka_sources.c - the sources that are not decoders:
 *   push       data written by the host (Spotify, conferences, speech)
 *   sample     a sound decoded once into memory, played by channels
 *   record     the microphone (miniaudio capture)
 *   converter  a "mixer" stream with one input: new rate and channel count
 *   tempo      tempo without pitch change (WSOLA), pitch and rate on top
 *
 * The tempo stream uses the WSOLA method of Klango's own engine
 * (klango_rs/src/engine/stretch.rs, written for this project): 40 ms grains
 * with a Hann window and 50 % overlap; each grain is moved within +-12 ms
 * to where it continues the previous one best (cross-correlation, coarse
 * then fine). Pitch is a resampling by 2^(semitones/12) after stretching
 * by tempo/pitch, so that speed and pitch end up where they were asked.
 */
#include "ka_internal.h"

#include <stdlib.h>
#include <string.h>
#include <math.h>

ma_context *ka_capture_context(int device, ma_device_id **id_out, int *is_null);
int ka_capture_device_info(int device, KA_DEVICEINFO *info);
void ka_capture_release(void);
void ka_free_channel(uint32_t handle);

/* ---------------------------------------------------------------- push */
static int push_read(ka_channel *ch, float *out, int frames, int *ended) {
    int n;
    *ended = 0;
    if (ch->attr_misc[30] > 0) { *ended = 0; return 0; }   /* dummy stream */
    n = ka_rb_read(ch, out, frames);
    if (n < frames && ch->ended && ka_rb_available(ch) == 0) *ended = 1;
    return n;
}
static int64_t push_length(ka_channel *ch) { (void)ch; return -1; }
const ka_source_ops ka_push_ops = { push_read, NULL, push_length, NULL, NULL, NULL };

/* -------------------------------------------------------------- sample */
static int sample_read(ka_channel *ch, float *out, int frames, int *ended) {
    ka_sample *s = ch->sample;
    int done = 0;
    *ended = 0;
    if (!s || s->frames <= 0) { *ended = 1; return 0; }
    while (done < frames) {
        int64_t left = s->frames - ch->sample_pos;
        int n;
        if (left <= 0) {
            if (ch->flags & KA_SAMPLE_LOOP) { ch->sample_pos = 0; continue; }
            *ended = 1;
            break;
        }
        n = (int)(left < frames - done ? left : frames - done);
        memcpy(out + (size_t)done * ch->chans, s->data + (size_t)ch->sample_pos * s->chans, (size_t)n * s->chans * sizeof(float));
        ch->sample_pos += n;
        done += n;
    }
    return done;
}
static int sample_seek(ka_channel *ch, int64_t frame) {
    if (!ch->sample || frame > ch->sample->frames) return 0;
    ch->sample_pos = frame;
    return 1;
}
static int64_t sample_length(ka_channel *ch) { return ch->sample ? ch->sample->frames : -1; }
const ka_source_ops ka_sample_ops = { sample_read, sample_seek, sample_length, NULL, NULL, NULL };

/* -------------------------------------------------------------- record */
static int g_record_device = -1;
static ma_device g_capture;
static int g_capture_running;
static ka_channel *g_capture_channel;

static void capture_callback(ma_device *d, void *output, const void *input, ma_uint32 frames) {
    ka_channel *ch = (ka_channel *)d->pUserData;
    (void)output;
    if (ch && ch->state == KA_ACTIVE_PLAYING && input) ka_rb_write(ch, (const float *)input, (int)frames);
}

static void capture_stop(void) {
    if (!g_capture_running) return;
    ma_device_uninit(&g_capture);
    g_capture_running = 0;
    g_capture_channel = NULL;
}

static int record_read(ka_channel *ch, float *out, int frames, int *ended) {
    *ended = 0;
    return ka_rb_read(ch, out, frames);
}
static int record_seek(ka_channel *ch, int64_t frame) {
    if (frame == -1 && g_capture_channel == ch) capture_stop();
    return frame == -1;
}
static int64_t record_length(ka_channel *ch) { (void)ch; return -1; }
static void record_destroy(ka_channel *ch) { if (g_capture_channel == ch) capture_stop(); }
const ka_source_ops ka_record_ops = { record_read, record_seek, record_length, record_destroy, NULL, NULL };

void ka_record_shutdown(void) { capture_stop(); }

KA_API int KA_RecordInit(int device) {
    ma_device_id *id;
    int is_null;
    if (device == -1) device = 1;
    if (!ka_capture_context(device, &id, &is_null)) return ka_set_error(KA_ERROR_DRIVER);
    if (g_record_device == device) return ka_set_error(KA_ERROR_ALREADY);
    g_record_device = device;
    return ka_ok();
}
KA_API int KA_RecordFree(void) {
    if (g_record_device < 0) return ka_set_error(KA_ERROR_INIT);
    capture_stop();
    ka_capture_release();
    g_record_device = -1;
    return ka_ok();
}
KA_API int KA_RecordGetDevice(void) {
    if (g_record_device < 0) { ka_set_error(KA_ERROR_INIT); return -1; }
    ka_ok();
    return g_record_device;
}
KA_API int KA_RecordSetDevice(int device) {
    if (g_record_device != device) return ka_set_error(KA_ERROR_INIT);
    return ka_ok();
}
KA_API int KA_RecordGetDeviceInfo(int device, KA_DEVICEINFO *info) {
    if (!info) return ka_set_error(KA_ERROR_ILLPARAM);
    return ka_capture_device_info(device, info) ? ka_ok() : ka_set_error(KA_ERROR_DEVICE);
}
KA_API uint32_t KA_RecordGetInput(int input, float *volume) {
    (void)input;
    if (volume) *volume = 1.0f;
    ka_ok();
    return 0;
}
KA_API int KA_RecordSetInput(int input, uint32_t flags, float volume) {
    (void)input; (void)flags; (void)volume;
    return ka_ok();
}

KA_API KAHANDLE KA_RecordStart(uint32_t freq, uint32_t chans, uint32_t flags, void *proc, void *user) {
    ka_channel *ch;
    ma_device_config cfg;
    ma_device_id *id;
    int is_null;
    ma_context *ctx;
    (void)proc; (void)user;
    if (g_record_device < 0) return ka_set_error(KA_ERROR_INIT);
    if (g_capture_running) return ka_set_error(KA_ERROR_ALREADY);
    ctx = ka_capture_context(g_record_device, &id, &is_null);
    if (!ctx) return ka_set_error(KA_ERROR_DRIVER);
    ch = ka_channel_new(KA_KIND_RECORD, freq ? (int)freq : 48000, chans ? (int)chans : 2, (flags & KA_SAMPLE_FLOAT) | KA_STREAM_DECODE, &ka_record_ops, NULL);
    if (!ch) return 0;
    if (!ka_rb_init(ch, 50)) { ka_free_channel(ch->handle); return ka_set_error(KA_ERROR_MEM); }
    cfg = ma_device_config_init(ma_device_type_capture);
    cfg.capture.format = ma_format_f32;
    cfg.capture.channels = (ma_uint32)ch->chans;
    cfg.capture.pDeviceID = id;
    cfg.sampleRate = (ma_uint32)ch->rate;
    cfg.dataCallback = capture_callback;
    cfg.pUserData = ch;
    if (ma_device_init(ctx, &cfg, &g_capture) != MA_SUCCESS) { ka_free_channel(ch->handle); return ka_set_error(KA_ERROR_DEVICE); }
    g_capture_running = 1;
    g_capture_channel = ch;
    ch->state = (flags & 0x8000) ? KA_ACTIVE_PAUSED : KA_ACTIVE_PLAYING;   /* 0x8000: start paused */
    if (ma_device_start(&g_capture) != MA_SUCCESS) { capture_stop(); ka_free_channel(ch->handle); return ka_set_error(KA_ERROR_START); }
    ka_ok();
    return ch->handle;
}

/* ----------------------------------------------------------- converter */
typedef struct conv {
    uint32_t input;
    ma_linear_resampler rs;
    int rs_ready;
    float *in, *mixed;
    int in_cap, mixed_cap;
    int ended;
} conv;

static int ensure_buf(float **b, int *cap, int frames, int chans) {
    if (*cap >= frames) return 1;
    free(*b);
    *b = (float *)malloc((size_t)frames * chans * sizeof(float));
    if (!*b) { *cap = 0; return 0; }
    *cap = frames;
    return 1;
}

static void convert_channels(const float *src, int src_ch, float *dst, int dst_ch, int frames) {
    int f, c;
    for (f = 0; f < frames; f++) {
        const float *s = src + (size_t)f * src_ch;
        float *d = dst + (size_t)f * dst_ch;
        if (src_ch == dst_ch) { memcpy(d, s, (size_t)dst_ch * sizeof(float)); continue; }
        if (dst_ch == 1) {
            float sum = 0;
            for (c = 0; c < src_ch; c++) sum += s[c];
            d[0] = sum / (float)src_ch;
        } else if (src_ch == 1) {
            for (c = 0; c < dst_ch; c++) d[c] = s[0];
        } else {
            for (c = 0; c < dst_ch; c++) d[c] = c < src_ch ? s[c] : 0.0f;
        }
    }
}

static int conv_read(ka_channel *ch, float *out, int frames, int *ended) {
    conv *v = (conv *)ch->impl;
    ka_channel *src;
    ma_uint64 need = 0, in_count, out_count;
    int got, e = 0;
    *ended = 0;
    if (!v->input) { *ended = 1; return 0; }
    src = ka_channel_get(v->input);
    if (!src) { *ended = 1; return 0; }
    if (!v->rs_ready) {
        ma_linear_resampler_config rc = ma_linear_resampler_config_init(ma_format_f32, (ma_uint32)ch->chans, (ma_uint32)src->rate, (ma_uint32)ch->rate);
        if (ma_linear_resampler_init(&rc, NULL, &v->rs) != MA_SUCCESS) { *ended = 1; return 0; }
        v->rs_ready = 1;
    }
    ma_linear_resampler_get_required_input_frame_count(&v->rs, (ma_uint64)frames, &need);
    if (need == 0) need = 1;
    if (!ensure_buf(&v->in, &v->in_cap, (int)need + 16, src->chans) || !ensure_buf(&v->mixed, &v->mixed_cap, (int)need + 16, ch->chans)) { *ended = 1; return 0; }
    got = v->ended ? 0 : ka_channel_read_float(src, v->in, (int)need, &e);
    if (e) v->ended = 1;
    if (got < (int)need) {
        if (!v->ended) {
            /* a live input without data right now: hand out what there is */
            if (got == 0) return 0;
        } else {
            memset(v->in + (size_t)got * src->chans, 0, ((size_t)need - got) * src->chans * sizeof(float));
        }
    }
    convert_channels(v->in, src->chans, v->mixed, ch->chans, v->ended ? (int)need : got);
    in_count = v->ended ? need : (ma_uint64)got;
    out_count = (ma_uint64)frames;
    ma_linear_resampler_process_pcm_frames(&v->rs, v->mixed, &in_count, out, &out_count);
    if (v->ended && got == 0) { *ended = 1; return 0; }
    if (v->ended && got < (int)need) {
        /* the padding produced the tail; stop after this block */
        int64_t real = (int64_t)got * ch->rate / (src->rate ? src->rate : 1);
        if (real < (int64_t)out_count) out_count = (ma_uint64)real;
        *ended = 1;
    }
    return (int)out_count;
}
static int conv_seek(ka_channel *ch, int64_t frame) {
    conv *v = (conv *)ch->impl;
    ka_channel *src = v->input ? ka_channel_get(v->input) : NULL;
    if (!src || !src->ops->seek) return 0;
    kmutex_lock(&src->lock);
    if (!src->ops->seek(src, frame * src->rate / ch->rate)) { kmutex_unlock(&src->lock); return 0; }
    kmutex_unlock(&src->lock);
    src->ended = 0;
    v->ended = 0;
    if (v->rs_ready) ma_linear_resampler_reset(&v->rs);
    return 1;
}
static int64_t conv_length(ka_channel *ch) {
    conv *v = (conv *)ch->impl;
    ka_channel *src = v->input ? ka_channel_get(v->input) : NULL;
    int64_t len;
    if (!src || !src->ops->length) return -1;
    len = src->ops->length(src);
    return len < 0 ? -1 : len * ch->rate / src->rate;
}
static void conv_destroy(ka_channel *ch) {
    conv *v = (conv *)ch->impl;
    if (!v) return;
    if (v->rs_ready) ma_linear_resampler_uninit(&v->rs, NULL);
    free(v->in);
    free(v->mixed);
    free(v);
    ch->impl = NULL;
}
static const char *conv_tags(ka_channel *ch, uint32_t type) {
    conv *v = (conv *)ch->impl;
    ka_channel *src = v->input ? ka_channel_get(v->input) : NULL;
    return src && src->ops->tags ? src->ops->tags(src, type) : NULL;
}
const ka_source_ops ka_converter_ops = { conv_read, conv_seek, conv_length, conv_destroy, conv_tags, NULL };

KA_API KAHANDLE KA_Mixer_StreamCreate(uint32_t freq, uint32_t chans, uint32_t flags) {
    conv *v = (conv *)calloc(1, sizeof *v);
    ka_channel *ch;
    if (!v) return ka_set_error(KA_ERROR_MEM);
    ch = ka_channel_new(KA_KIND_CONVERTER, (int)freq, (int)chans, flags & ~0x10000u, &ka_converter_ops, v);
    if (!ch) { free(v); return 0; }
    ka_ok();
    return ch->handle;
}
KA_API int KA_Mixer_StreamAddChannel(KAHANDLE mixer, KAHANDLE channel, uint32_t flags) {
    ka_channel *m = ka_channel_get(mixer), *src = ka_channel_get(channel);
    conv *v;
    (void)flags;
    if (!m || !src) return 0;
    if (m->kind != KA_KIND_CONVERTER) return ka_set_error(KA_ERROR_HANDLE);
    if (!(src->flags & KA_STREAM_DECODE)) return ka_set_error(KA_ERROR_DECODE);
    v = (conv *)m->impl;
    if (v->input) return ka_set_error(KA_ERROR_ALREADY);   /* one input is all Klangten needs */
    v->input = channel;
    m->input = channel;
    src->attr_misc[29] = (float)mixer;
    return ka_ok();
}
KA_API int KA_Mixer_ChannelRemove(KAHANDLE channel) {
    ka_channel *src = ka_channel_get(channel), *m;
    if (!src) return 0;
    m = src->attr_misc[29] > 0 ? ka_channel_get((uint32_t)src->attr_misc[29]) : NULL;
    if (m && m->kind == KA_KIND_CONVERTER) { ((conv *)m->impl)->input = 0; m->input = 0; }
    src->attr_misc[29] = 0;
    return ka_ok();
}
KA_API uint32_t KA_Mixer_ChannelFlags(KAHANDLE channel, uint32_t flags, uint32_t mask) {
    ka_channel *src = ka_channel_get(channel);
    (void)flags; (void)mask;
    if (!src) return (uint32_t)-1;
    ka_ok();
    return 0;
}
KA_API int KA_Mixer_ChannelGetData(KAHANDLE channel, void *buffer, uint32_t length) {
    (void)channel; (void)buffer; (void)length;
    ka_set_error(KA_ERROR_NOTAVAIL);
    return -1;
}
KA_API KAHANDLE KA_Split_StreamCreate(KAHANDLE channel, uint32_t flags, const int *chanmap) {
    (void)channel; (void)flags; (void)chanmap;
    return ka_set_error(KA_ERROR_NOTAVAIL);
}

/* --------------------------------------------------------------- tempo */
typedef struct tempo {
    uint32_t input;
    int src_chans;
    /* WSOLA */
    int n, hop, tol;
    float *window;
    float *tail;           /* hop frames, ch->chans */
    float *reference;      /* hop, mono */
    int first;
    double cursor;         /* source frames, relative to inbuf_base */
    float *inbuf;          /* source frames (ch->chans) */
    int in_len, in_cap;
    int src_ended;
    float *stretched;      /* stretched frames waiting for the resampler */
    int st_len, st_cap;
    /* pitch / rate */
    ma_linear_resampler rs;
    int rs_ready;
    double ratio;
    int done;
} tempo;

static double tempo_factor(ka_channel *ch) { return 1.0 + ch->tempo / 100.0; }
static double pitch_ratio(ka_channel *ch) { return pow(2.0, ch->tempo_pitch / 12.0); }
static double freq_ratio(ka_channel *ch) { return ch->tempo_freq > 0 ? ch->tempo_freq / ch->rate : 1.0; }

static float mono_at(tempo *t, int chans, int f) {
    const float *p = t->inbuf + (size_t)f * chans;
    return chans >= 2 ? (p[0] + p[1]) * 0.5f : p[0];
}

static float score(tempo *t, int chans, int c, int stride) {
    float acc = 0, energy = 1e-9f;
    int k;
    for (k = 0; k < t->hop; k += stride) {
        float x = mono_at(t, chans, c + k);
        acc += x * t->reference[k];
        energy += x * x;
    }
    return acc / sqrtf(energy);
}

static int st_reserve(tempo *t, int frames, int chans) {
    if (t->st_cap >= frames) return 1;
    {
        float *p = (float *)realloc(t->stretched, (size_t)frames * chans * sizeof(float));
        if (!p) return 0;
        t->stretched = p;
        t->st_cap = frames;
    }
    return 1;
}

static int in_reserve(tempo *t, int frames, int chans) {
    if (t->in_cap >= frames) return 1;
    {
        float *p = (float *)realloc(t->inbuf, (size_t)frames * chans * sizeof(float));
        if (!p) return 0;
        t->inbuf = p;
        t->in_cap = frames;
    }
    return 1;
}

/* fills the input buffer from the source up to `want` frames */
static void tempo_fill(ka_channel *ch, tempo *t, int want) {
    ka_channel *src = ka_channel_get(t->input);
    float *tmp;
    int need = want - t->in_len, got, e = 0;
    if (!src || t->src_ended || need <= 0) { if (!src) t->src_ended = 1; return; }
    if (!in_reserve(t, want, ch->chans)) return;
    tmp = (float *)malloc((size_t)need * src->chans * sizeof(float));
    if (!tmp) return;
    got = ka_channel_read_float(src, tmp, need, &e);
    if (got > 0) convert_channels(tmp, src->chans, t->inbuf + (size_t)t->in_len * ch->chans, ch->chans, got);
    if (got > 0) t->in_len += got;
    if (e) t->src_ended = 1;
    free(tmp);
}

/* drops consumed input in front of the cursor */
static void tempo_compact(ka_channel *ch, tempo *t) {
    int keep_from = (int)floor(t->cursor) - t->tol - 1;
    if (keep_from <= 0) return;
    if (keep_from > t->in_len) keep_from = t->in_len;
    memmove(t->inbuf, t->inbuf + (size_t)keep_from * ch->chans, (size_t)(t->in_len - keep_from) * ch->chans * sizeof(float));
    t->in_len -= keep_from;
    t->cursor -= keep_from;
}

/* one WSOLA grain into `stretched`; returns 0 when the source is exhausted */
static int tempo_grain(ka_channel *ch, tempo *t, double factor) {
    int chans = ch->chans, n = t->n, hop = t->hop, k, c, best, a;
    tempo_compact(ch, t);
    a = (int)floor(t->cursor < 0 ? 0 : t->cursor);
    tempo_fill(ch, t, a + t->tol + n + 1);
    if (a + t->tol + n > t->in_len) {
        if (!t->src_ended) return -1;            /* wait for data */
        if (a + n > t->in_len) {
            /* end: flush the waiting tail plus what is left, unstretched */
            int rest = t->in_len - a;
            if (rest < 0) rest = 0;
            if (!st_reserve(t, t->st_len + hop + rest, chans)) return 0;
            for (k = 0; k < hop && !t->first; k++) {
                for (c = 0; c < chans; c++) {
                    float v = t->tail[(size_t)k * chans + c];
                    if (k < rest) v += t->inbuf[(size_t)(a + k) * chans + c] * t->window[k];
                    t->stretched[(size_t)t->st_len * chans + c] = v;
                }
                t->st_len++;
            }
            for (k = t->first ? 0 : hop; k < rest; k++) {
                memcpy(t->stretched + (size_t)t->st_len * chans, t->inbuf + (size_t)(a + k) * chans, (size_t)chans * sizeof(float));
                t->st_len++;
            }
            t->cursor = t->in_len;
            t->done = 1;
            return 0;
        }
    }
    if (t->first) best = a;
    else {
        int lo = a - t->tol < 0 ? 0 : a - t->tol;
        int hi = a + t->tol;
        float best_s = -1e30f, s;
        if (hi > t->in_len - n) hi = t->in_len - n;
        if (hi < lo) hi = lo;
        best = a < lo ? lo : (a > hi ? hi : a);
        for (c = lo; c <= hi; c += 4) { s = score(t, chans, c, 4); if (s > best_s) { best_s = s; best = c; } }
        {
            int flo = best - 3 < lo ? lo : best - 3, fhi = best + 3 > hi ? hi : best + 3;
            best_s = -1e30f;
            for (c = flo; c <= fhi; c++) { s = score(t, chans, c, 2); if (s > best_s) { best_s = s; best = c; } }
        }
    }
    if (!st_reserve(t, t->st_len + hop, chans)) return 0;
    for (k = 0; k < hop; k++) {
        float w = t->first ? 1.0f : t->window[k];
        for (c = 0; c < chans; c++)
            t->stretched[(size_t)(t->st_len + k) * chans + c] = t->tail[(size_t)k * chans + c] + t->inbuf[(size_t)(best + k) * chans + c] * w;
    }
    t->st_len += hop;
    for (k = 0; k < hop; k++) {
        float w = t->window[hop + k];
        const float *p = t->inbuf + (size_t)(best + hop + k) * chans;
        for (c = 0; c < chans; c++) t->tail[(size_t)k * chans + c] = p[c] * w;
        t->reference[k] = chans >= 2 ? (p[0] + p[1]) * 0.5f : p[0];
    }
    t->first = 0;
    t->cursor += (factor < 0.05 ? 0.05 : factor) * hop;
    return 1;
}

static int tempo_read(ka_channel *ch, float *out, int frames, int *ended) {
    tempo *t = (tempo *)ch->impl;
    double factor = tempo_factor(ch) / pitch_ratio(ch);
    double ratio = pitch_ratio(ch) * freq_ratio(ch);
    int produced = 0;
    *ended = 0;
    if (!t->rs_ready || fabs(ratio - t->ratio) > 1e-9) {
        if (!t->rs_ready) {
            ma_linear_resampler_config rc = ma_linear_resampler_config_init(ma_format_f32, (ma_uint32)ch->chans, (ma_uint32)ch->rate, (ma_uint32)ch->rate);
            if (ma_linear_resampler_init(&rc, NULL, &t->rs) != MA_SUCCESS) { *ended = 1; return 0; }
            t->rs_ready = 1;
        }
        ma_linear_resampler_set_rate_ratio(&t->rs, (float)ratio);
        t->ratio = ratio;
    }
    while (produced < frames) {
        ma_uint64 need = 0, in_count, out_count;
        int want = frames - produced;
        ma_linear_resampler_get_required_input_frame_count(&t->rs, (ma_uint64)want, &need);
        if (need == 0) need = 1;
        while (t->st_len < (int)need && !t->done) {
            int r;
            if (fabs(factor - 1.0) < 1e-6 && t->first) {
                /* plain playback: no stretching needed */
                ka_channel *src = ka_channel_get(t->input);
                int got, e = 0;
                float *tmp;
                if (!src) { t->done = 1; break; }
                if (!st_reserve(t, (int)need, ch->chans)) { t->done = 1; break; }
                tmp = (float *)malloc(((size_t)need - t->st_len) * src->chans * sizeof(float));
                if (!tmp) { t->done = 1; break; }
                got = ka_channel_read_float(src, tmp, (int)need - t->st_len, &e);
                if (got > 0) convert_channels(tmp, src->chans, t->stretched + (size_t)t->st_len * ch->chans, ch->chans, got);
                free(tmp);
                if (got > 0) t->st_len += got;
                if (e) t->done = 1;
                if (got <= 0) break;
                continue;
            }
            r = tempo_grain(ch, t, factor);
            if (r < 0) break;
            if (r == 0) break;
        }
        if (t->st_len == 0) { if (t->done) *ended = 1; break; }
        in_count = (ma_uint64)t->st_len;
        out_count = (ma_uint64)want;
        ma_linear_resampler_process_pcm_frames(&t->rs, t->stretched, &in_count, out + (size_t)produced * ch->chans, &out_count);
        memmove(t->stretched, t->stretched + (size_t)in_count * ch->chans, ((size_t)t->st_len - in_count) * ch->chans * sizeof(float));
        t->st_len -= (int)in_count;
        produced += (int)out_count;
        if (out_count == 0) { if (t->done) { *ended = 1; break; } if (in_count == 0) break; }
    }
    return produced;
}

static void tempo_reset_state(ka_channel *ch, tempo *t) {
    t->first = 1;
    t->cursor = 0;
    t->in_len = 0;
    t->st_len = 0;
    t->src_ended = 0;
    t->done = 0;
    memset(t->tail, 0, (size_t)t->hop * ch->chans * sizeof(float));
    if (t->rs_ready) ma_linear_resampler_reset(&t->rs);
}

static int tempo_seek(ka_channel *ch, int64_t frame) {
    tempo *t = (tempo *)ch->impl;
    ka_channel *src = ka_channel_get(t->input);
    if (!src || !src->ops->seek) return 0;
    kmutex_lock(&src->lock);
    if (!src->ops->seek(src, frame)) { kmutex_unlock(&src->lock); return 0; }
    kmutex_unlock(&src->lock);
    src->ended = 0;
    src->position = frame;
    tempo_reset_state(ch, t);
    return 1;
}

static int64_t tempo_length(ka_channel *ch) {
    tempo *t = (tempo *)ch->impl;
    ka_channel *src = ka_channel_get(t->input);
    int64_t len;
    double speed = tempo_factor(ch) * freq_ratio(ch);
    if (!src || !src->ops->length) return -1;
    len = src->ops->length(src);
    if (len < 0 || speed <= 0) return -1;
    return (int64_t)(len / speed);
}

static void tempo_destroy(ka_channel *ch) {
    tempo *t = (tempo *)ch->impl;
    if (!t) return;
    if (t->rs_ready) ma_linear_resampler_uninit(&t->rs, NULL);
    free(t->window); free(t->tail); free(t->reference); free(t->inbuf); free(t->stretched);
    free(t);
    ch->impl = NULL;
}

static const char *tempo_tags(ka_channel *ch, uint32_t type) {
    tempo *t = (tempo *)ch->impl;
    ka_channel *src = ka_channel_get(t->input);
    return src && src->ops->tags ? src->ops->tags(src, type) : NULL;
}

const ka_source_ops ka_tempo_ops = { tempo_read, tempo_seek, tempo_length, tempo_destroy, tempo_tags, NULL };

int ka_tempo_set(ka_channel *ch, uint32_t attrib, float value) {
    switch (attrib) {
    case KA_ATTRIB_TEMPO:
        if (value <= -95.0f || value > 5000.0f) return 0;
        ch->tempo = value;
        return 1;
    case KA_ATTRIB_TEMPO_PITCH:
        if (value < -60.0f || value > 60.0f) return 0;
        ch->tempo_pitch = value;
        return 1;
    case KA_ATTRIB_TEMPO_FREQ:
        if (value < 0) return 0;
        ch->tempo_freq = value;
        return 1;
    }
    return 0;
}

KA_API KAHANDLE KA_FX_TempoCreate(KAHANDLE source, uint32_t flags) {
    ka_channel *src = ka_channel_get(source), *ch;
    tempo *t;
    int chans, i;
    if (!src) return 0;
    if (!(src->flags & KA_STREAM_DECODE)) return ka_set_error(KA_ERROR_DECODE);
    chans = src->chans > 2 ? 2 : src->chans;
    t = (tempo *)calloc(1, sizeof *t);
    if (!t) return ka_set_error(KA_ERROR_MEM);
    t->input = source;
    t->src_chans = src->chans;
    t->n = (src->rate < 8000 ? 8000 : src->rate) * 40 / 1000;
    t->n &= ~1;
    t->hop = t->n / 2;
    t->tol = (src->rate < 8000 ? 8000 : src->rate) * 12 / 1000;
    t->window = (float *)malloc((size_t)t->n * sizeof(float));
    t->tail = (float *)calloc((size_t)t->hop * chans, sizeof(float));
    t->reference = (float *)calloc((size_t)t->hop, sizeof(float));
    t->first = 1;
    if (!t->window || !t->tail || !t->reference) { free(t->window); free(t->tail); free(t->reference); free(t); return ka_set_error(KA_ERROR_MEM); }
    for (i = 0; i < t->n; i++) t->window[i] = 0.5f - 0.5f * cosf(2.0f * 3.14159265f * i / t->n);
    ch = ka_channel_new(KA_KIND_TEMPO, src->rate, chans, flags, &ka_tempo_ops, t);
    if (!ch) { tempo_destroy(&(ka_channel){ .impl = t }); return 0; }
    ch->input = source;
    ka_ok();
    return ch->handle;
}
