/*
  MenuBuddy theme runtime, shared by every theme page.

  A theme page is:
    <link rel="stylesheet" href="base.css">  + its own <style>
    <div id="stage"></div>
    <script src="buddy.js"></script>
    <script> Buddy.theme({ render(apps, stage, h) {...}, hot(app) {...}, empty(stage, message, h) {...} }) </script>

  apps: [{ id, name, icon }] in menu-bar order, left to right. icon is an image URL (a PNG data URL
  from the app, an SVG data URL in dev mode). Any count from 1 to ~40 must lay out sensibly.

  render(apps, stage, h)  builds the theme into #stage. It is called again every time the panel
                          opens, so entry animations replay. Give containers explicit sizes: the
                          stage's size (padding included) becomes the panel window's size.
  hot(app | null)         optional; updates a sign/label with the app under the pointer.
  action(name, el)        optional; a press-and-release on an element with data-action="name"
                          that isn't an app (keypad keys, coin slots…). It gets class "over" while
                          the pointer is on it and "pressed" while held.
  empty(stage, msg, h)    optional; shown when there is nothing to list (msg says why).

  h.app(app, {tag, class, style, img})  makes the clickable element for one app (class "app",
                          data-id). It holds the icon <img> unless img:false. base.css scales it 2x
                          while hot. Give it a width and height in style or the theme CSS.
  Put data-scope on an animated wrapper so it rises above its neighbours while its app is hot.
  stage.dataset.anchor = '0.8' puts that fraction of the stage width under the menu bar icon
  (default 0.5).

  Native side (Swift) calls: Buddy.setApps(list, message, {quiet}), Buddy.show(), Buddy.pointer(x, y),
  Buddy.leave(), Buddy.down/drag/up(x, y), Buddy.idAt(x, y). The page posts back
  {type:'ready'|'size'}, {type:'open', id}, {type:'move', id, to} and {type:'hide', id}.

  Rearranging is generic, themes need nothing for it: press an app and drag it onto another app to
  take its place, or onto the "hide" zone that appears at the bottom. A press without a drag opens
  the app. A quiet render (after a rearrange) skips the entry animations.

  Dev mode (opened in a browser, no native bridge): renders sample apps. URL params:
    ?n=4      number of sample apps (default 10)
    ?hot=2    make sample #2 hot, to check the 2x state in a screenshot
    ?empty=1  show the empty state
    ?dark=1   dark backdrop
*/
(function () {
  'use strict';
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.buddy;
  const post = (m) => { if (handler) handler.postMessage(m); };

  let theme = null;
  let stage = null;
  let apps = [];
  let message = null;
  let hotId = null;

  const h = {
    el(tag, props, ...kids) {
      const e = tag === 'svg' || tag === 'path' ? document.createElementNS('http://www.w3.org/2000/svg', tag) : document.createElement(tag);
      if (props) {
        for (const k in props) {
          const v = props[k];
          if (v == null || v === false) continue;
          if (k === 'class') e.setAttribute('class', v);
          else if (k === 'text') e.textContent = v;
          else if (k === 'html') e.innerHTML = v;
          else if (k === 'vars') { for (const n in v) e.style.setProperty('--' + n, v[n]); }
          else e.setAttribute(k, v);
        }
      }
      for (const kid of kids.flat(Infinity)) {
        if (kid == null || kid === false) continue;
        e.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
      }
      return e;
    },
    /** Element from an SVG/HTML string. */
    frag(markup) {
      const t = document.createElement('template');
      t.innerHTML = markup.trim();
      return t.content.firstElementChild;
    },
    app(app, opts) {
      opts = opts || {};
      const e = h.el(opts.tag || 'div', {
        class: 'app' + (opts.class ? ' ' + opts.class : ''),
        style: opts.style,
        vars: opts.vars,
        'data-id': app.id,
        'aria-label': app.name,
        role: 'button',
      });
      if (opts.img !== false) e.append(h.el('img', { src: app.icon, alt: '', draggable: 'false' }));
      return e;
    },
    /** Split into rows of at most `max`, balanced (11 with max 6 → 6 + 5). */
    rows(list, max) {
      const count = Math.max(1, Math.ceil(list.length / max));
      const per = Math.ceil(list.length / count);
      const out = [];
      for (let i = 0; i < list.length; i += per) out.push(list.slice(i, i + per));
      return out;
    },
    /** Deterministic 0..1 noise for index i (so wobbles and tilts are stable across opens). */
    rand(i, salt) {
      const x = Math.sin((i + 1) * 12.9898 + (salt || 0) * 78.233) * 43758.5453;
      return x - Math.floor(x);
    },
    /** Pick from a palette by index. */
    pick(list, i) { return list[((i % list.length) + list.length) % list.length]; },
  };

  function targetAt(x, y) {
    let el = document.elementFromPoint(x, y);
    let t = el && el.closest('[data-id]');
    // A hot app is drawn 2x and may cover a neighbour: let the neighbour win where it really is.
    if (t && t.classList.contains('hot')) {
      const prev = t.style.pointerEvents;
      t.style.pointerEvents = 'none';
      const under = document.elementFromPoint(x, y);
      t.style.pointerEvents = prev;
      const t2 = under && under.closest('[data-id]');
      if (t2 && t2 !== t) return t2;
    }
    return t || null;
  }

  function setHot(id) {
    if (id === hotId) return;
    hotId = id;
    stage.querySelectorAll('.hot').forEach((n) => n.classList.remove('hot'));
    stage.querySelectorAll('.hot-scope').forEach((n) => n.classList.remove('hot-scope'));
    let app = null;
    if (id != null) {
      stage.querySelectorAll('[data-id="' + CSS.escape(id) + '"]').forEach((n) => {
        n.classList.add('hot');
        let s = n.parentElement && n.parentElement.closest('[data-scope]');
        while (s) { s.classList.add('hot-scope'); s = s.parentElement && s.parentElement.closest('[data-scope]'); }
      });
      app = apps.find((a) => a.id === id) || null;
    }
    if (theme && theme.hot) theme.hot(app);
  }

  function defaultEmpty(st, msg, hh) {
    st.append(hh.el('div', { class: 'buddy-empty', text: msg }));
  }

  function report() {
    if (!stage) return;
    void stage.offsetWidth; // force layout
    post({
      type: 'size',
      width: Math.ceil(stage.offsetWidth),
      height: Math.ceil(stage.offsetHeight),
      anchor: parseFloat(stage.dataset.anchor || '0.5'),
    });
  }

  function render(quiet) {
    if (!theme || !stage) return;
    cancelDrag();
    hotId = null;
    stage.innerHTML = '';
    stage.removeAttribute('class');
    stage.removeAttribute('data-anchor');
    if (!apps.length) (theme.empty || defaultEmpty)(stage, message || 'Nothing up in the menu bar yet.', h);
    else theme.render(apps, stage, h);
    if (quiet) stage.classList.add('quiet');
    if (theme.hot) theme.hot(null);
    report();
  }

  // ---- Press, drag to rearrange, drop on the hide zone -----------------------------------------
  let press = null;   // { id, x, y, el } while the button is down on an app
  let drag = null;    // { id, el, ghost, target } once it has moved far enough
  let zone = null;

  const EYE_OFF = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 3l18 18M10.6 5.1A10 10 0 0 1 12 5c6 0 9.5 7 9.5 7a17 17 0 0 1-3 3.9M6.6 6.6C3.9 8.4 2.5 12 2.5 12S6 19 12 19a9.7 9.7 0 0 0 5.4-1.6M9.9 9.9a3 3 0 0 0 4.2 4.2"/></svg>';

  function hideZone() {
    if (!zone) {
      zone = h.el('div', { class: 'buddy-hide-zone', html: EYE_OFF + '<span>Drop here to hide</span>' });
      document.body.append(zone);
    }
    return zone;
  }

  function overZone(x, y) {
    if (!zone) return false;
    const r = zone.getBoundingClientRect();
    return x >= r.left - 8 && x <= r.right + 8 && y >= r.top - 8 && y <= r.bottom + 8;
  }

  function actionAt(x, y) {
    const hit = document.elementFromPoint(x, y);
    return hit ? hit.closest('[data-action]') : null;
  }

  let overEl = null;
  function setOver(el) {
    if (el === overEl) return;
    if (overEl) overEl.classList.remove('over');
    overEl = el;
    if (el) el.classList.add('over');
  }

  function down(x, y) {
    const t = targetAt(x, y);
    if (t) { press = { id: t.dataset.id, x, y, el: t }; return; }
    const act = actionAt(x, y);
    press = act ? { action: act, x, y } : null;
    if (act) act.classList.add('pressed');
  }

  function startDrag() {
    setHot(null);
    const app = apps.find((a) => a.id === press.id);
    const ghost = h.el('div', { class: 'buddy-ghost' }, h.el('img', { src: app ? app.icon : '', alt: '', draggable: 'false' }));
    document.body.append(ghost);
    press.el.classList.add('dragging');
    hideZone();
    document.body.classList.add('buddy-dragging');
    drag = { id: press.id, el: press.el, ghost, target: null };
  }

  function dragTo(x, y) {
    if (!press || press.action) return;
    if (!drag && Math.hypot(x - press.x, y - press.y) > 5) startDrag();
    if (!drag) return;
    drag.ghost.style.left = x + 'px';
    drag.ghost.style.top = y + 'px';
    const onZone = overZone(x, y);
    zone.classList.toggle('over', onZone);
    let t = onZone ? null : targetAt(x, y);
    if (t && t.dataset.id === drag.id) t = null;
    if (t !== drag.target) {
      if (drag.target) drag.target.classList.remove('drop-target');
      if (t) t.classList.add('drop-target');
      drag.target = t;
      if (theme && theme.hot) theme.hot(t ? apps.find((a) => a.id === t.dataset.id) || null : null);
    }
  }

  function cancelDrag() {
    if (drag) {
      drag.ghost.remove();
      drag.el.classList.remove('dragging');
      if (drag.target) drag.target.classList.remove('drop-target');
      drag = null;
    }
    if (zone) zone.classList.remove('over');
    document.body.classList.remove('buddy-dragging');
    if (press && press.action) press.action.classList.remove('pressed');
    press = null;
  }

  function up(x, y) {
    if (press && press.action) {
      const el = press.action;
      el.classList.remove('pressed');
      press = null;
      if (el.contains(document.elementFromPoint(x, y)) && theme && theme.action) theme.action(el.dataset.action, el);
      return;
    }
    if (drag) {
      const id = drag.id;
      const onZone = overZone(x, y);
      const to = drag.target ? drag.target.dataset.id : null;
      cancelDrag();
      if (onZone) act({ type: 'hide', id });
      else if (to) act({ type: 'move', id, to });
      else Buddy.pointer(x, y);
      return;
    }
    if (press) {
      const t = targetAt(x, y);
      const id = press.id;
      press = null;
      if (t && t.dataset.id === id) post({ type: 'open', id });
    }
  }

  /** Native applies moves and hides and sends the new list back; in a browser, do it here. */
  function act(m) {
    if (handler) { post(m); return; }
    // Same rule as the app: the dragged app takes the target's place.
    const ids = apps.map((a) => a.id);
    const from = ids.indexOf(m.id);
    const to = ids.indexOf(m.to);
    if (from < 0) return;
    const [app] = apps.splice(from, 1);
    if (m.type === 'move' && to >= 0) apps.splice(to, 0, app);
    render(true);
  }

  window.Buddy = {
    h,
    theme(t) {
      theme = t;
      stage = document.getElementById('stage');
      if (document.fonts && document.fonts.ready) document.fonts.ready.then(report);
      if (handler) post({ type: 'ready' });
      else devStart();
    },
    setApps(list, msg, opts) {
      apps = Array.isArray(list) ? list : [];
      message = msg || null;
      render(!!(opts && opts.quiet));
    },
    show() { render(false); },
    pointer(x, y) {
      if (press) { dragTo(x, y); return; }
      const t = targetAt(x, y);
      setHot(t ? t.dataset.id : null);
      setOver(t ? null : actionAt(x, y));
    },
    leave() { if (!press) { setHot(null); setOver(null); } },
    down,
    drag: dragTo,
    up,
    cancel: cancelDrag,
    idAt(x, y) { const t = targetAt(x, y); return t ? t.dataset.id : null; },
    report,
  };

  // Ordinary pointer events (Settings preview, a browser). In the menu bar panel the app feeds
  // these calls itself, because the panel never becomes the key window.
  document.addEventListener('mousemove', (e) => Buddy.pointer(e.clientX, e.clientY));
  document.addEventListener('mouseleave', () => Buddy.leave());
  document.addEventListener('mousedown', (e) => { if (e.button === 0 && !e.ctrlKey) down(e.clientX, e.clientY); });
  window.addEventListener('mouseup', (e) => { if (e.button === 0) up(e.clientX, e.clientY); });
  document.addEventListener('contextmenu', (e) => e.preventDefault());
  document.addEventListener('dragstart', (e) => e.preventDefault());

  // ---- Dev mode -------------------------------------------------------------------------------
  const SAMPLES = [
    ['Cloud sync', '#7FD6FF', 'M7 18h10a4 4 0 0 0 .5-7.97A6 6 0 0 0 6 9.5 4.5 4.5 0 0 0 7 18z'],
    ['Music', '#FFE45C', 'M9 18V5l11-2v13M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0zM20 16a3 3 0 1 1-6 0 3 3 0 0 1 6 0z'],
    ['Clipboard', '#FFB27A', 'M9 3h6v4H9zM7 5H5v16h14V5h-2'],
    ['VPN', '#B8F2C9', 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z'],
    ['Timer', '#FF8FB1', 'M12 9v4l3 2M10 2h4M12 22a8 8 0 1 0 0-16 8 8 0 0 0 0 16z'],
    ['Water reminder', '#A9C6FF', 'M12 3s6 6.5 6 11a6 6 0 0 1-12 0c0-4.5 6-11 6-11z'],
    ['Passwords', '#E2C7FF', 'M8 15a4 4 0 1 1 3.5-6H21v3h-2v3h-3v-3h-4.5A4 4 0 0 1 8 15z'],
    ['Night mode', '#9BE15D', 'M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z'],
    ['Chat', '#FFD3A8', 'M4 5h16v11H9l-5 4z'],
    ['Screenshot', '#C9F0FF', 'M3 8h4l2-3h6l2 3h4v11H3zM12 17a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z'],
  ];
  function sampleIcon(bg, d) {
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">' +
      '<rect x="5" y="5" width="54" height="54" rx="13" fill="' + bg + '" stroke="#1F1B2E" stroke-width="3"/>' +
      '<g transform="translate(16 16) scale(1.333)" fill="none" stroke="#1F1B2E" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="' + d + '"/></g></svg>';
    return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
  }
  function samples(n) {
    const out = [];
    for (let i = 0; i < n; i++) {
      const s = SAMPLES[i % SAMPLES.length];
      out.push({ id: 's' + i, name: s[0] + (i >= SAMPLES.length ? ' ' + (Math.floor(i / SAMPLES.length) + 1) : ''), icon: sampleIcon(s[1], s[2]) });
    }
    return out;
  }
  function devStart() {
    const q = new URLSearchParams(location.search);
    document.body.classList.add('dev');
    if (q.get('dark')) document.body.classList.add('dark');
    const n = q.get('empty') ? 0 : parseInt(q.get('n') || '10', 10);
    Buddy.setApps(samples(n), q.get('empty') ? 'Turn on Accessibility for MenuBuddy to see your menu bar apps.' : null);
    if (q.get('hot') != null) {
      const id = 's' + q.get('hot');
      setTimeout(() => setHot(id), 50);
    }
  }
})();
