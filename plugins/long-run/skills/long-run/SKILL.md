---
name: long-run
description: "Route synchronous Copilot PowerShell calls transparently through attached psmux sessions, or start persistent named shells in the chat cwd. A shared authenticated dev tunnel provides an on-demand ttyd proxy and inventory for all named psmux sessions. Use when asked to run a long command, open a persistent shell, or provide remote terminal access."
---

# Long Run

The plugin contributes a `preToolUse` hook for the Copilot `powershell` tool.
Eligible synchronous commands are rewritten to:

1. Save the original command verbatim in a temporary `.ps1` file.
2. Start a named psmux session **without `-d`**.
3. Keep Copilot attached to that client until the command exits.
4. Preserve the hook payload's working directory and the caller's complete
   process environment.
5. Return the real child exit code to the PowerShell tool.
6. Forward terminal input and attempt to forward `Ctrl+C` through the attached
   psmux client.
7. Remove the psmux session, wrapper scripts, environment snapshot, result file,
   and hook-created command file afterward.

Command-only sessions disable their psmux status line so terminal chrome is not
included in Copilot's captured tool output. Persistent interactive shells keep
the user's normal psmux status configuration.

psmux 3.3.8 has a known Ctrl+C delivery defect: both a real browser client and
`psmux send-keys C-c` can deliver the key without interrupting the pane process.
Use a psmux build containing the later Ctrl+C fixes before relying on that path.
Command panes install `pipe-pane` before releasing the original command and
stream that complete pane transcript to Copilot. This avoids losing output to
full-screen viewport redraws. The transcript remains a terminal stream with
merged stdout/stderr and ANSI control sequences, so exact-output commands must
remain excluded.

psmux supports multiple simultaneous clients. After
`LONG_RUN_VIEWER_DELAY_SECONDS` seconds (10 by default), a watcher checks whether
the session is still running and, on a local Copilot session, opens another
read/write client in the current Windows Terminal window or a new PowerShell
window. Remote sessions instead publish the command's named session through the
shared mux gateway. The hook detects Dragon and remotely steerable Copilot
sessions before rewriting the tool call, reserves the session name, and passes
`-RemoteMode Always` to the wrapper. The wrapper ensures the gateway and prints
`LONGRUN_REMOTE_URL` and `LONGRUN_TMUX_URL` before it starts the synchronous
attached psmux command. A post-tool hook extracts `LONGRUN_REMOTE_URL` and
supplies the exact session link as response context so it is reported to the
user instead of remaining hidden in the tool output.

`scripts\Get-LongRunStatusLine.ps1 -WorkingDirectory <path>` renders the newest
active remote command for that working directory as an OSC-8 `long-run`
hyperlink. Statusline aggregators can prepend that output to their existing
content. The renderer reads the command's existing temporary `session.json`,
requires the recorded owner process and start time to match, rejects unsafe
URLs, and stops producing output when normal command cleanup removes the state.
On Copilot CLI versions that support it, configure
`statusLine.refreshInterval` to periodically rerun the aggregator while a tool
is active; a value of `5` refreshes every five seconds.

## Hook exceptions

The hook leaves the original tool call unchanged when:

- `PSMUX_SESSION` is already set.
- The command invokes `psmux`, `pmux`, or `tmux`.
- The tool requested `mode: "async"` or detached execution.
- The description or command indicates an exact binary/machine-readable stream.
- `COPILOT_PSMUX=0` is set in the environment or command.

Set `COPILOT_PSMUX_EXACT_OUTPUT=1` when an otherwise ordinary-looking command
requires byte-for-byte stdout/stderr behavior.

## Diagnostics

The hook, command and shell launchers, cleanup watchers, gateway launcher, Node
gateway, ttyd lifecycle, and WebSocket acceptance/rejection write redacted JSON
Lines events to:

```text
%LOCALAPPDATA%\long-run\logs\events.jsonl
%LOCALAPPDATA%\long-run\logs\events.gateway-<state-hash>.jsonl
```

Each log rotates to a `.1` archive at 5 MiB. A separate file per gateway state
directory avoids cross-runtime and multi-gateway rotation races. Events record
names, timestamps, component and process identifiers, opaque session hashes,
mode, exit codes, and safe error categories. They do not record session names,
command text, environment values,
capabilities, access tokens, cookies, or passwords. Existing gateway service and
per-terminal stdout/stderr logs remain in the mux gateway state directory; the
structured terminal-start event references only their containing directory.

Inspect recent activity with:

```powershell
Get-Content "$env:LOCALAPPDATA\long-run\logs\events*.jsonl" -Tail 100 |
  ForEach-Object { $_ | ConvertFrom-Json } |
  Sort-Object timestamp |
  Format-Table timestamp, component, event, sessionHash, pid, exitCode
```

Set `LONG_RUN_LOG_PATH` to use a trial-specific PowerShell event file; the
gateway uses the same basename with `.gateway-<state-hash>` inserted before
`.jsonl`. Set it to `0` to disable structured logging.

