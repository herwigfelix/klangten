/*
 * A part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).
 * Klangten is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free
 * Software Foundation, version 3. See the file "license" in the repository.
 *
 * ka_encode.c - MP3 files through LAME (LGPL).
 *
 * Two ways in, as Klangten uses them:
 *   - on a playing channel (R, src/eapi/mediarecordings.rb): the mixer hands
 *     what the channel plays (after its effects, before volume) to a queue;
 *     a thread of the encoder encodes it - never the audio thread;
 *   - on a dummy decode stream (src/eapi/audio/encoders/mp3.rb): the host
 *     writes PCM with KA_Encode_Write, encoded right away.
 *
 * Options use LAME's command-line words: "-b 128 --tt "Title" --add-id3v2"
 * (--tt --ta --tl --ty --tc --tn --tg).
 */
#include "ka_internal.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <lame/lame.h>

uint32_t ka_new_handle(void);
int ka_register_encoder(uint32_t handle, void *enc);
void *ka_encoder_lookup(uint32_t handle);
void ka_unregister(uint32_t handle);

typedef struct enc {
    uint32_t handle;
    uint32_t channel;
    lame_global_flags *gf;
    FILE *out;
    int rate, chans, out_chans;
    int from_mixer;
    ma_pcm_rb rb;
    int rb_ready;
    kthread thread;
    int thread_running;
    volatile int stop;
    kevent wake;
    unsigned char *mp3;
    int mp3_cap;
    kmutex lock;
} enc;

static FILE *open_utf8(const char *path) {
#ifdef _WIN32
    wchar_t wpath[4096];
    if (MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, 4096) <= 0) return NULL;
    return _wfopen(wpath, L"w+b");
#else
    return fopen(path, "w+b");
#endif
}

/* "--tt "a b" -b 128" -> next word, quotes and backslashes honoured */
static const char *next_word(const char *p, char *out, size_t cap) {
    size_t n = 0;
    while (*p == ' ') p++;
    if (!*p) return NULL;
    if (*p == '"') {
        p++;
        while (*p && *p != '"') {
            if (*p == '\\' && p[1]) p++;
            if (n + 1 < cap) out[n++] = *p;
            p++;
        }
        if (*p == '"') p++;
    } else {
        while (*p && *p != ' ') { if (n + 1 < cap) out[n++] = *p; p++; }
    }
    out[n] = '\0';
    return p;
}

static void apply_options(enc *e, const char *options) {
    char word[1024], value[1024];
    const char *p = options;
    int id3v2 = 0;
    id3tag_init(e->gf);
    while (p && (p = next_word(p, word, sizeof word)) != NULL) {
        if (strcmp(word, "--add-id3v2") == 0) { id3v2 = 1; continue; }
        if (word[0] != '-') continue;
        if (strcmp(word, "-b") == 0 || strcmp(word, "-B") == 0 || strncmp(word, "--t", 3) == 0) {
            const char *q = next_word(p, value, sizeof value);
            if (!q) break;
            p = q;
            if (strcmp(word, "-b") == 0) lame_set_brate(e->gf, atoi(value));
            else if (strcmp(word, "--tt") == 0) id3tag_set_title(e->gf, value);
            else if (strcmp(word, "--ta") == 0) id3tag_set_artist(e->gf, value);
            else if (strcmp(word, "--tl") == 0) id3tag_set_album(e->gf, value);
            else if (strcmp(word, "--ty") == 0) id3tag_set_year(e->gf, value);
            else if (strcmp(word, "--tc") == 0) id3tag_set_comment(e->gf, value);
            else if (strcmp(word, "--tn") == 0) id3tag_set_track(e->gf, value);
            else if (strcmp(word, "--tg") == 0) id3tag_set_genre(e->gf, value);
        }
    }
    if (id3v2) id3tag_add_v2(e->gf);
}

