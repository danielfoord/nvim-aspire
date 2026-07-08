local M = {}

--- Resolve VS Code-style `${name}` variables in a string. Unknown
--- variables are left untouched rather than blanked out.
---@param str string|nil
---@param ctx table|nil e.g. { workspaceFolder = "/path/to/project" }
---@return string|nil
function M.resolve(str, ctx)
  if not str then
    return str
  end
  ctx = ctx or {}

  return (str:gsub("%${(%a+)}", function(name)
    return ctx[name] or ("${" .. name .. "}")
  end))
end

return M
