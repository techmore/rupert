import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PrismaClient } from "@prisma/client";

/* eslint-env node */

const root = path.dirname(fileURLToPath(import.meta.url));
const prisma = new PrismaClient();

const lower = (v = "") => String(v).toLowerCase().trim();

async function seedShopify(snapshot) {
  let products = 0;
  let variants = 0;
  for (const p of snapshot.products.nodes) {
    await prisma.shopifyProduct.upsert({
      where: { id: p.id },
      update: {
        title: p.title,
        status: p.status,
        handle: p.handle,
        publishedAt: p.publishedAt ? new Date(p.publishedAt) : null,
        totalInventory: p.totalInventory ?? 0,
        syncedAt: new Date(),
      },
      create: {
        id: p.id,
        title: p.title,
        status: p.status,
        handle: p.handle,
        publishedAt: p.publishedAt ? new Date(p.publishedAt) : null,
        totalInventory: p.totalInventory ?? 0,
        syncedAt: new Date(),
      },
    });
    products += 1;
    for (const v of p.variants.nodes) {
      await prisma.shopifyVariant.upsert({
        where: { id: v.id },
        update: {
          title: v.title,
          sku: v.sku,
          price: v.price !== undefined ? Number(v.price) : null,
          inventoryQuantity: v.inventoryQuantity ?? 0,
          tracked: v.inventoryItem?.tracked ?? false,
          inventoryItemId: v.inventoryItem?.id ?? null,
          syncedAt: new Date(),
        },
        create: {
          id: v.id,
          productId: p.id,
          title: v.title,
          sku: v.sku,
          price: v.price !== undefined ? Number(v.price) : null,
          inventoryQuantity: v.inventoryQuantity ?? 0,
          tracked: v.inventoryItem?.tracked ?? false,
          inventoryItemId: v.inventoryItem?.id ?? null,
          syncedAt: new Date(),
        },
      });
      variants += 1;
    }
  }
  return { products, variants };
}

async function seedSquare(data) {
  let items = 0;
  let variations = 0;
  const byItem = new Map();
  for (const v of data.catalog) {
    const list = byItem.get(v.itemId) || [];
    list.push(v);
    byItem.set(v.itemId, list);
  }
  for (const [itemId, list] of byItem) {
    const itemName = list[0].name || itemId;
    await prisma.squareItem.upsert({
      where: { id: itemId },
      update: { name: itemName, syncedAt: new Date() },
      create: { id: itemId, name: itemName, syncedAt: new Date() },
    });
    items += 1;
    for (const v of list) {
      await prisma.squareVariation.upsert({
        where: { id: v.variationId },
        update: { sku: v.sku, name: v.name, syncedAt: new Date() },
        create: { id: v.variationId, itemId, sku: v.sku, name: v.name, syncedAt: new Date() },
      });
      variations += 1;
    }
  }
  return { items, variations };
}

async function seedLocations(snapshot, squareData) {
  const locations = [];
  const shopifyStore = { externalId: "default", source: "shopify", name: "Shopify Online Store", kind: "VIRTUAL" };
  if (snapshot.locations?.length) {
    for (const l of snapshot.locations) {
      await prisma.location.upsert({
        where: { source_externalId: { source: "shopify", externalId: l.id } },
        update: { name: l.name, kind: l.kind ?? "RETAIL", active: l.isActive ?? true, syncedAt: new Date() },
        create: { source: "shopify", externalId: l.id, name: l.name, kind: l.kind ?? "RETAIL", active: l.isActive ?? true, syncedAt: new Date() },
      });
      const found = await prisma.location.findUnique({ where: { source_externalId: { source: "shopify", externalId: l.id } } });
      locations.push({ id: found.id, externalId: l.id, source: "shopify", name: found.name });
    }
  } else {
    await prisma.location.upsert({
      where: { source_externalId: { source: "shopify", externalId: shopifyStore.externalId } },
      update: { name: shopifyStore.name, kind: shopifyStore.kind, syncedAt: new Date() },
      create: { source: "shopify", externalId: shopifyStore.externalId, name: shopifyStore.name, kind: shopifyStore.kind, syncedAt: new Date() },
    });
    const found = await prisma.location.findUnique({ where: { source_externalId: { source: "shopify", externalId: shopifyStore.externalId } } });
    locations.push({ id: found.id, externalId: found.externalId, source: "shopify", name: found.name });
  }
  const squareLocations = [];
  for (const l of squareData.locations || []) {
    await prisma.location.upsert({
      where: { source_externalId: { source: "square", externalId: l.id } },
      update: { name: l.name, kind: l.type, timezone: l.timezone, active: true, syncedAt: new Date() },
      create: { source: "square", externalId: l.id, name: l.name, kind: l.type, timezone: l.timezone, active: true, syncedAt: new Date() },
    });
    const found = await prisma.location.findUnique({ where: { source_externalId: { source: "square", externalId: l.id } } });
    squareLocations.push({ id: found.id, externalId: l.id });
  }
  return { shopifyDefault: locations[0], squarePrimary: squareLocations[0] };
}

