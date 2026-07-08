local M = {}

--- Strip // line comments and /* */ block comments from JSONC text,
--- leaving comment-like sequences inside string literals untouched.
--- Newlines inside stripped comments are preserved so line numbers
--- in downstream error messages stay roughly accurate.
---@param text string
---@return string
function M.strip_comments(text)
  local out = {}
  local i, n = 1, #text
  local in_string = false
  local escaped = false

  while i <= n do
    local c = text:sub(i, i)

    if in_string then
      out[#out + 1] = c
      if escaped then
        escaped = false
      elseif c == "\\" then
        escaped = true
      elseif c == '"' then
        in_string = false
      end
      i = i + 1
    elseif c == '"' then
      in_string = true
      out[#out + 1] = c
      i = i + 1
    elseif c == "/" and text:sub(i + 1, i + 1) == "/" then
      while i <= n and text:sub(i, i) ~= "\n" do
        i = i + 1
      end
    elseif c == "/" and text:sub(i + 1, i + 1) == "*" then
      i = i + 2
      while i <= n and not (text:sub(i, i) == "*" and text:sub(i + 1, i + 1) == "/") do
        if text:sub(i, i) == "\n" then
          out[#out + 1] = "\n"
        end
        i = i + 1
      end
      i = i + 2
    else
      out[#out + 1] = c
      i = i + 1
    end
  end

  return table.concat(out)
end

--- Drop trailing commas before `}` or `]`, ignoring commas inside string
--- literals.
---@param text string
---@return string
function M.strip_trailing_commas(text)
  local out = {}
  local i, n = 1, #text
  local in_string = false
  local escaped = false

  while i <= n do
    local c = text:sub(i, i)

    if in_string then
      out[#out + 1] = c
      if escaped then
        escaped = false
      elseif c == "\\" then
        escaped = true
      elseif c == '"' then
        in_string = false
      end
      i = i + 1
    elseif c == '"' then
      in_string = true
      out[#out + 1] = c
      i = i + 1
    elseif c == "," then
      local j = i + 1
      while j <= n and text:sub(j, j):match("%s") do
        j = j + 1
      end
      local nextc = text:sub(j, j)
      if nextc == "}" or nextc == "]" then
        i = i + 1
      else
        out[#out + 1] = c
        i = i + 1
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end

  return table.concat(out)
end

---@param text string
---@return string
function M.strip(text)
  return M.strip_trailing_commas(M.strip_comments(text))
end

--- Read and parse a JSONC file (VS Code launch.json format: // and /* */
--- comments, trailing commas allowed).
---@param path string
---@return table|nil decoded
---@return string|nil err
function M.parse(path)
  if vim.fn.filereadable(path) == 0 then
    return nil, "file not readable: " .. path
  end

  local content = table.concat(vim.fn.readfile(path), "\n")
  local stripped = M.strip(content)

  local ok, decoded = pcall(vim.json.decode, stripped)
  if not ok then
    return nil, "failed to parse JSON in " .. path .. ": " .. tostring(decoded)
  end

  return decoded, nil
end

--- Find the Aspire launch config in a decoded launch.json.
---@param decoded table
---@param opts table|nil { name: string|nil }
---@return table|nil config single unambiguous match
---@return table|nil matches present (with 2+ entries) only when the match is ambiguous and opts.name wasn't given
function M.find_aspire_config(decoded, opts)
  opts = opts or {}

  local configs = (decoded and decoded.configurations) or {}
  local matches = {}
  for _, cfg in ipairs(configs) do
    if cfg.type == "aspire" and cfg.request == "launch" then
      matches[#matches + 1] = cfg
    end
  end

  if #matches == 0 then
    return nil, nil
  end

  if opts.name then
    for _, cfg in ipairs(matches) do
      if cfg.name == opts.name then
        return cfg, nil
      end
    end
    return nil, nil
  end

  if #matches == 1 then
    return matches[1], nil
  end

  return nil, matches
end

return M