## Integration tests

The regular Pester suite uses fake processes. Repeat the real dependency tests
with:

```powershell
pwsh -NoProfile -File tests\Invoke-LongRunIntegrationTests.ps1
```

The default `Core` group exercises real psmux command execution, cwd and
environment preservation, exit-code and state cleanup, secondary-client input,
owner-death cleanup, concurrent sessions, and complete 5,000-line transcript
capture. Additional opt-in groups are:

```powershell
# Local gateway -> WebSocket -> ttyd -> psmux -> command stdin
pwsh -NoProfile -File tests\Invoke-LongRunIntegrationTests.ps1 -Group Browser

# Opens a visible terminal tab/window and verifies a second client attaches
pwsh -NoProfile -File tests\Invoke-LongRunIntegrationTests.ps1 -Group UI

# Loads the worktree only with --plugin-dir in an isolated Copilot home
pwsh -NoProfile -File tests\Invoke-LongRunIntegrationTests.ps1 -Group Copilot

# Expected to fail on psmux 3.3.8; use to detect a Ctrl+C dependency fix
pwsh -NoProfile -File tests\Invoke-LongRunIntegrationTests.ps1 `
  -Group KnownLimitations
```

`-Group All` includes the expected-failure probes, so it is not the normal
validation command. Browser tests require `node` and `ttyd`; UI tests visibly
open a local terminal; Copilot tests make real model/tool calls. Every test owns
a unique session name and removes only that session and its temporary state.

## Direct usage

```powershell
pwsh -NoProfile -File <skill>\scripts\Start-LongRun.ps1 `
  -Command 'npm test' `
  -WorkingDirectory 'C:\src\project'
```

Do not run `psmux attach-session` directly from Copilot's non-interactive
shell. Use the provided scripts to open a user-controlled terminal or browser
client; an attaching client intentionally remains connected until detached.

## Security boundaries

- Starting the remote gateway creates a local Node/ttyd service and an
  authenticated Dev Tunnel. Confirm before installing missing dependencies or
  enabling anonymous tunnel access.
- Treat returned terminal URLs as credentials. Share them only with the user
  who requested the session, and stop the gateway when remote access is no
  longer needed.
- The plugin may create and remove only its owned psmux sessions and marked
  state directories. It must not delete unrelated sessions or caller files.

Use `-ViewerDelaySeconds` to change the delay or `-NoViewer` to suppress the
second local client. The call is synchronous and exits with the command's code.

## Persistent interactive shell

When the user asks for a new command prompt, persistent shell, or terminal in
the chat's working directory, decide the launch mode before creating anything:

1. Source `LongRun.Common.ps1` and call `Test-LongRunRemoteSession`.
2. Treat Dragon, `remote_steerable` Copilot sessions, and explicit remote-access
   requests as remote. Treat an ordinary Copilot CLI on the user's machine as
   local.
3. Ensure the mode's dependencies are available. If any are missing, explain
   which commands are needed and get explicit approval before installing them
   with `winget`:
   - Always: `Microsoft.PowerShell` (`pwsh`) and `marlocarlo.psmux`.
   - Remote: `OpenJS.NodeJS.LTS`, `tsl0922.ttyd`, and `Microsoft.devtunnel`.
   - Local: `Microsoft.WindowsTerminal` when `wt.exe` is unavailable.
4. For remote mode, run `devtunnel user show`; if it reports no authenticated
   user, run `devtunnel user login` before starting the shell.

Then run `Start-LongRunShell.ps1`. Prefix the tool call with
`COPILOT_PSMUX=0` so the pre-tool hook does not wrap it:

```powershell
$env:COPILOT_PSMUX = '0'
& <skill>\scripts\Start-LongRunShell.ps1 `
  -Session 'shell-descriptive-name' `
  -WorkingDirectory '<chat cwd>' `
  -RemoteMode Auto
```

Run this PowerShell tool call synchronously. The script itself starts the
persistent shell, cleanup watcher, gateway, and dev tunnel as detached
processes, then returns the connection details.

The script:

- creates a detached named psmux session and leaves it running;
- restores the chat tool's environment except agent/session markers and
  noninteractive or color-suppression overrides (`COPILOT_*`, `DRAGON_*`,
  psmux/tmux markers, `NO_COLOR`, `FORCE_COLOR`, Git askpass/config overrides,
  and related variables), while preserving `PSMUX_CONFIG_FILE` and
  `PSMUX_PICKER_SCRIPT` so user psmux themes and actions still load;
- starts `pwsh` by default, falling back to Windows PowerShell and then `cmd`
  only when necessary;
- opens a new Windows Terminal tab immediately in local mode, falling back to
  a new PowerShell window when Windows Terminal is unavailable;
- prints `LONGRUN_SHELL_LOCAL_ATTACH` with the exact local attach command;
- prints `LONGRUN_SHELL_REMOTE_URL` and `LONGRUN_TMUX_URL` when remote access is
  enabled;
- cleans the shell's generated metadata when the user exits the psmux session.

