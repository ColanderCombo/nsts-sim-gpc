#!/bin/bash
# Prerequisites: node >= 20, npm
npm install
./node_modules/.bin/electron-esbuild build
node esbuild/esbuild.gpc.config.js
echo "Ready. Use: ./GPC.sh {run,debug,gui,dump,disasm} [fcm-file] [options]"
