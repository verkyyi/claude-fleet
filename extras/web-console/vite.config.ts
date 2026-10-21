import fs from "node:fs";
import path from "node:path";
import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// One project, one build per side — the mode is the side (EPIC #3923 rule 3):
//   vite build --mode app     app/index.html → dist/app, served at /app/ (C3)
//   vite build --mode admin   admin/index.html → dist/admin, at /admin/ (C10);
//                             VITE_DEMO=1 builds its review page over demo data
// Separate builds, so no admin code ever rides in the member side's bundle.
// bin/web-console-pack.sh copies dist/<side> into the hub image. Every byte is
// local — no CDN, no font service (rule 4).
//   vite build --mode proto   the member side over a mock API (src/proto), one
//                             relative-path build that proto/inline.mjs folds
//                             into a single page for review (rule 14) — never packed
// 添加到主屏幕 (claude-fleet#3943): the member side's build writes
// manifest.webmanifest beside its index.html — served at /app/manifest.webmanifest
// (the hub's AppManifestPath), the ONE manifest of the hub (/term links it too).
// The icons are the theme's PNG cut of logo.svg (bin/site-images.sh), hashed
// into assets/; the colour is the theme's --fleet-bg. No service worker, no
// offline cache. Its shortcuts open the new addresses (GR5E C9, src/app/legacy.ts).
const repo = path.resolve(import.meta.dirname, "../..");
function homeScreen(base: string): Plugin {
  const href = `${base}manifest.webmanifest`;
  return {
    name: "fleet-home-screen",
    apply: "build",
    transformIndexHtml: () => [
      { tag: "link", attrs: { rel: "manifest", href }, injectTo: "head" },
    ],
    generateBundle() {
      const theme = fs.readFileSync(path.join(repo, "extras/fleet-theme/theme.css"), "utf8");
      const bg = /--fleet-bg:\s*(#[0-9a-fA-F]{6})/.exec(theme)?.[1];
      if (!bg) throw new Error("fleet-home-screen: no --fleet-bg in the theme");
      const icon = (file: string, sizes: string) => ({
        src: base + this.getFileName(this.emitFile({
          type: "asset", name: file,
          source: fs.readFileSync(path.join(repo, "site/assets", file)),
        })),
        sizes, type: "image/png",
      });
      const manifest = {
        id: "/app", name: "ClaudeFleet", short_name: "ClaudeFleet",
        start_url: "/app", scope: "/", display: "standalone",
        background_color: bg, theme_color: bg, lang: "zh-CN",
        icons: [icon("icon-192.png", "192x192"), icon("icon-512.png", "512x512"),
          icon("apple-touch-icon.png", "180x180")],
        // a long press on the home-screen icon (GR5E C9): the new addresses only
        shortcuts: [
          { name: "新建会话", short_name: "新建", url: "/app/new" },
          { name: "我的 Shell", short_name: "Shell", url: "/app/s/shell?view=term" },
          { name: "我的用量", short_name: "用量", url: "/app/me/usage" },
        ],
      };
      this.emitFile({ type: "asset", fileName: "manifest.webmanifest", source: JSON.stringify(manifest, null, 2) + "\n" });
    },
  };
}

export default defineConfig(({ mode }) => {
  const proto = mode === "proto";
  const side = proto ? "app" : mode;
  return {
    root: path.resolve(import.meta.dirname, side),
    base: proto ? "./" : `/${side}/`,
    envDir: import.meta.dirname,
    plugins: [react(), tailwindcss(), ...(side === "app" && !proto ? [homeScreen(`/${side}/`)] : [])],
    resolve: { alias: { "@": path.resolve(import.meta.dirname, "src") } },
    define: { __PROTO__: JSON.stringify(proto) },
    build: {
      outDir: path.resolve(import.meta.dirname, proto ? "dist-proto" : `dist/${side}`),
      emptyOutDir: true,
      // the admin side's review page (VITE_DEMO=1, src/admin/demo.ts) is one file: inline every asset
      assetsInlineLimit: process.env.VITE_DEMO === "1" ? 100_000_000 : 0, chunkSizeWarningLimit: 2000,
      // the review page is one file: no lazy chunks to fetch
      ...(proto ? { rollupOptions: { output: { codeSplitting: false } } } : {}),
    },
    server: { host: "127.0.0.1" },
  };
});
