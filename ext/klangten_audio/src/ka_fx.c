/*
 * A part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).
 * Klangten is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free
 * Software Foundation, version 3. See the file "license" in the repository.
 *
 * ka_fx.c - the effects programs put on a sound (src/eapi/audio/fx/effects.rb).
 *
 * The parameter blocks are exactly what effects.rb packs: its parameters in
 * declaration order, "f" = 32-bit float, "l" = 32-bit integer. The last
 * field is always the channel mask (-1 = all channels, else bit n-1 for
 * channel n).
 *
 *   ECHO       dry, wet, feedback, delay (s), stereo (l), channels (l)
 *   FREEVERB   dry, wet, room_size, damping, width, freeze (l), channels (l)
 *   CHORUS     dry, wet, feedback, min_sweep (ms), max_sweep (ms), rate (ms/s), channels (l)
 *   PHASER     dry, wet, feedback, rate (Hz), range (octaves), frequency (Hz), channels (l)
 *   DISTORTION drive, dry, wet, feedback, volume, channels (l)
 *   COMPRESSOR gain (dB), threshold (dB), ratio, attack (ms), release (ms), channels (l)
 *   AUTOWAH    dry, wet, feedback, rate (Hz), range (octaves), frequency (Hz), channels (l)
 *   PEAKEQ     band (l), bandwidth (octaves), q, center (Hz), gain (dB), channels (l)
 *   BIQUAD     filter (l), center (Hz), gain (dB), bandwidth (octaves), q, slope, channels (l)
 *   DAMP       target, quiet, rate, gain, delay (s), channels (l)
 *   ROTATE     rate (Hz), channels (l)
 *
 * The algorithms are textbook ones: Freeverb (Jezar at Dreampoint, public
 * domain) for the reverb, the biquads of Robert Bristow-Johnson's Audio EQ
 * Cookbook, delay lines with an LFO for chorus and flanger, a four-stage
 * allpass for the phaser, a peak follower for compressor and auto gain.
 */
#include "ka_internal.h"

#include <stdlib.h>
#include <string.h>
#include <math.h>

#define PI_F 3.14159265358979f
#define MAXCH 8

typedef struct { float b0, b1, b2, a1, a2; float x1[MAXCH], x2[MAXCH], y1[MAXCH], y2[MAXCH]; } biquad;

static void biquad_run(biquad *q, int c, float *x) {
    float in = *x;
    float out = q->b0 * in + q->b1 * q->x1[c] + q->b2 * q->x2[c] - q->a1 * q->y1[c] - q->a2 * q->y2[c];
    q->x2[c] = q->x1[c]; q->x1[c] = in;
    q->y2[c] = q->y1[c]; q->y1[c] = out;
    *x = out;
}

/* RBJ cookbook: type 0 lowpass 1 highpass 2 bandpass (skirt) 3 bandpass (peak 0 dB)
 * 4 notch 5 allpass 6 peaking 7 low shelf 8 high shelf */
static void biquad_design(biquad *q, int type, float rate, float f0, float gain_db, float bw, float qv, float slope) {
    float A = powf(10.0f, gain_db / 40.0f), w0, cw, sw, alpha, a0, b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    if (f0 <= 0) f0 = 1;
    if (f0 > rate * 0.49f) f0 = rate * 0.49f;
    w0 = 2 * PI_F * f0 / rate; cw = cosf(w0); sw = sinf(w0);
    if (bw > 0) alpha = sw * sinhf(logf(2.0f) / 2 * bw * w0 / sw);
    else if (type == 7 || type == 8) {
        float S = slope > 0 ? slope : 1;
        alpha = sw / 2 * sqrtf((A + 1 / A) * (1 / S - 1) + 2);
    } else alpha = sw / (2 * (qv > 0 ? qv : 0.707f));
    switch (type) {
    case 0: b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
    case 1: b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
    case 2: b0 = sw / 2; b1 = 0; b2 = -sw / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
    case 3: b0 = alpha; b1 = 0; b2 = -alpha; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
    case 4: b0 = 1; b1 = -2 * cw; b2 = 1; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
    case 5: b0 = 1 - alpha; b1 = -2 * cw; b2 = 1 + alpha; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
    case 6: b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A; break;
    case 7: {
        float sa = 2 * sqrtf(A) * alpha;
        b0 = A * ((A + 1) - (A - 1) * cw + sa); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - sa);
        a0 = (A + 1) + (A - 1) * cw + sa; a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - sa;
        break;
    }
    case 8: {
        float sa = 2 * sqrtf(A) * alpha;
        b0 = A * ((A + 1) + (A - 1) * cw + sa); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - sa);
        a0 = (A + 1) - (A - 1) * cw + sa; a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - sa;
        break;
    }
    default: a0 = 1; break;
    }
    q->b0 = b0 / a0; q->b1 = b1 / a0; q->b2 = b2 / a0; q->a1 = a1 / a0; q->a2 = a2 / a0;
}

