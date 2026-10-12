/*
 * A part of Klangten. Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT).
 * Klangten is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free
 * Software Foundation, version 3. See the file "license" in the repository.
 *
 * ka_core.c - handles, errors, configuration, output devices, the mixer and
 * everything a channel does regardless of where its sound comes from.
 *
 * Devices: 0 is "No sound" (miniaudio's null backend: plays in real time,
 * reaches no sound card), 1 is the system default, 2.. are the playback
 * devices miniaudio enumerates. KLANGTEN_AUDIO_NULL=1 in the environment
 * turns EVERY device into the null device (tests: never a real sound card).
 */
#include "ka_internal.h"

#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdio.h>
#ifndef _WIN32
#include <time.h>
#include <unistd.h>
#endif

#define KA_VERSION 0x00010000u

/* ------------------------------------------------------------ portability */
#ifdef _WIN32
void kmutex_init(kmutex *m) { InitializeCriticalSection(m); }
void kmutex_free(kmutex *m) { DeleteCriticalSection(m); }
void kmutex_lock(kmutex *m) { EnterCriticalSection(m); }
int kmutex_trylock(kmutex *m) { return TryEnterCriticalSection(m) ? 1 : 0; }
void kmutex_unlock(kmutex *m) { LeaveCriticalSection(m); }
typedef struct { void *(*fn)(void *); void *arg; } kthread_start_args;
static DWORD WINAPI kthread_trampoline(LPVOID p) {
    kthread_start_args a = *(kthread_start_args *)p;
    free(p);
    a.fn(a.arg);
    return 0;
}
int kthread_start(kthread *t, void *(*fn)(void *), void *arg) {
    kthread_start_args *a = (kthread_start_args *)malloc(sizeof *a);
    if (!a) return 0;
    a->fn = fn; a->arg = arg;
    *t = CreateThread(NULL, 0, kthread_trampoline, a, 0, NULL);
    if (*t == NULL) { free(a); return 0; }
    return 1;
}
void kthread_join(kthread t) { WaitForSingleObject(t, INFINITE); CloseHandle(t); }
void kevent_init(kevent *e) { InitializeCriticalSection(&e->cs); InitializeConditionVariable(&e->cv); e->signaled = 0; }
void kevent_free(kevent *e) { DeleteCriticalSection(&e->cs); }
void kevent_signal(kevent *e) { EnterCriticalSection(&e->cs); e->signaled = 1; LeaveCriticalSection(&e->cs); WakeAllConditionVariable(&e->cv); }
void kevent_wait(kevent *e, int ms) {
    EnterCriticalSection(&e->cs);
    if (!e->signaled) SleepConditionVariableCS(&e->cv, &e->cs, (DWORD)ms);
    e->signaled = 0;
    LeaveCriticalSection(&e->cs);
}
void ksleep_ms(int ms) { Sleep((DWORD)ms); }
#if defined(_MSC_VER)
#define KA_TLS __declspec(thread)
#else
#define KA_TLS __thread
#endif
#else
void kmutex_init(kmutex *m) {
    pthread_mutexattr_t a;
    pthread_mutexattr_init(&a);
    pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(m, &a);
    pthread_mutexattr_destroy(&a);
}
void kmutex_free(kmutex *m) { pthread_mutex_destroy(m); }
void kmutex_lock(kmutex *m) { pthread_mutex_lock(m); }
int kmutex_trylock(kmutex *m) { return pthread_mutex_trylock(m) == 0; }
void kmutex_unlock(kmutex *m) { pthread_mutex_unlock(m); }
int kthread_start(kthread *t, void *(*fn)(void *), void *arg) { return pthread_create(t, NULL, fn, arg) == 0; }
void kthread_join(kthread t) { pthread_join(t, NULL); }
void kevent_init(kevent *e) { pthread_mutex_init(&e->m, NULL); pthread_cond_init(&e->c, NULL); e->signaled = 0; }
void kevent_free(kevent *e) { pthread_cond_destroy(&e->c); pthread_mutex_destroy(&e->m); }
void kevent_signal(kevent *e) { pthread_mutex_lock(&e->m); e->signaled = 1; pthread_cond_broadcast(&e->c); pthread_mutex_unlock(&e->m); }
void kevent_wait(kevent *e, int ms) {
    struct timespec ts;
    pthread_mutex_lock(&e->m);
    if (!e->signaled) {
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += ms / 1000;
        ts.tv_nsec += (long)(ms % 1000) * 1000000L;
        if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
        pthread_cond_timedwait(&e->c, &e->m, &ts);
    }
    e->signaled = 0;
    pthread_mutex_unlock(&e->m);
}
void ksleep_ms(int ms) { struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L }; nanosleep(&ts, NULL); }
#define KA_TLS __thread
#endif

double ka_clock(void) {
#ifdef _WIN32
    static LARGE_INTEGER freq;
    LARGE_INTEGER now;
    if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&now);
    return (double)now.QuadPart / (double)freq.QuadPart;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1e9;
#endif
}

/* ------------------------------------------------------------- errors */
static KA_TLS int g_error;

int ka_set_error(int code) { g_error = code; return 0; }
int ka_ok(void) { g_error = KA_OK; return 1; }
KA_API int KA_ErrorGetCode(void) { return g_error; }
KA_API uint32_t KA_GetVersion(void) { return KA_VERSION; }

/* ----------------------------------------------------------- handles */
typedef enum { H_FREE = 0, H_CHANNEL, H_SAMPLE, H_FX, H_ENCODER } h_type;
typedef struct { uint32_t handle; h_type type; void *ptr; int refs; } h_entry;

static kmutex g_table_lock;
static h_entry *g_table;
static size_t g_table_size;
static uint32_t g_next_handle = 0x10001;
static int g_started;
static kmutex g_mix_lock;   /* channel lists of the devices, channel state */

static void ka_global_init(void) {
    if (g_started) return;
    g_started = 1;
    kmutex_init(&g_table_lock);
    kmutex_init(&g_mix_lock);
}

uint32_t ka_new_handle(void) {
    uint32_t h;
    kmutex_lock(&g_table_lock);
    h = g_next_handle++;
    if (g_next_handle == 0) g_next_handle = 0x10001;
    kmutex_unlock(&g_table_lock);
    return h;
}

static int table_put(uint32_t handle, h_type type, void *ptr) {
    size_t i;
    kmutex_lock(&g_table_lock);
    for (i = 0; i < g_table_size; i++) if (g_table[i].type == H_FREE) break;
    if (i == g_table_size) {
        size_t n = g_table_size ? g_table_size * 2 : 64;
        h_entry *t = (h_entry *)realloc(g_table, n * sizeof *t);
        if (!t) { kmutex_unlock(&g_table_lock); return 0; }
        memset(t + g_table_size, 0, (n - g_table_size) * sizeof *t);
        g_table = t;
        g_table_size = n;
    }
    g_table[i].handle = handle;
    g_table[i].type = type;
    g_table[i].ptr = ptr;
    g_table[i].refs = 0;
    kmutex_unlock(&g_table_lock);
    return 1;
}

static void *table_find(uint32_t handle, h_type type) {
    size_t i;
    void *p = NULL;
    if (!g_started || handle == 0) return NULL;
    kmutex_lock(&g_table_lock);
    for (i = 0; i < g_table_size; i++)
        if (g_table[i].type == type && g_table[i].handle == handle) { p = g_table[i].ptr; break; }
    kmutex_unlock(&g_table_lock);
    return p;
}

static void table_remove(uint32_t handle) {
    size_t i;
    kmutex_lock(&g_table_lock);
    for (i = 0; i < g_table_size; i++)
        if (g_table[i].handle == handle && g_table[i].type != H_FREE) { g_table[i].type = H_FREE; g_table[i].ptr = NULL; break; }
    kmutex_unlock(&g_table_lock);
}

int ka_register_sample(ka_sample *s) { return table_put(s->handle, H_SAMPLE, s); }
ka_sample *ka_sample_get(uint32_t handle) { return (ka_sample *)table_find(handle, H_SAMPLE); }
void ka_unregister(uint32_t handle) { table_remove(handle); }
int ka_register_fx(ka_fx *fx) { return table_put(fx->handle, H_FX, fx); }
ka_fx *ka_fx_lookup(uint32_t handle) { return (ka_fx *)table_find(handle, H_FX); }
int ka_register_encoder(uint32_t handle, void *enc) { return table_put(handle, H_ENCODER, enc); }
void *ka_encoder_lookup(uint32_t handle) { return table_find(handle, H_ENCODER); }

ka_channel *ka_channel_get(uint32_t handle) {
    ka_channel *ch = (ka_channel *)table_find(handle, H_CHANNEL);
    if (!ch || ch->freeing) { ka_set_error(KA_ERROR_HANDLE); return NULL; }
    return ch;
}
void ka_channel_release(ka_channel *ch) { (void)ch; }

/* ------------------------------------------------------- configuration */
static uint32_t g_config[64];
static char *g_config_str[64];
static float g_master_volume = 1.0f;

