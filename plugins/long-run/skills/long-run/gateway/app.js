"use strict";

const csrfToken = document.querySelector('meta[name="csrf-token"]').content;
const status = document.querySelector("#status");
const filterForm = document.querySelector("#session-filter-form");
const filterInput = document.querySelector("#session-filter");
const createDialog = document.querySelector("#create-session-dialog");
const createForm = document.querySelector("#create-session-form");
const manageDialog = document.querySelector("#manage-session-dialog");
const manageName = document.querySelector("#manage-session-name");
const manageDetails = document.querySelector("#manage-session-details");
const openTerminal = document.querySelector("#open-terminal");
const stopTerminal = document.querySelector("#stop-terminal");
const killSession = document.querySelector("#kill-session");
const killDialog = document.querySelector("#kill-session-dialog");
const killName = document.querySelector("#kill-session-name");
const killError = document.querySelector("#kill-session-error");
const cancelKill = document.querySelector("#cancel-kill-session");
const confirmKill = document.querySelector("#confirm-kill-session");
const refreshIntervalMilliseconds = 60_000;
const dateFormatter = new Intl.DateTimeFormat(undefined, {
  dateStyle: "medium",
  timeStyle: "long",
});
const relativeFormatter = new Intl.RelativeTimeFormat(undefined, {
  numeric: "auto",
});
let sessions = [];
let selectedSession = null;
let sortColumn = "startedAt";
let sortDirection = "desc";
let autoRefreshTimer = null;
let sessionLoad = null;
const textCollator = new Intl.Collator(undefined, {
  numeric: true,
  sensitivity: "base",
});
const sortComparators = {
  name: (left, right) => textCollator.compare(left.name, right.name),
  startedAt: (left, right) =>
    (Date.parse(left.completedAt || left.startedAt) || 0) -
      (Date.parse(right.completedAt || right.startedAt) || 0),
  cwd: (left, right) => textCollator.compare(left.cwd || "", right.cwd || ""),
  command: (left, right) =>
    textCollator.compare(left.command || "", right.command || ""),
};
const copyIconMarkup = `
  <svg viewBox="0 0 24 24" aria-hidden="true">
    <rect x="9" y="9" width="11" height="11" rx="2"></rect>
    <path d="M15 9V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h3"></path>
  </svg>`;

function setStatus(message, isError = false) {
  status.textContent = message;
  status.classList.toggle("error", isError);
}

function nextSessionName() {
  const names = new Set(sessions.map((session) => session.name));
  for (let number = 1; ; number++) {
    const candidate = `shell-${number}`;
    if (!names.has(candidate)) {
      return candidate;
    }
  }
}

async function api(path, options = {}) {
  const headers = new Headers(options.headers);
  const signal = options.signal || AbortSignal.timeout(30_000);
  if (options.body) {
    headers.set("Content-Type", "application/json");
  }
  if (options.method && !["GET", "HEAD"].includes(options.method)) {
    headers.set("X-Long-Run-CSRF", csrfToken);
  }
  const response = await fetch(path, {
    cache: "no-store",
    ...options,
    headers,
    signal,
  });
  if (!response.ok) {
    const payload = await response.json().catch(() => null);
    throw new Error(payload?.error || `Request failed (${response.status}).`);
  }
  return response.status === 204 ? null : response.json();
}

function relativeTime(date) {
  const elapsedSeconds = Math.round((date.getTime() - Date.now()) / 1000);
  const ranges = [
    ["year", 365 * 24 * 60 * 60],
    ["month", 30 * 24 * 60 * 60],
    ["week", 7 * 24 * 60 * 60],
    ["day", 24 * 60 * 60],
    ["hour", 60 * 60],
    ["minute", 60],
  ];
  for (const [unit, seconds] of ranges) {
    if (Math.abs(elapsedSeconds) >= seconds) {
      return relativeFormatter.format(Math.round(elapsedSeconds / seconds), unit);
    }
  }
  return "just now";
}

