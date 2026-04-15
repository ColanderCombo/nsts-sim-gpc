const esbuild = require('esbuild')
const coffeeScriptPlugin = require('esbuild-coffeescript')
const path = require('path')
const fs = require('fs')

// Civet plugin for CJS builds — compiles .civet files to JS
const civetPlugin = {
  name: 'civet',
  setup(build) {
    const { compile } = require('@danielx/civet')
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

async function main() {
  try {
    await esbuild.build({
      platform: 'node',
      entryPoints: [path.resolve('gpc/cli.coffee')],
      bundle: true,
      format: 'cjs',
      target: 'node20',
      outfile: 'dist/gpc.js',
      plugins: [
        civetPlugin,
        coffeeScriptPlugin({}),
      ],
      resolveExtensions: ['.coffee', '.js', '.ts', '.civet', '.json'],
      external: ['dgram', 'electron'],
      logLevel: 'info',
    })
  } catch (e) {
    console.error(e)
    process.exit(1)
  }
}

main()