const char *ka_config_string(int option) {
    if (option < 0 || option >= 64) return NULL;
    return g_config_str[option];
}
int ka_config_int(int option, int fallback) {
    if (option < 0 || option >= 64 || g_config[option] == 0) return fallback;
    return (int)g_config[option];
}
int ka_null_forced(void) {
    const char *v = getenv("KLANGTEN_AUDIO_NULL");
    return v != NULL && v[0] != '\0' && v[0] != '0';
}

KA_API int KA_SetConfig(int option, uint32_t value) {
    ka_global_init();
    if (option < 0 || option >= 64) return ka_set_error(KA_ERROR_ILLPARAM);
    g_config[option] = value;
    return ka_ok();
}
KA_API uint32_t KA_GetConfig(int option) {
    if (option < 0 || option >= 64) { ka_set_error(KA_ERROR_ILLPARAM); return (uint32_t)-1; }
    ka_ok();
    return g_config[option];
}
KA_API int KA_SetConfigPtr(int option, const void *value) {
    ka_global_init();
    if (option < 0 || option >= 64) return ka_set_error(KA_ERROR_ILLPARAM);
    free(g_config_str[option]);
    g_config_str[option] = NULL;
    if (value) {
        size_t n = strlen((const char *)value);
        g_config_str[option] = (char *)malloc(n + 1);
        if (g_config_str[option]) memcpy(g_config_str[option], value, n + 1);
    }
    return ka_ok();
}
KA_API uint32_t KA_PluginLoad(const char *file, uint32_t flags) {
    (void)file; (void)flags;
    /* Everything is built in (FFmpeg). Report success with a fake handle so
     * callers that load "plugins" in a loop stay quiet. */
    ka_ok();
    return 1;
}

/* ------------------------------------------------------------ devices */
typedef struct ka_device {
    int used;
    int index;
    int initialized;
    int is_null;
    ma_device device;
    int rate, chans;
    ka_channel **chans_list;
    int chans_count, chans_cap;
} ka_device;

static ma_context g_ctx;
static int g_ctx_ready;
static ma_context g_null_ctx;
static int g_null_ctx_ready;
static ma_device_info *g_play_infos;
static ma_uint32 g_play_count;
static ma_device_info *g_cap_infos;
static ma_uint32 g_cap_count;
static ka_device g_devices[KA_MAX_DEVICES];
static int g_current_device = -1;
static char g_device_names[KA_MAX_DEVICES][256];

static int ensure_contexts(void) {
    ka_global_init();
    if (!g_null_ctx_ready) {
        ma_backend nb[1] = { ma_backend_null };
        if (ma_context_init(nb, 1, NULL, &g_null_ctx) == MA_SUCCESS) g_null_ctx_ready = 1;
    }
    if (!g_ctx_ready && !ka_null_forced()) {
        ma_context_config cc = ma_context_config_init();
        /* iOS: plain playback. miniaudio's default would be playAndRecord,
         * which locks Bluetooth headsets into the hands-free profile; the
         * capture context switches to playAndRecord only while recording. */
        cc.coreaudio.sessionCategory = ma_ios_session_category_playback;
        cc.coreaudio.sessionCategoryOptions = 0;
        if (ma_context_init(NULL, 0, &cc, &g_ctx) == MA_SUCCESS) g_ctx_ready = 1;
    }
    return g_null_ctx_ready;
}

/* iOS: recording needs the playAndRecord category; it is set by a context
 * of its own and given back (playback) when the recording device is freed. */
#if defined(__APPLE__) && TARGET_OS_IPHONE
static ma_context g_rec_ctx;
static int g_rec_ctx_ready;
#endif
static ma_context *capture_context(void) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    if (!g_rec_ctx_ready) {
        ma_context_config cc = ma_context_config_init();
        cc.coreaudio.sessionCategory = ma_ios_session_category_play_and_record;
        cc.coreaudio.sessionCategoryOptions = ma_ios_session_category_option_allow_bluetooth | ma_ios_session_category_option_default_to_speaker;
        if (ma_context_init(NULL, 0, &cc, &g_rec_ctx) == MA_SUCCESS) g_rec_ctx_ready = 1;
    }
    return g_rec_ctx_ready ? &g_rec_ctx : &g_ctx;
#else
    return &g_ctx;
#endif
}
void ka_capture_release(void) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    if (g_rec_ctx_ready) {
        ma_context restore;
        ma_context_config cc = ma_context_config_init();
        ma_context_uninit(&g_rec_ctx);
        g_rec_ctx_ready = 0;
        cc.coreaudio.sessionCategory = ma_ios_session_category_playback;
        if (ma_context_init(NULL, 0, &cc, &restore) == MA_SUCCESS) ma_context_uninit(&restore);
    }
#endif
}

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

static void refresh_devices(void) {
    if (!g_ctx_ready) { g_play_count = 0; g_cap_count = 0; return; }
#if defined(__ANDROID__) || (defined(__APPLE__) && TARGET_OS_IPHONE)
    /* Phones: no device choice, and listing the inputs opens the microphone
     * (Android logs a refusal, iOS would ask for permission at start). */
    g_play_count = 0; g_cap_count = 0;
    return;
#endif
    if (ma_context_get_devices(&g_ctx, &g_play_infos, &g_play_count, &g_cap_infos, &g_cap_count) != MA_SUCCESS) {
        g_play_count = 0; g_cap_count = 0;
    }
}

ma_context *ka_capture_context(int device, ma_device_id **id_out, int *is_null) {
    ensure_contexts();
    refresh_devices();
    *id_out = NULL;
    *is_null = 0;
    if (ka_null_forced() || !g_ctx_ready || device == 0) { *is_null = 1; return &g_null_ctx; }
    if (device >= 2 && (ma_uint32)(device - 2) < g_cap_count) *id_out = &g_cap_infos[device - 2].id;
    return capture_context();
}

int ka_capture_device_info(int device, KA_DEVICEINFO *info) {
    static char names[KA_MAX_DEVICES][256];
    ensure_contexts();
    refresh_devices();
    if (device < 0 || device >= KA_MAX_DEVICES) return 0;
    if (device == 0) { info->name = "No sound"; info->driver = "null"; info->flags = KA_DEVICE_ENABLED; return 1; }
    if (device == 1) { info->name = "Default"; info->driver = "default"; info->flags = KA_DEVICE_ENABLED | KA_DEVICE_DEFAULT; return 1; }
    if ((ma_uint32)(device - 2) >= g_cap_count) return 0;
    snprintf(names[device], sizeof names[device], "%s", g_cap_infos[device - 2].name);
    info->name = names[device];
    info->driver = names[device];
    info->flags = KA_DEVICE_ENABLED | (g_cap_infos[device - 2].isDefault ? KA_DEVICE_DEFAULT : 0);
    return 1;
}

static void mix_channel(ka_channel *ch, float *out, ma_uint32 frames, int out_rate, int out_chans);
static void collect_finished(void);

static void device_callback(ma_device *d, void *output, const void *input, ma_uint32 frames) {
    ka_device *dev = (ka_device *)d->pUserData;
    float *out = (float *)output;
    int i;
    (void)input;
    memset(out, 0, (size_t)frames * dev->chans * sizeof(float));
    if (!kmutex_trylock(&g_mix_lock)) return;   /* never wait in the audio thread */
    for (i = 0; i < dev->chans_count; i++) {
        ka_channel *ch = dev->chans_list[i];
        if (ch->state == KA_ACTIVE_PLAYING && !ch->freeing) mix_channel(ch, out, frames, dev->rate, dev->chans);
    }
    kmutex_unlock(&g_mix_lock);
    if (g_master_volume != 1.0f) {
        size_t n = (size_t)frames * dev->chans, k;
        for (k = 0; k < n; k++) out[k] *= g_master_volume;
    }
    /* hard limit: never hand clipped garbage to the system */
    {
        size_t n = (size_t)frames * dev->chans, k;
        for (k = 0; k < n; k++) {
            if (out[k] > 1.0f) out[k] = 1.0f;
            else if (out[k] < -1.0f) out[k] = -1.0f;
        }
    }
}

static int device_add_channel(ka_device *dev, ka_channel *ch) {
    if (ch->in_mixer) return 1;
    if (dev->chans_count == dev->chans_cap) {
        int n = dev->chans_cap ? dev->chans_cap * 2 : 32;
        ka_channel **l = (ka_channel **)realloc(dev->chans_list, (size_t)n * sizeof *l);
        if (!l) return 0;
        dev->chans_list = l;
        dev->chans_cap = n;
    }
    dev->chans_list[dev->chans_count++] = ch;
    ch->in_mixer = 1;
    return 1;
}

static void device_remove_channel(ka_device *dev, ka_channel *ch) {
    int i;
    for (i = 0; i < dev->chans_count; i++) {
        if (dev->chans_list[i] == ch) {
            dev->chans_list[i] = dev->chans_list[--dev->chans_count];
            break;
        }
    }
    ch->in_mixer = 0;
}

static ka_device *device_get(int index) {
    if (index < 0 || index >= KA_MAX_DEVICES) return NULL;
    if (!g_devices[index].used || !g_devices[index].initialized) return NULL;
    return &g_devices[index];
}

