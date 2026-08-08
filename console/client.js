/* ==========================================================================
   Herbal Healers — Inventory Management console
   Served by local-console.mjs. Reads the /api/* endpoints.
   ========================================================================== */
const q = (s) => document.querySelector(s);
const qa = (s) => [...document.querySelectorAll(s)];
const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const pill = (text, type = "") => '<span class="pill ' + type + '">' + esc(text) + "</span>";
const money = (n, c = "USD") => new Intl.NumberFormat("en-US", { style: "currency", currency: c, maximumFractionDigits: 2 }).format(n ?? 0);
const cents = (n, c = "USD") => money(Number(n || 0) / 100, c);
const num = (n) => new Intl.NumberFormat("en-US").format(n ?? 0);
const dt = (v) => (v ? new Date(v).toLocaleString() : "never");
const day = (v) => (v ? new Date(v).toISOString().slice(0, 10) : "");
const ago = (v) => {
  if (!v) return "never synced";
  const m = Math.max(0, Math.round((Date.now() - new Date(v).getTime()) / 60000));
  if (m < 1) return "synced just now";
  if (m < 60) return "synced " + m + "m ago";
  return "synced " + Math.round(m / 60) + "h ago";
};
const TITLES = { overview: "Overview", inventory: "Inventory", wholesale: "Wholesale", sales: "Sales", ledger: "Ledger", sync: "Sync & audit" };

let analysis = null;
let active = "overview";
let ledger = null;
let inv = { q: "", scope: "all", sort: "product", dir: 1, page: 1, per: 25 };

/* ---------- icons ---------- */
function ico(p) {
  return '<svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' + p + "</svg>";
}
const ICONS = {
  overview: ico('<path d="M4 13h6V4H4zM14 9h6V4h-6zM4 20h6v-4H4zM14 20h6v-7h-6z"/>'),
  inventory: ico('<rect x="4" y="3" width="16" height="6" rx="1"/><path d="M4 9h16v11a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1zM9 9v4h6V9"/>'),
  wholesale: ico('<path d="M12 3 3 8l9 5 9-5zM3 12l9 5 9-5M3 16l9 5 9-5"/>'),
  sales: ico('<path d="M12 3v4m0 4v6M7 17l4-4 3 2 5-7"/><path d="M6 21h12"/>'),
  ledger: ico('<path d="M9 12h6m-6 4h6M9 8h3"/><rect x="3" y="3" width="18" height="18" rx="2"/>'),
  sync: ico('<path d="M20 7v5h-5M4 17v-5h5"/><path d="M6.1 8.6A7 7 0 0 1 18 7l2 5M17.9 15.4A7 7 0 0 1 6 17l-2-5"/>'),
  search: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.2-3.2"/></svg>',
};

/* ---------- shared ---------- */
function stat(label, value, detail, tone) {
  return '<div class="card stat ' + (tone || "") + '"><div class="label">' + esc(label) + "</div><div class=\"value\">" + value + "</div>" + (detail ? '<div class="detail">' + detail + "</div>" : "") + "</div>";
}
function cards(list) {
  return '<div class="metrics">' + list.map((m) => stat(m.label, m.value, m.detail, m.tone)).join("") + "</div>";
}
function qtyPill(v) {
  if (v === null || v === undefined) return '<span class="muted">—</span>';
  return pill(num(v), v <= 0 ? "bad" : v <= 5 ? "warn" : "ok");
}
function driftCell(v) {
  if (v === null || v === undefined) return '<span class="muted">—</span>';
  return pill(v === 0 ? "aligned" : (v > 0 ? "+" : "") + num(v), v === 0 ? "ok" : "bad");
}
function smallTable(head, rows) {
  if (!rows.length) return '<div class="empty">No data to show.</div>';
  return '<div class="tbl"><table><thead><tr>' + head.map((h) => "<th" + (h.num ? ' class="num"' : "") + ">" + h.t + "</th>").join("") + "</tr></thead><tbody>" + rows.join("") + "</tbody></table></div>";
}
function attn(a) {
  const items = a.issues || [];
  if (!items.length) return '<div class="callout ok">No open issues — everything looks aligned.</div>';
  return items.map((i) => '<div class="callout ' + i.level + '">' + esc(i.text) + "</div>").join("");
}
function productChip(p) {
  if (!p) return pill("Missing", "bad");
  return pill(p.status === "ACTIVE" ? "Active" : p.status, p.status === "ACTIVE" ? "ok" : "bad") + " " + pill(p.onlineStore ? "Online Store" : "Not published", p.onlineStore ? "ok" : "bad");
}
function summaryOf(e) {
  return e.summary ? '<div class="row sub">' + esc(e.summary) + "</div>" : "";
}
function setBanner(kind, text) {
  const b = q("#banner");
  b.className = "banner show " + kind;
  b.textContent = text;
}

