"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const {
  createGateway,
  isExpectedProxyDisconnect,
  parseSessionPath,
  psmuxAttachEnvironment,
  withoutPsmuxSessionEnvironment,
} = require("../server");

function writeScript(directory, name, source) {
  const file = path.join(directory, name);
  fs.writeFileSync(file, source, "utf8");
  return file;
}

function authorizedRequest(current, pathname, options = {}) {
  return request(current.port, pathname, {
    ...options,
    headers: {
      cookie: current.cookie,
      ...(options.headers || {}),
    },
  });
}

function request(port, pathname, options = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: "127.0.0.1",
      port,
      path: pathname,
      method: options.method || "GET",
      headers: options.headers,
    }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => resolve({
        status: res.statusCode,
        headers: res.headers,
        body: Buffer.concat(chunks).toString("utf8"),
      }));
    });
    req.on("error", reject);
    req.setTimeout(options.timeoutMs || 2000, () => {
      req.destroy(new Error("Timed out waiting for HTTP response."));
    });
    if (options.body) {
      req.write(options.body);
    }
    req.end();
  });
}

function websocketUpgrade(port, pathname, headers = {}, timeoutMs = 2000) {
  return new Promise((resolve, reject) => {
    const key = crypto.randomBytes(16).toString("base64");
    const socket = net.createConnection({ host: "127.0.0.1", port });
    let response = "";
    const cleanup = () => {
      clearTimeout(timer);
      socket.off("error", onError);
      socket.off("connect", onConnect);
      socket.off("data", onData);
    };
    const onError = (error) => {
      cleanup();
      reject(error);
    };
    const onConnect = () => {
      socket.write([
        `GET ${pathname} HTTP/1.1`,
        "Host: 127.0.0.1",
        "Connection: Upgrade",
        "Upgrade: websocket",
        `Sec-WebSocket-Key: ${key}`,
        "Sec-WebSocket-Version: 13",
        ...Object.entries(headers).map(([name, value]) => `${name}: ${value}`),
        "",
        "",
      ].join("\r\n"));
    };
    const onData = (chunk) => {
      response += chunk.toString("latin1");
      if (response.includes("\r\n\r\n")) {
        cleanup();
        resolve({ socket, response });
      }
    };
    const timer = setTimeout(() => {
      cleanup();
      socket.destroy();
      reject(new Error("Timed out waiting for WebSocket upgrade."));
    }, timeoutMs);
    socket.once("error", onError);
    socket.once("connect", onConnect);
    socket.on("data", onData);
  });
}

function browserWebSocket(port, pathname, label, timeoutMs = 2000) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(`ws://127.0.0.1:${port}${pathname}`, ["tty"]);
    const timer = setTimeout(() => {
      socket.close();
      reject(new Error(`${label} WebSocket timed out.`));
    }, timeoutMs);
    socket.addEventListener("open", () => {
      clearTimeout(timer);
      resolve(socket);
    }, { once: true });
    socket.addEventListener("error", () => {
      clearTimeout(timer);
      reject(new Error(`${label} WebSocket failed to open.`));
    }, { once: true });
  });
}

function closeBrowserWebSocket(socket) {
  return new Promise((resolve) => {
    socket.addEventListener("close", resolve, { once: true });
    socket.addEventListener("error", resolve, { once: true });
    socket.close();
  });
}

function closeRawWebSocket(socket) {
  return new Promise((resolve) => {
    socket.once("close", resolve);
    socket.once("error", resolve);
    socket.write(Buffer.from([0x88, 0x80, 0, 0, 0, 0]));
  });
}

async function waitFor(condition, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (condition()) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  assert.fail("Timed out waiting for condition.");
}

