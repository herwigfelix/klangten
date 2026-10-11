# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten (package names, klangten*.exe).
cmake_minimum_required(VERSION 3.24)

if(NOT DEFINED MODE)
  message(FATAL_ERROR "MODE is required")
endif()

if(NOT DEFINED RELEASE_ROOT)
  message(FATAL_ERROR "RELEASE_ROOT is required")
endif()

if(NOT DEFINED DIST_DIR)
  message(FATAL_ERROR "DIST_DIR is required")
endif()

if(NOT DEFINED INSTALLER_SCRIPT)
  message(FATAL_ERROR "INSTALLER_SCRIPT is required")
endif()

if(NOT DEFINED TIMESTAMP_URL OR "${TIMESTAMP_URL}" STREQUAL "")
  set(TIMESTAMP_URL "http://time.certum.pl")
endif()

set(APP_DIR "${DIST_DIR}/Klangten")
set(INSTALLER_BASENAME "KlangtenSetup")
set(INSTALLER_PATH "${DIST_DIR}/${INSTALLER_BASENAME}.exe")

function(run_checked)
  execute_process(
    COMMAND ${ARGV}
    RESULT_VARIABLE result
    OUTPUT_VARIABLE output
    ERROR_VARIABLE error
  )
  if(output)
    string(STRIP "${output}" output)
    if(output)
      message(STATUS "${output}")
    endif()
  endif()
  if(NOT result EQUAL 0)
    if(error)
      string(STRIP "${error}" error)
    endif()
    message(FATAL_ERROR "Command failed (${result}): ${ARGV}\n${error}")
  endif()
endfunction()

function(resolve_signtool out_var)
  if(DEFINED SIGNTOOL AND NOT "${SIGNTOOL}" STREQUAL "")
    if(EXISTS "${SIGNTOOL}")
      set(${out_var} "${SIGNTOOL}" PARENT_SCOPE)
      return()
    endif()
    message(FATAL_ERROR "signtool not found: ${SIGNTOOL}")
  endif()

  find_program(found_signtool NAMES signtool.exe signtool)
  if(found_signtool)
    set(${out_var} "${found_signtool}" PARENT_SCOPE)
    return()
  endif()

  file(GLOB candidates
    "C:/Program Files (x86)/Windows Kits/10/bin/*/x64/signtool.exe"
    "C:/Program Files/Windows Kits/10/bin/*/x64/signtool.exe"
  )
  if(candidates)
    list(SORT candidates COMPARE NATURAL ORDER DESCENDING)
    list(GET candidates 0 found_signtool)
    if(found_signtool)
      set(${out_var} "${found_signtool}" PARENT_SCOPE)
      return()
    endif()
  endif()

  message(FATAL_ERROR "signtool.exe not found")
endfunction()

function(sign_file target_path)
  if(NOT SIGN)
    return()
  endif()
  if(NOT EXISTS "${target_path}")
    message(FATAL_ERROR "Cannot sign missing file: ${target_path}")
  endif()
  resolve_signtool(signtool_path)
  message(STATUS "Signing ${target_path}...")
  run_checked(
    "${signtool_path}" sign
    /fd SHA256
    /td SHA256
    /tr "${TIMESTAMP_URL}"
    /a
    "${target_path}"
  )
endfunction()

function(resolve_iscc out_var)
  find_program(found_iscc
    NAMES ISCC.exe iscc.exe iscc
    HINTS
      "C:/Program Files (x86)/Inno Setup 6"
      "C:/Program Files/Inno Setup 6"
  )
  if(NOT found_iscc)
    message(FATAL_ERROR "Inno Setup compiler not found. Install Inno Setup 6 or add ISCC.exe to PATH.")
  endif()
  set(${out_var} "${found_iscc}" PARENT_SCOPE)
endfunction()

function(require_release_file relative_path)
  if(NOT EXISTS "${RELEASE_ROOT}/${relative_path}")
    message(FATAL_ERROR "Missing release file: ${RELEASE_ROOT}/${relative_path}. Build x64, x86 and arm64 launchers first.")
  endif()
