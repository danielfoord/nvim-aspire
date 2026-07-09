# nvim-aspire — Execution Plan

## Context

`intial.md` specs a new Neovim plugin, `nvim-aspire`, that treats a VS Code `.vscode/launch.json` entry of `"type": "aspire"` as a first-class launch target. VS Code's Aspire extension generates that config and handles orchestration/debugging itself; Neovim + nvim-dap has no equivalent, so nothing currently lets a Neovim user launch a .NET Aspire AppHost and attach debuggers the way VS Code does. Repo is currently empty (only `intial.md`, no git yet).

Goal: build a real plugin, starting from a working `:AspireLaunch` (parse config → find AppHost → run it → show log buffer → surface dashboard URL), then layer `:AspireStop`/`:AspireDashboard`/`:AspireResources`, then DAP attach. Per the spec's explicit design principle: **don't make nvim-dap understand Aspire directly** — get orchestration solid first, debugging is a separate later layer on top.

## Repo scaffolding

Standard Neovim plugin layout:
```
nvim-aspire/
├── lua/aspire/
│   ├── init.lua        -- setup(), command registration entrypoint
│   ├── launch_json.lua -- JSONC parse + config lookup (pure, testable)
│   ├── variables.lua   -- ${workspaceFolder} etc. resolution (pure, testable)
│   ├── discovery.lua   -- AppHost project discovery heuristics (pure, testable)
│   ├── launch_profiles.lua -- launchSettings.json profile selection (pure, testable)
│   ├── runner.lua      -- process lifecycle: start/stop, log buffer, dashboard URL detection
│   ├── dashboard.lua   -- :AspireDashboard, :AspireResources
│   ├── dap.lua          -- child .NET process discovery + nvim-dap attach (see DAP section below)
│   ├── health.lua       -- :checkhealth aspire — dotnet/netcoredbg/nvim-dap presence
│   └── ui.lua           -- vim.ui.select wrappers, log buffer/window management
├── plugin/aspire.lua    -- thin bootstrap, only if needed beyond init.lua's nvim_create_user_command calls
├── doc/aspire.txt        -- minimal vimdoc help
├── tests/
│   ├── minimal_init.lua
│   └── aspire/*_spec.lua -- plenary busted-style specs for the pure modules
├── README.md
└── LICENSE
```
No luarocks/rockspec needed for v1 — lazy.nvim/packer both work off the plain `lua/`+`plugin/` layout with zero extra packaging. Init as a git repo (`git init`) before first commit — ask user before doing so since it's a new-state action.

## Module design

**`launch_json.lua`**
- `parse(path) -> table|nil, err` — reads file, strips `//` line comments and `/* */` block comments outside of string literals (a small char-scanning stripper, not a blind regex — must not eat `//` inside a string value like a URL), strips trailing commas before `}`/`]`, then `vim.json.decode`.
- `find_aspire_config(decoded, opts) -> config|nil` — filters `configurations` for `type == "aspire"` and `request == "launch"`; if multiple, use `opts.name` to match `name` field, else prompt via `vim.ui.select`.

**`variables.lua`**
- `resolve(str, ctx) -> string` — substitutes `${workspaceFolder}` (root passed in `ctx`), leave others as stretch (`${workspaceFolderBasename}` trivial to add later). Keep this a single small function, not a generic templating engine.

**`discovery.lua`**
- `find_apphost(root, hint) -> path|nil, candidates` — if the launch config's `program` already resolves to a `.csproj`, use it directly; if it resolves to a folder, scan for `*.csproj` under it (prefer name ending in `.AppHost.csproj` or path containing `.AppHost`), else scan project for any `.csproj` referencing `Aspire.Hosting` (grep the file). Multiple candidates → `vim.ui.select`.

**`launch_profiles.lua`**
- `load(apphost_dir) -> table|nil` — reads `Properties/launchSettings.json` next to the AppHost csproj (same JSONC handling as launch_json.lua — reuse the stripper).
- `pick_profile(profiles, opts) -> name, profile` — default to first profile whose `commandName == "Project"`, or exact match on `opts.profile` name if given.
- `to_env(profile) -> table` — maps `environmentVariables` + `applicationUrl` (as `ASPNETCORE_URLS`) into an env table for the job.

