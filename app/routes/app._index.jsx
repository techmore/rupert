import { useLoaderData } from "react-router";
import { boundary } from "@shopify/shopify-app-react-router/server";
import { authenticate } from "../shopify.server";
import prisma from "../db.server";
import { dateTime, money, sumLevels } from "../lib/format";

export const loader = async ({ request }) => {
  await authenticate.admin(request);

  const daysAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
  const openAlertWindow = new Date(Date.now() - 14 * 24 * 60 * 60 * 1000);

  const [
    productCount,
    variantCount,
    skuLinkCount,
    alertGroups,
    recentRuns,
    recentSyncs,
    ledgerGroups,
    linkedSkuLinks,
    recentAlerts,
  ] = await Promise.all([
    prisma.shopifyProduct.count(),
    prisma.shopifyVariant.count(),
    prisma.skuLink.count(),
    prisma.stockAlert.groupBy({ by: ["status"], _count: true }),
    prisma.reconcileRun.findMany({
      orderBy: { startedAt: "desc" },
      take: 5,
    }),
    prisma.syncRun.findMany({
      orderBy: { startedAt: "desc" },
      take: 5,
    }),
    prisma.ledgerEntry.groupBy({
      by: ["source"],
      _sum: { grossCents: true },
      _count: true,
      where: { occurredAt: { gte: daysAgo } },
    }),
    prisma.skuLink.findMany({
      where: {
        shopifyVariantId: { not: null },
        squareVariationId: { not: null },
      },
      select: {
        id: true,
        shopifyVariant: {
          select: { levels: { select: { quantity: true } } },
        },
        squareVariation: {
          select: { levels: { select: { quantity: true } } },
        },
      },
    }),
    prisma.stockAlert.findMany({
      where: { status: "open", createdAt: { gte: openAlertWindow } },
      orderBy: { createdAt: "desc" },
      take: 5,
    }),
  ]);

  const drifting = linkedSkuLinks.filter((link) => {
    const shopifyQty = sumLevels(link.shopifyVariant?.levels);
    const squareQty = sumLevels(link.squareVariation?.levels);
    return shopifyQty !== squareQty;
  }).length;

  const alertMap = Object.fromEntries(
    alertGroups.map((group) => [group.status, group._count]),
  );

  return {
    productCount,
    variantCount,
    skuLinkCount,
    linkedCount: linkedSkuLinks.length,
    drifting,
    openAlerts: alertMap.open || 0,
    recentRuns,
    recentSyncs,
    ledgerGroups,
    recentAlerts,
  };
};