typedef struct { float *buf; int len, pos; } delay_line;
static int dl_init(delay_line *d, int len) { d->buf = (float *)calloc((size_t)(len > 1 ? len : 1), sizeof(float)); d->len = len > 1 ? len : 1; d->pos = 0; return d->buf != NULL; }
static void dl_free(delay_line *d) { free(d->buf); d->buf = NULL; }
static float dl_read(delay_line *d, float delay_samples) {
    float p = (float)d->pos - delay_samples;
    int i0; float frac;
    while (p < 0) p += (float)d->len;
    i0 = (int)p; frac = p - (float)i0;
    return d->buf[i0 % d->len] * (1 - frac) + d->buf[(i0 + 1) % d->len] * frac;
}
static void dl_write(delay_line *d, float v) { d->buf[d->pos] = v; d->pos = (d->pos + 1) % d->len; }

/* ---- Freeverb ---- */
static const int comb_tuning[8] = { 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 };
static const int ap_tuning[4] = { 556, 441, 341, 225 };
typedef struct { float *buf; int len, pos; float store; } fv_comb;
typedef struct { float *buf; int len, pos; } fv_ap;
typedef struct { fv_comb comb[MAXCH][8]; fv_ap ap[MAXCH][4]; } fv_state;

typedef struct {
    /* generic per-effect state */
    delay_line dl[MAXCH];
    biquad bq;
    biquad stages[4];
    float phase, env[MAXCH], gain_now, last[MAXCH], hold;
    fv_state *fv;
    float ap_state[MAXCH][4];
} fx_state;

static int mask_has(int32_t mask, int c) { return mask == -1 || (mask & (1 << c)); }

static float fparam(ka_fx *fx, int index) { float v; memcpy(&v, fx->params + index * 4, 4); return v; }
static int32_t iparam(ka_fx *fx, int index) { int32_t v; memcpy(&v, fx->params + index * 4, 4); return v; }

static size_t params_size_for(uint32_t type) {
    switch (type) {
    case KA_FX_ECHO: return 24;
    case KA_FX_FREEVERB: return 28;
    case KA_FX_CHORUS: return 28;
    case KA_FX_PHASER: return 28;
    case KA_FX_DISTORTION: return 24;
    case KA_FX_COMPRESSOR: return 24;
    case KA_FX_AUTOWAH: return 28;
    case KA_FX_PEAKEQ: return 24;
    case KA_FX_BIQUAD: return 28;
    case KA_FX_DAMP: return 24;
    case KA_FX_ROTATE: return 8;
    default: return 0;
    }
}