async function fixture(options = {}) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "long-run-gateway-test-"));
  const terminalFontPath = path.join(directory, "terminal-font.ttf");
  fs.writeFileSync(terminalFontPath, "fake-nerd-font");
  const stateFile = path.join(directory, "sessions.json");
  fs.writeFileSync(stateFile, JSON.stringify({
    sessions: [
      { id: "$1", name: "older", created: 1700000000, attached: 0, cwd: "C:\\older", command: "pwsh", pid: 1001, width: 120, height: 30, historySize: 25, historyLimit: 2000, dead: 0, deadStatus: 0 },
      { id: "$2", name: "newer", created: 1800000000, attached: 1, cwd: "C:\\newer", command: "node", pid: 1002, width: 160, height: 40, historySize: 75, historyLimit: 2000, dead: 1, deadStatus: 7 },
      { id: "$3", name: "long-run-util-gateway-1", created: 1900000000, attached: 0, cwd: "C:\\gateway", command: "node", pid: 1003, width: 100, height: 25, historySize: 5, historyLimit: 2000, dead: 0, deadStatus: 0 },
    ],
  }));
  const psmux = writeScript(directory, "fake-psmux.js", `
const fs = require("node:fs");
const path = require("node:path");
const stateFile = process.argv[2];
const args = process.argv.slice(3);
const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
const targetIndex = args.indexOf("-t");
const target = targetIndex >= 0 ? args[targetIndex + 1] : null;
if (args[0] === "list-sessions") {
  for (const session of state.sessions) {
    console.log([session.name, session.created, session.attached, session.id].join("|"));
  }
  process.exit(state.sessions.length ? 0 : 1);
}
if (args[0] === "list-panes") {
  for (const session of state.sessions) {
    console.log([
      session.name,
      session.cwd,
      session.command,
      session.pid,
      session.width,
      session.height,
      session.historySize,
      session.historyLimit,
      session.dead,
      session.deadStatus,
    ].join("|"));
  }
  process.exit(state.sessions.length ? 0 : 1);
}
if (args[0] === "has-session") {
  process.exit(state.sessions.some((session) => session.name === target) ? 0 : 1);
}
if (args[0] === "new-session") {
  const name = args[args.indexOf("-s") + 1];
  const cwd = args[args.indexOf("-c") + 1];
  const separator = args.indexOf("--");
  state.sessions.push({
    id: "$" + (Math.max(0, ...state.sessions.map((session) => Number(session.id.slice(1)))) + 1),
    name,
    cwd,
    command: path.basename(args[separator + 1], path.extname(args[separator + 1])),
    created: Math.floor(Date.now() / 1000),
    attached: 0,
  });
  fs.writeFileSync(
    path.join(path.dirname(stateFile), "session-environment.json"),
    JSON.stringify({
      NO_COLOR: process.env.NO_COLOR || null,
      FORCE_COLOR: process.env.FORCE_COLOR || null,
      COPILOT_CLI: process.env.COPILOT_CLI || null,
      DRAGON_INSTANCE: process.env.DRAGON_INSTANCE || null,
      GIT_TERMINAL_PROMPT: process.env.GIT_TERMINAL_PROMPT || null,
      TERM: process.env.TERM || null,
      COLORTERM: process.env.COLORTERM || null,
    }),
  );
  fs.writeFileSync(stateFile, JSON.stringify(state));
  process.exit(0);
}
if (args[0] === "kill-session") {
  state.sessions = state.sessions.filter(
    (session) => session.name !== target && session.id !== target,
  );
  fs.writeFileSync(stateFile, JSON.stringify(state));
  process.exit(0);
}
process.exit(0);
`);
  const ttyd = writeScript(directory, "fake-ttyd.js", `
const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const args = process.argv.slice(2);
fs.writeFileSync(${JSON.stringify(path.join(directory, "ttyd-args.json"))}, JSON.stringify(args));
fs.writeFileSync(${JSON.stringify(path.join(directory, "ttyd-environment.json"))}, JSON.stringify({
  PSMUX_SESSION: process.env.PSMUX_SESSION || null,
  PSMUX_TARGET_SESSION: process.env.PSMUX_TARGET_SESSION || null,
  PSMUX_CLAUDE_TEAMMATE_MODE: process.env.PSMUX_CLAUDE_TEAMMATE_MODE || null,
  PSMUX_PIPE_VT: process.env.PSMUX_PIPE_VT || null,
  TMUX: process.env.TMUX || null,
  TMUX_PANE: process.env.TMUX_PANE || null,
  NO_COLOR: process.env.NO_COLOR || null,
  FORCE_COLOR: process.env.FORCE_COLOR || null,
  COPILOT_CLI: process.env.COPILOT_CLI || null,
  DRAGON_INSTANCE: process.env.DRAGON_INSTANCE || null,
  GIT_TERMINAL_PROMPT: process.env.GIT_TERMINAL_PROMPT || null,
}));
if (process.env.PSMUX_PIPE_VT) {
  process.exit(73);
}
const port = Number(args[args.indexOf("-p") + 1]);
const basePath = args[args.indexOf("-b") + 1];
const once = args.includes("-o");
let acceptedConnection = false;
const server = http.createServer((req, res) => {
  if (req.url.endsWith("/reset")) {
    req.socket.destroy();
    return;
  }
  res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
  res.end("<!doctype html><html><head></head><body>fake ttyd " + basePath + " " + req.url + "</body></html>");
});
server.on("upgrade", (req, socket) => {
  if (once && acceptedConnection) {
    socket.destroy();
    return;
  }
  acceptedConnection = true;
  const accept = crypto.createHash("sha1")
    .update(req.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    .digest("base64");
  socket.write("HTTP/1.1 101 Switching Protocols\\r\\n" +
    "Upgrade: websocket\\r\\nConnection: Upgrade\\r\\n" +
    (req.headers["sec-websocket-protocol"]
      ? "Sec-WebSocket-Protocol: " + req.headers["sec-websocket-protocol"] + "\\r\\n"
      : "") +
    "Sec-WebSocket-Accept: " + accept + "\\r\\n\\r\\n");
  socket.on("data", (data) => {
    if ((data[0] & 0x0f) === 0x08) {
      socket.write(Buffer.from([0x88, 0x00]));
      socket.end();
    }
  });
});
setTimeout(
  () => server.listen(port, "127.0.0.1"),
  ${Number(options.ttydListenDelayMs || 0)},
);
`);
  const gateway = createGateway({
    bindHost: "127.0.0.1",
    port: 0,
    stateDirectory: directory,
    psmux: { file: process.execPath, args: [psmux, stateFile] },
    ttyd: options.ttyd || { file: process.execPath, args: [ttyd] },
    shell: process.execPath,
    version: "2.4.38",
    defaultWorkingDirectory: directory,
    terminalStartupIdleSeconds: options.terminalStartupIdleSeconds || 10,
    terminalDisconnectIdleSeconds: options.terminalDisconnectIdleSeconds || 0.1,
    ttydStartupTimeoutMs: options.ttydStartupTimeoutMs || 10000,
    terminalFontFamily: '"Long Run Nerd Font", "CaskaydiaCove NFM", Consolas, monospace',
    terminalFontPath,
    terminalCapability: "test-terminal-capability",
    logPath: path.join(directory, "events.jsonl"),
    environment: {
      ...process.env,
      PSMUX_SESSION: "long-run-util-gateway-1",
      PSMUX_TARGET_SESSION: "long-run-util-gateway-1",
      PSMUX_CLAUDE_TEAMMATE_MODE: "tmux",
      PSMUX_PIPE_VT: "1",
      TMUX: "test-tmux",
      TMUX_PANE: "%1",
      NO_COLOR: "1",
      FORCE_COLOR: "false",
      COPILOT_CLI: "1",
      DRAGON_INSTANCE: "test",
      GIT_TERMINAL_PROMPT: "0",
      TERM: "xterm-256color",
      COLORTERM: "truecolor",
    },
  });
  const address = await gateway.listen();
  const authorization = await request(
    address.port,
    `/tmux/?accessToken=${gateway.terminalCapability}`,
  );
  assert.equal(authorization.status, 302);
  const cookie = authorization.headers["set-cookie"][0].split(";")[0];
  return {
    cookie,
    directory,
    gateway,
    port: address.port,
    stateFile,
    async close() {
      await gateway.close();
      fs.rmSync(directory, { recursive: true, force: true });
    },
  };
}

