// main.tsx — the member side (/app, EPIC #3923 C3): the shell and the page
// table, routed by react-router under /app. The review build (--mode proto)
// runs the same app over a mock API, in memory (it lives in an iframe's srcdoc).
import { StrictMode, Suspense, lazy, useState } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter, MemoryRouter, Navigate, Route, Routes } from "react-router";
// first: a view (?as=, claude-fleet#3944) rides every read from the start
import "@/shared/viewAs";
import "@/shared/index.css";
import "@/shared/theme";
import { AppShell } from "./Shell";
import { PAGES } from "./routes";

declare const __PROTO__: boolean;

function App() {
  const [quotaKey, setQuotaKey] = useState(0);
  return (
    <AppShell quotaKey={quotaKey} bumpQuota={() => setQuotaKey((n) => n + 1)}>
      <Suspense fallback={null}>
        <Routes>
          {PAGES.map(({ id, path, page: Page }) => Page ? <Route key={id} path={path} element={<Page />} /> : null)}
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </Suspense>
    </AppShell>
  );
}

const PublicHealth = lazy(() => import("./pages/health"));

async function start() {
  const root = createRoot(document.getElementById("root")!);
  if (!__PROTO__ && location.pathname.replace(/\/$/, "") === "/status") {
    root.render(<StrictMode><Suspense fallback={null}><PublicHealth publicPage /></Suspense></StrictMode>);
    return;
  }
  if (__PROTO__) {
    const first = await (await import("@/proto/mock")).install();
    root.render(<StrictMode><MemoryRouter initialEntries={[first]}><App /></MemoryRouter></StrictMode>);
    return;
  }
  root.render(<StrictMode><BrowserRouter basename="/app"><App /></BrowserRouter></StrictMode>);
}
start();
