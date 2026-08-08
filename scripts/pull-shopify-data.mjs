import fs from "node:fs";

const required = ["SHOPIFY_SHOP", "SHOPIFY_CLIENT_ID", "SHOPIFY_CLIENT_SECRET"];
const missing = required.filter((name) => !process.env[name]);

if (missing.length) {
  console.error(`Missing environment variables: ${missing.join(", ")}`);
  process.exit(1);
}

const shop = process.env.SHOPIFY_SHOP.replace(/^https?:\/\//, "").replace(/\/$/, "");
const tokenResponse = await fetch(`https://${shop}/admin/oauth/access_token`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    client_id: process.env.SHOPIFY_CLIENT_ID,
    client_secret: process.env.SHOPIFY_CLIENT_SECRET,
    grant_type: "client_credentials",
  }),
});

if (!tokenResponse.ok) {
  console.error(`Token exchange failed (${tokenResponse.status}): ${await tokenResponse.text()}`);
  process.exit(1);
}

const { access_token: accessToken } = await tokenResponse.json();
const query = `#graphql
  query InventorySetupProducts($first: Int!, $query: String) {
    shop { name myshopifyDomain }
    products(first: $first, query: $query, sortKey: TITLE) {
      nodes {
        id
        title
        status
        handle
        publishedAt
        resourcePublicationsCount { count }
        variants(first: 100) {
          nodes { id title sku price }
        }
      }
    }
  }
`;

const apiResponse = await fetch(`https://${shop}/admin/api/2026-07/graphql.json`, {
  method: "POST",
  headers: {
    "content-type": "application/json",
    "x-shopify-access-token": accessToken,
  },
  body: JSON.stringify({
    query,
    variables: { first: 100, query: process.env.SHOPIFY_PRODUCT_QUERY || null },
  }),
});

const payload = await apiResponse.json();
if (!apiResponse.ok || payload.errors) {
  console.error(JSON.stringify(payload, null, 2));
  process.exit(1);
}

const output = JSON.stringify(payload.data, null, 2);
if (process.env.SHOPIFY_OUTPUT_FILE) {
  fs.writeFileSync(process.env.SHOPIFY_OUTPUT_FILE, `${output}\n`, { mode: 0o600 });
  console.log(`Saved Shopify data to ${process.env.SHOPIFY_OUTPUT_FILE}`);
} else {
  console.log(output);
}
