# Cross-compile toolchain for the car computer's aarch64 userspace.
#
# CarDisplay's own cmake/cross.cmake hardcodes /usr/bin/aarch64-linux-gnu-gcc,
# which only exists on Debian-family hosts and is wrong on an aarch64 host
# where the native compiler is already the target compiler. This looks the
# compiler up on PATH instead.
#
# Override with -DCROSS_PREFIX=... or CROSS_COMPILE, the kernel's spelling.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

if(NOT CROSS_PREFIX)
    if(DEFINED ENV{CROSS_COMPILE})
        set(CROSS_PREFIX "$ENV{CROSS_COMPILE}")
    else()
        set(CROSS_PREFIX "aarch64-linux-gnu-")
    endif()
endif()

find_program(CMAKE_C_COMPILER "${CROSS_PREFIX}gcc")
find_program(CMAKE_CXX_COMPILER "${CROSS_PREFIX}g++")

if(NOT CMAKE_C_COMPILER OR NOT CMAKE_CXX_COMPILER)
    message(FATAL_ERROR
        "Could not find ${CROSS_PREFIX}gcc and ${CROSS_PREFIX}g++ on PATH.\n"
        "Install an aarch64 Linux toolchain (Debian/Ubuntu: "
        "apt install crossbuild-essential-arm64) or point CROSS_PREFIX at one.")
endif()

# Libraries and headers come from the target sysroot; programs are host tools.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# CarDisplay reads this to pick the framebuffer backend over SDL.
set(RPI_CROSS ON CACHE BOOL "Target the Pi framebuffer rather than an SDL window")

# The rootfs carries no shared libraries at all, so neither does the app.
# Nothing to copy out of the sysroot, and no boot that fails with a "no such
# file or directory" that really means the dynamic loader is missing.
option(CARCOMPUTER_STATIC "Link the display app statically" ON)
if(CARCOMPUTER_STATIC)
    set(CMAKE_EXE_LINKER_FLAGS_INIT "-static")
endif()
