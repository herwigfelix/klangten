/*
 * A part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).
 * Klangten is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free
 * Software Foundation, version 3. See the file "license" in the repository.
 *
 * ka_decoder.c - files, memory and internet streams through FFmpeg.
 *
 * One decoder per stream: demux, decode, convert to float at the stream's
 * own rate and channel count (swresample). Internet streams use FFmpeg's
 * http/https (reconnecting), HLS and Icecast metadata ("icy"); a blocking
 * network call is interrupted when the stream is freed.
 *
 * Seeking is sample exact: FFmpeg lands on the packet before the target,
 * the frames in front of the target are dropped.
 *
 * Tags come out the way Klangten's AudioInfo reads them:
 *   KA_TAG_OGG  "KEY=value\0KEY=value\0\0", every format; chapters as
 *               CHAPTER001=00:01:02.500 and CHAPTER001NAME=title
 *   KA_TAG_META "StreamTitle='...';" of an Icecast/Shoutcast station
 *   KA_TAG_ICY  the station's icy-* headers, one per string
 */
#include "ka_internal.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libavutil/log.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libswresample/swresample.h>

void ka_channel_prebuffer(ka_channel *ch);

typedef struct mem_src {
    uint8_t *data;
    int64_t size, pos;
} mem_src;

typedef struct dec {
    AVFormatContext *fmt;
    AVCodecContext *cc;
    SwrContext *swr;
    AVPacket *pkt;
    AVFrame *frm;
    int stream;
    int rate, chans;
    float *pend;           /* converted frames not handed out yet */
    int pend_cap, pend_len, pend_off;
    int64_t skip_until;    /* drop frames before this position (seek) */
    int64_t next_frame;    /* position of the next frame produced */
    int flushing, finished;
    volatile int abort;
    double deadline;       /* open: give up after this clock time */
    int is_url;
    mem_src *mem;
    AVIOContext *mem_io;
    char *tags_ogg;
    char *tags_meta;
    char *tags_icy;
    char *filename;
    double meta_checked;
} dec;

static int interrupt_cb(void *opaque) {
    dec *d = (dec *)opaque;
    if (d->abort) return 1;
    if (d->deadline > 0 && ka_clock() > d->deadline) return 1;
    return 0;
}

static int mem_read(void *opaque, uint8_t *buf, int size) {
    mem_src *m = (mem_src *)opaque;
    int64_t left = m->size - m->pos;
    if (left <= 0) return AVERROR_EOF;
    if (size > left) size = (int)left;
    memcpy(buf, m->data + m->pos, (size_t)size);
    m->pos += size;
    return size;
}

static int64_t mem_seek(void *opaque, int64_t offset, int whence) {
    mem_src *m = (mem_src *)opaque;
    int64_t np;
    if (whence == AVSEEK_SIZE) return m->size;
    whence &= ~AVSEEK_FORCE;
    if (whence == SEEK_SET) np = offset;
    else if (whence == SEEK_CUR) np = m->pos + offset;
    else if (whence == SEEK_END) np = m->size + offset;
    else return -1;
    if (np < 0 || np > m->size) return -1;
    m->pos = np;
    return np;
}

static void dec_free(dec *d) {
    if (!d) return;
    d->abort = 1;
    if (d->swr) swr_free(&d->swr);
    if (d->cc) avcodec_free_context(&d->cc);
    if (d->fmt) avformat_close_input(&d->fmt);
    if (d->mem_io) { av_freep(&d->mem_io->buffer); avio_context_free(&d->mem_io); }
    if (d->mem) { free(d->mem->data); free(d->mem); }
    if (d->pkt) av_packet_free(&d->pkt);
    if (d->frm) av_frame_free(&d->frm);
    free(d->pend);
    free(d->tags_ogg);
    free(d->tags_meta);
    free(d->tags_icy);
    free(d->filename);
    free(d);
}