**`runner.lua`**
- `run(apphost_path, profile_env)` — uses `vim.system({"dotnet","run","--project",apphost_path}, {cwd=..., env=profile_env, stdout=on_output, stderr=on_output})` (Neovim 0.10+ `vim.system`, not `jobstart` — simpler API, structured stdout/stderr callbacks, handle returned has `:wait()`/`.pid`, no need for the old jobstart callback dance). Store the handle in module state (`M.job`).
- Output streamed into a dedicated scratch buffer (`filetype=aspirelog`), appended via `vim.schedule` from the callback to stay main-loop-safe.
- Dashboard URL detected by pattern-matching each output line against something like `https?://[^%s]+/login%?t=[^%s]+` (Aspire prints a login URL with token) — store first match in `M.dashboard_url`, `vim.notify` it once found.
- `stop()` — Aspire's `dotnet run` spawns a multi-level child process tree (confirmed empirically: `dotnet run` → `AppHost` binary → further child `dotnet` process). **Deviation from the original design**: a process-group kill (`kill -TERM -<pid>`) was tried and confirmed non-viable — `vim.system` doesn't put children in their own process group, they inherit Neovim's, so a negative-pid signal targets the wrong group entirely. Implemented instead as a recursive descendant walk (`pgrep -P` repeated per pid) collecting every descendant, then `vim.uv.kill()` on each pid individually (children first, root last). Self-contained in `runner.lua`; not shared with `dap.lua`'s later single-`ps`-call tree walk (different concern — that one also needs process metadata for the attach UI, not just pids).

**`dashboard.lua`**
- `open()` — `vim.ui.open(M.dashboard_url)` (built-in in 0.10+, falls back to `open`/`xdg-open` shell otherwise) if a URL was captured, else notify "not launched yet".
- `resources()` — v1: stub that notifies "not yet implemented, see dashboard" — Aspire's resource-state HTTP API isn't stable/documented enough to build against confidently for a v1; mark as a follow-up once a real Aspire sample app is available to inspect actual dashboard traffic.

## DAP integration design

Once `:AspireLaunch` has an AppHost running, the user needs to attach a debugger to individual .NET services the AppHost spawns — mirroring VS Code's Aspire extension, which auto-attaches per-service. `dap.lua` only starts once `runner.lua` has a live AppHost job with a known pid; it's a layer bolted on top of orchestration, not baked into the launch flow.

**Discovery strategy**: originally planned as an OS process-tree walk from the AppHost's pid (via `ps` — no auth needed, unlike Aspire's dashboard/DCP resource API). **Deviation, confirmed empirically**: this doesn't work. Aspire's DCP layer daemonizes when orchestrating child processes — `dcp start-apiserver` reparents to pid 1 and is only linked to the AppHost via a `--monitor <pid>` command-line argument, not real OS parentage. Verified against a live AppHost: the orchestrator binary had **zero** real OS-level children (`awk '$2==<apphost_pid>'` over a full `ps` snapshot returned nothing), even though the actual service processes were running several logical levels below it. A pid-tree walk (`build_tree`, built in milestone 9) can never reach them.

Fixed by filtering on build-output **path** instead of OS parentage: every compiled .NET binary (service or AppHost) sits at `.../<ProjectDir>/bin/<Config>/net<ver>/<Name>`, and we already know the workspace root and the AppHost's own project directory (to exclude it) from the launch pipeline. This sidesteps the broken tree entirely — no pid walk needed for service discovery. `build_tree`/`parse_ps_output` remain valid, tested utilities (still potentially useful elsewhere) but aren't part of this path. Limitation: only plain `Project` resources under the workspace are attachable this way — containerized resources (Redis, Postgres, etc.) aren't visible to a path-based host scan and are out of scope for v1.