KA_API int KA_Init(int device, uint32_t freq, uint32_t flags, void *win, void *clsid) {
    ka_device *dev;
    ma_device_config cfg;
    ma_context *ctx;
    ma_device_id *id = NULL;
    (void)flags; (void)win; (void)clsid;
    if (!ensure_contexts()) return ka_set_error(KA_ERROR_DRIVER);
    refresh_devices();
    if (device == -1) device = 1;
    if (device < 0 || device >= KA_MAX_DEVICES) return ka_set_error(KA_ERROR_DEVICE);
    if (device >= 2 && (ma_uint32)(device - 2) >= g_play_count && !ka_null_forced()) return ka_set_error(KA_ERROR_DEVICE);
    dev = &g_devices[device];
    if (dev->initialized) { g_current_device = device; return ka_set_error(KA_ERROR_ALREADY); }
    memset(dev, 0, sizeof *dev);
    dev->used = 1;
    dev->index = device;
    dev->is_null = (device == 0 || ka_null_forced() || !g_ctx_ready);
    ctx = dev->is_null ? &g_null_ctx : &g_ctx;
    if (!dev->is_null && device >= 2) id = &g_play_infos[device - 2].id;
    cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = 2;
    cfg.playback.pDeviceID = id;
    cfg.sampleRate = freq ? freq : 48000;
    cfg.dataCallback = device_callback;
    cfg.pUserData = dev;
    cfg.periodSizeInMilliseconds = 10;
    if (ma_device_init(ctx, &cfg, &dev->device) != MA_SUCCESS) {
        dev->used = 0;
        return ka_set_error(KA_ERROR_DRIVER);
    }
    dev->rate = (int)dev->device.sampleRate;
    dev->chans = (int)dev->device.playback.channels;
    if (ma_device_start(&dev->device) != MA_SUCCESS) {
        ma_device_uninit(&dev->device);
        dev->used = 0;
        return ka_set_error(KA_ERROR_START);
    }
    dev->initialized = 1;
    g_current_device = device;
    return ka_ok();
}

static void channel_free_internal(ka_channel *ch);

KA_API int KA_Free(void) {
    ka_device *dev = device_get(g_current_device);
    int i;
    if (!dev) return ka_set_error(KA_ERROR_INIT);
    ma_device_stop(&dev->device);
    /* free every channel that plays on this device */
    for (;;) {
        ka_channel *victim = NULL;
        kmutex_lock(&g_mix_lock);
        if (dev->chans_count > 0) victim = dev->chans_list[0];
        if (victim) device_remove_channel(dev, victim);
        kmutex_unlock(&g_mix_lock);
        if (!victim) break;
        channel_free_internal(victim);
    }
    ma_device_uninit(&dev->device);
    free(dev->chans_list);
    memset(dev, 0, sizeof *dev);
    for (i = 0; i < KA_MAX_DEVICES; i++) if (g_devices[i].initialized) { g_current_device = i; break; }
    if (i == KA_MAX_DEVICES) g_current_device = -1;
    return ka_ok();
}

KA_API int KA_GetDevice(void) {
    if (g_current_device < 0) { ka_set_error(KA_ERROR_INIT); return -1; }
    ka_ok();
    return g_current_device;
}

KA_API int KA_SetDevice(int device) {
    if (!device_get(device)) return ka_set_error(KA_ERROR_INIT);
    g_current_device = device;
    return ka_ok();
}

KA_API int KA_GetDeviceInfo(int device, KA_DEVICEINFO *info) {
    if (!info) return ka_set_error(KA_ERROR_ILLPARAM);
    ensure_contexts();
    refresh_devices();
    if (device < 0 || device >= KA_MAX_DEVICES) return ka_set_error(KA_ERROR_DEVICE);
    if (device == 0) {
        info->name = "No sound"; info->driver = "null";
        info->flags = KA_DEVICE_ENABLED | (g_devices[0].initialized ? KA_DEVICE_INIT : 0);
        return ka_ok();
    }
    if (device == 1) {
        info->name = "Default"; info->driver = "default";
        info->flags = KA_DEVICE_ENABLED | KA_DEVICE_DEFAULT | (g_devices[1].initialized ? KA_DEVICE_INIT : 0);
        return ka_ok();
    }
    if ((ma_uint32)(device - 2) >= g_play_count) return ka_set_error(KA_ERROR_DEVICE);
    snprintf(g_device_names[device], sizeof g_device_names[device], "%s", g_play_infos[device - 2].name);
    info->name = g_device_names[device];
    info->driver = g_device_names[device];
    info->flags = KA_DEVICE_ENABLED | (g_devices[device].initialized ? KA_DEVICE_INIT : 0);
    return ka_ok();
}

KA_API int KA_GetInfo(KA_INFO *info) {
    ka_device *dev = device_get(g_current_device);
    if (!dev) return ka_set_error(KA_ERROR_INIT);
    if (!info) return ka_set_error(KA_ERROR_ILLPARAM);
    memset(info, 0, sizeof *info);
    info->freq = (uint32_t)dev->rate;
    info->speakers = (uint32_t)dev->chans;
    info->minbuf = 10;
    info->latency = 20;
    info->minrate = 8000;
    info->maxrate = 192000;
    return ka_ok();
}

KA_API int KA_SetVolume(float volume) {
    if (volume < 0.0f || volume > 1.0f) return ka_set_error(KA_ERROR_ILLPARAM);
    g_master_volume = volume;
    return ka_ok();
}
KA_API float KA_GetVolume(void) { ka_ok(); return g_master_volume; }

KA_API int KA_Start(void) {
    ka_device *dev = device_get(g_current_device);
    if (!dev) return ka_set_error(KA_ERROR_INIT);
    return ma_device_start(&dev->device) == MA_SUCCESS ? ka_ok() : ka_set_error(KA_ERROR_START);
}
KA_API int KA_Stop(void) {
    ka_device *dev = device_get(g_current_device);
    if (!dev) return ka_set_error(KA_ERROR_INIT);
    ma_device_stop(&dev->device);
    return ka_ok();
}
KA_API int KA_Pause(void) { return KA_Stop(); }

/* ------------------------------------------------------- ring buffers */
int ka_rb_init(ka_channel *ch, int seconds_x10) {
    ma_uint32 frames = (ma_uint32)((int64_t)ch->rate * seconds_x10 / 10);
    if (frames < 4096) frames = 4096;
    if (ma_pcm_rb_init(ma_format_f32, (ma_uint32)ch->chans, frames, NULL, NULL, &ch->rb) != MA_SUCCESS) return 0;
    ch->rb_ready = 1;
    return 1;
}
int ka_rb_write(ka_channel *ch, const float *frames, int count) {
    int done = 0;
    while (done < count) {
        ma_uint32 n = (ma_uint32)(count - done);
        void *p;
        if (ma_pcm_rb_acquire_write(&ch->rb, &n, &p) != MA_SUCCESS || n == 0) break;
        memcpy(p, frames + (size_t)done * ch->chans, (size_t)n * ch->chans * sizeof(float));
        ma_pcm_rb_commit_write(&ch->rb, n);
        done += (int)n;
    }
    return done;
}
int ka_rb_read(ka_channel *ch, float *frames, int count) {
    int done = 0;
    while (done < count) {
        ma_uint32 n = (ma_uint32)(count - done);
        void *p;
        if (ma_pcm_rb_acquire_read(&ch->rb, &n, &p) != MA_SUCCESS || n == 0) break;
        memcpy(frames + (size_t)done * ch->chans, p, (size_t)n * ch->chans * sizeof(float));
        ma_pcm_rb_commit_read(&ch->rb, n);
        done += (int)n;
    }
    return done;
}
int ka_rb_available(ka_channel *ch) { return ch->rb_ready ? (int)ma_pcm_rb_available_read(&ch->rb) : 0; }
static int rb_space(ka_channel *ch) { return ch->rb_ready ? (int)ma_pcm_rb_available_write(&ch->rb) : 0; }
void ka_rb_clear(ka_channel *ch) { if (ch->rb_ready) ma_pcm_rb_reset(&ch->rb); }

/* ----------------------------------------------------------- channels */
ka_channel *ka_channel_new(ka_kind kind, int rate, int chans, uint32_t flags, const ka_source_ops *ops, void *impl) {
    ka_channel *ch;
    ka_global_init();
    if (rate <= 0 || chans <= 0 || chans > 8) { ka_set_error(KA_ERROR_FORMAT); return NULL; }
    ch = (ka_channel *)calloc(1, sizeof *ch);
    if (!ch) { ka_set_error(KA_ERROR_MEM); return NULL; }
    ch->handle = ka_new_handle();
    ch->kind = kind;
    ch->flags = flags;
    ch->rate = rate;
    ch->chans = chans;
    ch->ops = ops;
    ch->impl = impl;
    ch->volume = 1.0f;
    ch->state = KA_ACTIVE_STOPPED;
    ch->device = (flags & KA_STREAM_DECODE) ? -1 : g_current_device;
    kmutex_init(&ch->lock);
    kevent_init(&ch->feeder_wake);
    if (!table_put(ch->handle, H_CHANNEL, ch)) {
        kmutex_free(&ch->lock);
        kevent_free(&ch->feeder_wake);
        free(ch);
        ka_set_error(KA_ERROR_MEM);
        return NULL;
    }
    return ch;
}

