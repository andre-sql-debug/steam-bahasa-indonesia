#!/bin/sh
# Builds re4_minecraft_overlay.dll with the MinGW-w64 cross compiler (Linux), or MSYS2 on Windows.
set -e
cd "$(dirname "$0")"
x86_64-w64-mingw32-g++ -std=c++17 -O2 -shared -static -static-libgcc -static-libstdc++ \
    -Wall -Wno-unknown-pragmas -o re4_minecraft_overlay.dll overlay_plugin.cpp
x86_64-w64-mingw32-strip re4_minecraft_overlay.dll
echo "built re4_minecraft_overlay.dll"
