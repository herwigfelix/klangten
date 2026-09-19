#!/usr/bin/env bash
# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
#
# Cross-builds the embedded Ruby runtime for Android: libffi, libyaml, OpenSSL,
# CRuby (static, every extension linked in) and the fiddle gem extension.
# Unlike iOS there is no maintained prebuilt CRuby for Android, so we build it.
#
# Output (gitignored), per ABI:
#   android/vendor/<abi>/lib/      libruby-static.a, extension archives, libffi.a,
#                                  libyaml.a, libssl.a, libcrypto.a, libfiddle.a
#   android/vendor/<abi>/include/  ruby headers (ruby-4.0.0/...)
#   android/vendor/<abi>/stdlib/   the Ruby standard library incl. rbconfig
#   android/vendor/<abi>/ext.list  every statically linked extension (for the loader)
#
# Recipe from the 2026-09 spike (see docs/android.md):
#   - API 26 minimum: Bionic has nl_langinfo only from 26 on.
#   - libffi 3.8 sets FFI_EXEC_STATIC_TRAMP for Android; closures work without
#     writable+executable memory.
#   - Bionic has no libcrypt; fork/setuid checks are overridden (Termux recipe).
#   - `make install` would put the default gems into the HOST ruby
#     (/opt/homebrew/...); we therefore collect the results ourselves.
#   - Everything is linked with 16 KB page alignment (Play requirement 2025+).
#
# Usage: [ABI=arm64-v8a] [NDK=...] android/scripts/build-runtime.sh
set -euo pipefail

ABI="${ABI:-arm64-v8a}"
API="${API:-26}"
RUBY_VERSION="${RUBY_VERSION:-4.0.7}"
LIBFFI_VERSION="${LIBFFI_VERSION:-3.8.0}"
YAML_VERSION="${YAML_VERSION:-0.2.5}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.8}"
NDK="${NDK:-$(ls -d "$HOME"/Library/Android/sdk/ndk/28.* 2>/dev/null | sort -V | tail -1)}"
[ -d "$NDK" ] || { echo "!! Android NDK r28 not found (set NDK=...)"; exit 1; }
TC="$(ls -d "$NDK"/toolchains/llvm/prebuilt/* | head -1)"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

case "$ABI" in
  arm64-v8a)   TRIPLE=aarch64-linux-android; OSSL_TARGET=android-arm64 ;;
  x86_64)      TRIPLE=x86_64-linux-android;  OSSL_TARGET=android-x86_64 ;;
  armeabi-v7a) TRIPLE=armv7a-linux-androideabi; OSSL_TARGET=android-arm ;;
  *) echo "!! unsupported ABI $ABI"; exit 1 ;;
esac
HOST_TRIPLE="${TRIPLE/armv7a/arm}"

ANDROID_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ANDROID_DIR/vendor/$ABI"
WORK="$ANDROID_DIR/build/runtime-$ABI"
PREFIX="$WORK/prefix"
DL="$ANDROID_DIR/build/downloads"
mkdir -p "$WORK" "$PREFIX" "$DL"

export CC="$TC/bin/${TRIPLE}${API}-clang"
export CXX="$TC/bin/${TRIPLE}${API}-clang++"
export AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib" STRIP="$TC/bin/llvm-strip" NM="$TC/bin/llvm-nm"
BASE_CFLAGS="-O2 -fPIC"
PAGE_LDFLAGS="-Wl,-z,max-page-size=16384"

fetch() { # url file
  [ -f "$DL/$2" ] || curl -fL --retry 3 -o "$DL/$2.part" "$1" && { [ -f "$DL/$2" ] || mv "$DL/$2.part" "$DL/$2"; }
}
step() { echo; echo "==> $*"; }
log() { echo "$WORK/$1.log"; }

