# Cross-compile toolchain for Android arm64-v8a from a non-x86_64 Linux host
# (e.g. this Jetson, aarch64). Google's official NDK ships toolchain binaries
# for linux-x86_64 only (confirmed by inspecting an NDK r29 download's ELF
# headers -- they will not execute on an aarch64 host). Uses the host's own
# native clang (any reasonably recent LLVM understands Android target
# triples) pointed at the NDK's sysroot, which is just data (headers +
# target-arch libc stubs), not host binaries.
#
# Deliberately sets CMAKE_SYSTEM_NAME to Linux rather than Android: CMake's
# built-in Android platform support tries to locate and invoke the NDK's own
# (non-executable-here) toolchain binaries under
# toolchains/llvm/prebuilt/linux-x86_64/, hitting the same wall we're
# routing around. The ANDROID CMake variable is set directly below instead,
# purely so this project's own `if (NOT ... AND NOT ANDROID)` conditionals
# (e.g. skipping host libnuma/libatomic detection in the top-level
# CMakeLists.txt, which would otherwise incorrectly pick up the build host's
# own libraries instead of correctly finding nothing on Android) behave
# correctly.
#
# Required cache variables (set by the caller, e.g. via -D or before
# include()):
#   ANDROID_NDK_ROOT      path to the Android NDK
# Optional:
#   ANDROID_PLATFORM_LEVEL  Android API level (default 24)

if(COMMAND toolchain_save_config)
  return() # prevent recursive call
endif()

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_VERSION 1)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(ANDROID TRUE CACHE BOOL "" FORCE)
set(ANDROID_ABI "arm64-v8a" CACHE STRING "" FORCE)

# CMake's own internal try_compile() sanity checks (run to verify the
# compiler works) execute in a separate scratch build directory with its own
# cache, which does NOT automatically inherit custom -D cache variables from
# the outer build -- only specific CMAKE_* variables get propagated there.
# Falling back to the environment variable sidesteps that entirely, since
# environment is inherited by any child process regardless of CMake's cache
# scoping; build.rs sets this in the process environment already (it also
# passes it as a CACHE variable via -D for a normal invocation, but that
# alone is not enough to survive the nested try_compile step).
if(NOT DEFINED ANDROID_NDK_ROOT)
  if(DEFINED ENV{ANDROID_NDK_ROOT})
    set(ANDROID_NDK_ROOT "$ENV{ANDROID_NDK_ROOT}")
  else()
    message(FATAL_ERROR "ANDROID_NDK_ROOT must be set (path to the Android NDK), as a CMake variable or environment variable")
  endif()
endif()
if(NOT DEFINED ANDROID_PLATFORM_LEVEL)
  if(DEFINED ENV{ANDROID_PLATFORM_LEVEL})
    set(ANDROID_PLATFORM_LEVEL "$ENV{ANDROID_PLATFORM_LEVEL}")
  else()
    set(ANDROID_PLATFORM_LEVEL 24)
  endif()
endif()

set(_ndk_host_prebuilt "${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64")
set(_ndk_sysroot "${_ndk_host_prebuilt}/sysroot")
set(_ndk_resource_dir "${_ndk_host_prebuilt}/lib/clang/21")

if(NOT EXISTS "${_ndk_sysroot}")
  message(FATAL_ERROR "NDK sysroot not found at ${_ndk_sysroot} -- check ANDROID_NDK_ROOT")
endif()

# NOTE: deliberately NOT using -resource-dir=${_ndk_resource_dir} here. The
# NDK ships arm_neon.h (and other builtin headers) written against its own
# bundled clang version; running them through a different system clang
# version hits real incompatibilities (e.g. FP8/mfloat8 NEON intrinsics
# clang 18 does not know about). The two binary runtime archives Android
# needs (libclang_rt.builtins-aarch64-android.a, libunwind.a) are pre-compiled
# machine code with no such version sensitivity, so they were copied once
# into system clang's own resource dir instead -- see setup notes. Compile-only sanity check during CMake's own compiler detection: a full
# executable link pulls in Android's crt objects/entry point machinery,
# which isn't necessary just to prove the compiler works, and keeps this
# check independent of runtime-loader specifics.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# Deliberately NOT a plain PATH search (find_program(... NAMES clang)):
# quictls/OpenSSL's own Configure script (invoked as a sub-build of this same
# project, sharing this process's PATH) does its own independent Android
# toolchain discovery that expects the NDK's toolchain bin/ directory to
# appear ahead of anything else in PATH -- but a plain PATH search here would
# then find the NDK's own (non-executable-here) clang first too. Pinning
# this lookup to /usr/bin directly sidesteps the conflict: this toolchain
# file's own compiler choice no longer depends on PATH order at all, so the
# caller is free to put the NDK's bin/ first in PATH for OpenSSL's benefit.
find_program(CMAKE_C_COMPILER NAMES clang PATHS /usr/bin NO_DEFAULT_PATH)
find_program(CMAKE_CXX_COMPILER NAMES clang++ PATHS /usr/bin NO_DEFAULT_PATH)
if(NOT CMAKE_C_COMPILER)
  message(FATAL_ERROR "clang not found at /usr/bin -- install it (e.g. apt install clang lld), or adjust this toolchain file if system clang lives elsewhere")
endif()

find_program(CMAKE_AR NAMES ar PATHS /usr/bin NO_DEFAULT_PATH)
find_program(CMAKE_RANLIB NAMES ranlib PATHS /usr/bin NO_DEFAULT_PATH)

# --unwindlib and -fuse-ld are link-only flags; this project builds with
# -Werror, which turns clang's harmless "unused argument" warning for them
# during a compile-only (-c) step into a hard failure. Keep compile and link
# flags separate.
set(_android_compile_flags "--target=aarch64-linux-android${ANDROID_PLATFORM_LEVEL} --sysroot=${_ndk_sysroot} --rtlib=compiler-rt")
set(_android_link_flags "${_android_compile_flags} --unwindlib=libunwind -fuse-ld=lld")

set(CMAKE_C_FLAGS "${_android_compile_flags}" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS "${_android_compile_flags}" CACHE STRING "" FORCE)
set(CMAKE_EXE_LINKER_FLAGS "${_android_link_flags}" CACHE STRING "" FORCE)
set(CMAKE_SHARED_LINKER_FLAGS "${_android_link_flags}" CACHE STRING "" FORCE)

set(CMAKE_FIND_ROOT_PATH ${_ndk_sysroot})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
