# nvim-aspire

Neovim plugin that treats VS Code's `.vscode/launch.json` Aspire launch type (`"type": "aspire"`) as a first-class launch target: launch a .NET Aspire AppHost, surface its dashboard URL, and attach `nvim-dap` to the services it spawns.

## Status

Early development. See [PLAN.md](./PLAN.md) for design and milestones.

## Requirements

- Neovim 0.10+
- `dotnet` CLI on `$PATH`
- [nvim-dap](https://github.com/mfussenegger/nvim-dap) + `netcoredbg` (only required for debugger attach, not for launch/orchestration)

## Commands

- `:AspireLaunch` — parse `.vscode/launch.json`, find the AppHost, run it, stream output to a log buffer, surface the dashboard URL.
- `:AspireStop` — stop the running AppHost and its child processes.
- `:AspireDashboard` — open the Aspire dashboard URL.
- `:AspireResources` — list running resources (stub for now).
- `:AspireAttach` — attach `nvim-dap` to a running .NET service.
- `:AspireAttachAll` — attach `nvim-dap` to every discovered .NET service.

## Setup

```lua
require("aspire").setup({})
```

## macOS: netcoredbg needs the debugger entitlement

macOS's System Integrity Protection blocks an unsigned debugger from attaching to another process — `netcoredbg` as installed by mason.nvim (or downloaded manually) is unsigned, so `:AspireAttach` fails outright until it's ad-hoc signed with the debugger entitlement:

```bash
cat > /tmp/netcoredbg-entitlements.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.debugger</key>
    <true/>
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
</plist>
EOF
codesign -f -s - --entitlements /tmp/netcoredbg-entitlements.plist <path-to-real-netcoredbg-binary>
```

If installed via mason, the path mason.nvim puts on `$PATH` (e.g. `~/.local/share/nvim/mason/bin/netcoredbg`) is a wrapper shell script, not the real binary — sign the actual executable it `exec`s, typically `~/.local/share/nvim/mason/packages/netcoredbg/libexec/netcoredbg/netcoredbg`. Confirm with:

```bash
codesign -d --entitlements - <path-to-real-netcoredbg-binary>
```

which should print both entitlements listed above. This only needs doing once per netcoredbg install (re-signing is needed again after any reinstall/update).

## Known limitations

- Container-backed resources (Redis, Postgres, etc.) aren't attachable — only plain `Project` resources.
- Windows is unsupported for the DAP attach layer (`:AspireAttach`/`:AspireAttachAll`).
- **Apple Silicon**: `netcoredbg` doesn't ship a native macOS arm64 build, so Neovim plugin managers install the x86_64 build under Rosetta 2. A Rosetta-translated debugger cannot attach to a native arm64 .NET process — `:AspireAttach` will fail during the attach handshake on Apple Silicon Macs even with the entitlement fix above. This is an upstream `netcoredbg` limitation, not specific to this plugin.
