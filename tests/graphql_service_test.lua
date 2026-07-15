--- Acceptance suite for the Python GraphQL service archetype (Strawberry + FastAPI + uv).
--- Renders the project, verifies the layout and template substitution, installs it, runs its own
--- unit suite, then boots the real service and proves the GraphQL endpoint answers queries and
--- mutations over the wire, plus the management sidecar (health probes + Prometheus metrics).
---
--- The default configuration weaves in no resources (persistence/cache/messaging = None): the
--- resolvers return their empty/echo stubs. The persistence variants (PostgreSQL/MySQL) render the
--- sample Item scaffold behind persisted resolvers, boot against a real database container, and
--- prove GraphQL CRUD mutations round-trip into that database. This suite defines the archetype's
--- acceptance bar — its job is to fill the gaps and keep them filled.
---
--- The static tier reads the rendered tree with no toolchain; the build and live tiers require
--- `uv` (which provisions Python) and skip cleanly without it; the CRUD tiers additionally
--- require docker.
---
--- Run from the archetype repo root (uses ./prova.toml):   prova

local postgres = require("postgres")
local mysql    = require("mysql")

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

local function answers_with(extra)
  local out = {}
  for k, v in pairs(ANSWERS) do out[k] = v end
  for k, v in pairs(extra) do out[k] = v end
  return out
end

-- prefix Example / suffix Service => project dir `example-service`, package `example_service`.
-- Strawberry lowers snake_case resolver names to camelCase: `example` / `examples` /
-- `createExample` / `updateExample` / `deleteExample`, argument `display_name` -> `displayName`.
local PROJECT_DIR = "example-service"

local CREATE = [[mutation($name: String!) { createExample(displayName: $name) { id displayName } }]]
local GET    = [[query($id: String!) { example(id: $id) { id displayName } }]]
local LIST   = [[{ examples { id displayName } }]]
local UPDATE = [[mutation($id: String!, $name: String!) { updateExample(id: $id, displayName: $name) { id displayName } }]]
local DELETE = [[mutation($id: String!) { deleteExample(id: $id) }]]

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