function sessionTime(value) {
  if (!value) {
    const unknown = document.createElement("span");
    unknown.className = "muted";
    unknown.textContent = "Unknown";
    return unknown;
  }
  const date = new Date(value);
  const time = document.createElement("time");
  time.dateTime = value;
  time.title = dateFormatter.format(date);
  time.textContent = relativeTime(date);
  return time;
}

function cell(label, content) {
  const td = document.createElement("td");
  td.dataset.label = label;
  if (content instanceof Node) {
    td.append(content);
  } else {
    td.textContent = content;
  }
  return td;
}

function copyableValue(value, label) {
  const container = document.createElement("span");
  container.className = "copyable-value";
  const code = document.createElement("code");
  code.textContent = value || "Unknown";
  container.append(code);
  if (!value) {
    return container;
  }
  const button = document.createElement("button");
  button.type = "button";
  button.className = "copy-button";
  button.innerHTML = copyIconMarkup;
  button.setAttribute("aria-label", `Copy ${label}`);
  button.title = `Copy ${label}`;
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(value);
      button.textContent = "✓";
      setTimeout(() => {
        button.innerHTML = copyIconMarkup;
      }, 1500);
    } catch (error) {
      setStatus(`Could not copy ${label}: ${error.message}`, true);
    }
  });
  container.append(button);
  return container;
}

function showManage(session) {
  selectedSession = session;
  manageName.textContent = session.name;
  manageDetails.replaceChildren();
  const paneSize = Number.isInteger(session.paneWidth) &&
      Number.isInteger(session.paneHeight)
    ? `${session.paneWidth} x ${session.paneHeight}`
    : "Unknown";
  const scrollback = Number.isInteger(session.historySize) &&
      Number.isInteger(session.historyLimit)
    ? `${session.historySize} / ${session.historyLimit} lines`
    : "Unknown";
  const paneState = session.completed
    ? `Completed${Number.isInteger(session.exitCode)
        ? ` (exit code ${session.exitCode})`
        : ""}`
    : session.paneDead === true
    ? `Exited${Number.isInteger(session.paneExitStatus)
        ? ` (code ${session.paneExitStatus})`
        : ""}`
    : session.paneDead === false
      ? "Running"
      : "Unknown";
  for (const [label, value] of [
    ["Working directory", session.cwd || "Unknown"],
    ["Command", session.command || "Unknown"],
    ["PID", Number.isInteger(session.panePid) ? String(session.panePid) : "Unknown"],
    ["Pane size", paneSize],
    ["Scrollback", scrollback],
    ["Pane state", paneState],
    ...(session.completed
      ? [["Retained until", session.expiresAt
        ? dateFormatter.format(new Date(session.expiresAt))
        : "Unknown"]]
      : []),
    ["Attached clients", String(session.attachedClients)],
    ["Status", session.webTerminalActive
      ? "Web terminal active"
      : session.completed
        ? "Read-only output available"
        : "Starts on demand"],
  ]) {
    const detail = document.createElement("div");
    detail.className = "session-detail";
    const dt = document.createElement("dt");
    dt.textContent = label;
    const dd = document.createElement("dd");
    dd.append(
      label === "Working directory" || label === "Command" || label === "PID"
        ? copyableValue(value === "Unknown" ? null : value, label.toLowerCase())
        : document.createTextNode(value),
    );
    detail.append(dt, dd);
    manageDetails.append(detail);
  }
  stopTerminal.hidden = !session.webTerminalActive;
  killSession.hidden = session.killable === false;
  openTerminal.textContent = session.completed
    ? "View retained output"
    : "Open terminal";
  manageDialog.showModal();
}