/* ---------- charts ---------- */
function areaChart(ser, currency = false, c = "USD") {
  if (!ser || !ser.length) return '<div class="muted" style="padding:16px">No data in window</div>';
  const w = 760, h = 190, pad = 8;
  const max = Math.max(1, ...ser.map((x) => x.value));
  const step = (w - pad * 2) / Math.max(1, ser.length - 1);
  const pts = ser.map((x, i) => [pad + i * step, h - pad - (x.value / max) * (h - pad * 2)]);
  const line = pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" ");
  const area = line + " L" + (w - pad) + " " + (h - pad) + " L" + pad + " " + (h - pad) + " Z";
  const last = ser[ser.length - 1];
  const lp = pts[pts.length - 1];
  return (
    '<div class="chart"><svg viewBox="0 0 ' + w + " " + h + '" preserveAspectRatio="none" role="img">' +
    "<defs><linearGradient id=\"ag\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"#06d6a0\" stop-opacity=\".4\"/><stop offset=\"1\" stop-color=\"#118ab2\" stop-opacity=\"0\"/></linearGradient></defs>" +
    '<path d="' + area + '" fill="url(#ag)"/>' +
    '<path d="' + line + '" fill="none" stroke="#06d6a0" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>' +
    '<circle cx="' + lp[0] + '" cy="' + lp[1] + '" r="3.6" fill="#ffd166"/>' +
    "</svg></div>" +
    '<div class="legend"><span class="sw"><span class="dot" style="background:var(--emerald)"></span>' + esc(ser[0].label) + "</span><span class=\"sw\">" + esc(last.label) + " · <b>" + (currency ? money(last.value, c) : num(last.value)) + "</b></span></div>"
  );
}
function hbar(items, currency = false, c = "USD") {
  if (!items.length) return '<div class="muted" style="padding:12px">No data</div>';
  const mx = Math.max(1, ...items.map((x) => x.value));
  return items
    .map((x) => '<div class="barrow"><div class="bl" title="' + esc(x.label) + '">' + esc(x.label) + '</div><div class="bar"><div class="fill" style="width:' + Math.max(1.5, (x.value / mx) * 100) + '%"></div></div><strong>' + (currency ? money(x.value, c) : num(x.value)) + "</strong></div>")
    .join("");
}
function coverage(label, pct, grad) {
  return '<div class="row"><span class="muted" style="flex:1">' + esc(label) + "</span><b>" + num(pct) + "%</b></div><div class=\"progress\" style=\"margin:8px 0 14px\"><i style=\"width:" + pct + "%;background:" + grad + '"></i></div>';
}

/* ==========================================================================
   VIEWS
   ========================================================================== */
function overviewView(a) {
  const o = a.overview;
  const s = a.sales;
  const cur = a.shop.currencyCode || "USD";
  const matched = a.recon ? a.recon.rows.filter((r) => r.squareQty !== null).length : 0;
  return (
    cards([
      { label: "Combined revenue · 30d", value: cents(o.ledgerRevenueCents, cur), detail: "Shopify " + cents(o.ledgerShopifyCents, cur) + " + Square " + cents(o.ledgerSquareCents, cur), tone: "tone-emerald" },
      { label: "Online orders · 30d", value: num(s.orders), detail: s.paidOrders + " paid · " + money(s.revenue, cur), tone: "tone-ocean" },
      { label: "Average order", value: money(s.averageOrderValue, cur), detail: "latest 100 orders cap", tone: "tone-royal" },
      { label: "Active products", value: num(o.activeProducts), detail: o.onlineStoreProducts + " on Online Store", tone: "tone-teal" },
      { label: "Inventory drift", value: num(o.driftCount), detail: o.actionable + " SKUs ready to apply", tone: "tone-bubble" },
      { label: "Wholesale catalog", value: num(o.wholesaleProducts), detail: o.targetPairsReady + " / " + o.targetCount + " target pairs ready", tone: "tone-royal" },
      { label: "Low stock alerts", value: num(o.lowStockVariants), detail: o.missingSkuVariants + " variants missing a SKU", tone: "tone-bubble" },
    ]) +
    '<div class="grid-2 section"><section class="card"><h2>Sales trend · last 14 days</h2>' +
    areaChart(s.dailySales.slice(-14).map((x) => ({ label: x.day.slice(5), value: x.amount })), true, cur) +
    '</section><section class="card"><h2>What needs attention</h2>' +
    attn(a) +
    '</section></div><div class="grid-2 section">' +
    '<section class="card"><h2>Catalog coverage</h2>' +
    coverage("Published to Online Store", Math.round((o.onlineStoreProducts / Math.max(1, o.activeProducts)) * 100), "linear-gradient(90deg,#118ab2,#06d6a0)") +
    coverage("Inventory tracked", Math.round((a.inventory.trackedVariants / Math.max(1, a.inventory.totalVariants)) * 100), "linear-gradient(90deg,#06d6a0,#ffd166)") +
    coverage("SKUs matched to Square", Math.min(100, Math.round((matched / Math.max(1, o.activeProducts)) * 100)), "linear-gradient(90deg,#118ab2,#ef476f)") +
    "</section><section class=\"card\"><h2>Best sellers · by units</h2>" +
    hbar(s.topItems.slice(0, 6)) +
    "</section></div>"
  );
}

