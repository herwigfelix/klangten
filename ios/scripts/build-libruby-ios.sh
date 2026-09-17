#!/usr/bin/env bash
# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Elten is free software: GNU General Public License v3.
#
# Cross-compile a static CRuby for iOS into ios/Klangten/vendor/ruby.
#
# STATUS (verified in this repo):
#   * The cross-configure below WORKS: it produces a correct iOS build config
#     and the CRuby core cross-compiles to genuine iOS objects
#     (Mach-O arm64, platform = iOS Simulator, minos 16.0).
#   * Completing the build additionally requires a small SOURCE PATCH SET for
#     macOS-vs-iOS divergences (Ruby assumes __APPLE__ == macOS in several C
#     files). The first ones are applied by apply_ios_patches() below; the known
#     remaining walls are documented at the bottom. This is the same reason the
#     community maintains ruby-on-ios patch sets rather than a one-shot build.
#
# Usage: SDK=iphonesimulator ARCH=arm64 RUBY_VERSION=3.4.9 ./build-libruby-ios.sh
set -euo pipefail

RUBY_VERSION="${RUBY_VERSION:-3.4.9}"
SDK="${SDK:-iphonesimulator}"          # iphoneos | iphonesimulator
ARCH="${ARCH:-arm64}"
MIN_IOS="${MIN_IOS:-16.0}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/Klangten/vendor/ruby"
WORK="${WORK:-$(mktemp -d)}"

SDKROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CLANG="$(xcrun --sdk "$SDK" -f clang)"
if [ "$SDK" = "iphonesimulator" ]; then
  TARGET="${ARCH}-apple-ios${MIN_IOS}-simulator"
else
  TARGET="${ARCH}-apple-ios${MIN_IOS}"
fi

echo "==> Ruby ${RUBY_VERSION} for ${TARGET}"

cd "$WORK"
[ -f "ruby-${RUBY_VERSION}.tar.gz" ] || \
  curl -fsSLO "https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/ruby-${RUBY_VERSION}.tar.gz"
rm -rf "ruby-${RUBY_VERSION}"
tar xzf "ruby-${RUBY_VERSION}.tar.gz"
cd "ruby-${RUBY_VERSION}"

apply_ios_patches() {
  # dir.c: iOS SDK has no <sys/vnode.h>; provide the vtype/vtagtype constants
  # dir.c needs when the header is absent.
  perl -0pi -e 's{# include <sys/vnode\.h>}{# if __has_include(<sys/vnode.h>)\n#  include <sys/vnode.h>\n# else\nenum vtype { VNON, VREG, VDIR, VBLK, VCHR, VLNK, VSOCK, VFIFO, VBAD, VSTR, VCPLX };\nenum vtagtype { VT_NON, VT_UFS, VT_NFS, VT_MFS, VT_MSDOSFS, VT_LFS, VT_LOFS, VT_FDESC, VT_PORTAL, VT_NULL, VT_UMAP, VT_KERNFS, VT_PROCFS, VT_AFS, VT_ISOFS, VT_MOCKFS, VT_HFS, VT_ZFS, VT_DEVFS, VT_WEBDAV, VT_UDF, VT_AFP, VT_CDDA, VT_CIFS, VT_OTHER };\n# endif}' dir.c
  # TODO (see NOTES): file.c CoreFoundation version-gated helpers, process.c
  # fork/exec removal, thread_pthread signal handling.
}
apply_ios_patches

export CC="$CLANG -target $TARGET -isysroot $SDKROOT"
export CPP="$CLANG -target $TARGET -isysroot $SDKROOT -E"
export CFLAGS="-O1 -fno-common"
export LDFLAGS="-target $TARGET -isysroot $SDKROOT"

BASERUBY="${BASERUBY:-$(command -v ruby)}"

# KEY CROSS-COMPILE FIX: iOS uses the same "darwin" triple as macOS, so autoconf
# cannot tell target from host and tries to RUN the iOS test binary (which fails
# on the Mac). Use a syntactically different --host triple (arm-apple-darwin) and
# force cross_compiling=yes so autoconf uses compile-only feature checks.
./configure \
  --build=aarch64-apple-darwin \
  --host=arm-apple-darwin \
  --with-baseruby="${BASERUBY}" \
  --prefix="${OUT}" \
  --disable-shared --disable-install-doc \
  --disable-yjit --disable-rjit \
  --without-gmp \
  --with-static-linked-ext \
  --with-out-ext=openssl,readline,gdbm,dbm,win32,win32ole,-test-/win32 \
  cross_compiling=yes \
  ac_cv_func_fork=no ac_cv_func_vfork=no ac_cv_func_system=no \
  ac_cv_func_daemon=no ac_cv_func_setpgrp=no ac_cv_func_getpgrp=no \
  ac_cv_func_dlopen=yes

make -j"$(sysctl -n hw.ncpu)" || {
  cat <<'NOTES'
!! Build stopped at a macOS-vs-iOS source divergence.

   Known walls (patch each like dir.c in apply_ios_patches):
     * file.c   - CoreFoundation helpers (mutable_CFString_new) are defined
                  behind a macOS-version gate that is false on the iOS SDK while
                  the call sites stay active. Gate the definitions on the same
                  condition, or provide iOS equivalents.
     * process.c- fork/exec/posix_spawn paths; iOS forbids process spawning.
                  Stub the spawn paths (Elten's iOS childprocess layer already
                  refuses them at the Ruby level).
     * thread_pthread.c / signal.c - iOS signal + thread differences.
     * fiddle   - needs libffi built for iOS (essential: Elten's platform layer
                  is Fiddle-based). Build libffi.a for the SDK first and point
                  extconf at it.
     * openssl  - needs an iOS OpenSSL (or switch TLS to Network.framework).

   Each is individually tractable; together they are the multi-day, patch-set
   maintained effort that ruby-on-ios forks exist to carry.
NOTES
  exit 1
}
make install
echo "==> Installed static libruby to ${OUT}"