static int map_error(int averr, int is_url) {
    if (averr == AVERROR(ENOENT)) return KA_ERROR_FILEOPEN;
    if (averr == AVERROR_INVALIDDATA) return KA_ERROR_FILEFORM;
    if (averr == AVERROR_EXIT) return KA_ERROR_TIMEOUT;
    if (averr == AVERROR_HTTP_NOT_FOUND || averr == AVERROR_HTTP_FORBIDDEN || averr == AVERROR_HTTP_UNAUTHORIZED) return KA_ERROR_FILEOPEN;
    if (averr == AVERROR_PROTOCOL_NOT_FOUND) return KA_ERROR_PROTOCOL;
    if (averr == AVERROR(ETIMEDOUT)) return KA_ERROR_TIMEOUT;
    return is_url ? KA_ERROR_NONET : KA_ERROR_FILEOPEN;
}

/* Opens everything up to a working decoder. Returns 0 and sets the error. */
static void quiet_ffmpeg(void) {
    static int done;
    if (done) return;
    done = 1;
    /* FFmpeg logs to stderr; Klangten reports errors itself. KLANGTEN_AUDIO_DEBUG
     * brings the messages back for debugging. */
    av_log_set_level(getenv("KLANGTEN_AUDIO_DEBUG") ? AV_LOG_INFO : AV_LOG_QUIET);
}

