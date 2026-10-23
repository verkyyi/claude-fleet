import { message } from './message.js';
document.querySelector('#hmr').textContent = message;
if (import.meta.hot) import.meta.hot.accept('./message.js', (mod) => {
  document.querySelector('#hmr').textContent = mod.message;
});
document.querySelector('#post').onclick = async () => {
  const r = await fetch('/api', { method: 'POST', body: 'browser-post', headers: { 'X-App-Value': 'browser' } });
  document.querySelector('#api').textContent = await r.text();
};
const events = new EventSource('/events');
events.onmessage = (e) => { document.querySelector('#sse').textContent = `SSE: ${e.data}`; };