test("parses only safe named-session routes", () => {
  assert.deepEqual(parseSessionPath("/tmux/session/name-1/"), {
    session: "name-1",
    suffix: "/",
  });
  assert.equal(parseSessionPath("/tmux/session/bad%2Fname/"), null);
  assert.equal(parseSessionPath("/tmux/session/./"), null);
  assert.equal(parseSessionPath("/tmux/session/../"), null);
  assert.deepEqual(
    withoutPsmuxSessionEnvironment({
      Path: "C:\\tools",
      PSMUX_SESSION: "gateway",
      pSmUx_TaRgEt_SeSsIoN: "gateway",
      TMUX: "socket",
      TMUX_PANE: "%1",
    }),
    { Path: "C:\\tools" },
  );
});

test("keeps ttyd psmux attach clients in console input mode", () => {
  assert.deepEqual(
    psmuxAttachEnvironment({
      Path: "C:\\tools",
      NO_COLOR: "1",
      PSMUX_PIPE_VT: "stale",
      PSMUX_SESSION: "gateway",
      TERM: "xterm-256color",
    }),
    {
      Path: "C:\\tools",
      TERM: "xterm-256color",
    },
  );
});

test("classifies routine terminal proxy disconnects", () => {
  for (const code of [
    "ECONNABORTED",
    "ECONNRESET",
    "EPIPE",
    "ERR_STREAM_PREMATURE_CLOSE",
  ]) {
    assert.equal(isExpectedProxyDisconnect({ code }), true);
  }
  assert.equal(isExpectedProxyDisconnect({ code: "ECONNREFUSED" }), false);
  assert.equal(isExpectedProxyDisconnect(new Error("unknown")), false);
});