static void set_default(ka_fx *fx) {
    float f[8] = {0};
    int32_t all = -1;
    switch (fx->type) {
    case KA_FX_ECHO: f[0] = 1; f[1] = 0.5f; f[2] = 0.3f; f[3] = 0.25f; memcpy(fx->params, f, 16); { int32_t st = 1; memcpy(fx->params + 16, &st, 4); } memcpy(fx->params + 20, &all, 4); break;
    case KA_FX_FREEVERB: f[0] = 1; f[1] = 0.5f; f[2] = 0.5f; f[3] = 0.5f; f[4] = 1; memcpy(fx->params, f, 20); memset(fx->params + 20, 0, 4); memcpy(fx->params + 24, &all, 4); break;
    case KA_FX_CHORUS: f[0] = 1; f[1] = 0.5f; f[2] = 0; f[3] = 5; f[4] = 30; f[5] = 20; memcpy(fx->params, f, 24); memcpy(fx->params + 24, &all, 4); break;
    case KA_FX_PHASER: f[0] = 1; f[1] = 0.5f; f[2] = 0; f[3] = 1; f[4] = 4; f[5] = 500; memcpy(fx->params, f, 24); memcpy(fx->params + 24, &all, 4); break;
    case KA_FX_DISTORTION: f[0] = 1; f[1] = 0.8f; f[2] = 0.2f; f[3] = 0; f[4] = 1; memcpy(fx->params, f, 20); memcpy(fx->params + 20, &all, 4); break;
    case KA_FX_COMPRESSOR: f[0] = 0; f[1] = -12; f[2] = 4; f[3] = 10; f[4] = 100; memcpy(fx->params, f, 20); memcpy(fx->params + 20, &all, 4); break;
    case KA_FX_AUTOWAH: f[0] = 0.5f; f[1] = 0.5f; f[2] = 0.2f; f[3] = 2; f[4] = 4; f[5] = 200; memcpy(fx->params, f, 24); memcpy(fx->params + 24, &all, 4); break;
    case KA_FX_PEAKEQ: memset(fx->params, 0, 4); f[0] = 1; f[1] = 0; f[2] = 1000; f[3] = 0; memcpy(fx->params + 4, f, 16); memcpy(fx->params + 20, &all, 4); break;
    case KA_FX_BIQUAD: memset(fx->params, 0, 4); f[0] = 1000; f[1] = 0; f[2] = 0; f[3] = 0.707f; f[4] = 1; memcpy(fx->params + 4, f, 20); memcpy(fx->params + 24, &all, 4); break;
    case KA_FX_DAMP: f[0] = 0.95f; f[1] = 0.02f; f[2] = 0.5f; f[3] = 1; f[4] = 0; memcpy(fx->params, f, 20); memcpy(fx->params + 20, &all, 4); break;
    case KA_FX_ROTATE: f[0] = 0.2f; memcpy(fx->params, f, 4); memcpy(fx->params + 4, &all, 4); break;
    }
}

static void free_state(ka_fx *fx) {
    fx_state *s = (fx_state *)fx->state;
    int c, i;
    if (!s) return;
    for (c = 0; c < MAXCH; c++) dl_free(&s->dl[c]);
    if (s->fv) {
        for (c = 0; c < MAXCH; c++) {
            for (i = 0; i < 8; i++) free(s->fv->comb[c][i].buf);
            for (i = 0; i < 4; i++) free(s->fv->ap[c][i].buf);
        }
        free(s->fv);
    }
    free(s);
    fx->state = NULL;
}

static int alloc_state(ka_fx *fx) {
    fx_state *s = (fx_state *)calloc(1, sizeof *s);
    int c, i, chans = fx->chans > MAXCH ? MAXCH : fx->chans;
    if (!s) return 0;
    fx->state = s;
    s->gain_now = 1.0f;
    if (fx->type == KA_FX_ECHO || fx->type == KA_FX_CHORUS) {
        int len = fx->type == KA_FX_ECHO ? fx->rate * 6 + 2 : fx->rate / 10 + 2;   /* echo up to 6 s, chorus 100 ms */
        for (c = 0; c < chans; c++) if (!dl_init(&s->dl[c], len)) return 0;
    }
    if (fx->type == KA_FX_FREEVERB) {
        float scale = (float)fx->rate / 44100.0f;
        s->fv = (fv_state *)calloc(1, sizeof *s->fv);
        if (!s->fv) return 0;
        for (c = 0; c < chans; c++) {
            int spread = (c % 2) ? 23 : 0;
            for (i = 0; i < 8; i++) {
                s->fv->comb[c][i].len = (int)((comb_tuning[i] + spread) * scale) + 1;
                s->fv->comb[c][i].buf = (float *)calloc((size_t)s->fv->comb[c][i].len, sizeof(float));
                if (!s->fv->comb[c][i].buf) return 0;
            }
            for (i = 0; i < 4; i++) {
                s->fv->ap[c][i].len = (int)((ap_tuning[i] + spread) * scale) + 1;
                s->fv->ap[c][i].buf = (float *)calloc((size_t)s->fv->ap[c][i].len, sizeof(float));
                if (!s->fv->ap[c][i].buf) return 0;
            }
        }
    }
    return 1;
}