static int bytes_per_sample(ka_channel *ch) {
    if (ch->flags & KA_SAMPLE_FLOAT) return 4;
    if (ch->flags & KA_SAMPLE_8BITS) return 1;
    return 2;
}
static int bytes_per_frame(ka_channel *ch) { return bytes_per_sample(ch) * ch->chans; }

static void apply_fx(ka_channel *ch, float *frames, int count) {
    int i;
    for (i = 0; i < ch->fx_count; i++)
        if (!ch->fx[i]->bypass) ka_fx_process(ch->fx[i], frames, count);
}

/* Reads float frames for the caller's own use (decode channels, inputs of
 * converters and tempo streams). Effects apply here as they do on playback. */
int ka_channel_read_float(ka_channel *ch, float *out, int frames, int *ended) {
    int got = 0, end = 0;
    kmutex_lock(&ch->lock);
    while (got < frames && !end) {
        int n = ch->ops->read(ch, out + (size_t)got * ch->chans, frames - got, &end);
        if (n <= 0 && !end) {
            /* a source with nothing at hand right now (push, record, network) */
            if (ch->kind == KA_KIND_PUSH || ch->kind == KA_KIND_RECORD) break;
            if (n == 0) break;
        }
        if (n > 0) got += n;
        if (end && (ch->flags & KA_SAMPLE_LOOP) && ch->ops->seek && ch->kind != KA_KIND_PUSH) {
            if (ch->ops->seek(ch, 0)) { end = 0; ch->loop_length = ch->position + got; }
        }
    }
    kmutex_unlock(&ch->lock);
    if (got > 0) apply_fx(ch, out, got);
    ch->position += got;
    if (end) ch->ended = 1;
    if (ended) *ended = end;
    return got;
}

/* --- feeder: decodes ahead for a playing stream, outside the audio thread */
static void *feeder_main(void *arg) {
    ka_channel *ch = (ka_channel *)arg;
    float *tmp = NULL;
    int chunk = ch->rate / 20;      /* 50 ms */
    if (chunk < 256) chunk = 256;
    tmp = (float *)malloc((size_t)chunk * ch->chans * sizeof(float));
    if (!tmp) return NULL;
    while (!ch->feeder_stop) {
        int end = 0, n;
        if (ch->seek_pending) {
            kmutex_lock(&ch->lock);
            if (ch->ops->seek) ch->ops->seek(ch, ch->seek_frame);
            ka_rb_clear(ch);
            ch->position = ch->seek_frame;
            ch->ended = 0;
            ch->seek_pending = 0;
            kmutex_unlock(&ch->lock);
        }
        if (ch->ended || rb_space(ch) < chunk) { kevent_wait(&ch->feeder_wake, 20); continue; }
        kmutex_lock(&ch->lock);
        if (ch->seek_pending) { kmutex_unlock(&ch->lock); continue; }
        n = ch->ops->read(ch, tmp, chunk, &end);
        if (end && (ch->flags & KA_SAMPLE_LOOP) && ch->ops->seek) {
            int64_t len = ch->ops->length ? ch->ops->length(ch) : -1;
            if (ch->ops->seek(ch, 0)) { end = 0; if (len > 0) ch->loop_length = len; }
        }
        kmutex_unlock(&ch->lock);
        if (n > 0) ka_rb_write(ch, tmp, n);
        if (end) ch->ended = 1;
        if (n <= 0 && !end) kevent_wait(&ch->feeder_wake, 10);
    }
    free(tmp);
    return NULL;
}

static int start_feeder(ka_channel *ch) {
    if (ch->feeder_running) return 1;
    if (ch->kind == KA_KIND_PUSH || ch->kind == KA_KIND_SAMPLE || ch->kind == KA_KIND_RECORD) return 1;
    if (!ch->rb_ready && !ka_rb_init(ch, ch->kind == KA_KIND_STREAM ? 30 : 10)) return 0;
    ch->feeder_stop = 0;
    if (!kthread_start(&ch->feeder, feeder_main, ch)) return 0;
    ch->feeder_running = 1;
    return 1;
}

static void stop_feeder(ka_channel *ch) {
    if (!ch->feeder_running) return;
    ch->feeder_stop = 1;
    kevent_signal(&ch->feeder_wake);
    kthread_join(ch->feeder);
    ch->feeder_running = 0;
}

/* Called by the decoder right after opening a playable stream: start
 * buffering at once, like BASS did, so playback starts without a gap. */
void ka_channel_prebuffer(ka_channel *ch) {
    if (!(ch->flags & KA_STREAM_DECODE)) start_feeder(ch);
}

/* ------------------------------------------------------------- slides */
static float slide_value(ka_slide *s, float current, double now, int *done) {
    double t;
    *done = 0;
    if (!s->active) return current;
    t = s->duration > 0 ? (now - s->start) / s->duration : 1.0;
    if (t >= 1.0) { s->active = 0; *done = 1; return s->to; }
    if (t < 0) t = 0;
    if (s->logarithmic && s->from > 0 && s->to > 0)
        return (float)(s->from * pow(s->to / s->from, t));
    return (float)(s->from + (s->to - s->from) * t);
}

static void update_slides(ka_channel *ch) {
    double now = ka_clock();
    int done;
    if (ch->slide_vol.active) {
        ch->volume = slide_value(&ch->slide_vol, ch->volume, now, &done);
        if (done && ch->slide_vol.to <= 0.0f && ch->attr_misc[0] < 0) {
            /* slide to -1: fade out, then stop */
            ch->volume = 0.0f;
            ch->state = KA_ACTIVE_STOPPED;
            ch->attr_misc[0] = 0;
        }
    }
    if (ch->slide_pan.active) ch->pan = slide_value(&ch->slide_pan, ch->pan, now, &done);
    if (ch->slide_freq.active) ch->freq = slide_value(&ch->slide_freq, ch->freq, now, &done);
}

/* -------------------------------------------------------------- mixer */
static int ensure_scratch(float **buf, size_t *have, size_t frames, int chans) {
    if (*have >= frames) return 1;
    free(*buf);
    *buf = (float *)malloc(frames * (size_t)chans * sizeof(float));
    if (!*buf) { *have = 0; return 0; }
    *have = frames;
    return 1;
}

static int pull_for_playback(ka_channel *ch, float *dst, int frames) {
    if (ch->kind == KA_KIND_SAMPLE) {
        int end = 0;
        return ka_sample_ops.read(ch, dst, frames, &end) + (end ? 0 : 0);
    }
    return ka_rb_read(ch, dst, frames);
}

static void mix_channel(ka_channel *ch, float *out, ma_uint32 frames, int out_rate, int out_chans) {
    ma_uint64 need = 0, in_count, out_count;
    int in_rate, got, k;
    float l_gain, r_gain;

    update_slides(ch);
    if (ch->state != KA_ACTIVE_PLAYING) return;
    in_rate = ch->freq > 0 ? (int)(ch->freq + 0.5f) : ch->rate;
    if (in_rate < 100) in_rate = 100;
    if (!ch->resampler_ready || ch->resampler_out_rate != out_rate) {
        ma_linear_resampler_config rc = ma_linear_resampler_config_init(ma_format_f32, (ma_uint32)ch->chans, (ma_uint32)in_rate, (ma_uint32)out_rate);
        if (ch->resampler_ready) ma_linear_resampler_uninit(&ch->resampler, NULL);
        if (ma_linear_resampler_init(&rc, NULL, &ch->resampler) != MA_SUCCESS) { ch->resampler_ready = 0; return; }
        ch->resampler_ready = 1;
        ch->resampler_in_rate = in_rate;
        ch->resampler_out_rate = out_rate;
    } else if (ch->resampler_in_rate != in_rate) {
        ma_linear_resampler_set_rate(&ch->resampler, (ma_uint32)in_rate, (ma_uint32)out_rate);
        ch->resampler_in_rate = in_rate;
    }
    if (ma_linear_resampler_get_required_input_frame_count(&ch->resampler, frames, &need) != MA_SUCCESS) return;
    if (!ensure_scratch(&ch->scratch, &ch->scratch_frames, (size_t)need + 16, ch->chans)) return;
    if (!ensure_scratch(&ch->scratch2, &ch->scratch2_frames, (size_t)frames + 16, ch->chans)) return;

    got = pull_for_playback(ch, ch->scratch, (int)need);
    if (got < (int)need) {
        int drained = (ch->kind == KA_KIND_SAMPLE) ? 1 : (ch->ended && ka_rb_available(ch) == 0);
        if (ch->kind == KA_KIND_PUSH) drained = ch->ended && ka_rb_available(ch) == 0;
        memset(ch->scratch + (size_t)got * ch->chans, 0, ((size_t)need - got) * ch->chans * sizeof(float));
        if (drained) {
            if (got == 0) { ch->state = KA_ACTIVE_STOPPED; return; }
        } else {
            ch->stalled = 1;
        }
    } else {
        ch->stalled = 0;
    }
    if (got > 0) {
        apply_fx(ch, ch->scratch, got);
        if (ch->encoder) ka_encoder_feed(ch, ch->scratch, got);
        ch->position += got;
    }

    in_count = need;
    out_count = frames;
    ma_linear_resampler_process_pcm_frames(&ch->resampler, ch->scratch, &in_count, ch->scratch2, &out_count);

    l_gain = ch->volume * (ch->pan > 0 ? 1.0f - ch->pan : 1.0f);
    r_gain = ch->volume * (ch->pan < 0 ? 1.0f + ch->pan : 1.0f);
    for (k = 0; k < (int)out_count; k++) {
        const float *src = ch->scratch2 + (size_t)k * ch->chans;
        float l, r;
        if (ch->chans == 1) { l = r = src[0]; }
        else if (ch->chans == 2) { l = src[0]; r = src[1]; }
        else { l = src[0]; r = src[1]; }
        if (out_chans == 1) out[k] += (l * l_gain + r * r_gain) * 0.5f;
        else { out[(size_t)k * out_chans] += l * l_gain; out[(size_t)k * out_chans + 1] += r * r_gain; }
    }
    if (got < (int)need && (ch->kind == KA_KIND_SAMPLE || (ch->ended && ka_rb_available(ch) == 0)))
        ch->state = KA_ACTIVE_STOPPED;
}