static int encode_float(enc *e, const float *frames, int count) {
    int need = (int)(1.25 * count + 7200), n;
    if (count <= 0) return 1;
    if (e->mp3_cap < need) {
        unsigned char *b = (unsigned char *)realloc(e->mp3, (size_t)need);
        if (!b) return 0;
        e->mp3 = b;
        e->mp3_cap = need;
    }
    if (e->chans == 1) {
        n = lame_encode_buffer_ieee_float(e->gf, frames, frames, count, e->mp3, e->mp3_cap);
    } else if (e->chans == 2) {
        n = lame_encode_buffer_interleaved_ieee_float(e->gf, frames, count, e->mp3, e->mp3_cap);
    } else {
        /* more than two channels: keep the first two */
        float *st = (float *)malloc((size_t)count * 2 * sizeof(float));
        int f;
        if (!st) return 0;
        for (f = 0; f < count; f++) { st[2 * f] = frames[(size_t)f * e->chans]; st[2 * f + 1] = frames[(size_t)f * e->chans + 1]; }
        n = lame_encode_buffer_interleaved_ieee_float(e->gf, st, count, e->mp3, e->mp3_cap);
        free(st);
    }
    if (n < 0) return 0;
    if (n > 0 && fwrite(e->mp3, 1, (size_t)n, e->out) != (size_t)n) return 0;
    return 1;
}

static void *encoder_main(void *arg) {
    enc *e = (enc *)arg;
    float *tmp = (float *)malloc(4096 * (size_t)e->chans * sizeof(float));
    if (!tmp) return NULL;
    for (;;) {
        ma_uint32 n = 4096;
        void *p;
        int got = 0;
        if (ma_pcm_rb_acquire_read(&e->rb, &n, &p) == MA_SUCCESS && n > 0) {
            memcpy(tmp, p, (size_t)n * e->chans * sizeof(float));
            ma_pcm_rb_commit_read(&e->rb, n);
            got = (int)n;
        }
        if (got > 0) {
            kmutex_lock(&e->lock);
            encode_float(e, tmp, got);
            kmutex_unlock(&e->lock);
            continue;
        }
        if (e->stop) break;
        kevent_wait(&e->wake, 50);
    }
    free(tmp);
    return NULL;
}

static void encoder_finish(enc *e) {
    unsigned char tail[7200];
    int n;
    if (e->thread_running) {
        e->stop = 1;
        kevent_signal(&e->wake);
        kthread_join(e->thread);
        e->thread_running = 0;
    }
    if (e->gf && e->out) {
        n = lame_encode_flush(e->gf, tail, (int)sizeof tail);
        if (n > 0) fwrite(tail, 1, (size_t)n, e->out);
        n = (int)lame_get_id3v1_tag(e->gf, tail, sizeof tail);
        if (n > 0 && n <= (int)sizeof tail) fwrite(tail, 1, (size_t)n, e->out);
        lame_mp3_tags_fid(e->gf, e->out);     /* Xing/LAME header: exact length */
    }
    if (e->out) fclose(e->out);
    if (e->gf) lame_close(e->gf);
    if (e->rb_ready) ma_pcm_rb_uninit(&e->rb);
    kevent_free(&e->wake);
    kmutex_free(&e->lock);
    free(e->mp3);
    free(e);
}

KA_API uint32_t KA_Encode_MP3_StartFile(KAHANDLE handle, const char *options, uint32_t flags, const char *file) {
    ka_channel *ch = ka_channel_get(handle);
    enc *e;
    (void)flags;
    if (!ch) return 0;
    if (!file) return ka_set_error(KA_ERROR_FILEOPEN);
    if (ch->encoder) return ka_set_error(KA_ERROR_ALREADY);
    e = (enc *)calloc(1, sizeof *e);
    if (!e) return ka_set_error(KA_ERROR_MEM);
    kmutex_init(&e->lock);
    kevent_init(&e->wake);
    e->rate = ch->rate;
    e->chans = ch->chans;
    e->out_chans = ch->chans > 2 ? 2 : ch->chans;
    e->channel = handle;
    e->gf = lame_init();
    if (!e->gf) { encoder_finish(e); return ka_set_error(KA_ERROR_MEM); }
    lame_set_in_samplerate(e->gf, e->rate);
    lame_set_num_channels(e->gf, e->out_chans);
    lame_set_mode(e->gf, e->out_chans == 1 ? MONO : JOINT_STEREO);
    lame_set_brate(e->gf, 128);
    lame_set_quality(e->gf, 5);
    lame_set_write_id3tag_automatic(e->gf, 0);   /* v2 at the start, v1 at the end, by hand */
    apply_options(e, options ? options : "");
    if (lame_init_params(e->gf) < 0) { encoder_finish(e); return ka_set_error(KA_ERROR_FORMAT); }
    e->out = open_utf8(file);
    if (!e->out) { encoder_finish(e); return ka_set_error(KA_ERROR_CREATE); }
    {
        /* id3v2 goes first: write it now, the frames follow */
        unsigned char tag[16384];
        size_t n = lame_get_id3v2_tag(e->gf, tag, sizeof tag);
        if (n > 0 && n <= sizeof tag) fwrite(tag, 1, n, e->out);
    }
    e->handle = ka_new_handle();
    if (!ka_register_encoder(e->handle, e)) { encoder_finish(e); return ka_set_error(KA_ERROR_MEM); }
    if (!(ch->flags & KA_STREAM_DECODE)) {
        /* a playing channel: the mixer feeds a queue, a thread encodes */
        if (ma_pcm_rb_init(ma_format_f32, (ma_uint32)e->chans, (ma_uint32)(e->rate * 5), NULL, NULL, &e->rb) != MA_SUCCESS) {
            ka_unregister(e->handle); encoder_finish(e); return ka_set_error(KA_ERROR_MEM);
        }
        e->rb_ready = 1;
        e->from_mixer = 1;
        if (!kthread_start(&e->thread, encoder_main, e)) { ka_unregister(e->handle); encoder_finish(e); return ka_set_error(KA_ERROR_MEM); }
        e->thread_running = 1;
    }
    ch->encoder = e;
    ka_ok();
    return e->handle;
}