static void redesign(ka_fx *fx) {
    fx_state *s = (fx_state *)fx->state;
    if (fx->type == KA_FX_PEAKEQ)
        biquad_design(&s->bq, 6, (float)fx->rate, fparam(fx, 3), fparam(fx, 4), fparam(fx, 1), fparam(fx, 2), 1);
    if (fx->type == KA_FX_BIQUAD)
        biquad_design(&s->bq, iparam(fx, 0), (float)fx->rate, fparam(fx, 1), fparam(fx, 2), fparam(fx, 3), fparam(fx, 4), fparam(fx, 5));
}

ka_fx *ka_fx_create(uint32_t type, int rate, int chans) {
    ka_fx *fx;
    if (params_size_for(type) == 0) return NULL;
    fx = (ka_fx *)calloc(1, sizeof *fx);
    if (!fx) return NULL;
    fx->type = type;
    fx->rate = rate;
    fx->chans = chans;
    fx->params_size = params_size_for(type);
    set_default(fx);
    if (!alloc_state(fx)) { free_state(fx); free(fx); return NULL; }
    redesign(fx);
    return fx;
}

int ka_fx_set_params(ka_fx *fx, const void *params) {
    if (!params) return 0;
    memcpy(fx->params, params, fx->params_size);
    redesign(fx);
    return 1;
}
int ka_fx_get_params(ka_fx *fx, void *params) {
    if (!params) return 0;
    memcpy(params, fx->params, fx->params_size);
    return 1;
}
void ka_fx_reset(ka_fx *fx) {
    free_state(fx);
    alloc_state(fx);
    redesign(fx);
}
void ka_fx_destroy(ka_fx *fx) {
    if (!fx) return;
    free_state(fx);
    free(fx);
}

static float fv_comb_run(fv_comb *c, float in, float feedback, float damp) {
    float out = c->buf[c->pos];
    c->store = out * (1 - damp) + c->store * damp;
    c->buf[c->pos] = in + c->store * feedback;
    if (++c->pos >= c->len) c->pos = 0;
    return out;
}
static float fv_ap_run(fv_ap *a, float in) {
    float b = a->buf[a->pos], out = -in + b;
    a->buf[a->pos] = in + b * 0.5f;
    if (++a->pos >= a->len) a->pos = 0;
    return out;
}

