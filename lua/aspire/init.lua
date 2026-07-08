local M = {}

M.opts = {}

function M.setup(opts)
  M.opts = opts or {}
end

local function workspace_root()
  return vim.fn.getcwd()
end

local function launch_apphost(apphost_path)
  local launch_profiles = require("aspire.launch_profiles")
  local runner = require("aspire.runner")

  local apphost_dir = vim.fn.fnamemodify(apphost_path, ":h")
  local decoded = launch_profiles.load(apphost_dir)

  local env = vim.fn.environ()
  if decoded then
    local _, profile = launch_profiles.pick_profile(decoded.profiles, { profile = M.opts.profile })
    if profile then
      env = vim.tbl_extend("force", env, launch_profiles.to_env(profile))
    end
  end

  runner.run(apphost_path, { cwd = apphost_dir, env = env })
end

local function resolve_and_launch(root, cfg)
  local variables = require("aspire.variables")
  local discovery = require("aspire.discovery")

  local program = variables.resolve(cfg.program, { workspaceFolder = root })
  local apphost_path, candidates = discovery.find_apphost(root, program)

  if apphost_path then
    launch_apphost(apphost_path)
    return
  end

  if not candidates then
    vim.notify("aspire: could not find an AppHost project under " .. root, vim.log.levels.ERROR)
    return
  end

  vim.ui.select(candidates, {
    prompt = "Select Aspire AppHost project",
  }, function(choice)
    if choice then
      launch_apphost(choice)
    end
  end)
end

function M.launch()
  local launch_json = require("aspire.launch_json")

  local root = workspace_root()
  local launch_json_path = M.opts.launch_json_path or (root .. "/.vscode/launch.json")

  local decoded, err = launch_json.parse(launch_json_path)
  if not decoded then
    vim.notify("aspire: " .. (err or ("failed to read " .. launch_json_path)), vim.log.levels.ERROR)
    return
  end

  local cfg, matches = launch_json.find_aspire_config(decoded, { name = M.opts.config_name })
  if cfg then
    resolve_and_launch(root, cfg)
    return
  end

  if not matches then
    vim.notify("aspire: no Aspire launch config found in " .. launch_json_path, vim.log.levels.ERROR)
    return
  end

  vim.ui.select(matches, {
    prompt = "Select Aspire launch config",
    format_item = function(m)
      return m.name
    end,
  }, function(choice)
    if choice then
      resolve_and_launch(root, choice)
    end
  end)
end

function M.dashboard()
  require("aspire.dashboard").open()
end

vim.api.nvim_create_user_command("AspireLaunch", M.launch, {})
vim.api.nvim_create_user_command("AspireDashboard", M.dashboard, {})

return M
