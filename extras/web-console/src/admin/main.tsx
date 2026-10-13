// The admin side's entry (EPIC #3923 C10): /admin, an admin's only — the hub
// answers anyone else the 404 an unknown address gets before this file is
// ever sent (tokenledger/internal/api/app_mount.go). Its own build
// (vite --mode admin), so none of it rides in the member side's bundle.
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { createBrowserRouter, createMemoryRouter, Navigate, RouterProvider } from "react-router";
import "./admin.css";
// dark or light on <html data-theme> (the system's, or a pick made on 设置 — claude-fleet#3931)
import "@/shared/theme";
import { AdminShell, NotFound } from "./AdminShell";
import { MachineDetailPage } from "./pages/MachineDetail";
import { MachinesPage } from "./pages/Machines";
import { PoolPage } from "./pages/Pool";
import { PoolSettingsPage } from "./pages/PoolSettings";
import { ReleasePage } from "./pages/Release";
import { UsagePage } from "./pages/Usage";
import { AuditPage } from "./pages/Audit";
import { FeedbackPage } from "./pages/Feedback";
import { PeoplePage } from "./pages/People";
import { SettingsPage } from "./pages/Settings";
import { RequestsPage } from "./pages/Requests";

const routes = [
  {
    path: "/",
    element: <AdminShell />,
    children: [
      { index: true, element: <Navigate to="/people" replace /> },
      { path: "people", element: <PeoplePage /> },
      { path: "people/:p", element: <PeoplePage /> },
      { path: "machines", element: <MachinesPage /> },
      { path: "machines/:host", element: <MachineDetailPage /> },
      { path: "requests", element: <RequestsPage /> },
      { path: "requests/:id", element: <RequestsPage /> },
      { path: "release", element: <ReleasePage /> },
      { path: "release/:run", element: <ReleasePage /> },
      { path: "pool", element: <PoolPage /> },
      { path: "pool/settings", element: <PoolSettingsPage /> },
      { path: "pool/:id", element: <PoolPage /> },
      { path: "usage", element: <UsagePage /> },
      { path: "settings", element: <SettingsPage /> },
      { path: "settings/:k", element: <SettingsPage /> },
      { path: "audit", element: <AuditPage /> },
      { path: "feedback", element: <FeedbackPage /> },
      { path: "feedback/:id", element: <FeedbackPage /> },
      { path: "*", element: <NotFound /> },
    ],
  },
];

// The prototype (VITE_DEMO=1) is one file framed anywhere: its routes live in
// memory, the first one its frame's __DEMO_PAGE or ?page= (a review frame opens
// each page by it).
const router =
  import.meta.env.VITE_DEMO === "1" ? createMemoryRouter(routes, { initialEntries: [(window as any).__DEMO_PAGE || (window as any).__DEMO_PATH || new URLSearchParams(location.search).get("page") || "/people"] }) : createBrowserRouter(routes, { basename: "/admin" });

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <RouterProvider router={router} />
  </StrictMode>,
);