Use `-NoOpen` only when the user does not want a local terminal opened. Always
repeat the printed local attach command as a fallback. In remote mode, give the
user `LONGRUN_SHELL_REMOTE_URL` as the primary result and
`LONGRUN_TMUX_URL` as the session inventory.

### Shared remote mux gateway

`-RemoteMode Auto` enables remote access when either:

- the current Copilot workspace has a `client_name` beginning with `dragon/` or
  Dragon environment markers are present; or
- the current Copilot workspace has `remote_steerable: true`, which Copilot
  persists when `/remote on`, `--remote`, or the equivalent setting enables
  remote control.

Use `-RemoteMode Always` or `-RemoteMode Never` to override detection.

Remote mode ensures one machine-wide long-run gateway:

- one Node.js reverse proxy bound to `127.0.0.1`;
- one authenticated `devtunnels.ms` tunnel to that proxy;
- one inventory at `https://<tunnel>.devtunnels.ms/tmux/`;
- one session URL per named psmux session at
  `https://<tunnel>.devtunnels.ms/tmux/session/<session>/`.

The inventory is a plain JavaScript client over resource-oriented JSON APIs.
It lists every named psmux session, including its creation time, path, current
command, attached client count, utility status, web-terminal state, pane PID and
dimensions, scrollback usage and limit, and pane dead/exit status. A filter field
matches case-insensitive substrings in the session name, path, or command.
Creation times render as semantic `<time>` elements with relative visible text
and an exact timestamp. Sort buttons in each data column select that column or
toggle its direction. The **Start session** dialog creates a named
interactive shell in a selected CWD and can run an optional initial command.
The Manage dialog opens or stops the temporary web terminal or kills the
underlying psmux session.

Gateway API resources:

- `GET /tmux/api/sessions` lists sessions.
- `GET /tmux/api/sessions/<name>` returns one session.
- `POST /tmux/api/sessions` creates a session from JSON `name`, `cwd`, and
  optional `command` fields.
- `DELETE /tmux/api/sessions/<name>?sessionId=<id>` kills the exact session
  represented by the current inventory entry.
- `POST /tmux/api/sessions/<name>/terminal` starts web-terminal access.
- `DELETE /tmux/api/sessions/<name>/terminal` stops only web-terminal access.

Mutating API calls require the page's same-origin CSRF token.

Opening a session URL starts ttyd on an unused localhost port and reverse
proxies its HTTP and WebSocket traffic. The gateway tracks active WebSocket
clients and stops ttyd shortly after the last client disconnects, while the
psmux session continues. This permits browser navigation and reconnection
without ttyd's single-client reconnect screen. ttyd's leave-page warning is
disabled because navigating away cannot lose the underlying psmux session.
Terminal links contain a gateway-process capability that is exchanged for an
HTTP-only, strict same-site cookie before ttyd content loads. WebSocket upgrades
also reject cross-origin browser requests.
Because the gateway itself runs in psmux, it removes inherited psmux/tmux
session variables from ttyd's environment before ttyd launches a separate
`psmux attach-session` client.
The gateway automatically finds an installed CaskaydiaCove Nerd Font, serves
it to the browser, and requests the registered `CaskaydiaCove NFM` family as a
local fallback. This also provides Nerd Font glyphs to browsers connecting
through a dev tunnel. Override discovery with `-TerminalFontPath` or the CSS
font stack with `-TerminalFontFamily` on the gateway launcher.
The gateway host itself runs from a generated script in a numbered
`long-run-util-gateway-{N}` psmux session. The inventory lists sessions with
the reserved `long-run-util-` prefix separately from user sessions. Run the
launcher with `-Verbose` to see resolved tools, configuration replacement,
session allocation, health checks, and dev tunnel startup.
The inventory displays the gateway package version. Increment the patch
component for every long-run plugin change, keeping `.claude-plugin/plugin.json`,
the marketplace entry, and the gateway `package.json` and lockfile synchronized.
A ttyd instance that never
receives a WebSocket connection is stopped after 120 seconds by default. The
inventory can stop it explicitly at any time. Exiting the interactive shell
kills the psmux session, and any attached ttyd process then exits as well.

Remote mode requires:

```powershell
winget install --id tsl0922.ttyd
winget install --id Microsoft.devtunnel
devtunnel user login
```

It also requires a current supported Node.js release. The first gateway start
installs the locked `http-proxy-middleware` dependency into the gateway's local
application-state directory.

The dev tunnel requires authenticated access by default and is shared by every
long-run session. Do not use `-AllowAnonymous` unless the user explicitly
requests anonymously reachable shells and understands the risk. To stop the
gateway, all temporary ttyd processes, and the dev tunnel:

```powershell
& <skill>\scripts\Stop-LongRunMuxGateway.ps1
```

For a local-only inventory without Copilot or a dev tunnel:

```powershell
$gateway = & <skill>\scripts\Start-LongRunMuxGateway.ps1 `
  -LocalOnly -Port 8787
Start-Process $gateway.Url
```
