#!/bin/sh
# BorosKit: read-only portability check for the plain C / C++ cores (Vulkan engine kickoff, 2026-11-24).
# Original BorosKit code written for this project; contains no third-party code.
#
# What: compiles every plain-C core (*.c) as strict C99 and every C++ core (*.cpp) as C++17 with the
#       portable thread path, syntax-only, and lists any header that comes from Apple (simd, dispatch,
#       frameworks, Objective-C) or is not available on Windows (pthread). Writes nothing anywhere.
# Why:  the Vulkan engine reuses these cores on Windows / Linux; an Apple header in a core means it
#       will not build there (VULKAN-PORT-PLAN.md rule 1 / section 14).
# Use:  sh docs/tools/check-portable-cores.sh            (from the BorosKit folder)
# Exit: 0 = every core is clean, 1 = at least one problem (printed).
cd "$(dirname "$0")/../.." || exit 2
INC=""
for d in Sources/*/include Sources/*; do [ -d "$d" ] && INC="$INC -I$d"; done
BAD='simd/|dispatch/|\.framework/|objc/|Foundation|CoreGraphics|Metal|pthread\.h|TargetConditionals'
fail=0
for f in $(find Sources -name '*.c' | sort); do
  out=$(clang -std=c99 -pedantic -Werror -fno-modules -fsyntax-only -H $INC "$f" 2>&1)
  st=$?
  # 2026-11-25 (vulkan-engine M2): again with the plain-struct GPU types (BKGPUTypes.h), i.e. what GCC /
  # plain MSVC see: proves no core uses clang-only vector arithmetic on bk_float2 / bk_float4.
  if [ $st -eq 0 ]; then
    out2=$(clang -std=c99 -pedantic -Werror -fno-modules -fsyntax-only -DBK_GPU_TYPES_PORTABLE_STRUCTS=1 $INC "$f" 2>&1)
    st=$?; [ $st -ne 0 ] && out="$out
$out2"
  fi
  apple=$(printf '%s\n' "$out" | grep -E '^\.+ ' | grep -E "$BAD" | sed 's/^\.* //' | sort -u | tr '\n' ' ')
  errs=$(printf '%s\n' "$out" | grep -E 'error:' | head -3)
  if [ $st -ne 0 ] || [ -n "$apple" ]; then fail=1; echo "PROBLEM  $f"; [ -n "$apple" ] && echo "   non-portable headers: $apple"; [ -n "$errs" ] && echo "$errs" | sed 's/^/   /'
  else echo "ok       $f"; fi
done
# C++: <thread> reaches pthread.h inside the standard library on Unix; that is fine (std::thread is portable).
# The Vulkan backend (Sources/BorosKitGPUVulkan) is not a core: it needs the Vulkan SDK headers (CMake builds it).
for f in $(find Sources -name '*.cpp' -not -path 'Sources/BorosKitGPUVulkan/*' | sort); do
  out=$(clang++ -std=c++17 -DBK_PARALLEL_USE_STD_THREAD=1 -Werror -fno-modules -fsyntax-only -H $INC "$f" 2>&1)
  st=$?
  apple=$(printf '%s\n' "$out" | grep -E '^\.+ ' | grep -v 'pthread' | grep -E "$BAD" | sed 's/^\.* //' | sort -u | tr '\n' ' ')
  errs=$(printf '%s\n' "$out" | grep -E 'error:' | head -3)
  if [ $st -ne 0 ] || [ -n "$apple" ]; then fail=1; echo "PROBLEM  $f"; [ -n "$apple" ] && echo "   non-portable headers: $apple"; [ -n "$errs" ] && echo "$errs" | sed 's/^/   /'
  else echo "ok       $f"; fi
done
exit $fail
