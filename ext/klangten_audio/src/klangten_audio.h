/*
 * A part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).
 * Klangten is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free
 * Software Foundation, version 3. See the file "license" in the repository.
 *
 * klangten_audio - Klangten's own sound engine.
 *
 * Klangten's sound layer (src/eapi/audio/) was written against a channel
 * model: handles for streams, samples, recordings and effects, attributes,
 * byte positions, polling instead of callbacks. This library keeps that
 * model - the same calls, the same numbers - and implements it with
 * miniaudio (output, capture, mixing, resampling), FFmpeg (files, internet
 * streams, HLS, every codec Klangten plays), LAME (MP3 recordings) and
 * Klangten's own DSP (tempo, effects). Strings are UTF-8.
 *
 * Nothing in here ever calls back into the host: data goes in with
 * KA_StreamPutData / KA_Encode_Write and comes out with KA_ChannelGetData.
 */
#ifndef KLANGTEN_AUDIO_H
#define KLANGTEN_AUDIO_H

#include <stdint.h>

#ifdef _WIN32
#define KA_API __declspec(dllexport)
#else
#define KA_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t KAHANDLE;

/* errors (KA_ErrorGetCode) */
enum {
    KA_OK = 0, KA_ERROR_MEM = 1, KA_ERROR_FILEOPEN = 2, KA_ERROR_DRIVER = 3,
    KA_ERROR_HANDLE = 5, KA_ERROR_FORMAT = 6, KA_ERROR_POSITION = 7, KA_ERROR_INIT = 8,
    KA_ERROR_START = 9, KA_ERROR_SSL = 10, KA_ERROR_ALREADY = 14, KA_ERROR_NOCHAN = 18,
    KA_ERROR_ILLTYPE = 19, KA_ERROR_ILLPARAM = 20, KA_ERROR_DEVICE = 23, KA_ERROR_NOPLAY = 24,
    KA_ERROR_FREQ = 25, KA_ERROR_NOTFILE = 27, KA_ERROR_EMPTY = 31, KA_ERROR_NONET = 32,
    KA_ERROR_CREATE = 33, KA_ERROR_NOFX = 34, KA_ERROR_NOTAVAIL = 37, KA_ERROR_DECODE = 38,
    KA_ERROR_TIMEOUT = 40, KA_ERROR_FILEFORM = 41, KA_ERROR_CODEC = 44, KA_ERROR_ENDED = 45,
    KA_ERROR_PROTOCOL = 48, KA_ERROR_DENIED = 49, KA_ERROR_UNKNOWN = -1
};

/* flags */
#define KA_SAMPLE_8BITS      0x1
#define KA_SAMPLE_MONO       0x2
#define KA_SAMPLE_LOOP       0x4
#define KA_SAMPLE_FLOAT      0x100
#define KA_STREAM_PRESCAN    0x20000
#define KA_STREAM_AUTOFREE   0x40000
#define KA_STREAM_RESTRATE   0x80000
#define KA_STREAM_BLOCK      0x100000
#define KA_STREAM_DECODE     0x200000
#define KA_STREAM_STATUS     0x800000
#define KA_UNICODE           0x80000000u
#define KA_ENCODE_AUTOFREE   0x40000

#define KA_STREAMPROC_DUMMY  0
#define KA_STREAMPROC_PUSH   (-1)
#define KA_STREAMPROC_END    0x80000000u

/* KA_ChannelIsActive */
#define KA_ACTIVE_STOPPED 0
#define KA_ACTIVE_PLAYING 1
#define KA_ACTIVE_STALLED 2
#define KA_ACTIVE_PAUSED  3

/* attributes */
#define KA_ATTRIB_FREQ        1
#define KA_ATTRIB_VOL         2
#define KA_ATTRIB_PAN         3
#define KA_ATTRIB_CPU         7
#define KA_ATTRIB_SRC         8
#define KA_ATTRIB_NET_RESUME  9
#define KA_ATTRIB_NORAMP      11
#define KA_ATTRIB_BITRATE     12
#define KA_ATTRIB_BUFFER      13
#define KA_ATTRIB_GRANULE     14
#define KA_ATTRIB_TAIL        16
#define KA_ATTRIB_VOLDSP      19
#define KA_ATTRIB_VOLDSP_PRIORITY 20
#define KA_ATTRIB_TEMPO       0x10000
#define KA_ATTRIB_TEMPO_PITCH 0x10001
#define KA_ATTRIB_TEMPO_FREQ  0x10002
#define KA_SLIDE_LOG          0x1000000

/* positions */
#define KA_POS_BYTE 0

/* KA_ChannelGetData length flags */
#define KA_DATA_AVAILABLE 0
#define KA_DATA_FLOAT     0x40000000

