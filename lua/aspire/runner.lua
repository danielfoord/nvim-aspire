local M = {}

M.job = nil -- vim.SystemObj handle for the running AppHost, nil when stopped
M.buf = nil -- log buffer number
M.dashboard_url = nil -- set once the AppHost prints its dashboard login URL
M.workspace_root = nil -- set while the AppHost is running, for aspire.dap's service discovery
M.apphost_dir = nil -- ditto: directory containing the AppHost .csproj

local DASHBOARD_URL_PATTERN = "https?://[^%s]+/login%?t=[^%s]+"

--- Extract an Aspire dashboard login URL from a line of AppHost output,
--- e.g. "Login to the dashboard at https://localhost:17225/login?t=...".
---@param line string
---@return string|nil
function M.detect_dashboard_url(line)
  return line:match(DASHBOARD_URL_PATTERN)
end

local function ensure_log_buffer()
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    return M.buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "aspirelog"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, "aspire://log")
  M.buf = buf
  return buf
end

local function append_line(line)
  vim.schedule(function()
    local buf = ensure_log_buffer()
    local last = vim.api.nvim_buf_line_count(buf)
    if last == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, { line })
    else
      vim.api.nvim_buf_set_lines(buf, last, last, false, { line })
    end
  end)
end

local function process_line(line)
  if not M.dashboard_url then
    local url = M.detect_dashboard_url(line)
    if url then
      M.dashboard_url = url
      vim.schedule(function()
        vim.notify("aspire: dashboard available at " .. url, vim.log.levels.INFO)
      end)
    end
  end
  append_line(line)
end

local function on_output(prefix)
  return function(err, data)
    if err then
      process_line("[" .. prefix .. ":err] " .. err)
    end
    if data then
      for _, line in ipairs(vim.split(data, "\n", { plain = true, trimempty = true })) do
        process_line(line)
      end
    end
  end
end

local function signal_pid(pid, sig)
  local uv = vim.uv or vim.loop
  pcall(uv.kill, pid, sig)
end

local function children_of(pid)
  local ok, result = pcall(function()
    return vim.system({ "pgrep", "-P", tostring(pid) }, { text = true }):wait()
  end)
  if not ok or not result or result.code ~= 0 or not result.stdout then
    return {}
  end

  local pids = {}
  for line in result.stdout:gmatch("[^\n]+") do
    local n = tonumber(line)
    if n then
      pids[#pids + 1] = n
    end
  end
  return pids
end

--- Collect every descendant pid of `root_pid`, deepest last.
---@param root_pid integer
---@return integer[]
local function collect_descendants(root_pid)
  local all = {}
  local frontier = { root_pid }
  while #frontier > 0 do
    local pid = table.remove(frontier)
    for _, child in ipairs(children_of(pid)) do
      all[#all + 1] = child
      frontier[#frontier + 1] = child
    end
  end
  return all
end

--- Run the AppHost via `dotnet run --project <apphost_path>`.
---@param apphost_path string
---@param opts table|nil { cwd: string|nil, env: table<string,string>|nil, workspace_root: string|nil }
function M.run(apphost_path, opts)
  opts = opts or {}

  if M.job then
    vim.notify("aspire: AppHost already running", vim.log.levels.WARN)
    return
  end

  M.dashboard_url = nil
  M.workspace_root = opts.workspace_root
  M.apphost_dir = opts.cwd
  ensure_log_buffer()
  append_line("[aspire] dotnet run --project " .. apphost_path)

  M.job = vim.system({ "dotnet", "run", "--project", apphost_path }, {
    cwd = opts.cwd,
    env = opts.env,
    text = true,
    stdout = on_output("stdout"),
    stderr = on_output("stderr"),
  }, function(obj)
    vim.schedule(function()
      append_line(string.format("[aspire] process exited (code=%d)", obj.code))
      M.job = nil
      M.dashboard_url = nil
      M.workspace_root = nil
      M.apphost_dir = nil
    end)
  end)

  vim.notify("aspire: launching AppHost " .. apphost_path, vim.log.levels.INFO)
end

--- Stop the running AppHost and every child process it spawned.
--- `dotnet run` doesn't put its children in their own process group
--- (they inherit Neovim's), so a group kill (`kill -TERM -<pid>`) isn't
--- viable — instead this walks the descendant tree via `pgrep -P` and
--- signals each pid individually, children first.
function M.stop()
  if not M.job then
    vim.notify("aspire: AppHost is not running", vim.log.levels.WARN)
    return
  end

  local root_pid = M.job.pid
  local descendants = collect_descendants(root_pid)

  for i = #descendants, 1, -1 do
    signal_pid(descendants[i], "sigterm")
  end
  signal_pid(root_pid, "sigterm")

  append_line(
    string.format("[aspire] stop requested (root pid %d, %d child process(es))", root_pid, #descendants)
  )
  vim.notify("aspire: stopping AppHost", vim.log.levels.INFO)
end

--- Open (or focus) the log buffer in the current window.
function M.open_log()
  local buf = ensure_log_buffer()
  vim.api.nvim_set_current_buf(buf)
end

return M
