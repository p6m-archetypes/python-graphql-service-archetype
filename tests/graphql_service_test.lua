--- Acceptance suite for the Python GraphQL service archetype (Strawberry + FastAPI + uv).
--- Renders the project, verifies the layout and template substitution, installs it, runs its own
--- unit suite, then boots the real service and proves the GraphQL endpoint answers queries and
--- mutations over the wire, plus the management sidecar (health probes + Prometheus metrics).
---
--- The default configuration weaves in no resources (persistence/cache/messaging = None), so there
--- is a single variant - the resolvers return their empty/echo stubs. The GraphQL API is served by
--- Strawberry's GraphQLRouter mounted at /graphql; a management sidecar runs on a second port.
---
--- prova's in-process archetect engine renders once per run (prova.toml pins jobs = 1), so the whole
--- suite shares a single rendered tree (the `project` fixture). The static tier reads it with no
--- toolchain; the build and live tiers require `uv` and skip cleanly without it.
---
--- Run from the archetype repo root (uses ./prova.toml):   prova

local SRC = "."

local ANSWERS = {
  author_name    = "Test Author",
  author_email   = "test@example.com",
  org_name       = "acme",
  solution_name  = "platform",
  prefix_name    = "Example",
  suffix_name    = "Service",
  image_registry = "ghcr.io/acme",
}

-- prefix Example / suffix Service => project dir `example-service`, package `example_service`.
-- Strawberry lowers snake_case resolver names to camelCase: `examples` / `createExample`.
local PROJECT_DIR = "example-service"

local EXPECTED_FILES = {
  "pyproject.toml",
  ".python-version",
  "src/example_service/__init__.py",
  "src/example_service/main.py",
  "src/example_service/router.py",
  "src/example_service/schema.py",
  "src/example_service/management.py",
  "src/example_service/settings.py",
  "tests/test_health.py",
  ".github/workflows/build.yaml",
  ".platform/docker/local/Dockerfile",
  ".platform/docker/prd/Dockerfile",
}

-- Render once for the whole suite (single in-process render; every tier shares this one tree).
local project = prova.fixture("python-graphql:project", Scope.Suite, function(ctx)
  local tree = archetect.render{
    source = SRC,
    answers = ANSWERS,
    destination = ctx:tempdir(),
    defaults = true,
  }
  return tree:dir(PROJECT_DIR)
end)

-- Install once (shared by the build tier and the live-service fixture). Only reached from uv-gated
-- groups, so `uv` is guaranteed present here.
local installed = prova.fixture("python-graphql:installed", Scope.Suite, function(ctx)
  local root = ctx:use(project)
  local sync = shell.run("uv sync --group dev", { cwd = root.path, timeout = "300s" })
  assert(sync:ok(), "uv sync failed:\n" .. sync.stderr .. sync.stdout)
  return root
end)

-- Boot the rendered service on free ports (HOST/PORT/MANAGEMENT_PORT come from pydantic settings).
-- Waiting on the management sidecar's /health/liveness proves both uvicorn servers came up.
local service = prova.fixture("python-graphql:service", Scope.Suite, function(ctx)
  local root = ctx:use(installed)

  local port, mgmt = net.free_port(), net.free_port()
  ctx:manage(shell.spawn("uv run " .. PROJECT_DIR, {
    cwd = root.path,
    env = {
      HOST            = "127.0.0.1",
      PORT            = tostring(port),
      MANAGEMENT_PORT = tostring(mgmt),
    },
  }))

  local mgmt_url = "http://127.0.0.1:" .. mgmt
  http.wait_for(mgmt_url .. "/health/liveness", { timeout = "60s" })
  return { service_url = "http://127.0.0.1:" .. port, mgmt_url = mgmt_url }
end)

