#!/usr/bin/env node
// App Store screenshots of the Rupert iPhone/iPad app, without a Mac.
//
// Rupert's real pages are rendered by headless Chromium with the app's user agent (so Rupert
// serves its in-app layout, body.native-app), signed in to the fictional review workspace from
// `bin/rails rupert:app_review_demo`. The native chrome the app draws around its web view (status
// bar, navigation bar in the page's banner colours, tab bar) is then drawn around each capture,
// saved at App Store sizes:
//
//   iphone-69-*.png  1320 x 2868  (iPhone 6.9", 440 x 956 pt @3x)
//   ipad-13-*.png    2064 x 2752  (iPad 13", 1032 x 1376 pt @2x, iPadOS 18 floating tab bar)
//
// SF Symbols are not available off Apple platforms, so the tab icons are simple look-alikes.
// make-screenshots.sh seeds a throwaway dev database, starts Rails and runs this:
//
//   REVIEW_PASSWORD=... node make-screenshots.mjs --base-url http://127.0.0.1:3990 --count-id <id> [--out dir]
//
// Playwright: PLAYWRIGHT_MODULE=/path/to/node_modules/playwright/index.mjs when it is not installed here.

import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || "playwright");

const EMAIL = "appreview@rupertpos.com";
const ua = (device, os) =>
  `Rupert iOS/1.0.0 (1); Hotwire Native iOS; Turbo Native iOS; Mozilla/5.0 (${device}; CPU ${os} 18_0 like Mac OS X) ` +
  "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148";
const ACCENT = "#0E6F72"; // AccentColor.colorset (light): the window tint, so the selected tab's colour.
const INACTIVE = "#8E8E93"; // systemGray, unselected tab items.
// Single quotes only: it goes inside style="…" attributes.
const FONT = "-apple-system, 'SF Pro Text', Inter, 'Noto Sans', 'DejaVu Sans', sans-serif";

// What the app's WKWebView provides: the banner observer and the camera barcode scanner
// (Banner.swift, BarcodeScanner.swift). With them, pages show their in-app controls ("Scan with camera").
const NATIVE_BRIDGE = `window.webkit = window.webkit || { messageHandlers: {
  rupertBanner: { postMessage() {} }, rupertScanner: { postMessage() {} } } };`;

const DEVICES = {
  "iphone-69": { width: 440, height: 956, scale: 3, status: 62, nav: 44, tabs: 83, uaDevice: "iPhone", uaOs: "iPhone OS", floating: false },
  "ipad-13": { width: 1032, height: 1376, scale: 2, status: 24, nav: 50, tabs: 0, uaDevice: "iPad", uaOs: "OS", floating: true },
};

const TABS = [["home", "Home"], ["chat", "Team Chat"], ["ask", "Ask Rupert"], ["inbox", "Notifications"], ["search", "Search"]];

// file stem, path ({count} is the draft count id), selected tab, devices, element to scroll to the top (optional)
const SCREENS = [
  ["1-home", "/", "home", ["iphone-69", "ipad-13"]],
  ["2-inventory", "/inventory", "home", ["iphone-69", "ipad-13"], ".stock-viewbar"],
  ["3-scan-count", "/inventory_counts/{count}/scan", "home", ["iphone-69"], '[data-inventory-count-scanner-target="form"]'],
  ["4-team-chat", "/chat", "chat", ["iphone-69", "ipad-13"]],
  ["5-notifications", "/notifications", "inbox", ["iphone-69", "ipad-13"]],
];

