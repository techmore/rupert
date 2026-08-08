import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PrismaClient } from "@prisma/client";

/* eslint-env node */

const root = path.dirname(fileURLToPath(import.meta.url));
try {
  process.loadEnvFile(path.join(root, ".env"));
} catch {
  /* .env is optional — falls back to process env */
}
const snapshotPath = path.join(root, "shopify-operations-snapshot.json");
const squareFilePath = path.join(root, "square-snapshot.json");
const logPath = path.join(root, "sync-log.jsonl");
const consoleHtmlPath = path.join(root, "console", "index.html");
const consoleJsPath = path.join(root, "console", "client.js");
const shopDomain = "m11u0i-sb.myshopify.com";
const apiVersion = "2026-07";
const port = Number(process.env.PORT || 8787);
const syncMinutes = Number(process.env.SYNC_MINUTES || 15);
const syncEveryMs = syncMinutes * 60_000;
const squareToken = process.env.SQUARE_ACCESS_TOKEN || "";
const squareEnvironment = process.env.SQUARE_ENVIRONMENT || "production";
const squareLocationId = process.env.SQUARE_LOCATION_ID || "";
const squareBase = squareEnvironment === "sandbox" ? "https://connect.squareupsandbox.com/v2" : "https://connect.squareup.com/v2";
const REVENUE_STATUSES = new Set(["PAID", "PARTIALLY_REFUNDED", "PARTIALLY_PAID", "COMPLETED"]);
const PRIORITIES = new Set(["lowest", "shopify", "square"]);

const targetDefinitions = [
  { requested: "Papaya Crush Tier 2 Live Rosin", match: "Papaya Crush Tier 2 Rosin" },
  { requested: "Bazinga Tier 2 Live Rosin", match: "Benzina Tier 2 Rosin", note: "Shopify source title is Benzina" },
  { requested: "Orange Crush Tier 2 Live Rosin", match: "Orange Crush Tier 2 Rosin" },
  { requested: "Honey Banana Tier 2 Live Rosin", match: "Honey Banana Tier 2 Rosin" },
  { requested: "Jelly Donut Tier 2 Live Rosin", match: "Jelly Donut Tier 2 Rosin" },
];

const wholesaleArchitecture = [
  "Retail and wholesale variants must consume the same strain-specific Soply raw-material pool.",
  "Wholesale products must stay Active and published to Online Store so Soply can import them.",
  "BSS Lock must restrict wholesale products to customers tagged Wholesale.",
  "Shopify API cannot verify Soply pool bindings or BSS Lock rules without those apps' own API/UI data.",
];

const prisma = new PrismaClient();

const state = {
  running: false,
  lastSyncAt: null,
  lastMode: null,
  lastError: null,
  nextSyncAt: new Date(Date.now() + syncEveryMs).toISOString(),
  shopify: { ok: false, at: null, error: null, activeProducts: null },
  square: { configured: Boolean(squareToken), ok: false, at: null, error: null },
};

const cache = { html: null, js: null, token: null, tokenAt: 0 };

function writeLog(level, message, details = {}) {
  const entry = { at: new Date().toISOString(), level, message, ...details };
  fs.appendFileSync(logPath, `${JSON.stringify(entry)}\n`, { mode: 0o600 });
  return entry;
}

function recentLogs() {
  if (!fs.existsSync(logPath)) return [];
  return fs
    .readFileSync(logPath, "utf8")
    .trim()
    .split(/\r?\n/)
    .filter(Boolean)
    .slice(-120)
    .map((line) => JSON.parse(line))
    .reverse();
}

function readCredentials() {
  const clientId = process.env.SHOPIFY_CLIENT_ID;
  const clientSecret = process.env.SHOPIFY_CLIENT_SECRET;
  if (!clientId || !clientSecret) throw new Error(".env is missing SHOPIFY_CLIENT_ID or SHOPIFY_CLIENT_SECRET");
  return { clientId, clientSecret };
}

async function getShopifyToken() {
  if (cache.token && Date.now() - cache.tokenAt < 10 * 60_000) return cache.token;
  const { clientId, clientSecret } = readCredentials();
  const response = await fetch(`https://${shopDomain}/admin/oauth/access_token`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ client_id: clientId, client_secret: clientSecret, grant_type: "client_credentials" }),
  });
  if (!response.ok) throw new Error(`Token exchange failed (${response.status}): ${await response.text()}`);
  cache.token = (await response.json()).access_token;
  cache.tokenAt = Date.now();
  return cache.token;
}

async function shopifyGraphQL(query, variables) {
  const token = await getShopifyToken();
  const response = await fetch(`https://${shopDomain}/admin/api/${apiVersion}/graphql.json`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-shopify-access-token": token },
    body: JSON.stringify({ query, variables }),
  });
  const payload = await response.json();
  if (!response.ok || payload.errors) {
    const details = (payload.errors || [])
      .map((error) => error.message || (error.extensions && error.extensions.documentation) || "")
      .join("; ");
    throw new Error(`Shopify GraphQL failed${details ? `: ${details}` : ` (${response.status})`}`);
  }
  return payload.data;
}