**Windows support, added post-v1** (a user reported `:AspireAttach` failing with "no attachable processes found" on Windows — `ps`/`lsof` don't exist there): `list_processes()` now dispatches on `vim.fn.has("win32")` to a PowerShell `Get-CimInstance Win32_Process` query instead, emitting `pid|ppid|command` lines parsed by the new `parse_powershell_output`. The compiled-binary path pattern (`BIN_OUTPUT_PATTERN`) and `filter_services`'s prefix comparison were made separator-agnostic (`[/\\]` character class, plus a `normalize_sep` helper that maps `\`→`/` before comparing) so the same `filter_services` works unchanged for both `/`-style and `\`-style paths — covered by a Windows-shaped fixture (backslashes, `.exe` extensions, no leading slash) alongside the existing macOS-captured one. `resolve_name` was also rewritten from an impure per-pid `lsof`/`/proc` cwd lookup (macOS/Linux only) into a **pure** function that derives the project name directly from the already-known command path (the text before `/bin/<Config>/net<ver>/<Name>`) — simpler, faster (no extra shell-out per service), fully cross-platform, and unit-testable. Not yet fixed for Windows: `runner.stop()`'s descendant kill still shells out to `pgrep -P`, which doesn't exist on Windows — the root AppHost process will still be signalled via `vim.uv.kill` (libuv is cross-platform), but orphaned child services won't be discovered/killed there. Flagged as a known follow-up, out of scope for the reported issue.

**Windows fix round 2** (user reported the same "no attachable processes found" message even after the round-1 fix above — no Windows machine available to reproduce directly, so both of these are reasoned fixes from re-reading the implementation, not confirmed against real hardware):
1. The PowerShell invocation used an inline `-Command "Get-CimInstance ... | ForEach-Object { \"$($_.ProcessId)|...\" }"` string containing nested double quotes and `$()` subexpressions as a single argv element — fragile across Unix-argv-to-Windows-command-line translation (Windows programs receive one command-line string, not a real argv array, and quoting rules differ from Unix). Switched to writing the script to a temp `.ps1` file and invoking `-File <path> -ExecutionPolicy Bypass` instead — a bare file path is a far simpler thing to quote correctly, and `-ExecutionPolicy Bypass` keeps the same "runs regardless of policy" behavior an inline `-Command` string has (script files are otherwise subject to execution policy).
2. Failures in the Windows process listing were silently swallowed into an empty list, indistinguishable from "genuinely zero services running" — added `vim.notify` on both a failed shell-out and a non-zero exit code (including stderr) so a real failure is now visible instead of masquerading as the generic "no attachable processes found".
3. Separately spotted: `filter_services`'s workspace-root/apphost-dir prefix comparison was case-sensitive plain string matching, but Windows paths are case-insensitive and different APIs can report the same path with different casing (e.g. drive letter case). Added an explicit `case_insensitive` option (defaulted to `vim.fn.has("win32") == 1` at the `list_services` call site, not hardcoded inside `filter_services` itself, so the pure function stays platform-independent and testable by passing the flag directly) — covered by fixtures proving both the match-despite-case-mismatch and case-sensitive-by-default-elsewhere behavior.
4. `health.lua` now also checks `powershell` is on PATH, Windows-only.

**`dap.lua`**
- `parse_ps_output(raw) -> {pid, ppid, command}[]` — pure function parsing `ps -Ao pid,ppid,command` text (macOS/Linux). Testable with fixture text, no shell-out.
- `parse_powershell_output(raw) -> {pid, ppid, command}[]` — pure function parsing `pid|ppid|command` lines from the Windows PowerShell listing. Testable, handles CRLF line endings.
- `build_tree(entries, root_pid) -> pid[]` — pure function, recursively collects descendant pids of `root_pid`. Testable, but not used by `list_services` (see Discovery strategy above) — kept as a validated general-purpose utility.
- `filter_services(entries, workspace_root, apphost_dir) -> entries[]` — pure function, filters parsed process entries to those matching the compiled-binary path pattern under `workspace_root`, excluding anything under `apphost_dir` (the AppHost's own binary). Separator-agnostic. Testable — covered with fixtures captured verbatim from a live Aspire app's process listing (macOS) plus an equivalent Windows-shaped fixture.
- `resolve_name(command) -> string` — pure function, derives a display name from the compiled-binary command path (basename of the project directory containing `bin/<Config>/net<ver>/`). Testable, no shell-out.
- `list_services(workspace_root, apphost_dir) -> {name, pid, cmd}[]` — lists processes via the platform-appropriate mechanism, runs the result through `parse_ps_output`/`parse_powershell_output` + `filter_services` + `resolve_name`.
- `attach(pid, opts)` — builds `{type="coreclr", request="attach", processId=pid, name=opts.name, justMyCode=false}` and calls `require("dap").run(cfg)`. Before attaching: check `pcall(require, "dap")` succeeds and `vim.fn.executable("netcoredbg") == 1`; notify with a clear error naming the missing piece. Don't overwrite `require("dap").adapters.coreclr` if the user already configured one (e.g. via mason-nvim-dap) — only set a default (mirroring mason-nvim-dap's `coreclr.lua`: `{type="executable", command=vim.fn.exepath("netcoredbg"), args={"--interpreter=vscode"}}`) if unset.
- `pick_and_attach()` — `list_services()` → `vim.ui.select` by name → `attach()`. Backs `:AspireAttach`.
- `attach_all()` — `list_services()` → `attach()` on every entry, no prompt. nvim-dap supports multiple concurrent sessions.

**`health.lua`**: `:checkhealth aspire` reports `dotnet` executable presence (required for `:AspireLaunch`), `netcoredbg` presence (warning not error if missing — orchestration works without it), and whether `nvim-dap` is loadable.

**Commands added**: `:AspireAttach` (pick one service, attach), `:AspireAttachAll` (attach to every discovered service). Both live in `init.lua`, delegate to `dap.lua`.

**Known limitations** (document in README/help): container-backed resources aren't attachable; `:AspireStop`'s descendant kill doesn't discover child processes on Windows (see Windows support note above — the root AppHost process is still signalled); `:AspireStop` while a DAP session is attached leaves that session pointing at a dead process — nvim-dap handles a disconnected adapter reasonably but this isn't actively cleaned up in v1.

**Apple Silicon caveat, confirmed during milestone 11 verification**: `netcoredbg` doesn't ship a native macOS arm64 build — mason's registry maps `darwin_arm64` to the same x86_64 asset as `darwin_x64`, running under Rosetta 2. A Rosetta-translated x86_64 debugger cannot attach to a native arm64 .NET process on macOS (the attach handshake fails at the `configurationDone` step with a generic CLR HRESULT, confirmed via nvim-dap's own protocol trace — not fixable via codesigning/entitlements, which were verified correct and made no difference). This is an upstream netcoredbg limitation affecting any Neovim+nvim-dap+netcoredbg setup on Apple Silicon, not specific to this plugin. Every other layer of the attach path was verified working end-to-end on real hardware: `list_services` finds the correct process, the DAP config and adapter setup are correct, and the session successfully initializes and proceeds through the full attach handshake up to that final step. No local fix is available; documented as a known platform caveat.

**`init.lua`**
- `setup(opts)` stores config (profile name override, custom launch.json path).
- `M.launch()` orchestrates: `launch_json.parse` → `find_aspire_config` → `variables.resolve` on `program` → `discovery.find_apphost` → `launch_profiles.load/pick_profile/to_env` → `runner.run`.
- Registers `:AspireLaunch`, `:AspireStop`, `:AspireDashboard`, `:AspireResources`.

## Testing

- `plenary.nvim` busted-style specs for the pure modules: `launch_json_spec.lua` (fixture JSONC files with comments/trailing commas/comments-that-look-like-URLs), `discovery_spec.lua` (fixture project trees), `launch_profiles_spec.lua` (fixture `launchSettings.json`), `dap_spec.lua` (fixture `ps` output covering a multi-level process tree, verifying descendant pids collected correctly and unrelated processes excluded).
- `runner.lua`/`dap.lua`'s real process/job interaction (list_services' cwd-based name resolution, attach/attach_all) aren't practical to unit test — verify manually against a real minimal Aspire sample app (`dotnet new aspire-starter`) once core parsing/discovery is solid: run `:AspireLaunch`, confirm log buffer streams, confirm dashboard URL notification fires and `:AspireDashboard` opens it, confirm `:AspireStop` actually kills `dotnet` and its children (check via `ps` before/after).

## Milestones (build in this order)

1. [x] Scaffold repo structure + `doc/aspire.txt` + README stub, `git init`.
2. [x] `launch_json.lua` + `variables.lua` with plenary specs — parses fixture launch.json, resolves `${workspaceFolder}`.
3. [x] `discovery.lua` with plenary specs against fixture project trees.
4. [x] `launch_profiles.lua` with plenary specs against fixture `launchSettings.json`.
5. [x] `runner.lua` + `init.lua` wiring — `:AspireLaunch` runs `dotnet run`, streams to log buffer. Verify manually against a real Aspire sample app.
6. [x] Dashboard URL detection + `:AspireDashboard`. Verify manually.
7. [x] `:AspireStop` with process-tree kill. Verify manually (`ps` before/after).
8. [x] `:AspireResources` stub.
9. [x] `dap.lua`: `parse_ps_output` + `build_tree` pure functions with plenary specs.
10. [x] `list_services` wired to real `ps`/`lsof`, cwd-based name resolution.
11. [x] `health.lua` + `:AspireAttach` (single-service attach). Verified against a real Aspire sample app as far as the platform allows — see caveat below.
12. [x] `:AspireAttachAll`, verified manually — 2 simultaneous sessions correctly created with distinct pids (same Apple Silicon breakpoint-hit caveat as milestone 11 applies to actual stops, not to session creation).

## Verification

- Unit: `nvim --headless -c "PlenaryBustedDirectory tests/aspire/"` for the pure modules after each relevant milestone, including `dap_spec.lua`.
- Integration: real Aspire sample app (`dotnet new aspire-starter -n Sample`), run `:AspireLaunch` inside Neovim opened at that sample's root, confirm log buffer output, dashboard URL notification + `:AspireDashboard` opening the right URL in a browser, `:AspireStop` cleanly terminating `dotnet` and any spawned service processes, and `:AspireAttach`/`:AspireAttachAll` successfully hitting breakpoints in at least two simultaneously-attached services.