function sessionRow(session) {
  const row = document.createElement("tr");
  const link = document.createElement("a");
  link.href = session.links.terminal;
  const code = document.createElement("code");
  code.textContent = session.name;
  link.append(code);
  if (session.completed) {
    const retained = document.createElement("span");
    retained.className = "muted";
    retained.textContent = Number.isInteger(session.exitCode)
      ? ` Completed (${session.exitCode})`
      : " Completed";
    link.append(retained);
  }

  const manage = document.createElement("button");
  manage.type = "button";
  manage.className = "action-menu";
  manage.textContent = "...";
  manage.title = `Manage ${session.name}`;
  manage.setAttribute("aria-label", `Manage session ${session.name}`);
  manage.addEventListener("click", () => showManage(session));

  row.append(
    cell("Session", link),
    cell(
      session.completed ? "Completed" : "Started",
      sessionTime(session.completedAt || session.startedAt),
    ),
    cell("Path", copyableValue(session.cwd, "working directory")),
    cell("Command", copyableValue(session.command, "command")),
    cell("Actions", manage),
  );
  return row;
}

function sorted(items) {
  return [...items].sort((left, right) => {
    const compare = sortComparators[sortColumn] || sortComparators.name;
    const result = compare(left, right) ||
      sortComparators.name(left, right);
    return sortDirection === "asc" ? result : -result;
  });
}

function renderTable(bodyId, emptyId, items, defaultEmptyMessage, filteredEmptyMessage) {
  const body = document.querySelector(`#${bodyId}`);
  const empty = document.querySelector(`#${emptyId}`);
  body.replaceChildren(...sorted(items).map(sessionRow));
  empty.textContent = filterInput.value.trim()
    ? filteredEmptyMessage
    : defaultEmptyMessage;
  empty.hidden = items.length !== 0;
  body.closest("table").hidden = items.length === 0;
}

function filteredSessions() {
  const query = filterInput.value.trim().toLocaleLowerCase();
  if (!query) {
    return sessions;
  }
  return sessions.filter((session) =>
    [session.name, session.cwd, session.command].some((value) =>
      String(value || "").toLocaleLowerCase().includes(query)
    )
  );
}

function render() {
  const visibleSessions = filteredSessions();
  renderTable(
    "session-rows",
    "sessions-empty",
    visibleSessions.filter((session) => !session.utility && !session.completed),
    "No user psmux sessions are running.",
    "No user sessions match the filter.",
  );
  renderTable(
    "completed-session-rows",
    "completed-sessions-empty",
    visibleSessions.filter((session) => !session.utility && session.completed),
    "No completed command output is retained.",
    "No completed sessions match the filter.",
  );
  renderTable(
    "utility-rows",
    "utilities-empty",
    visibleSessions.filter((session) => session.utility),
    "No long-run utility sessions are running.",
    "No long-run utility sessions match the filter.",
  );
  setStatus(filterInput.value.trim()
    ? `Showing ${visibleSessions.length} of ${sessions.length} sessions.`
    : `Showing ${sessions.length} session${sessions.length === 1 ? "" : "s"}.`);
  for (const button of document.querySelectorAll("[data-sort]")) {
    const active = button.dataset.sort === sortColumn;
    const th = button.closest("th");
    th.setAttribute("aria-sort", active
      ? (sortDirection === "asc" ? "ascending" : "descending")
      : "none");
    button.dataset.direction = active ? sortDirection : "none";
    const label = button.dataset.label;
    const nextDirection = active && sortDirection === "asc"
      ? "descending"
      : "ascending";
    button.setAttribute("aria-label", `Sort by ${label} ${nextDirection}`);
  }
}

async function loadSessions({ showLoading = true } = {}) {
  if (sessionLoad) {
    return sessionLoad;
  }
  if (showLoading) {
    setStatus("Loading sessions...");
  }
  sessionLoad = (async () => {
    try {
      const payload = await api("/tmux/api/sessions");
      sessions = payload.sessions;
      render();
    } catch (error) {
      setStatus(error.message, true);
    } finally {
      sessionLoad = null;
    }
  })();
  return sessionLoad;
}

function scheduleAutoRefresh() {
  clearTimeout(autoRefreshTimer);
  if (document.hidden) {
    return;
  }
  autoRefreshTimer = setTimeout(async () => {
    await loadSessions({ showLoading: false });
    scheduleAutoRefresh();
  }, refreshIntervalMilliseconds);
}

async function refreshSessions(options) {
  clearTimeout(autoRefreshTimer);
  await loadSessions(options);
  scheduleAutoRefresh();
}

