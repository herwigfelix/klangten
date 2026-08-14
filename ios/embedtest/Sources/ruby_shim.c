#include <stdio.h>
#include <stdbool.h>
#include "ruby_shim.h"
#include <ruby.h>
extern void CRuby_init(void (*init_prelude)(void), bool yjit);
extern void Init_prelude(void);
extern void ruby_init_ext(const char *name, void (*init)(void));
extern void Init_fiddle(void);
extern void Init_bigdecimal(void);
extern void Init_zstdruby(void);
extern void Init_nokogiri(void);
void elten_ruby_run(const char *app_root, const char *boot_file) {
    CRuby_init(Init_prelude, false);
    { int st=0; rb_eval_string_protect("Object.const_set(:CRUBY_BUILD_SDK_AND_ARCH, 'iphonesimulator-arm64') unless defined?(CRUBY_BUILD_SDK_AND_ARCH)", &st); }
    ruby_init_ext("fiddle.so", Init_fiddle);
    ruby_init_ext("bigdecimal.so", Init_bigdecimal);
    ruby_init_ext("zstd-ruby/zstdruby.so", Init_zstdruby);
    ruby_init_ext("nokogiri/nokogiri.so", Init_nokogiri);
    int state = 0;
    rb_ary_push(rb_gv_get("$LOAD_PATH"), rb_str_new_cstr(app_root));
    { char sp[4096]; snprintf(sp, sizeof(sp), "%s/stdlib/4.0.0", app_root); rb_ary_push(rb_gv_get("$LOAD_PATH"), rb_str_new_cstr(sp)); }
    { char sp[4096]; snprintf(sp, sizeof(sp), "%s/stdlib/rbconfig", app_root); rb_ary_push(rb_gv_get("$LOAD_PATH"), rb_str_new_cstr(sp)); }
    { char sp[4096]; snprintf(sp, sizeof(sp), "%s/gemlibs", app_root); rb_ary_push(rb_gv_get("$LOAD_PATH"), rb_str_new_cstr(sp)); }
    rb_load_protect(rb_str_new_cstr(boot_file), 0, &state);
    if (state) { VALUE err = rb_errinfo(); if (RTEST(err)) { VALUE m = rb_funcall(err, rb_intern("message"), 0); fprintf(stderr, "[Elten embed] ruby error: %s\n", StringValueCStr(m)); } }
}
