// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Elten: Copyright (C) 2014-2026 Dawid Pieper
// Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
// This file was added for Klangten (GNU GPL v3, section 5a).
//
// Android side of the Ruby <-> host bridge. These are the same elten_host_*
// entry points the iOS host exports (ios/Klangten/Sources/EltenHostBridge.swift),
// so the Ruby platform layer (src/platforms/ios/eapi/hostbridge.rb) works
// unchanged; each one forwards to a static method of it.sixdots.klangten.Host.
//
// Input flows the other way: Java pushes tokens ("gesture:swipe_right",
// "ktext:...", "active:1") into a queue that Ruby drains via
// elten_host_next_input.

#include <jni.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default"), used))

static JavaVM *g_vm;
static jclass g_host;

// --- JNI plumbing --------------------------------------------------------------

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    g_vm = vm;
    JNIEnv *env;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
    jclass host = (*env)->FindClass(env, "it/sixdots/klangten/Host");
    if (host == NULL) return JNI_ERR;
    g_host = (*env)->NewGlobalRef(env, host);
    return JNI_VERSION_1_6;
}

// Ruby threads are native threads; attach them on first use (they stay attached).
static JNIEnv *env_for_thread(void) {
    JNIEnv *env = NULL;
    if (g_vm == NULL) return NULL;
    if ((*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6) == JNI_OK) return env;
    if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK) return NULL;
    return env;
}

static jmethodID method(JNIEnv *env, const char *name, const char *signature) {
    jmethodID id = (*env)->GetStaticMethodID(env, g_host, name, signature);
    if (id == NULL) (*env)->ExceptionClear(env);
    return id;
}

static void clear_exception(JNIEnv *env) {
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
    }
}

static jstring jstr(JNIEnv *env, const char *value) {
    return (*env)->NewStringUTF(env, value == NULL ? "" : value);
}

// Returned strings stay valid until the same function is called again, like
// the CStringHolder on iOS.
enum { S_VOICES, S_CLIPBOARD, S_LOCALE, S_OS, S_LIBDIR, S_INPUT, S_COUNT };
static char *g_strings[S_COUNT];
static pthread_mutex_t g_strings_lock = PTHREAD_MUTEX_INITIALIZER;

static const char *hold(int slot, char *value) {
    pthread_mutex_lock(&g_strings_lock);
    free(g_strings[slot]);
    g_strings[slot] = value != NULL ? value : strdup("");
    const char *result = g_strings[slot];
    pthread_mutex_unlock(&g_strings_lock);
    return result;
}

static char *copy_jstring(JNIEnv *env, jstring value) {
    if (value == NULL) return strdup("");
    const char *utf = (*env)->GetStringUTFChars(env, value, NULL);
    char *copy = strdup(utf != NULL ? utf : "");
    if (utf != NULL) (*env)->ReleaseStringUTFChars(env, value, utf);
    (*env)->DeleteLocalRef(env, value);
    return copy;
}

static const char *call_string(int slot, const char *name) {
    JNIEnv *env = env_for_thread();
    if (env == NULL) return hold(slot, NULL);
    jmethodID id = method(env, name, "()Ljava/lang/String;");
    if (id == NULL) return hold(slot, NULL);
    jstring value = (jstring)(*env)->CallStaticObjectMethod(env, g_host, id);
    clear_exception(env);
    return hold(slot, copy_jstring(env, value));
}

static int call_int(const char *name) {
    JNIEnv *env = env_for_thread();
    if (env == NULL) return 0;
    jmethodID id = method(env, name, "()I");
    if (id == NULL) return 0;
    jint value = (*env)->CallStaticIntMethod(env, g_host, id);
    clear_exception(env);
    return value;
}

static void call_void(const char *name) {
    JNIEnv *env = env_for_thread();
    if (env == NULL) return;
    jmethodID id = method(env, name, "()V");
    if (id == NULL) return;
    (*env)->CallStaticVoidMethod(env, g_host, id);
    clear_exception(env);
}

static int call_int_string(const char *name, const char *arg) {
    JNIEnv *env = env_for_thread();
    if (env == NULL) return 0;
    jmethodID id = method(env, name, "(Ljava/lang/String;)I");
    if (id == NULL) return 0;
    jstring value = jstr(env, arg);
    jint result = (*env)->CallStaticIntMethod(env, g_host, id, value);
    (*env)->DeleteLocalRef(env, value);
    clear_exception(env);
    return result;
}