// Simple glyphs in the spirit of the SF Symbols the app uses (Tabs.swift), on a 28 x 28 grid.
const line = 'fill="none" stroke="currentColor" stroke-width="1.85" stroke-linecap="round" stroke-linejoin="round"';
const star = (x, y, r) => {
  const k = r * 0.12;
  return `<path d="M${x} ${y - r}C${x + k} ${y - k} ${x + k} ${y - k} ${x + r} ${y}C${x + k} ${y + k} ${x + k} ${y + k} ${x} ${y + r}` +
    `C${x - k} ${y + k} ${x - k} ${y + k} ${x - r} ${y}C${x - k} ${y - k} ${x - k} ${y - k} ${x} ${y - r}z" fill="currentColor"/>`;
};
const ICONS = {
  home: `<path d="M3.5 13.2 14 4.3l10.5 8.9" ${line}/><path d="M6.8 11v11.2a1 1 0 0 0 1 1h4.2v-6.4h4v6.4h4.2a1 1 0 0 0 1-1V11" ${line}/>`,
  chat: `<path d="M4.5 4.5h11A2.5 2.5 0 0 1 18 7v5.5a2.5 2.5 0 0 1-2.5 2.5H10l-3.6 3.1V15H4.5A2.5 2.5 0 0 1 2 12.5V7a2.5 2.5 0 0 1 2.5-2.5z" ${line}/>` +
    `<path d="M20.8 9.5H23a2.5 2.5 0 0 1 2.5 2.5v5.5A2.5 2.5 0 0 1 23 20h-1v3.1L18.4 20H13a2.5 2.5 0 0 1-2.5-2.3" ${line}/>`,
  ask: star(11.5, 13.7, 7.6) + star(20.6, 5.7, 3.4) + star(21.6, 21, 2.7),
  inbox: `<path d="M14 3.8a6.4 6.4 0 0 1 6.4 6.4v4.6l2.3 3.7a.8.8 0 0 1-.7 1.2H6a.8.8 0 0 1-.7-1.2l2.3-3.7v-4.6A6.4 6.4 0 0 1 14 3.8z" ${line}/>` +
    `<path d="M11.2 22.3a2.9 2.9 0 0 0 5.6 0" ${line}/>`,
  search: `<circle cx="12" cy="12" r="7.3" fill="none" stroke="currentColor" stroke-width="2"/>` +
    `<path d="M17.4 17.4l6.3 6.3" stroke="currentColor" stroke-width="2.3" stroke-linecap="round"/>`,
};

// The page's title and banner colours, as the app reads them (Banner.swift readScript), resolved to RGB.
const READ_PAGE = () => {
  const css = getComputedStyle(document.documentElement);
  const ctx = Object.assign(document.createElement("canvas"), { width: 1, height: 1 }).getContext("2d");
  const rgb = (name, fallback) => {
    ctx.clearRect(0, 0, 1, 1);
    ctx.fillStyle = "#000";
    ctx.fillStyle = css.getPropertyValue(name).trim() || fallback;
    ctx.fillRect(0, 0, 1, 1);
    return Array.from(ctx.getImageData(0, 0, 1, 1).data.slice(0, 3));
  };
  return {
    title: document.title, banner: rgb("--color-banner", "#cce0dc"), ink: rgb("--color-ink", "#17353a"),
    text: document.body.innerText, nativeApp: document.body.classList.contains("native-app"),
  };
};

const hex = (rgb) => "#" + rgb.map((c) => c.toString(16).padStart(2, "0")).join("");
const isDark = ([r, g, b]) => 0.2126 * (r / 255) + 0.7152 * (g / 255) + 0.0722 * (b / 255) < 0.5;
const escape = (text) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;");

// 9:41, full signal, wi-fi and battery, as in Apple's own marketing screenshots.
function statusBar(dev, fg) {
  const left = dev.floating
    ? `<span style="position:absolute;left:20px;top:4px;font:600 15px/16px ${FONT}">9:41&nbsp;&nbsp;Thu Oct 29</span>`
    : `<span style="position:absolute;left:0;width:150px;text-align:center;top:20px;font:600 17px/22px ${FONT};letter-spacing:-.2px">9:41</span>`;
  const [right, top, scale] = dev.floating ? [20, 5, 0.85] : [30, 24, 1];
  const signal = [4, 6.5, 9, 12].map((h, i) => `<rect x="${i * 5.5}" y="${12 - h}" width="3.8" height="${h}" rx="1.1" fill="${fg}"/>`).join("");
  const wifi = `<path d="M8.6 12 6.1 9.1a3.5 3.5 0 0 1 5 0z" fill="${fg}"/>` +
    `<path d="M3.4 6.6a7.6 7.6 0 0 1 10.4 0" fill="none" stroke="${fg}" stroke-width="2" stroke-linecap="round"/>` +
    `<path d="M.9 3.7a11.4 11.4 0 0 1 15.4 0" fill="none" stroke="${fg}" stroke-width="2" stroke-linecap="round"/>`;
  const battery = `<rect x=".6" y=".6" width="24.5" height="11.8" rx="3.6" fill="none" stroke="${fg}" stroke-opacity=".4" stroke-width="1.1"/>` +
    `<rect x="2.6" y="2.6" width="20.5" height="7.8" rx="2" fill="${fg}"/>` +
    `<path d="M26.6 4.4v4.2c.9-.3 1.5-1.1 1.5-2.1s-.6-1.8-1.5-2.1z" fill="${fg}" fill-opacity=".4"/>`;
  const icons = `<svg width="${78 * scale}" height="${13 * scale}" viewBox="0 0 78 13" style="position:absolute;right:${right}px;top:${top}px">` +
    `<g>${signal}</g><g transform="translate(25 0)">${wifi}</g><g transform="translate(48 0)">${battery}</g></svg>`;
  return `<div style="position:absolute;left:0;right:0;top:0;height:${dev.status}px;color:${fg}">${left}${icons}</div>`;
}

