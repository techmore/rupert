import { useLoaderData } from "react-router";
import { boundary } from "@shopify/shopify-app-react-router/server";
import { authenticate } from "../shopify.server";
import prisma from "../db.server";
import { driftFor, money } from "../lib/format";

export const loader = async ({ request }) => {
  await authenticate.admin(request);

  const url = new URL(request.url);
  const q = url.searchParams.get("q")?.trim() || "";

  const products = await prisma.shopifyProduct.findMany({
    where: q
      ? {
          OR: [
            { title: { contains: q } },
            { variants: { some: { sku: { contains: q } } } },
          ],
        }
      : undefined,
    orderBy: { title: "asc" },
    take: 40,
    include: {
      variants: {
        orderBy: { title: "asc" },
        include: {
          levels: { select: { quantity: true } },
          skuLinks: {
            include: {
              squareVariation: {
                include: { levels: { select: { quantity: true } } },
              },
            },
          },
        },
      },
    },
  });

  return { q, products };
};

export default function Inventory() {
  const { q, products } = useLoaderData();

  return (
    <div className="space-y-6">
      <section>
        <h1 className="font-display text-3xl text-ink">Inventory</h1>
        <p className="mt-1 text-sm text-mocha">
          Products mirrored from Shopify, with quantities on both sides.
        </p>
      </section>

      <form method="get" className="max-w-sm">
        <input
          type="search"
          name="q"
          defaultValue={q}
          placeholder="Search products or SKUs…"
          className="input"
          autoComplete="off"
        />
      </form>

      <div className="card overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-fog bg-haze/60">
              <tr>
                <th className="th">Product / Variant</th>
                <th className="th">SKU</th>
                <th className="th text-right">Price</th>
                <th className="th text-right">Shopify</th>
                <th className="th text-right">Square</th>
                <th className="th text-right">Drift</th>
                <th className="th">Linked</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-fog">
              {products.length === 0 && (
                <tr>
                  <td className="td py-8 text-center text-taupe">
                    {q ? "Nothing matches that search." : "No products mirrored yet."}
                  </td>
                </tr>
              )}
              {products.map((product) => (
                <ProductRows key={product.id} product={product} />
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {products.length >= 40 && (
        <p className="text-xs text-taupe">
          Showing the first 40 products — refine your search to narrow down.
        </p>
      )}
    </div>
  );
}

function ProductRows({ product }) {
  return product.variants.map((variant) => {
    const { shopifyQty, squareQty, drift } = driftFor(variant);
    return (
      <tr key={variant.id} className="hover:bg-cream">
        <td className="td">
          <p className="font-medium text-ink">{variant.title}</p>
          <p className="text-xs text-taupe">{product.title}</p>
        </td>
        <td className="td font-mono text-xs text-mocha">{variant.sku || "—"}</td>
        <td className="td text-right font-medium text-ink">
          {money(Math.round((variant.price || 0) * 100))}
        </td>
        <td className="td text-right text-mocha">{shopifyQty}</td>
        <td className="td text-right text-mocha">{squareQty}</td>
        <td className="td text-right">
          <span
            className={
              drift === 0
                ? "font-medium text-taupe"
                : "font-semibold text-clay"
            }
          >
            {drift === 0 ? "—" : drift > 0 ? `+${drift}` : drift}
          </span>
        </td>
        <td className="td">
          {variant.skuLinks.length > 0 ? (
            <span className="pill-fern">linked</span>
          ) : (
            <span className="pill-taupe">unlinked</span>
          )}
        </td>
      </tr>
    );
  });
}

export const headers = (headersArgs) => {
  return boundary.headers(headersArgs);
};