const OPERATIONS_QUERY = `#graphql
  query OperationsDashboard($orderQuery: String!) {
    shop { name myshopifyDomain currencyCode }
    publications(first: 30) { nodes { id name autoPublish } }
    products(first: 250, query: "status:active", sortKey: TITLE) {
      nodes {
        id title status handle publishedAt totalInventory
        resourcePublicationsCount { count }
        resourcePublications(first: 20) { nodes { isPublished publishDate publication { id name } } }
        variants(first: 100) { nodes { id title sku price inventoryQuantity inventoryItem { id tracked } } }
      }
    }
    orders(first: 100, query: $orderQuery, sortKey: CREATED_AT, reverse: true) {
      pageInfo { hasNextPage }
      nodes {
        id name createdAt displayFinancialStatus
        currentTotalPriceSet { shopMoney { amount currencyCode } }
        lineItems(first: 100) { nodes { title variantTitle sku quantity } }
      }
    }
  }`;

const LOCATIONS_QUERY = `#graphql
  query Locations { locations(first: 10) { nodes { id name isActive } } }`;

async function pullShopify() {
  const since = new Date(Date.now() - 30 * 86400_000).toISOString().slice(0, 10);
  const data = await shopifyGraphQL(OPERATIONS_QUERY, { orderQuery: `created_at:>=${since}` });
  let locations = [];
  let writeNote = null;
  try {
    const locData = await shopifyGraphQL(LOCATIONS_QUERY, {});
    locations = locData.locations.nodes;
  } catch {
    writeNote = "Shopify partner API scope (client-credentials). Product/order access works, but location inventory writes need the app re-installed with inventory and location scopes (read_locations, write_inventory).";
  }
  const snapshot = {
    syncedAt: new Date().toISOString(),
    windowStart: since,
    writeNote,
    shop: data.shop,
    locations,
    publications: data.publications,
    products: data.products,
    orders: data.orders,
  };
  fs.writeFileSync(snapshotPath, `${JSON.stringify(snapshot, null, 2)}\n`, { mode: 0o600 });
  return snapshot;
}