function wholesaleView(a) {
  const w = a.wholesale;
  const rows = w.targets.map((x) => {
    const ready = x.retail && x.wholesale && x.retail.onlineStore && x.wholesale.onlineStore;
    return (
      "<tr><td><strong>" + esc(x.requested) + "</strong>" + (x.note ? '<div class="row sub">' + esc(x.note) + "</div>" : "") +
      "</td><td>" + productChip(x.retail) + "</td><td>" + productChip(x.wholesale) + "</td><td>" + pill(ready ? "Import-visible" : "Blocked", ready ? "ok" : "bad") + "</td></tr>"
    );
  });
  const existing = w.existing.map((x) =>
    "<tr><td><strong>" + esc(x.title) + "</strong></td><td>" + pill(x.onlineStore ? "Online Store" : "Not published", x.onlineStore ? "ok" : "bad") + "</td><td class=\"num\">" + x.variants.length + "</td><td class=\"num\">" + num(x.totalInventory) + "</td><td>" + (x.publicationNames || []).map((n) => pill(n, "faint")).join(" ") + "</td></tr>",
  );
  return (
    '<section class="card"><h2>Tier 2 wholesale build queue</h2>' +
    smallTable([{ t: "Requested product" }, { t: "Retail source" }, { t: "Wholesale product" }, { t: "Soply import" }], rows) +
    '</section><section class="card section"><h2>Existing wholesale catalog</h2>' +
    smallTable([{ t: "Product" }, { t: "Online Store" }, { t: "Variants", num: true }, { t: "Inventory", num: true }, { t: "Published channels" }], existing) +
    "</section>"
  );
}

function salesView(a) {
  const s = a.sales;
  const cur = a.shop.currencyCode || "USD";
  const orders = s.recentOrders.map((x) =>
    "<tr><td><strong>" + esc(x.name) + "</strong></td><td>" + dt(x.createdAt) + "</td><td>" + pill(x.status, x.status === "PAID" ? "ok" : "warn") + "</td><td class=\"num\">" + x.items + "</td><td class=\"num\">" + money(x.total, cur) + "</td></tr>",
  );
  return (
    cards([
      { label: "Shopify revenue", value: money(s.revenue, cur), detail: s.orderWindow, tone: "tone-ocean" },
      { label: "Square revenue · 30d", value: cents(a.ledger.squareRevenueCents, cur), detail: "from central ledger", tone: "tone-emerald" },
      { label: "Orders", value: num(s.orders), detail: s.truncated ? "window capped at 100" : "full window", tone: "tone-teal" },
      { label: "Paid orders", value: num(s.paidOrders), tone: "tone-emerald" },
      { label: "Average order", value: money(s.averageOrderValue, cur), tone: "tone-royal" },
      { label: "Wholesale orders", value: num(s.wholesaleOrders), detail: "containing wholesale line items", tone: "tone-bubble" },
    ]) +
    '<div class="grid-2 section"><section class="card"><h2>Daily sales</h2>' +
    areaChart(s.dailySales.map((x) => ({ label: x.day.slice(5), value: x.amount })), true, cur) +
    '</section><section class="card"><h2>Top items · units</h2>' +
    hbar(s.topItems.slice(0, 8)) +
    "</section></div>" +
    '<section class="card section"><h2>Recent orders</h2>' +
    smallTable([{ t: "Order" }, { t: "Created" }, { t: "Status" }, { t: "Units", num: true }, { t: "Total", num: true }], orders) +
    "</section>"
  );
}

/* ==========================================================================
   INVENTORY — search, filter, sort, paginate, apply
   ========================================================================== */
const SCOPES = [["all", "All SKUs"], ["drift", "Drift vs Square"], ["aligned", "Aligned"], ["out", "Out of stock"], ["low", "Low stock ≤ 5"], ["untracked", "Untracked"], ["mismatch", "Missing Square link"]];

