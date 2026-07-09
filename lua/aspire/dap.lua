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

--- Parse `pid|ppid|command` lines (as emitted by the PowerShell
--- Win32_Process listing used on Windows) into structured entries.
---@param raw string
---@return { pid: integer, ppid: integer, command: string }[]
function M.parse_powershell_output(raw)
  local entries = {}
  for line in raw:gmatch("[^\r\n]+") do
    local pid, ppid, command = line:match("^(%d+)|(%d+)|(.*)$")
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
-- project's normal build output directory: ".../bin/<Config>/net<ver>/<Name>"
-- (or "...\bin\<Config>\net<ver>\<Name>.exe" on Windows). Empirically,
-- this shape uniquely identifies real service/AppHost binaries —
-- "dotnet run --project ..." wrapper processes and Aspire's own
-- dashboard/DCP controller processes never match it.
local BIN_OUTPUT_PATTERN = "[/\\]bin[/\\][^/\\]+[/\\]net[%d%.]+[/\\][^/\\]+$"

local function looks_like_service_binary(command)
  return command:match(BIN_OUTPUT_PATTERN) ~= nil
end

local function normalize_sep(path)
  return (path:gsub("\\", "/"))
end

--- Pull the executable path out of a raw command line. Windows'
--- `Win32_Process.CommandLine` quotes the exe path and may append
--- arguments after it (e.g. `"C:\...\Foo.exe" --console`); macOS/Linux
--- `ps` output is normally unquoted with no wrapping quotes at all.
--- Handles both so downstream matching only ever sees the bare path.
---@param command string
---@return string
function M.extract_exe_path(command)
  local quoted = command:match('^"([^"]*)"')
  if quoted then
    return quoted
  end
  return command:match("^(%S+)") or command
end

