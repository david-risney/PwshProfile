"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const path = require("node:path");
const { execFile, spawn } = require("node:child_process");
const { promisify } = require("node:util");
const {
  createProxyMiddleware,
  responseInterceptor,
} = require("http-proxy-middleware");

const execFileAsync = promisify(execFile);
const sessionPattern = /^[A-Za-z0-9_.-]+$/;
const isValidSessionName = (session) =>
  sessionPattern.test(session) && session !== "." && session !== "..";
const logo = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="12" fill="#1559a6"/>
  <path d="m15 20 13 12-13 12" fill="none" stroke="#fff" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M34 45h16" fill="none" stroke="#fff" stroke-width="6" stroke-linecap="round"/>
</svg>`;
const terminalFontFamily = `"Long Run Nerd Font", "CaskaydiaCove NFM", "CaskaydiaCove NF", "Cascadia Mono", Consolas, monospace`;
const terminalLifecycleMarkup = `<style>
#long-run-session-closed{box-sizing:border-box;display:grid;min-height:100vh;place-content:center;gap:1rem;padding:2rem;background:hsl(220 18% 10%);color:hsl(210 20% 92%);font:1rem/1.5 system-ui,sans-serif;text-align:center}
#long-run-session-closed h1,#long-run-session-closed p{margin:0}
#long-run-session-closed a{justify-self:center;padding:.55rem .9rem;border-radius:.4rem;background:hsl(211 75% 45%);color:white;text-decoration:none}
#long-run-session-closed a:hover{background:hsl(211 75% 52%)}
</style>
<script>
(() => {
  const match = /^\\/tmux\\/session\\/([^/]+)\\//.exec(location.pathname);
  if (!match) return;
  const session = decodeURIComponent(match[1]);
  let ended = false;
  async function checkSession() {
    if (ended) return;
    try {
      const response = await fetch(
        "/tmux/api/sessions/" + encodeURIComponent(session),
        { cache: "no-store", credentials: "same-origin" },
      );
      if (response.status !== 404) return;
      ended = true;
      clearInterval(timer);
      document.title = session + " closed";
      const main = document.createElement("main");
      main.id = "long-run-session-closed";
      main.setAttribute("aria-live", "polite");
      const heading = document.createElement("h1");
      heading.textContent = "Session closed";
      const detail = document.createElement("p");
      detail.textContent = "The psmux session '" + session + "' is no longer running.";
      const link = document.createElement("a");
      link.href = "/tmux/";
      link.textContent = "Back to sessions";
      main.append(heading, detail, link);
      document.body.replaceChildren(main);
    } catch (error) {
      console.debug("Could not check whether the psmux session ended.", error);
    }
  }
  const timer = setInterval(checkSession, 1000);
  addEventListener("pagehide", () => clearInterval(timer), { once: true });
})();
</script>`;
const nestedPsmuxVariables = new Set([
  "ci",
  "clicolor",
  "clicolor_force",
  "force_color",
  "gh_prompt_disabled",
  "git_askpass",
  "git_terminal_prompt",
  "no_color",
  "pwsh_profile_minimal",
  "ssh_askpass",
  "psmux_claude_teammate_mode",
  "psmux_pipe_vt",
  "psmux_session",
  "psmux_target_session",
  "tmux",
  "tmux_pane",
  "wt_profile_id",
  "wt_session",
]);

function commandSpec(value) {
  return typeof value === "string" ? { file: value, args: [] } : value;
}

function runCommand(command, args, options = {}) {
  const spec = commandSpec(command);
  return execFileAsync(spec.file, [...(spec.args || []), ...args], {
    windowsHide: true,
    maxBuffer: 1024 * 1024,
    ...options,
  });
}

function spawnCommand(command, args, options = {}) {
  const spec = commandSpec(command);
  return spawn(spec.file, [...(spec.args || []), ...args], {
    windowsHide: true,
    ...options,
  });
}

function withoutPsmuxSessionEnvironment(environment) {
  return Object.fromEntries(Object.entries(environment).filter(
    ([name]) => {
      const lowerName = name.toLowerCase();
      return !nestedPsmuxVariables.has(lowerName) &&
        !lowerName.startsWith("copilot_") &&
        !lowerName.startsWith("dragon_") &&
        lowerName !== "dragon-server" &&
        !lowerName.startsWith("git_config_");
    },
  ));
}

function psmuxAttachEnvironment(environment) {
  // ttyd gives psmux a console/PTY. Pipe mode drops non-character console
  // input such as arrows and function keys on Windows.
  return withoutPsmuxSessionEnvironment(environment);
}

function isExpectedProxyDisconnect(error) {
  return new Set([
    "ECONNABORTED",
    "ECONNRESET",
    "EPIPE",
    "ERR_STREAM_PREMATURE_CLOSE",
  ]).has(error?.code);
}

function html(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function asDate(epochSeconds) {
  const seconds = Number(epochSeconds);
  return Number.isFinite(seconds) && seconds > 0
    ? new Date(seconds * 1000)
    : null;
}

function asInteger(value) {
  if (value === "" || value === null || value === undefined) {
    return null;
  }
  const number = Number(value);
  return Number.isInteger(number) ? number : null;
}

function formatDate(date) {
  if (!date) {
    return '<span class="muted">Unknown</span>';
  }
  const elapsedSeconds = Math.round((date.getTime() - Date.now()) / 1000);
  const ranges = [
    ["year", 365 * 24 * 60 * 60],
    ["month", 30 * 24 * 60 * 60],
    ["week", 7 * 24 * 60 * 60],
    ["day", 24 * 60 * 60],
    ["hour", 60 * 60],
    ["minute", 60],
  ];
  let relative = "just now";
  for (const [unit, seconds] of ranges) {
    if (Math.abs(elapsedSeconds) >= seconds) {
      relative = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" })
        .format(Math.round(elapsedSeconds / seconds), unit);
      break;
    }
  }
  const datetime = date.toISOString().replace(/\.\d{3}Z$/, "Z");
  return `<time datetime="${html(datetime)}" title="${html(
    new Intl.DateTimeFormat(undefined, {
      dateStyle: "medium",
      timeStyle: "long",
    }).format(date),
  )}">${html(relative)}</time>`;
}

