local M = {}

M.buf = nil -- resources buffer number

--- Open the Aspire dashboard URL captured from the running AppHost.
function M.open()
  local runner = require("aspire.runner")
  if not runner.dashboard_url then
    vim.notify("aspire: dashboard not available yet — launch the AppHost first", vim.log.levels.WARN)
    return
  end
  vim.ui.open(runner.dashboard_url)
end

--- Format running services into aligned "name  pid <pid>  command" lines.
---@param services { name: string, pid: integer, cmd: string }[]
---@return string[]
function M.format_services(services)
  local name_width = 0
  for _, s in ipairs(services) do
    name_width = math.max(name_width, #s.name)
  end

  local lines = {}
  for _, s in ipairs(services) do
    lines[#lines + 1] = string.format("%-" .. name_width .. "s  pid %-8d %s", s.name, s.pid, s.cmd)
  end
  return lines
end

local function ensure_buf()
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    return M.buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "aspireresources"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, "aspire://resources")
  M.buf = buf
  return buf
end

--- List running Aspire .NET service resources (name, pid, command) in a
--- scratch buffer. Resource discovery is the same cross-platform process
--- listing `:AspireAttach` uses (`ps` on macOS/Linux, a PowerShell
--- `Win32_Process` query on Windows) rather than Aspire's own
--- resource-state API, which isn't stable/documented enough to build
--- against confidently yet. Container-backed resources (Redis, Postgres,
--- etc.) don't show up here — only plain `Project` resources have a
--- local .NET process to discover.
function M.resources()
  local services = require("aspire.dap").running_services()
  if not services then
    return
  end

  local buf = ensure_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.format_services(services))
  vim.api.nvim_set_current_buf(buf)
end

return M
