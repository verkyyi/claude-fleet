// The admin side's entry (EPIC #3923 C10): /admin, an admin's only — the hub
// answers anyone else the 404 an unknown address gets before this file is
// ever sent (tokenledger/internal/api/app_mount.go). Its own build
// (vite --mode admin), so none of it rides in the member side's bundle.
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { createBrowserRouter, createMemoryRouter, Navigate, RouterProvider } from "react-router";
import "./admin.css";
import { AdminShell, NotFound } from "./AdminShell";
import { PeoplePage } from "./pages/People";

const routes = [
  {
    path: "/",
    element: <AdminShell />,
    children: [
      { index: true, element: <Navigate to="/people" replace /> },
      { path: "people", element: <PeoplePage /> },
      { path: "people/:p", element: <PeoplePage /> },
      { path: "*", element: <NotFound /> },
    ],
  },
];

// The prototype (VITE_DEMO=1) is one file framed anywhere: its routes live in memory.
const router =
  import.meta.env.VITE_DEMO === "1" ? createMemoryRouter(routes, { initialEntries: ["/people"] }) : createBrowserRouter(routes, { basename: "/admin" });

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <RouterProvider router={router} />
  </StrictMode>,
);