// --- input queue (Java -> Ruby) ---------------------------------------------------

typedef struct token { char *text; struct token *next; } token;
static token *g_head, *g_tail;
static pthread_mutex_t g_queue_lock = PTHREAD_MUTEX_INITIALIZER;

JNIEXPORT void JNICALL
Java_it_sixdots_klangten_Host_pushInput(JNIEnv *env, jclass cls, jstring value) {
    (void)cls;
    token *t = malloc(sizeof(token));
    const char *utf = (*env)->GetStringUTFChars(env, value, NULL);
    t->text = strdup(utf != NULL ? utf : "");
    if (utf != NULL) (*env)->ReleaseStringUTFChars(env, value, utf);
    t->next = NULL;
    pthread_mutex_lock(&g_queue_lock);
    if (g_tail != NULL) g_tail->next = t; else g_head = t;
    g_tail = t;
    pthread_mutex_unlock(&g_queue_lock);
}

EXPORT const char *elten_host_next_input(void) {
    pthread_mutex_lock(&g_queue_lock);
    token *t = g_head;
    if (t != NULL) {
        g_head = t->next;
        if (g_head == NULL) g_tail = NULL;
    }
    pthread_mutex_unlock(&g_queue_lock);
    if (t == NULL) return hold(S_INPUT, NULL);
    char *text = t->text;
    free(t);
    return hold(S_INPUT, text);
}

// --- speech -------------------------------------------------------------------------

EXPORT int elten_host_speech_available(void) { return call_int("speechAvailable"); }
EXPORT const char *elten_host_speech_voices_json(void) { return call_string(S_VOICES, "speechVoicesJson"); }
EXPORT void elten_host_speech_stop(void) { call_void("speechStop"); }
EXPORT int elten_host_speech_speaking(void) { return call_int("speechSpeaking"); }
EXPORT void elten_host_speech_pause(void) { call_void("speechStop"); }
EXPORT void elten_host_speech_resume(void) {}

EXPORT void elten_host_speech_speak(const char *text, const char *voice, int rate, int volume,
                                    int pitch, int interrupt) {
    JNIEnv *env = env_for_thread();
    if (env == NULL) return;
    jmethodID id = method(env, "speechSpeak", "(Ljava/lang/String;Ljava/lang/String;IIIZ)V");
    if (id == NULL) return;
    jstring t = jstr(env, text), v = jstr(env, voice);
    (*env)->CallStaticVoidMethod(env, g_host, id, t, v, rate, volume, pitch, interrupt ? JNI_TRUE : JNI_FALSE);
    (*env)->DeleteLocalRef(env, t);
    (*env)->DeleteLocalRef(env, v);
    clear_exception(env);
}

// --- clipboard, URLs, permissions, system info ----------------------------------------

EXPORT const char *elten_host_clipboard_get(void) { return call_string(S_CLIPBOARD, "clipboardGet"); }
EXPORT void elten_host_clipboard_set(const char *text) { call_int_string("clipboardSet", text); }
EXPORT int elten_host_open_url(const char *url) { return call_int_string("openUrl", url); }
EXPORT const char *elten_host_locale(void) { return call_string(S_LOCALE, "locale"); }
EXPORT const char *elten_host_os_version(void) { return call_string(S_OS, "osVersion"); }
EXPORT const char *elten_host_frameworks_path(void) { return call_string(S_LIBDIR, "nativeLibraryDir"); }

EXPORT int elten_host_microphone_request(double timeout) {
    JNIEnv *env = env_for_thread();
    if (env == NULL) return 0;
    jmethodID id = method(env, "microphoneRequest", "(D)I");
    if (id == NULL) return 0;
    jint result = (*env)->CallStaticIntMethod(env, g_host, id, timeout);
    clear_exception(env);
    return result;
}

// --- system on-screen keyboard ---------------------------------------------------------

EXPORT void elten_host_system_keyboard_show(void) { call_void("keyboardShow"); }
EXPORT void elten_host_system_keyboard_hide(void) { call_void("keyboardHide"); }
EXPORT int elten_host_system_keyboard_visible(void) { return call_int("keyboardVisible"); }