-- Tier 1 - static: layout, template substitution, and generated k8s manifests. No toolchain.
prova.group("python-graphql layout", function(g)
  g:test("scaffolds the expected project layout", function(t)
    local root = t:use(project).path
    t:expect_all(function()
      for _, f in ipairs(EXPECTED_FILES) do
        t:expect(fs.exists(root .. "/" .. f), f):is_true()
      end
    end)
  end)

  g:test("wires prefix/suffix and ports through file contents", function(t)
    local root = t:use(project).path
    -- {{ PrefixName }}{{ SuffixName }} -> ExampleService in the app title.
    t:expect(fs.read(root .. "/src/example_service/main.py"), "app title"):contains("ExampleService")
    -- The GraphQL type derives from PrefixName; the router mounts the schema at /graphql.
    t:expect(fs.read(root .. "/src/example_service/schema.py"), "GraphQL type"):contains("class Example")
    t:expect(fs.read(root .. "/src/example_service/router.py"), "GraphQL mount"):contains("/graphql")
    -- service-port + derived management-port land in settings.
    local settings = fs.read(root .. "/src/example_service/settings.py")
    t:expect(settings, "service port"):contains("port: int = 8080")
    t:expect(settings, "management port"):contains("management_port: int = 8081")
  end)

  g:test("renders valid, non-empty kubernetes manifests", function(t)
    local root = t:use(project).path
    local manifests = fs.glob(root, ".platform/kubernetes/**/*.yaml")
    t:expect(#manifests > 0, "at least one k8s manifest"):is_true()
    t:expect_all(function()
      for _, m in ipairs(manifests) do
        local docs = yaml.parse_all(fs.read(m))
        t:expect(#docs > 0, m .. " has ≥1 document"):is_true()
      end
    end)
  end)

  g:test("leaves no unrendered template markers", function(t)
    t:expect(t:use(project)):is_fully_rendered()
  end)
end)

-- Tier 2 - build + unit: the generated project's own pytest suite passes.
prova.group("python-graphql build + unit tests", { requires = { "uv" } }, function(g)
  g:test("the generated pytest suite passes", function(t)
    local root = t:use(installed).path
    local pytest = shell.run("uv run pytest -q", { cwd = root, timeout = "180s" })
    t:expect(pytest.code, "pytest exit code"):equals(0)
    t:expect(pytest.stdout .. pytest.stderr, "pytest reports a passing suite"):contains("passed")
  end)
end)

-- Tier 3 - live GraphQL: the running service answers real queries and mutations, and the management
-- sidecar answers real requests.
prova.group("python-graphql endpoints", { requires = { "uv" } }, function(g)
  g:test("the GraphQL list query returns the empty stub", function(t)
    local svc = t:use(service)
    local client = graphql.client{ url = svc.service_url .. "/graphql" }
    -- The unresolved `examples` query returns [] (no persistence woven in the default config).
    local data = client:query("{ examples { id displayName } }")
    t:expect(#data.examples, "examples is an empty list"):equals(0)
  end)

  g:test("the GraphQL mutation echoes its input", function(t)
    local svc = t:use(service)
    local client = graphql.client{ url = svc.service_url .. "/graphql" }
    local data = client:query(
      'mutation { createExample(displayName: "widget") { id displayName } }'
    )
    t:expect(data.createExample.displayName, "mutation echoes displayName"):equals("widget")
  end)

  g:test("the management sidecar reports readiness and liveness", function(t)
    local svc = t:use(service)

    local ready = http.get(svc.mgmt_url .. "/health/readiness")
    t:expect(ready.status, "readiness status code"):equals(200)
    t:expect(ready:json().status, "readiness body"):equals("ok")

    local live = http.get(svc.mgmt_url .. "/health/liveness")
    t:expect(live.status, "liveness status code"):equals(200)
    t:expect(live:json().status, "liveness body"):equals("ok")
  end)

  g:test("the management sidecar exposes Prometheus metrics", function(t)
    local svc = t:use(service)
    -- /metrics 307-redirects to /metrics/; hit the canonical path directly.
    local r = http.get(svc.mgmt_url .. "/metrics/")
    t:expect(r.status, "metrics status code"):equals(200)
    t:expect(r.body, "Prometheus exposition format"):contains("# HELP")
  end)
end)
