// Records a short demo of playing the Vending Machine theme: the real theme page (dev mode, sample
// apps) in headless Chrome, a drawn pointer, step captions, recorded with the DevTools screencast.
//   node scripts/vending-demo.mjs <out-folder>   → <out>/vending-demo.mp4 (+ vending-demo.webm, poster)
// Needs Google Chrome and ffmpeg. No npm packages (Node's own WebSocket).
import { spawn, execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const out = resolve(process.argv[2] || join(root, 'build/demo'));
const W = 900, H = 700, SCALE = 2, PORT = 9333;
mkdirSync(out, { recursive: true });
const frames = mkdtempSync(join(tmpdir(), 'vending-frames-'));
const profile = mkdtempSync(join(tmpdir(), 'vending-chrome-'));

const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', '--disable-gpu', '--hide-scrollbars', '--allow-file-access-from-files', '--mute-audio',
  `--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`, `--window-size=${W},${H}`,
  `--force-device-scale-factor=${SCALE}`, 'about:blank',
], { stdio: 'ignore' });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let target;
for (let i = 0; i < 50 && !target; i++) {
  await sleep(200);
  try { target = (await (await fetch(`http://127.0.0.1:${PORT}/json`)).json()).find((t) => t.type === 'page'); } catch {}
}
if (!target) { chrome.kill(); throw new Error('Chrome did not start'); }

const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r, { once: true }));
let seq = 0;
const pending = new Map();
const listeners = [];
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  else if (m.method) listeners.forEach((f) => f(m));
});
const send = (method, params = {}) => new Promise((r) => { const id = ++seq; pending.set(id, r); ws.send(JSON.stringify({ id, method, params })); });

await send('Page.enable');
await send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: SCALE, mobile: false });
await send('Page.navigate', { url: `file://${root}/Resources/Themes/vending.html?n=12` });
await sleep(1500);

// The pointer, ripples and captions live in the page, so every frame shows exactly what the theme does.
const STAGE = String.raw`
(() => {
  const css = document.createElement('style');
  css.textContent = ` + '`' + String.raw`
    #demo-cursor { position: fixed; left: 0; top: 0; width: 26px; height: 38px; pointer-events: none; z-index: 99999; transform-origin: 3px 2px; transition: transform .08s; filter: drop-shadow(0 2px 3px rgba(0,0,0,.35)); }
    #demo-cursor.down { transform: scale(.88); }
    .demo-ripple { position: fixed; width: 44px; height: 44px; margin: -22px 0 0 -22px; border-radius: 50%; border: 3px solid rgba(31,27,46,.55); pointer-events: none; z-index: 99998; animation: demo-rip .5s ease-out forwards; }
    @keyframes demo-rip { from { transform: scale(.3); opacity: 1; } to { transform: scale(1.4); opacity: 0; } }
    #demo-cap { position: fixed; left: 50%; bottom: 22px; transform: translate(-50%, 8px); padding: 10px 20px; border-radius: 999px; background: rgba(31,27,46,.82); color: #fff; font: 600 19px/1.2 -apple-system, "SF Pro Text", "Helvetica Neue", sans-serif; white-space: nowrap; opacity: 0; transition: opacity .3s, transform .3s; pointer-events: none; z-index: 99997; }
    #demo-cap.on { opacity: 1; transform: translate(-50%, 0); }
    #demo-cap b { color: #FFE45C; }
  ` + '`' + String.raw`;
  document.head.append(css);
  const cur = document.createElement('div');
  cur.id = 'demo-cursor';
  cur.innerHTML = '<svg width="26" height="38" viewBox="0 0 13 19"><path d="M1 1v15.5l3.6-3.4 2.4 5.4 2.6-1.1-2.4-5.3h5z" fill="#000" stroke="#fff" stroke-width="1.2" stroke-linejoin="round"/></svg>';
  document.body.append(cur);
  const cap = document.createElement('div');
  cap.id = 'demo-cap';
  document.body.append(cap);
  let px = ${W} * 0.5, py = ${H} + 30;
  const place = () => { cur.style.left = (px - 3) + 'px'; cur.style.top = (py - 2) + 'px'; };
  place();
  const ease = (t) => t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
  const fire = (type, x, y) => (type === 'mouseup' ? window : document).dispatchEvent(new MouseEvent(type, { clientX: x, clientY: y, button: 0, bubbles: true }));
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const center = (sel) => { const r = document.querySelector(sel).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; };
  window.demo = {
    wait,
    center,
    async move(sel, ms = 600, dx = 0, dy = 0) {
      const [tx, ty] = center(sel); const x0 = px, y0 = py; const t0 = performance.now();
      await new Promise((done) => { const step = (now) => { const k = Math.min(1, (now - t0) / ms); const e = ease(k);
        px = x0 + (tx + dx - x0) * e; py = y0 + (ty + dy - y0) * e; place(); fire('mousemove', px, py);
        k < 1 ? requestAnimationFrame(step) : done(); }; requestAnimationFrame(step); });
    },
    async click() {
      cur.classList.add('down'); fire('mousedown', px, py);
      const r = document.createElement('div'); r.className = 'demo-ripple'; r.style.left = px + 'px'; r.style.top = py + 'px'; document.body.append(r); setTimeout(() => r.remove(), 600);
      await wait(110); fire('mouseup', px, py); cur.classList.remove('down');
    },
    caption(html) { if (!html) { cap.classList.remove('on'); return; } cap.innerHTML = html; cap.classList.add('on'); },
  };
})();
`;
await send('Runtime.evaluate', { expression: STAGE });
// Frame = the machine plus an even margin, with room for the caption under it.
const box = JSON.parse((await send('Runtime.evaluate', { expression: `(() => { const r = document.querySelector('.machine').getBoundingClientRect();
  const m = 36, x = Math.max(0, r.left - m), y = Math.max(0, r.top - m), w = r.width + 2 * m + 8, h = r.height + m + 8 + 84;
  const cap = document.getElementById('demo-cap'); cap.style.bottom = 'auto'; cap.style.top = (r.bottom + 30) + 'px'; cap.style.left = (r.left + r.width / 2 + 4) + 'px';
  return JSON.stringify({ x, y, w, h }); })()` })).result.result.value);
