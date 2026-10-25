// wordmark.ts — the brand's text logo, read off extras/fleet-theme/wordmark.svg
// (the one source; never re-spelled here). Plain TS so the poster's Node test
// can import it: the caller hands in the file's text (Vite's `?raw`).
export type WordmarkPart = { d: string; fill: string; stroke?: string; strokeWidth?: number };
export type Wordmark = { viewBox: [number, number, number, number]; parts: WordmarkPart[] };

const attr = (tag: string, name: string) => new RegExp(`\\s${name}="([^"]*)"`).exec(tag)?.[1];

export function parseWordmark(svg: string): Wordmark {
  const root = /<svg\b[^>]*>/.exec(svg)?.[0] ?? "";
  const vb = (attr(root, "viewBox") ?? "0 0 0 0").split(/[\s,]+/).map(Number) as Wordmark["viewBox"];
  const parts = [...svg.matchAll(/<path\b[^>]*>/g)].map(([tag]) => ({
    d: attr(tag, "d") ?? "",
    fill: attr(tag, "fill") ?? "currentColor",
    stroke: attr(tag, "stroke"),
    strokeWidth: attr(tag, "stroke-width") ? Number(attr(tag, "stroke-width")) : undefined,
  }));
  return { viewBox: vb, parts };
}
