#!/usr/bin/env bash
# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
#
# Builds the gems the Klangten core needs for Android, after build-runtime.sh:
#   native, linked statically into libklangten.so (registered in klangten_jni.c):
#     bigdecimal, zstd-ruby, nokogiri (+ libxml2 and libxslt: Android has no
#     public copy of either, unlike iOS)
#   pure Ruby, staged next to the stdlib:
#     the Gemfile gems and Ruby's bundled gems (csv, rexml, racc, ...)
#
# Output: vendor/<abi>/lib/lib{bigdecimal,zstdruby,nokogiri,xml2,xslt,exslt}.a
#         vendor/<abi>/gemlibs/
# Versions follow the Gemfile; libxml2/libxslt follow nokogiri's dependencies.yml.
# The HAVE_* flags normally come from nokogiri's extconf: they tell its
# polyfill which libxml2 functions exist (2.13 has these two, not xmlCtxtGetOptions).
#
# Usage: [ABI=arm64-v8a] android/scripts/build-gems.sh
set -euo pipefail

ABI="${ABI:-arm64-v8a}"
API="${API:-26}"
NOKOGIRI="nokogiri-1.19.4"
BIGDECIMAL="bigdecimal-3.3.1"
ZSTD="zstd-ruby-2.0.6"
LIBXML2_VERSION="2.13.9"; LIBXML2_SHA256="a2c9ae7b770da34860050c309f903221c67830c86e4a7e760692b803df95143a"
LIBXSLT_VERSION="1.1.43"; LIBXSLT_SHA256="5a3d6b383ca5afc235b171118e90f5ff6aa27e9fea3303065231a6d403f0183a"
PURE_GEMS="rubyzip-3.2.2 http-2-1.1.3 base62-1.0.0 base64-0.3.0 ostruct-0.6.3 ruby-xz-1.0.3 net-http-0.9.1"

NDK="${NDK:-$(ls -d "$HOME"/Library/Android/sdk/ndk/28.* 2>/dev/null | sort -V | tail -1)}"
TC="$(ls -d "$NDK"/toolchains/llvm/prebuilt/* | head -1)"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
case "$ABI" in
  arm64-v8a)   TRIPLE=aarch64-linux-android ;;
  x86_64)      TRIPLE=x86_64-linux-android ;;
  armeabi-v7a) TRIPLE=armv7a-linux-androideabi ;;
  *) echo "!! unsupported ABI $ABI"; exit 1 ;;
esac
HOST_TRIPLE="${TRIPLE/armv7a/arm}"

ANDROID_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ANDROID_DIR/vendor/$ABI"
WORK="$ANDROID_DIR/build/gems-$ABI"
PREFIX="$WORK/prefix"
DL="$ANDROID_DIR/build/downloads"
RUBY_SRC="$ANDROID_DIR/build/runtime-$ABI/ruby"
[ -f "$VENDOR/lib/libruby-static.a" ] || { echo "!! run scripts/build-runtime.sh first"; exit 1; }
mkdir -p "$WORK" "$PREFIX" "$DL"

export CC="$TC/bin/${TRIPLE}${API}-clang" AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib"
CFLAGS_BASE=(-O2 -fPIC -fno-common)
RUBY_INC=(-I"$VENDOR/include")