async function seedLevels(snapshot, squareData, locations) {
  let levels = 0;
  const shopifyVariantBySku = new Map();
  for (const p of snapshot.products.nodes) {
    for (const v of p.variants.nodes) {
      await prisma.inventoryLevel.upsert({
        where: {
          source_locationId_shopifyVariantId: {
            source: "shopify",
            locationId: locations.shopifyDefault.id,
            shopifyVariantId: v.id,
          },
        },
        update: { quantity: v.inventoryQuantity ?? 0, available: v.inventoryQuantity ?? 0, updatedAt: new Date() },
        create: {
          source: "shopify",
          locationId: locations.shopifyDefault.id,
          shopifyVariantId: v.id,
          quantity: v.inventoryQuantity ?? 0,
          available: v.inventoryQuantity ?? 0,
          updatedAt: new Date(),
        },
      });
      if (v.sku) shopifyVariantBySku.set(lower(v.sku), { variantId: v.id, sku: v.sku });
      levels += 1;
    }
  }
  const squareVariationBySku = new Map();
  if (locations.squarePrimary?.id && squareData.counts) {
    for (const v of squareData.catalog) {
      const qty = squareData.counts[v.variationId];
      if (qty === undefined) continue;
      await prisma.inventoryLevel.upsert({
        where: {
          source_locationId_squareVariationId: {
            source: "square",
            locationId: locations.squarePrimary.id,
            squareVariationId: v.variationId,
          },
        },
        update: { quantity: qty, available: qty, updatedAt: new Date() },
        create: {
          source: "square",
          locationId: locations.squarePrimary.id,
          squareVariationId: v.variationId,
          quantity: qty,
          available: qty,
          updatedAt: new Date(),
        },
      });
      if (v.sku) squareVariationBySku.set(lower(v.sku), v.variationId);
      levels += 1;
    }
  }
  return { levels, shopifyVariantBySku, squareVariationBySku };
}

async function seedLinks(shopifyVariantBySku, squareVariationBySku) {
  let links = 0;
  for (const [sku, { variantId }] of shopifyVariantBySku) {
    const squareVariationId = squareVariationBySku.get(sku);
    if (!squareVariationId) continue;
    await prisma.skuLink.upsert({
      where: { shopifyVariantId_squareVariationId: { shopifyVariantId: variantId, squareVariationId } },
      update: {},
      create: { sku, shopifyVariantId: variantId, squareVariationId, matchSource: "sku", auto: true },
    });
    links += 1;
  }
  return links;
}

async function seedAlerts(snapshot) {
  let alerts = 0;
  for (const p of snapshot.products.nodes) {
    for (const v of p.variants.nodes) {
      const qty = v.inventoryQuantity ?? 0;
      if (qty > 5) continue;
      const existing = await prisma.stockAlert.findFirst({ where: { shopifyVariantId: v.id, status: "open" } });
      if (existing) continue;
      await prisma.stockAlert.create({
        data: {
          shopifyVariantId: v.id,
          sku: v.sku,
          quantity: qty,
          threshold: 5,
          status: "open",
          note: qty <= 0 ? "Out of stock" : "Low stock — below threshold of 5",
        },
      });
      alerts += 1;
    }
  }
  return alerts;
}

