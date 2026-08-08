import { redirect, Form, useLoaderData } from "react-router";
import { login } from "../../shopify.server";

export const loader = async ({ request }) => {
  const url = new URL(request.url);

  if (url.searchParams.get("shop")) {
    throw redirect(`/app?${url.searchParams.toString()}`);
  }

  return { showForm: Boolean(login) };
};

const features = [
  {
    title: "Automate your workflow",
    body: "Move data between your sales channels on autopilot — no manual exports, no missed updates.",
    accent: "from-emerald to-ocean",
    icon: "M3 17l6-6 4 4 8-8 M13 7h8v8",
  },
  {
    title: "Real-time insights",
    body: "Track the health of every catalog and sync with clear, live dashboards across your store.",
    accent: "from-royal to-bubblegum",
    icon: "M4 19V5 M10 19V9 M16 19V3 M22 19V12",
  },
  {
    title: "Works everywhere you do",
    body: "First-class support for the apps and marketplaces your business already runs on.",
    accent: "from-bubblegum to-royal",
    icon: "M12 3v18M3 12h18M12 3a15 15 0 019 0M12 21a15 15 0 019 0M3 12a15 15 0 019 9",
  },
  {
    title: "Secure by default",
    body: "Permission-aware access to your store data, with full Shopify audit logging on every action.",
    accent: "from-ocean to-emerald",
    icon: "M12 3l7 3v5c0 5-3 8.5-7 10-4-1.5-7-5-7-10V6l7-3z",
  },
];

