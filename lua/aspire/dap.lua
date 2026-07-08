local M = {}

--- Parse `ps -Ao pid,ppid,command` output into structured entries.
--- Lines that don't match "<pid> <ppid> <command>" (the header row,
--- blank lines) are skipped.
---@param raw string
---@return { pid: integer, ppid: integer, command: string }[]
function M.parse_ps_output(raw)
  local entries = {}
  for line in raw:gmatch("[^\n]+") do
    local pid, ppid, command = line:match("^%s*(%d+)%s+(%d+)%s+(.*)$")
    if pid then
      entries[#entries + 1] = {
        pid = tonumber(pid),
        ppid = tonumber(ppid),
        command = command,
      }
    end
  end
  return entries
end

--- Collect every descendant pid of `root_pid` from parsed ps entries.
---@param entries { pid: integer, ppid: integer, command: string }[]
---@param root_pid integer
---@return integer[]
function M.build_tree(entries, root_pid)
  local children_by_ppid = {}
  for _, e in ipairs(entries) do
    children_by_ppid[e.ppid] = children_by_ppid[e.ppid] or {}
    table.insert(children_by_ppid[e.ppid], e.pid)
  end

  local descendants = {}
  local frontier = { root_pid }
  while #frontier > 0 do
    local pid = table.remove(frontier)
    for _, child in ipairs(children_by_ppid[pid] or {}) do
      descendants[#descendants + 1] = child
      frontier[#frontier + 1] = child
    end
  end
  return descendants
end

-- Compiled .NET binaries (both self-contained apphost-style bare
-- executables and framework-dependent .dll invocations) sit in their
-- project's normal build output directory: ".../bin/<Config>/net<ver>/<Name>".
-- Empirically, this shape uniquely identifies real service/AppHost
-- binaries — "dotnet run --project ..." wrapper processes and Aspire's
-- own dashboard/DCP controller processes never match it.
local BIN_OUTPUT_PATTERN = "/bin/[^/]+/net[%d%.]+/[^/]+$"

local function looks_like_service_binary(command)
  return command:match(BIN_OUTPUT_PATTERN) ~= nil
end

--- Narrow a parsed ps listing down to attachable .NET service binaries
--- under `workspace_root`, excluding the AppHost's own binary (anything
--- under `apphost_dir`).
---
--- This does NOT walk the OS process tree from the AppHost's pid.
--- Empirically, Aspire's DCP layer daemonizes (`dcp start-apiserver`
--- reparents to pid 1, only linked to the AppHost via a `--monitor
--- <pid>` command-line argument, not real OS parentage) when
--- orchestrating child processes, so the real service processes are
--- NOT reachable via `build_tree` from the AppHost's pid at all —
--- confirmed against a live AppHost where the orchestrator binary had
--- zero real OS-level children. Filtering by build-output path instead
--- sidesteps the broken tree entirely.
---@param entries { pid: integer, ppid: integer, command: string }[]
---@param workspace_root string
---@param apphost_dir string directory containing the AppHost .csproj, excluded from results
---@return { pid: integer, ppid: integer, command: string }[]
function M.filter_services(entries, workspace_root, apphost_dir)
  local services = {}
  for _, e in ipairs(entries) do
    if
      looks_like_service_binary(e.command)
      and e.command:find(workspace_root, 1, true) == 1
      and e.command:find(apphost_dir, 1, true) ~= 1
    then
      services[#services + 1] = e
    end
  end
  return services
end

local function shell_ps_output()
  local ok, result = pcall(function()
    return vim.system({ "ps", "-Ao", "pid,ppid,command" }, { text = true }):wait()
  end)
  if not ok or not result or result.code ~= 0 then
    return ""
  end
  return result.stdout or ""
end

--- Resolve a display name for `pid` via its cwd, falling back to
--- "pid <n>" if the lookup fails (e.g. the process already exited, or
--- we're on an unsupported platform — this is macOS/Linux only).
---@param pid integer
---@return string
function M.resolve_name(pid)
  local cwd

  if vim.fn.has("mac") == 1 then
    local ok, result = pcall(function()
      return vim.system({ "lsof", "-a", "-d", "cwd", "-p", tostring(pid) }, { text = true }):wait()
    end)
    if ok and result and result.code == 0 and result.stdout then
      local last_line
      for line in result.stdout:gmatch("[^\n]+") do
        last_line = line
      end
      if last_line then
        cwd = last_line:match("(%S+)%s*$")
      end
    end
  else
    local uv = vim.uv or vim.loop
    local ok, link = pcall(uv.fs_readlink, "/proc/" .. pid .. "/cwd")
    if ok and link then
      cwd = link
    end
  end

  if cwd then
    return vim.fn.fnamemodify(cwd, ":t")
  end
  return "pid " .. pid
end

--- List attachable .NET service processes belonging to the AppHost at
--- `apphost_dir`, under `workspace_root`.
---@param workspace_root string
---@param apphost_dir string directory containing the AppHost .csproj
---@return { name: string, pid: integer, cmd: string }[]
function M.list_services(workspace_root, apphost_dir)
  local entries = M.parse_ps_output(shell_ps_output())
  local services = M.filter_services(entries, workspace_root, apphost_dir)

  local result = {}
  for _, e in ipairs(services) do
    result[#result + 1] = { name = M.resolve_name(e.pid), pid = e.pid, cmd = e.command }
  end
  return result
end

--- Attach nvim-dap's coreclr adapter to a running .NET process.
---@param pid integer
---@param opts table|nil { name: string|nil }
function M.attach(pid, opts)
  opts = opts or {}

  local ok, dap_plugin = pcall(require, "dap")
  if not ok then
    vim.notify("aspire: nvim-dap is not installed — required for :AspireAttach", vim.log.levels.ERROR)
    return
  end

  if vim.fn.executable("netcoredbg") ~= 1 then
    vim.notify("aspire: netcoredbg not found on PATH — required for :AspireAttach", vim.log.levels.ERROR)
    return
  end

  if not dap_plugin.adapters.coreclr then
    dap_plugin.adapters.coreclr = {
      type = "executable",
      command = vim.fn.exepath("netcoredbg"),
      args = { "--interpreter=vscode" },
    }
  end

  dap_plugin.run({
    type = "coreclr",
    request = "attach",
    processId = pid,
    name = opts.name or ("pid " .. pid),
    justMyCode = false,
  })
end

--- Prompt the user to pick a running service and attach to it.
--- Backs `:AspireAttach`.
function M.pick_and_attach()
  local runner = require("aspire.runner")
  if not runner.job then
    vim.notify("aspire: AppHost is not running — launch it first", vim.log.levels.WARN)
    return
  end

  local services = M.list_services(runner.workspace_root, runner.apphost_dir)
  if #services == 0 then
    vim.notify("aspire: no attachable .NET service processes found", vim.log.levels.WARN)
    return
  end

  vim.ui.select(services, {
    prompt = "Select a service to attach to",
    format_item = function(s)
      return string.format("%s (pid %d)", s.name, s.pid)
    end,
  }, function(choice)
    if choice then
      M.attach(choice.pid, { name = choice.name })
    end
  end)
end

return M
