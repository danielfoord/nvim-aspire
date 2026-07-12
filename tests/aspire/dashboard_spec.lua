local dashboard = require("aspire.dashboard")

describe("dashboard.format_services", function()
  it("aligns names to the longest one and includes pid and command", function()
    local lines = dashboard.format_services({
      { name = "Sample.ApiService", pid = 100, cmd = "/repo/Sample.ApiService/bin/Debug/net9.0/Sample.ApiService" },
      { name = "Sample.Web", pid = 2, cmd = "/repo/Sample.Web/bin/Debug/net9.0/Sample.Web" },
    })

    assert.equals(2, #lines)
    assert.equals(
      "Sample.ApiService  pid 100      /repo/Sample.ApiService/bin/Debug/net9.0/Sample.ApiService",
      lines[1]
    )
    assert.equals("Sample.Web         pid 2        /repo/Sample.Web/bin/Debug/net9.0/Sample.Web", lines[2])
  end)

  it("returns an empty list for no services", function()
    assert.same({}, dashboard.format_services({}))
  end)
end)