export default function App() {
  const { showForm } = useLoaderData();

  return (
    <div className="min-h-dvh bg-teal text-white">
      <header className="sticky top-0 z-20 border-b border-white/10 bg-teal/80 backdrop-blur">
        <nav className="mx-auto flex h-16 max-w-6xl items-center justify-between px-4 sm:px-6">
          <a href="/" className="flex items-center gap-2.5">
            <span className="flex h-8 w-8 items-center justify-center rounded-lg bg-gradient-to-br from-emerald to-ocean shadow-lg shadow-ocean/40">
              <svg
                className="h-4 w-4 text-white"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2.5"
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                <path d="M22 12h-6l-2 3h-4l-2-3H2" />
                <path d="M5.5 5.1 4.7 6.9M3.5 8.1l-1.3 2.4M8.8 5.1l.7-1.8" />
              </svg>
            </span>
            <span className="text-lg font-bold tracking-tight">
              Prisma<span className="text-royal">Sync</span>
            </span>
          </a>
          <div className="hidden items-center gap-8 text-sm font-medium text-white/70 md:flex">
            <a href="#features" className="transition hover:text-royal">
              Features
            </a>
            <a href="#how-it-works" className="transition hover:text-royal">
              How it works
            </a>
            <a href="#get-started" className="transition hover:text-royal">
              Get started
            </a>
          </div>
          {showForm && (
            <a
              href="#get-started"
              className="hidden rounded-lg bg-royal px-4 py-2 text-sm font-semibold text-teal transition hover:bg-white sm:block"
            >
              Log in
            </a>
          )}
        </nav>
      </header>

      <main>
        <section className="relative overflow-hidden">
          <div
            aria-hidden="true"
            className="pointer-events-none absolute -top-32 left-1/2 h-96 w-96 -translate-x-1/2 rounded-full bg-ocean/30 blur-3xl"
          />
          <div
            aria-hidden="true"
            className="pointer-events-none absolute right-0 top-24 h-72 w-72 rounded-full bg-bubblegum/20 blur-3xl"
          />
          <div
            aria-hidden="true"
            className="pointer-events-none absolute bottom-0 -left-24 h-72 w-72 rounded-full bg-emerald/20 blur-3xl"
          />

          <div className="relative mx-auto max-w-4xl px-4 py-24 text-center sm:px-6 sm:py-32">
            <span className="inline-flex items-center gap-2 rounded-full border border-white/15 bg-white/5 px-4 py-1.5 text-xs font-semibold tracking-wide text-white/80 uppercase">
              <span className="h-2 w-2 rounded-full bg-emerald" />
              Catalog automation
            </span>
            <h1 className="mt-6 text-4xl font-extrabold tracking-tight sm:text-6xl">
              The growth engine{" "}
              <span className="bg-gradient-to-r from-bubblegum via-royal to-emerald bg-clip-text text-transparent">
                for your storefront
              </span>
            </h1>
            <p className="mx-auto mt-6 max-w-2xl text-lg text-white/70 sm:text-xl">
              Sync products, inventory, and orders across every channel with
              one elegant workflow. Real-time, permission-aware, and built
              for Shopify.
            </p>

            {showForm ? (
              <div className="mt-10">
                <Form
                  id="get-started"
                  method="post"
                  action="/auth/login"
                  className="mx-auto flex max-w-md flex-col gap-3 rounded-2xl border border-white/10 bg-white/5 p-2 backdrop-blur sm:flex-row"
                >
                  <label className="sr-only" htmlFor="shop">
                    Shop domain
                  </label>
                  <input
                    id="shop"
                    className="w-full flex-1 rounded-xl border-0 bg-transparent px-4 py-3 text-white placeholder-white/40 outline-none focus:ring-2 focus:ring-emerald"
                    type="text"
                    name="shop"
                    placeholder="your-store.myshopify.com"
                  />
                  <button
                    type="submit"
                    className="shrink-0 rounded-xl bg-bubblegum px-6 py-3 font-semibold text-white shadow-lg shadow-bubblegum/30 transition hover:bg-[#d9365d]"
                  >
                    Get started
                  </button>
                </Form>
                <p className="mt-4 text-sm text-white/50">
                  Connect your store to start syncing in minutes.
                </p>
              </div>
            ) : (
              <div className="mt-10 flex flex-wrap items-center justify-center gap-4">
                <a
                  href="#get-started"
                  className="rounded-xl bg-bubblegum px-6 py-3 font-semibold text-white shadow-lg shadow-bubblegum/30 transition hover:bg-[#d9365d]"
                >
                  Get started
                </a>
                <a
                  href="#features"
                  className="rounded-xl border border-white/15 bg-white/5 px-6 py-3 font-semibold text-white transition hover:bg-white/10"
                >
                  See features
                </a>
              </div>
            )}

            <dl className="mx-auto mt-16 grid max-w-2xl grid-cols-3 gap-8 border-t border-white/10 pt-10">
              {[
                ["99.9%", "Uptime"],
                ["< 30s", "Sync latency"],
                ["5★", "Support"],
              ].map(([value, label]) => (
                <div key={label}>
                  <dt className="order-2 mt-1 text-xs font-medium tracking-wide text-white/50 uppercase">
                    {label}
                  </dt>
                  <dd className="text-2xl font-extrabold text-royal sm:text-3xl">
                    {value}
                  </dd>
                </div>
              ))}
            </dl>
          </div>
        </section>

        <section id="features" className="relative border-t border-white/10 bg-teal/60">
          <div className="mx-auto max-w-6xl px-4 py-20 sm:px-6">
            <div className="max-w-2xl">
              <h2 className="text-3xl font-extrabold tracking-tight sm:text-4xl">
                Everything your store needs,{" "}
                <span className="text-emerald">in one place</span>
              </h2>
              <p className="mt-4 text-white/70">
                Powerful automation without the setup headache — get your catalog
                flowing across every channel.
              </p>
            </div>

            <div className="mt-12 grid gap-6 sm:grid-cols-2 lg:grid-cols-4">
              {features.map((feature) => (
                <div
                  key={feature.title}
                  className="group rounded-2xl border border-white/10 bg-white/5 p-6 transition hover:-translate-y-1 hover:border-white/20 hover:bg-white/10"
                >
                  <span
                    className={`inline-flex h-11 w-11 items-center justify-center rounded-xl bg-gradient-to-br ${feature.accent} shadow-lg`}
                  >
                    <svg
                      className="h-5 w-5 text-white"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="2"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    >
                      <path d={feature.icon} />
                    </svg>
                  </span>
                  <h3 className="mt-4 text-lg font-bold">{feature.title}</h3>
                  <p className="mt-2 text-sm leading-relaxed text-white/60">
                    {feature.body}
                  </p>
                  <a
                    href="#get-started"
                    className="mt-4 inline-flex items-center gap-1 text-sm font-semibold text-royal transition group-hover:gap-2"
                  >
                    Learn more
                    <svg
                      className="h-4 w-4"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="2"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    >
                      <path d="M5 12h14m-6-6 6 6-6 6" />
                    </svg>
                  </a>
                </div>
              ))}
            </div>
          </div>
        </section>

        <section
          id="how-it-works"
          className="border-t border-white/10 bg-gradient-to-b from-teal to-ocean/40"
        >
          <div className="mx-auto max-w-6xl px-4 py-20 sm:px-6">
            <div className="grid items-center gap-12 lg:grid-cols-2">
              <div>
                <h2 className="text-3xl font-extrabold tracking-tight sm:text-4xl">
                  Set up once.{" "}
                  <span className="bg-gradient-to-r from-royal to-emerald bg-clip-text text-transparent">
                    Sync forever.
                  </span>
                </h2>
                <p className="mt-4 text-white/70">
                  PrismaSync watches your store and keeps every channel in
                  lockstep — so you can focus on selling.
                </p>
                <ol className="mt-8 space-y-4">
                  {[
                    ["Connect", "Link your Shopify store in one click using secure OAuth."],
                    ["Configure", "Choose your mapping, rules, and which fields to sync."],
                    ["Relax", "Automation handles every update, from variants to stock."],
                  ].map(([title, body], i) => (
                    <li key={title} className="flex gap-4">
                      <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-royal text-sm font-extrabold text-teal">
                        {i + 1}
                      </span>
                      <div>
                        <h3 className="font-bold">{title}</h3>
                        <p className="text-sm text-white/60">{body}</p>
                      </div>
                    </li>
                  ))}
                </ol>
              </div>
              <div className="relative">
                <div
                  aria-hidden="true"
                  className="absolute -inset-4 rounded-3xl bg-gradient-to-br from-emerald/40 via-bubblegum/20 to-royal/40 blur-2xl"
                />
                <div className="relative rounded-2xl border border-white/10 bg-white/5 p-6 backdrop-blur">
                  <div className="flex items-center gap-2">
                    <span className="h-3 w-3 rounded-full bg-bubblegum" />
                    <span className="h-3 w-3 rounded-full bg-royal" />
                    <span className="h-3 w-3 rounded-full bg-emerald" />
                    <span className="ml-3 text-xs font-medium text-white/50">
                      Sync activity
                    </span>
                  </div>
                  <div className="mt-6 space-y-3">
                    {[
                      ["Product added", "2,314 · Storefront", "emerald"],
                      ["Inventory updated", "1,048 · Orders", "ocean"],
                      ["Price changed", "412 · Bulk", "royal"],
                      ["Outlet synced", "198 · Positions", "bubblegum"],
                    ].map(([label, value, color]) => (
                      <div
                        key={label}
                        className="flex items-center justify-between rounded-xl border border-white/10 bg-teal/50 px-4 py-3"
                      >
                        <span className="flex items-center gap-3 text-sm font-medium">
                          <span
                            className={
                              {
                                emerald: "h-2.5 w-2.5 rounded-full bg-emerald",
                                ocean: "h-2.5 w-2.5 rounded-full bg-ocean",
                                royal: "h-2.5 w-2.5 rounded-full bg-royal",
                                bubblegum:
                                  "h-2.5 w-2.5 rounded-full bg-bubblegum",
                              }[color]
                            }
                          />
                          {label}
                        </span>
                        <span className="text-sm text-white/50">{value}</span>
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section id="get-started" className="border-t border-white/10">
          <div className="mx-auto max-w-3xl px-4 py-20 text-center sm:px-6">
            <h2 className="text-3xl font-extrabold tracking-tight sm:text-4xl">
              Ready to simplify your{" "}
              <span className="text-bubblegum">workflow?</span>
            </h2>
            <p className="mt-4 text-lg text-white/70">
              Install PrismaSync today and keep your entire business on
              schedule.
            </p>
            {showForm && (
              <div className="mt-10">
                <Form
                  method="post"
                  action="/auth/login"
                  className="mx-auto flex max-w-md flex-col gap-3 rounded-2xl border border-white/10 bg-white/5 p-2 backdrop-blur sm:flex-row"
                >
                  <label className="sr-only" htmlFor="shop-cta">
                    Shop domain
                  </label>
                  <input
                    id="shop-cta"
                    className="w-full flex-1 rounded-xl border-0 bg-transparent px-4 py-3 text-white placeholder-white/40 outline-none focus:ring-2 focus:ring-royal"
                    type="text"
                    name="shop"
                    placeholder="my-shop.myshopify.com"
                  />
                  <button
                    type="submit"
                    className="shrink-0 rounded-xl bg-emerald px-6 py-3 font-semibold text-teal shadow-lg shadow-emerald/30 transition hover:bg-[#05c28f]"
                  >
                    Connect store
                  </button>
                </Form>
              </div>
            )}
          </div>
        </section>
      </main>

      <footer className="border-t border-white/10 bg-black/20">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 px-4 py-8 sm:flex-row sm:px-6">
          <p className="text-sm text-white/50">
            © {new Date().getFullYear()} PrismaSync. Built for Shopify.
          </p>
          <div className="flex gap-6 text-sm text-white/50">
            <a href="#features" className="transition hover:text-royal">
              Features
            </a>
            <a href="#how-it-works" className="transition hover:text-royal">
              How it works
            </a>
            <a href="/auth/login" className="transition hover:text-royal">
              Log in
            </a>
          </div>
        </div>
      </footer>
    </div>
  );
}