export default function Dashboard() {
  const data = useLoaderData();

  const today = new Date().toLocaleDateString("en-US", {
    weekday: "long",
    month: "long",
    day: "numeric",
  });

  const stats = [
    { label: "Active products", value: data.productCount, note: "Shopify mirror" },
    { label: "Tracked variants", value: data.variantCount, note: `${data.linkedCount} linked to Square` },
    { label: "Out of sync SKUs", value: data.drifting, note: "Shopify vs Square" },
    { label: "Open alerts", value: data.openAlerts, note: "Low stock flags" },
  ];

  return (
    <div className="space-y-10">
      <section>
        <p className="eyebrow mb-2 text-olive">{today}</p>
        <h1 className="font-display text-4xl text-ink md:text-5xl">
          Inventory, in one place.
        </h1>
        <p className="mt-3 max-w-xl text-mocha">
          Shopify and Square mirror into a single database — products,
          quantities, drift, and the money side of every order.
        </p>
      </section>

      <section className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        {stats.map((stat) => (
          <div key={stat.label} className="stat">
            <p className="stat-label">{stat.label}</p>
            <p className="stat-value mt-1">{stat.value}</p>
            <p className="mt-1 text-xs text-taupe">{stat.note}</p>
          </div>
        ))}
      </section>

      <section className="grid gap-4 lg:grid-cols-2">
        <div className="card card-pad">
          <h2 className="font-display text-xl text-ink">Latest reconcile runs</h2>
          <ul className="mt-4 divide-y divide-fog">
            {data.recentRuns.length === 0 && (
              <li className="py-3 text-sm text-taupe">No runs yet.</li>
            )}
            {data.recentRuns.map((run) => (
              <li key={run.id} className="flex items-center justify-between gap-4 py-3">
                <div className="min-w-0">
                  <p className="truncate text-sm font-medium text-ink">
                    {run.mode} run
                  </p>
                  <p className="text-xs text-taupe">{dateTime(run.startedAt)}</p>
                </div>
                <div className="flex items-center gap-2">
                  <span
                    className={`pill ${
                      run.status === "applied"
                        ? "pill-fern"
                        : run.status === "failed"
                          ? "pill-rose"
                          : "pill-taupe"
                    }`}
                  >
                    {run.status}
                  </span>
                  <span className="text-xs text-mocha">
                    {run.applied}/{run.actionable}
                  </span>
                </div>
              </li>
            ))}
          </ul>
        </div>

        <div className="card card-pad">
          <h2 className="font-display text-xl text-ink">Sync history</h2>
          <ul className="mt-4 divide-y divide-fog">
            {data.recentSyncs.length === 0 && (
              <li className="py-3 text-sm text-taupe">
                No syncs recorded. The ops console writes each pull here.
              </li>
            )}
            {data.recentSyncs.map((sync) => (
              <li key={sync.id} className="flex items-center justify-between gap-4 py-3">
                <div className="min-w-0">
                  <p className="truncate text-sm font-medium text-ink">
                    {sync.source || sync.mode} sync
                  </p>
                  <p className="text-xs text-taupe">{dateTime(sync.startedAt)}</p>
                </div>
                <span
                  className={`pill ${
                    sync.status === "success"
                      ? "pill-fern"
                      : sync.status === "failed"
                        ? "pill-rose"
                        : "pill-taupe"
                  }`}
                >
                  {sync.status}
                </span>
              </li>
            ))}
          </ul>
        </div>
      </section>

      <section className="grid gap-4 lg:grid-cols-2">
        <div className="card card-pad">
          <div className="flex items-baseline justify-between">
            <h2 className="font-display text-xl text-ink">Revenue · last 30 days</h2>
            <span className="text-xs text-taupe">per source</span>
          </div>
          <dl className="mt-4 grid grid-cols-2 gap-4">
            {data.ledgerGroups.map((group) => (
              <div key={group.source} className="rounded-xl bg-haze px-4 py-3">
                <dt className="text-xs font-medium capitalize text-mocha">
                  {group.source}
                </dt>
                <dd className="font-display text-2xl text-ink">
                  {money(group._sum.grossCents)}
                </dd>
                <dd className="text-xs text-taupe">{group._count} orders</dd>
              </div>
            ))}
            {data.ledgerGroups.length === 0 && (
              <p className="text-sm text-taupe">No ledger entries this month.</p>
            )}
          </dl>
        </div>

        <div className="card card-pad">
          <h2 className="font-display text-xl text-ink">Stock alerts · last 14 days</h2>
          <ul className="mt-4 divide-y divide-fog">
            {data.recentAlerts.length === 0 && (
              <li className="py-3 text-sm text-taupe">No recent alerts.</li>
            )}
            {data.recentAlerts.map((alert) => (
              <li key={alert.id} className="flex items-center justify-between gap-4 py-3">
                <div className="min-w-0">
                  <p className="truncate text-sm font-medium text-ink">
                    {alert.sku || alert.id.slice(0, 10)}
                  </p>
                  <p className="text-xs text-taupe">{dateTime(alert.createdAt)}</p>
                </div>
                <span
                  className={`pill ${
                    alert.quantity <= 0 ? "pill-rose" : "pill-clay"
                  }`}
                >
                  {alert.quantity} / {alert.threshold}
                </span>
              </li>
            ))}
          </ul>
        </div>
      </section>
    </div>
  );
}

export const headers = (headersArgs) => {
  return boundary.headers(headersArgs);
};
