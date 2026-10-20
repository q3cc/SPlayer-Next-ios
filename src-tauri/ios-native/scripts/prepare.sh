#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
node src-tauri/ios-native/scripts/prepare-services.mjs
VITE_MOBILE_TARGET=ios pnpm exec vite build --config vite.native.config.ts --mode mobile
VITE_MOBILE_TARGET=ios pnpm exec vite build --config vite.native-plugin.config.ts --mode mobile
