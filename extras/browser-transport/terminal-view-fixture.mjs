// Browser interception only: this route and bundle are never served by Fleet.
import { build } from 'esbuild'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('../web-console/', import.meta.url))
let bundle
export const workerTransportURL = (origin, worker) => `${origin}/app/__terminal-transport/${encodeURIComponent(worker)}`
export async function mountWorkerTransport(context) {
  bundle ??= build({
    entryPoints: [fileURLToPath(new URL('terminal-view-fixture.tsx', import.meta.url))],
    bundle: true, write: false, outdir: '/fixture', format: 'esm', target: 'es2022', jsx: 'automatic',
    tsconfig: `${root}tsconfig.json`, nodePaths: [`${root}node_modules`],
    define: { 'process.env.NODE_ENV': '"production"', 'import.meta.env': '{}' },
    loader: { '.svg': 'dataurl', '.png': 'dataurl', '.woff2': 'dataurl' },
  })
  const output = await bundle
  const script = output.outputFiles.find(f => f.path.endsWith('.js')).text
  const css = output.outputFiles.find(f => f.path.endsWith('.css'))?.text || ''
  const index = await readFile(`${root}dist/app/index.html`, 'utf8')
  const styles = [...index.matchAll(/<link[^>]+rel="stylesheet"[^>]*>/g)].map(m => m[0]).join('')
  await context.route('**/__terminal-fixture.js', route => route.fulfill({ contentType: 'application/javascript', body: script }))
  await context.route('**/__terminal-fixture.css', route => route.fulfill({ contentType: 'text/css', body: css }))
  await context.route('**/app/__terminal-transport/**', route => route.fulfill({ contentType: 'text/html', body:
    `<!doctype html><html lang="en"><head>${styles}<link rel="stylesheet" href="/__terminal-fixture.css"></head><body style="margin:0"><div id="root" style="height:100vh"></div><script type="module" src="/__terminal-fixture.js"></script></body></html>` }))
}