function parseSessionPath(pathname) {
  const match = /^\/tmux\/session\/([^/]+)(\/.*)?$/.exec(pathname);
  if (!match) {
    return null;
  }
  let session;
  try {
    session = decodeURIComponent(match[1]);
  } catch {
    return null;
  }
  if (!isValidSessionName(session)) {
    return null;
  }
  return { session, suffix: match[2] || "" };
}

function readBody(req, maxBytes = 8192) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let length = 0;
    req.on("data", (chunk) => {
      length += chunk.length;
      if (length > maxBytes) {
        reject(new Error("Request body is too large."));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

async function readJson(req) {
  if (!String(req.headers["content-type"] || "").toLowerCase()
    .startsWith("application/json")) {
    const error = new Error("Content-Type must be application/json.");
    error.statusCode = 415;
    throw error;
  }
  try {
    return JSON.parse(await readBody(req));
  } catch (error) {
    if (error.statusCode) throw error;
    const invalid = new Error("The request body is not valid JSON.");
    invalid.statusCode = 400;
    throw invalid;
  }
}

async function getFreePort(host) {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.on("error", reject);
    server.listen(0, host, () => {
      const address = server.address();
      server.close((error) => {
        if (error) {
          reject(error);
        } else {
          resolve(address.port);
        }
      });
    });
  });
}

async function waitForPort(host, port, child, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`ttyd exited before listening on port ${port}.`);
    }
    const connected = await new Promise((resolve) => {
      const socket = net.createConnection({ host, port });
      socket.setTimeout(200);
      socket.once("connect", () => {
        socket.destroy();
        resolve(true);
      });
      socket.once("timeout", () => {
        socket.destroy();
        resolve(false);
      });
      socket.once("error", () => resolve(false));
    });
    if (connected) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 75));
  }
  throw new Error(`Timed out waiting for ttyd on port ${port}.`);
}

function securityHeaders(res) {
  res.setHeader("Content-Security-Policy",
    "default-src 'none'; img-src 'self'; connect-src 'self'; script-src 'self'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'");
  res.setHeader("Referrer-Policy", "no-referrer");
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "DENY");
  res.setHeader("Cache-Control", "no-store");
}

function sendJson(res, status, value, headers = {}) {
  securityHeaders(res);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    ...headers,
  });
  res.end(JSON.stringify(value));
}

function sendText(res, status, text) {
  securityHeaders(res);
  res.writeHead(status, { "Content-Type": "text/plain; charset=utf-8" });
  res.end(text);
}

function sendHtml(res, status, content) {
  securityHeaders(res);
  res.writeHead(status, { "Content-Type": "text/html; charset=utf-8" });
  res.end(content);
}

function sendFile(res, filePath, contentType) {
  const stat = fs.statSync(filePath);
  res.writeHead(200, {
    "Content-Type": contentType,
    "Content-Length": stat.size,
    "Cache-Control": "private, max-age=3600",
    "X-Content-Type-Options": "nosniff",
  });
  fs.createReadStream(filePath).pipe(res);
}

function redirect(res, location) {
  res.writeHead(303, { Location: location, "Cache-Control": "no-store" });
  res.end();
}

function sortableHeader(label, key, direction = "none") {
  const nextDirection = direction === "ascending" ? "descending" : "ascending";
  const indicatorDirection = direction === "ascending"
    ? "asc"
    : direction === "descending"
      ? "desc"
      : "none";
  return `<th scope="col" aria-sort="${direction}"><button class="sort-link" type="button" data-sort="${key}" data-label="${label}" data-direction="${indicatorDirection}" aria-label="Sort by ${label} ${nextDirection}"><span class="sort-label">${label}</span><span class="sort-indicator" aria-hidden="true"><span class="sort-triangle sort-up"></span><span class="sort-triangle sort-down"></span></span></button></th>`;
}

