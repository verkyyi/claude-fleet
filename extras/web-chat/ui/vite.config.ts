import path from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// Every byte local, no CDN (issue #3637): npm run build → dist/, served by
// ../server.mjs at /, its API /api (committed). The website's /chat build went
// with the old console (claude-fleet#3939): the conversation is the console's
// front page, /app.
export default defineConfig(() => ({
  base: "/",
  plugins: [react(), tailwindcss()],
  resolve: { alias: { "@": path.resolve(import.meta.dirname, "src") } },
  build: { outDir: "dist", emptyOutDir: true, assetsInlineLimit: 0, chunkSizeWarningLimit: 2000 },
  server: { host: "127.0.0.1", proxy: { "/api": "http://127.0.0.1:18961" } },
}));