function invFiltered() {
  const rows = analysis.recon ? analysis.recon.rows : [];
  const term = (inv.q || "").toLowerCase();
  const list = rows.filter((r) => {
    if (term && !(r.sku || "").toLowerCase().includes(term) && !(r.product || "").toLowerCase().includes(term) && !(r.variant || "").toLowerCase().includes(term)) return false;
    const sc = inv.scope;
    if (sc === "drift") return r.squareQty !== null && r.drift !== 0;
    if (sc === "aligned") return r.squareQty !== null && r.drift === 0;
    if (sc === "out") return (r.shopifyQty ?? -1) <= 0;
    if (sc === "low") return (r.shopifyQty ?? 99) <= 5;
    if (sc === "untracked") return !r.tracked;
    if (sc === "mismatch") return r.squareQty === null;
    return true;
  });
  const key = inv.sort;
  const d = inv.dir;
  list.sort((x, y) => {
    let res = 0;
    if (key === "sku") res = (x.sku || "").localeCompare(y.sku || "");
    else if (key === "product") res = (x.product || "").localeCompare(y.product || "");
    else if (key === "shopify") res = (x.shopifyQty ?? -1) - (y.shopifyQty ?? -1);
    else if (key === "square") res = (x.squareQty ?? -1) - (y.squareQty ?? -1);
    else if (key === "target") res = (x.target ?? -1) - (y.target ?? -1);
    else res = (x.drift ?? 0) - (y.drift ?? 0);
    return res * d;
  });
  return list;
}

function invRow(r) {
  const opts = ["lowest", "shopify", "square"]
    .map((p) => '<option value="' + p + '"' + (r.priority === p ? " selected" : "") + ">" + p + "</option>")
    .join("");
  const state = r.squareQty === null ? pill("Square unknown", "warn") : r.drift === 0 ? pill("Aligned", "ok") : pill("Drift " + (r.drift > 0 ? "+" : "") + num(r.drift), "bad");
  return (
    "<tr><td><strong>" + esc(r.sku) + "</strong></td>" +
    "<td>" + esc(r.product) + '<div class="row sub">' + esc(r.variant) + "</div></td>" +
    "<td>" + pill(r.tracked ? "Tracked" : "Untracked", r.tracked ? "ok" : "faint") + "</td>" +
    '<td class="num">' + qtyPill(r.shopifyQty) + "</td><td class=\"num\">" + qtyPill(r.squareQty) + "</td>" +
    '<td><select class="prio" data-sku="' + esc(r.sku) + '">' + opts + "</select></td>" +
    '<td class="num">' + (r.target === null ? '<span class="muted">—</span>' : "<b>" + num(r.target) + "</b>") + "</td>" +
    '<td class="num">' + driftCell(r.drift) + "</td>" +
    "<td>" + state + "</td></tr>"
  );
}

function inventoryView(a) {
  const i = a.inventory;
  const r = a.recon;
  const writeSafety = r.writeSafety || { ready: false, reasons: ["Write safety has not been checked."] };
  const scopes = SCOPES.map(([v, t]) => '<option value="' + v + '"' + (inv.scope === v ? " selected" : "") + ">" + t + "</option>").join("");
  const sorts = `product,Sku sort|sku,Name|shopify,Shopify qty|square,Square qty|target,Target|drift,Drift`
    .split("|")
    .map((p) => {
      const [v, t] = p.split(",");
      return '<option value="' + v + '"' + (inv.sort === v ? " selected" : "") + ">" + t + "</option>";
    })
    .join("");
  return (
    cards([
      { label: "Variants", value: num(i.totalVariants), detail: "in Shopify catalog", tone: "tone-teal" },
      { label: "Tracked", value: num(i.trackedVariants), detail: "inventory managed", tone: "tone-emerald" },
      { label: "Out of stock", value: num(i.outOfStock), tone: "tone-royal" },
      { label: "Low stock ≤ 5", value: num(i.inventoryRisks.length), tone: "tone-bubble" },
      { label: "Drift vs Square", value: num(r.summary.driftCount), detail: "SKUs", tone: "tone-bubble" },
      { label: "Differences", value: num(r.summary.actionable), detail: writeSafety.ready ? "shared-pool check passed" : "review only", tone: "tone-emerald" },
    ]) +
    '<section class="card section"><div class="row" style="justify-content:space-between;flex-wrap:wrap;gap:12px;margin-bottom:4px">' +
    '<h2 style="margin:0">Shopify ↔ Square reconciliation</h2>' +
    '<button class="btn primary small" id="apply-btn" type="button"' + (writeSafety.ready ? "" : " disabled") + ">" + (writeSafety.ready ? "Apply reconciliation (" + num(r.summary.actionable) + ")" : "Writes safely locked") + "</button></div>" +
    '<div class="callout ' + (writeSafety.ready ? "ok" : "err") + '">' + (writeSafety.ready ? "Shared inventory check passed. Shopify is compared with both Square locations added together. Corrections go through " + esc(writeSafety.homeBase?.name || "the Square home base") + "." : "No inventory will be written. " + writeSafety.reasons.map(esc).join(" ")) + "</div>" +
    '<div class="row sub" style="margin:8px 0 12px">Shopify is one shared count. Square’s two exposure locations are added together. The home-base count changes only by the difference.</div>' +
    '<div class="toolbar"><div class="search"><span class="ico">' + ICONS.search + '</span><input id="iv-q" ' +
    'type="text" placeholder="Search SKU, product, variant…" autocomplete="off" value="' + esc(inv.q) + '"></div>' +
    '<select id="iv-scope" aria-label="Filter">' + scopes + "</select>" +
    '<select id="iv-sort" aria-label="Sort">' + sorts + "</select>" +
    '<button class="btn small ghost" id="iv-export" type="button">Export CSV</button>' +
    '<span class="tr-span" id="iv-count"></span></div>' +
    '<div class="tbl"><table><thead><tr>' +
    '<th class="sortable" data-k="sku">SKU</th><th class="sortable" data-k="product">Product / variant</th><th>Status</th>' +
    '<th class="num sortable" data-k="shopify">Shopify</th><th class="num sortable" data-k="square">Square</th><th data-k="none">Priority</th>' +
    '<th class="num sortable" data-k="target">Target</th><th class="num sortable" data-k="drift">Drift</th><th>State</th>' +
    "</tr></thead><tbody id=\"iv-body\"></tbody></table></div>" +
    '<div id="inv-pager"></div></section>'
  );
}