/* ------------------------------------------------------- channel calls */
static void channel_free_internal(ka_channel *ch) {
    int i;
    ka_device *dev;
    if (!ch) return;
    kmutex_lock(&g_mix_lock);
    ch->freeing = 1;
    ch->state = KA_ACTIVE_STOPPED;
    dev = (ch->device >= 0 && ch->device < KA_MAX_DEVICES && g_devices[ch->device].used) ? &g_devices[ch->device] : NULL;
    if (dev && ch->in_mixer) device_remove_channel(dev, ch);
    kmutex_unlock(&g_mix_lock);
    stop_feeder(ch);
    ka_encoder_close_for(ch);
    table_remove(ch->handle);
    for (i = 0; i < ch->fx_count; i++) { table_remove(ch->fx[i]->handle); ka_fx_destroy(ch->fx[i]); }
    if (ch->ops && ch->ops->destroy) ch->ops->destroy(ch);
    if (ch->rb_ready) ma_pcm_rb_uninit(&ch->rb);
    if (ch->resampler_ready) ma_linear_resampler_uninit(&ch->resampler, NULL);
    free(ch->scratch);
    free(ch->scratch2);
    kevent_free(&ch->feeder_wake);
    kmutex_free(&ch->lock);
    free(ch);
}

/* Channels with AUTOFREE that have finished are released here - never in
 * the audio thread. Runs at the start of the next call into the engine. */
static void collect_finished(void) {
    int d;
    for (;;) {
        ka_channel *victim = NULL;
        kmutex_lock(&g_mix_lock);
        for (d = 0; d < KA_MAX_DEVICES && !victim; d++) {
            ka_device *dev = &g_devices[d];
            int i;
            if (!dev->used) continue;
            for (i = 0; i < dev->chans_count; i++) {
                ka_channel *c = dev->chans_list[i];
                if ((c->flags & KA_STREAM_AUTOFREE) && c->state == KA_ACTIVE_STOPPED && c->attr_misc[31] > 0) { victim = c; break; }
            }
        }
        kmutex_unlock(&g_mix_lock);
        if (!victim) break;
        channel_free_internal(victim);
    }
}

void ka_free_channel(uint32_t handle) {
    ka_channel *ch = (ka_channel *)table_find(handle, H_CHANNEL);
    if (ch) channel_free_internal(ch);
}

KA_API int KA_StreamFree(KAHANDLE handle) {
    ka_channel *ch;
    collect_finished();
    ch = ka_channel_get(handle);
    if (!ch) return 0;
    if (ch->kind == KA_KIND_SAMPLE) return ka_set_error(KA_ERROR_NOTAVAIL);
    channel_free_internal(ch);
    return ka_ok();
}

void ka_free_sample_channel(ka_channel *ch) { channel_free_internal(ch); }

KA_API int KA_ChannelPlay(KAHANDLE handle, int restart) {
    ka_channel *ch;
    ka_device *dev;
    collect_finished();
    ch = ka_channel_get(handle);
    if (!ch) return 0;
    if (ch->flags & KA_STREAM_DECODE) return ka_set_error(KA_ERROR_DECODE);
    if (ch->kind == KA_KIND_RECORD) {
        ch->state = KA_ACTIVE_PLAYING;
        return ka_ok();
    }
    dev = device_get(ch->device);
    if (!dev) return ka_set_error(KA_ERROR_START);
    if (restart) {
        if (ch->kind == KA_KIND_SAMPLE) ch->sample_pos = 0;
        else if (ch->kind == KA_KIND_PUSH) { ka_rb_clear(ch); ch->ended = 0; }   /* restart drops queued data */
        else if (ch->ops->seek) { ch->seek_frame = 0; ch->seek_pending = 1; ka_rb_clear(ch); ch->ended = 0; }
        ch->position = 0;
    }
    if (ch->kind != KA_KIND_SAMPLE && ch->kind != KA_KIND_PUSH && !start_feeder(ch)) return ka_set_error(KA_ERROR_MEM);
    if (ch->kind == KA_KIND_PUSH && !ch->rb_ready && !ka_rb_init(ch, 50)) return ka_set_error(KA_ERROR_MEM);
    kmutex_lock(&g_mix_lock);
    if (!device_add_channel(dev, ch)) { kmutex_unlock(&g_mix_lock); return ka_set_error(KA_ERROR_MEM); }
    ch->state = KA_ACTIVE_PLAYING;
    ch->attr_misc[31] = 1;    /* has been started (AUTOFREE may collect it) */
    kmutex_unlock(&g_mix_lock);
    kevent_signal(&ch->feeder_wake);
    return ka_ok();
}

KA_API int KA_ChannelStop(KAHANDLE handle) {
    ka_channel *ch = ka_channel_get(handle);
    if (!ch) return 0;
    kmutex_lock(&g_mix_lock);
    ch->state = KA_ACTIVE_STOPPED;
    if (ch->kind == KA_KIND_PUSH) ka_rb_clear(ch);
    kmutex_unlock(&g_mix_lock);
    if (ch->kind == KA_KIND_RECORD) ka_record_ops.seek(ch, -1);  /* stops capturing */
    collect_finished();
    return ka_ok();
}

KA_API int KA_ChannelPause(KAHANDLE handle) {
    ka_channel *ch = ka_channel_get(handle);
    if (!ch) return 0;
    if (ch->flags & KA_STREAM_DECODE) return ka_set_error(KA_ERROR_DECODE);
    if (ch->state != KA_ACTIVE_PLAYING) return ka_set_error(KA_ERROR_NOPLAY);
    ch->state = KA_ACTIVE_PAUSED;
    return ka_ok();
}

KA_API uint32_t KA_ChannelIsActive(KAHANDLE handle) {
    ka_channel *ch = ka_channel_get(handle);
    if (!ch) return KA_ACTIVE_STOPPED;
    ka_ok();
    if (ch->flags & KA_STREAM_DECODE) {
        if (ch->kind == KA_KIND_PUSH) return (ch->ended && ka_rb_available(ch) == 0) ? KA_ACTIVE_STOPPED : KA_ACTIVE_PLAYING;
        return ch->ended ? KA_ACTIVE_STOPPED : KA_ACTIVE_PLAYING;
    }
    update_slides(ch);
    if (ch->state == KA_ACTIVE_PLAYING && ch->stalled) return KA_ACTIVE_STALLED;
    return (uint32_t)ch->state;
}

KA_API uint32_t KA_ChannelFlags(KAHANDLE handle, uint32_t flags, uint32_t mask) {
    ka_channel *ch = ka_channel_get(handle);
    uint32_t changeable = KA_SAMPLE_LOOP | KA_STREAM_AUTOFREE;
    if (!ch) return (uint32_t)-1;
    mask &= changeable;
    ch->flags = (ch->flags & ~mask) | (flags & mask);
    ka_ok();
    return ch->flags;
}

KA_API int KA_ChannelSetDevice(KAHANDLE handle, int device) {
    ka_channel *ch = ka_channel_get(handle);
    ka_device *old_dev, *new_dev;
    if (!ch) return 0;
    if (ch->flags & KA_STREAM_DECODE) return ka_set_error(KA_ERROR_DECODE);
    if (device == -1) device = 1;
    new_dev = device_get(device);
    if (!new_dev) return ka_set_error(KA_ERROR_INIT);
    kmutex_lock(&g_mix_lock);
    old_dev = device_get(ch->device);
    if (old_dev && ch->in_mixer) device_remove_channel(old_dev, ch);
    ch->device = device;
    if (ch->state == KA_ACTIVE_PLAYING || ch->state == KA_ACTIVE_PAUSED) device_add_channel(new_dev, ch);
    kmutex_unlock(&g_mix_lock);
    return ka_ok();
}

