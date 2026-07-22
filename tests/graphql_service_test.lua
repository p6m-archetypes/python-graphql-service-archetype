--- Render-verification suite for the Python GraphQL service archetype: each persistence variant
--- lays out correctly and is fully rendered, and the hollow (None) rendering stays hollow —
--- including its schema, which must expose no persisted mutations.
---
--- The BEHAVIORAL bar — CRUD through the production image, the platform env contract, health/
--- metrics/structured logs, both name shapes — lives in tests/standards_test.lua (the shared
--- p6m standards suite), fully containerized: docker is the only requirement. The `build_steps`
--- here are gated on host `uv` and skip cleanly where it's absent.
---
--- Run from the archetype repo root (uses ./prova.toml):   prova

local SRC = "."

-- prefix Example / suffix Service => project dir `example-service`, package `example_service`.
local PROJECT_DIR = "example-service"

local BASE_ANSWERS = {
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
  for k, v in pairs(BASE_ANSWERS) do out[k] = v end
  for k, v in pairs(extra) do out[k] = v end
  return out
end

-- Files the persistence scaffold must produce (relative to the rendered project root):
-- the archetype's sample entity and the resource library's wiring.
local SCAFFOLD_FILES = {
  "src/example_service/domain/items.py",
  "src/example_service/persistence/__init__.py",
  "src/example_service/persistence/models.py",
}

for _, persistence in ipairs({ "PostgreSQL", "MySQL" }) do
  local label = "python-graphql[" .. persistence .. "]"

  local project = prova.fixture(label .. ":project", Scope.File, function(ctx)
    return archetect.render{
      source = SRC,
      answers = answers_with{ persistence = persistence },
      destination = ctx:tempdir(),
      defaults = true,
    }
  end)

  archetect.verify(project, {
    name = label,
    project_dir = PROJECT_DIR,
    expected_files = {
      "pyproject.toml",
      ".python-version",
      ".dockerignore",
      "src/example_service/__init__.py",
      "src/example_service/main.py",
      "src/example_service/router.py",
      "src/example_service/schema.py",
      "src/example_service/management.py",
      "src/example_service/settings.py",
      "tests/test_health.py",
      SCAFFOLD_FILES[1], SCAFFOLD_FILES[2], SCAFFOLD_FILES[3],
      ".github/workflows/build.yaml",
      ".platform/docker/local/Dockerfile",
      ".platform/docker/prd/Dockerfile",
    },
    yaml_globs = { ".platform/kubernetes/**/*.yaml" },
    requires = { "uv" },
    build_steps = { "uv sync --group dev", "uv run pytest -q" },
  })
end

-- The hollow rendering stays hollow: no persistence, no scaffold files, and a stub schema that
-- exposes no persisted mutations.
local hollow = prova.fixture("python-graphql[None]:project", Scope.File, function(ctx)
  return archetect.render{
    source = SRC,
    answers = answers_with{ persistence = "None" },
    destination = ctx:tempdir(),
    defaults = true,
  }
end)

archetect.verify(hollow, {
  name = "python-graphql[None]",
  project_dir = PROJECT_DIR,
  expected_files = {
    "pyproject.toml",
    "src/example_service/main.py",
    "src/example_service/schema.py",
    "src/example_service/settings.py",
  },
  absent_files = SCAFFOLD_FILES,
  yaml_globs = { ".platform/kubernetes/**/*.yaml" },
  requires = { "uv" },
  build_steps = { "uv sync --group dev", "uv run pytest -q" },
})

prova.group("python-graphql[None] stub schema", function(g)
  g:test("exposes no persisted mutations", function(t)
    local root = t:use(hollow):dir(PROJECT_DIR).path
    local schema = fs.read(root .. "/src/example_service/schema.py")
    t:expect(schema, "no update mutation in the stub schema"):never():contains("update_example")
    t:expect(schema, "no delete mutation in the stub schema"):never():contains("delete_example")
  end)
end)
