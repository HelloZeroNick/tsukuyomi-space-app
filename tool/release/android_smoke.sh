#!/usr/bin/env bash
set -euo pipefail
mkdir -p artifacts
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell settings put secure show_ime_with_hard_keyboard 1
adb logcat -c || true
adb shell am start -n space.tsukuyomi.tsukuyomi_space_app/.MainActivity
for attempt in $(seq 1 150); do
  adb logcat -d -b main -v brief > artifacts/android-smoke.log 2>&1 || true
  if grep -q 'TSUKUYOMI_GPU_CAPTURE_READY' artifacts/android-smoke.log && [ ! -f artifacts/android-gpu-composition.png ]; then
    adb exec-out screencap -p > artifacts/android-gpu-composition.png
  fi
  if grep -q 'TSUKUYOMI_LIVE2D_OK'  artifacts/android-smoke.log; then
    grep -q 'TSUKUYOMI_LIVE2D_GPU_OK' artifacts/android-smoke.log || { cat artifacts/android-smoke.log; exit 1; }
    adb pull /sdcard/Android/data/space.tsukuyomi.tsukuyomi_space_app/files/live2d-gpu-qa artifacts/live2d-gpu-qa
    grep -q 'TSUKUYOMI_UPDATE_OK' artifacts/android-smoke.log || { cat artifacts/android-smoke.log; exit 1; }
    grep -q 'TSUKUYOMI_GAME_AUDIO_OK' artifacts/android-smoke.log || { cat artifacts/android-smoke.log; exit 1; }
    grep -q 'TSUKUYOMI_GAME_RIDING_OK' artifacts/android-smoke.log || { cat artifacts/android-smoke.log; exit 1; }
    grep -q 'TSUKUYOMI_LIVE2D_RENDER_OK' artifacts/android-smoke.log || { cat artifacts/android-smoke.log; exit 1; }
    grep -q 'TSUKUYOMI_LIVE2D_DETAIL_OK' artifacts/android-smoke.log || { cat artifacts/android-smoke.log; exit 1; }
    grep -q 'TSUKUYOMI_ROOM_IME_OK' artifacts/android-smoke.log || { cat artifacts/android-smoke.log; exit 1; }
    grep -q 'TSUKUYOMI_ROOM_LAZY_OK' artifacts/android-smoke.log || { cat artifacts/android-smoke.log; exit 1; }
    grep -q 'TSUKUYOMI_LIVE2D_BATCH_OK' artifacts/android-smoke.log || { cat artifacts/android-smoke.log; exit 1; }
    grep -q 'TSUKUYOMI_LIVE2D_ASYNC_OK' artifacts/android-smoke.log || { cat artifacts/android-smoke.log; exit 1; }
    grep -q 'TSUKUYOMI_GAME_CONTINUITY_OK' artifacts/android-smoke.log || { cat artifacts/android-smoke.log; exit 1; }
    grep 'TSUKUYOMI_ROOM_IME_OK' artifacts/android-smoke.log
    grep 'TSUKUYOMI_ROOM_LAZY_OK' artifacts/android-smoke.log
    grep 'TSUKUYOMI_LIVE2D_BATCH_OK' artifacts/android-smoke.log
    grep 'TSUKUYOMI_LIVE2D_ASYNC_OK' artifacts/android-smoke.log
    grep 'TSUKUYOMI_GAME_CONTINUITY_OK' artifacts/android-smoke.log
    grep 'TSUKUYOMI_LIVE2D_DETAIL_OK' artifacts/android-smoke.log
    grep 'TSUKUYOMI_LIVE2D_RENDER_OK' artifacts/android-smoke.log
    grep 'TSUKUYOMI_LIVE2D_TIMINGS' artifacts/android-smoke.log
    grep 'TSUKUYOMI_GAME_AUDIO_OK' artifacts/android-smoke.log
    grep 'TSUKUYOMI_GAME_RIDING_OK' artifacts/android-smoke.log
    grep 'TSUKUYOMI_UPDATE_OK' artifacts/android-smoke.log
    grep 'TSUKUYOMI_LIVE2D_OK' artifacts/android-smoke.log
    exit 0
  fi
  if grep -q 'TSUKUYOMI_LIVE2D_FAILED' artifacts/android-smoke.log; then
    cat artifacts/android-smoke.log
    exit 1
  fi
  sleep 2
done
cat artifacts/android-smoke.log
exit 1
