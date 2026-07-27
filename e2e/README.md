# e2e - live deploy-loop proof

`e2e/deploy_loop_test.lua` proves the **full archetype deploy loop** for this repo's current code
against a live environment (`ybor-playground` by default):

```
render archetype
   -> create GitHub repo + push to main
      -> Build workflow (lint/test/build + docker publish)
         -> git tag + GitHub release (carries the image digest)
            -> CI dispatches a manifest update into the .platform repo
               -> ApplicationSet auto-creates an ArgoCD app
                  -> app syncs -> Healthy
                     -> deployed pods run the exact built image digest
                        -> Deployment Healthy + its Pods Running
```

The loop logic lives in the reusable **`deploy` plugin**
([`../prova-p6m-deploy-loop`](../prova-p6m-deploy-loop), pinned in `prova.toml`). This file only
supplies this archetype's answers and calls `deploy.flow(...)`; every other archetype's e2e suite
consumes the same plugin, so the bar cannot drift between languages.

The suite only **triggers and verifies**: the platform's own automation creates every cluster-side
object. The only things it creates are the GitHub test repo and, on teardown, a commit that removes
the manifest folder from the `.platform` repo.

## Separate from the acceptance suite

The acceptance suite (`tests/`) renders + builds + boots the project **locally** (docker-only) on
every push/PR. This suite renders + **pushes a real repo** and drives live GitOps, so it is kept
apart two ways:

1. It lives under `e2e/`, which is **not** in `prova.toml`'s default `[run] proofs = ["tests"]`, so
   a bare `prova` and the `Acceptance` workflow never run it.
2. The flow hard-`requires` the live-infra CLIs (`archetect`, `gh`, `git`, `argocd`), so even if
   selected on a runner that lacks them it **skips cleanly** rather than failing.

Run it on its own:

```sh
prova -p e2e                 # the e2e profile (proofs = ["e2e"])
prova e2e                    # or point prova straight at the directory
prova -p e2e -k render       # just the render step, while iterating
prova --last-failed          # re-run only the step that failed
```

## Requirements

- `archetect`, `gh` (authenticated, scopes `repo`+`workflow`), `argocd` (logged in:
  `argocd login <server> --sso`, or `ARGOCD_SERVER` + `ARGOCD_AUTH_TOKEN` + `ARGOCD_OPTS=--grpc-web`),
  `git`.
- The target GitHub org must inherit the platform org secrets/vars the generated CI needs
  (`P6M_ARTIFACTORY_USERNAME/IDENTITY_TOKEN`, `P6M_UPDATE_MANIFEST_TOKEN`,
  `P6M_ARTIFACTORY_HOSTNAME/PROJECT`, `P6M_PLATFORM_DISPATCH_URL`). `ybor-playground` does.

## Configuration (environment)

Operational knobs are read by the plugin's `deploy.from_env` - see
[`../prova-p6m-deploy-loop/README.md`](../prova-p6m-deploy-loop/README.md) for the full list
(`GITHUB_ORG`, `PLATFORM_REPO`, `ENVIRONMENT`, `ARGO_APP_SUFFIX`, `KEEP_RESOURCES`, the stage
timeouts, ...). This file additionally reads a few **answer** overrides so you can retarget without
editing it:

| Var | Default | Meaning |
|---|---|---|
| `ORG_NAME` / `SOLUTION_NAME` | `ybor` / `playground` | Archetype identity (drives `group_id`, repo owner, ArgoCD naming) |
| `PROJECT_SUFFIX` | `Service` | Project name suffix |
| `GROUP_ID` | `<org>.<solution>` | Maven groupId |
| `ARTIFACTORY_HOST` / `IMAGE_REGISTRY` | `p6m.jfrog.io` | Registry coordinates |
| `PERSISTENCE` | `None` | Persistence backend (`None`/`PostgreSQL`/`MySQL`) |

Sensible defaults render a hollow (`persistence: None`) `ybor.playground` service into
`ybor-playground`. Teardown runs at the end whether the flow passed, failed, or skipped - set
`KEEP_RESOURCES=1` to leave everything up for debugging.

## CI

`.github/workflows/e2e.yaml` runs this suite on `workflow_dispatch` only (never on push/PR), behind
the `e2e-deploy-loop` concurrency group so only one loop runs at a time (all callers share ArgoCD and
the `.platform` repo). It installs `archetect` + `argocd`, rewrites git URLs to token-authed https so
`archetect` can fetch the archetype's private libraries, and always tears down. It needs org/repo
secrets `E2E_GH_TOKEN` (PAT with `repo`+`workflow`, member of the target org) and `ARGOCD_AUTH_TOKEN`
(`argocd account generate-token`).