document.querySelector("#refresh").addEventListener("click", () => refreshSessions());
filterForm.addEventListener("submit", (event) => event.preventDefault());
filterInput.addEventListener("input", render);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    clearTimeout(autoRefreshTimer);
  } else {
    refreshSessions({ showLoading: false });
  }
});
document.querySelector("#start-session").addEventListener("click", () => {
  createForm.elements.name.value = nextSessionName();
  createDialog.showModal();
  createForm.elements.name.select();
});
document.addEventListener("selectionchange", () => {
  const selection = document.getSelection();
  for (const container of document.querySelectorAll(".copyable-value")) {
    const selectedInside = selection &&
      !selection.isCollapsed &&
      container.contains(selection.anchorNode) &&
      container.contains(selection.focusNode);
    container.classList.toggle("has-selection", Boolean(selectedInside));
  }
});
if (!("closedBy" in HTMLDialogElement.prototype)) {
  for (const dialog of [createDialog, manageDialog]) {
    dialog.addEventListener("click", (event) => {
      if (event.target !== dialog) {
        return;
      }
      const rect = dialog.getBoundingClientRect();
      const insideDialog =
        event.clientX >= rect.left &&
        event.clientX <= rect.right &&
        event.clientY >= rect.top &&
        event.clientY <= rect.bottom;
      if (!insideDialog) {
        dialog.close();
      }
    });
  }
}
for (const button of document.querySelectorAll("[data-sort]")) {
  button.addEventListener("click", () => {
    const column = button.dataset.sort;
    if (sortColumn === column) {
      sortDirection = sortDirection === "asc" ? "desc" : "asc";
    } else {
      sortColumn = column;
      sortDirection = "asc";
    }
    render();
  });
}

createForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const data = new FormData(createForm);
  setStatus("Starting session...");
  try {
    const created = await api("/tmux/api/sessions", {
      method: "POST",
      body: JSON.stringify({
        name: data.get("name"),
        cwd: data.get("cwd"),
        command: data.get("command"),
      }),
    });
    createDialog.close();
    createForm.elements.command.value = "";
    await loadSessions();
    showManage(created);
  } catch (error) {
    setStatus(error.message, true);
  }
});

stopTerminal.addEventListener("click", async () => {
  if (!selectedSession) return;
  try {
    await api(selectedSession.links.terminalApi, { method: "DELETE" });
    manageDialog.close();
    await loadSessions();
  } catch (error) {
    setStatus(error.message, true);
  }
});

openTerminal.addEventListener("click", async () => {
  if (!selectedSession) return;
  try {
    const terminal = await api(selectedSession.links.terminalApi, {
      method: "POST",
    });
    window.location.assign(terminal.url);
  } catch (error) {
    setStatus(error.message, true);
  }
});

killSession.addEventListener("click", () => {
  if (!selectedSession) return;
  if (!selectedSession.id) {
    setStatus("This session cannot be killed because psmux did not report its identity.", true);
    return;
  }
  killName.textContent = selectedSession.name;
  killError.textContent = "";
  killError.hidden = true;
  killDialog.showModal();
});

cancelKill.addEventListener("click", () => killDialog.close());

confirmKill.addEventListener("click", async () => {
  if (!selectedSession?.id) {
    killDialog.close();
    return;
  }
  const originalLabel = confirmKill.textContent;
  confirmKill.disabled = true;
  cancelKill.disabled = true;
  confirmKill.textContent = "Killing...";
  try {
    const target = new URL(selectedSession.links.self, window.location.origin);
    target.searchParams.set("sessionId", selectedSession.id);
    await api(`${target.pathname}${target.search}`, { method: "DELETE" });
    killDialog.close();
    manageDialog.close();
    await loadSessions();
  } catch (error) {
    killError.textContent = error.message;
    killError.hidden = false;
  } finally {
    confirmKill.disabled = false;
    cancelKill.disabled = false;
    confirmKill.textContent = originalLabel;
  }
});

refreshSessions();
