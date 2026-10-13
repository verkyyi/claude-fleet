import path from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// One source, two builds — every byte local, no CDN (issue #3637):
//   npm run build        dist/ — served by ../server.mjs at /, its API /api (committed)
//   npm run build:site   the website's /chat (issue #3646): base /chat/, its API the
//                        entry's /v1/chat, the site's top bar. bin/web-chat-pack.sh
//                        writes it into tokenledger/web/dist/chat/ before the hub
//                        image is built — gitignored, never a committed copy.
export default defineConfig(({ mode }) => ({
  base: mode === "site" ? "/chat/" : "/",
  plugins: [react(), tailwindcss()],
  resolve: { alias: { "@": path.resolve(import.meta.dirname, "src") } },
  build: { outDir: mode === "site" ? "dist-site" : "dist", emptyOutDir: true, assetsInlineLimit: 0, chunkSizeWarningLimit: 2000 },
  server: { host: "127.0.0.1", proxy: { "/api": "http://127.0.0.1:18961" } },
}));