const crop = ['w', 'h', 'x', 'y'].map((k) => 2 * Math.round(box[k] * SCALE / 2)).join(':');

// Screencast: every changed frame with its time; ffmpeg turns them into a steady 30 fps.
const shots = [];
listeners.push((m) => {
  if (m.method !== 'Page.screencastFrame') return;
  const file = join(frames, `f${String(shots.length).padStart(5, '0')}.jpg`);
  writeFileSync(file, Buffer.from(m.params.data, 'base64'));
  shots.push({ file, t: m.params.metadata.timestamp });
  send('Page.screencastFrameAck', { sessionId: m.params.sessionId });
});
await send('Page.startScreencast', { format: 'jpeg', quality: 95, maxWidth: W * SCALE, maxHeight: H * SCALE, everyNthFrame: 1 });

const script = String.raw`(async () => {
  const d = window.demo;
  await d.wait(700);
  d.caption('Point at an app: its <b>code</b> and <b>price</b>');
  await d.move('.slot[data-code="B4"] .app', 900);
  await d.wait(1500);
  d.caption('1 · Type the code: <b>B</b> then <b>4</b>');
  await d.move('.key[data-key="B"]', 650);
  await d.wait(200); await d.click(); await d.wait(450);
  await d.move('.key[data-key="4"]', 450);
  await d.wait(150); await d.click(); await d.wait(900);
  d.caption('2 · Click the coin slot once per $1: <b>$3</b>');
  await d.move('.coin', 550);
  for (let i = 0; i < 3; i++) { await d.wait(250); await d.click(); await d.wait(350); }
  await d.wait(500);
  d.caption('3 · Press <b>OK</b>');
  await d.move('.key.ok', 500);
  await d.wait(250); await d.click();
  await d.wait(250);
  d.caption('The app drops into the tray. <b>Enjoy!</b>');
  await d.move('.flap', 700, 120, 4);
  await d.wait(2200);
  d.caption('');
  await d.wait(500);
})()`;
await send('Runtime.evaluate', { expression: script, awaitPromise: true });
await send('Page.stopScreencast');
await sleep(300);
ws.close();
chrome.kill();

// concat list with each frame's real duration
const lines = [];
for (let i = 0; i < shots.length; i++) {
  const dur = i + 1 < shots.length ? shots[i + 1].t - shots[i].t : 0.5;
  lines.push(`file '${shots[i].file}'`, `duration ${Math.max(dur, 0.001).toFixed(4)}`);
}
lines.push(`file '${shots[shots.length - 1].file}'`);
writeFileSync(join(frames, 'list.txt'), lines.join('\n'));
const mp4 = join(out, 'vending-demo.mp4');
execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', join(frames, 'list.txt'),
  '-vf', `fps=30,crop=${crop},scale=1200:-2:flags=lanczos,format=yuv420p`, '-c:v', 'libx264', '-profile:v', 'high', '-preset', 'slow', '-crf', '20',
  '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709', '-movflags', '+faststart', '-an', mp4]);
execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-ss', '9.6', '-i', mp4, '-frames:v', '1', join(out, 'vending-demo-poster.png')]);
rmSync(frames, { recursive: true, force: true });
rmSync(profile, { recursive: true, force: true });
console.log(`${mp4} (${shots.length} frames)`);