function tabBar(selected, floating) {
  if (floating) { // iPadOS 18: a capsule of tab titles at the top, centred in the navigation bar.
    const cells = TABS.map(([key, title]) => {
      const on = key === selected;
      return `<span style="padding:0 16px;height:34px;display:inline-flex;align-items:center;border-radius:17px;font:${on ? 600 : 500} 15px ${FONT};` +
        `color:${on ? ACCENT : "#3c3c43"};${on ? "background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.14);" : ""}">${title}</span>`;
    }).join("");
    return `<div style="display:inline-flex;gap:2px;padding:4px;border-radius:21px;background:rgba(242,242,247,.94);` +
      `box-shadow:0 0 0 .5px rgba(0,0,0,.12),0 4px 14px rgba(0,0,0,.08)">${cells}</div>`;
  }
  const cells = TABS.map(([key, title]) =>
    `<div style="flex:1;display:flex;flex-direction:column;align-items:center;padding-top:4px;color:${key === selected ? ACCENT : INACTIVE}">` +
    `<svg width="28" height="28" viewBox="0 0 28 28">${ICONS[key]}</svg>` +
    `<span style="margin-top:2px;font:500 10px/12px ${FONT};letter-spacing:.1px">${title}</span></div>`).join("");
  return `<div style="display:flex;height:49px">${cells}</div>`;
}

// The App settings button (person.crop.circle) on a tab's first page, a back chevron on pushed pages.
function navButtons(dev, ink, accent, root) {
  const y = dev.status + dev.nav / 2;
  if (root) {
    return `<svg style="position:absolute;right:16px;top:${y - 13}px" width="26" height="26" viewBox="0 0 26 26" fill="none" stroke="${accent}" stroke-width="1.8">` +
      `<circle cx="13" cy="13" r="11.5"/><circle cx="13" cy="10.2" r="3.8"/><path d="M5.6 20.6c1.7-2.7 4.3-4 7.4-4s5.7 1.3 7.4 4"/></svg>`;
  }
  return `<svg style="position:absolute;left:10px;top:${y - 12}px" width="14" height="24" viewBox="0 0 14 24" fill="none" stroke="${accent}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M11 2 2 12l9 10"/></svg>`;
}

function frameHtml(dev, png, info, selected, root) {
  const banner = hex(info.banner);
  const ink = hex(info.ink);
  const fg = isDark(info.banner) ? "#fff" : "#000";
  const top = dev.status + dev.nav;
  const contentHeight = dev.height - top - dev.tabs;
  // The app drops the browser-tab suffix (Banner.swift visitableDidRender).
  const title = escape(info.title.replace(/ · Rupert$/, ""));
  let nav, bottom;
  if (dev.floating) {
    nav = `<div style="position:absolute;left:0;right:0;top:${dev.status}px;height:${dev.nav}px;background:${banner}">` +
      `<span style="position:absolute;left:20px;top:0;font:600 17px/${dev.nav}px ${FONT};color:${ink}">${title}</span>` +
      `<div style="position:absolute;left:0;right:0;top:4px;text-align:center">${tabBar(selected, true)}</div></div>`;
    nav += navButtons(dev, ink, ACCENT, root);
    bottom = `<div style="position:absolute;left:50%;bottom:8px;width:320px;margin-left:-160px;height:5px;border-radius:3px;background:rgba(0,0,0,.85)"></div>`;
  } else {
    nav = `<div style="position:absolute;left:0;right:0;top:${dev.status}px;height:${dev.nav}px;background:${banner};text-align:center;` +
      `font:600 17px/${dev.nav}px ${FONT};color:${ink};padding:0 60px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${title}</div>`;
    nav += navButtons(dev, ink, ACCENT, root);
    bottom = `<div style="position:absolute;left:0;right:0;bottom:0;height:${dev.tabs}px;background:rgba(249,249,249,.97);` +
      `box-shadow:inset 0 .5px 0 rgba(0,0,0,.25)">${tabBar(selected, false)}` +
      `<div style="position:absolute;left:50%;bottom:8px;width:144px;margin-left:-72px;height:5px;border-radius:3px;background:#000"></div></div>`;
  }
  return `<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;width:${dev.width}px;height:${dev.height}px;` +
    `overflow:hidden;background:${banner}}img{position:absolute;left:0;top:${top}px;width:${dev.width}px;height:${contentHeight}px}</style></head><body>` +
    `<div style="position:absolute;left:0;right:0;top:0;height:${dev.status}px;background:${banner}"></div>` +
    `<img src="data:image/png;base64,${png.toString("base64")}">${nav}${statusBar(dev, fg)}${bottom}</body></html>`;
}

