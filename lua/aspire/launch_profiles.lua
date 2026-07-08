local launch_json = require("aspire.launch_json")

local M = {}

--- Read `Properties/launchSettings.json` for the project at `apphost_dir`.
---@param apphost_dir string directory containing the AppHost .csproj
---@return table|nil decoded
---@return string|nil err
function M.load(apphost_dir)
  return launch_json.parse(apphost_dir .. "/Properties/launchSettings.json")
end

--- Pick a profile from a launchSettings.json `profiles` table.
--- Default: first "Project" profile in alphabetical name order (JSON
--- object key order isn't preserved through vim.json.decode, so
--- alphabetical is used as a deterministic substitute for "file order").
---@param profiles table|nil keyed by profile name
---@param opts table|nil { profile: string|nil } exact profile name to pick
---@return string|nil name
---@return table|nil profile
function M.pick_profile(profiles, opts)
  opts = opts or {}
  profiles = profiles or {}

  if opts.profile then
    local match = profiles[opts.profile]
    if match then
      return opts.profile, match
    end
    return nil, nil
  end

  local names = vim.tbl_keys(profiles)
  table.sort(names)
  for _, name in ipairs(names) do
    if profiles[name].commandName == "Project" then
      return name, profiles[name]
    end
  end

  return nil, nil
end

--- Map a profile's environmentVariables + applicationUrl into an env
--- table suitable for the `dotnet run` job.
---@param profile table|nil
---@return table<string, string>
function M.to_env(profile)
  local env = {}
  if not profile then
    return env
  end

  for k, v in pairs(profile.environmentVariables or {}) do
    env[k] = tostring(v)
  end

  if profile.applicationUrl then
    env.ASPNETCORE_URLS = profile.applicationUrl
  end

  return env
end

return M
