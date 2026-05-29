import * as esbuild from 'esbuild';

await esbuild.build({
  entryPoints: ['server.ts'],
  bundle: true,
  platform: 'node',
  target: 'node22',
  outfile: 'dist/server.js',
  format: 'esm',
  sourcemap: true,
  external: [],
});
