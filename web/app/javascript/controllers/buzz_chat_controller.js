import { Controller } from "@hotwired/stimulus"

// Team chat tab on the Buzz page: a small Buzz client. A channel list with unread
// markers, the selected channel's messages, threads, reactions and an @mention
// picker, all from BuzzChatController as JSON, kept current by polling.
//
// Every message is other people's text: it is only ever put on the page with
// textContent / DOM nodes, never innerHTML. A small safe subset of formatting
// (**bold**, `code`, http(s) links, line breaks) is built from DOM nodes, and a
// link is plain text plus an href. Nothing linked is fetched or previewed.
export default class extends Controller {
  static targets = [
    "log", "more", "status", "channels", "main", "threadPane", "threadLog", "threadTitle", "channelTitle", "channelAbout",
    "notice", "form", "input", "send", "count", "picker", "jump", "empty", "loading",
    "threadNotice", "threadForm", "threadInput", "threadSend", "threadCount", "threadPicker"
  ]
  static values = {
    url: String, canPost: Boolean, postMax: { type: Number, default: 1500 }, interval: { type: Number, default: 4000 },
    emoji: { type: Array, default: ["👍", "❤️", "😂", "🎉", "👀", "✅"] }
  }

  static GROUP_SECONDS = 5 * 60
  static MENTION_PATTERN = /(^|\s)@([^\s@]{0,30})$/

  connect() {
    this.channels = []
    this.current = null
    this.messages = []
    this.hasMore = false
    this.loadFailed = false
    this.status = null
    this.signature = ""
    this.thread = null // { root, replies }
    this.threadSignature = ""
    this.members = {} // channel id -> [member]
    this.mentions = { channel: new Map(), thread: new Map() } // name -> pubkey, per composer
    this.picking = { channel: null, thread: null } // the open picker: { items, index }
    this.sending = false
    this.busy = false
    this.fetchFailed = false
    this.lastRead = {}
    this.onClick = (event) => this.handleClick(event)
    this.element.addEventListener("click", this.onClick)
    this.onKey = (event) => { if (event.key === "Escape") this.closePopovers() }
    document.addEventListener("keydown", this.onKey)
    this.start()
    this.timer = setInterval(() => this.poll(), this.intervalValue)
    this.onVisible = () => { if (!document.hidden) this.poll() }
    document.addEventListener("visibilitychange", this.onVisible)
    this.ticker = setInterval(() => this.renderStatus(), 15000)
  }

  disconnect() {
    clearInterval(this.timer)
    clearInterval(this.ticker)
    document.removeEventListener("visibilitychange", this.onVisible)
    document.removeEventListener("keydown", this.onKey)
    this.element.removeEventListener("click", this.onClick)
  }

  // --- parsing (pure; also used by the tests) ---