--- Narrow a parsed process listing down to attachable .NET service
--- binaries under `workspace_root`, excluding the AppHost's own binary
--- (anything under `apphost_dir`). Path separators are normalized
--- before comparison so this works whether the listing reports `/`
--- (macOS/Linux `ps`) or `\` (Windows `Win32_Process.CommandLine`).
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
---@param opts table|nil { case_insensitive: boolean|nil } pass true on Windows, where the same path can be reported with different casing by different APIs
---@return { pid: integer, ppid: integer, command: string }[]
function M.filter_services(entries, workspace_root, apphost_dir, opts)
  opts = opts or {}

  local function comparison_key(path)
    local normalized = normalize_sep(path)
    if opts.case_insensitive then
      normalized = normalized:lower()
    end
    return normalized
  end

  local norm_root = comparison_key(workspace_root)
  local norm_apphost = comparison_key(apphost_dir)

  local services = {}
  for _, e in ipairs(entries) do
    local exe_path = M.extract_exe_path(e.command)
    local norm_cmd = comparison_key(exe_path)
    if
      looks_like_service_binary(exe_path)
      and norm_cmd:find(norm_root, 1, true) == 1
      and norm_cmd:find(norm_apphost, 1, true) ~= 1
    then
      services[#services + 1] = e
    end
  end
  return services
end

local WINDOWS_PROCESS_LISTING_SCRIPT = [[
Get-CimInstance Win32_Process | ForEach-Object { "$($_.ProcessId)|$($_.ParentProcessId)|$($_.CommandLine)" }
]]

--- Run the process-listing PowerShell script from a temp .ps1 file
--- rather than an inline `-Command "..."` string. The script contains
--- nested double quotes and `$()` subexpressions that aren't reliable
--- to pass as a single argv element through Unix-argv-to-Windows-
--- command-line translation; a file path is a much simpler argument
--- to quote correctly. `-ExecutionPolicy Bypass` avoids the script
--- being blocked by a restrictive execution policy (an inline
--- `-Command` string isn't subject to that policy, so switching to
--- `-File` needs this to keep the same behavior).
---@return vim.SystemCompleted|nil
local function run_windows_process_listing()
  local script_path = vim.fn.tempname() .. ".ps1"
  local ok_write = pcall(vim.fn.writefile, vim.split(WINDOWS_PROCESS_LISTING_SCRIPT, "\n"), script_path)
  if not ok_write then
    return nil
  end

  local ok, result = pcall(function()
    return vim.system({
      "powershell",
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      script_path,
    }, { text = true }):wait()
  end)

  pcall(vim.fn.delete, script_path)

  if not ok then
    return nil
  end
  return result
end

--- Shell out to list every running process as { pid, ppid, command }
--- entries: `ps -Ao pid,ppid,command` on macOS/Linux, a PowerShell
--- Win32_Process query on Windows.
---@return { pid: integer, ppid: integer, command: string }[]
local function list_processes()
  if vim.fn.has("win32") == 1 then
    local result = run_windows_process_listing()
    if not result then
      vim.notify("aspire: failed to run the PowerShell process listing (is powershell on PATH?)", vim.log.levels.WARN)
      return {}
    end
    if result.code ~= 0 then
      vim.notify(
        "aspire: PowerShell process listing exited with code "
          .. tostring(result.code)
          .. (result.stderr and result.stderr ~= "" and (": " .. result.stderr) or ""),
        vim.log.levels.WARN
      )
      return {}
    end
    return M.parse_powershell_output(result.stdout or "")
  end

  local ok, result = pcall(function()
    return vim.system({ "ps", "-Ao", "pid,ppid,command" }, { text = true }):wait()
  end)
  if not ok or not result or result.code ~= 0 then
    return {}
  end
  return M.parse_ps_output(result.stdout or "")
end

--- Derive a display name for a service from its command path: the
--- basename of the project directory containing bin/<Config>/net<ver>/.
--- Pure — works identically for `/`- and `\`-separated paths, so it
--- needs no per-pid shell-out (unlike the cwd-lookup approach this
--- replaced, which was macOS/Linux-only).
---@param command string
---@return string
function M.resolve_name(command)
  local exe_path = M.extract_exe_path(command)
  local project_dir = exe_path:match("^(.*)[/\\]bin[/\\][^/\\]+[/\\]net[%d%.]+[/\\][^/\\]+$")
  if project_dir then
    return vim.fn.fnamemodify(normalize_sep(project_dir), ":t")
  end
  return command
end

--- List attachable .NET service processes belonging to the AppHost at
--- `apphost_dir`, under `workspace_root`.
---@param workspace_root string
---@param apphost_dir string directory containing the AppHost .csproj
---@return { name: string, pid: integer, cmd: string }[]
function M.list_services(workspace_root, apphost_dir)
  local entries = list_processes()
  local services = M.filter_services(entries, workspace_root, apphost_dir, { case_insensitive = vim.fn.has("win32") == 1 })

  local result = {}
  for _, e in ipairs(services) do
    result[#result + 1] = { name = M.resolve_name(e.command), pid = e.pid, cmd = e.command }
  end
  return result
end

--- Resolve the real `netcoredbg` binary to spawn. On Windows, mason
--- exposes `netcoredbg` via a `.cmd` shim on PATH (`mason/bin/*.cmd`);
--- spawning that shim as a DAP adapter wraps it in `cmd.exe`, whose
--- stdio indirection stalls the interpreter-mode JSON-RPC protocol —
--- confirmed empirically: the adapter process starts but never responds
--- to the `initialize` request, even after 45s, while pointing directly
--- at the real `.exe` responds almost instantly. mason-registry knows
--- the real install path (mason-nvim-dap's own `coreclr.lua` resolves
--- it the same way), so prefer that and only fall back to PATH lookup
--- when mason isn't installed.
---@return string|nil
local function resolve_netcoredbg_command()
  local ok_registry, registry = pcall(require, "mason-registry")
  if ok_registry and registry.is_installed("netcoredbg") then
    local install_path = registry.get_package("netcoredbg"):get_install_path()
    local exe = install_path .. "/netcoredbg/netcoredbg" .. (vim.fn.has("win32") == 1 and ".exe" or "")
    if vim.fn.filereadable(exe) == 1 then
      return exe
    end
  end
  return vim.fn.exepath("netcoredbg")
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
      command = resolve_netcoredbg_command(),
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

local function running_services()
  local runner = require("aspire.runner")
  if not runner.job then
    vim.notify("aspire: AppHost is not running — launch it first", vim.log.levels.WARN)
    return nil
  end

  local services = M.list_services(runner.workspace_root, runner.apphost_dir)
  if #services == 0 then
    vim.notify("aspire: no attachable .NET service processes found", vim.log.levels.WARN)
    return nil
  end

  return services
end

--- Prompt the user to pick a running service and attach to it.
--- Backs `:AspireAttach`.
function M.pick_and_attach()
  local services = running_services()
  if not services then
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

--- Attach to every discovered service, no prompt. Backs `:AspireAttachAll`.
function M.attach_all()
  local services = running_services()
  if not services then
    return
  end

  for _, s in ipairs(services) do
    M.attach(s.pid, { name = s.name })
  end
end

return M
