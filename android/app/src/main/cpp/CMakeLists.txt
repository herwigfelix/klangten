# Klangten for Android (GNU GPL v3). See docs/android.md.
#
# libklangten.so = JNI entry, the elten_host_* bridge and the static Ruby
# runtime plus gems from android/vendor/<abi> (scripts/build-runtime.sh,
# scripts/build-gems.sh).
cmake_minimum_required(VERSION 3.22.1)
project(klangten C)

set(VENDOR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../vendor/${ANDROID_ABI}")
if(NOT EXISTS "${VENDOR}/lib/libruby-static.a")
  message(FATAL_ERROR "Ruby runtime missing: run android/scripts/build-runtime.sh (ABI=${ANDROID_ABI})")
endif()

add_library(klangten SHARED klangten_jni.c host_bridge.c)
target_include_directories(klangten PRIVATE "${VENDOR}/include")

file(GLOB RUBY_EXT_ARCHIVES "${VENDOR}/lib/ext_*.a" "${VENDOR}/lib/enc_*.a")
target_link_libraries(klangten PRIVATE
  "${VENDOR}/lib/extinit.o"
  "${VENDOR}/lib/encinit.o"
  -Wl,--start-group
  "${VENDOR}/lib/libruby-static.a"
  ${RUBY_EXT_ARCHIVES}
  "${VENDOR}/lib/libfiddle.a"
  "${VENDOR}/lib/libbigdecimal.a"
  "${VENDOR}/lib/libzstdruby.a"
  "${VENDOR}/lib/libnokogiri.a"
  "${VENDOR}/lib/libexslt.a"
  "${VENDOR}/lib/libxslt.a"
  "${VENDOR}/lib/libxml2.a"
  -Wl,--end-group
  "${VENDOR}/lib/libffi.a"
  "${VENDOR}/lib/libyaml.a"
  "${VENDOR}/lib/libssl.a"
  "${VENDOR}/lib/libcrypto.a"
  z m dl log)
# 16 KB pages (required for new apps on Google Play, harmless elsewhere).
# The bridge is looked up by Fiddle at run time, so its symbols must survive
# --gc-sections and stay in the dynamic symbol table.
target_link_options(klangten PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,--gc-sections" "-Wl,--export-dynamic-symbol=elten_host_*")
