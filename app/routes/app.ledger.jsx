import { useLoaderData } from "react-router";
import { boundary } from "@shopify/shopify-app-react-router/server";
import { authenticate } from "../shopify.server";
import prisma from "../db.server";
import { dateTime, money } from "../lib/format";

export const loader = async ({ request }) => {
  await authenticate.admin(request);

  const url = new URL(request.url);
  const source = url.searchParams.get("source") || "all";
  const windowDays = Math.min(365, Number(url.searchParams.get("window") || 30) || 30);
  const since = new Date(Date.now() - windowDays * 24 * 60 * 60 * 1000);

  const where = {
    occurredAt: { gte: since },
    ...(source !== "all" ? { source } : {}),
  };

  const [entries, groups] = await Promise.all([
    prisma.ledgerEntry.findMany({
      where,
      orderBy: { occurredAt: "desc" },
      take: 200,
    }),
    prisma.ledgerEntry.groupBy({
      by: ["source"],
      _sum: { grossCents: true },
      _count: true,
      where,
    }),
  ]);

  return { source, windowDays, entries, groups };
};

export default function Ledger() {
  const { source, windowDays, entries, groups } = useLoaderData();

  const total = groups.reduce((sum, group) => sum + group._sum.grossCents, 0);

  return (
    <div className="space-y-6">
      <section>
        <h1 className="font-display text-3xl text-ink">Ledger</h1>
        <p className="mt-1 text-sm text-mocha">
          Central transaction ledger across Shopify and Square.
        </p>
      </section>

      <section className="grid grid-cols-2 gap-4 lg:grid-cols-3">
        <div className="stat">
          <p className="stat-label">Total · {windowDays} days</p>
          <p className="stat-value mt-1">{money(total)}</p>
          <p className="mt-1 text-xs text-taupe">{entries.length} shown</p>
        </div>
        {groups.map((group) => (
          <div key={group.source} className="stat">
            <p className="stat-label capitalize">{group.source}</p>
            <p className="stat-value mt-1">{money(group._sum.grossCents)}</p>
            <p className="mt-1 text-xs text-taupe">{group._count} orders</p>
          </div>
        ))}
      </section>

      <form method="get" className="flex flex-wrap items-center gap-3">
        <select name="window" defaultValue={windowDays} className="select">
          <option value="7">Last 7 days</option>
          <option value="30">Last 30 days</option>
          <option value="90">Last 90 days</option>
          <option value="365">Last year</option>
        </select>
        <select name="source" defaultValue={source} className="select">
          <option value="all">All sources</option>
          <option value="shopify">Shopify</option>
          <option value="square">Square</option>
        </select>
        <button type="submit" className="btn-ghost btn-sm">
          Filter
        </button>
      </form>

      <div className="card overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-fog bg-haze/60">
              <tr>
                <th className="th">Date</th>
                <th className="th">Source</th>
                <th className="th">Order</th>
                <th className="th text-right">Gross</th>
                <th className="th">Status</th>
                <th className="th text-right">Lines</th>
                <th className="th">Summary</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-fog">
              {entries.length === 0 && (
                <tr>
                  <td className="td py-8 text-center text-taupe">
                    No ledger entries in this range.
                  </td>
                </tr>
              )}
              {entries.map((entry) => (
                <tr key={entry.id} className="hover:bg-cream">
                  <td className="td whitespace-nowrap text-mocha">
                    {dateTime(entry.occurredAt)}
                  </td>
                  <td className="td">
                    <span className="pill-taupe capitalize">{entry.source}</span>
                  </td>
                  <td className="td font-medium text-ink">
                    {entry.orderName || entry.sourceOrderId.slice(0, 12)}
                  </td>
                  <td className="td text-right font-medium text-ink">
                    {money(entry.grossCents)}
                  </td>
                  <td className="td">
                    <span
                      className={`pill ${
                        entry.status === "PAID" ||
                        entry.status === "COMPLETED" ||
                        entry.status === "CLOSED"
                          ? "pill-fern"
                          : "pill-taupe"
                      }`}
                    >
                      {entry.status}
                    </span>
                  </td>
                  <td className="td text-right text-mocha">{entry.lineItems}</td>
                  <td className="td max-w-[220px] truncate text-xs text-taupe">
                    {entry.summary || "—"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

export const headers = (headersArgs) => {
  return boundary.headers(headersArgs);
};
