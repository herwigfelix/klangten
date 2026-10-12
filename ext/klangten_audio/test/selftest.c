/*
 * A part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).
 * GNU General Public License, version 3.
 *
 * Self test of klangten_audio. Runs ONLY on the null device: it sets
 * KLANGTEN_AUDIO_NULL=1 before anything else, so the library never talks to
 * the system's sound service. Build and run:
 *   sh ext/klangten_audio/test/run-selftest.sh
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#ifdef _WIN32
#include <windows.h>
#define sleep_ms(ms) Sleep(ms)
#else
#include <unistd.h>
#define sleep_ms(ms) usleep((ms) * 1000)
#endif
#include "klangten_audio.h"

static int failures, checks;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf(" (error %d)\n", KA_ErrorGetCode()); } } while (0)

/* a WAV file in memory: seconds of 440 Hz, 16 bit stereo */
static unsigned char *make_wav(int rate, double seconds, size_t *size_out) {
    int frames = (int)(rate * seconds), i;
    size_t data = (size_t)frames * 4, size = 44 + data;
    unsigned char *w = (unsigned char *)malloc(size);
    int16_t *s = (int16_t *)(w + 44);
    memcpy(w, "RIFF", 4); *(uint32_t *)(w + 4) = (uint32_t)(size - 8); memcpy(w + 8, "WAVEfmt ", 8);
    *(uint32_t *)(w + 16) = 16; *(uint16_t *)(w + 20) = 1; *(uint16_t *)(w + 22) = 2;
    *(uint32_t *)(w + 24) = (uint32_t)rate; *(uint32_t *)(w + 28) = (uint32_t)rate * 4; *(uint16_t *)(w + 32) = 4; *(uint16_t *)(w + 34) = 16;
    memcpy(w + 36, "data", 4); *(uint32_t *)(w + 40) = (uint32_t)data;
    for (i = 0; i < frames; i++) { int16_t v = (int16_t)(sin(2 * 3.14159265 * 440 * i / rate) * 16000); s[2 * i] = v; s[2 * i + 1] = v; }
    *size_out = size;
    return w;
}

static int64_t read_all(KAHANDLE h, int chans, float *peak) {
    float buf[4096];
    int64_t frames = 0;
    *peak = 0;
    for (;;) {
        int n = KA_ChannelGetData(h, buf, sizeof buf | KA_DATA_FLOAT), i;
        if (n <= 0) break;
        for (i = 0; i < n / 4; i++) if (fabsf(buf[i]) > *peak) *peak = fabsf(buf[i]);
        frames += n / 4 / chans;
    }
    return frames;
}