KA_API int KA_ChannelGetDevice(KAHANDLE handle) {
    ka_channel *ch = ka_channel_get(handle);
    if (!ch) return -1;
    ka_ok();
    return ch->device;
}

static void float_to_format(ka_channel *ch, const float *src, void *dst, size_t samples, int as_float) {
    size_t i;
    if (as_float) { memcpy(dst, src, samples * sizeof(float)); return; }
    if (ch->flags & KA_SAMPLE_8BITS) {
        uint8_t *d = (uint8_t *)dst;
        for (i = 0; i < samples; i++) {
            float v = src[i] * 127.0f + 128.0f;
            d[i] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
        }
    } else {
        int16_t *d = (int16_t *)dst;
        for (i = 0; i < samples; i++) {
            float v = src[i] * 32767.0f;
            d[i] = (int16_t)(v < -32768.0f ? -32768 : v > 32767.0f ? 32767 : (int)lrintf(v));
        }
    }
}

KA_API int KA_ChannelGetData(KAHANDLE handle, void *buffer, uint32_t length) {
    ka_channel *ch = ka_channel_get(handle);
    int as_float, sample_bytes, frames, got, ended = 0;
    float *tmp;
    if (!ch) return -1;
    if (length == KA_DATA_AVAILABLE) {
        ka_ok();
        /* a playing push stream has no playback buffer apart from its
         * queue, which KA_StreamPutData(h, NULL, 0) reports already */
        if (ch->kind == KA_KIND_RECORD || (ch->kind == KA_KIND_PUSH && (ch->flags & KA_STREAM_DECODE)))
            return ka_rb_available(ch) * bytes_per_frame(ch);
        return 0;
    }
    if (length & 0x80000000u) return ka_set_error(KA_ERROR_NOTAVAIL), -1;   /* FFT */
    if (!(ch->flags & KA_STREAM_DECODE) && ch->kind != KA_KIND_RECORD) return ka_set_error(KA_ERROR_NOTAVAIL), -1;
    as_float = (length & KA_DATA_FLOAT) || (ch->flags & KA_SAMPLE_FLOAT);
    length &= 0x0FFFFFFF;
    sample_bytes = as_float ? 4 : bytes_per_sample(ch);
    frames = (int)(length / (uint32_t)(sample_bytes * ch->chans));
    if (frames <= 0) return ka_set_error(KA_ERROR_ILLPARAM), -1;
    tmp = (float *)malloc((size_t)frames * ch->chans * sizeof(float));
    if (!tmp) return ka_set_error(KA_ERROR_MEM), -1;
    if (ch->kind == KA_KIND_RECORD) {
        got = ka_rb_read(ch, tmp, frames);
        ch->position += got;
    } else {
        got = ka_channel_read_float(ch, tmp, frames, &ended);
    }
    if (got <= 0) {
        free(tmp);
        if (ch->kind == KA_KIND_RECORD) { ka_ok(); return 0; }
        if (ended || ch->ended) return ka_set_error(KA_ERROR_ENDED), -1;
        if (ch->kind == KA_KIND_PUSH) { ka_ok(); return 0; }
        ka_ok();
        return 0;
    }
    float_to_format(ch, tmp, buffer, (size_t)got * ch->chans, as_float);
    free(tmp);
    ka_ok();
    return got * sample_bytes * ch->chans;
}

KA_API uint64_t KA_ChannelGetLength(KAHANDLE handle, uint32_t mode) {
    ka_channel *ch = ka_channel_get(handle);
    int64_t frames;
    if (!ch) return (uint64_t)-1;
    if (mode != KA_POS_BYTE) return ka_set_error(KA_ERROR_NOTAVAIL), (uint64_t)-1;
    if (ch->kind == KA_KIND_SAMPLE && ch->sample) frames = ch->sample->frames;
    else frames = ch->ops && ch->ops->length ? ch->ops->length(ch) : -1;
    if (frames < 0) return ka_set_error(KA_ERROR_NOTAVAIL), (uint64_t)-1;
    ka_ok();
    return (uint64_t)frames * (uint64_t)bytes_per_frame(ch);
}

KA_API uint64_t KA_ChannelGetPosition(KAHANDLE handle, uint32_t mode) {
    ka_channel *ch = ka_channel_get(handle);
    int64_t frames;
    if (!ch) return (uint64_t)-1;
    if (mode != KA_POS_BYTE) return ka_set_error(KA_ERROR_NOTAVAIL), (uint64_t)-1;
    if (ch->kind == KA_KIND_SAMPLE) frames = ch->sample_pos;
    else {
        frames = ch->position;
        if (ch->loop_length > 0 && frames >= ch->loop_length) frames %= ch->loop_length;
    }
    ka_ok();
    return (uint64_t)frames * (uint64_t)bytes_per_frame(ch);
}

KA_API int KA_ChannelSetPosition(KAHANDLE handle, uint64_t pos, uint32_t mode) {
    ka_channel *ch = ka_channel_get(handle);
    int64_t frame;
    if (!ch) return 0;
    if (mode != KA_POS_BYTE) return ka_set_error(KA_ERROR_NOTAVAIL);
    frame = (int64_t)(pos / (uint64_t)bytes_per_frame(ch));
    if (ch->kind == KA_KIND_SAMPLE) {
        if (ch->sample && frame > ch->sample->frames) return ka_set_error(KA_ERROR_POSITION);
        ch->sample_pos = frame;
        return ka_ok();
    }
    if (!ch->ops->seek) return ka_set_error(KA_ERROR_NOTAVAIL);
    if (ch->feeder_running) {
        ch->seek_frame = frame;
        ch->seek_pending = 1;
        ka_rb_clear(ch);
        ch->position = frame;
        ch->ended = 0;
        kevent_signal(&ch->feeder_wake);
        return ka_ok();
    }
    kmutex_lock(&ch->lock);
    if (!ch->ops->seek(ch, frame)) { kmutex_unlock(&ch->lock); return ka_set_error(KA_ERROR_POSITION); }
    ch->position = frame;
    ch->ended = 0;
    kmutex_unlock(&ch->lock);
    return ka_ok();
}

KA_API double KA_ChannelBytes2Seconds(KAHANDLE handle, uint64_t pos) {
    ka_channel *ch = ka_channel_get(handle);
    if (!ch) return -1.0;
    ka_ok();
    return (double)(pos / (uint64_t)bytes_per_frame(ch)) / (double)ch->rate;
}

KA_API uint64_t KA_ChannelSeconds2Bytes(KAHANDLE handle, double seconds) {
    ka_channel *ch = ka_channel_get(handle);
    if (!ch) return (uint64_t)-1;
    if (seconds < 0) seconds = 0;
    ka_ok();
    return (uint64_t)(seconds * ch->rate) * (uint64_t)bytes_per_frame(ch);
}

KA_API int KA_ChannelGetInfo(KAHANDLE handle, KA_CHANNELINFO *info) {
    ka_channel *ch = ka_channel_get(handle);
    if (!ch) return 0;
    if (!info) return ka_set_error(KA_ERROR_ILLPARAM);
    memset(info, 0, sizeof *info);
    info->freq = (uint32_t)ch->rate;
    info->chans = (uint32_t)ch->chans;
    info->flags = ch->flags;
    info->ctype = ch->kind == KA_KIND_SAMPLE ? 1 : 0x10000;
    info->origres = (ch->flags & KA_SAMPLE_FLOAT) ? 32 : 16;
    info->sample = ch->sample ? ch->sample->handle : 0;
    return ka_ok();
}

KA_API const char *KA_ChannelGetTags(KAHANDLE handle, uint32_t tags) {
    ka_channel *ch = ka_channel_get(handle);
    const char *t;
    if (!ch) return NULL;
    t = ch->ops && ch->ops->tags ? ch->ops->tags(ch, tags) : NULL;
    if (!t) { ka_set_error(KA_ERROR_NOTAVAIL); return NULL; }
    ka_ok();
    return t;
}

KA_API uint64_t KA_StreamGetFilePosition(KAHANDLE handle, uint32_t mode) {
    ka_channel *ch = ka_channel_get(handle);
    if (!ch) return (uint64_t)-1;
    if (!ch->ops || !ch->ops->file_position) return ka_set_error(KA_ERROR_NOTFILE), (uint64_t)-1;
    ka_ok();
    if (mode == KA_FILEPOS_BUFFERING) {
        /* percentage still to fill before the decoder has enough at hand */
        int have = ka_rb_available(ch), want = ch->rate / 2;
        if (!ch->rb_ready || have >= want) return 0;
        return (uint64_t)(100 - have * 100 / (want > 0 ? want : 1));
    }
    return ch->ops->file_position(ch, mode);
}