static int dec_open(dec *d, const char *url) {
    AVDictionary *opts = NULL;
    const AVCodec *codec = NULL;
    AVStream *st;
    AVChannelLayout out_layout;
    int r;

    quiet_ffmpeg();
    d->fmt = avformat_alloc_context();
    if (!d->fmt) return ka_set_error(KA_ERROR_MEM);
    d->fmt->interrupt_callback.callback = interrupt_cb;
    d->fmt->interrupt_callback.opaque = d;
    if (d->mem_io) {
        d->fmt->pb = d->mem_io;
        d->fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
    }
    if (d->is_url) {
        const char *agent = ka_config_string(KA_CONFIG_NET_AGENT);
        const char *proxy = ka_config_string(KA_CONFIG_NET_PROXY);
        int timeout_ms = ka_config_int(KA_CONFIG_NET_TIMEOUT, 15000);
        char tbuf[32];
        if (agent && agent[0]) av_dict_set(&opts, "user_agent", agent, 0);
        if (proxy && proxy[0]) {
            char pbuf[512];
            snprintf(pbuf, sizeof pbuf, "%s%s", strstr(proxy, "://") ? "" : "http://", proxy);
            av_dict_set(&opts, "http_proxy", pbuf, 0);
        }
        snprintf(tbuf, sizeof tbuf, "%lld", (long long)timeout_ms * 1000LL);
        av_dict_set(&opts, "rw_timeout", tbuf, 0);
        av_dict_set(&opts, "reconnect", "1", 0);
        av_dict_set(&opts, "reconnect_streamed", "1", 0);
        av_dict_set(&opts, "reconnect_on_network_error", "1", 0);
        av_dict_set(&opts, "reconnect_delay_max", "4", 0);
        av_dict_set(&opts, "icy", "1", 0);
        {
            const char *ca = ka_config_string(KA_CONFIG_CA_FILE);
            if (ca && ca[0]) av_dict_set(&opts, "ca_file", ca, 0);
        }
        d->deadline = ka_clock() + timeout_ms / 1000.0 + 5.0;
    }
    r = avformat_open_input(&d->fmt, d->mem_io ? NULL : url, NULL, &opts);
    av_dict_free(&opts);
    if (r < 0) { d->fmt = NULL; return ka_set_error(map_error(r, d->is_url)); }
    d->fmt->flags |= AVFMT_FLAG_GENPTS;
    if ((r = avformat_find_stream_info(d->fmt, NULL)) < 0) return ka_set_error(map_error(r, d->is_url));
    d->deadline = 0;
    d->stream = av_find_best_stream(d->fmt, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    if (d->stream < 0 || !codec) return ka_set_error(d->stream == AVERROR_DECODER_NOT_FOUND ? KA_ERROR_CODEC : KA_ERROR_FILEFORM);
    st = d->fmt->streams[d->stream];
    d->cc = avcodec_alloc_context3(codec);
    if (!d->cc) return ka_set_error(KA_ERROR_MEM);
    if (avcodec_parameters_to_context(d->cc, st->codecpar) < 0) return ka_set_error(KA_ERROR_CODEC);
    d->cc->pkt_timebase = st->time_base;
    if (avcodec_open2(d->cc, codec, NULL) < 0) return ka_set_error(KA_ERROR_CODEC);
    d->rate = d->cc->sample_rate;
    d->chans = d->cc->ch_layout.nb_channels;
    if (d->rate <= 0 || d->chans <= 0) return ka_set_error(KA_ERROR_FORMAT);
    if (d->chans > 8) d->chans = 8;
    av_channel_layout_default(&out_layout, d->chans);
    if (swr_alloc_set_opts2(&d->swr, &out_layout, AV_SAMPLE_FMT_FLT, d->rate,
                            &d->cc->ch_layout, d->cc->sample_fmt, d->cc->sample_rate, 0, NULL) < 0 || swr_init(d->swr) < 0)
        return ka_set_error(KA_ERROR_FORMAT);
    av_channel_layout_uninit(&out_layout);
    d->pkt = av_packet_alloc();
    d->frm = av_frame_alloc();
    if (!d->pkt || !d->frm) return ka_set_error(KA_ERROR_MEM);
    for (r = 0; r < (int)d->fmt->nb_streams; r++)
        if (r != d->stream) d->fmt->streams[r]->discard = AVDISCARD_ALL;
    return 1;
}

static int pend_reserve(dec *d, int frames) {
    if (d->pend_cap >= frames) return 1;
    {
        float *p = (float *)realloc(d->pend, (size_t)frames * d->chans * sizeof(float));
        if (!p) return 0;
        d->pend = p;
        d->pend_cap = frames;
    }
    return 1;
}

/* Converts one decoded frame into the pending buffer, honouring skip_until. */
static void take_frame(dec *d, AVFrame *f) {
    int out_max = swr_get_out_samples(d->swr, f->nb_samples) + 32, got;
    uint8_t *outp[1];
    int64_t first;
    if (d->pend_off > 0 && d->pend_off == d->pend_len) { d->pend_off = 0; d->pend_len = 0; }
    if (d->pend_off > 0) {
        memmove(d->pend, d->pend + (size_t)d->pend_off * d->chans, (size_t)(d->pend_len - d->pend_off) * d->chans * sizeof(float));
        d->pend_len -= d->pend_off;
        d->pend_off = 0;
    }
    if (!pend_reserve(d, d->pend_len + out_max)) return;
    outp[0] = (uint8_t *)(d->pend + (size_t)d->pend_len * d->chans);
    got = swr_convert(d->swr, outp, out_max, (const uint8_t **)f->extended_data, f->nb_samples);
    if (got <= 0) return;
    /* position of this frame, from its timestamp when there is one */
    first = d->next_frame;
    if (f->best_effort_timestamp != AV_NOPTS_VALUE) {
        AVRational tb = d->fmt->streams[d->stream]->time_base;
        int64_t ts = av_rescale_q(f->best_effort_timestamp, tb, (AVRational){1, d->rate});
        int64_t start = d->fmt->streams[d->stream]->start_time;
        if (start != AV_NOPTS_VALUE) ts -= av_rescale_q(start, tb, (AVRational){1, d->rate});
        if (d->skip_until >= 0) first = ts;
    }
    d->next_frame = first + got;
    if (d->skip_until >= 0) {
        int64_t drop = d->skip_until - first;
        if (drop >= got) return;               /* entirely before the target */
        if (drop > 0) {
            memmove(outp[0], (float *)outp[0] + (size_t)drop * d->chans, (size_t)(got - drop) * d->chans * sizeof(float));
            got -= (int)drop;
        }
        d->skip_until = -1;
    }
    d->pend_len += got;
}

static void update_meta(dec *d) {
    uint8_t *v = NULL;
    double now;
    if (!d->is_url || !d->fmt || !d->fmt->pb) return;
    now = ka_clock();
    if (now - d->meta_checked < 1.0) return;
    d->meta_checked = now;
    if (av_opt_get(d->fmt->pb, "icy_metadata_packet", AV_OPT_SEARCH_CHILDREN, &v) >= 0 && v) {
        if (v[0] && (!d->tags_meta || strcmp(d->tags_meta, (char *)v) != 0)) {
            free(d->tags_meta);
            d->tags_meta = strdup((char *)v);
        }
        av_free(v);
    }
}

/* Decodes until at least `want` frames are pending or the stream ends. */
static void decode_more(dec *d, int want) {
    int r;
    while (d->pend_len - d->pend_off < want && !d->finished && !d->abort) {
        r = avcodec_receive_frame(d->cc, d->frm);
        if (r == 0) { take_frame(d, d->frm); av_frame_unref(d->frm); continue; }
        if (r == AVERROR_EOF) { d->finished = 1; break; }
        if (r != AVERROR(EAGAIN)) { d->finished = 1; break; }
        if (d->flushing) { d->finished = 1; break; }
        r = av_read_frame(d->fmt, d->pkt);
        if (r < 0) {
            if (r == AVERROR(EAGAIN)) break;
            d->flushing = 1;
            avcodec_send_packet(d->cc, NULL);
            continue;
        }
        if (d->pkt->stream_index == d->stream) {
            if (avcodec_send_packet(d->cc, d->pkt) == AVERROR_INVALIDDATA) { /* skip broken packet */ }
        }
        av_packet_unref(d->pkt);
    }
    update_meta(d);
}

static int dec_read(ka_channel *ch, float *out, int frames, int *ended) {
    dec *d = (dec *)ch->impl;
    int have;
    *ended = 0;
    decode_more(d, frames);
    have = d->pend_len - d->pend_off;
    if (have > frames) have = frames;
    if (have > 0) {
        memcpy(out, d->pend + (size_t)d->pend_off * d->chans, (size_t)have * d->chans * sizeof(float));
        d->pend_off += have;
    }
    if (d->finished && d->pend_len - d->pend_off == 0) *ended = 1;
    return have;
}

static int dec_seek(ka_channel *ch, int64_t frame) {
    dec *d = (dec *)ch->impl;
    AVStream *st = d->fmt->streams[d->stream];
    int64_t ts = av_rescale_q(frame, (AVRational){1, d->rate}, st->time_base);
    if (st->start_time != AV_NOPTS_VALUE) ts += st->start_time;
    if (av_seek_frame(d->fmt, d->stream, ts, AVSEEK_FLAG_BACKWARD) < 0) {
        if (frame != 0) return 0;
        if (avformat_seek_file(d->fmt, -1, INT64_MIN, 0, INT64_MAX, 0) < 0) return 0;
    }
    avcodec_flush_buffers(d->cc);
    swr_convert(d->swr, NULL, 0, NULL, 0);
    d->pend_len = d->pend_off = 0;
    d->flushing = d->finished = 0;
    d->skip_until = frame;
    d->next_frame = frame;
    return 1;
}

static int64_t dec_length(ka_channel *ch) {
    dec *d = (dec *)ch->impl;
    AVStream *st = d->fmt->streams[d->stream];
    if (st->duration != AV_NOPTS_VALUE && st->duration > 0)
        return av_rescale_q(st->duration, st->time_base, (AVRational){1, d->rate});
    if (d->fmt->duration != AV_NOPTS_VALUE && d->fmt->duration > 0)
        return av_rescale(d->fmt->duration, d->rate, AV_TIME_BASE);
    return -1;
}

static void append_tag(char **buf, size_t *len, size_t *cap, const char *key, const char *value) {
    size_t kl = strlen(key), vl = strlen(value), need = kl + 1 + vl + 1;
    if (*len + need + 1 > *cap) {
        size_t n = (*cap + need + 1) * 2;
        char *p = (char *)realloc(*buf, n);
        if (!p) return;
        *buf = p;
        *cap = n;
    }
    memcpy(*buf + *len, key, kl);
    (*buf)[*len + kl] = '=';
    memcpy(*buf + *len + kl + 1, value, vl);
    (*buf)[*len + need - 1] = '\0';
    *len += need;
}

static void upper(char *s) { for (; *s; s++) if (*s >= 'a' && *s <= 'z') *s = (char)(*s - 32); }

static const char *dec_tags(ka_channel *ch, uint32_t type) {
    dec *d = (dec *)ch->impl;
    if (type == KA_TAG_META) { update_meta(d); return d->tags_meta; }
    if (type == KA_TAG_ICY || type == KA_TAG_HTTP) {
        uint8_t *v = NULL;
        if (!d->is_url || !d->fmt->pb) return NULL;
        if (av_opt_get(d->fmt->pb, "icy_metadata_headers", AV_OPT_SEARCH_CHILDREN, &v) >= 0 && v && v[0]) {
            size_t n = strlen((char *)v), i;
            free(d->tags_icy);
            d->tags_icy = (char *)malloc(n + 2);
            if (d->tags_icy) {
                memcpy(d->tags_icy, v, n + 1);
                for (i = 0; i < n; i++) if (d->tags_icy[i] == '\n' || d->tags_icy[i] == '\r') d->tags_icy[i] = '\0';
                d->tags_icy[n + 1] = '\0';
            }
        }
        av_free(v);
        return d->tags_icy;
    }
    if (type == KA_TAG_OGG) {
        char *buf = NULL;
        size_t len = 0, cap = 0;
        const AVDictionaryEntry *e = NULL;
        unsigned i;
        char key[256], value[64];
        while ((e = av_dict_iterate(d->fmt->metadata, e)) != NULL) {
            snprintf(key, sizeof key, "%s", e->key); upper(key);
            append_tag(&buf, &len, &cap, key, e->value);
        }
        e = NULL;
        while ((e = av_dict_iterate(d->fmt->streams[d->stream]->metadata, e)) != NULL) {
            snprintf(key, sizeof key, "%s", e->key); upper(key);
            append_tag(&buf, &len, &cap, key, e->value);
        }
        for (i = 0; i < d->fmt->nb_chapters; i++) {
            AVChapter *c = d->fmt->chapters[i];
            double s = c->start * av_q2d(c->time_base);
            int h = (int)(s / 3600), m = (int)(s / 60) % 60;
            const AVDictionaryEntry *t = av_dict_get(c->metadata, "title", NULL, 0);
            snprintf(key, sizeof key, "CHAPTER%03u", i + 1);
            snprintf(value, sizeof value, "%02d:%02d:%06.3f", h, m, s - h * 3600 - m * 60);
            append_tag(&buf, &len, &cap, key, value);
            if (t) { snprintf(key, sizeof key, "CHAPTER%03uNAME", i + 1); append_tag(&buf, &len, &cap, key, t->value); }
        }
        if (!buf) return NULL;
        buf[len] = '\0';
        free(d->tags_ogg);
        d->tags_ogg = buf;
        return d->tags_ogg;
    }
    return NULL;
}

static uint64_t dec_file_position(ka_channel *ch, uint32_t mode) {
    dec *d = (dec *)ch->impl;
    AVIOContext *pb = d->fmt ? d->fmt->pb : NULL;
    int64_t size;
    if (!pb) return (uint64_t)-1;
    switch (mode) {
    case KA_FILEPOS_CURRENT: return (uint64_t)avio_tell(pb);
    case KA_FILEPOS_DOWNLOAD: return (uint64_t)(pb->bytes_read > 0 ? pb->bytes_read : avio_tell(pb));
    case KA_FILEPOS_START: return 0;
    case KA_FILEPOS_CONNECTED: return d->is_url ? (d->abort ? 0 : 1) : (uint64_t)-1;
    case KA_FILEPOS_BUFFER: return (uint64_t)(pb->buf_end - pb->buf_ptr);
    case KA_FILEPOS_END: case KA_FILEPOS_SIZE:
        size = avio_size(pb);
        return size >= 0 ? (uint64_t)size : (uint64_t)-1;
    default: return (uint64_t)-1;
    }
}

static void dec_destroy(ka_channel *ch) {
    dec *d = (dec *)ch->impl;
    ch->impl = NULL;
    dec_free(d);
}

static const ka_source_ops dec_ops = { dec_read, dec_seek, dec_length, dec_destroy, dec_tags, dec_file_position };

static KAHANDLE finish_open(dec *d, const char *url, uint32_t flags) {
    ka_channel *ch;
    if (!dec_open(d, url)) { int e = KA_ErrorGetCode(); dec_free(d); ka_set_error(e); return 0; }
    ch = ka_channel_new(KA_KIND_STREAM, d->rate, d->chans, flags & ~(uint32_t)KA_UNICODE, &dec_ops, d);
    if (!ch) { dec_free(d); return 0; }
    d->skip_until = -1;
    if (d->fmt->bit_rate > 0) ch->attr_misc[KA_ATTRIB_BITRATE] = (float)(d->fmt->bit_rate / 1000);
    ka_channel_prebuffer(ch);
    ka_ok();
    return ch->handle;
}

uint32_t ka_decoder_open_file(const char *path, uint64_t offset, uint64_t length, uint32_t flags) {
    dec *d = (dec *)calloc(1, sizeof *d);
    (void)offset; (void)length;
    if (!d) return ka_set_error(KA_ERROR_MEM);
    d->filename = strdup(path);
    return finish_open(d, path, flags);
}

static int attach_memory(dec *d, const void *data, uint64_t length) {
    unsigned char *iobuf;
    d->mem = (mem_src *)calloc(1, sizeof *d->mem);
    if (!d->mem) return 0;
    d->mem->data = (uint8_t *)malloc(length ? length : 1);
    if (!d->mem->data) return 0;
    memcpy(d->mem->data, data, length);
    d->mem->size = (int64_t)length;
    iobuf = (unsigned char *)av_malloc(32768);
    if (!iobuf) return 0;
    d->mem_io = avio_alloc_context(iobuf, 32768, 0, d->mem, mem_read, NULL, mem_seek);
    return d->mem_io != NULL;
}

uint32_t ka_decoder_open_memory(const void *data, uint64_t length, uint32_t flags) {
    dec *d = (dec *)calloc(1, sizeof *d);
    if (!d) return ka_set_error(KA_ERROR_MEM);
    if (!attach_memory(d, data, length)) { dec_free(d); return ka_set_error(KA_ERROR_MEM); }
    return finish_open(d, NULL, flags);
}

uint32_t ka_decoder_open_url(const char *url, uint64_t offset, uint32_t flags) {
    dec *d = (dec *)calloc(1, sizeof *d);
    (void)offset;
    if (!d) return ka_set_error(KA_ERROR_MEM);
    d->is_url = 1;
    d->filename = strdup(url);
    return finish_open(d, url, flags);
}

/* Decodes a whole file (or memory block) for a sample. */
int ka_decoder_probe_sample(const char *path, const void *mem, uint64_t length, float **data, int64_t *frames, int *rate, int *chans) {
    dec *d = (dec *)calloc(1, sizeof *d);
    float *all = NULL;
    int64_t have = 0, cap = 0;
    ka_channel tmp;
    if (!d) return ka_set_error(KA_ERROR_MEM);
    if (mem) {
        if (!attach_memory(d, mem, length)) { dec_free(d); return ka_set_error(KA_ERROR_MEM); }
    }
    if (!dec_open(d, mem ? NULL : path)) { int e = KA_ErrorGetCode(); dec_free(d); return ka_set_error(e); }
    d->skip_until = -1;
    memset(&tmp, 0, sizeof tmp);
    tmp.impl = d;
    tmp.chans = d->chans;
    tmp.rate = d->rate;
    for (;;) {
        int ended = 0, n;
        if (have + 8192 > cap) {
            int64_t ncap = cap ? cap * 2 : 65536;
            float *p = (float *)realloc(all, (size_t)ncap * d->chans * sizeof(float));
            if (!p) { free(all); dec_free(d); return ka_set_error(KA_ERROR_MEM); }
            all = p;
            cap = ncap;
        }
        n = dec_read(&tmp, all + (size_t)have * d->chans, 8192, &ended);
        if (n > 0) have += n;
        if (ended || n <= 0) break;
    }
    *data = all;
    *frames = have;
    *rate = d->rate;
    *chans = d->chans;
    dec_free(d);
    if (have == 0) { free(all); *data = NULL; return ka_set_error(KA_ERROR_EMPTY); }
    return 1;
}
