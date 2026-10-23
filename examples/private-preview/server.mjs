// Explicit fixture/application entrypoint. No project configuration is edited.
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { WebSocketServer } from 'ws';

process.umask(0o077);
const name = process.env.PREVIEW_SOCKET || 'example.sock';
if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,39}\.sock$/.test(name)) throw Error('socket basename required');
const dir = path.join(os.homedir(), '.fleet-preview');
if (!fs.existsSync(dir)) fs.mkdirSync(dir, { mode: 0o700 });
const st = fs.lstatSync(dir);
if (!st.isDirectory() || st.isSymbolicLink() || st.uid !== process.getuid() || (st.mode & 0o077)) throw Error('private 0700 directory required');
const socket = path.join(dir, name);
// Never unlink a pre-existing socket: it could belong to another running app.
if (fs.existsSync(socket)) throw Error('socket already exists; stop its owner before removing it');
const app = process.argv.includes('--express') ? (await import('express')).default() : null;
const server = http.createServer();
const ws = new WebSocketServer({ noServer: true });
ws.on('connection', (c) => c.on('message', (b) => c.send(b.toString())));
server.on('upgrade', (req, socket, head) => {
  if (new URL(req.url, 'http://preview.invalid').pathname === '/ws') ws.handleUpgrade(req, socket, head, (c) => ws.emit('connection', c));
});
let vite;
if (process.argv.includes('--vite')) {
  // HMR shares this Unix listener. No TCP listener, tunnel, or project edits.
  const host = process.env.PREVIEW_HOST;
  if (!host || !/^[a-z0-9.-]+$/.test(host)) throw Error('PREVIEW_HOST must be your exact preview hostname');
  const { createServer } = await import('vite');
  vite = await createServer({ configFile: false, root: import.meta.dirname, appType: 'spa', server: {
    middlewareMode: true, allowedHosts: [host], hmr: { server, protocol: 'wss', host, clientPort: 443 },
  } });
}
const handler = async (req, res) => {
  const url = new URL(req.url, 'http://preview.invalid');
  if (url.pathname === '/api') {
    const chunks = []; for await (const b of req) chunks.push(b);
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Set-Cookie', 'app_session=example; Path=/; HttpOnly; Secure');
    res.end(JSON.stringify({ method: req.method, body: Buffer.concat(chunks).toString(), cookie: req.headers.cookie || '', auth: req.headers.authorization || '', custom: req.headers['x-app-value'] || '' }));
  } else if (url.pathname === '/events') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream' }); res.write('data: ready\n\n');
    const timer = setInterval(() => res.write(`data: ${Date.now()}\n\n`), 1000);
    req.on('close', () => clearInterval(timer));
  } else if (vite) vite.middlewares(req, res);
  else { res.setHeader('Content-Type', 'text/html'); res.end('<h1>Private Unix HTTP preview</h1><p>POST /api, GET /events, WebSocket /ws</p>'); }
};
if (app) { app.use(handler); server.on('request', app); } else server.on('request', handler);
server.listen(socket, () => { fs.chmodSync(socket, 0o600); console.log(`Listening on ${socket}`); });
async function close() { ws.close(); await vite?.close(); server.close(() => { try { fs.unlinkSync(socket); } catch {} process.exit(0); }); }
process.on('SIGINT', close); process.on('SIGTERM', close);
