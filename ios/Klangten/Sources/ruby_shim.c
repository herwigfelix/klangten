// A part of Elten - EltenLink / Elten Network desktop client.
// Copyright (C) 2026 Dawid Pieper
// Elten is free software: GNU General Public License v3.
//
// Boots the embedded CRuby runtime and runs the real Elten app. Verified on the
// simulator: the full core loads (185 files) and main.rb runs interactively —
// gestures drive it and it speaks through the host bridge.

#include <stdio.h>
#include <stdbool.h>
#include <string.h>
#include <TargetConditionals.h>
#include "ruby_shim.h"

#if __has_include(<ruby.h>)
#include <ruby.h>
#define ELTEN_HAS_RUBY 1
#endif

#ifdef ELTEN_HAS_RUBY

// CRuby embedded init (sets up the machine stack, registers built-ins, prelude).
extern void CRuby_init(void (*init_prelude)(void), bool yjit);
extern void Init_prelude(void);
extern void ruby_init_ext(const char *name, void (*init)(void));

// Native gem extensions, built for iOS (weak: a partial build still links).
extern void Init_fiddle(void)     __attribute__((weak));
extern void Init_bigdecimal(void) __attribute__((weak));
extern void Init_zstdruby(void)   __attribute__((weak));
extern void Init_nokogiri(void)   __attribute__((weak));

static const char *elten_sdk_and_arch(void) {
#if TARGET_OS_SIMULATOR
#if TARGET_CPU_X86_64
    return "iphonesimulator-x86_64";
#else
    return "iphonesimulator-arm64";
#endif
#else
    return "iphoneos-arm64";
#endif
}

static void report(const char *where) {
    VALUE err = rb_errinfo();
    if (RTEST(err)) {
        VALUE m = rb_funcall(err, rb_intern("message"), 0);
        fprintf(stderr, "[Elten] %s: %s\n", where, StringValueCStr(m));
        rb_set_errinfo(Qnil);
    }
}

static void push_load_path(const char *path) {
    rb_ary_push(rb_gv_get("$LOAD_PATH"), rb_str_new_cstr(path));
}

void elten_ruby_boot(const char *app_root, const char *entry) {
    int state = 0;
    char path[4096];

    CRuby_init(Init_prelude, false);

    // Statically-linked gem extensions (iOS forbids dlopen of external dylibs).
    if (Init_fiddle)     ruby_init_ext("fiddle.so", Init_fiddle);
    if (Init_bigdecimal) ruby_init_ext("bigdecimal.so", Init_bigdecimal);
    if (Init_zstdruby)   ruby_init_ext("zstd-ruby/zstdruby.so", Init_zstdruby);
    if (Init_nokogiri)   ruby_init_ext("nokogiri/nokogiri.so", Init_nokogiri);

    // CRuby's rbconfig needs this before it is required.
    snprintf(path, sizeof(path),
             "Object.const_set(:CRUBY_BUILD_SDK_AND_ARCH, '%s') unless defined?(CRUBY_BUILD_SDK_AND_ARCH)",
             elten_sdk_and_arch());
    rb_eval_string_protect(path, &state);

    // Load paths: bundled stdlib (+ rbconfig), the gem libs and the app source.
    snprintf(path, sizeof(path), "%s/stdlib/4.0.0", app_root);  push_load_path(path);
    snprintf(path, sizeof(path), "%s/stdlib/rbconfig", app_root); push_load_path(path);
    snprintf(path, sizeof(path), "%s/gemlibs", app_root);       push_load_path(path);
    snprintf(path, sizeof(path), "%s/eltencore/src", app_root);     push_load_path(path);
    push_load_path(app_root);

    // ios_boot.rb loads the Elten core, starts the gesture pump and runs main.rb.
    rb_load_protect(rb_str_new_cstr(entry), 0, &state);
    if (state) report("boot failed");
}

void elten_ruby_eval(const char *code) {
    int state = 0;
    rb_eval_string_protect(code, &state);
    if (state) report("eval failed");
}

#else /* no vendored runtime: stub so the native host still builds */
void elten_ruby_boot(const char *app_root, const char *entry) {
    (void)app_root; (void)entry;
    fprintf(stderr, "[Elten] built without CRuby; run ios/scripts/fetch-cruby-runtime.sh\n");
}
void elten_ruby_eval(const char *code) { (void)code; }
#endif