test("times out incomplete WebSocket upgrades", async () => {
  const server = net.createServer();
  const sockets = new Set();
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    await assert.rejects(
      websocketUpgrade(server.address().port, "/", {}, 100),
      /Timed out waiting for WebSocket upgrade/,
    );
  } finally {
    for (const socket of sockets) {
      socket.destroy();
    }
    await new Promise((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
    });
  }
});

test("settles terminal shutdown when ttyd cannot spawn", async () => {
  const current = await fixture({
    ttyd: {
      file: path.join(os.tmpdir(), `missing-ttyd-${crypto.randomUUID()}.exe`),
      args: [],
    },
    ttydStartupTimeoutMs: 200,
  });
  let closed = false;
  try {
    const response = await authorizedRequest(current, "/tmux/session/newer/");
    assert.equal(response.status, 500);
    await Promise.race([
      current.gateway.close(),
      new Promise((resolve, reject) => {
        setTimeout(() => reject(new Error("Gateway close timed out.")), 1000);
      }),
    ]);
    closed = true;
  } finally {
    if (closed) {
      fs.rmSync(current.directory, { recursive: true, force: true });
    } else {
      await current.close();
    }
  }
});

test("writes redacted structured gateway lifecycle events", async () => {
  const current = await fixture();
  let closed = false;
  try {
    const response = await authorizedRequest(current, "/tmux/session/newer/");
    assert.equal(response.status, 200);
    await current.gateway.close();
    closed = true;
    const entries = fs.readFileSync(
      path.join(current.directory, "events.jsonl"),
      "utf8",
    ).trim().split(/\r?\n/).map((line) => JSON.parse(line));
    assert.ok(entries.some((entry) => entry.event === "started"));
    assert.ok(entries.some((entry) => entry.event === "stopped"));
    assert.ok(entries.some((entry) =>
      entry.event === "terminal-starting" && entry.sessionHash));
    const serialized = JSON.stringify(entries);
    assert.doesNotMatch(
      serialized,
      /test-terminal-capability|accessToken|cookie|newer/i,
    );
  } finally {
    if (closed) {
      fs.rmSync(current.directory, { recursive: true, force: true });
    } else {
      await current.close();
    }
  }
});

