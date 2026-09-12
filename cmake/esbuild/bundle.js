// Bundles one CLI entry point into a single CommonJS file for node.
//
//   node cmake/esbuild/bundle.js <name> [<name> ...]
//   node cmake/esbuild/bundle.js --list
//
// The source root is NSTS_SRC_ROOT, or the tree this file sits in.  The
// output directory is NSTS_DIST, or <root>/build/dist; cmake passes the
// build tree's.
//
// Every bundle takes the same options.  A name here is the basename of the
// bundle it writes: `gpc` is dist/gpc.js.

const esbuild = require('esbuild')
const coffeeScriptPlugin = require('esbuild-coffeescript')
const path = require('path')
const fs = require('fs')

const ROOT = process.env.NSTS_SRC_ROOT
    ? path.resolve(process.env.NSTS_SRC_ROOT)
    : path.resolve(__dirname, '..', '..')
const DIST = process.env.NSTS_DIST
    ? path.resolve(process.env.NSTS_DIST)
    : path.join(ROOT, 'build', 'dist')

// An entry is a path from the tree root, so a command outside src/ is
// named the same way as one inside it.
const BUNDLES = {
  gpc:      'src/gpc/cli.coffee',
  gpcmd:    'src/meds/gpcmd.coffee',
  idp:      'src/meds/idp/cli.coffee',
  ratsnest: 'src/ratsnest/cli.coffee',
  dfbDump:      'tools/deu/dfbDump.coffee',
  dpsDispToFcb: 'tools/deu/dpsDispToFcb.coffee',
  fcwCal:       'tools/deu/fcwCal.coffee',
  lru:      'src/lru/cli.coffee',
  adc:      'src/lru/adc/cli.coffee',
  adta:     'src/lru/adta/cli.coffee',
  ddu:      'src/lru/ddu/cli.coffee',
  imu:      'src/lru/imu/cli.coffee',
  mdm:      'src/lru/mdm/cli.coffee',
  mmu:      'src/lru/mmu/cli.coffee',
  mtu:      'src/lru/mtu/cli.coffee',
  nsp:      'src/lru/nsp/cli.coffee',
  pcmmu:    'src/lru/pcmmu/cli.coffee',
}

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
      const filename = path.relative(ROOT, args.path)
      const compiled = compile(source, { filename, inlineMap: true, js: true })
      return { contents: compiled, loader: 'js' }
    })
  }
}

async function bundle(name) {
  const entry = BUNDLES[name]
  if (!entry) throw new Error(`no bundle named '${name}' (have: ${Object.keys(BUNDLES).join(' ')})`)
  await esbuild.build({
    absWorkingDir: ROOT,
    platform: 'node',
    entryPoints: [path.join(ROOT, entry)],
    bundle: true,
    format: 'cjs',
    target: 'node20',
    outfile: path.join(DIST, `${name}.js`),
    plugins: [
      civetPlugin,
      coffeeScriptPlugin({}),
    ],
    loader: {'.asm': 'text'},   // meds/asm: SP-0 assembly source
    resolveExtensions: ['.coffee', '.js', '.ts', '.civet', '.json'],
    external: ['dgram', 'electron'],
    logLevel: 'info',
  })
}

async function main() {
  const args = process.argv.slice(2)
  if (args[0] === '--list') { console.log(Object.keys(BUNDLES).join('\n')); return }
  const names = args.length ? args : Object.keys(BUNDLES)
  for (const n of names) await bundle(n)
}

main().catch((e) => { console.error(e); process.exit(1) })
