// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Elten: Copyright (C) 2014-2026 Dawid Pieper
// Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
// This file was added for Klangten (GNU GPL v3, section 5a).
//
// JNI entry point that boots the statically linked CRuby. It goes through
// ruby_options() like the ruby executable does, because that path also
// registers the encodings, the statically linked extensions (Init_ext) and
// the gem prelude; the load path is given as -I options, since the prefix
// compiled into the runtime does not exist on the device.
//
// stdout and stderr are forwarded to logcat (tag "Klangten-ruby").

#include <jni.h>
#include <android/log.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <ruby.h>

extern void ruby_init_ext(const char *name, void (*init)(void));
extern void Init_fiddle(void);

#define LOG_TAG "Klangten-ruby"

static void *pump(void *arg) {
    int fd = (int)(intptr_t)arg;
    char buffer[1024];
    size_t used = 0;
    for (;;) {
        ssize_t n = read(fd, buffer + used, sizeof(buffer) - 1 - used);
        if (n <= 0) break;
        used += (size_t)n;
        char *start = buffer, *nl;
        while ((nl = memchr(start, '\n', used - (size_t)(start - buffer))) != NULL) {
            *nl = 0;
            __android_log_write(ANDROID_LOG_INFO, LOG_TAG, start);
            start = nl + 1;
        }
        used -= (size_t)(start - buffer);
        memmove(buffer, start, used);
        if (used == sizeof(buffer) - 1) {
            buffer[used] = 0;
            __android_log_write(ANDROID_LOG_INFO, LOG_TAG, buffer);
            used = 0;
        }
    }
    return NULL;
}

static void forward_output(void) {
    int fds[2];
    if (pipe(fds) != 0) return;
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    dup2(fds[1], STDOUT_FILENO);
    dup2(fds[1], STDERR_FILENO);
    pthread_t thread;
    if (pthread_create(&thread, NULL, pump, (void *)(intptr_t)fds[0]) == 0) pthread_detach(thread);
}

static char *dup_jstring(JNIEnv *env, jstring value) {
    const char *utf = (*env)->GetStringUTFChars(env, value, NULL);
    char *copy = strdup(utf);
    (*env)->ReleaseStringUTFChars(env, value, utf);
    return copy;
}

static char *join(const char *a, const char *b) {
    size_t n = strlen(a) + strlen(b) + 1;
    char *s = malloc(n);
    snprintf(s, n, "%s%s", a, b);
    return s;
}

// fiddle is a bundled gem, so Init_ext does not know it; register it by hand.
static VALUE register_fiddle(VALUE unused) {
    (void)unused;
    ruby_init_ext("fiddle.so", Init_fiddle);
    return Qnil;
}

JNIEXPORT jint JNICALL
Java_it_sixdots_klangten_RubyRuntime_boot(JNIEnv *env, jclass cls, jstring jroot, jstring jentry,
                                         jstring jlibdir, jstring jfiles) {
    (void)cls;
    static int booted = 0;
    if (booted) return -2;
    booted = 1;

    char *root = dup_jstring(env, jroot);
    char *entry = dup_jstring(env, jentry);
    char *libdir = dup_jstring(env, jlibdir);
    char *files = dup_jstring(env, jfiles);

    forward_output();
    setenv("HOME", files, 1);
    setenv("TMPDIR", join(files, "/tmp"), 1);
    setenv("LANG", "C.UTF-8", 1);
    setenv("KLANGTEN_NATIVE_LIB_DIR", libdir, 1);
    setenv("KLANGTEN_RUBY_ROOT", root, 1);

    char *stdlib = join(root, "/stdlib");
    char *app = join(root, "/app");
    char *argv[] = { "klangten", "-I", stdlib, "-I", app, "-E", "UTF-8:UTF-8", entry, NULL };
    int argc = (int)(sizeof(argv) / sizeof(argv[0])) - 1;
    char **pargv = argv;

    ruby_sysinit(&argc, &pargv);
    {
        RUBY_INIT_STACK;
        ruby_init();
        int state = 0;
        rb_protect(register_fiddle, Qnil, &state);
        void *node = ruby_options(argc, pargv);
        int status = ruby_run_node(node);
        fflush(stdout);
        fflush(stderr);
        return status;
    }
}
