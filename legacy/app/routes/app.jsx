import { NavLink, Outlet, useLoaderData, useRouteError } from "react-router";
import { boundary } from "@shopify/shopify-app-react-router/server";
import { AppProvider } from "@shopify/shopify-app-react-router/react";
import { authenticate } from "../shopify.server";
import prisma from "../db.server";

export const loader = async ({ request }) => {
  await authenticate.admin(request);

  const lastSync = await prisma.syncRun.findFirst({
    orderBy: { startedAt: "desc" },
    select: { status: true, startedAt: true },
  });

  return {
    apiKey: process.env.SHOPIFY_API_KEY || "",
    lastSync,
  };
};

const NAV = [
  { to: "/app", label: "Dashboard", end: true },
  { to: "/app/inventory", label: "Inventory" },
  { to: "/app/reconcile", label: "Reconcile" },
  { to: "/app/ledger", label: "Ledger" },
  { to: "/app/alerts", label: "Alerts" },
  { to: "/app/sync", label: "Sync" },
];

export default function App() {
  const { apiKey, lastSync } = useLoaderData();

  const synced = lastSync?.status === "success";

  return (
    <AppProvider embedded apiKey={apiKey}>
      <div className="min-h-full">
        <header className="sticky top-0 z-20 border-b border-fog bg-oat/90 backdrop-blur">
          <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-x-6 gap-y-2 px-6 py-3.5">
            <NavLink to="/app" className="flex items-center gap-3">
              <span className="grid h-9 w-9 place-items-center rounded-xl bg-olive font-display text-lg text-cream">
                H
              </span>
              <span className="leading-tight">
                <span className="block font-display text-lg text-ink">
                  Herbal Healers
                </span>
                <span className="block text-[10px] font-semibold uppercase tracking-[0.16em] text-mocha">
                  Inventory ops
                </span>
              </span>
            </NavLink>

            <nav className="flex flex-wrap items-center gap-1">
              {NAV.map((item) => (
                <NavLink
                  key={item.to}
                  to={item.to}
                  end={item.end}
                  className={({ isActive }) =>
                    [
                      "rounded-full px-3.5 py-1.5 text-sm font-medium transition-colors",
                      isActive
                        ? "bg-olive text-cream"
                        : "text-mocha hover:bg-haze hover:text-ink",
                    ].join(" ")
                  }
                >
                  {item.label}
                </NavLink>
              ))}
            </nav>

            <span
              className={`pill ${synced ? "pill-fern" : "pill-clay"}`}
              title={
                lastSync
                  ? `Last sync: ${new Date(lastSync.startedAt).toLocaleString()}`
                  : "No sync recorded yet"
              }
            >
              <span
                className={`dot ${synced ? "bg-fern" : "bg-clay"}`}
              />
              {synced ? "Synced" : "Needs sync"}
            </span>
          </div>
        </header>

        <main className="mx-auto max-w-6xl px-6 py-8">
          <Outlet />
        </main>
      </div>
    </AppProvider>
  );
}

export function ErrorBoundary() {
  return boundary.error(useRouteError());
}

export const headers = (headersArgs) => {
  return boundary.headers(headersArgs);
};