/* --------------------------------------------------------- attributes */
KA_API int KA_ChannelGetAttribute(KAHANDLE handle, uint32_t attrib, float *value) {
    ka_channel *ch = ka_channel_get(handle);
    if (!ch) return 0;
    if (!value) return ka_set_error(KA_ERROR_ILLPARAM);
    update_slides(ch);
    switch (attrib) {
    case KA_ATTRIB_FREQ: *value = ch->freq > 0 ? ch->freq : (float)ch->rate; break;
    case KA_ATTRIB_VOL: *value = ch->volume; break;
    case KA_ATTRIB_PAN: *value = ch->pan; break;
    case KA_ATTRIB_CPU: *value = 0.0f; break;
    case KA_ATTRIB_TEMPO: *value = ch->tempo; break;
    case KA_ATTRIB_TEMPO_PITCH: *value = ch->tempo_pitch; break;
    case KA_ATTRIB_TEMPO_FREQ: *value = ch->tempo_freq > 0 ? ch->tempo_freq : (float)ch->rate; break;
    default:
        if (attrib < 31) { *value = ch->attr_misc[attrib]; break; }
        return ka_set_error(KA_ERROR_ILLTYPE);
    }
    return ka_ok();
}

KA_API int KA_ChannelSetAttribute(KAHANDLE handle, uint32_t attrib, float value) {
    ka_channel *ch = ka_channel_get(handle);
    if (!ch) return 0;
    switch (attrib) {
    case KA_ATTRIB_FREQ:
        if (value != 0 && (value < 100 || value > 384000)) return ka_set_error(KA_ERROR_ILLPARAM);
        ch->slide_freq.active = 0;
        ch->freq = value;
        break;
    case KA_ATTRIB_VOL:
        if (value < 0) return ka_set_error(KA_ERROR_ILLPARAM);
        ch->slide_vol.active = 0;
        ch->volume = value;
        break;
    case KA_ATTRIB_PAN:
        if (value < -1.0f || value > 1.0f) return ka_set_error(KA_ERROR_ILLPARAM);
        ch->slide_pan.active = 0;
        ch->pan = value;
        break;
    case KA_ATTRIB_TEMPO: case KA_ATTRIB_TEMPO_PITCH: case KA_ATTRIB_TEMPO_FREQ:
        if (ch->kind != KA_KIND_TEMPO) return ka_set_error(KA_ERROR_ILLTYPE);
        return ka_tempo_set(ch, attrib, value) ? ka_ok() : ka_set_error(KA_ERROR_ILLPARAM);
    default:
        if (attrib < 31) { ch->attr_misc[attrib] = value; break; }
        return ka_set_error(KA_ERROR_ILLTYPE);
    }
    return ka_ok();
}

KA_API int KA_ChannelSlideAttribute(KAHANDLE handle, uint32_t attrib, float value, uint32_t time_ms) {
    ka_channel *ch = ka_channel_get(handle);
    ka_slide *s;
    float current;
    int logarithmic = (attrib & KA_SLIDE_LOG) != 0;
    if (!ch) return 0;
    attrib &= ~(uint32_t)KA_SLIDE_LOG;
    switch (attrib) {
    case KA_ATTRIB_VOL: s = &ch->slide_vol; current = ch->volume; break;
    case KA_ATTRIB_PAN: s = &ch->slide_pan; current = ch->pan; break;
    case KA_ATTRIB_FREQ: s = &ch->slide_freq; current = ch->freq > 0 ? ch->freq : (float)ch->rate; break;
    default: return ka_set_error(KA_ERROR_ILLTYPE);
    }
    if (attrib == KA_ATTRIB_VOL && value < 0) { ch->attr_misc[0] = -1; value = 0; }
    s->from = current;
    s->to = value;
    s->start = ka_clock();
    s->duration = time_ms / 1000.0;
    s->logarithmic = logarithmic;
    s->active = 1;
    if (time_ms == 0) update_slides(ch);
    return ka_ok();
}

KA_API int KA_ChannelIsSliding(KAHANDLE handle, uint32_t attrib) {
    ka_channel *ch = ka_channel_get(handle);
    if (!ch) return 0;
    update_slides(ch);
    ka_ok();
    switch (attrib) {
    case 0: return ch->slide_vol.active || ch->slide_pan.active || ch->slide_freq.active;
    case KA_ATTRIB_VOL: return ch->slide_vol.active;
    case KA_ATTRIB_PAN: return ch->slide_pan.active;
    case KA_ATTRIB_FREQ: return ch->slide_freq.active;
    default: return 0;
    }
}

KA_API int KA_ChannelSet3DPosition(KAHANDLE handle, const void *pos, const void *orient, const void *vel) {
    (void)handle; (void)pos; (void)orient; (void)vel;
    return ka_set_error(KA_ERROR_NOTAVAIL);
}
KA_API int KA_Apply3D(void) { return ka_set_error(KA_ERROR_NOTAVAIL); }

/* ------------------------------------------------------------ effects */
static int fx_compare(const void *a, const void *b) {
    const ka_fx *x = *(const ka_fx *const *)a, *y = *(const ka_fx *const *)b;
    return y->priority - x->priority;
}

KA_API uint32_t KA_ChannelSetFX(KAHANDLE handle, uint32_t type, int priority) {
    ka_channel *ch = ka_channel_get(handle);
    ka_fx *fx;
    if (!ch) return 0;
    if (ch->fx_count >= KA_MAX_FX) return ka_set_error(KA_ERROR_NOFX);
    fx = ka_fx_create(type, ch->rate, ch->chans);
    if (!fx) return ka_set_error(KA_ERROR_ILLTYPE);
    fx->handle = ka_new_handle();
    fx->priority = priority;
    fx->channel = handle;
    if (!ka_register_fx(fx)) { ka_fx_destroy(fx); return ka_set_error(KA_ERROR_MEM); }
    kmutex_lock(&g_mix_lock);
    ch->fx[ch->fx_count++] = fx;
    qsort(ch->fx, (size_t)ch->fx_count, sizeof ch->fx[0], fx_compare);
    kmutex_unlock(&g_mix_lock);
    ka_ok();
    return fx->handle;
}

static int detach_fx(ka_fx *fx) {
    ka_channel *ch = (ka_channel *)table_find(fx->channel, H_CHANNEL);
    int i;
    if (!ch) return 0;
    kmutex_lock(&g_mix_lock);
    for (i = 0; i < ch->fx_count; i++) {
        if (ch->fx[i] == fx) {
            memmove(&ch->fx[i], &ch->fx[i + 1], (size_t)(ch->fx_count - i - 1) * sizeof ch->fx[0]);
            ch->fx_count--;
            break;
        }
    }
    kmutex_unlock(&g_mix_lock);
    return 1;
}

KA_API int KA_ChannelRemoveFX(KAHANDLE handle, uint32_t fxh) {
    ka_fx *fx = ka_fx_lookup(fxh);
    (void)handle;
    if (!fx) return ka_set_error(KA_ERROR_HANDLE);
    detach_fx(fx);
    table_remove(fxh);
    ka_fx_destroy(fx);
    return ka_ok();
}
KA_API int KA_FXFree(uint32_t fx) { return KA_ChannelRemoveFX(0, fx); }

KA_API int KA_FXSetParameters(uint32_t fxh, const void *params) {
    ka_fx *fx = ka_fx_lookup(fxh);
    int r;
    if (!fx) return ka_set_error(KA_ERROR_HANDLE);
    kmutex_lock(&g_mix_lock);
    r = ka_fx_set_params(fx, params);
    kmutex_unlock(&g_mix_lock);
    return r ? ka_ok() : ka_set_error(KA_ERROR_ILLPARAM);
}
KA_API int KA_FXGetParameters(uint32_t fxh, void *params) {
    ka_fx *fx = ka_fx_lookup(fxh);
    if (!fx) return ka_set_error(KA_ERROR_HANDLE);
    return ka_fx_get_params(fx, params) ? ka_ok() : ka_set_error(KA_ERROR_ILLPARAM);
}
KA_API int KA_FXReset(uint32_t fxh) {
    ka_fx *fx = ka_fx_lookup(fxh);
    if (!fx) return ka_set_error(KA_ERROR_HANDLE);
    kmutex_lock(&g_mix_lock);
    ka_fx_reset(fx);
    kmutex_unlock(&g_mix_lock);
    return ka_ok();
}
KA_API int KA_FXSetBypass(uint32_t fxh, int bypass) {
    ka_fx *fx = ka_fx_lookup(fxh);
    if (!fx) return ka_set_error(KA_ERROR_HANDLE);
    fx->bypass = bypass ? 1 : 0;
    return ka_ok();
}
KA_API int KA_FXSetPriority(uint32_t fxh, int priority) {
    ka_fx *fx = ka_fx_lookup(fxh);
    ka_channel *ch;
    if (!fx) return ka_set_error(KA_ERROR_HANDLE);
    kmutex_lock(&g_mix_lock);
    fx->priority = priority;
    ch = (ka_channel *)table_find(fx->channel, H_CHANNEL);
    if (ch) qsort(ch->fx, (size_t)ch->fx_count, sizeof ch->fx[0], fx_compare);
    kmutex_unlock(&g_mix_lock);
    return ka_ok();
}
KA_API uint32_t KA_FX_GetVersion(void) { ka_ok(); return KA_VERSION; }


/* Klangten hands paths and addresses over as UTF-16LE when KA_UNICODE is
 * set (that is what its old engine wanted); inside everything is UTF-8. */
