# nvim-aspire

Neovim plugin that treats VS Code's `.vscode/launch.json` Aspire launch type (`"type": "aspire"`) as a first-class launch target: launch a .NET Aspire AppHost, surface its dashboard URL, and attach `nvim-dap` to the services it spawns.

## Requirements

- Neovim 0.10+
- `dotnet` CLI on `$PATH`
- [nvim-dap](https://github.com/mfussenegger/nvim-dap) + `netcoredbg` (only required for debugger attach, not for launch/orchestration)

## Installation

**[lazy.nvim](https://github.com/folke/lazy.nvim)**

```lua
{
  "danielfoord/nvim-aspire",
  dependencies = { "mfussenegger/nvim-dap" }, -- optional, only needed for :AspireAttach*
  opts = {},
}
```

**[packer.nvim](https://github.com/wbthomason/packer.nvim)**

```lua
use({
  "danielfoord/nvim-aspire",
  requires = { "mfussenegger/nvim-dap" }, -- optional, only needed for :AspireAttach*
  config = function()
    require("aspire").setup({})
  end,
})
```

Run `:checkhealth aspire` after installing to confirm `dotnet`, `netcoredbg`, and `nvim-dap` are all detected correctly.

## Commands

- `:AspireLaunch` — parse `.vscode/launch.json`, find the AppHost, run it, stream output to a log buffer, surface the dashboard URL.
- `:AspireStop` — stop the running AppHost and its child processes.
- `:AspireLog` — open the AppHost's output log buffer (build output, `dotnet run` stdout/stderr) — handy while waiting for services to come up.
- `:AspireDashboard` — open the Aspire dashboard URL.
- `:AspireResources` — list running .NET service resources (name, pid, command) in a scratch buffer.
- `:AspireAttach` — attach `nvim-dap` to a running .NET service.
- `:AspireAttachAll` — attach `nvim-dap` to every discovered .NET service.

## Setup

```lua
require("aspire").setup({})
```

## Keymaps

Not set by default — add whichever of these you want, e.g. under a `<leader>a` ("aspire") prefix:

```lua
vim.keymap.set("n", "<leader>al", "<cmd>AspireLaunch<cr>", { desc = "Aspire: Launch AppHost" })
vim.keymap.set("n", "<leader>ax", "<cmd>AspireStop<cr>", { desc = "Aspire: Stop AppHost" })
vim.keymap.set("n", "<leader>ao", "<cmd>AspireLog<cr>", { desc = "Aspire: Open log" })
vim.keymap.set("n", "<leader>ad", "<cmd>AspireDashboard<cr>", { desc = "Aspire: Open dashboard" })
vim.keymap.set("n", "<leader>ar", "<cmd>AspireResources<cr>", { desc = "Aspire: List resources" })
vim.keymap.set("n", "<leader>aa", "<cmd>AspireAttach<cr>", { desc = "Aspire: Attach to service" })
vim.keymap.set("n", "<leader>aA", "<cmd>AspireAttachAll<cr>", { desc = "Aspire: Attach to all services" })
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

- Container-backed resources (Redis, Postgres, etc.) aren't attachable or listed by `:AspireResources` — only plain `Project` resources have a local .NET process to discover.
- On Windows, `:AspireStop` signals the AppHost process itself but doesn't discover/kill its child service processes (its descendant-kill still relies on `pgrep`, which Windows doesn't have) — you may need to end those manually via Task Manager.
- Apple Silicon: netcoredbg supports macOS arm64 as a community-supported source build, but its official releases do not currently ship a native macOS arm64 binary. Consequently, package managers such as Mason generally install the official x86_64 build, which macOS runs through Rosetta 2. netcoredbg and the target .NET runtime must use compatible architectures: the Rosetta-translated x86_64 debugger cannot attach reliably to a native arm64 CoreCLR process. As a result, :AspireAttach will fail when it uses the x86_64 netcoredbg against a native arm64 Aspire process. The workaround is to use a community-built or locally compiled arm64 netcoredbg, or run both dotnet and netcoredbg as x86_64 under Rosetta. This is primarily an upstream netcoredbg release-packaging and architecture-support limitation rather than an AspireAttach-specific issue. 
