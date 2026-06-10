#!/usr/bin/env bash
# Build eqgfx.dll (x64 PE) with the msvc-wine toolchain, matching the LuaJIT
# module build flow in .vscode/msvc-wine-luajit-build.md.
#
# eqgfx.dll bakes in NO game offsets and depends on NO external libs beyond the
# Windows CRT, so this is a one-shot self-contained compile. It links nothing
# from eqlib - the live render pointer arrives at runtime from Lua.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE}"

# Point this at your msvc-wine install (https://github.com/mstorsjo/msvc-wine).
# Override with:  MSVC_ROOT=/path/to/msvc ./build_eqgfx.sh
MSVC_ROOT="${MSVC_ROOT:-$HOME/opt/msvc}"

# Speed: silence all Wine debug channels (kills the bcrypt fixme spam + logging
# overhead) and keep wineserver resident so cl.exe/link.exe don't cold-start
# the prefix each invocation.
export WINEDEBUG=-all
wineserver -p 2>/dev/null || true

source "$MSVC_ROOT/bin/x64/msvcenv.sh"
export PATH="$MSVC_ROOT/bin/x64:$PATH"

# Critical WINEPATH fix (see msvc-wine-luajit-build.md): child processes need z:
FIXED_WINEPATH=""
IFS=';' read -ra WP_PARTS <<< "$WINEPATH"
for part in "${WP_PARTS[@]}"; do
    if [[ "$part" != z:* && "$part" != Z:* ]]; then
        part="z:$part"
    fi
    FIXED_WINEPATH="${FIXED_WINEPATH:+$FIXED_WINEPATH;}$part"
done
export WINEPATH="$FIXED_WINEPATH"

# /MT static CRT to match MQ; /EHsc for C++; /LD builds a DLL.
wine cl /nologo /O2 /MT /EHsc /std:c++17 /W3 /D_CRT_SECURE_NO_DEPRECATE \
    /LD "z:${HERE}/eqgfx.cpp" \
    /link /MACHINE:X64 /OUT:"z:${OUT}/eqgfx.dll"

echo "Built: ${OUT}/eqgfx.dll"
file "${OUT}/eqgfx.dll" 2>/dev/null || true
