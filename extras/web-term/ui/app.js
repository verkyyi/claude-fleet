// web-term C1 (#3837): the page. A real terminal (xterm.js) on top, a key bar,
// and a native compose box under it: the phone's IME / dictation / paste write
// into an ordinary <textarea>, and only a finished text goes into the PTY.
(function () {
  'use strict';
  var K = window.WebTermKeys;
  var $ = function (id) { return document.getElementById(id); };
  var input = $('input'), keys = $('keys'), dot = $('dot'), termEl = $('term');
  var coarse = window.matchMedia && window.matchMedia('(pointer: coarse)').matches;

  function load(k, d) { try { var v = localStorage.getItem(k); return v === null ? d : v; } catch (e) { return d; } }
  function save(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* private mode */ } }

  // ------------------------------------------------------------ terminal
  var term = new window.Terminal({
    fontFamily: 'Menlo, "SF Mono", ui-monospace, "Noto Sans Mono CJK SC", "PingFang SC", monospace',
    fontSize: +load('webterm.font', coarse ? 12 : 14),
    scrollback: 5000,
    cursorBlink: true,
    allowProposedApi: true,
    macOptionIsMeta: true,
    theme: { background: '#0d1117', foreground: '#e6edf3', cursor: '#e6edf3', selectionBackground: '#264f78' }
  });
  var fit = new window.FitAddon.FitAddon();
  term.loadAddon(fit);
  try { term.loadAddon(new window.Unicode11Addon.Unicode11Addon()); term.unicode.activeVersion = '11'; } catch (e) { /* widths v6 */ }
  term.open(termEl);
  var helper = termEl.querySelector('.xterm-helper-textarea');
  window.webterm = { term: term }; // for the console and the drills

  // ------------------------------------------------------------ socket
  var ws = null, retry = 0, timer = null, lastSize = '';
  function setDot(s) { dot.className = 'dot ' + s; }
  function sendIn(d) {
    if (d && ws && ws.readyState === 1) ws.send(JSON.stringify({ t: 'in', d: d }));
  }
  function sendSize(force) {
    var s = term.cols + 'x' + term.rows;
    if ((force || s !== lastSize) && ws && ws.readyState === 1) {
      lastSize = s;
      ws.send(JSON.stringify({ t: 'resize', cols: term.cols, rows: term.rows }));
    }
  }
  function connect() {
    clearTimeout(timer);
    if (ws && ws.readyState < 2) return;
    setDot('wait');
    var url = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host +
      '/ws?cols=' + term.cols + '&rows=' + term.rows;
    ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';
    ws.onopen = function () { retry = 0; setDot('on'); sendSize(true); };
    ws.onmessage = function (ev) {
      term.write(typeof ev.data === 'string' ? ev.data : new Uint8Array(ev.data));
    };
    ws.onclose = function () {
      setDot('off');
      retry = Math.min(retry + 1, 6);
      timer = setTimeout(connect, Math.min(500 * Math.pow(2, retry - 1), 8000));
    };
  }
  setInterval(function () { if (ws && ws.readyState === 1) ws.send('{"t":"ping"}'); }, 20000);
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible' && (!ws || ws.readyState > 1)) { retry = 0; connect(); }
  });

  // ------------------------------------------------------------ Ctrl (sticky)
  var ctrlBtn = $('ctrl'), ctrlOn = false;
  function setCtrl(on) { ctrlOn = on; ctrlBtn.classList.toggle('on', on); }
  function typeChar(ch) {
    if (ctrlOn) { setCtrl(false); var c = K.ctrlOf(ch); if (c) { sendIn(c); return; } }
    sendIn(ch);
  }
  term.onData(function (d) {
    if (ctrlOn && d.length === 1) { typeChar(d); return; }
    sendIn(d);
  });

  // ------------------------------------------------------------ compose box
  var bracketed = function () { return !!(term.modes && term.modes.bracketedPasteMode); };
  function grow() {
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight + 2, window.innerHeight * 0.3) + 'px';
  }
  function submit(withEnter) {
    var text = input.value;
    var data = K.encodeCompose(text, bracketed());
    if (data) sendIn(data);
    // The submit is its own write, a beat later: a TUI that times keystrokes to
    // tell a paste from typing must not read this CR as part of the paste.
    if (withEnter) { if (data) setTimeout(function () { sendIn('\r'); }, 40); else sendIn('\r'); }
    input.value = '';
    grow();
  }
  $('compose').addEventListener('submit', function (e) { e.preventDefault(); submit(true); input.focus(); });
  input.addEventListener('keydown', function (e) {
    // While an IME is composing, Enter belongs to it (pinyin → 汉字), never to us.
    if (e.isComposing || e.keyCode === 229) return;
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit(true); }
  });
  input.addEventListener('input', function (e) {
    if (ctrlOn && e.data && e.data.length === 1 && !e.isComposing) {
      input.value = input.value.slice(0, -1);
      typeChar(e.data);
    }
    grow();
  });

  // ------------------------------------------------------------ key bar
  var press = null;
  keys.addEventListener('mousedown', function (e) { e.preventDefault(); }); // keep focus where it is
  keys.addEventListener('pointerdown', function (e) {
    var b = e.target.closest('button');
    if (!b) return;
    press = { b: b, x: e.clientX, y: e.clientY, refocus: document.activeElement === input };
  });
  keys.addEventListener('pointercancel', function () { press = null; });
  keys.addEventListener('pointerup', function (e) {
    if (!press) return;
    var p = press; press = null;
    if (Math.abs(e.clientX - p.x) > 10 || Math.abs(e.clientY - p.y) > 10) return; // it was a scroll of the bar
    var b = p.b;
    if (b.id === 'ctrl') setCtrl(!ctrlOn);
    else if (b.id === 'fill') submit(false);
    else if (b.dataset.k) {
      if (ctrlOn) setCtrl(false);
      sendIn(K.keySeq(b.dataset.k, !!(term.modes && term.modes.applicationCursorKeysMode)));
    } else if (b.dataset.t) typeChar(b.dataset.t);
    if (p.refocus) input.focus();
    else if (document.body.classList.contains('direct')) term.focus();
  });
  Array.prototype.forEach.call(keys.querySelectorAll('button'), function (b) { b.tabIndex = -1; });

  // ------------------------------------------------------------ direct mode
  var directBtn = $('direct');
  function setDirect(on) {
    document.body.classList.toggle('direct', on);
    directBtn.setAttribute('aria-pressed', on ? 'true' : 'false');
    // On a phone, a tap on the terminal must not pop the keyboard unless asked.
    if (helper) {
      if (on || !coarse) helper.removeAttribute('inputmode');
      else helper.setAttribute('inputmode', 'none');
    }
    save('webterm.direct', on ? '1' : '0');
    layout();
    if (on) term.focus(); else if (coarse) input.focus();
  }
  directBtn.addEventListener('click', function () { setDirect(!document.body.classList.contains('direct')); });

  // ------------------------------------------------------------ font size
  function setFont(n) { term.options.fontSize = Math.max(9, Math.min(24, n)); save('webterm.font', term.options.fontSize); layout(); }
  $('font-up').addEventListener('click', function () { setFont(term.options.fontSize + 1); });
  $('font-dn').addEventListener('click', function () { setFont(term.options.fontSize - 1); });

  // ------------------------------------------------------------ scrolling by swipe
  // A program that reports the mouse (tmux `mouse on` → copy-mode, a full-screen
  // TUI) gets wheel steps; anything else scrolls xterm's own history.
  // One wheel step moves tmux (and most TUIs) several lines, so the finger has
  // to travel WHEEL_LINES rows for each step to keep the page under it.
  var touch = null, WHEEL_LINES = 3, wheelAcc = 0;
  function cellH() { return Math.max(8, termEl.clientHeight / Math.max(1, term.rows)); }
  function scrollBy(lines) {
    if (!lines) return;
    var mouse = term.modes && term.modes.mouseTrackingMode && term.modes.mouseTrackingMode !== 'none';
    if (mouse) {
      if ((wheelAcc > 0) !== (lines > 0)) wheelAcc = 0; // changed direction
      wheelAcc += lines;
      var steps = wheelAcc > 0 ? Math.floor(wheelAcc / WHEEL_LINES) : Math.ceil(wheelAcc / WHEEL_LINES);
      wheelAcc -= steps * WHEEL_LINES;
      var seq = K.wheelSeq(steps > 0, Math.ceil(term.cols / 2), Math.ceil(term.rows / 2));
      for (var i = 0; i < Math.min(Math.abs(steps), 10); i++) sendIn(seq);
    } else {
      term.scrollLines(-lines);
    }
  }
  termEl.addEventListener('touchstart', function (e) {
    if (e.touches.length !== 1) { touch = null; return; }
    touch = { y: e.touches[0].clientY, acc: 0, moved: false };
    wheelAcc = 0;
  }, { passive: true, capture: true });
  termEl.addEventListener('touchmove', function (e) {
    if (!touch || e.touches.length !== 1) return;
    e.preventDefault(); e.stopPropagation();
    var y = e.touches[0].clientY;
    touch.acc += y - touch.y; touch.y = y;
    var h = cellH(), lines = touch.acc > 0 ? Math.floor(touch.acc / h) : Math.ceil(touch.acc / h);
    if (lines) { touch.moved = true; touch.acc -= lines * h; scrollBy(lines); }
  }, { passive: false, capture: true });
  termEl.addEventListener('touchend', function () {
    if (touch && !touch.moved) {
      if (document.body.classList.contains('direct')) term.focus(); else input.blur(); // a tap shows the whole screen
    }
    touch = null;
  }, { capture: true });

  // ------------------------------------------------------------ layout (the phone keyboard)
  var raf = 0;
  function layout() {
    cancelAnimationFrame(raf);
    raf = requestAnimationFrame(function () {
      var vv = window.visualViewport;
      var root = document.documentElement.style;
      root.setProperty('--vh', (vv ? vv.height : window.innerHeight) + 'px');
      root.setProperty('--vtop', (vv ? vv.offsetTop : 0) + 'px');
      try { fit.fit(); } catch (e) { /* not visible yet */ }
      sendSize(false);
    });
  }
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', layout);
    window.visualViewport.addEventListener('scroll', layout);
  }
  window.addEventListener('resize', layout);
  term.onTitleChange(function (t) { $('title').textContent = t || 'web-term'; document.title = t || 'web-term'; });

  setDirect(load('webterm.direct', coarse ? '0' : '1') === '1');
  layout();
  requestAnimationFrame(connect);
})();
