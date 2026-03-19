import { BuildOptions } from 'esbuild'
import civetPlugin from '@danielx/civet/esbuild-plugin'
import * as path from 'path'
import svg from 'esbuild-plugin-svg';


const config: BuildOptions = {
  platform: 'node',
  plugins: [
    civetPlugin({outputExtension: 'jsx'}),
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
    '.civet': 'jsx',
  },
  bundle: true,
  format: 'cjs',
  target: 'node20.6.0',
}

export default config
