local M = {}

--- Open the Aspire dashboard URL captured from the running AppHost.
function M.open()
  local runner = require("aspire.runner")
  if not runner.dashboard_url then
    vim.notify("aspire: dashboard not available yet — launch the AppHost first", vim.log.levels.WARN)
    return
  end
  vim.ui.open(runner.dashboard_url)
end

--- List running Aspire resources.
--- Stub for v1: Aspire's resource-state API isn't stable/documented
--- enough to build against confidently yet — use the dashboard UI
--- directly for now.
function M.resources()
  vim.notify(
    "aspire: :AspireResources not implemented yet — use :AspireDashboard to see running resources",
    vim.log.levels.WARN
  )
end

return M
