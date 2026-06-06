# dist/vcpkg-triplets/zig-macos-toolchain.cmake

if(NOT DEFINED ZIG_TARGET)
  if(DEFINED ENV{ZIG_TARGET})
    set(ZIG_TARGET "$ENV{ZIG_TARGET}")
  elseif(DEFINED VCPKG_TARGET_ARCHITECTURE)
    if(VCPKG_TARGET_ARCHITECTURE STREQUAL "arm64")
      set(ZIG_TARGET aarch64-macos)
    elseif(VCPKG_TARGET_ARCHITECTURE STREQUAL "x64")
      set(ZIG_TARGET x86_64-macos)
    endif()
  endif()
endif()

if(NOT DEFINED ZIG_TARGET)
  message(FATAL_ERROR "Unable to infer Zig macOS target from VCPKG_TARGET_ARCHITECTURE")
endif()

if(DEFINED ENV{SDKROOT})
  set(_MACOS_SDK "$ENV{SDKROOT}")
elseif(DEFINED ENV{MACOSX_SDK})
  set(_MACOS_SDK "$ENV{MACOSX_SDK}")
else()
  message(FATAL_ERROR "Set SDKROOT or MACOSX_SDK to your MacOSX.sdk path")
endif()

if(DEFINED ENV{ZIG})
  set(_ZIG "$ENV{ZIG}")
else()
  set(_ZIG zig)
endif()

if(DEFINED VCPKG_OSX_DEPLOYMENT_TARGET)
  set(_MACOS_DEPLOYMENT_TARGET "${VCPKG_OSX_DEPLOYMENT_TARGET}")
