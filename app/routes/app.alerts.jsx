import { useLoaderData, useFetcher } from "react-router";
import { boundary } from "@shopify/shopify-app-react-router/server";
import { authenticate } from "../shopify.server";
import prisma from "../db.server";
import { dateTime } from "../lib/format";

export const loader = async ({ request }) => {
  await authenticate.admin(request);

  const url = new URL(request.url);
  const status = url.searchParams.get("status") || "open";

  const [alerts, groups] = await Promise.all([
    prisma.stockAlert.findMany({
      where: status !== "all" ? { status } : undefined,
      orderBy: { createdAt: "desc" },
      take: 100,
      include: {
        shopifyVariant: {
          include: { product: { select: { title: true } } },
        },
        squareVariation: {
          include: { item: { select: { name: true } } },
        },
      },
    }),
    prisma.stockAlert.groupBy({ by: ["status"], _count: true }),
  ]);

  const counts = Object.fromEntries(
    groups.map((group) => [group.status, group._count]),
  );

  return { status, counts, alerts };
};

export const action = async ({ request }) => {
  await authenticate.admin(request);

  const form = await request.formData();
  const id = form.get("id");
  const next = form.get("status");

  if (!id || !["resolved", "ignored"].includes(next)) {
    return { ok: false, error: "invalid id or status" };
  }

  await prisma.stockAlert.update({
    where: { id },
    data: {
      status: next,
      resolvedAt: next === "resolved" ? new Date() : null,
    },
  });

  return { ok: true };
};

const TABS = ["open", "resolved", "ignored", "all"];

export default function Alerts() {
  const { status, counts, alerts } = useLoaderData();
  const fetcher = useFetcher();

  return (
    <div className="space-y-6">
      <section>
        <h1 className="font-display text-3xl text-ink">Alerts</h1>
        <p className="mt-1 text-sm text-mocha">
          Low-stock flags raised from inventory levels.
        </p>
      </section>

      <nav className="flex flex-wrap gap-1">
        {TABS.map((tab) => (
          <a
            key={tab}
            href={`/app/alerts?status=${tab}`}
            className={[
              "rounded-full px-3.5 py-1.5 text-sm font-medium transition-colors",
              status === tab
                ? "bg-olive text-cream"
                : "text-mocha hover:bg-haze hover:text-ink",
            ].join(" ")}
          >
            {tab}
            {counts[tab] != null && (
              <span className="ml-1.5 text-xs opacity-70">{counts[tab]}</span>
            )}
          </a>
        ))}
      </nav>

      <div className="card overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-fog bg-haze/60">
              <tr>
                <th className="th">SKU</th>
                <th className="th">Product</th>
                <th className="th text-right">Qty / threshold</th>
                <th className="th">Raised</th>
                <th className="th">Status</th>
                <th className="th text-right">Action</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-fog">
              {alerts.length === 0 && (
                <tr>
                  <td className="td py-8 text-center text-taupe">
                    No alerts here.
                  </td>
                </tr>
              )}
              {alerts.map((alert) => (
                <tr key={alert.id} className="hover:bg-cream">
                  <td className="td font-mono text-xs text-mocha">
                    {alert.sku || "—"}
                  </td>
                  <td className="td">
                    <p className="font-medium text-ink">
                      {alert.shopifyVariant?.product?.title ||
                        alert.squareVariation?.item?.name ||
                        "—"}
                    </p>
                    <p className="text-xs text-taupe">
                      {alert.shopifyVariant?.title ||
                        alert.squareVariation?.name ||
                        ""}
                    </p>
                  </td>
                  <td className="td text-right">
                    <span
                      className={
                        alert.quantity <= 0
                          ? "font-semibold text-rose"
                          : "font-semibold text-clay"
                      }
                    >
                      {alert.quantity}
                    </span>
                    <span className="text-taupe"> / {alert.threshold}</span>
                  </td>
                  <td className="td whitespace-nowrap text-mocha">
                    {dateTime(alert.createdAt)}
                  </td>
                  <td className="td">
                    <span
                      className={`pill ${
                        alert.status === "open"
                          ? "pill-clay"
                          : alert.status === "resolved"
                            ? "pill-fern"
                            : "pill-taupe"
                      }`}
                    >
                      {alert.status}
                    </span>
                  </td>
                  <td className="td text-right">
                    {alert.status === "open" ? (
                      <fetcher.Form method="post" className="flex justify-end gap-1.5">
                        <input type="hidden" name="id" value={alert.id} />
                        <button
                          name="status"
                          value="resolved"
                          className="btn-ghost btn-sm"
                        >
                          Resolve
                        </button>
                        <button
                          name="status"
                          value="ignored"
                          className="btn-ghost btn-sm"
                        >
                          Ignore
                        </button>
                      </fetcher.Form>
                    ) : (
                      <span className="text-xs text-taupe">
                        {dateTime(alert.resolvedAt)}
                      </span>
                    )}
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
