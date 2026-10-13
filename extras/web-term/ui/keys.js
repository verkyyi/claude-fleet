// web-term C1 (#3837): what the compose box and the key bar turn into bytes.
// Pure functions, no DOM — bin/fleet-webterm-selftest.py runs them under node.
(function (root) {
  'use strict';
  var ESC = '\x1b';

  // The compose box's text → what goes into the PTY. Under bracketed paste (the
  // program asked for it: Claude Code, a modern shell) the whole text is ONE
  // paste — an IME / dictation / multi-line paste arrives as typed, never as
  // keystrokes the TUI re-interprets. ESC is dropped so the text cannot end the
  // paste early (\e[201~) or smuggle a sequence. Newlines become CR, as xterm.js
  // does for a paste. `enter` appends the submit after it, as a separate write.
  function encodeCompose(text, bracketed) {
    var body = String(text).replace(/\x1b/g, '').replace(/\r?\n/g, '\r');
    if (!body) return '';
    return bracketed ? ESC + '[200~' + body + ESC + '[201~' : body;
  }

  // The key bar. An arrow honours application-cursor mode (DECCKM).
  var KEYS = {
    esc: ESC, tab: '\t', stab: ESC + '[Z', enter: '\r', ctrlc: '\x03',
    up: 'A', down: 'B', right: 'C', left: 'D'
  };
  function keySeq(name, appCursor) {
    var k = KEYS[name];
    if (k === undefined) return '';
    if (k.length === 1 && /[ABCD]/.test(k)) return ESC + (appCursor ? 'O' : '[') + k;
    return k;
  }

  // Ctrl + a printable char → its control code (^A..^Z, ^[ ^\ ^] ^^ ^_, ^@ for space).
  function ctrlOf(ch) {
    if (!ch || ch.length !== 1) return '';
    if (ch === ' ') return '\x00';
    var c = ch.toUpperCase().charCodeAt(0);
    if (c >= 64 && c <= 95) return String.fromCharCode(c - 64);
    if (ch === '?') return '\x7f';
    return '';
  }

  // One wheel step for a program that turned mouse reporting on (tmux with
  // `mouse on`, a full-screen TUI): SGR encoding, at the given cell.
  function wheelSeq(up, col, row) {
    return ESC + '[<' + (up ? 64 : 65) + ';' + (col || 1) + ';' + (row || 1) + 'M';
  }

  var api = { encodeCompose: encodeCompose, keySeq: keySeq, ctrlOf: ctrlOf, wheelSeq: wheelSeq };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.WebTermKeys = api;
})(this);