elseif(DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
  set(_MACOS_DEPLOYMENT_TARGET "${CMAKE_OSX_DEPLOYMENT_TARGET}")
elseif(DEFINED ENV{MACOSX_DEPLOYMENT_TARGET})
  set(_MACOS_DEPLOYMENT_TARGET "$ENV{MACOSX_DEPLOYMENT_TARGET}")
else()
  set(_MACOS_DEPLOYMENT_TARGET 11.0)
endif()

if(DEFINED Z_VCPKG_ROOT_DIR AND DEFINED VCPKG_TARGET_TRIPLET)
  set(_ZIG_MACOS_TOOL_DIR "${Z_VCPKG_ROOT_DIR}/buildtrees/zig-macos-tools/${VCPKG_TARGET_TRIPLET}")
elseif(DEFINED _VCPKG_ROOT_DIR AND DEFINED VCPKG_TARGET_TRIPLET)
  set(_ZIG_MACOS_TOOL_DIR "${_VCPKG_ROOT_DIR}/buildtrees/zig-macos-tools/${VCPKG_TARGET_TRIPLET}")
else()
  set(_ZIG_MACOS_TOOL_DIR "${CMAKE_BINARY_DIR}/zig-macos-tools")
endif()
file(MAKE_DIRECTORY "${_ZIG_MACOS_TOOL_DIR}")

if(CMAKE_HOST_WIN32)
  set(_ZIG_CC "${_ZIG_MACOS_TOOL_DIR}/zig-cc.cmd")
  set(_ZIG_CXX "${_ZIG_MACOS_TOOL_DIR}/zig-cxx.cmd")
  set(_ZIG_OBJC "${_ZIG_MACOS_TOOL_DIR}/zig-objc.cmd")
  set(_ZIG_OBJCXX "${_ZIG_MACOS_TOOL_DIR}/zig-objcxx.cmd")
  set(_ZIG_AR "${_ZIG_MACOS_TOOL_DIR}/zig-ar.cmd")
  set(_ZIG_RANLIB "${_ZIG_MACOS_TOOL_DIR}/zig-ranlib.cmd")
  set(_ZIG_STRIP "${_ZIG_MACOS_TOOL_DIR}/zig-strip.cmd")
  set(_ZIG_OBJCOPY "${_ZIG_MACOS_TOOL_DIR}/zig-objcopy.cmd")
  set(_ZIG_OBJDUMP "${_ZIG_MACOS_TOOL_DIR}/zig-objdump.cmd")
  set(_INSTALL_NAME_TOOL "${_ZIG_MACOS_TOOL_DIR}/install_name_tool.cmd")

  # Fontconfig preprocesses this gperf input through the C compiler. Clang
  # rejects it as C, and Meson's generated command leaves a later -c in place.
  file(WRITE "${_ZIG_CC}"
    "@echo off\r\n"
    "setlocal enabledelayedexpansion\r\n"
    "set \"HAS_GPERF=\"\r\n"
    "for %%A in (%*) do (\r\n"
    "  echo %%~A | findstr /C:\"fcobjshash.gperf.h\" >nul && set \"HAS_GPERF=1\"\r\n"
    ")\r\n"
    "if not defined HAS_GPERF (\r\n"
    "  \"${_ZIG}\" cc -target ${ZIG_TARGET} %*\r\n"
    "  exit /b !ERRORLEVEL!\r\n"
    ")\r\n"
    "set \"ARGS=\"\r\n"
    "for %%A in (%*) do (\r\n"
    "  if \"%%~A\"==\"-xc\" (\r\n"
    "    set \"ARGS=!ARGS! -x assembler-with-cpp\"\r\n"
    "  ) else if \"%%~A\"==\"-c\" (\r\n"
    "    rem Keep -E as the active driver action for the gperf preprocessor step.\r\n"
    "  ) else (\r\n"
    "    set \"ARGS=!ARGS! %%A\"\r\n"
    "  )\r\n"
    ")\r\n"
    "\"${_ZIG}\" cc -target ${ZIG_TARGET} !ARGS!\r\n"
    "exit /b !ERRORLEVEL!\r\n"
  )
  file(WRITE "${_ZIG_CXX}" "@echo off\r\n\"${_ZIG}\" c++ -target ${ZIG_TARGET} %*\r\n")
  file(WRITE "${_ZIG_OBJC}" "@echo off\r\n\"${_ZIG}\" cc -target ${ZIG_TARGET} %*\r\n")
  file(WRITE "${_ZIG_OBJCXX}" "@echo off\r\n\"${_ZIG}\" c++ -target ${ZIG_TARGET} %*\r\n")
  file(WRITE "${_ZIG_AR}"
    "@echo off\r\n"
    "setlocal enabledelayedexpansion\r\n"
    "\"${_ZIG}\" ar %*\r\n"
    "set \"ZIG_AR_STATUS=!ERRORLEVEL!\"\r\n"
    "if not \"!ZIG_AR_STATUS!\"==\"0\" exit /b !ZIG_AR_STATUS!\r\n"
    "for %%A in (%*) do (\r\n"
    "  if /I \"%%~nxA\"==\"libicudata.a\" copy /Y \"%%~fA\" \"%%~dpnA.lib\" >nul\r\n"
    ")\r\n"
    "exit /b !ZIG_AR_STATUS!\r\n"
  )
  file(WRITE "${_ZIG_RANLIB}" "@echo off\r\n\"${_ZIG}\" ranlib %*\r\n")
  file(WRITE "${_ZIG_STRIP}" "@echo off\r\n\"${_ZIG}\" strip %*\r\n")
  file(WRITE "${_ZIG_OBJCOPY}" "@echo off\r\n\"${_ZIG}\" objcopy %*\r\n")
  file(WRITE "${_ZIG_OBJDUMP}" "@echo off\r\n\"${_ZIG}\" objdump %*\r\n")
  file(WRITE "${_INSTALL_NAME_TOOL}" "@echo off\r\nexit /b 0\r\n")
else()
  set(_ZIG_CC "${_ZIG_MACOS_TOOL_DIR}/zig-cc")
  set(_ZIG_CXX "${_ZIG_MACOS_TOOL_DIR}/zig-cxx")
  set(_ZIG_OBJC "${_ZIG_MACOS_TOOL_DIR}/zig-objc")
  set(_ZIG_OBJCXX "${_ZIG_MACOS_TOOL_DIR}/zig-objcxx")
  set(_ZIG_AR "${_ZIG_MACOS_TOOL_DIR}/zig-ar")
  set(_ZIG_RANLIB "${_ZIG_MACOS_TOOL_DIR}/zig-ranlib")
  set(_ZIG_STRIP "${_ZIG_MACOS_TOOL_DIR}/zig-strip")
  set(_ZIG_OBJCOPY "${_ZIG_MACOS_TOOL_DIR}/zig-objcopy")
  set(_ZIG_OBJDUMP "${_ZIG_MACOS_TOOL_DIR}/zig-objdump")
  set(_INSTALL_NAME_TOOL "${_ZIG_MACOS_TOOL_DIR}/install_name_tool")

  file(WRITE "${_ZIG_CC}"
    "#!/bin/sh\n"
    "has_gperf=0\n"
    "for arg do\n"
    "  case \"\$arg\" in *fcobjshash.gperf.h*) has_gperf=1 ;; esac\n"
    "done\n"
    "if [ \"\$has_gperf\" -eq 1 ]; then\n"
    "  set -- \$(for arg do if [ \"\$arg\" = -xc ]; then printf '%s\\n' -x assembler-with-cpp; elif [ \"\$arg\" != -c ]; then printf '%s\\n' \"\$arg\"; fi; done)\n"
    "fi\n"
    "exec \"\${ZIG:-zig}\" cc -target ${ZIG_TARGET} \"\$@\"\n"
  )
  file(WRITE "${_ZIG_CXX}" "#!/bin/sh\nexec \"\${ZIG:-zig}\" c++ -target ${ZIG_TARGET} \"$@\"\n")
  file(WRITE "${_ZIG_OBJC}" "#!/bin/sh\nexec \"\${ZIG:-zig}\" cc -target ${ZIG_TARGET} \"$@\"\n")
  file(WRITE "${_ZIG_OBJCXX}" "#!/bin/sh\nexec \"\${ZIG:-zig}\" c++ -target ${ZIG_TARGET} \"$@\"\n")
  file(WRITE "${_ZIG_AR}" "#!/bin/sh\nexec \"\${ZIG:-zig}\" ar \"$@\"\n")
  file(WRITE "${_ZIG_RANLIB}" "#!/bin/sh\nexec \"\${ZIG:-zig}\" ranlib \"$@\"\n")
  file(WRITE "${_ZIG_STRIP}" "#!/bin/sh\nexec \"\${ZIG:-zig}\" strip \"$@\"\n")
  file(WRITE "${_ZIG_OBJCOPY}" "#!/bin/sh\nexec \"\${ZIG:-zig}\" objcopy \"$@\"\n")
  file(WRITE "${_ZIG_OBJDUMP}" "#!/bin/sh\nexec \"\${ZIG:-zig}\" objdump \"$@\"\n")
  file(WRITE "${_INSTALL_NAME_TOOL}" "#!/bin/sh\nexit 0\n")

  file(CHMOD
    "${_ZIG_CC}"
    "${_ZIG_CXX}"
    "${_ZIG_OBJC}"
    "${_ZIG_OBJCXX}"
    "${_ZIG_AR}"
    "${_ZIG_RANLIB}"
    "${_ZIG_STRIP}"
    "${_ZIG_OBJCOPY}"
    "${_ZIG_OBJDUMP}"
    "${_INSTALL_NAME_TOOL}"
    PERMISSIONS
      OWNER_READ OWNER_WRITE OWNER_EXECUTE
      GROUP_READ GROUP_EXECUTE
      WORLD_READ WORLD_EXECUTE
  )
endif()

set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_OSX_SYSROOT "${_MACOS_SDK}" CACHE PATH "")
set(CMAKE_OSX_DEPLOYMENT_TARGET "${_MACOS_DEPLOYMENT_TARGET}" CACHE STRING "")
set(CMAKE_OSX_ARCHITECTURES "${VCPKG_OSX_ARCHITECTURES}" CACHE STRING "")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_AR "${_ZIG_AR}" CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB "${_ZIG_RANLIB}" CACHE FILEPATH "" FORCE)
set(CMAKE_STRIP "${_ZIG_STRIP}" CACHE FILEPATH "" FORCE)
set(CMAKE_OBJCOPY "${_ZIG_OBJCOPY}" CACHE FILEPATH "" FORCE)
set(CMAKE_OBJDUMP "${_ZIG_OBJDUMP}" CACHE FILEPATH "" FORCE)
set(CMAKE_INSTALL_NAME_TOOL "${_INSTALL_NAME_TOOL}" CACHE FILEPATH "" FORCE)
set(CMAKE_EXE_LINKER_FLAGS_INIT "-L${_MACOS_SDK}/usr/lib")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-L${_MACOS_SDK}/usr/lib")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-L${_MACOS_SDK}/usr/lib")
set(CMAKE_C_FLAGS_INIT "-idirafter ${_MACOS_SDK}/usr/include")
set(CMAKE_CXX_FLAGS_INIT "-idirafter ${_MACOS_SDK}/usr/include")
set(CMAKE_OBJC_FLAGS_INIT "-idirafter ${_MACOS_SDK}/usr/include")
set(CMAKE_OBJCXX_FLAGS_INIT "-idirafter ${_MACOS_SDK}/usr/include")

set(CMAKE_C_COMPILER "${_ZIG_CC}" CACHE FILEPATH "" FORCE)
set(CMAKE_CXX_COMPILER "${_ZIG_CXX}" CACHE FILEPATH "" FORCE)
set(CMAKE_OBJC_COMPILER "${_ZIG_OBJC}" CACHE FILEPATH "" FORCE)
set(CMAKE_OBJCXX_COMPILER "${_ZIG_OBJCXX}" CACHE FILEPATH "" FORCE)