async function seedMovements(snapshot, squareData, locations) {
  let movements = 0;
  for (const p of snapshot.products.nodes) {
    for (const v of p.variants.nodes) {
      await prisma.inventoryMovement.create({
        data: {
          sku: v.sku,
          shopifyVariantId: v.id,
          source: "shopify",
          direction: "set",
          delta: 0,
          quantityBefore: 0,
          quantityAfter: v.inventoryQuantity ?? 0,
          reason: "Initial sync backfill",
          reference: "seed",
          actor: "system",
        },
      });
      movements += 1;
    }
  }
  if (locations.squarePrimary && squareData.counts) {
    for (const v of squareData.catalog) {
      const qty = squareData.counts[v.variationId];
      if (qty === undefined) continue;
      await prisma.inventoryMovement.create({
        data: {
          sku: v.sku,
          squareVariationId: v.variationId,
          source: "square",
          direction: "set",
          delta: 0,
          quantityBefore: 0,
          quantityAfter: qty,
          reason: "Initial sync backfill",
          reference: "seed",
          actor: "system",
        },
      });
      movements += 1;
    }
  }
  return movements;
}

async function seedReconcilePlan(snapshot, squareData) {
  const sqBySku = new Map();
  if (squareData) for (const v of squareData.catalog || []) if (v.sku) sqBySku.set(lower(v.sku), v);
  const rows = [];
  for (const product of snapshot.products.nodes) {
    for (const v of product.variants.nodes) {
      const sku = (v.sku || "").trim();
      if (!sku) continue;
      const squareVariation = sqBySku.get(lower(sku));
      if (!squareVariation) continue;
      const shopifyQty = v.inventoryQuantity ?? null;
      const squareQty = squareData?.counts && squareData.counts[squareVariation.variationId] !== undefined
        ? Number(squareData.counts[squareVariation.variationId]) || 0
        : null;
      if (shopifyQty === null || squareQty === null) continue;
      const tracked = v.inventoryItem?.tracked ?? false;
      const target = Math.max(0, Math.min(shopifyQty, squareQty));
      const drift = squareQty - shopifyQty;
      rows.push({
        sku,
        product: product.title,
        variant: v.title,
        tracked,
        priority: "lowest",
        shopifyQty,
        squareQty,
        target,
        drift,
        shopifyDelta: target - shopifyQty,
        squareDelta: target - squareQty,
        ok: null,
        actions: null,
      });
    }
  }
  const actionable = rows.filter((r) => r.tracked && (r.shopifyDelta !== 0 || r.squareDelta !== 0));
  const run = await prisma.reconcileRun.create({
    data: {
      mode: "seed",
      status: "pending",
      totalRows: rows.length,
      actionable: actionable.length,
      applied: 0,
      failed: 0,
      items: { create: rows },
    },
  });
  return run;
}

async function main() {
  const snapshotPath = path.join(root, "..", "shopify-operations-snapshot.json");
  const squarePath = path.join(root, "..", "square-snapshot.json");
  const snapshot = JSON.parse(fs.readFileSync(snapshotPath, "utf8"));
  const squareData = JSON.parse(fs.readFileSync(squarePath, "utf8"));

  const shopify = await seedShopify(snapshot);
  const square = await seedSquare(squareData);
  const locations = await seedLocations(snapshot, squareData);
  const levelData = await seedLevels(snapshot, squareData, locations);
  const links = await seedLinks(levelData.shopifyVariantBySku, levelData.squareVariationBySku);
  const alerts = await seedAlerts(snapshot);
  const movements = await seedMovements(snapshot, squareData, locations);
  const run = await seedReconcilePlan(snapshot, squareData);

  console.log(
    JSON.stringify(
      {
        shopifyProducts: shopify.products,
        shopifyVariants: shopify.variants,
        squareItems: square.items,
        squareVariations: square.variations,
        locations: 2,
        inventoryLevels: levelData.levels,
        skuLinks: links,
        stockAlerts: alerts,
        inventoryMovements: movements,
        reconcileRun: { id: run.id, rows: run.totalRows, actionable: run.actionable },
        ledgerEntries: await prisma.ledgerEntry.count(),
      },
      null,
      2,
    ),
  );
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());