/* ==========================================================================
   LEDGER
   ========================================================================== */
function ledgerControls() {
  return (
    '<div class="toolbar"><label class="muted" style="font-size:12.5px">Window <select id="lw">' +
    [14, 30, 90, 365, 0]
      .map((w) => '<option value="' + w + '"' + (w === 30 ? " selected" : "") + ">" + (w ? w + " days" : "All time") + "</option>")
      .join("") +
    '</select></label><label class="muted" style="font-size:12.5px">Source <select id="ls">' +
    [["all", "All sources"], ["shopify", "Shopify"], ["square", "Square"]]
      .map(([v, t]) => '<option value="' + v + '">' + t + "</option>")
      .join("") +
    '</select></label><div class="search"><span class="ico">' + ICONS.search + '</span><input type="text" id="lq" placeholder="Search order, item, status…" autocomplete="off"></div>' +
    '<button class="btn small ghost" id="lcsv" type="button">Export CSV</button></div><div id="ledger-body" class="loading">Loading central ledger…</div>'
  );
}
function ledgerView() {
  return '<section class="card"><h2>Central transaction ledger</h2><div class="row sub" style="margin-bottom:10px">Every Shopify order and Square sale is logged once, deduplicated by source order id — one journal for reconciliation and taxes.</div>' + ledgerControls() + "</section>";
}
function exportLedgerCsv() {
  if (!ledger || !ledger.entries.length) return;
  const rows = [["date", "source", "order", "status", "units", "total_cents", "currency", "summary"]];
  for (const e of ledger.entries) {
    const cell = (v) => {
      const s = String(v ?? "");
      return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
    };
    rows.push([cell(day(e.occurredAt)), e.source, cell(e.orderName || e.sourceOrderId), e.status, e.lineItems, e.grossCents, e.currency, cell(e.summary || "")]);
  }
  const blob = new Blob([rows.map((r) => r.join(",")).join("\n")], { type: "text/csv;charset=utf-8" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "herbal-healers-ledger.csv";
  a.click();
  URL.revokeObjectURL(a.href);
}
async function loadLedger() {
  const w = q("#lw").value;
  const s = q("#ls").value;
  const res = await fetch("/api/ledger?window=" + w + "&source=" + s);
  ledger = await res.json();
  renderLedgerBody();
}
function renderLedgerBody() {
  const body = q("#ledger-body");
  if (!ledger || !body) return;
  const term = (q("#lq").value || "").toLowerCase();
  const entries = term ? ledger.entries.filter((e) => (e.orderName || "").toLowerCase().includes(term) || (e.summary || "").toLowerCase().includes(term) || e.status.toLowerCase().includes(term)) : ledger.entries;
  const cur = analysis.shop.currencyCode || "USD";
  const rows = entries.map((e) =>
    "<tr><td>" + dt(e.occurredAt) + "</td><td>" + pill(e.source === "shopify" ? "Shopify" : "Square", e.source === "shopify" ? "info" : "ok") + "</td><td><strong>" + esc(e.orderName || e.sourceOrderId) + "</strong>" + summaryOf(e) + "</td><td>" + esc(e.status) + "</td><td class=\"num\">" + e.lineItems + "</td><td class=\"num\">" + cents(e.grossCents, e.currency || cur) + "</td></tr>",
  );
  body.outerHTML =
    '<div id="ledger-body"><div class="ledger-stats">' +
    stat("Entries in window", num(ledger.count), "filtered to " + num(entries.length) + " by search") +
    stat("Revenue (paid/completed)", cents(ledger.revenueCents, cur), "Shopify " + cents(ledger.shopifyRevenueCents, cur) + " · Square " + cents(ledger.squareRevenueCents, cur)) +
    stat("Gross flow", cents(ledger.grossCents, cur), "all statuses, unweighted") +
    stat("Shopify entries", num(ledger.sources.shopify.count), cents(ledger.sources.shopify.grossCents, cur)) +
    stat("Square entries", num(ledger.sources.square.count), cents(ledger.sources.square.grossCents, cur)) +
    "</div>" +
    smallTable([{ t: "Occurred" }, { t: "Source" }, { t: "Order" }, { t: "Status" }, { t: "Units", num: true }, { t: "Total", num: true }], rows) +
    "</div>";
  const csvBtn = q("#lcsv");
  if (csvBtn) csvBtn.onclick = exportLedgerCsv;
  const wSel = q("#lw");
  const sSel = q("#ls");
  const tSel = q("#lq");
  if (wSel) wSel.onchange = loadLedger;
  if (sSel) sSel.onchange = loadLedger;
  if (tSel) tSel.oninput = () => renderLedgerBody();
}

/* ==========================================================================
   SYNC & AUDIT
   ========================================================================== */
function syncView(a) {
  const sq = a.sources.square;
  const sh = a.sources.shopify;
  const arch = a.wholesale.architecture || [];
  return (
    '<div class="grid-2 eq"><section class="card"><h2>Shopify connection</h2>' +
    '<div class="row">' + pill(sh.ok ? "Connected" : "Error", sh.ok ? "ok" : "bad") + '<span class="muted">' + ago(sh.at) + "</span></div>" +
    '<div class="row sub">Credentials via info.txt · Admin GraphQL 2026-07 · ' + (sh.activeProducts ?? "-") + " active products</div>" +
    '<button class="btn small" id="sync-sh" type="button">Sync Shopify only</button>' +
    '</section><section class="card"><h2>Square connection</h2>' +
    '<div class="row">' + pill(sq.configured ? (sq.ok ? "Connected" : "Error") : "Not configured", !sq.configured ? "warn" : sq.ok ? "ok" : "bad") + '<span class="muted">' + ago(sq.at) + "</span></div>" +
    (sq.configured
      ? '<div class="row sub">' + esc((sq.environment || "production").toUpperCase()) + " · " + esc(sq.location?.name || sq.location || "") + " · " + num(sq.catalogVariations ?? 0) + " catalog variations · " + num(sq.matchedVariants ?? 0) + " SKUs matched to Shopify</div>"
      : '<div class="row sub">Add Square Production credentials to info.txt to enable catalog, inventory, and sales pulls.</div>') +
    '<button class="btn small" id="sync-sq" type="button">Sync Square only</button></section></div>' +
    '<section class="card section"><h2>Operating model</h2>' +
    arch.map((t) => '<div class="callout info">' + esc(t) + "</div>").join("") +
    '<div class="callout ok">Square pulls catalog + counted inventory per location and completed orders into the same central ledger as Shopify orders. Reconciliation applies per-SKU priority (“lowest” by default) and never writes without an explicit Apply.</div>' +
    '</section><section class="card section"><h2>Sync audit log</h2><div id="logbox" class="log">Loading…</div></section>'
  );
}
async function loadLogs() {
  const box = q("#logbox");
  if (!box) return;
  const res = await fetch("/api/logs");
  const j = await res.json();
  box.innerHTML =
    j.logs.map((e) => '<div class="logrow"><span class="lg-time">' + esc(e.at.replace("T", " ").slice(0, 19)) + '</span><span class="lg-level lg-' + esc(e.level) + '">' + esc(e.level) + "</span><span class=\"lg-msg\">" + esc(e.message) + "</span></div>").join("") || '<div class="empty">No sync activity logged yet.</div>';
}

/* ==========================================================================
   INVENTORY binding + repaint
   ========================================================================== */
function invRepaint() {
  const list = invFiltered();
  const total = list.length;
  const pages = Math.max(1, Math.ceil(total / inv.per));
  if (inv.page > pages) inv.page = pages;
  const page = list.slice((inv.page - 1) * inv.per, inv.page * inv.per);
  const body = q("#iv-body");
  const pager = q("#inv-pager");
  const count = q("#iv-count");
  if (body) body.innerHTML = page.map(invRow).join("") || '<tr><td colspan="9" class="empty">No SKUs match the current filter.</td></tr>';
  if (count) count.textContent = num(total) + " rows";
  if (pager)
    pager.innerHTML =
      '<div class="pager"><span>Showing <b>' + num(page.length) + "</b> of <b>" + num(total) + "</b> rows</span><div class=\"row\">" +
      '<button class="btn small ghost" id="pv" ' + (inv.page <= 1 ? "disabled" : "") + '>← Prev</button>' +
      "<span>" + inv.page + " / " + pages + "</span>" +
      '<button class="btn small ghost" id="pn" ' + (inv.page >= pages ? "disabled" : "") + '>Next →</button></div></div>';
  const pv = q("#pv");
  const pn = q("#pn");
  if (pv) pv.onclick = () => { inv.page -= 1; invRepaint(); };
  if (pn) pn.onclick = () => { inv.page += 1; invRepaint(); };
}

function invExport() {
  const list = invFiltered();
  if (!list.length) return;
  const rows = [["sku", "product", "variant", "tracked", "shopify", "square", "priority", "target", "drift", "state"]];
  for (const r of list) {
    rows.push([r.sku, r.product, r.variant, r.tracked, r.shopifyQty ?? "", r.squareQty ?? "", r.priority, r.target ?? "", r.drift ?? "", r.squareQty === null ? "square unknown" : r.drift === 0 ? "aligned" : "drift"].map((v) => {
      const s = String(v ?? "");
      return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
    }));
  }
  const blob = new Blob([rows.map((r) => r.join(",")).join("\n")], { type: "text/csv;charset=utf-8" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "inventory-reconciliation.csv";
  a.click();
  URL.revokeObjectURL(a.href);
}

function bindInv(a) {
  const apply = q("#apply-btn");
  if (apply && a.recon.writeSafety && a.recon.writeSafety.ready)
    apply.onclick = async () => {
      if (!confirm("Apply the reconciliation plan? Shopify and Square inventory will be written for " + num(a.recon.summary.actionable) + " SKUs.")) return;
      apply.disabled = true;
      apply.textContent = "Applying…";
      try {
        const res = await fetch("/api/apply", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({}) });
        const j = await res.json();
        if (!res.ok) throw new Error(j.error);
        const failed = (j.results || []).filter((x) => !x.ok).length;
        setBanner(failed ? "err" : "ok", "Applied " + (j.results || []).filter((x) => x.ok).length + " SKU plans" + (failed ? ", " + failed + " failed" : "") + ".");
        await load();
      } catch (e) {
        setBanner("err", "Apply failed: " + e.message);
      } finally {
        apply.disabled = false;
        apply.textContent = "Apply reconciliation (" + num(a.recon.summary.actionable) + ")";
      }
    };
  const inp = q("#iv-q");
  if (inp)
    inp.oninput = () => {
      inv.q = inp.value;
      inv.page = 1;
      invRepaint();
    };
  const scope = q("#iv-scope");
  if (scope)
    scope.onchange = () => {
      inv.scope = scope.value;
      inv.page = 1;
      invRepaint();
    };
  const sortSel = q("#iv-sort");
  if (sortSel)
    sortSel.onchange = () => {
      inv.sort = sortSel.value;
      inv.page = 1;
      invRepaint();
    };
  const ex = q("#iv-export");
  if (ex) ex.onclick = invExport;
  qa(".tbl thead th.sortable").forEach((th) => {
    th.onclick = () => {
      const k = th.dataset.k;
      if (!k || k === "none") return;
      if (inv.sort === k) inv.dir *= -1;
      else {
        inv.sort = k;
        inv.dir = 1;
      }
      invRepaint();
    };
  });
  const body = q("#iv-body");
  if (body)
    body.addEventListener("change", async (e) => {
      const sel = e.target.closest("select.prio");
      if (!sel) return;
      try {
        const res = await fetch("/api/policy", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ sku: sel.dataset.sku, priority: sel.value }) });
        if (!res.ok) throw new Error((await res.json()).error || "failed");
        setBanner("ok", "Priority for " + sel.dataset.sku + " set to “" + sel.value + "”.");
        await load();
      } catch (err) {
        setBanner("err", "Priority update failed: " + err.message);
      }
    });
  invRepaint();
}