endfunction()

# Klangten: the ARM64 launcher is optional. Its Ruby runtime can only be prepared on
# an ARM64 host, and the facade (klangten.exe) falls back to klangten-x64.exe on ARM64
# Windows, which runs under x64 emulation.
#
# Up to 0.3 the programs had Elten's names (elten.exe, elten-x86.exe, ...). A
# release tree or bin/ext directory left over from such a build must not ship
# them next to the new ones, so they are removed from the copy.
set(KLANGTEN_LEGACY_PROGRAMS
  elten.exe
  elten-x86.exe
  elten-x64.exe
  elten-arm64.exe
  bin/ext/windows/EltenSapiBridge32.exe
  bin/ext/windows/EltenSapiBridge64.exe
)

function(create_dist)
  require_release_file("klangten.exe")
  require_release_file("klangten-x86.exe")
  require_release_file("klangten-x64.exe")
  if(NOT EXISTS "${RELEASE_ROOT}/klangten-arm64.exe")
    message(STATUS "klangten-arm64.exe not built; ARM64 Windows will use the x64 launcher via emulation")
  endif()

  message(STATUS "Creating ${APP_DIR}...")
  file(REMOVE_RECURSE "${APP_DIR}")
  file(MAKE_DIRECTORY "${DIST_DIR}" "${APP_DIR}")
  file(COPY "${RELEASE_ROOT}/" DESTINATION "${APP_DIR}")
  file(REMOVE_RECURSE "${APP_DIR}/tmp")
  foreach(legacy_program IN LISTS KLANGTEN_LEGACY_PROGRAMS)
    if(EXISTS "${APP_DIR}/${legacy_program}")
      message(STATUS "Leaving out the old ${legacy_program}")
      file(REMOVE "${APP_DIR}/${legacy_program}")
    endif()
  endforeach()

  sign_file("${APP_DIR}/klangten.exe")
  sign_file("${APP_DIR}/klangten-x86.exe")
  sign_file("${APP_DIR}/klangten-x64.exe")
  if(EXISTS "${APP_DIR}/klangten-arm64.exe")
    sign_file("${APP_DIR}/klangten-arm64.exe")
  endif()
  if(EXISTS "${APP_DIR}/bin/ext/windows/KlangtenSapiBridge32.exe")
    sign_file("${APP_DIR}/bin/ext/windows/KlangtenSapiBridge32.exe")
  endif()
  if(EXISTS "${APP_DIR}/bin/ext/windows/KlangtenSapiBridge64.exe")
    sign_file("${APP_DIR}/bin/ext/windows/KlangtenSapiBridge64.exe")
  endif()
endfunction()

function(create_installer)
  if(NOT EXISTS "${APP_DIR}/klangten.exe" OR NOT EXISTS "${APP_DIR}/klangten-x86.exe" OR NOT EXISTS "${APP_DIR}/klangten-x64.exe")
    create_dist()
  endif()

  if(NOT EXISTS "${INSTALLER_SCRIPT}")
    message(FATAL_ERROR "Installer script not found: ${INSTALLER_SCRIPT}")
  endif()

  resolve_iscc(iscc_path)
  file(REMOVE "${INSTALLER_PATH}")
  file(TO_NATIVE_PATH "${APP_DIR}" source_dir)
  file(TO_NATIVE_PATH "${DIST_DIR}" output_dir)
  message(STATUS "Creating ${INSTALLER_PATH}...")
  run_checked(
    "${iscc_path}"
    "/DSourceDir=${source_dir}"
    "/DOutputDir=${output_dir}"
    "/DOutputBaseFilename=${INSTALLER_BASENAME}"
    "${INSTALLER_SCRIPT}"
  )

  sign_file("${INSTALLER_PATH}")
  message(STATUS "Built ${INSTALLER_PATH}")
endfunction()

if(MODE STREQUAL "CREATE_DIST")
  create_dist()
elseif(MODE STREQUAL "CREATE_INSTALLER")
  create_installer()
else()
  message(FATAL_ERROR "Unknown MODE: ${MODE}")
endif()
