// A finger drag on the terminal (C8X3). xterm's own touch scroll moves its local
// buffer, which is empty under tmux's alternate screen; while the program reads
// the mouse (tmux, mouse on) the drag becomes the wheel's reports instead — one
// per cell height moved, a finger moving down = scrolling back (wheel up, < 0).
// `carry` is the movement not yet spent; the result says the wheel steps to send.
export function touchWheel(carry: number, dy: number, cell: number): { steps: number; carry: number } {
  const step = Math.max(8, cell);
  let left = carry + dy;
  const n = Math.trunc(left / step);
  left -= n * step;
  return { steps: n ? -n : 0, carry: left };
}
