// WebMCP: offers Rupert's tools to an AI assistant running in this browser
// (W3C Web Machine Learning CG draft, `document.modelContext.registerTool`).
// See docs/webmcp.md.
//
// - Does nothing unless the browser has a model context, so ordinary visitors
//   pay nothing: no request is made and no tool exists.
// - The page says what to offer in <script type="application/json" id="rupert-webmcp">:
//     public pages: { mode: "public", tools: [{ ..., result }] } — static answers, nothing is fetched.
//     signed-in pages: { mode: "app", key, endpoint } — the tool list comes from the
//     server for the signed-in person, and each call goes back through the normal
//     session with the page's CSRF token.
// - A tool marked `confirm` changes data. The person must approve it in the
//   browser's own dialog first (the spec has no page-side confirmation API yet);
//   if they decline, nothing is sent.
// - With Turbo, the element changes on sign-in, sign-out and permission changes;
//   the old tools are unregistered (AbortSignal) and the new ones registered.

export const ELEMENT_ID = "rupert-webmcp"

// The draft's entry point is document.modelContext; early Chromium builds used navigator.modelContext.
export function modelContextOf(win) {
  const context = win?.document?.modelContext || win?.navigator?.modelContext
  return context && typeof context.registerTool === "function" ? context : null
}

export function readConfig(doc) {
  const element = doc?.getElementById?.(ELEMENT_ID)
  if (!element) return null
  try {
    const config = JSON.parse(element.textContent || "")
    return config && (config.mode === "public" || config.mode === "app") ? config : null
  } catch {
    return null
  }
}

export function errorResult(text, error = "tool_error") {
  return { content: [{ type: "text", text }], isError: true, error }
}

function descriptor(definition) {
  const tool = {
    name: definition.name,
    description: definition.description,
    inputSchema: definition.inputSchema || { type: "object", properties: {} },
  }
  if (definition.title) tool.title = definition.title
  if (definition.annotations) tool.annotations = definition.annotations
  return tool
}

// Public site: each tool answers from the facts embedded in the page.
export function buildPublicTools(config) {
  return (config.tools || []).map((definition) => ({
    ...descriptor(definition),
    execute: async () => ({
      content: [{ type: "text", text: JSON.stringify(definition.result) }],
      structuredContent: definition.result,
      isError: false,
    }),
  }))
}

function csrfTokenOf(doc) {
  return doc?.querySelector?.('meta[name="csrf-token"]')?.getAttribute?.("content") || ""
}

async function postTool(endpoint, name, body, { fetchImpl, doc, signal }) {
  let response
  try {
    response = await fetchImpl(`${endpoint}/${encodeURIComponent(name)}`, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": csrfTokenOf(doc),
        "X-Requested-With": "XMLHttpRequest",
      },
      body: JSON.stringify(body),
      signal,
    })
  } catch (error) {
    if (error?.name === "AbortError") throw error
    return errorResult("Rupert could not be reached. Check the connection and try again.", "network")
  }
  try {
    return await response.json()
  } catch {
    return errorResult(`Rupert answered with status ${response.status}.`, "bad_response")
  }
}

function argumentLines(input) {
  return Object.entries(input || {})
    .filter(([key]) => key !== "dry_run" && key !== "idempotency_key")
    .map(([key, value]) => `${key.replace(/_/g, " ")}: ${typeof value === "string" ? value : JSON.stringify(value)}`)
    .join("\n")
}

// "Dry run: would create task “X”. Nothing was saved." → "Would create task “X”."
function previewLine(preview) {
  const text = String(preview || "").replace(/^\s*dry run:\s*/i, "").replace(/\s*nothing was saved\.?\s*$/i, "").trim()
  return text ? text.charAt(0).toUpperCase() + text.slice(1) : ""
}

export function confirmationMessage(definition, input, preview) {
  const what = previewLine(preview) || argumentLines(input) || "(no details)"
  return `An AI assistant in this browser wants Rupert to: ${definition.title || definition.name}\n\n${what}\n\nAllow this change?`
}

