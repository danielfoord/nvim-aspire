local M = {}

function M.check()
  local health = vim.health

  health.start("aspire")

  if vim.fn.executable("dotnet") == 1 then
    health.ok("dotnet found on PATH (required for :AspireLaunch)")
  else
    health.error("dotnet not found on PATH — :AspireLaunch will not work")
  end

  if vim.fn.executable("netcoredbg") == 1 then
    health.ok("netcoredbg found on PATH (required for :AspireAttach)")
  else
    health.warn("netcoredbg not found on PATH — :AspireAttach/:AspireAttachAll will not work")
  end

  local ok = pcall(require, "dap")
  if ok then
    health.ok("nvim-dap is installed (required for :AspireAttach)")
  else
    health.warn("nvim-dap is not installed — :AspireAttach/:AspireAttachAll will not work")
  end

  if vim.fn.has("win32") == 1 then
    if vim.fn.executable("powershell") == 1 then
      health.ok("powershell found on PATH (required for :AspireAttach service discovery on Windows)")
    else
      health.warn("powershell not found on PATH — :AspireAttach/:AspireAttachAll will not work on Windows")
    end
  end
end

return M
