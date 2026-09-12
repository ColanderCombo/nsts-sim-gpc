import { BuildOptions, Plugin } from 'esbuild'
import coffeeScriptPlugin from 'esbuild-coffeescript';
import svg from 'esbuild-plugin-svg';
import {wasmLoader} from 'esbuild-plugin-wasm'
import * as path from 'path'
import * as fs from 'fs'
import { createRequire } from 'module'

const _require = createRequire(import.meta.url ?? __filename)

// The source root is NSTS_SRC_ROOT, or the tree this file sits in; cmake
// runs electron-esbuild from the build directory, so nothing here may be
// relative to the working directory.
const ROOT = process.env.NSTS_SRC_ROOT
  ? path.resolve(process.env.NSTS_SRC_ROOT)
  : path.resolve(__dirname, '..', '..')

// The @danielx/civet/esbuild plugin handles .civet.jsx resolution and JSX
// loading internally, but it pulls in @typescript/vfs which calls
// localStorage.getItem() and crashes on Node 25+. The @danielx/civet/esbuild-plugin
// variant avoids this but doesn't set loader:'jsx' on its onLoad results and
// doesn't resolve .civet.jsx imports. This custom plugin handles both.
const civetPlugin: Plugin = {
  name: 'civet',
  setup(build) {
    const { compile } = _require('@danielx/civet')

    // Resolve .civet.jsx imports back to .civet source files
    build.onResolve({ filter: /\.civet\.jsx$/ }, (args) => {
      const resolved = path.resolve(path.dirname(args.importer), args.path.replace(/\.jsx$/, ''))
      return { path: resolved }
    })

    // Compile .civet files and return as JSX
    build.onLoad({ filter: /\.civet$/ }, async (args) => {
      const source = await fs.promises.readFile(args.path, 'utf8')
      const filename = path.relative(ROOT, args.path)
      const compiled = compile(source, { filename, inlineMap: true, js: true })
      return { contents: compiled, loader: 'jsx' }
    })
  }
}

const config: BuildOptions = {
  platform: 'browser',
  keepNames: true, // Checkpoint adapters identify model classes across launches.
  jsxFragment: "Fragment",
  jsx: "automatic",
  plugins: [
    civetPlugin,
    coffeeScriptPlugin({
      transpile: {presets: ["@babel/react"]}
    }),
    wasmLoader({mode:'deferred'}),
    svg(),
  ],
  entryPoints: [
    path.resolve(ROOT, 'src/com/lru.civet'),
    path.resolve(ROOT, 'src/simRunner/renderer/startup.civet'),
  ],
  loader: {
    '.tsx': 'tsx',
    '.jsx': 'jsx',
    '.ts': 'tsx',
    '.js': 'jsx',
    '.png': 'dataurl',
    '.wasm': 'file',
    '.jpg': 'file',
  },
  resolveExtensions: ['.civet.jsx', '.ts', '.js', '.coffee', '.civet', '.jsx'],
  publicPath: './',
  bundle: true,
  target: 'chrome118',
  format: 'esm'
}

export default config
