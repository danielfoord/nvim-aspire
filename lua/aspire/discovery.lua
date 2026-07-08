local M = {}

local function is_dir(path)
  return vim.fn.isdirectory(path) == 1
end

local function is_file(path)
  return vim.fn.filereadable(path) == 1
end

local function find_csproj_files(dir)
  local matches = vim.fn.globpath(dir, "**/*.csproj", false, true)
  table.sort(matches)
  return matches
end

local function is_apphost_named(path)
  return path:match("%.AppHost%.csproj$") ~= nil or path:find(".AppHost", 1, true) ~= nil
end

local function references_aspire_hosting(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return false
  end
  local content = table.concat(lines, "\n")
  return content:find("Aspire.Hosting", 1, true) ~= nil
end

--- Narrow a list of .csproj candidates down to a single AppHost.
---@param candidates string[]
---@return string|nil path
---@return string[]|nil ambiguous_candidates present only when narrowing left 2+ candidates tied
local function pick_apphost(candidates)
  if #candidates == 0 then
    return nil, nil
  end
  if #candidates == 1 then
    return candidates[1], nil
  end

  local named = vim.tbl_filter(is_apphost_named, candidates)
  if #named == 1 then
    return named[1], nil
  elseif #named > 1 then
    return nil, named
  end

  local referencing = vim.tbl_filter(references_aspire_hosting, candidates)
  if #referencing == 1 then
    return referencing[1], nil
  elseif #referencing > 1 then
    return nil, referencing
  end

  return nil, candidates
end

--- Find the Aspire AppHost .csproj under `root`.
---@param root string workspace root to fall back to
---@param hint string|nil resolved `program` value from the launch config (a .csproj file or a folder)
---@return string|nil path
---@return string[]|nil ambiguous_candidates present only when multiple candidates tie and need a user pick
function M.find_apphost(root, hint)
  if hint and is_file(hint) and hint:match("%.csproj$") then
    return hint, nil
  end

  local search_dir = (hint and is_dir(hint)) and hint or root
  local candidates = find_csproj_files(search_dir)

  if #candidates == 0 and search_dir ~= root then
    candidates = find_csproj_files(root)
  end

  return pick_apphost(candidates)
end

return M
