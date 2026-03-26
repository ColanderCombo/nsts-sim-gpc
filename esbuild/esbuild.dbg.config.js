const esbuild = require('esbuild')
const coffeeScriptPlugin = require('esbuild-coffeescript')
const path = require('path')

async function main() {
  try {
    await esbuild.build({
      platform: 'node',
      entryPoints: [path.resolve('gpc/run_dbg.coffee')],
      bundle: true,
      format: 'cjs',
      target: 'node20',
      outfile: 'dist/gpc-dbg.js',
      plugins: [
        coffeeScriptPlugin({}),
      ],
      resolveExtensions: ['.coffee', '.js', '.ts', '.json'],
      external: ['dgram', 'electron'],
      logLevel: 'info',
    })
  } catch (e) {
    console.error(e)
    process.exit(1)
  }
}

main()
