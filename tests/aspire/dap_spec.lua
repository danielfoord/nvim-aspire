local dap = require("aspire.dap")

-- Modeled on real output observed launching a .NET Aspire sample app:
-- dotnet run (2045) -> AppHost binary (2194) -> per-service dotnet
-- processes (2300, 2301), one of which (2300) has its own child (2400).
-- 2019/1/9999 are unrelated processes that must never show up as
-- descendants of 2045.
local PS_OUTPUT = [[
  PID  PPID COMMAND
    1     0 /sbin/launchd
 2019     1 -zsh
 2045  2019 dotnet run --project /repo/Sample.AppHost/Sample.AppHost.csproj
 2194  2045 /repo/Sample.AppHost/bin/Debug/net9.0/Sample.AppHost
 2300  2194 dotnet exec /repo/Sample.ApiService/bin/Debug/net9.0/Sample.ApiService.dll
 2301  2194 dotnet exec /repo/Sample.Web/bin/Debug/net9.0/Sample.Web.dll
 2400  2300 dotnet exec /repo/Sample.Worker/bin/Debug/net9.0/Sample.Worker.dll
 9999     1 /usr/sbin/some-unrelated-daemon
]]

local function sorted(t)
  local copy = vim.deepcopy(t)
  table.sort(copy)
  return copy
end

-- Captured verbatim from `ps -Ao pid,ppid,command` while a real
-- `dotnet new aspire-starter` app was running: the AppHost wrapper
-- (20486) spawns the AppHost orchestrator binary (20781), which starts
-- Aspire's DCP controller (20876), which spawns the dashboard (20886)
-- and one "dotnet run --no-build" wrapper per service (20884, 20938),
-- each of which execs the real compiled service binary (20900, 20979).
local REAL_ASPIRE_PS_OUTPUT = [[
  PID  PPID COMMAND
20486 20456 dotnet run --project /repo/Sample.AppHost/Sample.AppHost.csproj
20781 20486 /repo/Sample.AppHost/bin/Debug/net9.0/Sample.AppHost
20876 20833 /Users/daniel/.nuget/packages/aspire.hosting.orchestration.osx-arm64/9.3.1/tools/ext/dcpctrl run-controllers --kubeconfig /tmp/aspire.zZ7ZLf/kubeconfig --monitor 20833
20884 20876 dotnet run --no-build --project /repo/Sample.ApiService/Sample.ApiService.csproj -c Debug --no-launch-profile
20886 20876 dotnet /Users/daniel/.nuget/packages/aspire.dashboard.sdk.osx-arm64/9.3.1/tools/Aspire.Dashboard.dll
20900 20884 /repo/Sample.ApiService/bin/Debug/net9.0/Sample.ApiService
20938 20876 dotnet run --no-build --project /repo/Sample.Web/Sample.Web.csproj -c Debug --no-launch-profile
20979 20938 /repo/Sample.Web/bin/Debug/net9.0/Sample.Web
]]

describe("dap.parse_ps_output", function()
  it("parses pid, ppid, and command from each row", function()
    local entries = dap.parse_ps_output(PS_OUTPUT)
    local by_pid = {}
    for _, e in ipairs(entries) do
      by_pid[e.pid] = e
    end

    assert.equals(2019, by_pid[2045].ppid)
    assert.equals("dotnet run --project /repo/Sample.AppHost/Sample.AppHost.csproj", by_pid[2045].command)
  end)

  it("skips the header row", function()
    local entries = dap.parse_ps_output(PS_OUTPUT)
    for _, e in ipairs(entries) do
      assert.is_number(e.pid)
    end
  end)

  it("returns an empty list for empty input", function()
    assert.same({}, dap.parse_ps_output(""))
  end)
end)

describe("dap.build_tree", function()
  it("collects every descendant across multiple levels", function()
    local entries = dap.parse_ps_output(PS_OUTPUT)
    local descendants = dap.build_tree(entries, 2045)
    assert.same({ 2194, 2300, 2301, 2400 }, sorted(descendants))
  end)

  it("excludes unrelated processes and ancestors", function()
    local entries = dap.parse_ps_output(PS_OUTPUT)
    local descendants = dap.build_tree(entries, 2045)
    for _, pid in ipairs(descendants) do
      assert.is_not.equal(2019, pid)
      assert.is_not.equal(1, pid)
      assert.is_not.equal(9999, pid)
      assert.is_not.equal(2045, pid)
    end
  end)

  it("returns only the direct subtree for a deeper root", function()
    local entries = dap.parse_ps_output(PS_OUTPUT)
    local descendants = dap.build_tree(entries, 2300)
    assert.same({ 2400 }, sorted(descendants))
  end)

  it("returns an empty list for a pid with no children", function()
    local entries = dap.parse_ps_output(PS_OUTPUT)
    assert.same({}, dap.build_tree(entries, 2400))
  end)

  it("returns an empty list when root_pid is not in entries", function()
    local entries = dap.parse_ps_output(PS_OUTPUT)
    assert.same({}, dap.build_tree(entries, 424242))
  end)
end)

