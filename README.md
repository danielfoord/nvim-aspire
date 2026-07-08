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