  // Splits one line of text into parts: text, bold, code and link. Markup the
  // person typed stays text; only http(s) URLs become links.
  static parseLine(line) {
    const parts = []
    const pattern = /`([^`\n]+)`|\*\*([^*\n]+)\*\*|(https?:\/\/[^\s<>"'`]+)/g
    let last = 0
    let match
    const push = (type, value, extra = {}) => { if (value) parts.push({ type, text: value, ...extra }) }
    while ((match = pattern.exec(line)) !== null) {
      push("text", line.slice(last, match.index))
      last = match.index + match[0].length
      if (match[1] !== undefined) push("code", match[1])
      else if (match[2] !== undefined) push("bold", match[2])
      else {
        let url = match[3]
        let trailing = ""
        while (/[.,;:!?)\]}'"]$/.test(url) && !(url.endsWith(")") && url.includes("("))) {
          trailing = url.slice(-1) + trailing
          url = url.slice(0, -1)
        }
        const safe = this.safeUrl(url)
        if (safe) push("link", url, { href: safe })
        else push("text", url)
        push("text", trailing)
      }
    }
    push("text", line.slice(last))
    return parts
  }

  static safeUrl(value) {
    try {
      const url = new URL(value)
      if (url.protocol !== "http:" && url.protocol !== "https:") return null
      if (url.username || url.password) return null
      return url.href
    } catch (_error) {
      return null
    }
  }

  // The "@query" being typed just before the caret, or null.
  static mentionQuery(text, caret) {
    const match = this.MENTION_PATTERN.exec(text.slice(0, caret))
    return match ? { query: match[2], start: caret - match[2].length - 1 } : null
  }

  // Members whose name contains the query, the agent and name-prefix matches first.
  static filterMembers(members, query) {
    const needle = query.toLowerCase()
    return members
      .filter((member) => member.name.toLowerCase().includes(needle))
      .sort((a, b) => {
        const rank = (member) => (member.name.toLowerCase().startsWith(needle) ? 0 : 1) + (member.agent ? -0.5 : 0)
        return rank(a) - rank(b) || a.name.localeCompare(b.name)
      })
      .slice(0, 6)
  }

  // The pubkeys of the picked mentions whose "@name" is still in the text.
  static mentionedKeys(text, picked) {
    const keys = []
    picked.forEach((pubkey, name) => { if (text.includes(`@${name}`) && !keys.includes(pubkey)) keys.push(pubkey) })
    return keys
  }

  // Orders "posted_at:event_id" cursors numerically on the time part.
  static compareCursor(a, b) {
    const [ta, ia] = a.split(":")
    const [tb, ib] = b.split(":")
    return Number(ta) - Number(tb) || (ia < ib ? -1 : ia > ib ? 1 : 0)
  }

  // --- loading ---

  async start() {
    this.showLoading(true)
    await this.loadChannels()
    const saved = this.savedChannel()
    const wanted = this.channels.find((c) => c.id === saved) || this.channels.find((c) => c.default) || this.channels[0]
    if (wanted) await this.selectChannel(wanted.id)
    this.showLoading(false)
  }

  savedChannel() {
    try { return localStorage.getItem("buzzChat.channel") } catch (_error) { return null }
  }

  saveChannel(id) {
    try { localStorage.setItem("buzzChat.channel", id) } catch (_error) { /* private window: fine */ }
  }

  async getJSON(path, params = {}) {
    const query = new URLSearchParams(Object.entries(params).filter(([, value]) => value))
    const response = await fetch(`${this.urlValue}${path}${query.toString() ? `?${query}` : ""}`, { headers: { Accept: "application/json" }, credentials: "same-origin" })
    if (!response.ok) throw new Error(response.status === 403 || response.status === 404 ? "denied" : "failed")
    return response.json()
  }

  async postJSON(path, body) {
    const response = await fetch(`${this.urlValue}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": this.csrf },
      credentials: "same-origin",
      body: JSON.stringify(body)
    })
    const data = await response.json().catch(() => ({}))
    return { ok: response.ok, data }
  }

  async loadChannels() {
    try {
      const data = await this.getJSON("/channels")
      this.fetchFailed = false
      this.status = data.status
      this.channels = data.channels
      if (this.current) {
        const open = this.channels.find((c) => c.id === this.current)
        if (open) open.unread = 0
      }
      this.renderChannels()
    } catch (_error) {
      this.fetchFailed = true
    }
    this.renderStatus()
  }

  async selectChannel(id) {
    if (this.current === id && this.messages.length) return
    this.current = id
    this.saveChannel(id)
    this.messages = []
    this.signature = ""
    this.hasMore = false
    this.loadFailed = false
    this.closeThread()
    this.logTarget.querySelector("[data-buzz-chat-list]").replaceChildren()
    this.renderChannels()
    this.renderHeader()
    this.showLoading(true)
    await this.fetchLatest({ initial: true })
    this.showLoading(false)
    this.markRead()
  }

  async poll() {
    if (document.hidden || this.busy || this.sending) return
    this.busy = true
    try {
      await this.loadChannels()
      if (this.current) await this.fetchLatest({ initial: false })
      if (this.thread) await this.fetchThread({ refresh: false })
    } finally {
      this.busy = false
    }
  }

  // The latest page of the open channel. Earlier pages that were loaded are kept;
  // the newest window is replaced so edits, deletions, reactions and reply counts
  // stay current.
  async fetchLatest({ initial }) {
    const id = this.current
    if (!id) return
    try {
      const data = await this.getJSON("/messages", { channel: id })
      if (id !== this.current) return
      this.fetchFailed = false
      this.status = data.status
      this.mergeLatest(data, { initial })
    } catch (_error) {
      this.fetchFailed = true
    }
    this.renderStatus()
  }

  mergeLatest(data, { initial }) {
    const latest = data.messages
    const signature = JSON.stringify(latest)
    if (initial) {
      this.messages = latest
      this.hasMore = data.has_more
    } else {
      if (signature === this.signature && this.messages.length) return
      const first = latest[0]
      const older = first ? this.messages.filter((m) => this.constructor.compareCursor(m.cursor, first.cursor) < 0) : this.messages
      const known = new Set(this.messages.map((m) => m.id))
      this.messages = older.concat(latest)
      this.fresh = latest.filter((m) => !known.has(m.id)).length
    }
    this.signature = signature
    const log = this.logTarget
    const atBottom = initial || log.scrollHeight - log.scrollTop - log.clientHeight < 80
    this.renderAll()
    if (atBottom) {
      this.jumpTo(log.scrollHeight)
      this.hideJump()
      if (!initial) this.markRead()
    } else if (this.fresh) {
      this.showJump()
    }
    this.fresh = 0
  }

  async loadEarlier() {
    if (this.busy || !this.messages.length) return
    this.busy = true
    this.moreTarget.disabled = true
    this.moreTarget.textContent = "Loading…"
    try {
      const data = await this.getJSON("/messages", { channel: this.current, before: this.messages[0].cursor })
      const known = new Set(this.messages.map((m) => m.id))
      const log = this.logTarget
      const before = log.scrollHeight
      this.messages = data.messages.filter((m) => !known.has(m.id)).concat(this.messages)
      this.hasMore = data.has_more
      this.loadFailed = data.older_failed
      this.renderAll()
      this.jumpTo(log.scrollTop + log.scrollHeight - before)
    } catch (_error) {
      this.loadFailed = true
    } finally {
      this.busy = false
      this.renderMore()
    }
  }

  async markRead() {
    const id = this.current
    if (!id || document.hidden) return
    const newest = this.messages[this.messages.length - 1]
    const mark = newest ? newest.cursor : "none"
    if (this.lastRead[id] === mark) return
    this.lastRead[id] = mark
    const channel = this.channels.find((c) => c.id === id)
    if (channel) { channel.unread = 0; this.renderChannels() }
    try { await this.postJSON("/read", { channel: id }) } catch (_error) { /* the next poll tries again */ }
  }

  // --- threads ---

  async openThread(id) {
    this.thread = { root: { id }, replies: [] }
    this.threadSignature = ""
    this.element.dataset.threadOpen = "true"
    this.threadPaneTarget.hidden = false
    await this.fetchThread({ refresh: true })
    this.threadPaneTarget.querySelector("[data-thread-focus]")?.focus()
  }

  closeThread() {
    this.thread = null
    this.element.dataset.threadOpen = "false"
    if (this.hasThreadPaneTarget) this.threadPaneTarget.hidden = true
    this.mentions.thread.clear()
    if (this.hasThreadInputTarget) { this.threadInputTarget.value = ""; this.syncComposer("thread") }
  }

  async fetchThread({ refresh }) {
    const id = this.thread && this.thread.root.id
    if (!id) return
    try {
      const data = await this.getJSON(`/threads/${id}`, { channel: this.current, refresh: refresh ? "1" : "" })
      if (!this.thread || this.thread.root.id !== id) return
      const signature = JSON.stringify(data)
      if (signature === this.threadSignature) return
      this.threadSignature = signature
      this.thread = { root: data.root, replies: data.replies }
      this.renderThread()
    } catch (_error) {
      if (refresh) { this.closeThread(); this.setNotice("channel", "That thread is not available any more.") }
    }
  }

  // --- rendering ---

  renderChannels() {
    if (!this.hasChannelsTarget) return
    const list = this.channelsTarget
    list.replaceChildren()
    this.channels.forEach((channel) => {
      const item = document.createElement("li")
      const button = document.createElement("button")
      button.type = "button"
      button.className = "buzz-channel"
      button.dataset.channel = channel.id
      if (channel.id === this.current) button.setAttribute("aria-current", "true")
      const name = document.createElement("span")
      name.className = "buzz-channel-name"
      name.textContent = `# ${channel.name}`
      button.append(name)
      if (channel.unread > 0 && channel.id !== this.current) {
        const badge = document.createElement("span")
        badge.className = "buzz-unread"
        badge.textContent = channel.unread > 99 ? "99+" : String(channel.unread)
        badge.setAttribute("aria-label", `${channel.unread} unread`)
        button.classList.add("buzz-channel-unread")
        button.append(badge)
      }
      item.append(button)
      list.append(item)
    })
  }

  renderHeader() {
    const channel = this.channels.find((c) => c.id === this.current)
    if (this.hasChannelTitleTarget) this.channelTitleTarget.textContent = channel ? `# ${channel.name}` : "Team chat"
    if (this.hasChannelAboutTarget) this.channelAboutTarget.textContent = channel && channel.about ? channel.about : ""
  }

  renderAll() {
    const holder = this.logTarget.querySelector("[data-buzz-chat-list]")
    holder.replaceChildren()
    this.buildTimeline(this.messages, holder, { replies: false })
    this.renderMore()
    this.renderEmpty()
  }

  // Messages grouped by day and by author, as DOM nodes.
  buildTimeline(list, holder, { replies }) {
    let previous = null
    list.forEach((message) => {
      const day = new Date(message.at)
      if (!previous || !this.sameDay(new Date(previous.at), day)) holder.append(this.dayDivider(day))
      const grouped = previous && this.sameDay(new Date(previous.at), day) && this.sameAuthor(previous, message) &&
        (day - new Date(previous.at)) / 1000 < this.constructor.GROUP_SECONDS
      holder.append(this.buildMessage(message, grouped, { replies }))
      previous = message
    })
  }

  renderThread() {
    if (!this.thread || !this.hasThreadLogTarget) return
    const log = this.threadLogTarget
    const stick = log.scrollHeight - log.scrollTop - log.clientHeight < 80
    const holder = document.createDocumentFragment()
    holder.append(this.buildMessage(this.thread.root, false, { replies: true, root: true }))
    const count = document.createElement("p")
    count.className = "buzz-thread-count"
    const total = this.thread.replies.length
    count.textContent = total === 0 ? "No replies yet." : `${total} ${total === 1 ? "reply" : "replies"}`
    holder.append(count)
    this.buildTimeline(this.thread.replies, holder, { replies: true })
    log.replaceChildren(holder)
    if (stick) log.scrollTop = log.scrollHeight
    if (this.hasThreadTitleTarget) this.threadTitleTarget.textContent = `Thread in ${this.channelTitleTarget.textContent}`
  }

  buildMessage(message, grouped, { replies, root = false }) {
    const item = document.createElement("article")
    item.className = "buzz-msg"
    if (message.agent) item.classList.add("buzz-msg-agent")
    if (message.mine) item.classList.add("buzz-msg-mine")
    if (grouped) item.classList.add("buzz-msg-grouped")
    if (root) item.classList.add("buzz-msg-root")
    item.dataset.messageId = message.id
    if (!grouped) {
      const head = document.createElement("header")
      head.className = "buzz-msg-head"
      const name = document.createElement("span")
      name.className = message.named ? "buzz-msg-author" : "buzz-msg-author buzz-msg-unnamed"
      name.textContent = message.author
      name.title = message.key
      head.append(name)
      if (message.agent) head.append(this.badge(message.via_rupert ? "via Rupert" : "AI agent", "buzz-badge-agent"))
      const time = document.createElement("time")
      time.className = "buzz-msg-time"
      time.dateTime = message.at
      time.textContent = this.timeLabel(new Date(message.at))
      time.title = new Date(message.at).toLocaleString()
      head.append(time)
      if (message.edited) head.append(this.badge("edited", "buzz-badge-quiet"))
      item.append(head)
    }
    const body = document.createElement("div")
    body.className = "buzz-msg-body"
    message.text.split("\n").forEach((line, index) => {
      if (index > 0) body.append(document.createElement("br"))
      this.constructor.parseLine(line).forEach((part) => body.append(this.partNode(part)))
    })
    item.append(body)
    item.append(this.buildFooter(message, { replies, root }))
    return item
  }

  // Reaction chips, the add-reaction button and the reply / thread link.
  buildFooter(message, { replies, root }) {
    const footer = document.createElement("div")
    footer.className = "buzz-msg-foot"
    message.reactions.forEach((reaction) => {
      const chip = document.createElement("button")
      chip.type = "button"
      chip.className = "buzz-reaction"
      chip.dataset.react = reaction.emoji
      chip.dataset.message = message.id
      chip.disabled = !this.canPostValue
      chip.setAttribute("aria-pressed", reaction.mine ? "true" : "false")
      chip.title = reaction.by.join(", ")
      chip.setAttribute("aria-label", `${reaction.emoji} ${reaction.count}: ${reaction.by.join(", ")}`)
      const emoji = document.createElement("span")
      emoji.textContent = reaction.emoji
      const count = document.createElement("span")
      count.className = "buzz-reaction-count"
      count.textContent = String(reaction.count)
      chip.append(emoji, count)
      footer.append(chip)
    })
    if (this.canPostValue) {
      const add = document.createElement("button")
      add.type = "button"
      add.className = "buzz-act"
      add.dataset.reactMenu = message.id
      add.setAttribute("aria-haspopup", "true")
      add.setAttribute("aria-expanded", "false")
      add.setAttribute("aria-label", "Add a reaction")
      add.textContent = "☺ +"
      footer.append(add)
    }
    if (!replies && !message.root) {
      const link = document.createElement("button")
      link.type = "button"
      link.className = message.reply_count > 0 ? "buzz-thread-link" : "buzz-act"
      link.dataset.openThread = message.id
      link.textContent = message.reply_count > 0 ? `${message.reply_count} ${message.reply_count === 1 ? "reply" : "replies"}` : "Reply"
      if (message.reply_count > 0 && message.last_reply_at) link.title = `Last reply ${this.timeLabel(new Date(message.last_reply_at))}`
      footer.append(link)
    }
    return footer
  }

  partNode(part) {
    if (part.type === "text") return document.createTextNode(part.text)
    if (part.type === "bold") {
      const strong = document.createElement("strong")
      strong.textContent = part.text
      return strong
    }
    if (part.type === "code") {
      const code = document.createElement("code")
      code.textContent = part.text
      return code
    }
    const link = document.createElement("a")
    link.href = part.href
    link.textContent = part.text
    link.target = "_blank"
    link.rel = "noopener noreferrer nofollow ugc"
    return link
  }

  badge(text, extra) {
    const span = document.createElement("span")
    span.className = `buzz-badge ${extra}`
    span.textContent = text
    return span
  }

  dayDivider(day) {
    const divider = document.createElement("div")
    divider.className = "buzz-day"
    divider.setAttribute("role", "separator")
    const label = document.createElement("span")
    label.textContent = this.dayLabel(day)
    divider.append(label)
    return divider
  }

  renderMore() {
    const button = this.moreTarget
    button.hidden = !this.hasMore
    button.disabled = false
    button.textContent = this.loadFailed ? "Couldn’t load earlier messages. Try again" : "Load earlier messages"
  }

  renderEmpty() {
    if (this.hasEmptyTarget) this.emptyTarget.hidden = this.messages.length > 0
  }

  showLoading(on) {
    if (this.hasLoadingTarget) this.loadingTarget.hidden = !on
  }

  renderStatus() {
    if (!this.hasStatusTarget) return
    const node = this.statusTarget
    let text = ""
    let tone = "ok"
    if (this.fetchFailed) {
      text = "Rupert can’t be reached right now. Retrying…"
      tone = "bad"
    } else if (this.status && this.status.error) {
      const reason = this.status.error.charAt(0).toUpperCase() + this.status.error.slice(1)
      const when = this.status.synced_at ? ` Showing saved messages from ${this.ago(this.status.synced_at)}.` : " Showing what Rupert has saved."
      text = `Not live. ${reason.replace(/\.$/, "")}.${when}`
      tone = "warn"
    } else if (this.status && this.status.synced_at) {
      text = `Live · updated ${this.ago(this.status.synced_at)}`
    } else if (this.status) {
      text = "Connecting to Buzz…"
    }
    node.textContent = text
    node.dataset.tone = tone
  }

  showJump() { if (this.hasJumpTarget) this.jumpTarget.hidden = false }
  hideJump() { if (this.hasJumpTarget) this.jumpTarget.hidden = true }

  // The log scrolls smoothly for people; loading and restoring positions must not animate.
  jumpTo(top) {
    this.logTarget.scrollTo({ top, behavior: "instant" })
  }

  scrollToEnd() {
    this.logTarget.scrollTo({ top: this.logTarget.scrollHeight, behavior: "smooth" })
    this.hideJump()
    this.markRead()
  }

  onScroll() {
    const log = this.logTarget
    if (log.scrollHeight - log.scrollTop - log.clientHeight < 80) { this.hideJump(); this.markRead() }
  }

  // --- clicks ---

  handleClick(event) {
    const target = event.target.closest("[data-channel], [data-react], [data-react-menu], [data-pick-emoji], [data-open-thread], [data-close-thread], [data-pick-member]")
    if (!target) {
      this.closePopovers()
      return
    }
    if (target.dataset.channel) this.selectChannel(target.dataset.channel)
    else if (target.dataset.openThread) this.openThread(target.dataset.openThread)
    else if (target.dataset.closeThread !== undefined) this.closeThread()
    else if (target.dataset.reactMenu) this.toggleEmojiMenu(target)
    else if (target.dataset.pickEmoji) { this.react(target.dataset.message, target.dataset.pickEmoji); this.closePopovers() }
    else if (target.dataset.react) this.react(target.dataset.message, target.dataset.react)
    else if (target.dataset.pickMember !== undefined) this.pickMember(target.dataset.scope, Number(target.dataset.pickMember))
  }

  closePopovers() {
    this.element.querySelectorAll(".buzz-emoji-pop").forEach((pop) => {
      pop.parentElement.querySelector("[data-react-menu]")?.setAttribute("aria-expanded", "false")
      pop.remove()
    })
  }

  toggleEmojiMenu(button) {
    const open = button.parentElement.querySelector(".buzz-emoji-pop")
    this.closePopovers()
    if (open) return
    const pop = document.createElement("div")
    pop.className = "buzz-emoji-pop"
    pop.setAttribute("role", "menu")
    this.emojiValue.forEach((emoji) => {
      const choice = document.createElement("button")
      choice.type = "button"
      choice.className = "buzz-emoji"
      choice.setAttribute("role", "menuitem")
      choice.dataset.pickEmoji = emoji
      choice.dataset.message = button.dataset.reactMenu
      choice.textContent = emoji
      choice.setAttribute("aria-label", `React with ${emoji}`)
      pop.append(choice)
    })
    button.setAttribute("aria-expanded", "true")
    button.after(pop)
    pop.querySelector("button")?.focus()
  }

  async react(messageId, emoji) {
    if (!this.canPostValue || this.sending) return
    const { ok, data } = await this.postJSON("/reactions", { channel: this.current, message: messageId, emoji })
    if (!ok) {
      this.setNotice(this.thread ? "thread" : "channel", data.error || "The reaction was not sent. Try again.")
      return
    }
    await this.fetchLatest({ initial: false })
    if (this.thread) await this.fetchThread({ refresh: false })
  }

  // --- posting ---

  composer(scope) {
    return scope === "thread"
      ? { input: this.threadInputTarget, send: this.threadSendTarget, count: this.threadCountTarget, picker: this.threadPickerTarget }
      : { input: this.inputTarget, send: this.sendTarget, count: this.hasCountTarget ? this.countTarget : null, picker: this.pickerTarget }
  }

  keydown(event) {
    const scope = event.currentTarget === this.threadInputTarget ? "thread" : "channel"
    const picking = this.picking[scope]
    if (picking && picking.items.length) {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault()
        picking.index = (picking.index + (event.key === "ArrowDown" ? 1 : picking.items.length - 1)) % picking.items.length
        this.renderPicker(scope)
        return
      }
      if (event.key === "Enter" || event.key === "Tab") {
        event.preventDefault()
        this.pickMember(scope, picking.index)
        return
      }
      if (event.key === "Escape") {
        event.preventDefault()
        this.hidePicker(scope)
        return
      }
    }
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault()
      this.send(event, scope)
    }
  }

  input(event) {
    this.syncComposer(event.currentTarget === this.threadInputTarget ? "thread" : "channel")
  }

  syncComposer(scope) {
    const { input, send, count } = this.composer(scope)
    input.style.height = "auto"
    input.style.height = `${Math.min(input.scrollHeight, 160)}px`
    const length = input.value.length
    if (count) {
      count.hidden = length < this.postMaxValue * 0.8
      count.textContent = `${length} / ${this.postMaxValue}`
      count.dataset.over = length > this.postMaxValue ? "true" : "false"
    }
    send.disabled = this.sending || !input.value.trim() || length > this.postMaxValue
    this.updatePicker(scope)
  }

  submitChannel(event) { this.send(event, "channel") }
  submitThread(event) { this.send(event, "thread") }

  async send(event, scope = "channel") {
    if (event) event.preventDefault()
    if (this.sending || !this.canPostValue) return
    const { input } = this.composer(scope)
    const text = input.value.trim()
    if (!text || text.length > this.postMaxValue) return
    this.sending = true
    this.composer(scope).send.disabled = true
    this.setNotice(scope, "")
    try {
      const body = { channel: this.current, message: text, mentions: this.constructor.mentionedKeys(text, this.mentions[scope]) }
      if (scope === "thread") body.reply_to = this.thread.root.id
      const { ok, data } = await this.postJSON("/messages", body)
      if (!ok) {
        this.setNotice(scope, data.error || "Your message was not sent. Try again.")
        return
      }
      input.value = ""
      this.mentions[scope].clear()
      this.sending = false
      this.syncComposer(scope)
      await this.fetchLatest({ initial: false })
      if (scope === "thread") await this.fetchThread({ refresh: false })
      else this.scrollToEnd()
    } catch (_error) {
      this.setNotice(scope, "Your message was not sent. Check your connection and try again.")
    } finally {
      this.sending = false
      this.syncComposer(scope)
      input.focus()
    }
  }

  setNotice(scope, text) {
    const node = scope === "thread" ? (this.hasThreadNoticeTarget ? this.threadNoticeTarget : null) : (this.hasNoticeTarget ? this.noticeTarget : null)
    if (!node) return
    node.textContent = text
    node.hidden = !text
  }

  // --- mentions ---

  async channelMembers() {
    const id = this.current
    if (this.members[id]) return this.members[id]
    try {
      const data = await this.getJSON("/members", { channel: id })
      this.members[id] = data.members
    } catch (_error) {
      this.members[id] = []
    }
    return this.members[id]
  }

  async updatePicker(scope) {
    const { input } = this.composer(scope)
    const found = this.constructor.mentionQuery(input.value, input.selectionStart ?? input.value.length)
    if (!found) { this.hidePicker(scope); return }
    const members = await this.channelMembers()
    const items = this.constructor.filterMembers(members, found.query)
    this.picking[scope] = items.length ? { items, index: 0, start: found.start, end: found.start + 1 + found.query.length } : null
    this.renderPicker(scope)
  }

  renderPicker(scope) {
    const { picker, input } = this.composer(scope)
    const state = this.picking[scope]
    picker.replaceChildren()
    picker.hidden = !state
    input.setAttribute("aria-expanded", state ? "true" : "false")
    if (!state) { input.removeAttribute("aria-activedescendant"); return }
    state.items.forEach((member, index) => {
      const option = document.createElement("button")
      option.type = "button"
      option.id = `buzz-${scope}-mention-${index}`
      option.className = "buzz-mention-option"
      option.setAttribute("role", "option")
      option.setAttribute("aria-selected", index === state.index ? "true" : "false")
      option.dataset.pickMember = String(index)
      option.dataset.scope = scope
      option.addEventListener("mousedown", (event) => event.preventDefault()) // keep the caret in the box
      const name = document.createElement("span")
      name.textContent = `@${member.name}`
      option.append(name)
      if (member.agent) option.append(this.badge("AI agent", "buzz-badge-agent"))
      picker.append(option)
    })
    input.setAttribute("aria-activedescendant", `buzz-${scope}-mention-${state.index}`)
  }

  hidePicker(scope) {
    this.picking[scope] = null
    this.renderPicker(scope)
  }

  pickMember(scope, index) {
    const state = this.picking[scope]
    if (!state || !state.items[index]) return
    const member = state.items[index]
    const { input } = this.composer(scope)
    const text = input.value
    const insert = `@${member.name} `
    input.value = text.slice(0, state.start) + insert + text.slice(state.end)
    const caret = state.start + insert.length
    input.setSelectionRange(caret, caret)
    this.mentions[scope].set(member.name, member.pubkey)
    this.hidePicker(scope)
    this.syncComposer(scope)
    input.focus()
  }

  get csrf() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  // --- time ---

  sameDay(a, b) { return a.toDateString() === b.toDateString() }
  sameAuthor(a, b) { return a.author === b.author && a.agent === b.agent && a.via_rupert === b.via_rupert && a.key === b.key }

  timeLabel(date) {
    return date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
  }

  dayLabel(date) {
    const today = new Date()
    const yesterday = new Date(today.getTime() - 86400000)
    if (this.sameDay(date, today)) return "Today"
    if (this.sameDay(date, yesterday)) return "Yesterday"
    return date.toLocaleDateString([], { weekday: "short", month: "short", day: "numeric", year: date.getFullYear() === today.getFullYear() ? undefined : "numeric" })
  }

  ago(iso) {
    const seconds = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000))
    if (seconds < 10) return "just now"
    if (seconds < 90) return `${seconds}s ago`
    const minutes = Math.round(seconds / 60)
    if (minutes < 90) return `${minutes} min ago`
    return new Date(iso).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })
  }
}
