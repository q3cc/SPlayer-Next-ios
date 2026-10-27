#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
node src-tauri/ios-native/scripts/prepare-fluid.mjs
node src-tauri/ios-native/scripts/prepare-services.mjs
VITE_MOBILE_TARGET=ios pnpm exec vite build --config vite.native.config.ts --mode mobile
VITE_MOBILE_TARGET=ios pnpm exec vite build --config vite.native-plugin.config.ts --mode mobile
# 关于页的环境信息：与 main 的 __COMMIT_HASH__ / __COMMIT_DATE__ 取值一致
printf '{"commit":"%s","date":"%s"}\n' \
  "$(git rev-parse HEAD 2>/dev/null | cut -c1-7 || echo unknown)" \
  "$(git log -1 --format=%cI 2>/dev/null || echo unknown)" \
  > src-tauri/ios-native/Sources/SPlayerNativeUI/Resources/build-info.json