test("serves a script inventory and session REST resources", async () => {
  const current = await fixture();
  try {
    assert.equal((await request(current.port, "/tmux/")).status, 403);
    const response = await authorizedRequest(current, "/tmux/");
    assert.equal(response.status, 200);
    assert.match(response.body, /psmux sessions/);
    assert.match(response.body, /Long-run version 2\.4\.38/);
    assert.doesNotMatch(response.body, /Opening a session starts/);
    assert.match(response.body, /<h2>Sessions<\/h2>/);
    assert.match(response.body, /<h2>Long-run utilities<\/h2>/);
    assert.doesNotMatch(response.body, /long-run-util-gateway-1|C:\\gateway/);
    assert.match(response.body, /id="start-session"/);
    assert.ok(response.body.includes(
      'pattern="(?!\\.{1,2}$)[A-Za-z0-9_.-]+" maxlength="80" autocomplete="off" required',
    ));
    assert.match(
      response.body,
      /id="create-session-dialog" closedby="any" aria-labelledby="create-session-title"/,
    );
    assert.match(response.body, /src="\/tmux\/assets\/app\.js"/);
    assert.match(response.body, /<link rel="icon" href="\/tmux\/assets\/logo\.svg" type="image\/svg\+xml">/);
    for (const [label, key] of [
      ["Session", "name"],
      ["Started", "startedAt"],
      ["Path", "cwd"],
      ["Command", "command"],
    ]) {
      assert.match(
        response.body,
        new RegExp(`<th scope="col" aria-sort="(?:none|descending)"><button class="sort-link" type="button" data-sort="${key}" data-label="${label}"`),
      );
    }
    assert.match(response.body, /class="sort-indicator" aria-hidden="true"/);
    assert.match(response.body, /\.sort-link \{[^}]*white-space: nowrap;/s);
    assert.match(response.body, /\.sort-link:focus-visible \{[^}]*outline:/s);
    assert.match(response.body, /\.sort-up \{ border-block-end:/);
    assert.match(response.body, /\.sort-down \{ border-block-start:/);
    assert.match(response.body, /<th scope="col" aria-label="Actions"><\/th>/);
    assert.match(response.body, /<form id="session-filter-form" class="filter" role="search">/);
    assert.match(response.body, /<label for="session-filter">Filter sessions<\/label>/);
    assert.match(response.body, /<input id="session-filter" name="filter" type="search" autocomplete="off" placeholder="Session, path, or command">/);
    assert.doesNotMatch(response.body, /data-sort="(?:attachedClients|webTerminalActive|actions)"/);
    assert.match(response.body, /id="manage-session-dialog" closedby="any" aria-labelledby="manage-session-title"/);
    assert.doesNotMatch(response.body, /data-close-dialog|>Cancel<|>Close</);
    assert.match(response.body, /#manage-session-details \{[^}]*grid-template-columns: repeat\(2, minmax\(0, 1fr\)\)/s);
    assert.match(response.body, /td \{[^}]*grid-template-columns: 5\.5rem minmax\(0, 1fr\)/s);
    assert.match(response.body, /td\[data-label="Actions"\] \{[^}]*position: static;[^}]*padding: 0;/s);
    assert.match(response.body, /td\[data-label="Actions"\] \.action-menu \{[^}]*position: absolute;[^}]*inset-block-start: \.75rem;[^}]*inset-inline-end: \.75rem;/s);
    assert.match(
      response.headers["content-security-policy"],
      /connect-src 'self'; script-src 'self'/,
    );
    const app = await authorizedRequest(current, "/tmux/assets/app.js");
    assert.equal(app.status, 200);
    assert.match(app.body, /\/tmux\/api\/sessions/);
    for (const key of [
      "name",
      "startedAt",
      "cwd",
      "command",
    ]) {
      assert.match(app.body, new RegExp(`\\b${key}: \\(`));
    }
    assert.doesNotMatch(app.body, /\b(?:attachedClients|webTerminalActive|actions): \(/);
    assert.match(app.body, /manage\.textContent = "\.\.\.";/);
    assert.match(app.body, /manage\.setAttribute\("aria-label", `Manage session \$\{session\.name\}`\)/);
    assert.match(app.body, /function copyableValue\(value, label\)/);
    assert.match(app.body, /navigator\.clipboard\.writeText\(value\)/);
    assert.match(app.body, /const copyIconMarkup = `\s*<svg viewBox="0 0 24 24" aria-hidden="true">/);
    assert.match(app.body, /button\.innerHTML = copyIconMarkup;/);
    assert.match(app.body, /document\.addEventListener\("selectionchange"/);
    assert.match(app.body, /cell\("Path", copyableValue\(session\.cwd, "working directory"\)\)/);
    assert.match(app.body, /cell\("Command", copyableValue\(session\.command, "command"\)\)/);
    assert.match(app.body, /killSession\.hidden = session\.killable === false/);
    assert.match(app.body, /target\.searchParams\.set\("sessionId", selectedSession\.id\)/);
    assert.match(app.body, /function filteredSessions\(\)/);
    assert.match(app.body, /\[session\.name, session\.cwd, session\.command\]/);
    assert.match(app.body, /\.toLocaleLowerCase\(\)\.includes\(query\)/);
    assert.match(app.body, /filterInput\.addEventListener\("input", render\)/);
    assert.match(app.body, /Showing \$\{visibleSessions\.length\} of \$\{sessions\.length\} sessions\./);
    assert.match(app.body, /\["Status", session\.webTerminalActive \? "Web terminal active" : "Starts on demand"\]/);
    assert.match(app.body, /if \(!\("closedBy" in HTMLDialogElement\.prototype\)\)/);
    assert.match(app.body, /for \(const dialog of \[createDialog, manageDialog\]\)/);
    assert.match(app.body, /function nextSessionName\(\)/);
    assert.match(app.body, /createForm\.elements\.name\.value = nextSessionName\(\)/);
    assert.match(app.body, /button\.dataset\.direction = active \? sortDirection : "none"/);
    assert.match(app.body, /Sort by \$\{label\} \$\{nextDirection\}/);
    assert.match(app.body, /const refreshIntervalMilliseconds = 60_000;/);
    assert.match(app.body, /if \(sessionLoad\) \{\s+return sessionLoad;/);
    assert.match(app.body, /setTimeout\(async \(\) => \{\s+await loadSessions\(\{ showLoading: false \}\);/);
    assert.match(app.body, /document\.addEventListener\("visibilitychange"/);
    assert.match(app.body, /if \(document\.hidden\) \{\s+clearTimeout\(autoRefreshTimer\);/);
    const icon = await authorizedRequest(current, "/tmux/assets/logo.svg");
    assert.equal(icon.status, 200);
    assert.match(icon.headers["content-type"], /^image\/svg\+xml/);

    assert.equal(
      (await request(current.port, "/tmux/api/sessions")).status,
      403,
    );
    const apiResponse = await authorizedRequest(current, "/tmux/api/sessions");
    assert.equal(apiResponse.status, 200);
    const payload = JSON.parse(apiResponse.body);
    assert.equal(payload.sessions.length, 3);
    assert.deepEqual(
      payload.sessions.find((session) => session.name === "newer"),
      {
        id: "$2",
        name: "newer",
        startedAt: new Date(1800000000 * 1000).toISOString(),
        attachedClients: 1,
        webTerminalActive: false,
        utility: false,
        killable: true,
        cwd: "C:\\newer",
        command: "node",
        panePid: 1002,
        paneWidth: 160,
        paneHeight: 40,
        historySize: 75,
        historyLimit: 2000,
        paneDead: true,
        paneExitStatus: 7,
        links: {
          self: "/tmux/api/sessions/newer",
          terminalApi: "/tmux/api/sessions/newer/terminal",
          terminal: "/tmux/session/newer/",
        },
      },
    );
    assert.equal(
      payload.sessions.find((session) => session.name === "long-run-util-gateway-1").utility,
      true,
    );
    assert.equal(
      payload.sessions.find((session) => session.name === "long-run-util-gateway-1").killable,
      false,
    );
    const connectionListenerCount =
      current.gateway.server.listenerCount("connection");
    assert.equal((await request(current.port, "/healthz")).status, 403);
    for (let index = 0; index < 12; index++) {
      assert.equal(
        (await authorizedRequest(current, "/healthz")).status,
        200,
      );
    }
    assert.equal(
      current.gateway.server.listenerCount("connection"),
      connectionListenerCount,
    );
  } finally {
    await current.close();
  }
});

test("recreates ttyd after disconnect and allows later session visits", async () => {
  const current = await fixture();
  try {
    const denied = await request(current.port, "/tmux/session/newer/");
    assert.equal(denied.status, 403);
    const normalized = await request(
      current.port,
      `/tmux/session/newer?accessToken=${current.gateway.terminalCapability}`,
    );
    assert.equal(normalized.status, 302);
    assert.equal(normalized.headers.location, "/tmux/session/newer");
    assert.doesNotMatch(normalized.headers.location, /accessToken/);
    const granted = await request(
      current.port,
      `/tmux/session/newer/?accessToken=${current.gateway.terminalCapability}`,
    );
    assert.equal(granted.status, 302);
    const cookie = granted.headers["set-cookie"][0].split(";")[0];
    const first = await request(current.port, "/tmux/session/newer/", {
      headers: { cookie },
    });

    assert.equal(first.status, 200);
    assert.match(first.body, /fake ttyd \/tmux\/session\/newer/);
    assert.match(first.body, /font-family:"Long Run Nerd Font"/);
    assert.match(first.body, /href="\/tmux\/assets\/terminal-font\.ttf"/);
    assert.match(first.body, /id = "long-run-session-closed"/);
    assert.match(first.body, /Back to sessions/);
    assert.match(first.body, /\/tmux\/api\/sessions\//);
    assert.equal(current.gateway.terminals.size, 1);
    const proxyCloseListenerCount =
      current.gateway.server.listenerCount("close");
    const ttydArgs = JSON.parse(fs.readFileSync(
      path.join(current.directory, "ttyd-args.json"),
      "utf8",
    ));
    assert.deepEqual(
      ttydArgs.slice(ttydArgs.indexOf("-t"), ttydArgs.indexOf("-t") + 2),
      ["-t", "disableLeaveAlert=true"],
    );
    const fontOption = ttydArgs.indexOf('fontFamily="Long Run Nerd Font", "CaskaydiaCove NFM", Consolas, monospace');
    assert.ok(fontOption > 0);
    assert.equal(ttydArgs[fontOption - 1], "-t");
    assert.deepEqual(
      JSON.parse(fs.readFileSync(
        path.join(current.directory, "ttyd-environment.json"),
        "utf8",
      )),
      {
        PSMUX_SESSION: null,
        PSMUX_TARGET_SESSION: null,
        PSMUX_CLAUDE_TEAMMATE_MODE: null,
        PSMUX_PIPE_VT: null,
        TMUX: null,
        TMUX_PANE: null,
        NO_COLOR: null,
        FORCE_COLOR: null,
        COPILOT_CLI: null,
        DRAGON_INSTANCE: null,
        GIT_TERMINAL_PROMPT: null,
      },
    );
    const font = await authorizedRequest(
      current,
      "/tmux/assets/terminal-font.ttf",
    );
    assert.equal(font.status, 200);
    assert.equal(font.body, "fake-nerd-font");

    const second = await request(current.port, "/tmux/session/newer/token", {
      headers: { cookie },
    });
    assert.equal(second.status, 200);
    assert.equal(current.gateway.terminals.size, 1);

    const rejectedOrigin = await websocketUpgrade(
      current.port,
      `/tmux/session/newer/ws?accessToken=${current.gateway.terminalCapability}`,
      { Origin: "https://attacker.example" },
    );
    assert.match(rejectedOrigin.response, /^HTTP\/1\.1 403/);
    rejectedOrigin.socket.destroy();

    const terminalCountBeforeMissingCapability = current.gateway.terminals.size;
    const rejectedMissingCapability = await websocketUpgrade(
      current.port,
      "/tmux/session/newer/ws",
      { Origin: `http://127.0.0.1:${current.port}` },
    );
    assert.match(rejectedMissingCapability.response, /^HTTP\/1\.1 403/);
    rejectedMissingCapability.socket.destroy();
    assert.equal(
      current.gateway.terminals.size,
      terminalCountBeforeMissingCapability,
    );

    fs.writeFileSync(
      path.join(current.directory, "gateway.json"),
      JSON.stringify({ url: "https://example.devtunnels.ms" }),
    );
    const rejectedTunnelOrigin = await websocketUpgrade(
      current.port,
      `/tmux/session/newer/ws?accessToken=${current.gateway.terminalCapability}`,
      {
        Origin: "https://attacker.devtunnels.ms",
        "X-Forwarded-Host": `127.0.0.1:${current.port}`,
        "X-Forwarded-Proto": "https",
      },
    );
    assert.match(rejectedTunnelOrigin.response, /^HTTP\/1\.1 403/);
    rejectedTunnelOrigin.socket.destroy();

    const tunneledUpgrade = await websocketUpgrade(
      current.port,
      `/tmux/session/newer/ws?accessToken=${current.gateway.terminalCapability}`,
      {
        Origin: "https://example.devtunnels.ms",
        "X-Forwarded-Host": `127.0.0.1:${current.port}`,
        "X-Forwarded-Proto": "https",
      },
    );
    assert.match(tunneledUpgrade.response, /^HTTP\/1\.1 101/);
    await closeRawWebSocket(tunneledUpgrade.socket);
    await waitFor(() => current.gateway.terminals.size === 0);

    const upgraded = await browserWebSocket(
      current.port,
      `/tmux/session/newer/ws?accessToken=${current.gateway.terminalCapability}`,
      "first",
    );
    const firstPid = current.gateway.terminals.get("newer").process.pid;
    await closeBrowserWebSocket(upgraded);
    await waitFor(() => current.gateway.terminals.size === 0);

    const revisited = await request(current.port, "/tmux/session/newer/", {
      headers: { cookie },
    });
    assert.equal(revisited.status, 200);
    const secondPid = current.gateway.terminals.get("newer").process.pid;
    assert.notEqual(secondPid, firstPid);
    await new Promise((resolve) => setTimeout(resolve, 200));
    assert.equal(current.gateway.terminals.get("newer").process.exitCode, null);
    const reconnected = await browserWebSocket(
      current.port,
      `/tmux/session/newer/ws?accessToken=${current.gateway.terminalCapability}`,
      "second",
    );
    await closeBrowserWebSocket(reconnected);
    await waitFor(() => current.gateway.terminals.size === 0);
    assert.equal(
      current.gateway.server.listenerCount("close"),
      proxyCloseListenerCount,
    );
  } finally {
    await current.close();
  }
});

test("records reset terminal proxies without raw errors or format placeholders", async () => {
  const current = await fixture();
  const errors = [];
  const originalConsoleError = console.error;
  console.error = (...args) => errors.push(args);
  try {
    await assert.rejects(
      authorizedRequest(current, "/tmux/session/newer/reset"),
    );
    await waitFor(() => {
      const log = fs.readFileSync(
        path.join(current.directory, "events.jsonl"),
        "utf8",
      );
      return log.includes('"event":"terminal-proxy-disconnected"');
    });
    assert.equal(errors.length, 0);
    const log = fs.readFileSync(
      path.join(current.directory, "events.jsonl"),
      "utf8",
    );
    assert.doesNotMatch(log, /ECONNRESET.*at TCP|%s|newer/);
    assert.match(log, /"errorCode":"ECONNRESET"/);
  } finally {
    console.error = originalConsoleError;
    await current.close();
  }
});

test("deduplicates requests while ttyd is still starting", async () => {
  const current = await fixture({ ttydListenDelayMs: 500 });
  try {
    const first = authorizedRequest(current, "/tmux/session/newer/");
    await new Promise((resolve) => setTimeout(resolve, 100));
    const second = authorizedRequest(current, "/tmux/session/newer/");
    const responses = await Promise.all([first, second]);

    assert.deepEqual(responses.map((response) => response.status), [200, 200]);
    assert.equal(current.gateway.terminals.size, 1);
  } finally {
    await current.close();
  }
});

test("REST mutations require CSRF and keep terminal cleanup separate", async () => {
  const current = await fixture();
  try {
    const rejected = await authorizedRequest(
      current,
      "/tmux/api/sessions/older/terminal",
      {
      method: "POST",
      },
    );
    assert.equal(rejected.status, 403);
    assert.equal(current.gateway.terminals.size, 0);

    const started = await authorizedRequest(
      current,
      "/tmux/api/sessions/older/terminal",
      {
      method: "POST",
      headers: { "x-long-run-csrf": current.gateway.csrfToken },
      },
    );
    assert.equal(started.status, 200);
    assert.equal(
      JSON.parse(started.body).url,
      "/tmux/session/older/",
    );
    assert.equal(current.gateway.terminals.size, 1);

    const created = await authorizedRequest(current, "/tmux/api/sessions", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-long-run-csrf": current.gateway.csrfToken,
      },
      body: JSON.stringify({
        name: "created",
        cwd: current.directory,
        command: "npm test",
      }),
    });
    assert.equal(created.status, 201);
    assert.equal(created.headers.location, "/tmux/api/sessions/created");
    const createdSession = JSON.parse(created.body);
    assert.equal(createdSession.cwd, current.directory);
    assert.equal(createdSession.command, "node");
    assert.deepEqual(
      JSON.parse(fs.readFileSync(
        path.join(current.directory, "session-environment.json"),
        "utf8",
      )),
      {
        NO_COLOR: null,
        FORCE_COLOR: null,
        COPILOT_CLI: null,
        DRAGON_INSTANCE: null,
        GIT_TERMINAL_PROMPT: null,
        TERM: "xterm-256color",
        COLORTERM: "truecolor",
      },
    );

    const missingName = await authorizedRequest(current, "/tmux/api/sessions", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-long-run-csrf": current.gateway.csrfToken,
      },
      body: JSON.stringify({ cwd: current.directory }),
    });
    assert.equal(missingName.status, 400);

    const dotSegment = await authorizedRequest(current, "/tmux/api/sessions", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-long-run-csrf": current.gateway.csrfToken,
      },
      body: JSON.stringify({ name: "..", cwd: current.directory }),
    });
    assert.equal(dotSegment.status, 400);

    const stopped = await authorizedRequest(current, "/tmux/api/sessions/older/terminal", {
      method: "DELETE",
      headers: { "x-long-run-csrf": current.gateway.csrfToken },
    });
    assert.equal(stopped.status, 204);
    await waitFor(() => current.gateway.terminals.size === 0);
    assert.match(fs.readFileSync(current.stateFile, "utf8"), /older/);

    const missingPrecondition = await authorizedRequest(current, "/tmux/api/sessions/older", {
      method: "DELETE",
      headers: { "x-long-run-csrf": current.gateway.csrfToken },
    });
    assert.equal(missingPrecondition.status, 428);

    const stale = await authorizedRequest(
      current,
      "/tmux/api/sessions/older?sessionId=%2499",
      {
        method: "DELETE",
        headers: { "x-long-run-csrf": current.gateway.csrfToken },
      },
    );
    assert.equal(stale.status, 409);

    const selfKill = await authorizedRequest(
      current,
      "/tmux/api/sessions/long-run-util-gateway-1?sessionId=%243",
      {
        method: "DELETE",
        headers: { "x-long-run-csrf": current.gateway.csrfToken },
      },
    );
    assert.equal(selfKill.status, 409);

    const killed = await authorizedRequest(
      current,
      "/tmux/api/sessions/older?sessionId=%241",
      {
      method: "DELETE",
      headers: { "x-long-run-csrf": current.gateway.csrfToken },
      },
    );
    assert.equal(killed.status, 204);
    assert.doesNotMatch(fs.readFileSync(current.stateFile, "utf8"), /older/);
  } finally {
    await current.close();
  }
});
