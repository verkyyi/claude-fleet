// The 看台's word to its page (task C8X3): ⌘P in a browser terminal picked a
// session on another of the person's machines, which a browser 看台 cannot show
// itself — `ESC ] 7502 ; web-go ; w=<worker id> BEL` — so the page opens that
// session's own terminal (the hub admits it only on the person's own logins).
// The worker id, or null for anything else (another 7502 word, a bad id).
export function webGoTarget(data: string): string | null {
  const m = /^web-go;w=([A-Za-z0-9-]{1,64}\/[A-Za-z0-9._:-]{1,128})$/.exec(data);
  return m ? m[1] : null;
}