const FORBIDDEN = ["localhost", "127.0.0.1", "Herbal Healers", "Exception", "Routing Error", "We're sorry", "Something went wrong"];

async function capture(browser, name, dev, { baseUrl, password, countId, out }) {
  const viewport = { width: dev.width, height: dev.height - dev.status - dev.nav - dev.tabs };
  const context = await browser.newContext({
    viewport, deviceScaleFactor: dev.scale, isMobile: true, hasTouch: true, userAgent: ua(dev.uaDevice, dev.uaOs),
    locale: "en-US", timezoneId: process.env.TZ || "America/New_York", colorScheme: "light",
  });
  await context.addInitScript(NATIVE_BRIDGE);
  const page = await context.newPage();
  await page.goto(`${baseUrl}/login`, { waitUntil: "networkidle" });
  await page.fill('input[name="email"]', EMAIL);
  await page.fill('input[name="password"]', password);
  await Promise.all([page.waitForURL((url) => !url.pathname.startsWith("/login")), page.click('input[type="submit"][value="Sign in"]')]);

  const framer = await browser.newContext({ viewport: { width: dev.width, height: dev.height }, deviceScaleFactor: dev.scale });
  const framePage = await framer.newPage();
  for (const [stem, path, tab, devices, scrollTo] of SCREENS) {
    if (!devices.includes(name)) continue;
    await page.goto(baseUrl + path.replace("{count}", countId), { waitUntil: "networkidle" });
    await page.waitForTimeout(900); // charts and Stimulus controllers settle
    await page.evaluate((selector) => {
      document.activeElement?.blur();
      const target = selector && document.querySelector(selector);
      const bar = document.querySelector(".app-topbar");
      // Scrolled as a person would: the target just below Rupert's own (sticky) header.
      window.scrollTo(0, target ? target.getBoundingClientRect().top + window.scrollY - (bar ? bar.offsetHeight : 0) - 12 : 0);
    }, scrollTo || null);
    // Park the pointer on the empty middle of Rupert's header, so no hover-only toolbar shows.
    await page.mouse.move(dev.width / 2, 12);
    await page.waitForTimeout(250);
    const info = await page.evaluate(READ_PAGE);
    const problems = FORBIDDEN.filter((word) => info.text.includes(word));
    if (!info.nativeApp) problems.push("body is not .native-app");
    if (problems.length) console.error(`warning: ${name}-${stem} (${page.url()}): ${problems.join(", ")}`);
    const png = await page.screenshot({ animations: "disabled", caret: "hide" });
    const root = path === "/" || tab !== "home";
    await framePage.setContent(frameHtml(dev, png, info, tab, root), { waitUntil: "load" });
    const target = join(out, `${name}-${stem}.png`);
    await framePage.screenshot({ path: target, animations: "disabled" });
    console.log(`${name}-${stem}.png: ${info.title}`);
  }
  await context.close();
  await framer.close();
}

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, arg, i, all) =>
  arg.startsWith("--") ? [...pairs, [arg.slice(2), all[i + 1]]] : pairs, []));
const password = process.env.REVIEW_PASSWORD;
if (!password) { console.error("Set REVIEW_PASSWORD to the review account's password."); process.exit(1); }
if (!args["count-id"]) { console.error("Pass --count-id <draft inventory count id>."); process.exit(1); }
const out = args.out || dirname(fileURLToPath(import.meta.url));
mkdirSync(out, { recursive: true });
const browser = await chromium.launch();
try {
  for (const name of args.device ? [args.device] : Object.keys(DEVICES)) {
    await capture(browser, name, DEVICES[name], { baseUrl: (args["base-url"] || "http://127.0.0.1:3990").replace(/\/$/, ""), password, countId: args["count-id"], out });
  }
} finally {
  await browser.close();
}