char *ka_utf8_arg(const void *str, uint32_t flags) {
    const uint16_t *w;
    size_t n = 0, i, o = 0;
    char *out;
    if (!str) return NULL;
    if (!(flags & KA_UNICODE)) return strdup((const char *)str);
    w = (const uint16_t *)str;
    while (w[n]) n++;
    out = (char *)malloc(n * 3 + 1);
    if (!out) return NULL;
    for (i = 0; i < n; i++) {
        uint32_t c = w[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < n && w[i + 1] >= 0xDC00 && w[i + 1] <= 0xDFFF) {
            c = 0x10000 + ((c - 0xD800) << 10) + (w[i + 1] - 0xDC00);
            i++;
        }
        if (c < 0x80) out[o++] = (char)c;
        else if (c < 0x800) { out[o++] = (char)(0xC0 | (c >> 6)); out[o++] = (char)(0x80 | (c & 0x3F)); }
        else if (c < 0x10000) { out[o++] = (char)(0xE0 | (c >> 12)); out[o++] = (char)(0x80 | ((c >> 6) & 0x3F)); out[o++] = (char)(0x80 | (c & 0x3F)); }
        else { out[o++] = (char)(0xF0 | (c >> 18)); out[o++] = (char)(0x80 | ((c >> 12) & 0x3F)); out[o++] = (char)(0x80 | ((c >> 6) & 0x3F)); out[o++] = (char)(0x80 | (c & 0x3F)); }
        if (o + 4 > n * 3) { char *p = (char *)realloc(out, o + (n - i) * 4 + 8); if (!p) { free(out); return NULL; } out = p; }
    }
    out[o] = '\0';
    return out;
}

/* ----------------------------------------------------------- streams */
KA_API KAHANDLE KA_StreamCreateFile(int mem, const void *file, uint64_t offset, uint64_t length, uint32_t flags) {
    collect_finished();
    ensure_contexts();
    if (!file) return ka_set_error(KA_ERROR_FILEOPEN);
    if (mem) return ka_decoder_open_memory((const char *)file + offset, length, flags);
    {
        char *path = ka_utf8_arg(file, flags);
        KAHANDLE h;
        if (!path) return ka_set_error(KA_ERROR_MEM);
        h = ka_decoder_open_file(path, offset, length, flags);
        free(path);
        return h;
    }
}

KA_API KAHANDLE KA_StreamCreateURL(const char *url, uint32_t offset, uint32_t flags, void *proc, void *user) {
    (void)proc; (void)user;
    collect_finished();
    ensure_contexts();
    if (!url) return ka_set_error(KA_ERROR_FILEOPEN);
    {
        char *u = ka_utf8_arg(url, flags);
        KAHANDLE h;
        if (!u) return ka_set_error(KA_ERROR_MEM);
        h = ka_decoder_open_url(u, offset, flags);
        free(u);
        return h;
    }
}

KA_API KAHANDLE KA_StreamCreate(uint32_t freq, uint32_t chans, uint32_t flags, intptr_t proc, void *user) {
    ka_channel *ch;
    (void)user;
    collect_finished();
    ensure_contexts();
    if (proc != KA_STREAMPROC_PUSH && proc != KA_STREAMPROC_DUMMY) return ka_set_error(KA_ERROR_NOTAVAIL);
    ch = ka_channel_new(KA_KIND_PUSH, (int)freq, (int)chans, flags, &ka_push_ops, NULL);
    if (!ch) return 0;
    if (proc == KA_STREAMPROC_DUMMY) ch->attr_misc[30] = 1;   /* dummy: no data at all */
    if (!ka_rb_init(ch, 50)) { channel_free_internal(ch); return ka_set_error(KA_ERROR_MEM); }
    ka_ok();
    return ch->handle;
}

KA_API int KA_StreamPutData(KAHANDLE handle, const void *buffer, uint32_t length) {
    ka_channel *ch = ka_channel_get(handle);
    uint32_t bytes = length & ~KA_STREAMPROC_END;
    int bps, frames, written = 0;
    if (!ch) return -1;
    if (ch->kind != KA_KIND_PUSH) return ka_set_error(KA_ERROR_NOTAVAIL), -1;
    if (ch->ended && bytes > 0) return ka_set_error(KA_ERROR_ENDED), -1;
    bps = bytes_per_sample(ch);
    frames = (int)(bytes / (uint32_t)(bps * ch->chans));
    if (frames > 0 && buffer) {
        float *tmp = (float *)malloc((size_t)frames * ch->chans * sizeof(float));
        size_t i, n = (size_t)frames * ch->chans;
        if (!tmp) return ka_set_error(KA_ERROR_MEM), -1;
        if (ch->flags & KA_SAMPLE_FLOAT) memcpy(tmp, buffer, n * sizeof(float));
        else if (ch->flags & KA_SAMPLE_8BITS) { const uint8_t *s = (const uint8_t *)buffer; for (i = 0; i < n; i++) tmp[i] = ((int)s[i] - 128) / 128.0f; }
        else { const int16_t *s = (const int16_t *)buffer; for (i = 0; i < n; i++) tmp[i] = s[i] / 32768.0f; }
        written = ka_rb_write(ch, tmp, frames);
        free(tmp);
        if (written < frames) {
            /* the queue is full: report it like BASS (data dropped) */
            ka_set_error(KA_ERROR_MEM);
            return -1;
        }
    }
    if (length & KA_STREAMPROC_END) ch->ended = 1;
    ka_ok();
    return ka_rb_available(ch) * bps * ch->chans;
}

/* ---------------------------------------------------------- samples */
KA_API KAHANDLE KA_SampleLoad(int mem, const void *file, uint64_t offset, uint32_t length, uint32_t max, uint32_t flags) {
    ka_sample *s;
    float *data = NULL;
    int64_t frames = 0;
    int rate = 0, chans = 0;
    collect_finished();
    ensure_contexts();
    if (!file) return ka_set_error(KA_ERROR_FILEOPEN);
    {
        char *path = mem ? NULL : ka_utf8_arg(file, flags);
        int ok = ka_decoder_probe_sample(path, mem ? (const char *)file + offset : NULL, length, &data, &frames, &rate, &chans);
        free(path);
        if (!ok) return 0;
    }
    s = (ka_sample *)calloc(1, sizeof *s);
    if (!s) { free(data); return ka_set_error(KA_ERROR_MEM); }
    s->handle = ka_new_handle();
    s->data = data;
    s->frames = frames;
    s->rate = rate;
    s->chans = chans;
    s->flags = flags;
    s->max_channels = max ? (int)max : 1;
    if (!ka_register_sample(s)) { free(data); free(s); return ka_set_error(KA_ERROR_MEM); }
    ka_ok();
    return s->handle;
}

KA_API KAHANDLE KA_SampleCreate(uint32_t length, uint32_t freq, uint32_t chans, uint32_t max, uint32_t flags) {
    (void)length; (void)freq; (void)chans; (void)max; (void)flags;
    return ka_set_error(KA_ERROR_NOTAVAIL);
}

KA_API int KA_SampleFree(KAHANDLE handle) {
    ka_sample *s = ka_sample_get(handle);
    size_t i;
    if (!s) return ka_set_error(KA_ERROR_HANDLE);
    /* free the playback channels of this sample first */
    for (;;) {
        ka_channel *victim = NULL;
        kmutex_lock(&g_table_lock);
        for (i = 0; i < g_table_size; i++) {
            if (g_table[i].type == H_CHANNEL) {
                ka_channel *c = (ka_channel *)g_table[i].ptr;
                if (c->kind == KA_KIND_SAMPLE && c->sample == s) { victim = c; break; }
            }
        }
        kmutex_unlock(&g_table_lock);
        if (!victim) break;
        channel_free_internal(victim);
    }
    table_remove(handle);
    free(s->data);
    free(s);
    return ka_ok();
}

KA_API KAHANDLE KA_SampleGetChannel(KAHANDLE handle, int flags) {
    ka_sample *s = ka_sample_get(handle);
    ka_channel *ch;
    if (!s) return ka_set_error(KA_ERROR_HANDLE);
    collect_finished();
    ch = ka_channel_new(KA_KIND_SAMPLE, s->rate, s->chans, s->flags & ~(uint32_t)KA_STREAM_DECODE, &ka_sample_ops, NULL);
    if (!ch) return 0;
    ch->sample = s;
    if (flags & KA_SAMPLE_LOOP) ch->flags |= KA_SAMPLE_LOOP;
    ka_ok();
    return ch->handle;
}

KA_API int KA_SampleStop(KAHANDLE handle) {
    ka_sample *s = ka_sample_get(handle);
    size_t i;
    if (!s) return ka_set_error(KA_ERROR_HANDLE);
    kmutex_lock(&g_table_lock);
    for (i = 0; i < g_table_size; i++) {
        if (g_table[i].type == H_CHANNEL) {
            ka_channel *c = (ka_channel *)g_table[i].ptr;
            if (c->kind == KA_KIND_SAMPLE && c->sample == s) c->state = KA_ACTIVE_STOPPED;
        }
    }
    kmutex_unlock(&g_table_lock);
    return ka_ok();
}
