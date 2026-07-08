local runner = require("aspire.runner")

describe("runner.detect_dashboard_url", function()
  it("extracts the url from a real Aspire dashboard login line", function()
    local line =
      "      Login to the dashboard at https://localhost:17225/login?t=ba108c9ecd920f0bc7a0334323b80c3e"
    assert.equals("https://localhost:17225/login?t=ba108c9ecd920f0bc7a0334323b80c3e", runner.detect_dashboard_url(line))
  end)

  it("matches http as well as https", function()
    local line = "Login to the dashboard at http://localhost:15888/login?t=abc123"
    assert.equals("http://localhost:15888/login?t=abc123", runner.detect_dashboard_url(line))
  end)

  it("returns nil for unrelated log lines", function()
    assert.is_nil(runner.detect_dashboard_url("Now listening on: https://localhost:17225"))
    assert.is_nil(runner.detect_dashboard_url("Building..."))
  end)

  it("returns nil for a login-less url", function()
    assert.is_nil(runner.detect_dashboard_url("see https://aspire.dev/docs for details"))
  end)
end)