fetch() { # url file [sha256]
  if [ ! -f "$DL/$2" ]; then curl -fL --retry 3 -o "$DL/$2.part" "$1" && mv "$DL/$2.part" "$DL/$2"; fi
  if [ -n "${3:-}" ]; then echo "$3  $DL/$2" | shasum -a 256 -c - >/dev/null || { echo "!! checksum mismatch: $2"; exit 1; }; fi
}
gem_src() { # name-version -> $WORK/<name-version>
  fetch "https://rubygems.org/downloads/$1.gem" "$1.gem"
  rm -rf "$WORK/$1" && mkdir -p "$WORK/$1"
  tar xf "$DL/$1.gem" -C "$WORK/$1" && tar xzf "$WORK/$1/data.tar.gz" -C "$WORK/$1"
}
compile_all() { # outdir archive flags... -- sources...
  local out="$1" archive="$2"; shift 2
  local flags=(); while [ "$1" != "--" ]; do flags+=("$1"); shift; done; shift
  rm -rf "$out" && mkdir -p "$out"
  for s in "$@"; do
    "$CC" "${CFLAGS_BASE[@]}" "${flags[@]}" -c "$s" -o "$out/$(echo "$s" | shasum | cut -c1-16)-$(basename "$s" .c).o"
  done
  "$AR" rcs "$archive" "$out"/*.o
}
step() { echo; echo "==> $*"; }

# --- libxml2 / libxslt ------------------------------------------------------------
if [ ! -f "$PREFIX/lib/libxml2.a" ]; then
  step "libxml2 $LIBXML2_VERSION"
  fetch "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/libxml2-$LIBXML2_VERSION.tar.xz" "libxml2-$LIBXML2_VERSION.tar.xz" "$LIBXML2_SHA256"
  rm -rf "$WORK/libxml2" && mkdir "$WORK/libxml2" && tar xf "$DL/libxml2-$LIBXML2_VERSION.tar.xz" -C "$WORK/libxml2" --strip-components 1
  # No iconv before API 28: libxml2 keeps its built-in UTF-8/UTF-16/Latin-1 codecs.
  (cd "$WORK/libxml2" && CFLAGS="-O2 -fPIC" ./configure --host="$HOST_TRIPLE" --prefix="$PREFIX" \
     --enable-static --disable-shared --without-python --without-iconv --without-icu --without-lzma \
     --without-http --without-ftp --with-zlib >"$WORK/libxml2.log" 2>&1 \
   && make -j"$JOBS" >>"$WORK/libxml2.log" 2>&1 && make install >>"$WORK/libxml2.log" 2>&1) \
   || { tail -30 "$WORK/libxml2.log"; exit 1; }
fi
if [ ! -f "$PREFIX/lib/libxslt.a" ]; then
  step "libxslt $LIBXSLT_VERSION"
  fetch "https://download.gnome.org/sources/libxslt/${LIBXSLT_VERSION%.*}/libxslt-$LIBXSLT_VERSION.tar.xz" "libxslt-$LIBXSLT_VERSION.tar.xz" "$LIBXSLT_SHA256"
  rm -rf "$WORK/libxslt" && mkdir "$WORK/libxslt" && tar xf "$DL/libxslt-$LIBXSLT_VERSION.tar.xz" -C "$WORK/libxslt" --strip-components 1
  (cd "$WORK/libxslt" && CFLAGS="-O2 -fPIC" PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
     ./configure --host="$HOST_TRIPLE" --prefix="$PREFIX" --with-libxml-prefix="$PREFIX" \
     --enable-static --disable-shared --without-python --without-crypto --without-plugins >"$WORK/libxslt.log" 2>&1 \
   && make -j"$JOBS" >>"$WORK/libxslt.log" 2>&1 && make install >>"$WORK/libxslt.log" 2>&1) \
   || { tail -30 "$WORK/libxslt.log"; exit 1; }
fi

# --- bigdecimal ---------------------------------------------------------------------
step "$BIGDECIMAL"
gem_src "$BIGDECIMAL"
BD="$WORK/$BIGDECIMAL/ext/bigdecimal"
compile_all "$WORK/o-bigdecimal" "$VENDOR/lib/libbigdecimal.a" "${RUBY_INC[@]}" -I"$BD" \
  -DHAVE_FLOAT_H -DHAVE_MATH_H -DHAVE_STDBOOL_H -DHAVE_STDLIB_H \
  -DHAVE_RUBY_ATOMIC_H -DHAVE_RUBY_INTERNAL_HAS_BUILTIN_H -DHAVE_RUBY_INTERNAL_STATIC_ASSERT_H \
  -DHAVE_RB_COMPLEX_REAL -DHAVE_RB_COMPLEX_IMAG -DHAVE_RB_OPTS_EXCEPTION_P \
  -DHAVE_RB_CATEGORY_WARN -DHAVE_RB_EXT_RACTOR_SAFE \
  -DHAVE_BUILTIN___BUILTIN_CLZ -DHAVE_BUILTIN___BUILTIN_CLZL -DHAVE_BUILTIN___BUILTIN_CLZLL \
  -DHAVE_BUILTIN___BUILTIN_ADD_OVERFLOW -DHAVE_BUILTIN___BUILTIN_MUL_OVERFLOW \
  -- "$BD/bigdecimal.c" "$BD/missing.c"

# --- zstd-ruby ------------------------------------------------------------------------
step "$ZSTD"
gem_src "$ZSTD"
Z="$WORK/$ZSTD/ext/zstdruby"
# shellcheck disable=SC2046
compile_all "$WORK/o-zstd" "$VENDOR/lib/libzstdruby.a" "${RUBY_INC[@]}" -std=c99 \
  -DZSTD_STATIC_LINKING_ONLY -DZSTD_MULTITHREAD -DDEBUGLEVEL=0 -DZSTD_DISABLE_ASM -fvisibility=hidden \
  -I"$Z" -I"$Z/libzstd" -I"$Z/libzstd/common" -I"$Z/libzstd/compress" -I"$Z/libzstd/decompress" -I"$Z/libzstd/dictBuilder" \
  -- $(find "$Z/libzstd" -name '*.c') "$Z"/*.c

# --- nokogiri -------------------------------------------------------------------------
step "$NOKOGIRI"
gem_src "$NOKOGIRI"
N="$WORK/$NOKOGIRI"
compile_all "$WORK/o-nokogiri" "$VENDOR/lib/libnokogiri.a" "${RUBY_INC[@]}" -std=c99 \
  -I"$N/ext/nokogiri" -I"$N/gumbo-parser/src" -I"$PREFIX/include/libxml2" -I"$PREFIX/include" \
  -DNOKOGIRI_STATIC_LIBRARIES -DHAVE_XMLCTXTSETOPTIONS -DHAVE_XMLSWITCHENCODINGNAME -DHAVE_RB_CATEGORY_WARNING \
  -- "$N"/ext/nokogiri/*.c "$N"/gumbo-parser/src/*.c
cp "$PREFIX/lib/libxml2.a" "$PREFIX/lib/libxslt.a" "$PREFIX/lib/libexslt.a" "$VENDOR/lib/"

# --- pure Ruby parts ---------------------------------------------------------------------
step "gem libraries"
GEMLIBS="$VENDOR/gemlibs"
rm -rf "$GEMLIBS" && mkdir -p "$GEMLIBS"
for g in $NOKOGIRI $BIGDECIMAL $ZSTD; do cp -R "$WORK/$g/lib/." "$GEMLIBS/"; done
for g in $PURE_GEMS; do gem_src "$g"; [ -d "$WORK/$g/lib" ] && cp -R "$WORK/$g/lib/." "$GEMLIBS/"; done
# Ruby's bundled gems (csv, rexml, racc, ...): pure Ruby parts only; fiddle and
# bigdecimal already have their own copy.
for gem in "$RUBY_SRC"/gems/*.gem; do
  name="$(basename "$gem" .gem)"
  case "$name" in fiddle-*|bigdecimal-*|win32ole-*|debug-*|rbs-*|typeprof-*|rdoc-*|irb-*|minitest-*|test-unit-*|power_assert-*|rake-*|repl_type_completor-*) continue ;; esac
  rm -rf "$WORK/bg" && mkdir -p "$WORK/bg" && tar xf "$gem" -C "$WORK/bg" && tar xzf "$WORK/bg/data.tar.gz" -C "$WORK/bg"
  [ -d "$WORK/bg/lib" ] && cp -R "$WORK/bg/lib/." "$GEMLIBS/"
done
# nokogiri loads its extension with require_relative, which cannot reach a
# statically linked one (same fix as on iOS).
perl -0pi -e 's{require_relative "\#\{Regexp.last_match\(1\)\}/nokogiri"}{require "\#{Regexp.last_match(1)}/nokogiri"}' "$GEMLIBS/nokogiri/extension.rb"

echo
echo "==> gems for $ABI: $(cd "$VENDOR/lib" && ls libbigdecimal.a libzstdruby.a libnokogiri.a libxml2.a libxslt.a libexslt.a | tr '\n' ' ')"
echo "    gemlibs $(du -sh "$GEMLIBS" | cut -f1)"
