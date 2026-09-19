# Klangten for Android (GNU GPL v3). See docs/android.md.
#
# libklangten.so = JNI entry + the static Ruby runtime from
# android/vendor/<abi> (scripts/build-runtime.sh).
cmake_minimum_required(VERSION 3.22.1)
project(klangten C)

set(VENDOR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../vendor/${ANDROID_ABI}")
if(NOT EXISTS "${VENDOR}/lib/libruby-static.a")
  message(FATAL_ERROR "Ruby runtime missing: run android/scripts/build-runtime.sh (ABI=${ANDROID_ABI})")
endif()

add_library(klangten SHARED klangten_jni.c)
target_include_directories(klangten PRIVATE "${VENDOR}/include")

file(GLOB RUBY_EXT_ARCHIVES "${VENDOR}/lib/ext_*.a" "${VENDOR}/lib/enc_*.a")
target_link_libraries(klangten PRIVATE
  "${VENDOR}/lib/extinit.o"
  "${VENDOR}/lib/encinit.o"
  -Wl,--start-group
  "${VENDOR}/lib/libruby-static.a"
  ${RUBY_EXT_ARCHIVES}
  "${VENDOR}/lib/libfiddle.a"
  -Wl,--end-group
  "${VENDOR}/lib/libffi.a"
  "${VENDOR}/lib/libyaml.a"
  "${VENDOR}/lib/libssl.a"
  "${VENDOR}/lib/libcrypto.a"
  z m dl log)
# 16 KB pages (required for new apps on Google Play, harmless elsewhere).
target_link_options(klangten PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,--gc-sections")
