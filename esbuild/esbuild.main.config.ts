import { BuildOptions, Plugin } from 'esbuild'
import coffeeScriptPlugin from 'esbuild-coffeescript'
import * as path from 'path'
import * as fs from 'fs'
import { createRequire } from 'module'
import svg from 'esbuild-plugin-svg';

const _require = createRequire(import.meta.url ?? __filename)

// Civet plugin — compiles .civet files, and resolves .civet.jsx imports
// back to .civet source paths.  Mirrors the renderer-side plugin so main
// and renderer agree on the civet toolchain.
const civetPlugin: Plugin = {
  name: 'civet',
  setup(build) {
    const { compile } = _require('@danielx/civet')
    build.onResolve({ filter: /\.civet\.jsx$/ }, (args) => {
      const resolved = path.resolve(path.dirname(args.importer), args.path.replace(/\.jsx$/, ''))
      return { path: resolved }
    })
    build.onLoad({ filter: /\.civet$/ }, async (args) => {
      const source = await fs.promises.readFile(args.path, 'utf8')
      const filename = path.relative(process.cwd(), args.path)
      const compiled = compile(source, { filename, inlineMap: true, js: true })
      return { contents: compiled, loader: 'js' }
    })
  }
}

const config: BuildOptions = {
  platform: 'node',
  plugins: [
    civetPlugin,
    coffeeScriptPlugin({}),
    svg(),
  ],
  entryPoints: [
    path.resolve('simRunner/main/main.civet'),
    path.resolve('simRunner/main/preload.civet'),
  ],
  loader: {
    '.tsx': 'tsx',
    '.jsx': 'jsx',
    '.ts': 'tsx',
    '.js': 'jsx',
    '.png': 'file',
  },
  resolveExtensions: ['.civet.jsx', '.ts', '.js', '.coffee', '.civet', '.jsx'],
  bundle: true,
  format: 'cjs',
  target: 'node20.6.0',
}

export default config
