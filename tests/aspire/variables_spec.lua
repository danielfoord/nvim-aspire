local variables = require("aspire.variables")

describe("variables.resolve", function()
  it("substitutes ${workspaceFolder}", function()
    local out = variables.resolve("${workspaceFolder}/AppHost", { workspaceFolder = "/repo" })
    assert.equals("/repo/AppHost", out)
  end)

  it("leaves unknown variables untouched", function()
    local out = variables.resolve("${workspaceFolderBasename}/x", { workspaceFolder = "/repo" })
    assert.equals("${workspaceFolderBasename}/x", out)
  end)

  it("passes through strings with no variables", function()
    local out = variables.resolve("plain/path", { workspaceFolder = "/repo" })
    assert.equals("plain/path", out)
  end)

  it("returns nil unchanged", function()
    assert.is_nil(variables.resolve(nil, { workspaceFolder = "/repo" }))
  end)

  it("handles a missing ctx", function()
    local out = variables.resolve("${workspaceFolder}/x")
    assert.equals("${workspaceFolder}/x", out)
  end)
end)