/* ==========================================================================
   RENDER + TABS
   ========================================================================== */
function render() {
  if (!analysis) return;
  const views = { overview: overviewView, inventory: inventoryView, wholesale: wholesaleView, sales: salesView, ledger: ledgerView, sync: syncView };
  const main = q("#content");
  main.innerHTML = '<section class="view active">' + views[active](analysis) + "</section>";
  const title = q("#page-title");
  if (title) title.textContent = TITLES[active] || "Overview";

  const sh = analysis.sources.shopify;
  const sq = analysis.sources.square;
  const st = analysis.sync;
  const chip = (id, cls, text) => {
    const el = q(id);
    if (!el) return;
    el.className = "chip " + cls;
    const span = el.querySelector(".meta span");
    if (span) span.textContent = text;
  };
  chip("#chip-shopify", sh.ok ? "ok" : "err", (sh.ok ? "Live · " : "Error · ") + (sh.at ? ago(sh.at) : "no sync yet") + (sh.error ? " — " + sh.error : ""));
  chip("#chip-square", !sq.configured ? "warn" : sq.ok ? "ok" : "err", !sq.configured ? "Not configured" : (sq.ok ? (sq.environment || "production").toUpperCase() + " live · " : "Error · ") + (sq.at ? ago(sq.at) : "no sync yet") + (sq.error ? " — " + sq.error : ""));
  chip("#chip-sync", st.lastError ? "err" : "ok", (st.lastError ? "Last sync failed" : "Auto every " + st.intervalMinutes + " min") + " · next " + (st.nextSyncAt ? dt(st.nextSyncAt) : "—"));

  const banner = q("#banner");
  if (st.lastError) {
    banner.className = "banner show err";
    banner.textContent = "Last sync failed: " + st.lastError;
  } else if (analysis.syncedAt) {
    banner.className = "banner show ok";
    banner.textContent = "Live snapshot verified " + dt(analysis.syncedAt) + (analysis.windowStart ? " · order window from " + day(analysis.windowStart) : "");
  } else {
    banner.className = "banner";
  }

  if (active === "inventory") bindInv(analysis);
  if (active === "ledger") {
    renderLedgerBody();
    if (!ledger) loadLedger();
  }
  if (active === "sync") {
    const shBtn = q("#sync-sh");
    const sqBtn = q("#sync-sq");
    if (shBtn) shBtn.onclick = () => sourceSync("shopify", shBtn);
    if (sqBtn) sqBtn.onclick = () => sourceSync("square", sqBtn);
    loadLogs();
  }
}