async function squareRequest(pathname, options = {}) {
  const response = await fetch(`${squareBase}${pathname}`, {
    method: options.method || "GET",
    headers: { authorization: `Bearer ${squareToken}`, "content-type": "application/json", "Square-Version": "2026-07-15" },
    body: options.body !== undefined ? JSON.stringify(options.body) : undefined,
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const detail = (payload.errors || []).map((e) => e.detail || "unknown error").join("; ") || `HTTP ${response.status}`;
    throw new Error(`Square ${options.method || "GET"} ${pathname} failed: ${detail}`);
  }
  return payload;
}

async function squareCatalog() {
  const variations = [];
  let cursor = undefined;
  do {
    const params = new URLSearchParams({ types: "ITEM", limit: "1000" });
    if (cursor) params.set("cursor", cursor);
    const payload = await squareRequest(`/catalog/list?${params}`);
    for (const obj of payload.objects || []) {
      if (obj.type !== "ITEM" || obj.is_deleted) continue;
      const itemName = (obj.item_data && obj.item_data.name) || "Untitled item";
      for (const v of obj.item_data && obj.item_data.variations ? obj.item_data.variations : []) {
        if (v.is_deleted) continue;
        variations.push({
          variationId: v.id,
          itemId: obj.id,
          sku: (v.item_variation_data && v.item_variation_data.sku) || "",
          name: (v.item_variation_data && v.item_variation_data.name) || itemName,
        });
      }
    }
    cursor = payload.cursor;
  } while (cursor);
  return variations;
}

async function squareInventoryCounts(locationIds, variations) {
  const counts = {};
  const countsByLocation = {};
  const ids = [...new Set(variations.map((v) => v.variationId))];
  for (let i = 0; i < ids.length; i += 100) {
    const payload = await squareRequest("/inventory/counts/batch-retrieve", {
      method: "POST",
      body: { location_ids: locationIds, catalog_object_ids: ids.slice(i, i + 100), states: ["IN_STOCK"] },
    });
    for (const c of payload.counts || []) {
      if (c.quantity == null) continue;
      const quantity = Number(c.quantity) || 0;
      if (c.state !== "IN_STOCK" && c.state) continue;
      counts[c.catalog_object_id] = (counts[c.catalog_object_id] || 0) + quantity;
      if (!countsByLocation[c.location_id]) countsByLocation[c.location_id] = {};
      countsByLocation[c.location_id][c.catalog_object_id] = (countsByLocation[c.location_id][c.catalog_object_id] || 0) + quantity;
    }
  }
  return { counts, countsByLocation };
}

async function squareOrders(locationIds, sinceIso) {
  const orders = [];
  let cursor;
  do {
    const body = {
      location_ids: locationIds.slice(0, 10),
      query: {
        filter: { state_filter: { states: ["COMPLETED"] }, date_time_filter: { created_at: { start_at: sinceIso } } },
        sort: { sort_field: "UPDATED_AT", sort_order: "DESC" },
      },
      limit: 200,
    };
    if (cursor) body.cursor = cursor;
    const payload = await squareRequest("/orders/search", { method: "POST", body });
    orders.push(...(payload.orders || []));
    cursor = payload.cursor;
  } while (cursor && orders.length < 1000);
  return orders;
}

async function pullSquare() {
  if (!squareToken) throw new Error("SQUARE_ACCESS_TOKEN is not set");
  const locPayload = await squareRequest("/locations");
  const locations = (locPayload.locations || []).filter((l) => l.status === "ACTIVE");
  const location = squareLocationId
    ? locations.find((l) => l.id === squareLocationId) || locations[0]
    : locations[0];
  if (!location) throw new Error("Square: no active location found");
  const catalog = await squareCatalog();
  const locationIds = locations.map((item) => item.id);
  const { counts, countsByLocation } = await squareInventoryCounts(locationIds, catalog);
  const orders = await squareOrders(locationIds, new Date(Date.now() - 30 * 86400_000).toISOString());
  const data = {
    syncedAt: new Date().toISOString(),
    location: { id: location.id, name: location.name },
    environment: squareEnvironment,
    locations: locations.map((l) => ({ id: l.id, name: l.name, type: l.type, timezone: l.timezone })),
    catalogVariations: catalog.length,
    catalog,
    counts,
    countsByLocation,
    orders,
  };
  fs.writeFileSync(
    squareFilePath,
    `${JSON.stringify({ environment: data.environment, syncedAt: data.syncedAt, location: data.location, locations: data.locations, catalogVariations: data.catalogVariations, catalog, counts, countsByLocation, orders }, null, 2)}\n`,
    { mode: 0o600 },
  );
  return data;
}

function readSquareSnapshot() {
  if (!fs.existsSync(squareFilePath)) return null;
  try {
    const d = JSON.parse(fs.readFileSync(squareFilePath, "utf8"));
    return { environment: d.environment, syncedAt: d.syncedAt, location: d.location, locations: d.locations, catalogVariations: d.catalogVariations, catalog: d.catalog, counts: d.counts, countsByLocation: d.countsByLocation, orders: d.orders };
  } catch {
    return null;
  }
}

function shopifyLedgerEntries(snapshot) {
  return (snapshot.orders && snapshot.orders.nodes ? snapshot.orders.nodes : []).map((o) => {
    const moneyObj = o.currentTotalPriceSet && o.currentTotalPriceSet.shopMoney;
    const items = (o.lineItems && o.lineItems.nodes) || [];
    return {
      id: `shopify:${o.id}`,
      source: "shopify",
      sourceOrderId: o.id,
      orderName: o.name || o.id,
      occurredAt: new Date(o.createdAt),
      syncedAt: new Date(),
      currency: (moneyObj && moneyObj.currencyCode) || "USD",
      grossCents: Math.round(Number((moneyObj && moneyObj.amount) || 0) * 100),
      status: o.displayFinancialStatus || "ANY",
      lineItems: items.reduce((sum, it) => sum + (it.quantity || 0), 0),
      summary: items.slice(0, 3).map((it) => it.title).join(", "),
    };
  });
}

function squareLedgerEntries(data) {
  return (data.orders || []).map((o) => {
    const amount = Number((o.total_money && o.total_money.amount) || 0);
    const items = o.line_items || [];
    return {
      id: `square:${o.id}`,
      source: "square",
      sourceOrderId: o.id,
      orderName: `SQ-${(o.id || "").slice(0, 12)}`,
      occurredAt: new Date(o.created_at || Date.now()),
      syncedAt: new Date(),
      currency: (o.total_money && o.total_money.currency) || "USD",
      grossCents: amount,
      status: o.state || "UNKNOWN",
      lineItems: items.reduce((sum, it) => sum + Number(it.quantity || 1), 0),
      summary: items.slice(0, 3).map((it) => it.name || it.catalog_object_name || "Item").join(", "),
    };
  });
}

async function upsertLedger(entries) {
  for (const entry of entries) {
    const record = { ...entry, syncedAt: new Date() };
    await prisma.ledgerEntry.upsert({ where: { id: entry.id }, update: record, create: record });
  }
}

async function ledgerQuery({ windowDays = 30, source = "all", limit = 2000 } = {}) {
  const where = {};
  if (windowDays > 0) where.occurredAt = { gte: new Date(Date.now() - windowDays * 86400_000) };
  if (source && source !== "all") where.source = source;
  const entries = await prisma.ledgerEntry.findMany({ where, orderBy: { occurredAt: "desc" }, take: limit });
  const revenue = (list) => list.filter((e) => REVENUE_STATUSES.has(e.status)).reduce((s, e) => s + e.grossCents, 0);
  const shopify = entries.filter((e) => e.source === "shopify");
  const square = entries.filter((e) => e.source === "square");
  return {
    currency: entries.length ? entries[0].currency : "USD",
    count: entries.length,
    revenueCents: revenue(entries),
    grossCents: entries.reduce((s, e) => s + e.grossCents, 0),
    shopifyRevenueCents: revenue(shopify),
    squareRevenueCents: revenue(square),
    sources: {
      shopify: { count: shopify.length, grossCents: shopify.reduce((s, e) => s + e.grossCents, 0), revenueCents: revenue(shopify) },
      square: { count: square.length, grossCents: square.reduce((s, e) => s + e.grossCents, 0), revenueCents: revenue(square) },
    },
    entries,
  };
}

async function setPolicy(sku, priority) {
  if (!PRIORITIES.has(priority)) throw new Error(`Unknown priority: ${priority}`);
  if (!sku) throw new Error("SKU required");
  await prisma.inventoryPolicy.upsert({ where: { sku }, update: { priority, updatedAt: new Date() }, create: { sku, priority, updatedAt: new Date() } });
}

const lower = (value = "") => value.toLowerCase();
const hasOnlineStore = (product) => (product.resourcePublications && product.resourcePublications.nodes || []).some((item) => item.isPublished && item.publication.name === "Online Store");
const summarizeProduct = (product) => (product
  ? {
      id: product.id,
      title: product.title,
      status: product.status,
      onlineStore: hasOnlineStore(product),
      publicationNames: (product.resourcePublications?.nodes || []).filter((item) => item.isPublished).map((item) => item.publication.name).sort(),
      publicationCount: product.resourcePublicationsCount?.count || 0,
      totalInventory: product.totalInventory,
      variants: product.variants.nodes.map((variant) => ({ title: variant.title, sku: variant.sku, price: Number(variant.price), inventory: variant.inventoryQuantity, tracked: variant.inventoryItem?.tracked ?? null })),
    }
  : null);

function analyze(snapshot) {
  const products = snapshot.products.nodes;
  const orders = snapshot.orders.nodes;
  const wholesaleProducts = products.filter((product) => lower(product.title).includes("wholesale"));
  const targets = targetDefinitions.map((definition) => {
    const retail = products.find((product) => lower(product.title).includes(lower(definition.match)) && !lower(product.title).includes("wholesale"));
    const wholesale = products.find((product) => lower(product.title).includes(lower(definition.match)) && lower(product.title).includes("wholesale"));
    return { requested: definition.requested, note: definition.note || null, retail: summarizeProduct(retail), wholesale: summarizeProduct(wholesale) };
  });

  const variants = products.flatMap((product) => product.variants.nodes.map((variant) => ({ product: product.title, ...variant })));
  const missingSku = variants.filter((variant) => !variant.sku);
  const skuGroups = new Map();
  variants.filter((variant) => variant.sku).forEach((variant) => skuGroups.set(variant.sku, [...(skuGroups.get(variant.sku) || []), variant]));
  const duplicateSkus = [...skuGroups.entries()]
    .filter(([, items]) => items.length > 1)
    .map(([sku, items]) => ({ sku, count: items.length, products: [...new Set(items.map((item) => item.product))].slice(0, 8) }))
    .sort((a, b) => b.count - a.count);
  const inventoryRisks = variants
    .filter((variant) => variant.inventoryQuantity <= 5)
    .map((variant) => ({ product: variant.product, variant: variant.title, sku: variant.sku, inventory: variant.inventoryQuantity }))
    .sort((a, b) => a.inventory - b.inventory || a.product.localeCompare(b.product));

  const paidOrders = orders.filter((order) => ["PAID", "PARTIALLY_REFUNDED", "PARTIALLY_PAID"].includes(order.displayFinancialStatus));
  const revenue = paidOrders.reduce((sum, order) => sum + Number(order.currentTotalPriceSet.shopMoney.amount), 0);
  const units = new Map();
  let wholesaleOrders = 0;
  orders.forEach((order) => {
    let containsWholesale = false;
    order.lineItems.nodes.forEach((item) => {
      if (lower(item.title).includes("wholesale")) containsWholesale = true;
      const key = `${item.title}${item.variantTitle ? ` — ${item.variantTitle}` : ""}`;
      units.set(key, (units.get(key) || 0) + item.quantity);
    });
    if (containsWholesale) wholesaleOrders += 1;
  });
  const topItems = [...units.entries()]
    .map(([title, quantity]) => ({ title, quantity }))
    .filter((item) => !lower(item.title).includes("shipping protection"))
    .sort((a, b) => b.quantity - a.quantity)
    .slice(0, 10);
  const dailyMap = new Map();
  paidOrders.forEach((order) => {
    const day = order.createdAt.slice(0, 10);
    dailyMap.set(day, (dailyMap.get(day) || 0) + Number(order.currentTotalPriceSet.shopMoney.amount));
  });
  const dailySales = [...dailyMap.entries()].map(([day, amount]) => ({ day, amount })).sort((a, b) => a.day.localeCompare(b.day));

  return {
    wholesale: { targets, existing: wholesaleProducts.map(summarizeProduct), architecture: wholesaleArchitecture },
    sales: {
      orderWindow: "Last 30 days, latest 100 orders",
      truncated: Boolean(snapshot.orders.pageInfo?.hasNextPage),
      orders: orders.length,
      paidOrders: paidOrders.length,
      revenue,
      averageOrderValue: paidOrders.length ? revenue / paidOrders.length : 0,
      wholesaleOrders,
      currency: snapshot.shop.currencyCode,
      dailySales,
      topItems,
      recentOrders: orders.slice(0, 12).map((order) => ({
        name: order.name,
        createdAt: order.createdAt,
        status: order.displayFinancialStatus,
        total: Number(order.currentTotalPriceSet.shopMoney.amount),
        items: order.lineItems.nodes.reduce((sum, item) => sum + item.quantity, 0),
      })),
    },
    inventory: {
      totalVariants: variants.length,
      trackedVariants: variants.filter((variant) => variant.inventoryItem?.tracked).length,
      outOfStock: variants.filter((variant) => variant.inventoryQuantity <= 0).length,
      inventoryRisks,
      missingSku: missingSku.map((variant) => ({ product: variant.product, variant: variant.title, inventory: variant.inventoryQuantity })),
      duplicateSkus,
    },
    overview: {
      activeProducts: products.length,
      wholesaleProducts: wholesaleProducts.length,
      onlineStoreProducts: products.filter(hasOnlineStore).length,
      targetPairsReady: targets.filter((target) => target.retail?.onlineStore && target.wholesale?.onlineStore).length,
      targetCount: targets.length,
      lowStockVariants: inventoryRisks.length,
      missingSkuVariants: missingSku.length,
      duplicateSkuGroups: duplicateSkus.length,
    },
  };
}

function reconcilePlan(snapshot, squareData, policies) {
  const sqBySku = new Map();
  if (squareData) for (const v of squareData.catalog || []) if (v.sku) sqBySku.set(v.sku.toLowerCase(), v);
  const rows = [];
  for (const product of snapshot.products.nodes) {
    for (const v of product.variants.nodes) {
      const sku = (v.sku || "").trim();
      if (!sku) continue;
      const key = sku.toLowerCase();
      const policy = policies.get(key);
      const priority = policy ? policy.priority : "lowest";
      const shopifyQty = v.inventoryQuantity ?? null;
      const tracked = !!(v.inventoryItem && v.inventoryItem.tracked);
      const squareVariation = sqBySku.get(key);
      let squareQty = null;
      let squareHomeQty = null;
      if (squareData && squareVariation && Object.prototype.hasOwnProperty.call(squareData.counts, squareVariation.variationId)) {
        squareQty = Number(squareData.counts[squareVariation.variationId]) || 0;
        const homeCounts = squareData.countsByLocation && squareData.location ? squareData.countsByLocation[squareData.location.id] : null;
        squareHomeQty = homeCounts ? Number(homeCounts[squareVariation.variationId] || 0) : null;
      }
      let target = null;
      if (shopifyQty !== null && squareQty !== null) {
        if (priority === "square") target = squareQty;
        else if (priority === "shopify") target = shopifyQty;
        else target = Math.min(shopifyQty, squareQty);
        target = Math.max(0, target);
      }
      const drift = shopifyQty !== null && squareQty !== null ? squareQty - shopifyQty : null;
      rows.push({
        sku,
        product: product.title,
        variant: v.title,
        variantId: v.id,
        inventoryItemId: (v.inventoryItem && v.inventoryItem.id) || null,
        tracked,
        priority,
        shopifyQty,
        squareQty,
        squareHomeQty,
        target,
        drift,
        shopifyDelta: target !== null && shopifyQty !== null ? target - shopifyQty : null,
        squareDelta: target !== null && squareQty !== null ? target - squareQty : null,
        squareHomeTarget: target !== null && squareQty !== null && squareHomeQty !== null ? squareHomeQty + (target - squareQty) : null,
        squareVariationId: squareVariation ? squareVariation.variationId : null,
      });
    }
  }
  const actionable = rows.filter((r) => r.target !== null && r.tracked && r.squareVariationId && (r.shopifyDelta !== 0 || r.squareDelta !== 0));
  const blockedAdjustments = actionable.filter((r) => r.squareDelta && (r.squareHomeTarget === null || r.squareHomeTarget < 0)).length;
  const driftCount = rows.filter((r) => r.target !== null && r.drift !== 0 && r.tracked && r.squareVariationId).length;
  return { rows, summary: { total: rows.length, driftCount, actionable: actionable.length, blockedAdjustments } };
}

function readSnapshot() {
  if (!fs.existsSync(snapshotPath)) return null;
  try {
    return JSON.parse(fs.readFileSync(snapshotPath, "utf8"));
  } catch {
    return null;
  }
}

async function buildStatus() {
  const snapshot = readSnapshot();
  const squareData = state.squareData || null;
  const policies = new Map((await prisma.inventoryPolicy.findMany().catch(() => [])).map((p) => [p.sku.toLowerCase(), p]));
  const base = snapshot ? analyze(snapshot) : null;
  const recon = snapshot ? reconcilePlan(snapshot, squareData, policies) : null;
  const ledger = await ledgerQuery({ windowDays: 30 }).catch(() => null);

  const overview = base ? { ...base.overview } : null;
  if (overview) {
    overview.driftCount = recon ? recon.summary.driftCount : 0;
    overview.actionable = recon ? recon.summary.actionable : 0;
    overview.ledgerRevenueCents = ledger ? ledger.revenueCents : 0;
    overview.ledgerShopifyCents = ledger ? ledger.shopifyRevenueCents : 0;
    overview.ledgerSquareCents = ledger ? ledger.squareRevenueCents : 0;
  }

  const issues = [];
  if (!squareToken) issues.push({ level: "warn", text: "Square is not connected. Set SQUARE_ACCESS_TOKEN in the environment to pull catalog, inventory, and in-store sales into the ledger." });
  else if (!state.square.ok) issues.push({ level: state.square.error ? "err" : "warn", text: state.square.error ? `Square sync problem — ${state.square.error}` : "Square connected but not synced yet. Run Sync everything now." });
  if (snapshot && overview.targetPairsReady < overview.targetCount) issues.push({ level: "warn", text: `${overview.targetCount - overview.targetPairsReady} of ${overview.targetCount} Tier 2 wholesale pairs are not import-visible to Soply.` });
  if (recon && recon.summary.actionable > 0) issues.push({ level: "err", text: `${recon.summary.actionable} SKUs drift between Shopify and Square. Review the Inventory tab and Apply reconciliation when ready.` });
  if (overview && overview.lowStockVariants > 0) issues.push({ level: "warn", text: `${overview.lowStockVariants} variants have five or fewer Shopify units.` });
  if (overview && overview.missingSkuVariants > 0) issues.push({ level: "warn", text: `${overview.missingSkuVariants} variants have no SKU and cannot sync to Square or reconcile.` });
  if (base && base.sales.truncated) issues.push({ level: "info", text: "The Shopify order window is capped at the latest 100 orders. Ledger keeps growing across syncs." });

  const writeSafetyReasons = [];
  if (!snapshot || !snapshot.locations || snapshot.locations.length !== 1) writeSafetyReasons.push("Shopify must have exactly one active inventory location for this shared-pool setup.");
  if (!squareData || !squareData.location) writeSafetyReasons.push("Square home-base location is unavailable.");
  if (!squareData || !squareData.countsByLocation) writeSafetyReasons.push("Square per-location counts have not been pulled yet.");
  if (recon && recon.summary.blockedAdjustments > 0) writeSafetyReasons.push(`${recon.summary.blockedAdjustments} corrections would make the Square home-base count negative.`);
  const writeSafety = {
    ready: writeSafetyReasons.length === 0,
    mode: writeSafetyReasons.length === 0 ? "shared-pool" : "read-only",
    homeBase: squareData && squareData.location ? squareData.location : null,
    reasons: writeSafetyReasons,
  };
  if (!writeSafety.ready) issues.unshift({ level: "err", text: "Inventory writes are safety-locked until the shared-pool preflight passes." });

  return {
    version: 3,
    syncedAt: snapshot ? snapshot.syncedAt : null,
    windowStart: snapshot ? snapshot.windowStart : null,
    shop: snapshot ? snapshot.shop : null,
    sources: {
      shopify: { ...state.shopify, configured: true },
      square: {
        configured: Boolean(squareToken),
        ok: state.square.ok,
        at: state.square.at,
        error: state.square.error,
        environment: squareData ? squareData.environment : squareEnvironment,
        location: squareData ? squareData.location : null,
        locations: squareData ? squareData.locations : [],
        catalogVariations: squareData ? squareData.catalogVariations : 0,
        matchedVariants: recon ? recon.rows.filter((r) => r.squareQty !== null).length : 0,
      },
    },
    sync: {
      running: state.running,
      lastSyncAt: state.lastSyncAt,
      lastMode: state.lastMode,
      lastError: state.lastError,
      nextSyncAt: state.nextSyncAt,
      intervalMinutes: syncMinutes,
    },
    overview,
    wholesale: base ? base.wholesale : null,
    sales: base ? base.sales : null,
    inventory: base ? base.inventory : null,
    recon: recon ? { rows: recon.rows, summary: recon.summary, writeSafety } : null,
    ledger: ledger
      ? {
          count: ledger.count,
          revenueCents: ledger.revenueCents,
          grossCents: ledger.grossCents,
          shopifyRevenueCents: ledger.shopifyRevenueCents,
          squareRevenueCents: ledger.squareRevenueCents,
        }
      : null,
    issues,
  };
}

function json(res, status, body) {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  res.end(JSON.stringify(body));
}

async function runSync(mode) {
  if (state.running) throw new Error("A full sync is already running");
  state.running = true;
  state.lastError = null;
  state.lastMode = mode;
  writeLog("info", `${mode === "automatic" ? "Automatic" : "Manual"} full sync started`);
  try {
    const snapshot = await pullShopify();
    state.shopify = { ok: true, at: snapshot.syncedAt, error: null, activeProducts: snapshot.products.nodes.length, writeNote: snapshot.writeNote };
    await upsertLedger(shopifyLedgerEntries(snapshot)).catch((e) => writeLog("error", "Shopify ledger upsert failed", { error: e.message }));

    if (squareToken) {
      try {
        const square = await pullSquare();
        state.squareData = square;
        state.square.ok = true;
        state.square.at = square.syncedAt;
        state.square.error = null;
        await upsertLedger(squareLedgerEntries(square)).catch((e) => writeLog("error", "Square ledger upsert failed", { error: e.message }));
      } catch (e) {
        state.square.ok = false;
        state.square.error = e.message;
        writeLog("error", "Square sync failed", { error: e.message });
      }
    } else {
      state.squareData = state.squareData || null;
    }

    state.lastSyncAt = snapshot.syncedAt;
    state.lastError = null;
    state.nextSyncAt = new Date(Date.now() + syncEveryMs).toISOString();
    const status = await buildStatus();
    status.sync.running = false;
    const o = status.overview || {};
    writeLog("success", "Sync completed", {
      mode,
      activeProducts: o.activeProducts ?? snapshot.products.nodes.length,
      orders: status.sales?.orders,
      revenue: status.sales?.revenue,
      driftCount: o.driftCount ?? 0,
      actionable: o.actionable ?? 0,
      squareOk: state.square.ok,
    });
    return status;
  } catch (e) {
    state.lastError = e.message;
    writeLog("error", "Sync failed", { mode, error: e.message });
    throw e;
  } finally {
    state.running = false;
  }
}

async function runSourceSync(source) {
  if (state.running) throw new Error("Another sync is already running");
  state.running = true;
  state.lastError = null;
  state.lastMode = source;
  writeLog("info", `${source === "square" ? "Square" : "Shopify"} sync started`);
  try {
    if (source === "square") {
      if (!squareToken) throw new Error("SQUARE_ACCESS_TOKEN is not set");
      const square = await pullSquare();
      state.squareData = square;
      state.square.ok = true;
      state.square.at = square.syncedAt;
      state.square.error = null;
      state.lastSyncAt = square.syncedAt;
      await upsertLedger(squareLedgerEntries(square)).catch((e) => writeLog("error", "Square ledger upsert failed", { error: e.message }));
      writeLog("success", "Square sync completed", { catalogVariations: square.catalogVariations, orders: square.orders.length });
      return;
    }
    if (source !== "shopify") throw new Error("Unknown sync source");
    const snapshot = await pullShopify();
    state.shopify = { ok: true, at: snapshot.syncedAt, error: null, activeProducts: snapshot.products.nodes.length, writeNote: snapshot.writeNote };
    state.lastSyncAt = snapshot.syncedAt;
    await upsertLedger(shopifyLedgerEntries(snapshot)).catch((e) => writeLog("error", "Shopify ledger upsert failed", { error: e.message }));
    writeLog("success", "Shopify sync completed", { activeProducts: snapshot.products.nodes.length, orders: snapshot.orders.nodes.length });
  } catch (e) {
    state.lastError = e.message;
    writeLog("error", `${source === "square" ? "Square" : "Shopify"} sync failed`, { error: e.message });
    throw e;
  } finally {
    state.running = false;
    state.nextSyncAt = new Date(Date.now() + syncEveryMs).toISOString();
  }
}

async function applyPlan({ skus }) {
  const snapshot = readSnapshot();
  if (!snapshot) throw new Error("No snapshot yet — run a sync first");
  const policies = new Map((await prisma.inventoryPolicy.findMany()).map((p) => [p.sku.toLowerCase(), p]));
  const squareData = state.squareData || null;
  const plan = reconcilePlan(snapshot, squareData, policies);
  if (!snapshot.locations || snapshot.locations.length !== 1 || !squareData || !squareData.location || !squareData.countsByLocation || plan.summary.blockedAdjustments > 0) {
    const safetyError = new Error("Inventory writes are safety-locked because the shared-pool preflight did not pass.");
    safetyError.statusCode = 409;
    throw safetyError;
  }
  const candidateRows = (skus && skus.length ? plan.rows.filter((r) => skus.some((sku) => sku.toLowerCase() === r.sku.toLowerCase())) : plan.rows).filter(
    (r) => r.target !== null && r.tracked && r.squareVariationId && (r.shopifyDelta !== 0 || r.squareDelta !== 0),
  );
  const groupedRows = new Map();
  for (const row of candidateRows) {
    const key = row.sku.toLowerCase();
    if (!groupedRows.has(key)) groupedRows.set(key, []);
    groupedRows.get(key).push(row);
  }
  const conflicts = [...groupedRows.entries()].filter(([, items]) => new Set(items.map((item) => `${item.target}:${item.squareVariationId}`)).size > 1);
  if (conflicts.length) {
    const conflictError = new Error(`Conflicting duplicate Shopify SKUs must be fixed before applying: ${conflicts.map(([sku]) => sku).join(", ")}`);
    conflictError.statusCode = 409;
    throw conflictError;
  }
  const rows = [...groupedRows.values()].map((items) => items[0]);
  const location = snapshot.locations && snapshot.locations[0];
  const results = [];
  let applied = 0;
  for (const row of rows) {
    const notes = [];
    let ok = true;
    if (row.squareDelta && state.squareData && state.square.ok) {
      try {
        const idempotencyKey = `hh-sync-${row.sku.replace(/[^a-z0-9]/gi, "").slice(0, 40) || "item"}-${Date.now()}`;
        await squareRequest("/inventory/changes/batch-create", {
          method: "POST",
          body: {
            idempotency_key: idempotencyKey,
            changes: [
              {
                type: "PHYSICAL_COUNT",
                physical_count: {
                  reference_id: idempotencyKey,
                  catalog_object_id: row.squareVariationId,
                  state: "IN_STOCK",
                  location_id: state.squareData.location.id,
                  quantity: String(row.squareHomeTarget),
                  occurred_at: new Date().toISOString(),
                },
              },
            ],
            ignore_unchanged_counts: true,
          },
        });
        notes.push(`Square ${state.squareData.location.name}→${row.squareHomeTarget} (shared total ${row.target})`);
      } catch (e) {
        ok = false;
        notes.push(`Square ✕ ${e.message}`);
      }
    }
    if (row.shopifyDelta) {
      if (!row.inventoryItemId || !location) {
        ok = false;
        notes.push("Shopify write needs location + read/write inventory scopes (re-install app with access)");
      } else {
        try {
          const result = await shopifyGraphQL(
            `mutation AdjustInventory($input: InventoryAdjustQuantitiesInput!, $idempotencyKey: String!) {
              inventoryAdjustQuantities(input: $input) @idempotent(key: $idempotencyKey) {
                inventoryAdjustmentGroup { createdAt changes { name delta } }
                userErrors { field message }
              }
            }`,
            {
              input: {
                reason: "correction",
                name: "available",
                referenceDocumentUri: "herbal-healers://inventory/reconciliation",
                changes: [{ delta: row.shopifyDelta, inventoryItemId: row.inventoryItemId, locationId: location.id }],
              },
              idempotencyKey: `hh-${row.sku.replace(/[^a-z0-9]/gi, "").slice(0, 40) || "item"}-${Date.now()}`,
            },
          );
          const userErrors = result.inventoryAdjustQuantities.userErrors || [];
          if (userErrors.length) throw new Error(userErrors.map((item) => item.message).join("; "));
          notes.push(`Shopify ${row.shopifyDelta > 0 ? "+" : ""}${row.shopifyDelta}`);
        } catch (e) {
          ok = false;
          notes.push(`Shopify ✕ ${e.message}`);
        }
      }
    }
    if (ok) applied += 1;
    results.push({ sku: row.sku, ok, target: row.target, actions: notes });
    writeLog(ok ? "success" : "error", ok ? "Reconciliation applied" : "Reconciliation item failed", { sku: row.sku, target: row.target, actions: notes });
  }
  return { applied, results };
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const pathname = url.pathname;

    if (req.method === "GET" && pathname === "/") {
      res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
      return res.end(fs.readFileSync(consoleHtmlPath));
    }
    if (req.method === "GET" && pathname === "/console/client.js") {
      res.writeHead(200, { "content-type": "text/javascript; charset=utf-8", "cache-control": "no-store" });
      return res.end(fs.readFileSync(consoleJsPath));
    }
    if (req.method === "GET" && pathname === "/api/status") return json(res, 200, { analysis: await buildStatus() });
    if (req.method === "GET" && pathname === "/api/logs") return json(res, 200, { logs: recentLogs() });
    if (req.method === "GET" && pathname === "/api/ledger") {
      const windowDays = Math.min(3650, Number(url.searchParams.get("window") || 30) || 0);
      const source = url.searchParams.get("source") || "all";
      return json(res, 200, await ledgerQuery({ windowDays, source }));
    }
    if (req.method === "POST" && pathname === "/api/sync") {
      const status = await runSync("manual");
      return json(res, 200, {
        ok: true,
        status,
        summary: `Shopify + Square synced — ${status.overview?.activeProducts ?? 0} products, ${(status.recon?.summary?.actionable || 0)} plans ready.`,
      });
    }
    if (req.method === "POST" && pathname === "/api/sync/source") {
      const { source } = await readJsonBody(req);
      await runSourceSync(source);
      return json(res, 200, { ok: true });
    }
    if (req.method === "POST" && pathname === "/api/policy") {
      const { sku, priority } = await readJsonBody(req);
      if (!sku || !priority) return json(res, 400, { error: "sku and priority are required" });
      await setPolicy(sku, priority);
      return json(res, 200, { ok: true, sku, priority });
    }
    if (req.method === "POST" && pathname === "/api/apply") {
      const body = await readJsonBody(req);
      return json(res, 200, await applyPlan({ skus: body.skus, ...body }));
    }
    return json(res, 404, { error: "Not found" });
  } catch (e) {
    return json(res, e.statusCode || 500, { error: e.message });
  }
});

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (chunk) => (data += chunk));
    req.on("end", () => {
      try {
        resolve(data ? JSON.parse(data) : {});
      } catch (e) {
        reject(new Error("Invalid JSON body"));
      }
    });
    req.on("error", reject);
  });
}

const storedSquare = readSquareSnapshot();
if (storedSquare) {
  state.squareData = storedSquare;
  if (!state.square.ok) {
    state.square.at = storedSquare.syncedAt || null;
    state.square.error = squareToken ? "Using prior snapshot — sync to refresh" : null;
  }
}

setInterval(() => runSync("automatic").catch(() => {}), syncEveryMs).unref();
server.listen(port, "127.0.0.1", () => console.log(`Herbal Healers Operations running at http://127.0.0.1:${port}`));
