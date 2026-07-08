local discovery = require("aspire.discovery")

local fixtures_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/fixtures/discovery"

describe("discovery.find_apphost", function()
  it("uses the hint directly when it already points at a .csproj", function()
    local root = fixtures_dir .. "/direct"
    local hint = root .. "/MyApp.AppHost/MyApp.AppHost.csproj"
    local path, candidates = discovery.find_apphost(root, hint)
    assert.is_nil(candidates)
    assert.equals(hint, path)
  end)

  it("prefers a project named *.AppHost.csproj among siblings", function()
    local root = fixtures_dir .. "/named"
    local path, candidates = discovery.find_apphost(root, nil)
    assert.is_nil(candidates)
    assert.equals(root .. "/MyApp.AppHost/MyApp.AppHost.csproj", path)
  end)

  it("falls back to a project referencing Aspire.Hosting when none is named *.AppHost", function()
    local root = fixtures_dir .. "/hosting_ref"
    local path, candidates = discovery.find_apphost(root, nil)
    assert.is_nil(candidates)
    assert.equals(root .. "/Orchestrator/Orchestrator.csproj", path)
  end)

  it("returns ambiguous candidates when multiple projects are named *.AppHost.csproj", function()
    local root = fixtures_dir .. "/ambiguous"
    local path, candidates = discovery.find_apphost(root, nil)
    assert.is_nil(path)
    assert.equals(2, #candidates)
  end)

  it("returns nil, nil when no .csproj files exist under root", function()
    local root = fixtures_dir .. "/none"
    local path, candidates = discovery.find_apphost(root, nil)
    assert.is_nil(path)
    assert.is_nil(candidates)
  end)

  it("returns the only candidate when there is exactly one .csproj and no heuristic match", function()
    local root = fixtures_dir .. "/single"
    local path, candidates = discovery.find_apphost(root, nil)
    assert.is_nil(candidates)
    assert.equals(root .. "/OnlyProject/OnlyProject.csproj", path)
  end)

  it("scopes the search to a hint directory rather than the whole root", function()
    local root = fixtures_dir .. "/hinted"
    local hint = root .. "/Sub"
    local path, candidates = discovery.find_apphost(root, hint)
    assert.is_nil(candidates)
    assert.equals(root .. "/Sub/App.AppHost/App.AppHost.csproj", path)
  end)
end)