# --- libffi ------------------------------------------------------------------
if [ ! -f "$PREFIX/lib/libffi.a" ]; then
  step "libffi $LIBFFI_VERSION"
  fetch "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VERSION/libffi-$LIBFFI_VERSION.tar.gz" "libffi-$LIBFFI_VERSION.tar.gz"
  rm -rf "$WORK/libffi" && mkdir "$WORK/libffi" && tar xzf "$DL/libffi-$LIBFFI_VERSION.tar.gz" -C "$WORK/libffi" --strip-components 1
  (cd "$WORK/libffi" && CFLAGS="$BASE_CFLAGS" ./configure --host="$HOST_TRIPLE" --prefix="$PREFIX" \
     --enable-static --disable-shared --disable-docs >"$(log libffi)" 2>&1 \
   && make -j"$JOBS" >>"$(log libffi)" 2>&1 && make install >>"$(log libffi)" 2>&1) \
   || { tail -30 "$(log libffi)"; exit 1; }
  grep -q "define FFI_EXEC_STATIC_TRAMP 1" "$WORK"/libffi/*/fficonfig.h \
    || echo "   warning: FFI_EXEC_STATIC_TRAMP not set, closures may need W+X memory"
fi

# --- libyaml -----------------------------------------------------------------
if [ ! -f "$PREFIX/lib/libyaml.a" ]; then
  step "libyaml $YAML_VERSION"
  fetch "https://github.com/yaml/libyaml/releases/download/$YAML_VERSION/yaml-$YAML_VERSION.tar.gz" "yaml-$YAML_VERSION.tar.gz"
  rm -rf "$WORK/yaml" && mkdir "$WORK/yaml" && tar xzf "$DL/yaml-$YAML_VERSION.tar.gz" -C "$WORK/yaml" --strip-components 1
  (cd "$WORK/yaml" && CFLAGS="$BASE_CFLAGS" ./configure --host="$HOST_TRIPLE" --prefix="$PREFIX" \
     --enable-static --disable-shared >"$(log yaml)" 2>&1 \
   && make -j"$JOBS" >>"$(log yaml)" 2>&1 && make install >>"$(log yaml)" 2>&1) \
   || { tail -30 "$(log yaml)"; exit 1; }
fi

# --- OpenSSL -----------------------------------------------------------------
if [ ! -f "$PREFIX/lib/libssl.a" ]; then
  step "OpenSSL $OPENSSL_VERSION"
  fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "openssl-$OPENSSL_VERSION.tar.gz"
  rm -rf "$WORK/openssl" && mkdir "$WORK/openssl" && tar xzf "$DL/openssl-$OPENSSL_VERSION.tar.gz" -C "$WORK/openssl" --strip-components 1
  # OpenSSL's Android targets pick the compiler from the NDK themselves.
  (cd "$WORK/openssl" && env -u CC -u CXX ANDROID_NDK_ROOT="$NDK" PATH="$TC/bin:$PATH" \
     ./Configure "$OSSL_TARGET" -D__ANDROID_API__="$API" no-shared no-tests no-docs no-apps \
       --prefix="$PREFIX" --libdir=lib >"$(log openssl)" 2>&1 \
   && env -u CC -u CXX ANDROID_NDK_ROOT="$NDK" PATH="$TC/bin:$PATH" make -j"$JOBS" build_libs >>"$(log openssl)" 2>&1 \
   && env -u CC -u CXX ANDROID_NDK_ROOT="$NDK" PATH="$TC/bin:$PATH" make install_dev >>"$(log openssl)" 2>&1) \
   || { tail -30 "$(log openssl)"; exit 1; }
fi

# --- CRuby -------------------------------------------------------------------
RUBY_SRC="$WORK/ruby"
if [ ! -f "$RUBY_SRC/libruby-static.a" ] || [ ! -f "$RUBY_SRC/ext/extinit.o" ]; then
  step "CRuby $RUBY_VERSION (baseruby $(ruby -e 'print RUBY_VERSION'))"
  fetch "https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/ruby-$RUBY_VERSION.tar.gz" "ruby-$RUBY_VERSION.tar.gz"
  rm -rf "$RUBY_SRC" && mkdir "$RUBY_SRC" && tar xzf "$DL/ruby-$RUBY_VERSION.tar.gz" -C "$RUBY_SRC" --strip-components 1
  (cd "$RUBY_SRC" && \
   CFLAGS="$BASE_CFLAGS -fno-strict-aliasing -I$PREFIX/include" \
   LDFLAGS="-L$PREFIX/lib $PAGE_LDFLAGS" \
   PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
   ./configure \
     --host="$HOST_TRIPLE" --prefix=/klangten-ruby \
     --with-baseruby="$(command -v ruby)" \
     --disable-shared --with-static-linked-ext \
     --disable-install-doc --disable-jit-support \
     --with-openssl-dir="$PREFIX" --with-libyaml-dir="$PREFIX" --with-libffi-dir="$PREFIX" \
     --with-out-ext=win32,win32ole,dbm,gdbm,readline,pty,syslog \
     ac_cv_func_setgroups=no ac_cv_func_setresuid=no ac_cv_func_setreuid=no \
     ac_cv_lib_crypt_crypt=no ac_cv_func_fork=no rb_cv_type_deprecated=x \
     >"$(log ruby-configure)" 2>&1) || { tail -40 "$(log ruby-configure)"; exit 1; }
  (cd "$RUBY_SRC" && make -j"$JOBS" >"$(log ruby-make)" 2>&1) \
    || { grep -E "error:|undefined symbol" "$(log ruby-make)" | sort -u | head -20; tail -15 "$(log ruby-make)"; exit 1; }
fi

# --- fiddle (bundled gem, not built by make) ----------------------------------
if [ ! -f "$PREFIX/lib/libfiddle.a" ]; then
  step "fiddle"
  FDIR="$(find "$RUBY_SRC/gems" "$RUBY_SRC/.bundle/gems" -maxdepth 4 -type d -path '*fiddle-*/ext/fiddle' 2>/dev/null | head -1)"
  if [ -z "$FDIR" ]; then
    GEM="$(ls "$RUBY_SRC"/gems/fiddle-*.gem | head -1)"
    rm -rf "$WORK/fiddle" && mkdir -p "$WORK/fiddle" && (cd "$WORK/fiddle" && tar xf "$GEM" data.tar.gz && tar xzf data.tar.gz)
    FDIR="$WORK/fiddle/ext/fiddle"
  fi
  [ -d "$FDIR" ] || { echo "!! fiddle sources not found"; exit 1; }
  CFG_INC="$(dirname "$(dirname "$(find "$RUBY_SRC/.ext/include" -name config.h -path '*ruby/config.h' | head -1)")")"
  DEFS=(-DHAVE_DLFCN_H -DHAVE_SYS_MMAN_H -DHAVE_FFI_CLOSURE_ALLOC -DHAVE_FFI_PREP_CIF_VAR
        -DHAVE_RUBY_MEMORY_VIEW_H -DSIGNEDNESS_OF_SIZE_T=1 -DRUBY_EXPORT)
  rm -rf "$WORK/fobj" && mkdir "$WORK/fobj"
  for src in "$FDIR"/*.c; do
    "$CC" $BASE_CFLAGS "${DEFS[@]}" -I"$RUBY_SRC/include" -I"$CFG_INC" -I"$PREFIX/include" -I"$FDIR" \
      -c "$src" -o "$WORK/fobj/$(basename "$src" .c).o"
  done
  "$AR" rcs "$PREFIX/lib/libfiddle.a" "$WORK/fobj"/*.o
  mkdir -p "$PREFIX/fiddle-lib" && cp -R "$(dirname "$(dirname "$FDIR")")/lib/." "$PREFIX/fiddle-lib/"
fi

# --- collect -------------------------------------------------------------------
step "collect into $OUT"
rm -rf "$OUT" && mkdir -p "$OUT/lib" "$OUT/include" "$OUT/stdlib"
cp "$RUBY_SRC/libruby-static.a" "$OUT/lib/"
# Every statically linked extension: extinit.o registers them, the archives hold them.
cp "$RUBY_SRC/ext/extinit.o" "$RUBY_SRC/enc/encinit.o" "$OUT/lib/"
find "$RUBY_SRC/ext" "$RUBY_SRC/enc" -name "*.a" | while read -r a; do
  rel="${a#"$RUBY_SRC"/}"; cp "$a" "$OUT/lib/$(echo "$rel" | tr '/' '_')"
done
cp "$PREFIX"/lib/{libffi,libyaml,libssl,libcrypto,libfiddle}.a "$OUT/lib/"
cp -R "$RUBY_SRC/include/." "$OUT/include/"
cp -R "$CFG_INC/." "$OUT/include/" 2>/dev/null || cp -R "$(dirname "$(dirname "$(find "$RUBY_SRC/.ext/include" -name config.h -path '*ruby/config.h' | head -1)")")/." "$OUT/include/"
# Standard library: lib/ (pure Ruby), .ext/common (Ruby parts of extensions),
# rbconfig.rb, fiddle's Ruby files.
cp -R "$RUBY_SRC/lib/." "$OUT/stdlib/"
cp -R "$RUBY_SRC/.ext/common/." "$OUT/stdlib/"
cp -R "$PREFIX/fiddle-lib/." "$OUT/stdlib/"
cp "$RUBY_SRC/rbconfig.rb" "$OUT/stdlib/"
"$NM" -g "$RUBY_SRC/ext/extinit.o" 2>/dev/null | awk '/ U Init_/ {print $2}' > "$OUT/ext.list"

echo
echo "==> Android runtime for $ABI in $OUT"
echo "    libruby-static.a $(du -h "$OUT/lib/libruby-static.a" | cut -f1), $(ls "$OUT/lib" | wc -l | tr -d ' ') archives, $(wc -l < "$OUT/ext.list" | tr -d ' ') extensions, stdlib $(du -sh "$OUT/stdlib" | cut -f1)"