/* KA_StreamGetFilePosition */
#define KA_FILEPOS_CURRENT   0
#define KA_FILEPOS_DOWNLOAD  1
#define KA_FILEPOS_END       2
#define KA_FILEPOS_START     3
#define KA_FILEPOS_CONNECTED 4
#define KA_FILEPOS_BUFFER    5
#define KA_FILEPOS_SIZE      8
#define KA_FILEPOS_BUFFERING 9

/* KA_ChannelGetTags */
#define KA_TAG_ID3V2 1
#define KA_TAG_OGG   2
#define KA_TAG_HTTP  3
#define KA_TAG_ICY   4
#define KA_TAG_META  5

/* effects (the parameter blocks are documented in ka_fx.c) */
#define KA_FX_ROTATE      0x10000
#define KA_FX_PEAKEQ      0x10004
#define KA_FX_DAMP        0x10008
#define KA_FX_AUTOWAH     0x10009
#define KA_FX_PHASER      0x1000b
#define KA_FX_CHORUS      0x1000d
#define KA_FX_DISTORTION  0x10010
#define KA_FX_COMPRESSOR  0x10011
#define KA_FX_BIQUAD      0x10013
#define KA_FX_ECHO        0x10014
#define KA_FX_FREEVERB    0x10016

/* configuration */
#define KA_CONFIG_BUFFER       0
#define KA_CONFIG_UPDATEPERIOD 1
#define KA_CONFIG_NET_TIMEOUT  11
#define KA_CONFIG_NET_BUFFER   12
#define KA_CONFIG_NET_PREBUF   15
#define KA_CONFIG_NET_AGENT    16
#define KA_CONFIG_NET_PROXY    17
#define KA_CONFIG_NET_READTIMEOUT 37
/* Klangten: PEM file with the trusted CAs for https where TLS is OpenSSL
 * (Linux, Android); elsewhere the system's store is used. */
#define KA_CONFIG_CA_FILE 50

typedef struct KA_DEVICEINFO {
    const char *name;
    const char *driver;
    uint32_t flags;          /* 1 enabled, 2 default, 4 initialized */
} KA_DEVICEINFO;

#define KA_DEVICE_ENABLED 1
#define KA_DEVICE_DEFAULT 2
#define KA_DEVICE_INIT    4

typedef struct KA_INFO {
    uint32_t flags, hwsize, hwfree, freesam, free3d, minrate, maxrate, eax, minbuf, dsver, latency, initflags, speakers, freq;
} KA_INFO;

typedef struct KA_CHANNELINFO {
    uint32_t freq, chans, flags, ctype, origres;
    uint32_t plugin, sample;
    const char *filename;
} KA_CHANNELINFO;

/* engine */
KA_API uint32_t KA_GetVersion(void);
KA_API int KA_ErrorGetCode(void);
KA_API int KA_Init(int device, uint32_t freq, uint32_t flags, void *win, void *clsid);
KA_API int KA_Free(void);
KA_API int KA_GetInfo(KA_INFO *info);
KA_API int KA_GetDevice(void);
KA_API int KA_SetDevice(int device);
KA_API int KA_GetDeviceInfo(int device, KA_DEVICEINFO *info);
KA_API int KA_SetConfig(int option, uint32_t value);
KA_API uint32_t KA_GetConfig(int option);
KA_API int KA_SetConfigPtr(int option, const void *value);
KA_API int KA_SetVolume(float volume);
KA_API float KA_GetVolume(void);
KA_API int KA_Start(void);
KA_API int KA_Stop(void);
KA_API int KA_Pause(void);
KA_API uint32_t KA_PluginLoad(const char *file, uint32_t flags);

/* streams */
KA_API KAHANDLE KA_StreamCreate(uint32_t freq, uint32_t chans, uint32_t flags, intptr_t proc, void *user);
KA_API KAHANDLE KA_StreamCreateFile(int mem, const void *file, uint64_t offset, uint64_t length, uint32_t flags);
KA_API KAHANDLE KA_StreamCreateURL(const char *url, uint32_t offset, uint32_t flags, void *proc, void *user);
KA_API int KA_StreamFree(KAHANDLE handle);
KA_API int KA_StreamPutData(KAHANDLE handle, const void *buffer, uint32_t length);
KA_API uint64_t KA_StreamGetFilePosition(KAHANDLE handle, uint32_t mode);

/* samples */
KA_API KAHANDLE KA_SampleLoad(int mem, const void *file, uint64_t offset, uint32_t length, uint32_t max, uint32_t flags);
KA_API KAHANDLE KA_SampleCreate(uint32_t length, uint32_t freq, uint32_t chans, uint32_t max, uint32_t flags);
KA_API int KA_SampleFree(KAHANDLE handle);
KA_API KAHANDLE KA_SampleGetChannel(KAHANDLE handle, int flags);
KA_API int KA_SampleStop(KAHANDLE handle);

