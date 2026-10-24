# Problem 4: Ship It Twice

Two GitHub Actions pipelines replace manual releases:

- **backend** → EC2, via AWS CodeDeploy;
- **frontend** → S3 + CloudFront.

```
PR      ──▶ CI (lint, test, audit, build)
main    ──▶ CI ──▶ package once ──▶ staging ──▶ [approval] ──▶ production
manual  ──▶ roll back one environment to a version previously released there
```

| Path | What it is |
|---|---|
| `.github/workflows/backend.yml`, `frontend.yml` | Pipelines: CI + orchestration |
| `.github/workflows/_deploy-*.yml` | Reusable: deploy one version (git SHA) to one environment |
| `ci/` | `codedeploy-wait.sh` (follow deployment + rollback), `release-guard.sh` (no older-over-newer), `check-cors.sh` (frontend can call API) |
| `backend/`, `frontend/` | Minimal stand-in apps + CodeDeploy files |

> The workflows sit in `src/problem4/.github/workflows/` as the template requires. **GitHub only runs them from the repo root**, so move them to `.github/workflows/` to activate. All paths inside are already root-relative.

## Assumptions

- **No apps were provided**, so I wrote minimal Node.js stand-ins with zero dependencies. The focus is the pipeline.
- **Backend uses CodeDeploy** (in-place, rolling, behind an ALB). It gives health-checked hooks and automatic rollback without SSH. I preferred it over:
  - SSH/rsync: needs keys and you build your own rollback;
  - SSM Run Command: no rolling deploy or rollback out of the box.
- **Infrastructure already exists and is out of scope:** instances with Node + the CodeDeploy agent + `/etc/backend/backend.env`, an S3 bucket behind CloudFront, and an IAM role per environment.
- **Frontend and API are on different origins**, so the API allows the frontend via CORS (`CORS_ALLOWED_ORIGINS`).
- **`staging` and `production` are GitHub Environments.** Production has required reviewers and only accepts `main`. Each environment has its own variables and AWS role.
- **Every release is stored as `<app>/<sha>.tgz`** in a per-environment artifact bucket. That makes releases immutable, and a rollback is just a redeploy.
- **AWS access uses OIDC.** No access keys are stored in GitHub.

## How it works

- **Build once, promote:** the bundle tested on staging is byte-for-byte what reaches production. The frontend gets its per-environment `config.json` at deploy time.
- **Backend deploy:**
  1. Wait until no other CodeDeploy deployment is active.
  2. Release guard: skip if a newer SHA is already deployed.
  3. Create the deployment.
  4. Follow its **real status**:
     - on failure, follow the automatic rollback to the end;
     - on timeout, stop the deployment with rollback.
  5. Smoke test that `/health` returns the new SHA.
  6. CORS check.
- **Frontend deploy:**
  1. Release guard.
  2. Upload hashed assets (cached 1 year), then `config.json`, then `index.html` **last** (both `no-cache`).
  3. Invalidate CloudFront.
  4. Smoke test for the new SHA, then CORS check.
- **Rollback:** run the workflow manually with an environment and a SHA. It skips CI and the guard, and only works for versions already released to that environment. Production still needs approval.
- **Guardrails:**
  - one deploy lock per app and environment, never cancelled mid-deploy;
  - least-privilege `permissions`;
  - actions pinned to commit SHAs;
  - path filters so each app only builds when it changes;
  - timeouts on every job.

**Automatic vs manual:**

- CodeDeploy rolls back on a failed hook (ValidateService) or a CloudWatch alarm.
- **A smoke or CORS check failing after a successful deployment does not roll back.** The job fails and asks for a manual rollback.

## What I verified (no AWS account)

- **App tests:** backend 7 tests, including CORS; frontend build test.
- **Packaging:** the bundle starts and reports its SHA.
- **CI scripts:**
  - `codedeploy-wait.sh` against a fake AWS CLI, in 9 scenarios;
  - `release-guard.sh` in a test git repo;
  - `check-cors.sh` against the real backend.
- **Workflows:** YAML, job/step references, reusable inputs, pinned actions, and `bash -n` on all `run:` scripts.
- **Not verified:** `actionlint`, a real Actions run, and real AWS behaviour.

## Deliberately left out

- **Infrastructure as code** (VPC, EC2/ASG, ALB, S3, CloudFront, IAM, CodeDeploy). It needs its own Terraform pipeline.
- **Blue/green deploys** and **automatic rollback after a failed smoke test.**
- **Same-origin routing** (CloudFront `/api/*` → ALB), which would remove CORS.
- **Queueing every release** instead of letting the latest candidate win, and a **deploy freeze** after a rollback.
- **Deeper testing and security:** E2E browser tests, CodeQL/SBOM/signing, old-asset cleanup, notifications, preview environments.