-- The same real Aspire process tree, as it would be reported by
-- Win32_Process.CommandLine on Windows: backslash separators, .exe
-- extensions on compiled binaries, no leading slash (drive letter).
local WINDOWS_ASPIRE_PS_OUTPUT = table.concat({
  [[20486|20456|dotnet run --project C:\repo\Sample.AppHost\Sample.AppHost.csproj]],
  [[20781|20486|C:\repo\Sample.AppHost\bin\Debug\net9.0\Sample.AppHost.exe]],
  [[20884|20876|dotnet run --no-build --project C:\repo\Sample.ApiService\Sample.ApiService.csproj -c Debug --no-launch-profile]],
  [[20900|20884|C:\repo\Sample.ApiService\bin\Debug\net9.0\Sample.ApiService.exe]],
  [[20938|20876|dotnet run --no-build --project C:\repo\Sample.Web\Sample.Web.csproj -c Debug --no-launch-profile]],
  [[20979|20938|C:\repo\Sample.Web\bin\Debug\net9.0\Sample.Web.exe]],
}, "\r\n")

describe("dap.parse_powershell_output", function()
  it("parses pid, ppid, and command from pipe-delimited lines", function()
    local entries = dap.parse_powershell_output(WINDOWS_ASPIRE_PS_OUTPUT)
    local by_pid = {}
    for _, e in ipairs(entries) do
      by_pid[e.pid] = e
    end

    assert.equals(20456, by_pid[20486].ppid)
    assert.equals([[dotnet run --project C:\repo\Sample.AppHost\Sample.AppHost.csproj]], by_pid[20486].command)
  end)

  it("returns an empty list for empty input", function()
    assert.same({}, dap.parse_powershell_output(""))
  end)

  it("handles CRLF line endings", function()
    local entries = dap.parse_powershell_output("1|0|foo\r\n2|1|bar\r\n")
    assert.equals(2, #entries)
  end)
end)

describe("dap.filter_services (Windows-style paths)", function()
  local entries = dap.parse_powershell_output(WINDOWS_ASPIRE_PS_OUTPUT)
  local workspace_root = [[C:\repo]]
  local apphost_dir = [[C:\repo\Sample.AppHost]]

  it("finds exactly the two real service binaries despite backslash separators", function()
    local services = dap.filter_services(entries, workspace_root, apphost_dir)
    local pids = {}
    for _, s in ipairs(services) do
      pids[#pids + 1] = s.pid
    end
    assert.same({ 20900, 20979 }, sorted(pids))
  end)

  it("excludes the AppHost orchestrator binary itself", function()
    local services = dap.filter_services(entries, workspace_root, apphost_dir)
    for _, s in ipairs(services) do
      assert.is_not.equal(20781, s.pid)
    end
  end)
end)

describe("dap.resolve_name", function()
  it("derives the project name from a macOS/Linux-style path", function()
    assert.equals("Sample.ApiService", dap.resolve_name("/repo/Sample.ApiService/bin/Debug/net9.0/Sample.ApiService"))
  end)

  it("derives the project name from a Windows-style path with .exe", function()
    assert.equals(
      "Sample.ApiService",
      dap.resolve_name([[C:\repo\Sample.ApiService\bin\Debug\net9.0\Sample.ApiService.exe]])
    )
  end)

  it("falls back to the raw command when the shape doesn't match", function()
    assert.equals("some random command", dap.resolve_name("some random command"))
  end)
end)

describe("dap.filter_services (real Aspire process tree)", function()
  local entries = dap.parse_ps_output(REAL_ASPIRE_PS_OUTPUT)
  local workspace_root = "/repo"
  local apphost_dir = "/repo/Sample.AppHost"

  it("finds exactly the two real service binaries", function()
    local services = dap.filter_services(entries, workspace_root, apphost_dir)
    local pids = {}
    for _, s in ipairs(services) do
      pids[#pids + 1] = s.pid
    end
    assert.same({ 20900, 20979 }, sorted(pids))
  end)

  it("excludes the AppHost orchestrator binary itself", function()
    local services = dap.filter_services(entries, workspace_root, apphost_dir)
    for _, s in ipairs(services) do
      assert.is_not.equal(20781, s.pid)
    end
  end)

  it("excludes dotnet run wrapper processes and the DCP controller", function()
    local services = dap.filter_services(entries, workspace_root, apphost_dir)
    for _, s in ipairs(services) do
      assert.is_not.equal(20884, s.pid)
      assert.is_not.equal(20938, s.pid)
      assert.is_not.equal(20876, s.pid)
    end
  end)

  it("excludes the Aspire dashboard process", function()
    local services = dap.filter_services(entries, workspace_root, apphost_dir)
    for _, s in ipairs(services) do
      assert.is_not.equal(20886, s.pid)
    end
  end)

  it("excludes processes outside workspace_root", function()
    local services = dap.filter_services(entries, "/some/other/root", apphost_dir)
    assert.same({}, services)
  end)
end)
