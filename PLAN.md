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
- `stop()` — Aspire's `dotnet run` spawns a child process tree; killing just the `dotnet` pid can leave orphans. On the pid returned by `vim.system`, kill the process **group**: launch via `setsid`/detach isn't directly exposed by `vim.system`, so track `pid` and shell out to `kill -TERM -<pid>` if a negative-pid group kill is supported, otherwise fall back to `vim.system({"pkill","-P",tostring(pid)})` to also kill children before killing the parent. Document this as best-effort — full process-tree management is inherently platform-fiddly; acceptable for v1.

**`dashboard.lua`**
- `open()` — `vim.ui.open(M.dashboard_url)` (built-in in 0.10+, falls back to `open`/`xdg-open` shell otherwise) if a URL was captured, else notify "not launched yet".
- `resources()` — v1: stub that notifies "not yet implemented, see dashboard" — Aspire's resource-state HTTP API isn't stable/documented enough to build against confidently for a v1; mark as a follow-up once a real Aspire sample app is available to inspect actual dashboard traffic.

## DAP integration design

Once `:AspireLaunch` has an AppHost running, the user needs to attach a debugger to individual .NET services the AppHost spawns — mirroring VS Code's Aspire extension, which auto-attaches per-service. `dap.lua` only starts once `runner.lua` has a live AppHost job with a known pid; it's a layer bolted on top of orchestration, not baked into the launch flow.

**Discovery strategy**: walk the OS process tree rather than call Aspire's dashboard resource API. The dashboard/DCP resource API isn't stable/documented enough to build against confidently and requires the same auth token already handled ad hoc for the dashboard URL. Plain `ps`-based process-tree walking needs no auth and works today. Limitation: only plain `Project` resources (child `dotnet` processes) are attachable this way — containerized resources (Redis, Postgres, etc.) aren't visible to a host-side pid walk and are out of scope for v1. Windows unsupported in v1 (`ps`/`lsof` don't exist there).

**`dap.lua`**
- `parse_ps_output(raw) -> {pid, ppid, command}[]` — pure function parsing `ps -Ao pid,ppid,command` text. Testable with fixture text, no shell-out.
- `build_tree(entries, root_pid) -> pid[]` — pure function, recursively collects descendant pids of `root_pid`. Testable.
- `list_services(apphost_pid) -> {name, pid, cmd}[]` — shells to `ps -Ao pid,ppid,command`, runs it through the two pure functions above, filters descendants whose `command` looks like `dotnet exec <dll>` or a self-contained apphost binary (excludes the `dotnet run` wrapper itself and non-.NET children). Resolves a display `name` per pid via cwd lookup (`lsof -a -d cwd -p <pid>` on macOS, `/proc/<pid>/cwd` on Linux), basename of that directory; falls back to `"pid <n>"` if lookup fails.
- `attach(pid, opts)` — builds `{type="coreclr", request="attach", processId=pid, name=opts.name, justMyCode=false}` and calls `require("dap").run(cfg)`. Before attaching: check `pcall(require, "dap")` succeeds and `vim.fn.executable("netcoredbg") == 1`; notify with a clear error naming the missing piece. Don't overwrite `require("dap").adapters.coreclr` if the user already configured one (e.g. via mason-nvim-dap) — only set a default (mirroring mason-nvim-dap's `coreclr.lua`: `{type="executable", command=vim.fn.exepath("netcoredbg"), args={"--interpreter=vscode"}}`) if unset.
- `pick_and_attach()` — `list_services()` → `vim.ui.select` by name → `attach()`. Backs `:AspireAttach`.
- `attach_all()` — `list_services()` → `attach()` on every entry, no prompt. nvim-dap supports multiple concurrent sessions.

**`health.lua`**: `:checkhealth aspire` reports `dotnet` executable presence (required for `:AspireLaunch`), `netcoredbg` presence (warning not error if missing — orchestration works without it), and whether `nvim-dap` is loadable.

**Commands added**: `:AspireAttach` (pick one service, attach), `:AspireAttachAll` (attach to every discovered service). Both live in `init.lua`, delegate to `dap.lua`.

**Known limitations** (document in README/help): container-backed resources aren't attachable; Windows unsupported for attach; `:AspireStop` while a DAP session is attached leaves that session pointing at a dead process — nvim-dap handles a disconnected adapter reasonably but this isn't actively cleaned up in v1.

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
6. Dashboard URL detection + `:AspireDashboard`. Verify manually.
7. `:AspireStop` with process-tree kill. Verify manually (`ps` before/after).
8. `:AspireResources` stub.
9. `dap.lua`: `parse_ps_output` + `build_tree` pure functions with plenary specs.
10. `list_services` wired to real `ps`/`lsof`, cwd-based name resolution.
11. `health.lua` + `:AspireAttach` (single-service attach), verify manually against a real Aspire sample app — confirm breakpoint hits.
12. `:AspireAttachAll`, verify manually with 2+ simultaneous attach sessions.

## Verification

- Unit: `nvim --headless -c "PlenaryBustedDirectory tests/aspire/"` for the pure modules after each relevant milestone, including `dap_spec.lua`.
- Integration: real Aspire sample app (`dotnet new aspire-starter -n Sample`), run `:AspireLaunch` inside Neovim opened at that sample's root, confirm log buffer output, dashboard URL notification + `:AspireDashboard` opening the right URL in a browser, `:AspireStop` cleanly terminating `dotnet` and any spawned service processes, and `:AspireAttach`/`:AspireAttachAll` successfully hitting breakpoints in at least two simultaneously-attached services.