/* audio thread: hand over, never encode here */
void ka_encoder_feed(ka_channel *ch, const float *frames, int count) {
    enc *e = (enc *)ch->encoder;
    int done = 0;
    if (!e || !e->rb_ready) return;
    while (done < count) {
        ma_uint32 n = (ma_uint32)(count - done);
        void *p;
        if (ma_pcm_rb_acquire_write(&e->rb, &n, &p) != MA_SUCCESS || n == 0) break;
        memcpy(p, frames + (size_t)done * e->chans, (size_t)n * e->chans * sizeof(float));
        ma_pcm_rb_commit_write(&e->rb, n);
        done += (int)n;
    }
}

KA_API int KA_Encode_Write(uint32_t encoder, const void *buffer, uint32_t length) {
    enc *e = (enc *)ka_encoder_lookup(encoder);
    ka_channel *ch;
    int frames, ok;
    float *tmp;
    size_t i, n;
    if (!e) return ka_set_error(KA_ERROR_HANDLE);
    ch = ka_channel_get(e->channel);
    if (!ch) return 0;
    if (ch->flags & KA_SAMPLE_FLOAT) frames = (int)(length / (4u * (uint32_t)e->chans));
    else frames = (int)(length / (2u * (uint32_t)e->chans));
    if (frames <= 0) return ka_ok();
    n = (size_t)frames * e->chans;
    tmp = (float *)malloc(n * sizeof(float));
    if (!tmp) return ka_set_error(KA_ERROR_MEM);
    if (ch->flags & KA_SAMPLE_FLOAT) memcpy(tmp, buffer, n * sizeof(float));
    else { const int16_t *s = (const int16_t *)buffer; for (i = 0; i < n; i++) tmp[i] = s[i] / 32768.0f; }
    kmutex_lock(&e->lock);
    ok = encode_float(e, tmp, frames);
    kmutex_unlock(&e->lock);
    free(tmp);
    return ok ? ka_ok() : ka_set_error(KA_ERROR_CREATE);
}

KA_API int KA_Encode_Stop(uint32_t encoder) {
    enc *e = (enc *)ka_encoder_lookup(encoder);
    ka_channel *ch;
    if (!e) return ka_set_error(KA_ERROR_HANDLE);
    ch = ka_channel_get(e->channel);
    if (ch && ch->encoder == e) ch->encoder = NULL;
    ka_unregister(encoder);
    encoder_finish(e);
    return ka_ok();
}

void ka_encoder_close_for(ka_channel *ch) {
    enc *e = (enc *)ch->encoder;
    if (!e) return;
    ch->encoder = NULL;
    ka_unregister(e->handle);
    encoder_finish(e);
}

KA_API uint32_t KA_Encode_Start(KAHANDLE handle, const char *cmdline, uint32_t flags, void *proc, void *user) {
    (void)handle; (void)cmdline; (void)flags; (void)proc; (void)user;
    return ka_set_error(KA_ERROR_NOTAVAIL);
}

KA_API int KA_Encode_CastInit(uint32_t encoder, const char *server, const char *pass, const char *content, const char *name, const char *url, const char *genre, const char *desc, const char *headers, uint32_t bitrate, uint32_t flags) {
    (void)encoder; (void)server; (void)pass; (void)content; (void)name; (void)url; (void)genre; (void)desc; (void)headers; (void)bitrate; (void)flags;
    return ka_set_error(KA_ERROR_NOTAVAIL);
}
