#!/bin/bash
# GPC interactive debugger — launches Electron GUI
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${DIR}" && ./node_modules/.bin/electron-esbuild build && node esbuild/esbuild.batch.config.js && node esbuild/esbuild.fcmdump.config.js && exec ./node_modules/.bin/electron dist/main/main.js --fcm "$@"