void ka_fx_process(ka_fx *fx, float *x, int frames) {
    fx_state *s = (fx_state *)fx->state;
    int chans = fx->chans > MAXCH ? MAXCH : fx->chans, step = fx->chans, f, c;
    float rate = (float)fx->rate;
    if (!s) return;
    switch (fx->type) {
    case KA_FX_ECHO: {
        float dry = fparam(fx, 0), wet = fparam(fx, 1), fb = fparam(fx, 2), dly = fparam(fx, 3) * rate;
        int stereo = iparam(fx, 4), mask = iparam(fx, 5);
        if (dly > s->dl[0].len - 2) dly = (float)(s->dl[0].len - 2);
        if (dly < 1) dly = 1;
        for (f = 0; f < frames; f++) {
            float *p = x + (size_t)f * step, d[MAXCH];
            for (c = 0; c < chans; c++) d[c] = dl_read(&s->dl[c], dly);
            for (c = 0; c < chans; c++) {
                float back = (stereo && chans == 2) ? d[1 - c] : d[c];
                if (!mask_has(mask, c)) { dl_write(&s->dl[c], 0); continue; }
                dl_write(&s->dl[c], p[c] + back * fb);
                p[c] = p[c] * dry + d[c] * wet;
            }
        }
        break;
    }
    case KA_FX_FREEVERB: {
        float dry = fparam(fx, 0), wet = fparam(fx, 1), room = fparam(fx, 2), damp = fparam(fx, 3), width = fparam(fx, 4);
        int freeze = iparam(fx, 5), mask = iparam(fx, 6), i;
        float fbk = freeze ? 1.0f : room * 0.28f + 0.7f, dmp = freeze ? 0.0f : damp * 0.4f, gain = freeze ? 0.0f : 0.015f;
        float wet1 = wet * 3.0f * (width / 2 + 0.5f), wet2 = wet * 3.0f * ((1 - width) / 2);
        for (f = 0; f < frames; f++) {
            float *p = x + (size_t)f * step, out[MAXCH], in = 0;
            for (c = 0; c < chans; c++) in += p[c];
            in = in / (float)chans * gain;
            for (c = 0; c < chans; c++) {
                float acc = 0;
                for (i = 0; i < 8; i++) acc += fv_comb_run(&s->fv->comb[c][i], in, fbk, dmp);
                for (i = 0; i < 4; i++) acc = fv_ap_run(&s->fv->ap[c][i], acc);
                out[c] = acc;
            }
            for (c = 0; c < chans; c++) {
                float other = chans == 2 ? out[1 - c] : out[c];
                if (!mask_has(mask, c)) continue;
                p[c] = p[c] * dry + out[c] * wet1 + other * wet2;
            }
        }
        break;
    }
    case KA_FX_CHORUS: {
        float dry = fparam(fx, 0), wet = fparam(fx, 1), fb = fparam(fx, 2), mn = fparam(fx, 3), mx = fparam(fx, 4), rt = fparam(fx, 5);
        int mask = iparam(fx, 6);
        float span = mx > mn ? mx - mn : 0.001f, maxlen = (float)(s->dl[0].len - 2);
        for (f = 0; f < frames; f++) {
            float *p = x + (size_t)f * step;
            float tri, dms, dsamp;
            s->phase += rt / rate / (2 * span);           /* sweeps `rate` ms per second */
            if (s->phase >= 1) s->phase -= 1;
            tri = s->phase < 0.5f ? s->phase * 2 : 2 - s->phase * 2;
            dms = mn + span * tri;
            dsamp = dms * rate / 1000.0f;
            if (dsamp > maxlen) dsamp = maxlen;
            if (dsamp < 1) dsamp = 1;
            for (c = 0; c < chans; c++) {
                float d = dl_read(&s->dl[c], dsamp);
                if (!mask_has(mask, c)) { dl_write(&s->dl[c], p[c]); continue; }
                dl_write(&s->dl[c], p[c] + d * fb);
                p[c] = p[c] * dry + d * wet;
            }
        }
        break;
    }
    case KA_FX_PHASER: case KA_FX_AUTOWAH: {
        float dry = fparam(fx, 0), wet = fparam(fx, 1), fb = fparam(fx, 2), rt = fparam(fx, 3), range = fparam(fx, 4), base = fparam(fx, 5);
        int mask = iparam(fx, 6), i;
        for (f = 0; f < frames; f++) {
            float *p = x + (size_t)f * step;
            float lfo, fc;
            s->phase += rt / rate;
            if (s->phase >= 1) s->phase -= 1;
            lfo = 0.5f - 0.5f * cosf(2 * PI_F * s->phase);
            fc = base * powf(2.0f, range * lfo);
            if (fc > rate * 0.45f) fc = rate * 0.45f;
            if ((f & 31) == 0) {
                if (fx->type == KA_FX_AUTOWAH) biquad_design(&s->bq, 3, rate, fc, 0, 0, 3.0f, 1);
                else for (i = 0; i < 4; i++) biquad_design(&s->stages[i], 5, rate, fc * (1 + i * 0.5f), 0, 0, 0.7f, 1);
            }
            for (c = 0; c < chans; c++) {
                float v = p[c] + s->last[c] * fb;
                if (!mask_has(mask, c)) continue;
                if (fx->type == KA_FX_AUTOWAH) biquad_run(&s->bq, c, &v);
                else for (i = 0; i < 4; i++) biquad_run(&s->stages[i], c, &v);
                s->last[c] = v;
                p[c] = p[c] * dry + v * wet;
            }
        }
        break;
    }
    case KA_FX_DISTORTION: {
        float drive = fparam(fx, 0), dry = fparam(fx, 1), wet = fparam(fx, 2), fb = fparam(fx, 3), vol = fparam(fx, 4);
        int mask = iparam(fx, 5);
        for (f = 0; f < frames; f++) {
            float *p = x + (size_t)f * step;
            for (c = 0; c < chans; c++) {
                float v;
                if (!mask_has(mask, c)) continue;
                v = tanhf((p[c] + s->last[c] * fb) * (1.0f + drive * 4.0f));
                s->last[c] = v;
                p[c] = (p[c] * dry + v * wet) * vol;
            }
        }
        break;
    }
    case KA_FX_COMPRESSOR: {
        float makeup = powf(10.0f, fparam(fx, 0) / 20.0f), thr = fparam(fx, 1), ratio = fparam(fx, 2);
        float att = expf(-1.0f / (rate * fparam(fx, 3) / 1000.0f + 1e-6f)), rel = expf(-1.0f / (rate * fparam(fx, 4) / 1000.0f + 1e-6f));
        int mask = iparam(fx, 5);
        if (ratio < 1) ratio = 1;
        for (f = 0; f < frames; f++) {
            float *p = x + (size_t)f * step, peak = 0, db, gr, g;
            for (c = 0; c < chans; c++) if (mask_has(mask, c) && fabsf(p[c]) > peak) peak = fabsf(p[c]);
            s->env[0] = peak > s->env[0] ? att * s->env[0] + (1 - att) * peak : rel * s->env[0] + (1 - rel) * peak;
            db = 20.0f * log10f(s->env[0] + 1e-9f);
            gr = db > thr ? (thr + (db - thr) / ratio) - db : 0;
            g = powf(10.0f, gr / 20.0f) * makeup;
            for (c = 0; c < chans; c++) if (mask_has(mask, c)) p[c] *= g;
        }
        break;
    }
    case KA_FX_PEAKEQ: case KA_FX_BIQUAD: {
        int mask = iparam(fx, fx->type == KA_FX_PEAKEQ ? 5 : 6);
        for (f = 0; f < frames; f++) {
            float *p = x + (size_t)f * step;
            for (c = 0; c < chans; c++) if (mask_has(mask, c)) biquad_run(&s->bq, c, &p[c]);
        }
        break;
    }
    case KA_FX_DAMP: {
        float target = fparam(fx, 0), quiet = fparam(fx, 1), rt = fparam(fx, 2), maxgain = fparam(fx, 3), dly = fparam(fx, 4);
        int mask = iparam(fx, 5);
        float follow = expf(-1.0f / (rate * 0.05f));
        if (maxgain < 1) maxgain = 1;
        for (f = 0; f < frames; f++) {
            float *p = x + (size_t)f * step, peak = 0, want;
            for (c = 0; c < chans; c++) if (mask_has(mask, c) && fabsf(p[c]) > peak) peak = fabsf(p[c]);
            s->env[0] = peak > s->env[0] ? peak : follow * s->env[0];
            if (s->env[0] < quiet) { s->hold = 0; want = s->gain_now; }
            else {
                want = target / (s->env[0] + 1e-9f);
                if (want > maxgain) want = maxgain;
                if (want < s->gain_now) s->gain_now = want;      /* never clip */
                else if ((s->hold += 1.0f / rate) >= dly) s->gain_now += (want - s->gain_now) * rt / rate;
            }
            for (c = 0; c < chans; c++) if (mask_has(mask, c)) p[c] *= s->gain_now;
        }
        break;
    }
    case KA_FX_ROTATE: {
        float rt = fparam(fx, 0);
        if (chans < 2) break;
        for (f = 0; f < frames; f++) {
            float *p = x + (size_t)f * step, l = p[0], r = p[1], a;
            s->phase += rt / rate;
            if (s->phase >= 1) s->phase -= 1;
            a = sinf(2 * PI_F * s->phase);
            p[0] = l * (0.5f - 0.5f * a) + r * (0.5f - 0.5f * a);
            p[1] = r * (0.5f + 0.5f * a) + l * (0.5f + 0.5f * a);
        }
        break;
    }
    }
}