// Signed-in app: each tool posts to the server as this person.
export function buildAppTools(definitions, { endpoint, fetchImpl, doc, confirmImpl }) {
  return definitions.map((definition) => ({
    ...descriptor(definition),
    execute: async (inputObject, options = {}) => {
      const input = inputObject && typeof inputObject === "object" ? inputObject : {}
      const request = { fetchImpl, doc, signal: options.signal }
      if (!definition.confirm || input.dry_run === true) {
        return postTool(endpoint, definition.name, { arguments: input }, request)
      }

      // Writes: validate and preview first (when the tool can), then ask the person.
      let preview = null
      if (definition.inputSchema?.properties?.dry_run) {
        const dryRun = await postTool(endpoint, definition.name, { arguments: { ...input, dry_run: true } }, request)
        if (dryRun?.isError) return dryRun
        preview = dryRun?.content?.[0]?.text || null
      }
      let approved = false
      try {
        approved = (await confirmImpl(confirmationMessage(definition, input, preview))) === true
      } catch {
        approved = false
      }
      if (!approved) return errorResult("The person declined in Rupert. Nothing was changed.", "declined")

      return postTool(endpoint, definition.name, { arguments: input, confirmed: true }, request)
    },
  }))
}

async function registerAll(context, tools, signal) {
  const handles = []
  let registered = 0
  for (const tool of tools) {
    if (signal.aborted) break
    try {
      const handle = await context.registerTool(tool, { signal })
      // Early drafts returned a handle instead of taking a signal.
      if (handle && typeof handle.unregister === "function") handles.push(handle)
      registered += 1
    } catch (error) {
      console.warn(`[webmcp] could not register ${tool.name}: ${error?.name || error}`)
    }
  }
  const unregister = () => handles.forEach((handle) => { try { handle.unregister() } catch { /* already gone */ } })
  if (signal.aborted) unregister()
  else signal.addEventListener("abort", unregister, { once: true })
  return registered
}

export function createWebMcp(win, deps = {}) {
  const fetchImpl = deps.fetchImpl || win.fetch?.bind(win)
  const confirmImpl = deps.confirmImpl || ((message) => win.confirm(message))
  let current = null

  async function sync() {
    const context = modelContextOf(win)
    if (!context) return "unsupported"

    const config = readConfig(win.document)
    const key = config ? (config.mode === "app" ? `app:${config.key}:${config.endpoint}` : "public") : null
    if (current && current.key === key) return "unchanged"
    if (current) {
      current.controller.abort()
      current = null
    }
    if (!config) return "cleared"

    const controller = new AbortController()
    current = { key, controller }
    let tools
    if (config.mode === "public") {
      tools = buildPublicTools(config)
    } else {
      let manifest
      try {
        const response = await fetchImpl(config.endpoint, {
          credentials: "same-origin",
          headers: { Accept: "application/json" },
          signal: controller.signal,
        })
        if (!response.ok) return "unavailable"
        manifest = await response.json()
      } catch {
        return controller.signal.aborted ? "aborted" : "unavailable"
      }
      tools = buildAppTools(manifest.tools || [], { endpoint: manifest.endpoint || config.endpoint, fetchImpl, doc: win.document, confirmImpl })
    }
    if (controller.signal.aborted) return "aborted"

    await registerAll(context, tools, controller.signal)
    return "registered"
  }

  return { sync, get key() { return current?.key || null } }
}

export function startWebMcp(win) {
  if (!win?.document) return null
  const instance = createWebMcp(win)
  instance.sync()
  win.document.addEventListener("turbo:load", () => instance.sync())
  return instance
}

// Starts itself in a browser page; importing it elsewhere (tests) does nothing.
if (typeof window !== "undefined" && window.document && !window.__rupertWebMcp) {
  window.__rupertWebMcp = startWebMcp(window)
}