/* channels */
KA_API int KA_ChannelPlay(KAHANDLE handle, int restart);
KA_API int KA_ChannelStop(KAHANDLE handle);
KA_API int KA_ChannelPause(KAHANDLE handle);
KA_API uint32_t KA_ChannelIsActive(KAHANDLE handle);
KA_API uint32_t KA_ChannelFlags(KAHANDLE handle, uint32_t flags, uint32_t mask);
KA_API int KA_ChannelSetDevice(KAHANDLE handle, int device);
KA_API int KA_ChannelGetDevice(KAHANDLE handle);
KA_API int KA_ChannelGetData(KAHANDLE handle, void *buffer, uint32_t length);
KA_API uint64_t KA_ChannelGetLength(KAHANDLE handle, uint32_t mode);
KA_API uint64_t KA_ChannelGetPosition(KAHANDLE handle, uint32_t mode);
KA_API int KA_ChannelSetPosition(KAHANDLE handle, uint64_t pos, uint32_t mode);
KA_API double KA_ChannelBytes2Seconds(KAHANDLE handle, uint64_t pos);
KA_API uint64_t KA_ChannelSeconds2Bytes(KAHANDLE handle, double seconds);
KA_API int KA_ChannelGetInfo(KAHANDLE handle, KA_CHANNELINFO *info);
KA_API const char *KA_ChannelGetTags(KAHANDLE handle, uint32_t tags);
KA_API int KA_ChannelGetAttribute(KAHANDLE handle, uint32_t attrib, float *value);
KA_API int KA_ChannelSetAttribute(KAHANDLE handle, uint32_t attrib, float value);
KA_API int KA_ChannelSlideAttribute(KAHANDLE handle, uint32_t attrib, float value, uint32_t time_ms);
KA_API int KA_ChannelIsSliding(KAHANDLE handle, uint32_t attrib);
KA_API int KA_ChannelSet3DPosition(KAHANDLE handle, const void *pos, const void *orient, const void *vel);
KA_API int KA_Apply3D(void);

/* effects */
KA_API uint32_t KA_ChannelSetFX(KAHANDLE handle, uint32_t type, int priority);
KA_API int KA_ChannelRemoveFX(KAHANDLE handle, uint32_t fx);
KA_API int KA_FXSetParameters(uint32_t fx, const void *params);
KA_API int KA_FXGetParameters(uint32_t fx, void *params);
KA_API int KA_FXReset(uint32_t fx);
KA_API int KA_FXSetBypass(uint32_t fx, int bypass);
KA_API int KA_FXSetPriority(uint32_t fx, int priority);
KA_API int KA_FXFree(uint32_t fx);
KA_API uint32_t KA_FX_GetVersion(void);
KA_API KAHANDLE KA_FX_TempoCreate(KAHANDLE source, uint32_t flags);

/* format converter (a mixer stream with one input) */
KA_API KAHANDLE KA_Mixer_StreamCreate(uint32_t freq, uint32_t chans, uint32_t flags);
KA_API int KA_Mixer_StreamAddChannel(KAHANDLE mixer, KAHANDLE channel, uint32_t flags);
KA_API int KA_Mixer_ChannelRemove(KAHANDLE channel);
KA_API uint32_t KA_Mixer_ChannelFlags(KAHANDLE channel, uint32_t flags, uint32_t mask);
KA_API int KA_Mixer_ChannelGetData(KAHANDLE channel, void *buffer, uint32_t length);
KA_API KAHANDLE KA_Split_StreamCreate(KAHANDLE channel, uint32_t flags, const int *chanmap);

/* recording */
KA_API int KA_RecordInit(int device);
KA_API int KA_RecordFree(void);
KA_API int KA_RecordGetDevice(void);
KA_API int KA_RecordSetDevice(int device);
KA_API int KA_RecordGetDeviceInfo(int device, KA_DEVICEINFO *info);
KA_API uint32_t KA_RecordGetInput(int input, float *volume);
KA_API int KA_RecordSetInput(int input, uint32_t flags, float volume);
KA_API KAHANDLE KA_RecordStart(uint32_t freq, uint32_t chans, uint32_t flags, void *proc, void *user);

/* MP3 encoding (LAME) */
KA_API uint32_t KA_Encode_MP3_StartFile(KAHANDLE handle, const char *options, uint32_t flags, const char *file);
KA_API int KA_Encode_Write(uint32_t encoder, const void *buffer, uint32_t length);
KA_API int KA_Encode_Stop(uint32_t encoder);
KA_API uint32_t KA_Encode_Start(KAHANDLE handle, const char *cmdline, uint32_t flags, void *proc, void *user);
KA_API int KA_Encode_CastInit(uint32_t encoder, const char *server, const char *pass, const char *content, const char *name, const char *url, const char *genre, const char *desc, const char *headers, uint32_t bitrate, uint32_t flags);

#ifdef __cplusplus
}
#endif
#endif
