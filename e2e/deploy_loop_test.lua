--- Live deploy-loop proof for this archetype. The loop itself - render, push, watch Build, capture
--- the release digest, verify the .platform dispatch, then ArgoCD app appears -> Synced/Healthy ->
--- Deployment Healthy -> pods run the built digest -> pods stay Running - is the reusable `deploy`
--- plugin (../prova-p6m-deploy-loop). This file only supplies this archetype's answers.
---
--- SEPARATE FROM THE ACCEPTANCE SUITE (tests/): e2e/ is not in the default proofs, so a bare `prova`
--- never runs it. Run it on its own with `prova -p e2e` (or `prova e2e`). The flow `requires` the
--- live-infra CLIs (archetect/gh/git/argocd), so it skips cleanly on a runner that lacks them.
---
--- Operational knobs come from the environment (see e2e/README.md) via deploy.from_env; teardown
--- runs at the end whether the flow passed, failed, or skipped - unless KEEP_RESOURCES is set.

local deploy = require("deploy")

local function env(name, default)
  local v = os.getenv(name)
  if v == nil or v == "" then return default end
  return v
end

-- Identity the generated CI + ArgoCD naming line up with (override via env for other targets).
local org = env("ORG_NAME", "ybor")
local solution = env("SOLUTION_NAME", "playground")


local cfg = deploy.resolve(deploy.from_env{
  archetype_dir = ".",   -- render this repo's current code
  answers = {
    author_name      = "Archetype E2E",
    author_email     = "e2e@ybor.ai",
    org_name         = org,
    solution_name    = solution,
    prefix_name      = "Example",   -- overridden per run by the plugin for a unique repo name
    suffix_name      = "Service",
    image_registry   = "p6m.jfrog.io",
    persistence      = "None",
    cache            = "None",
    messaging        = "None",
    object_storage   = {},
  },
})

-- The shared, flow-scoped run state (+ guaranteed teardown at flow end).
local run = deploy.new_run(cfg, "deploy-loop")

prova.flow("deploy-loop", {
  requires = cfg.requires,   -- archetect/gh/git/argocd; missing => skip cleanly
  tags = { "e2e" },
  serial = true,             -- one loop at a time (shared ArgoCD + .platform repo)
  timeout = cfg.flow_timeout,
}, function(f)
  deploy.step(f, run, "preflight")           -- tools & tokens verified
  deploy.step(f, run, "render")              -- archetect render (assert full-loop CI)
  deploy.step(f, run, "push")                -- create GitHub repo + push
  deploy.step(f, run, "build")               -- Build workflow kicked off + successful
  deploy.step(f, run, "release")             -- git tag + release; capture the image digest
  deploy.step(f, run, "platform")            -- .platform manifest updated with the digest
  deploy.step(f, run, "argo_appears")        -- ArgoCD application appears (5 min)
  deploy.step(f, run, "argo_healthy")        -- application Synced + Healthy
  deploy.step(f, run, "deployment_healthy")  -- Deployment Healthy (3 min)
  deploy.step(f, run, "digest_deployed")     -- deployed pods run the built digest
  deploy.step(f, run, "pods_stable")         -- pods stay Running (30 s)
end)