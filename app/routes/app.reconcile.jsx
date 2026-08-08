import { useLoaderData, useFetcher } from "react-router";
import { boundary } from "@shopify/shopify-app-react-router/server";
import { authenticate } from "../shopify.server";
import prisma from "../db.server";
import { sumLevels } from "../lib/format";

export const loader = async ({ request }) => {
  await authenticate.admin(request);

  const [links, policies] = await Promise.all([
    prisma.skuLink.findMany({
      orderBy: { sku: "asc" },
      include: {
        shopifyVariant: {
          include: {
            product: { select: { title: true } },
            levels: { select: { quantity: true } },
          },
        },
        squareVariation: {
          include: {
            item: { select: { name: true } },
            levels: { select: { quantity: true } },
          },
        },
      },
    }),
    prisma.inventoryPolicy.findMany(),
  ]);

  const policyMap = Object.fromEntries(
    policies.map((policy) => [policy.sku, policy.priority]),
  );

  const rows = links.map((link) => {
    const shopifyQty = sumLevels(link.shopifyVariant?.levels);
    const squareQty = sumLevels(link.squareVariation?.levels);
    return {
      id: link.id,
      sku: link.sku,
      product:
        link.shopifyVariant?.product?.title ||
        link.squareVariation?.item?.name ||
        "—",
      variant: link.shopifyVariant?.title || link.squareVariation?.name || "—",
      shopifyQty,
      squareQty,
      drift: shopifyQty - squareQty,
      matchSource: link.matchSource,
      priority: policyMap[link.sku] || "lowest",
    };
  });

  const drifting = rows.filter((row) => row.drift !== 0);
  const unitsDrift = drifting.reduce((total, row) => total + Math.abs(row.drift), 0);

  return { rows, stats: { total: rows.length, drifting: drifting.length, unitsDrift } };
};

export const action = async ({ request }) => {
  await authenticate.admin(request);

  const form = await request.formData();
  const sku = form.get("sku");
  const priority = form.get("priority");

  if (!sku || !priority) {
    return { ok: false, error: "sku and priority are required" };
  }

  await prisma.inventoryPolicy.upsert({
    where: { sku },
    update: { priority, updatedAt: new Date() },
    create: { sku, priority, updatedAt: new Date() },
  });

  return { ok: true, sku, priority };
};

export default function Reconcile() {
  const { rows, stats } = useLoaderData();
  const fetcher = useFetcher();

  return (
    <div className="space-y-6">
      <section>
        <h1 className="font-display text-3xl text-ink">Reconcile</h1>
        <p className="mt-1 text-sm text-mocha">
          SKU-level bridge between Shopify variants and Square variations, with
          live drift from inventory levels.
        </p>
      </section>

      <section className="grid grid-cols-3 gap-4">
        <div className="stat">
          <p className="stat-label">Linked SKUs</p>
          <p className="stat-value mt-1">{stats.total}</p>
        </div>
        <div className="stat">
          <p className="stat-label">Out of sync</p>
          <p className="stat-value mt-1">{stats.drifting}</p>
        </div>
        <div className="stat">
          <p className="stat-label">Units drift</p>
          <p className="stat-value mt-1">{stats.unitsDrift}</p>
        </div>
      </section>

      <div className="card p-4 text-sm text-mocha">
        Applying adjustments writes to Shopify and Square, so it stays in the
        ops console (<code className="font-mono text-xs">local-console.mjs</code>).
        Here you can review drift and set the per-SKU priority policy.
      </div>

      <div className="card overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-fog bg-haze/60">
              <tr>
                <th className="th">SKU</th>
                <th className="th">Product / Variant</th>
                <th className="th text-right">Shopify</th>
                <th className="th text-right">Square</th>
                <th className="th text-right">Drift</th>
                <th className="th">Priority</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-fog">
              {rows.length === 0 && (
                <tr>
                  <td className="td py-8 text-center text-taupe">
                    No SKU links yet — run a sync from the ops console first.
                  </td>
                </tr>
              )}
              {rows.map((row) => (
                <tr key={row.id} className="hover:bg-cream">
                  <td className="td font-mono text-xs text-mocha">{row.sku}</td>
                  <td className="td">
                    <p className="font-medium text-ink">{row.product}</p>
                    <p className="text-xs text-taupe">{row.variant}</p>
                  </td>
                  <td className="td text-right text-mocha">{row.shopifyQty}</td>
                  <td className="td text-right text-mocha">{row.squareQty}</td>
                  <td className="td text-right">
                    <span
                      className={
                        row.drift === 0
                          ? "font-medium text-taupe"
                          : "font-semibold text-clay"
                      }
                    >
                      {row.drift === 0 ? "—" : row.drift > 0 ? `+${row.drift}` : row.drift}
                    </span>
                  </td>
                  <td className="td">
                    <fetcher.Form method="post" className="inline-block">
                      <input type="hidden" name="sku" value={row.sku} />
                      <select
                        name="priority"
                        defaultValue={row.priority}
                        onChange={(event) => event.target.form.requestSubmit()}
                        className="select"
                      >
                        <option value="lowest">lowest</option>
                        <option value="shopify">shopify</option>
                        <option value="square">square</option>
                      </select>
                    </fetcher.Form>
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