function page(defaultWorkingDirectory, csrfToken, version) {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="csrf-token" content="${html(csrfToken)}">
  <link rel="icon" href="/tmux/assets/logo.svg" type="image/svg+xml">
  <title>Session inventory | psmux sessions</title>
  <style>
    :root {
      color-scheme: light dark;
      --background: hsl(220 18% 97%);
      --foreground: hsl(220 28% 15%);
      --surface: hsl(0 0% 100%);
      --border: hsl(220 12% 82%);
      --accent: hsl(215 75% 46%);
      --danger: hsl(3 72% 44%);
      --muted: hsl(220 10% 42%);
      font-family: system-ui, sans-serif;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --background: hsl(220 22% 11%);
        --foreground: hsl(220 16% 90%);
        --surface: hsl(220 20% 16%);
        --border: hsl(220 13% 30%);
        --accent: hsl(210 90% 67%);
        --danger: hsl(4 82% 68%);
        --muted: hsl(220 11% 68%);
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--background);
      color: var(--foreground);
    }
    main {
      inline-size: min(72rem, calc(100% - 2rem));
      margin-inline: auto;
      padding-block: 2rem 4rem;
    }
    header, .toolbar, .actions {
      display: flex;
      align-items: center;
      gap: .75rem;
      flex-wrap: wrap;
    }
    header { justify-content: space-between; }
    h1 { margin-block: 0 .25rem; }
    p { line-height: 1.5; }
    a { color: var(--accent); }
    table {
      inline-size: 100%;
      margin-block-start: 1.5rem;
      border-collapse: collapse;
      background: var(--surface);
      border: 1px solid var(--border);
    }
    th, td {
      padding: .8rem;
      border-block-end: 1px solid var(--border);
      text-align: start;
      vertical-align: middle;
    }
    th { font-size: .875rem; }
    .sort-link {
      display: inline-flex;
      align-items: center;
      gap: .35rem;
      min-block-size: auto;
      padding: 0;
      color: var(--accent);
      background: transparent;
      border: 0;
      border-radius: .2rem;
      white-space: nowrap;
    }
    .sort-link:hover .sort-label { text-decoration: underline; }
    .sort-link:focus-visible {
      outline: 2px solid var(--accent);
      outline-offset: 3px;
    }
    .sort-indicator {
      display: inline-flex;
      flex-direction: column;
      gap: 1px;
      inline-size: .55rem;
      flex: none;
    }
    .sort-triangle {
      inline-size: 0;
      block-size: 0;
      border-inline: .275rem solid transparent;
      opacity: .32;
    }
    .sort-up { border-block-end: .35rem solid currentColor; }
    .sort-down { border-block-start: .35rem solid currentColor; }
    .sort-link[data-direction="asc"] .sort-up,
    .sort-link[data-direction="desc"] .sort-down {
      opacity: 1;
    }
    .sort-link[data-direction="asc"] .sort-down,
    .sort-link[data-direction="desc"] .sort-up {
      opacity: .12;
    }
    code { overflow-wrap: anywhere; }
    button, input, .button {
      min-block-size: 2.5rem;
      padding: .5rem .75rem;
      color: var(--foreground);
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: .35rem;
      font: inherit;
    }
    button, .button { cursor: pointer; }
    .button { display: inline-flex; align-items: center; text-decoration: none; }
    .action-menu {
      inline-size: 2.5rem;
      min-inline-size: 2.5rem;
      padding-inline: .65rem;
      font-weight: 700;
      letter-spacing: .08em;
    }
    .copyable-value {
      display: inline-flex;
      align-items: center;
      gap: .4rem;
      max-inline-size: 100%;
    }
    .copyable-value code { min-inline-size: 0; }
    .copy-button {
      min-block-size: 1.75rem;
      padding: .15rem .4rem;
      flex: none;
      font-size: .75rem;
      opacity: 0;
      visibility: hidden;
      pointer-events: none;
      transition: opacity 120ms ease;
    }
    .copy-button svg {
      display: block;
      inline-size: 1rem;
      block-size: 1rem;
      fill: none;
      stroke: currentColor;
      stroke-linecap: round;
      stroke-linejoin: round;
      stroke-width: 2;
    }
    .copyable-value:hover .copy-button,
    .copyable-value:focus-within .copy-button,
    .copyable-value.has-selection .copy-button {
      opacity: 1;
      visibility: visible;
      pointer-events: auto;
    }
    .primary { color: white; background: var(--accent); border-color: var(--accent); }
    .danger { color: white; background: var(--danger); border-color: var(--danger); }
    .muted { color: var(--muted); }
    .error { color: var(--danger); }
    .status { font-size: .875rem; font-weight: 650; }
    .filter {
      display: grid;
      gap: .35rem;
      inline-size: min(32rem, 100%);
      margin-block-start: 1.5rem;
    }
    .filter label { font-weight: 650; }
    .filter input { inline-size: 100%; }
    .field { display: grid; gap: .35rem; margin-block: 1rem; }
    .field input { inline-size: min(36rem, 100%); }
    dialog {
      inline-size: min(42rem, calc(100% - 2rem));
      color: var(--foreground);
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: .5rem;
    }
    dialog::backdrop { background: hsl(220 20% 10% / .55); }
    dialog form { margin: 0; }
    #manage-session-details {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 1rem 1.5rem;
    }
    .session-detail { min-inline-size: 0; }
    dt { color: var(--muted); }
    dd { margin-inline-start: 0; }
    .empty {
      padding: 2rem;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: .5rem;
    }
    @media (max-width: 45rem) {
      table, tbody, tr, th, td { display: block; }
      thead { position: absolute; inline-size: 1px; block-size: 1px; overflow: hidden; clip-path: inset(50%); }
      tr {
        position: relative;
        padding: .75rem 4rem .75rem .75rem;
        border-block-end: 1px solid var(--border);
      }
      td {
        display: grid;
        grid-template-columns: 5.5rem minmax(0, 1fr);
        gap: .75rem;
        padding: .35rem 0;
        border: 0;
      }
      td::before { content: attr(data-label) ":"; font-weight: 650; }
      td[data-label="Actions"] {
        position: static;
        padding: 0;
      }
      td[data-label="Actions"]::before { content: none; }
      td[data-label="Actions"] .action-menu {
        position: absolute;
        inset-block-start: .75rem;
        inset-inline-end: .75rem;
      }
      td .copyable-value { justify-self: start; }
    }
    @media (max-width: 35rem) {
      #manage-session-details { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>psmux sessions</h1>
        <p class="muted">Long-run version ${html(version)}</p>
      </div>
      <div class="actions">
        <button id="refresh" type="button">Refresh</button>
        <button id="start-session" class="primary" type="button">Start session</button>
      </div>
    </header>
    <form id="session-filter-form" class="filter" role="search">
      <label for="session-filter">Filter sessions</label>
      <input id="session-filter" name="filter" type="search" autocomplete="off" placeholder="Session, path, or command">
    </form>
    <p id="status" class="muted" role="status" aria-live="polite">Loading sessions...</p>
    <h2>Sessions</h2>
    <p id="sessions-empty" class="empty" hidden>No user psmux sessions are running.</p>
    <table hidden>
      <thead><tr>
        ${sortableHeader("Session", "name")}
        ${sortableHeader("Started", "startedAt", "descending")}
        ${sortableHeader("Path", "cwd")}
        ${sortableHeader("Command", "command")}
        <th scope="col" aria-label="Actions"></th>
      </tr></thead>
      <tbody id="session-rows"></tbody>
    </table>
    <h2>Long-run utilities</h2>
    <p id="utilities-empty" class="empty" hidden>No long-run utility sessions are running.</p>
    <table hidden>
      <thead><tr>
        ${sortableHeader("Session", "name")}
        ${sortableHeader("Started", "startedAt", "descending")}
        ${sortableHeader("Path", "cwd")}
        ${sortableHeader("Command", "command")}
        <th scope="col" aria-label="Actions"></th>
      </tr></thead>
      <tbody id="utility-rows"></tbody>
    </table>
    <noscript><p class="error">This session inventory requires JavaScript.</p></noscript>
  </main>
  <dialog id="create-session-dialog" closedby="any" aria-labelledby="create-session-title">
    <form id="create-session-form" method="post" action="/tmux/api/sessions">
      <h2 id="create-session-title">Start session</h2>
      <label class="field">Name
        <input name="name" pattern="(?!\\.{1,2}$)[A-Za-z0-9_.-]+" maxlength="80" autocomplete="off" required>
      </label>
      <label class="field">Working directory
        <input name="cwd" value="${html(defaultWorkingDirectory)}" maxlength="1024" required>
      </label>
      <label class="field">Command (optional)
        <input name="command" maxlength="4096" autocomplete="off" placeholder="Start an interactive shell">
      </label>
      <div class="actions">
        <button class="primary" type="submit">Start session</button>
      </div>
    </form>
  </dialog>
  <dialog id="manage-session-dialog" closedby="any" aria-labelledby="manage-session-title">
    <h2 id="manage-session-title">Manage <code id="manage-session-name"></code></h2>
    <dl id="manage-session-details"></dl>
    <p>The psmux session continues running when its temporary web terminal is stopped.</p>
    <div class="actions">
      <button id="open-terminal" class="primary" type="button">Open web terminal</button>
      <button id="stop-terminal" type="button">Stop web terminal</button>
      <button id="kill-session" class="danger" type="button">Kill psmux session</button>
    </div>
  </dialog>
  <script src="/tmux/assets/app.js" defer></script>
</body>
</html>`;
}

function createGateway(config) {
  const bindHost = config.bindHost || "127.0.0.1";
  const gatewaySession = config.gatewaySession ||
    config.environment?.PSMUX_SESSION ||
    process.env.PSMUX_SESSION ||
    null;
  const terminals = new Map();
  const starting = new Map();
  const serverSockets = new Set();
  const csrfToken = crypto.randomBytes(24).toString("base64url");
  const terminalCapability = config.terminalCapability ||
    crypto.randomBytes(24).toString("base64url");
  const logPath = config.logPath || null;
  let rejectedWebSockets = 0;
  let lastWebSocketRejectionLog = 0;

  function sessionHash(session) {
    return session
      ? crypto.createHash("sha256").update(session).digest("hex").slice(0, 16)
      : null;
  }

  function logEvent(event, details = {}, level = "info") {
    if (!logPath) return;
    const entry = {
      timestamp: new Date().toISOString(),
      level,
      component: "gateway",
      event,
      pid: process.pid,
    };
    for (const [name, value] of Object.entries(details)) {
      if (!/(token|capability|secret|password|command|environment|session)/i.test(name)) {
        entry[name] = value;
      }
    }
    if (details.session) {
      entry.sessionHash = sessionHash(details.session);
    }
    try {
      fs.mkdirSync(path.dirname(logPath), { recursive: true });
      if (fs.existsSync(logPath) && fs.statSync(logPath).size >= 5 * 1024 * 1024) {
        const archive = `${logPath}.1`;
        fs.rmSync(archive, { force: true });
        fs.renameSync(logPath, archive);
      }
      fs.appendFileSync(logPath, `${JSON.stringify(entry)}\n`, "utf8");
    } catch {
      // Diagnostics must never affect gateway behavior.
    }
  }

  function logWebSocketRejection(reason, session) {
    rejectedWebSockets += 1;
    const now = Date.now();
    if (now - lastWebSocketRejectionLog < 10000) return false;
    logEvent("websocket-rejected", {
      reason,
      session,
      rejectionCount: rejectedWebSockets,
    }, "warning");
    rejectedWebSockets = 0;
    lastWebSocketRejectionLog = now;
    return true;
  }

  function terminalUrl(session) {
    return `/tmux/session/${encodeURIComponent(session)}/`;
  }

  function capabilityMatches(value) {
    const actual = Buffer.from(String(value || ""));
    const expected = Buffer.from(terminalCapability);
    return actual.length === expected.length &&
      crypto.timingSafeEqual(actual, expected);
  }

  function hasGatewayCapability(req, url) {
    if (capabilityMatches(url.searchParams.get("accessToken")) ||
        capabilityMatches(req.headers["x-long-run-capability"])) {
      return true;
    }
    return String(req.headers.cookie || "")
      .split(";")
      .map((value) => value.trim())
      .some((value) => {
        const [name, capability] = value.split("=", 2);
        return name === "long_run_gateway" && capabilityMatches(capability);
      });
  }

  function trustedWebSocketOrigin(req) {
    const origin = req.headers.origin;
    if (!origin) {
      return true;
    }
    const forwardedHost = String(req.headers["x-forwarded-host"] || "")
      .split(",")[0]
      .trim();
    const host = forwardedHost || req.headers.host;
    const forwardedProto = String(req.headers["x-forwarded-proto"] || "")
      .split(",")[0]
      .trim();
    const forwardedOriginProtocol = forwardedProto === "wss"
      ? "https"
      : forwardedProto === "ws"
        ? "http"
        : forwardedProto;
    const protocol = forwardedOriginProtocol ||
      (req.socket.encrypted ? "https" : "http");
    if (origin === `${protocol}://${host}`) {
      return true;
    }
    try {
      const metadata = JSON.parse(fs.readFileSync(
        path.join(config.stateDirectory, "gateway.json"),
        "utf8",
      ));
      return Boolean(metadata.url) && origin === new URL(metadata.url).origin;
    } catch (error) {
      if (error.code !== "ENOENT") {
        console.error(`Could not read the gateway public URL: ${error.message}`);
      }
      return false;
    }
  }

  function setGatewayCookie(req, res, url) {
    const secure = String(req.headers["x-forwarded-proto"] || "")
      .split(",")[0]
      .trim() === "https";
    const cleanUrl = new URL(url);
    cleanUrl.searchParams.delete("accessToken");
    res.writeHead(302, {
      Location: `${cleanUrl.pathname}${cleanUrl.search}`,
      "Cache-Control": "no-store",
      "Set-Cookie": `long_run_gateway=${terminalCapability}; Path=/tmux/; HttpOnly; SameSite=Strict${secure ? "; Secure" : ""}`,
    });
    res.end();
  }

  function scheduleTerminalStop(terminal) {
    clearTimeout(terminal.disconnectTimer);
    terminal.disconnectTimer = setTimeout(() => {
      if (terminal.connections.size === 0) {
        stopTerminal(terminal.session, terminal);
      }
    }, (config.terminalDisconnectIdleSeconds || 2) * 1000);
    terminal.disconnectTimer.unref();
  }

  function createTerminalProxy() {
    return createProxyMiddleware({
      target: `http://${bindHost}:1`,
      router(req) {
        return `http://${bindHost}:${req.longRunTerminalPort}`;
      },
      // WebSocket upgrades are dispatched by the gateway's single upgrade
      // handler. Enabling HPM's automatic subscription would leave each
      // per-terminal proxy registered on the server after ttyd exits.
      ws: false,
      changeOrigin: true,
      xfwd: true,
      selfHandleResponse: true,
      logger: {
        info() {},
        warn() {},
        // The explicit proxy error handler below logs a sanitized classification.
        error() {},
      },
      on: {
        proxyRes: responseInterceptor(async (responseBuffer, proxyRes) => {
          if (!String(proxyRes.headers["content-type"] || "").includes("text/html")) {
            return responseBuffer;
          }
          const fontMarkup = config.terminalFontPath
            ? `<link rel="preload" href="/tmux/assets/terminal-font.ttf" as="font" type="font/ttf" crossorigin>
<style>@font-face{font-family:"Long Run Nerd Font";src:url("/tmux/assets/terminal-font.ttf") format("truetype");font-display:block}</style>`
            : "";
          return responseBuffer.toString("utf8").replace(
            "</head>",
            `${fontMarkup}${terminalLifecycleMarkup}</head>`,
          );
        }),
        error(error, req, res) {
          const expectedDisconnect = isExpectedProxyDisconnect(error);
          const errorCode = error?.code || error?.name || "UNKNOWN";
          const session = parseSessionPath(req?.url || "")?.session || null;
          logEvent(
            expectedDisconnect
              ? "terminal-proxy-disconnected"
              : "terminal-proxy-error",
            { session, errorCode },
            expectedDisconnect ? "debug" : "error",
          );
          if (!expectedDisconnect) {
            console.error(`Terminal proxy error (${errorCode}).`);
          }
          if (expectedDisconnect) {
            if (res && typeof res.destroy === "function") {
              res.destroy();
            }
          } else if (res && typeof res.setHeader === "function" && !res.headersSent) {
            sendText(res, 502, "The web terminal proxy failed.");
          } else if (res && typeof res.destroy === "function") {
            res.destroy();
          }
        },
      },
    });
  }
  const terminalProxy = createTerminalProxy();

  async function listSessions() {
    let stdout;
    try {
      ({ stdout } = await runCommand(config.psmux, [
        "list-sessions",
        "-F",
        "#{session_name}|#{session_created}|#{session_attached}|#{session_id}",
      ]));
    } catch (error) {
      if (error.code === 1) {
        return [];
      }
      throw error;
    }
    let paneOutput = "";
    try {
      ({ stdout: paneOutput } = await runCommand(config.psmux, [
        "list-panes",
        "-a",
        "-F",
        "#{session_name}|#{pane_current_path}|#{pane_current_command}|#{pane_pid}|#{pane_width}|#{pane_height}|#{history_size}|#{history_limit}|#{pane_dead}|#{pane_dead_status}",
      ]));
    } catch (error) {
      if (error.code !== 1) throw error;
    }
    const panes = new Map();
    for (const line of paneOutput.split(/\r?\n/).filter(Boolean)) {
      const [
        name,
        cwd,
        command,
        pid,
        width,
        height,
        historySize,
        historyLimit,
        dead,
        deadStatus,
      ] = line.split("|");
      if (!panes.has(name)) {
        const paneDead = dead === "1";
        panes.set(name, {
          cwd: cwd || null,
          command: command || null,
          panePid: asInteger(pid),
          paneWidth: asInteger(width),
          paneHeight: asInteger(height),
          historySize: asInteger(historySize),
          historyLimit: asInteger(historyLimit),
          paneDead,
          paneExitStatus: paneDead ? asInteger(deadStatus) : null,
        });
      }
    }
    return stdout
      .split(/\r?\n/)
      .filter(Boolean)
      .map((line) => {
        const [name, created, attached, id] = line.split("|");
        const pane = panes.get(name) || {};
        const encoded = encodeURIComponent(name);
        return {
          name,
          id: id || null,
          startedAt: asDate(created)?.toISOString() || null,
          attachedClients: Number(attached) || 0,
          webTerminalActive: terminals.has(name),
          utility: name.startsWith("long-run-util-"),
          killable: name !== gatewaySession,
          cwd: pane.cwd || null,
          command: pane.command || null,
          panePid: pane.panePid ?? null,
          paneWidth: pane.paneWidth ?? null,
          paneHeight: pane.paneHeight ?? null,
          historySize: pane.historySize ?? null,
          historyLimit: pane.historyLimit ?? null,
          paneDead: pane.paneDead ?? null,
          paneExitStatus: pane.paneExitStatus ?? null,
          links: {
            self: `/tmux/api/sessions/${encoded}`,
            terminalApi: `/tmux/api/sessions/${encoded}/terminal`,
            terminal: terminalUrl(name),
          },
        };
      });
  }

  async function getSession(session) {
    return (await listSessions()).find((item) => item.name === session) || null;
  }

  async function hasSession(session) {
    try {
      await runCommand(config.psmux, ["has-session", "-t", session]);
      return true;
    } catch (error) {
      if (error.code === 1) {
        return false;
      }
      throw error;
    }
  }

  function stopTerminal(session, expectedTerminal = null) {
    const terminal = terminals.get(session);
    if (!terminal || (expectedTerminal && terminal !== expectedTerminal)) {
      return false;
    }
    if (terminal.stopping) {
      return true;
    }
    terminal.stopping = true;
    logEvent("terminal-stop-requested", { session, terminalPid: terminal.process.pid });
    clearTimeout(terminal.startupTimer);
    clearTimeout(terminal.disconnectTimer);
    if (terminal.process.exitCode === null) {
      terminal.process.kill();
    } else {
      terminal.finishExit();
    }
    return true;
  }

  async function startTerminal(session) {
    if (!(await hasSession(session))) {
      const error = new Error(`The psmux session '${session}' does not exist.`);
      error.statusCode = 404;
      throw error;
    }
    const port = await getFreePort(bindHost);
    const basePath = `/tmux/session/${session}`;
    const logPath = path.join(config.stateDirectory, "terminals");
    fs.mkdirSync(logPath, { recursive: true });
    const stdoutFd = fs.openSync(path.join(logPath, `${session}.out.log`), "a");
    const stderrFd = fs.openSync(path.join(logPath, `${session}.err.log`), "a");
    const child = spawnCommand(config.ttyd, [
      "-W",
      "-t",
      "disableLeaveAlert=true",
      "-t",
      `fontFamily=${config.terminalFontFamily || terminalFontFamily}`,
      "-i",
      bindHost,
      "-p",
      String(port),
      "-b",
      basePath,
      commandSpec(config.psmux).file,
      ...(commandSpec(config.psmux).args || []),
      "attach-session",
      "-t",
      session,
    ], {
      env: psmuxAttachEnvironment(config.environment || process.env),
      stdio: ["ignore", stdoutFd, stderrFd],
    });
    fs.closeSync(stdoutFd);
    fs.closeSync(stderrFd);
    logEvent("terminal-starting", {
      session,
      terminalPid: child.pid,
      port,
      terminalLogDirectory: logPath,
    });

    const terminal = {
      session,
      port,
      process: child,
      connections: new Set(),
      lastUsedAt: new Date(),
      startupTimer: null,
      disconnectTimer: null,
      stopping: false,
      exitPromise: null,
      finishExit: null,
    };
    terminal.exitPromise = new Promise((resolve) => {
      terminal.finishExit = resolve;
    });
    terminals.set(session, terminal);
    child.once("exit", (code, signal) => {
      clearTimeout(terminal.startupTimer);
      clearTimeout(terminal.disconnectTimer);
      if (terminals.get(session) === terminal) {
        terminals.delete(session);
      }
      logEvent("terminal-exited", { session, exitCode: code, signal });
      terminal.finishExit();
    });
    child.once("error", (error) => {
      if (terminals.get(session) === terminal) {
        terminals.delete(session);
      }
      logEvent("terminal-error", {
        session,
        errorType: error.name,
        errorCode: error.code || null,
      }, "error");
    });

    try {
      await waitForPort(bindHost, port, child, config.ttydStartupTimeoutMs || 10000);
    } catch (error) {
      stopTerminal(session);
      throw error;
    }

    terminal.startupTimer = setTimeout(() => {
      if (terminal.connections.size === 0) {
        stopTerminal(session, terminal);
      }
    }, (config.terminalStartupIdleSeconds || 120) * 1000);
    terminal.startupTimer.unref();
    return terminal;
  }

  async function ensureTerminal(session) {
    if (starting.has(session)) {
      return starting.get(session);
    }
    const existing = terminals.get(session);
    if (existing) {
      if (existing.stopping) {
        await existing.exitPromise;
      } else if (existing.process.exitCode === null) {
        existing.lastUsedAt = new Date();
        return existing;
      }
    }
    if (!starting.has(session)) {
      const promise = startTerminal(session).finally(() => starting.delete(session));
      starting.set(session, promise);
    }
    return starting.get(session);
  }

  function requireCsrf(req) {
    if (req.headers["x-long-run-csrf"] !== csrfToken) {
      const error = new Error("The management request was rejected.");
      error.statusCode = 403;
      throw error;
    }
  }

  function decodeSession(value) {
    let session;
    try {
      session = decodeURIComponent(value);
    } catch {
      session = "";
    }
    if (!isValidSessionName(session)) {
      const error = new Error("Invalid session name.");
      error.statusCode = 400;
      throw error;
    }
    return session;
  }

  async function createSession(body) {
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      const error = new Error("The request body must be a JSON object.");
      error.statusCode = 400;
      throw error;
    }
    const requestedName = String(body.name || "").trim();
    const cwd = String(body.cwd || config.defaultWorkingDirectory || "").trim();
    const command = String(body.command || "").trim();
    if (!requestedName) {
      const error = new Error("A session name is required.");
      error.statusCode = 400;
      throw error;
    }
    if (requestedName.length > 80 || !isValidSessionName(requestedName)) {
      const error = new Error("Session names may contain only letters, numbers, dots, underscores, and dashes, and may not be '.' or '..'.");
      error.statusCode = 400;
      throw error;
    }
    if (!cwd || cwd.length > 1024) {
      const error = new Error("A valid working directory is required.");
      error.statusCode = 400;
      throw error;
    }
    let directory;
    try {
      directory = fs.statSync(cwd);
    } catch {
      directory = null;
    }
    if (!directory?.isDirectory()) {
      const error = new Error(`The working directory '${cwd}' does not exist.`);
      error.statusCode = 400;
      throw error;
    }
    if (command.length > 4096 || command.includes("\0")) {
      const error = new Error("The command is invalid or too long.");
      error.statusCode = 400;
      throw error;
    }
    const existing = await listSessions();
    const name = requestedName;
    if (existing.some((session) => session.name === name)) {
      const error = new Error(`The psmux session '${name}' already exists.`);
      error.statusCode = 409;
      throw error;
    }

    const shell = commandSpec(config.shell);
    const shellName = path.basename(shell.file, path.extname(shell.file)).toLowerCase();
    const shellArgs = [...(shell.args || [])];
    if (shellName === "cmd") {
      shellArgs.push("/d", "/k");
      if (command) shellArgs.push(command);
    } else {
      shellArgs.push("-NoLogo", "-NoExit");
      if (command) shellArgs.push("-Command", command);
    }
    try {
      await runCommand(config.psmux, [
        "new-session",
        "-d",
        "-s",
        name,
        "-c",
        cwd,
        "--",
        shell.file,
        ...shellArgs,
      ], {
        env: withoutPsmuxSessionEnvironment(config.environment || process.env),
      });
    } catch (error) {
      if (error.code === 1) {
        const conflict = new Error(`The psmux session '${name}' already exists.`);
        conflict.statusCode = 409;
        throw conflict;
      }
      throw error;
    }
    for (let attempt = 0; attempt < 20; attempt++) {
      const created = await getSession(name);
      if (created) {
        logEvent("session-created", { session: name, sessionId: created.id });
        return created;
      }
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error(`The psmux session '${name}' was created but could not be read.`);
  }

  async function handleApi(req, res, url) {
    if (url.pathname === "/tmux/api/sessions") {
      if (req.method === "GET" || req.method === "HEAD") {
        sendJson(res, 200, { sessions: await listSessions() });
        return true;
      }
      if (req.method === "POST") {
        requireCsrf(req);
        const session = await createSession(await readJson(req));
        sendJson(res, 201, session, { Location: session.links.self });
        return true;
      }
      sendJson(res, 405, { error: "Method not allowed." }, {
        Allow: "GET, HEAD, POST",
      });
      return true;
    }
    const match = /^\/tmux\/api\/sessions\/([^/]+)(\/terminal)?$/.exec(url.pathname);
    if (!match) return false;
    const session = decodeSession(match[1]);
    if (match[2]) {
      if (!["POST", "DELETE"].includes(req.method)) {
        sendJson(res, 405, { error: "Method not allowed." }, {
          Allow: "POST, DELETE",
        });
        return true;
      }
      requireCsrf(req);
      if (!(await hasSession(session))) {
        const error = new Error(`The psmux session '${session}' does not exist.`);
        error.statusCode = 404;
        throw error;
      }
      if (req.method === "POST") {
        await ensureTerminal(session);
        sendJson(res, 200, {
          url: terminalUrl(session),
        });
        return true;
      }
      stopTerminal(session);
      res.writeHead(204, { "Cache-Control": "no-store" });
      res.end();
      return true;
    }
    if (req.method === "GET" || req.method === "HEAD") {
      const item = await getSession(session);
      if (!item) {
        sendJson(res, 404, { error: `The psmux session '${session}' does not exist.` });
      } else {
        sendJson(res, 200, item);
      }
      return true;
    }
    if (req.method === "DELETE") {
      requireCsrf(req);
      if (session === gatewaySession) {
        const error = new Error("The gateway cannot kill its own psmux session.");
        error.statusCode = 409;
        throw error;
      }
      const expectedId = url.searchParams.get("sessionId");
      if (!expectedId) {
        const error = new Error("The session ID is required.");
        error.statusCode = 428;
        throw error;
      }
      const current = await getSession(session);
      if (!current) {
        const error = new Error(`The psmux session '${session}' does not exist.`);
        error.statusCode = 404;
        throw error;
      }
      if (current.id !== expectedId) {
        const error = new Error(
          `The psmux session '${session}' was replaced; refresh before retrying.`,
        );
        error.statusCode = 409;
        throw error;
      }
      stopTerminal(session);
      try {
        await runCommand(config.psmux, ["kill-session", "-t", current.id]);
      } catch (error) {
        if (error.code !== 1) throw error;
      }
      logEvent("session-killed", { session, sessionId: current.id });
      res.writeHead(204, { "Cache-Control": "no-store" });
      res.end();
      return true;
    }
    sendJson(res, 405, { error: "Method not allowed." }, {
      Allow: "GET, HEAD, DELETE",
    });
    return true;
  }

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
      if (url.pathname === "/healthz") {
        if (!hasGatewayCapability(req, url)) {
          sendText(res, 403, "A valid gateway capability is required.");
          return;
        }
        res.writeHead(200, {
          "Content-Type": "application/json; charset=utf-8",
          "Cache-Control": "no-store",
        });
        res.end(JSON.stringify({ status: "ok", terminals: terminals.size }));
        return;
      }
      if (url.pathname === "/") {
        redirect(res, "/tmux/");
        return;
      }
      if (url.pathname === "/tmux" || url.pathname.startsWith("/tmux/")) {
        if (!hasGatewayCapability(req, url)) {
          sendText(res, 403, "A valid gateway capability is required.");
          return;
        }
        if (url.searchParams.has("accessToken")) {
          setGatewayCookie(req, res, url);
          return;
        }
      }
      if (url.pathname === "/tmux/assets/logo.svg") {
        res.writeHead(200, {
          "Content-Type": "image/svg+xml; charset=utf-8",
          "Cache-Control": "private, max-age=3600",
          "X-Content-Type-Options": "nosniff",
        });
        res.end(logo);
        return;
      }
      if (url.pathname === "/tmux/assets/app.js") {
        sendFile(res, path.join(__dirname, "app.js"), "text/javascript; charset=utf-8");
        return;
      }
      if (url.pathname === "/tmux/assets/terminal-font.ttf") {
        if (!config.terminalFontPath) {
          sendText(res, 404, "No terminal web font is configured.");
          return;
        }
        sendFile(res, config.terminalFontPath, "font/ttf");
        return;
      }
      if (await handleApi(req, res, url)) {
        return;
      }
      if (url.pathname === "/tmux" || url.pathname === "/tmux/") {
        if (req.method !== "GET" && req.method !== "HEAD") {
          sendText(res, 405, "Method not allowed.");
          return;
        }
        sendHtml(res, 200, page(
          config.defaultWorkingDirectory || process.cwd(),
          csrfToken,
          config.version || "unknown",
        ));
        return;
      }
      const route = parseSessionPath(url.pathname);
      if (!route) {
        sendText(res, 404, "Not found.");
        return;
      }
      if (route.suffix === "") {
        redirect(
          res,
          `/tmux/session/${encodeURIComponent(route.session)}/${url.search}`,
        );
        return;
      }
      const terminal = await ensureTerminal(route.session);
      terminal.lastUsedAt = new Date();
      req.longRunTerminalPort = terminal.port;
      terminalProxy(req, res, (error) => {
        if (error) {
          sendText(res, 502, `The web terminal proxy failed: ${error.message}`);
        }
      });
    } catch (error) {
      if (!error.statusCode || error.statusCode >= 500) {
        console.error(error);
      }
      if (String(req.url || "").startsWith("/tmux/api/")) {
        sendJson(res, error.statusCode || 500, {
          error: error.message || "Internal server error.",
        });
      } else {
        sendText(res, error.statusCode || 500, error.message || "Internal server error.");
      }
    }
  });

  server.on("connection", (socket) => {
    serverSockets.add(socket);
    socket.once("close", () => serverSockets.delete(socket));
  });

  server.on("upgrade", async (req, socket, head) => {
    let terminal = null;
    let clientClosed = false;
    socket.once("close", () => {
      clientClosed = true;
      if (!terminal) {
        return;
      }
      terminal.connections.delete(socket);
      if (terminal.connections.size === 0) {
        scheduleTerminalStop(terminal);
      }
    });
    try {
      const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
      const route = parseSessionPath(url.pathname);
      const rejection = !route
        ? "invalid route"
        : route.suffix === ""
          ? "missing terminal path suffix"
          : !trustedWebSocketOrigin(req)
            ? "untrusted origin"
            : !hasGatewayCapability(req, url)
              ? "missing capability"
              : null;
      if (rejection) {
        if (logWebSocketRejection(rejection, route?.session || null)) {
          console.error(`Rejected WebSocket upgrade: ${rejection}.`);
        }
        socket.write("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n");
        socket.destroy();
        return;
      }
      terminal = await ensureTerminal(route.session);
      terminal.lastUsedAt = new Date();
      if (clientClosed || socket.destroyed) {
        scheduleTerminalStop(terminal);
        return;
      }
      terminal.connections.add(socket);
      logEvent("websocket-accepted", {
        session: route.session,
        connections: terminal.connections.size,
      });
      clearTimeout(terminal.startupTimer);
      clearTimeout(terminal.disconnectTimer);
      req.longRunTerminalPort = terminal.port;
      terminalProxy.upgrade(req, socket, head);
    } catch (error) {
      logEvent("websocket-failed", {
        errorType: error.name,
        errorCode: error.code || null,
      }, "error");
      console.error(`WebSocket upgrade failed: ${error.message}`);
      socket.destroy();
    }
  });

  async function close() {
    if (rejectedWebSockets > 0) {
      logEvent("websocket-rejected", {
        rejectionCount: rejectedWebSockets,
      }, "warning");
      rejectedWebSockets = 0;
    }
    logEvent("stopping", { activeTerminals: terminals.size });
    const exiting = [...terminals.values()].map((terminal) => terminal.exitPromise);
    for (const session of [...terminals.keys()]) {
      stopTerminal(session);
    }
    await Promise.all(exiting);
    for (const socket of serverSockets) {
      socket.destroy();
    }
    await new Promise((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
    });
    logEvent("stopped");
  }

  return {
    server,
    terminals,
    csrfToken,
    terminalCapability,
    close,
    listen() {
      return new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(config.port, bindHost, () => {
          server.off("error", reject);
          logEvent("started", { port: server.address().port });
          resolve(server.address());
        });
      });
    },
  };
}

async function main() {
  const configPath = process.argv[2];
  if (!configPath) {
    throw new Error("Usage: node server.js <config.json>");
  }
  const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  const gateway = createGateway(config);
  const address = await gateway.listen();
  console.log(`Long-run mux gateway listening on http://${address.address}:${address.port}/tmux/`);
  const shutdown = async () => {
    await gateway.close();
    process.exit(0);
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

module.exports = {
  createGateway,
  isExpectedProxyDisconnect,
  parseSessionPath,
  psmuxAttachEnvironment,
  withoutPsmuxSessionEnvironment,
};

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