async function sourceSync(source, btn) {
  btn.disabled = true;
  const old = btn.textContent;
  btn.textContent = "Syncing " + source + "…";
  try {
    const res = await fetch("/api/sync/source", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ source }), signal: AbortSignal.timeout(60000) });
    const j = await res.json();
    if (!res.ok) throw new Error(j.error);
    await load();
    setBanner("ok", source + " sync completed.");
  } catch (e) {
    setBanner("err", source + " sync failed: " + e.message);
  } finally {
    btn.disabled = false;
    btn.textContent = old;
  }
}

async function syncAll() {
  const btn = q("#sync-btn");
  btn.disabled = true;
  btn.textContent = "Syncing…";
  try {
    const res = await fetch("/api/sync", { method: "POST", signal: AbortSignal.timeout(60000) });
    const j = await res.json();
    if (!res.ok) throw new Error(j.error);
    await load();
    setBanner("ok", "Sync completed. " + (j.summary || ""));
  } catch (e) {
    setBanner("err", "Sync failed: " + e.message);
  } finally {
    btn.disabled = false;
    btn.textContent = "Sync everything";
  }
}

async function load() {
  try {
    const res = await fetch("/api/status", { signal: AbortSignal.timeout(15000) });
    if (!res.ok) throw new Error("Dashboard status failed (" + res.status + ")");
    const j = await res.json();
    analysis = j.analysis;
    render();
  } catch (e) {
    setBanner("err", e.message);
  }
}

function setupTabs() {
  const tabs = qa("#tabs .nav-item");
  tabs.forEach((tab, i) => {
    const activate = () => {
      active = tab.dataset.view;
      tabs.forEach((t, j) => {
        t.setAttribute("aria-selected", String(j === i));
        t.tabIndex = j === i ? 0 : -1;
      });
      render();
    };
    tab.onclick = activate;
    tab.onkeydown = (e) => {
      let next = null;
      if (e.key === "ArrowRight") next = (i + 1) % tabs.length;
      if (e.key === "ArrowLeft") next = (i - 1 + tabs.length) % tabs.length;
      if (e.key === "Home") next = 0;
      if (e.key === "End") next = tabs.length - 1;
      if (next !== null) {
        e.preventDefault();
        tabs[next].focus();
        tabs[next].click();
      }
    };
  });
}

q("#sync-btn").onclick = syncAll;
setupTabs();
load();
setInterval(() => {
  if (document.hidden) return;
  load();
}, 90000);
