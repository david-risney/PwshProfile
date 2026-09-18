---
name: long-run
description: "Run Copilot commands through psmux. Transparently wraps eligible synchronous PowerShell tool calls while preserving cwd, environment, output, cancellation, and exit code. Also starts persistent named interactive shells in the chat cwd and provides a shared authenticated /tmux/ web inventory for Dragon or remotely steerable Copilot sessions. Use when asked to run a long command, open a shell/command prompt for the chat, create a persistent terminal session, or provide remote terminal access."
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
6. Forward terminal input, including `Ctrl+C`, through the attached psmux client.
7. Remove the psmux session, wrapper scripts, environment snapshot, result file,
   and hook-created command file afterward.

psmux supports multiple simultaneous clients. After
`LONG_RUN_VIEWER_DELAY_SECONDS` seconds (10 by default), a watcher checks whether
the session is still running and, on a local Copilot session, opens another
read/write client in the current Windows Terminal window or a new PowerShell
window. Remote sessions instead publish the command's named session through the
shared mux gateway.

## Hook exceptions

The hook leaves the original tool call unchanged when:

- `PSMUX_SESSION` is already set.
- The command invokes `psmux`, `pmux`, or `tmux`.
- The tool requested `mode: "async"` or detached execution.
- The description or command indicates an exact binary/machine-readable stream.
- `COPILOT_PSMUX=0` is set in the environment or command.

Set `COPILOT_PSMUX_EXACT_OUTPUT=1` when an otherwise ordinary-looking command
requires byte-for-byte stdout/stderr behavior.

## Direct usage

```powershell
pwsh -NoProfile -File scripts\Start-LongRun.ps1 `
  -Command 'npm test' `
  -WorkingDirectory 'C:\src\project'
```

Use `-ViewerDelaySeconds` to change the delay or `-NoViewer` to suppress the
second local client. The call is synchronous and exits with the command's code.

## Persistent interactive shell

When the user asks for a new command prompt, persistent shell, or terminal in
the chat's working directory, run `Start-LongRunShell.ps1`. Prefix the tool call
with `COPILOT_PSMUX=0` so the pre-tool hook does not wrap this intentionally
asynchronous psmux operation:

```powershell
$env:COPILOT_PSMUX = '0'
& <skill>\scripts\Start-LongRunShell.ps1 `
  -Session 'shell-descriptive-name' `
  -WorkingDirectory '<chat cwd>'
```

The script:

- creates a detached named psmux session and leaves it running;
- restores the chat tool's complete process environment;
- resolves applications explicitly and starts `pwsh` when available, falling
  back to Windows PowerShell and then `cmd`;
- prints `LONGRUN_SHELL_LOCAL_ATTACH` with the exact local attach command;
- prints `LONGRUN_SHELL_REMOTE_URL` and `LONGRUN_TMUX_URL` when remote access is
  enabled;
- cleans the shell's generated metadata when the user exits the psmux session.

Always repeat the printed local attach command to the user. When a remote URL is
printed, repeat that URL too.

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