int main(int argc, char **argv) {
    size_t wav_size;
    unsigned char *wav = make_wav(44100, 1.0, &wav_size);
    KA_DEVICEINFO di;
    KA_CHANNELINFO ci;
    KAHANDLE h, t, m, push, smp, sch, dummy;
    uint32_t enc;
    float peak, v;
    int64_t frames;
    char mp3_path[512];
    const char *tags;
    const char *url = argc > 1 ? argv[1] : NULL;

#ifdef _WIN32
    _putenv("KLANGTEN_AUDIO_NULL=1");
    snprintf(mp3_path, sizeof mp3_path, "%s\\ka_selftest.mp3", getenv("TEMP") ? getenv("TEMP") : ".");
#else
    setenv("KLANGTEN_AUDIO_NULL", "1", 1);
    snprintf(mp3_path, sizeof mp3_path, "%s/ka_selftest.mp3", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
#endif

    /* 1. the null device */
    CHECK(KA_Init(0, 48000, 0, NULL, NULL), "init null device");
    CHECK(KA_GetDeviceInfo(0, &di) && strcmp(di.name, "No sound") == 0, "device 0 is No sound");
    CHECK(KA_GetDevice() == 0, "current device 0");

    /* 2. decode a WAV from memory */
    h = KA_StreamCreateFile(1, wav, 0, wav_size, KA_STREAM_DECODE | KA_SAMPLE_FLOAT);
    CHECK(h != 0, "open wav from memory");
    CHECK(KA_ChannelGetInfo(h, &ci) && ci.freq == 44100 && ci.chans == 2, "wav info %u/%u", ci.freq, ci.chans);
    CHECK(KA_ChannelGetLength(h, KA_POS_BYTE) == 44100ull * 2 * 4, "wav length %llu", (unsigned long long)KA_ChannelGetLength(h, KA_POS_BYTE));
    frames = read_all(h, 2, &peak);
    CHECK(frames == 44100, "decoded frames %lld", (long long)frames);
    CHECK(peak > 0.45f && peak < 0.52f, "peak %f", peak);
    CHECK(KA_ChannelIsActive(h) == KA_ACTIVE_STOPPED, "decode channel stopped at the end");
    CHECK(KA_ChannelSetPosition(h, KA_ChannelSeconds2Bytes(h, 0.5), KA_POS_BYTE), "seek 0.5 s");
    frames = read_all(h, 2, &peak);
    CHECK(frames == 22050, "frames after seek %lld", (long long)frames);

    /* 3. FX: an echo changes the sound */
    KA_ChannelSetPosition(h, 0, KA_POS_BYTE);
    {
        uint32_t fx = KA_ChannelSetFX(h, KA_FX_ECHO, 0);
        float params[6] = { 0.0f, 1.0f, 0.0f, 0.1f, 0, 0 };
        int32_t all = -1, stereo = 0;
        float buf[2000];
        memcpy(&params[4], &stereo, 4); memcpy(&params[5], &all, 4);
        CHECK(fx != 0, "set echo");
        CHECK(KA_FXSetParameters(fx, params), "echo parameters");
        KA_ChannelGetData(h, buf, sizeof buf | KA_DATA_FLOAT);
        CHECK(fabsf(buf[0]) < 1e-6f && fabsf(buf[1000]) < 1e-6f, "wet-only echo is silent before the delay");
        CHECK(KA_ChannelRemoveFX(h, fx), "remove echo");
    }
    KA_StreamFree(h);

    /* 4. MP3: encode 2 s, decode again, tags survive */
    dummy = KA_StreamCreate(44100, 2, KA_STREAM_DECODE, KA_STREAMPROC_DUMMY, NULL);
    CHECK(dummy != 0, "dummy stream");
    enc = KA_Encode_MP3_StartFile(dummy, "-b 128 --tt \"Klangten Test\" --ta \"Selbsttest\" --add-id3v2", 0, mp3_path);
    CHECK(enc != 0, "start mp3");
    {
        int16_t *pcm = (int16_t *)(wav + 44);
        int i;
        for (i = 0; i < 2; i++) CHECK(KA_Encode_Write(enc, pcm, (uint32_t)(wav_size - 44)), "write pcm");
    }
    CHECK(KA_Encode_Stop(enc), "stop mp3");
    KA_StreamFree(dummy);
    h = KA_StreamCreateFile(0, mp3_path, 0, 0, KA_STREAM_DECODE | KA_SAMPLE_FLOAT);
    CHECK(h != 0, "open mp3");
    tags = KA_ChannelGetTags(h, KA_TAG_OGG);
    {
        int found = 0;
        const char *p = tags;
        while (p && *p) { if (strcmp(p, "TITLE=Klangten Test") == 0) found = 1; p += strlen(p) + 1; }
        CHECK(found, "mp3 title tag");
    }
    {
        double len = KA_ChannelBytes2Seconds(h, KA_ChannelGetLength(h, KA_POS_BYTE));
        CHECK(len > 1.95 && len < 2.1, "mp3 length %f", len);
    }
    frames = read_all(h, 2, &peak);
    CHECK(frames > 44100 * 19 / 10 && frames < 44100 * 21 / 10, "mp3 frames %lld", (long long)frames);
    CHECK(peak > 0.4f && peak < 0.6f, "mp3 peak %f", peak);
    KA_StreamFree(h);

    /* 5. tempo +100 %: half the frames, same rate */
    h = KA_StreamCreateFile(1, wav, 0, wav_size, KA_STREAM_DECODE | KA_SAMPLE_FLOAT);
    t = KA_FX_TempoCreate(h, KA_STREAM_DECODE | KA_SAMPLE_FLOAT);
    CHECK(t != 0, "tempo stream");
    CHECK(KA_ChannelSetAttribute(t, KA_ATTRIB_TEMPO, 100.0f), "tempo +100");
    CHECK(KA_ChannelGetAttribute(t, KA_ATTRIB_TEMPO, &v) && v == 100.0f, "tempo read back");
    frames = read_all(t, 2, &peak);
    CHECK(frames > 21000 && frames < 23500, "tempo frames %lld", (long long)frames);
    CHECK(peak > 0.4f, "tempo peak %f", peak);
    KA_StreamFree(t);
    KA_StreamFree(h);

    /* 6. converter: 22050 Hz mono */
    h = KA_StreamCreateFile(1, wav, 0, wav_size, KA_STREAM_DECODE | KA_SAMPLE_FLOAT);
    m = KA_Mixer_StreamCreate(22050, 1, KA_STREAM_DECODE | KA_SAMPLE_FLOAT | 0x10000);
    CHECK(m != 0, "converter");
    CHECK(KA_Mixer_StreamAddChannel(m, h, 0), "converter input");
    frames = read_all(m, 1, &peak);
    CHECK(frames > 22000 && frames < 22100, "converter frames %lld", (long long)frames);
    KA_StreamFree(m);
    KA_StreamFree(h);

    /* 7. playback on the null device: a 1 s stream plays to the end */
    h = KA_StreamCreateFile(1, wav, 0, wav_size, 0);
    CHECK(h != 0, "playback stream");
    CHECK(KA_ChannelPlay(h, 0), "play");
    CHECK(KA_ChannelIsActive(h) == KA_ACTIVE_PLAYING, "playing");
    sleep_ms(400);
    CHECK(KA_ChannelGetPosition(h, KA_POS_BYTE) > 0, "position advances");
    CHECK(KA_ChannelPause(h) && KA_ChannelIsActive(h) == KA_ACTIVE_PAUSED, "pause");
    CHECK(KA_ChannelPlay(h, 0), "resume");
    sleep_ms(1200);
    CHECK(KA_ChannelIsActive(h) == KA_ACTIVE_STOPPED, "finished after 1 s (state %u)", KA_ChannelIsActive(h));
    CHECK(KA_ChannelBytes2Seconds(h, KA_ChannelGetPosition(h, KA_POS_BYTE)) > 0.95, "position at the end");
    KA_ChannelSlideAttribute(h, KA_ATTRIB_VOL, 0.0f, 100);
    CHECK(KA_ChannelIsSliding(h, KA_ATTRIB_VOL), "volume slides");
    KA_StreamFree(h);

    /* 8. push stream */
    push = KA_StreamCreate(44100, 2, 0, KA_STREAMPROC_PUSH, NULL);
    CHECK(push != 0, "push stream");
    CHECK(KA_StreamPutData(push, wav + 44, 44100) >= 0, "put data");
    CHECK(KA_ChannelPlay(push, 0), "play push");
    sleep_ms(400);
    CHECK(KA_StreamPutData(push, NULL, KA_STREAMPROC_END) >= 0, "end of push data");
    sleep_ms(300);
    CHECK(KA_ChannelIsActive(push) == KA_ACTIVE_STOPPED, "push stream drained (state %u)", KA_ChannelIsActive(push));
    KA_StreamFree(push);

    /* 9. sample */
    smp = KA_SampleLoad(1, wav, 0, (uint32_t)wav_size, 4, 0);
    CHECK(smp != 0, "sample");
    sch = KA_SampleGetChannel(smp, 0);
    CHECK(sch != 0 && KA_ChannelPlay(sch, 0), "play sample");
    sleep_ms(1200);
    CHECK(KA_ChannelIsActive(sch) == KA_ACTIVE_STOPPED, "sample finished");
    CHECK(KA_SampleFree(smp), "free sample");

    /* 10. recording on the null device gives silence */
    CHECK(KA_RecordInit(0), "record init");
    h = KA_RecordStart(48000, 1, 0, NULL, NULL);
    CHECK(h != 0, "record start");
    sleep_ms(300);
    {
        int16_t buf[48000];
        int n = KA_ChannelGetData(h, buf, sizeof buf);
        CHECK(n > 0, "recorded bytes %d", n);
    }
    KA_ChannelStop(h);
    KA_RecordFree();

    /* 11. optional: an internet stream (argument: URL) */
    if (url) {
        h = KA_StreamCreateURL(url, 0, KA_STREAM_DECODE | KA_SAMPLE_FLOAT, NULL, NULL);
        CHECK(h != 0, "open %s", url);
        if (h) {
            float buf[8192];
            int n = KA_ChannelGetData(h, buf, sizeof buf | KA_DATA_FLOAT);
            CHECK(n > 0, "data from the url");
            printf("url: %u Hz, %llu bytes downloaded, meta: %s\n", (KA_ChannelGetInfo(h, &ci), ci.freq),
                   (unsigned long long)KA_StreamGetFilePosition(h, KA_FILEPOS_DOWNLOAD),
                   KA_ChannelGetTags(h, KA_TAG_META) ? KA_ChannelGetTags(h, KA_TAG_META) : "-");
            KA_StreamFree(h);
        }
    }

    CHECK(KA_Free(), "free device");
    remove(mp3_path);
    free(wav);
    printf("%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
