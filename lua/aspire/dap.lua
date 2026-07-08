local M = {}

--- Parse `ps -Ao pid,ppid,command` output into structured entries.
--- Lines that don't match "<pid> <ppid> <command>" (the header row,
--- blank lines) are skipped.
---@param raw string
---@return { pid: integer, ppid: integer, command: string }[]
function M.parse_ps_output(raw)
  local entries = {}
  for line in raw:gmatch("[^\n]+") do
    local pid, ppid, command = line:match("^%s*(%d+)%s+(%d+)%s+(.*)$")
    if pid then
      entries[#entries + 1] = {
        pid = tonumber(pid),
        ppid = tonumber(ppid),
        command = command,
      }
    end
  end
  return entries
end

--- Collect every descendant pid of `root_pid` from parsed ps entries.
---@param entries { pid: integer, ppid: integer, command: string }[]
---@param root_pid integer
---@return integer[]
function M.build_tree(entries, root_pid)
  local children_by_ppid = {}
  for _, e in ipairs(entries) do
    children_by_ppid[e.ppid] = children_by_ppid[e.ppid] or {}
    table.insert(children_by_ppid[e.ppid], e.pid)
  end

  local descendants = {}
  local frontier = { root_pid }
  while #frontier > 0 do
    local pid = table.remove(frontier)
    for _, child in ipairs(children_by_ppid[pid] or {}) do
      descendants[#descendants + 1] = child
      frontier[#frontier + 1] = child
    end
  end
  return descendants
end

return M
