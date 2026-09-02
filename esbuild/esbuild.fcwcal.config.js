// One-off bundle for the beam-grid analyser, `meds/fcwCal.coffee`.
//   node esbuild/esbuild.fcwcal.config.js && node dist/fcwCal.js <file.dfb>
const esbuild = require('esbuild')
const coffeeScriptPlugin = require('esbuild-coffeescript')
const path = require('path')

esbuild.build({
  platform: 'node',
  entryPoints: [path.resolve('meds/fcwCal.coffee')],
  bundle: true,
  format: 'cjs',
  target: 'node20',
  outfile: 'dist/fcwCal.js',
  plugins: [coffeeScriptPlugin({})],
  loader: {'.asm': 'text'},   // meds/asm: SP-0 assembly source
  resolveExtensions: ['.coffee', '.js', '.ts', '.civet', '.json'],
  external: ['dgram', 'electron'],
  logLevel: 'info',
}).catch((e) => { console.error(e); process.exit(1) })
