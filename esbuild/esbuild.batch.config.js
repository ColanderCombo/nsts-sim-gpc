const esbuild = require('esbuild')
const coffeeScriptPlugin = require('esbuild-coffeescript')
const path = require('path')

async function main() {
  try {
    await esbuild.build({
      platform: 'node',
      entryPoints: [path.resolve('gpc/run_batch.coffee')],
      bundle: true,
      format: 'cjs',
      target: 'node18',
      outfile: 'dist/gpc-batch.js',
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
