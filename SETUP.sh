#!/bin/bash
# Prerequisites: node >= 20, npm
npm install
./node_modules/.bin/electron-esbuild build
node esbuild/esbuild.batch.config.js
node esbuild/esbuild.fcmdump.config.js
echo "Ready. Use: npm run batch, npm run fcmdump, npm run dev"
