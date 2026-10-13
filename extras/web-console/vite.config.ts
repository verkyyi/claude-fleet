import path from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// One project, one build per side — the mode is the side (EPIC #3923 rule 3):
//   vite build --mode app     app/index.html → dist/app, served at /app/ (C3)
//   vite build --mode admin   admin/index.html → dist/admin, at /admin/ (C10)
// Separate builds, so no admin code ever rides in the member side's bundle.
// bin/web-console-pack.sh copies dist/<side> into the hub image. Every byte is
// local — no CDN, no font service (rule 4).
//   vite build --mode proto   the member side over a mock API (src/proto), one
//                             relative-path build that proto/inline.mjs folds
//                             into a single page for review (rule 14) — never packed
export default defineConfig(({ mode }) => {
  const proto = mode === "proto";
  const side = proto ? "app" : mode;
  return {
    root: path.resolve(import.meta.dirname, side),
    base: proto ? "./" : `/${side}/`,
    envDir: import.meta.dirname,
    plugins: [react(), tailwindcss()],
    resolve: { alias: { "@": path.resolve(import.meta.dirname, "src") } },
    define: { __PROTO__: JSON.stringify(proto) },
    build: {
      outDir: path.resolve(import.meta.dirname, proto ? "dist-proto" : `dist/${side}`),
      emptyOutDir: true, assetsInlineLimit: 0, chunkSizeWarningLimit: 2000,
      // the review page is one file: no lazy chunks to fetch
      ...(proto ? { rollupOptions: { output: { codeSplitting: false } } } : {}),
    },
    server: { host: "127.0.0.1" },
  };
});
