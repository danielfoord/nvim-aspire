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

return M