-- Files the persistence scaffold must produce (relative to the rendered project root):
-- the archetype's sample entity and the resource library's wiring.
local SCAFFOLD_FILES = {
  "src/example_service/domain/items.py",
  "src/example_service/persistence/__init__.py",
  "src/example_service/persistence/models.py",
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
-- The management sidecar answers before the service lifespan finishes, so readiness is gated on
-- BOTH the sidecar's liveness AND the GraphQL endpoint answering a real query.
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
  local api = graphql.client{ url = "http://127.0.0.1:" .. port .. "/graphql" }
  prova.retry(function() return api:query(LIST) end,
    { timeout = "60s", message = "graphql endpoint never became ready" })
  return { api = api, service_url = "http://127.0.0.1:" .. port, mgmt_url = mgmt_url }
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

  g:test("the hollow rendering stays hollow: no persistence scaffold", function(t)
    local root = t:use(project).path
    t:expect_all(function()
      for _, f in ipairs(SCAFFOLD_FILES) do
        t:expect(fs.exists(root .. "/" .. f), f .. " absent"):is_false()
      end
    end)
    -- The stub schema exposes no persisted mutations either.
    local schema = fs.read(root .. "/src/example_service/schema.py")
    t:expect(schema, "no update mutation in the stub schema"):never():contains("update_example")
    t:expect(schema, "no delete mutation in the stub schema"):never():contains("delete_example")
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
-- sidecar answers real requests. The hollow resolvers stay hollow: empty list, echo create.
prova.group("python-graphql endpoints", { requires = { "uv" } }, function(g)
  g:test("the GraphQL list query returns the empty stub", function(t)
    local svc = t:use(service)
    -- The unresolved `examples` query returns [] (no persistence woven in the default config).
    local data = svc.api:query(LIST)
    t:expect(#data.examples, "examples is an empty list"):equals(0)
  end)

  g:test("the GraphQL mutation echoes its input", function(t)
    local svc = t:use(service)
    local created = svc.api:query(CREATE, { name = "widget" }).createExample
    t:expect(created.displayName, "mutation echoes displayName"):equals("widget")
    t:expect(created.id, "stub id stays empty"):equals("")
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

-- Persistence variants: render with a real database backend, verify the scaffold, boot the
-- service against a database container, and prove GraphQL CRUD mutations round-trip into that
-- database. One entry per rendering variant. `db` is the container recipe namespace; the SQL
-- strings carry each backend's placeholder syntax (the scaffold uses snake_case identifiers,
-- lowercase tables).
local VARIANTS = {
  {
    persistence = "PostgreSQL",
    db = postgres,
    db_port = 5432,
    count_by_name = [[SELECT count(*) FROM items WHERE display_name = $1]],
  },
  {
    persistence = "MySQL",
    db = mysql,
    db_port = 3306,
    count_by_name = "SELECT count(*) FROM items WHERE display_name = ?",
  },
}

for _, v in ipairs(VARIANTS) do
  local label = "python-graphql[" .. v.persistence .. "]"

  -- a) render — one fixture per variant, shared by verify and the black-box tests.
  local variant_project = prova.fixture(label .. ":project", Scope.File, function(ctx)
    return archetect.render{
      source = SRC,
      answers = answers_with{ persistence = v.persistence },
      destination = ctx:tempdir(),
      defaults = true,
    }
  end)

  -- b) verify — layout, fully-rendered, and build checks against that rendering.
  archetect.verify(variant_project, {
    name = label,
    project_dir = PROJECT_DIR,
    expected_files = {
      "pyproject.toml",
      "src/example_service/main.py",
      "src/example_service/schema.py",
      "src/example_service/settings.py",
      SCAFFOLD_FILES[1], SCAFFOLD_FILES[2], SCAFFOLD_FILES[3],
      ".github/workflows/build.yaml",
    },
    yaml_globs = { ".platform/kubernetes/**/*.yaml" },
    requires = { "uv" },
    build_steps = { "uv sync --group dev", "uv run pytest -q" },
  })

  -- c) black-box — provision the database, boot the installed service against it.
  local variant_service = prova.fixture(label .. ":service", Scope.File, function(ctx)
    local root = ctx:use(variant_project):dir(PROJECT_DIR)
    local db = v.db.container(ctx)

    local sync = shell.run("uv sync --group dev", { cwd = root.path, timeout = "300s" })
    assert(sync:ok(), label .. " uv sync failed:\n" .. sync.stderr .. sync.stdout)

    local port, mgmt = net.free_port(), net.free_port()
    ctx:manage(shell.spawn("uv run " .. PROJECT_DIR, {
      cwd = root.path,
      env = {
        -- pydantic-settings binds UPPER_SNAKE env vars onto the Settings fields.
        HOST            = "127.0.0.1",
        PORT            = tostring(port),
        MANAGEMENT_PORT = tostring(mgmt),
        DB_HOST         = "127.0.0.1",
        DB_PORT         = tostring(db.container:host_port(v.db_port)),
        DB_USERNAME     = "prova",
        DB_PASSWORD     = "prova",
        DB_DBNAME       = "prova",
      },
    }))

    -- The management sidecar proves the process is up; the GraphQL endpoint only answers after
    -- the lifespan (init_db + ensure_schema) succeeded against the database.
    http.wait_for("http://127.0.0.1:" .. mgmt .. "/health/liveness", { timeout = "60s" })
    local api = graphql.client{ url = "http://127.0.0.1:" .. port .. "/graphql" }
    prova.retry(function() return api:query(LIST) end,
      { timeout = "60s", message = label .. " graphql endpoint never became ready" })
    return { api = api, db = db.client }
  end)

  prova.group(label .. " CRUD round-trip", { requires = { "docker", "uv" } }, function(g)
    g:test("created entities land in " .. v.persistence, function(t)
      local svc = t:use(variant_service)

      -- Create through the public API...
      local created = svc.api:query(CREATE, { name = "widget" }).createExample
      t:expect(created.displayName):equals("widget")
      t:expect(created.id, "created id"):is_truthy()

      -- ...and prove the row exists in the actual database, not just the API's memory.
      t:expect(svc.db:query_value(v.count_by_name, { "widget" }), "rows in DB"):equals(1)

      -- Read back through every door (the old stub returned nil / an empty list).
      local fetched = svc.api:query(GET, { id = created.id }).example
      t:expect(fetched.displayName):equals("widget")

      local listed = svc.api:query(LIST).examples
      local found = false
      for _, e in ipairs(listed or {}) do
        if e.id == created.id then found = true end
      end
      t:expect(found, "created entity present in examples"):is_true()
    end)

    g:test("updates and deletes round-trip into " .. v.persistence, function(t)
      local svc = t:use(variant_service)

      local created = svc.api:query(CREATE, { name = "ephemeral" }).createExample

      local updated = svc.api:query(UPDATE, { id = created.id, name = "renamed" }).updateExample
      t:expect(updated.displayName):equals("renamed")
      t:expect(svc.db:query_value(v.count_by_name, { "renamed" }), "renamed row in DB"):equals(1)
      t:expect(svc.db:query_value(v.count_by_name, { "ephemeral" }), "old name gone"):equals(0)

      t:expect(svc.api:query(DELETE, { id = created.id }).deleteExample, "delete reports true"):is_true()
      local gone = svc.api:query(GET, { id = created.id }).example
      t:expect(gone):is_nil()
      t:expect(svc.db:query_value(v.count_by_name, { "renamed" }), "row deleted from DB"):equals(0)
    end)
  end)
end
