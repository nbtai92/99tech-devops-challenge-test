# Problem 4: Ship It Twice

Two GitHub Actions pipelines replace today's manual releases:

- **backend:** an HTTP API on EC2, deployed with AWS CodeDeploy;
- **frontend:** a static SPA on S3, served by CloudFront.

Both follow the same shape:

```
PR        ──▶ CI (lint, test, audit, build)
main      ──▶ CI ──▶ package once ──▶ staging ──▶ [manual approval] ──▶ production
manual    ──▶ roll back one environment to a version previously released there
```

## Files

```text
src/problem4/
├── .github/workflows/
│   ├── backend.yml             # backend pipeline (CI + orchestration)
│   ├── _deploy-backend.yml     # reusable: deploy one backend version to one environment
│   ├── frontend.yml            # frontend pipeline
│   └── _deploy-frontend.yml    # reusable: deploy one frontend version to one environment
├── ci/
│   ├── codedeploy-wait.sh      # follows a CodeDeploy deployment (and its rollback) to the end
│   ├── release-guard.sh        # stops an older release from replacing a newer one
│   └── check-cors.sh           # integration check: frontend origin can call the API
├── backend/                    # minimal Node.js API + CodeDeploy files (deploy/)
└── frontend/                   # minimal static SPA + build script
```

> **Where the workflows live.** They are in `src/problem4/.github/workflows/` because that is where the challenge template puts them, and **they do not run from there**. GitHub only runs workflows from the repository root, and `uses: ./.github/workflows/_deploy-*.yml` resolves only from there too. To activate them, move all four files to `.github/workflows/` at the root. Every path inside them is already written relative to the repository root.

## Assumptions (and why)

| Assumption | Why |
|---|---|
| The repo had no apps, so I added **minimal Node.js stand-ins** with zero dependencies | The task is the pipeline, not the app. The pipeline still uses `npm ci` + lockfile exactly as a real project would |
| Backend deploys to EC2 with **AWS CodeDeploy** (in-place, rolling, behind an ALB) | Rolling updates, health-checked lifecycle hooks and automatic rollback, without SSH from the runner. Alternatives below |
| Instances already have Node.js, the CodeDeploy agent and their config in `/etc/backend/backend.env` (including `CORS_ALLOWED_ORIGINS`) | Instance provisioning belongs to infrastructure code, not the release pipeline |
| Frontend: an **S3 bucket behind CloudFront** (OAC, SPA fallback to `index.html`) | Standard way to serve an SPA on AWS |
| **The frontend and the API are on different origins** (CloudFront domain vs ALB domain), so the API uses **CORS** with a per-environment allowlist | This keeps the two apps independently deployable. Same-origin routing is the alternative (see "Left out") |
| **Two environments, `staging` and `production`**, as GitHub Environments | Production gets required reviewers and is restricted to `main`. Each environment has its own AWS role and variables |
| **One artifact bucket per environment**, every release stored as `<app>/<git-sha>.tgz` | Releases are immutable and addressable by SHA, so rollback means redeploying an older object |
| **Trunk-based:** merge to `main` = release candidate | Simplest flow for a small team |
| AWS access uses **GitHub OIDC**, no access keys | No long-lived secrets to leak or rotate |

**Alternatives I considered for the backend:**

- **SSH + rsync:** needs SSH open to runners and key management, and you write your own rollback.
- **SSM Run Command:** no SSH, but rolling deploys and rollback would be hand-built.
- **ECR + ECS:** a better long-term target, but it changes the hosting model, which the task fixed as EC2.

## How the pipelines work

### On a pull request

Only the pipeline of the app that changed runs (path filters).

- **Backend:** `npm ci` → lint → tests (incl. CORS behaviour) → `npm audit`.
- **Frontend:** the same, plus a production build.

A new push to the PR cancels the previous run.

### On merge to `main`

**Backend:**

1. **CI** runs again, then the **bundle is packaged once**:
   - production dependencies are installed;
   - the git SHA is written into `VERSION`;
   - `appspec.yml` goes at the root of the bundle.
2. **Deploy to staging** (`_deploy-backend.yml`, `mode: release`):
   1. Assume the staging role via OIDC.
   2. **Wait until the deployment group is idle.** If a previous job was cancelled or an automatic rollback is still running, the new deployment waits for it instead of colliding.
   3. **Release guard.** Read the last successful deployment's SHA from CodeDeploy. If it is *newer* than this candidate (runs finished out of order), skip.
   4. Upload the bundle to `s3://<artifact-bucket>/backend/<sha>.tgz`. Objects are never overwritten.
   5. Create a CodeDeploy deployment with auto-rollback on failure or alarm. On each instance the hooks run: stop → install → start → **ValidateService** (`/health` must report the new SHA).
   6. **Follow the deployment by its real status** (`ci/codedeploy-wait.sh`), not with `aws deploy wait`:
      - `Succeeded` → continue.
      - `Failed`/`Stopped` → find the automatic rollback deployment and **wait until it finishes**, then fail the job, saying whether the previous revision was restored.
      - Still running after 30 min, or the status can't be read → **stop the deployment with rollback**, then follow the rollback the same way.
      - Transient API errors are retried.

      So the job only ends when AWS is no longer deploying. That means the per-environment lock really covers the deployment, not just the API call.
   7. **Smoke test** through the load balancer: `/health` must return the deployed SHA.
   8. **Integration check:** a request with `Origin: <FRONTEND_URL>` must get `Access-Control-Allow-Origin: <FRONTEND_URL>`. This catches a frontend that loads but cannot talk to the API.
3. **Deploy to production:** the same steps, after a required reviewer approves, with **the same bundle**.

**Frontend:**

1. **Build once.** Assets get content-hashed names and the SHA is stamped into `index.html`.
2. **Deploy** (`_deploy-frontend.yml`), staging, then production after approval:
   1. Release guard against the version in the live `config.json`.
   2. Publish the tarball to the artifact bucket, then deploy what is in S3. Releases and rollbacks use the same code path.
   3. Upload `assets/` with `max-age=31536000, immutable`.
   4. Write a per-environment `config.json` (`apiBaseUrl`, `version`, `no-cache`), then `index.html` **last** (`no-cache`), so a page never points at assets that aren't uploaded yet.
   5. Invalidate `/`, `/index.html` and `/config.json`, and wait.
   6. **Smoke test** (the page contains the SHA) and **integration check** (the API accepts the frontend origin).

### Rollback

Run the `backend` or `frontend` workflow manually ("Run workflow") **from the default branch**, choosing an environment and the full SHA. Things to know:

- **It skips CI, packaging and the release guard** (`mode: rollback`), because going back to an older version is the point.
- **The SHA must have been released to that environment before:** the bundle must exist in *that environment's* artifact bucket. Otherwise the job stops with a clear error.
- **Production still requires approval.**

### What is automatic and what is not

| Situation | What happens |
|---|---|
| A CodeDeploy hook fails (e.g. ValidateService) or a CloudWatch alarm fires | CodeDeploy rolls back automatically; the job waits for the rollback and reports the outcome |
| Deployment hangs past the timeout | The job stops it with rollback and waits for the rollback |
| First deployment fails (no previous revision) | No rollback is possible; the job fails with "manual intervention required" |
| **Smoke test or integration check fails after CodeDeploy reported success** | **Nothing rolls back automatically.** The job fails and tells you to run a manual rollback |

### Concurrency and release order

The policy is **latest candidate wins; rollbacks are explicit**.

- Each app has one lock per environment (`<app>-deploy-<env>`). A deployment in progress is never cancelled.
- GitHub keeps at most one *pending* run per lock, so a newer pending run replaces an older pending one. This is intended: there is no value in deploying an outdated candidate first.
- Out-of-order runs are covered by the **release guard**. If A builds slowly and reaches deploy after B, A sees that B (a descendant of A) is already deployed and skips, instead of silently reverting the environment.
- A run waiting for production approval does not block the next commit's CI. Only the deployment step is locked.
- **Known gap:** after a manual rollback to X, a still-pending older release A (newer than X) could be deployed by the next run. Production requires approval, so a reviewer would see it, but freezing releases after a rollback (e.g. a `DEPLOY_FREEZE` environment variable) would close this gap.

### What makes this production ready (within the stated scope)

| Concern | How it's handled |
|---|---|
| Quality gates | Lint, tests and dependency audit must pass before anything is packaged |
| Build once, promote | One artifact per commit; staging and production get identical bytes |
| Safe releases | Staging first, approval for production, production restricted to `main` |
| Zero-downtime backend | Rolling CodeDeploy behind the ALB, health-checked hooks |
| Deployment lifecycle | Real-status polling; failed or timed-out deployments are followed through rollback before the job ends |
| Release order | Release guard + per-environment lock; rollbacks bypass the guard explicitly |
| End-to-end check | Version smoke tests plus a CORS integration check between the two apps |
| No secrets in GitHub | OIDC role per environment |
| Least privilege | `contents: read` by default, `id-token: write` only on deploy jobs, checkout without persisted credentials |
| Supply chain | Every action pinned to a full commit SHA |
| Traceability | Deploy description and job summary record SHA, mode, decision, actor, run ID and S3 object |
| Bounded runs | Every job has `timeout-minutes`, sized to cover the deployment and its rollback |

## Setup the pipelines expect

**GitHub Environments:** `staging` (no reviewers) and `production` (required reviewers, deployment branches: `main` only). Each one sets these variables:

| Variable | Used by |
|---|---|
| `AWS_REGION`, `AWS_DEPLOY_ROLE_ARN`, `ARTIFACT_BUCKET`, `BACKEND_URL`, `FRONTEND_URL` | both |
| `CODEDEPLOY_APP`, `CODEDEPLOY_GROUP` | backend |
| `SITE_BUCKET`, `CLOUDFRONT_DISTRIBUTION_ID` | frontend |

**Instances:** `/etc/backend/backend.env` contains `CORS_ALLOWED_ORIGINS=<FRONTEND_URL of that environment>`.

**AWS:** one IAM role per environment, trusted only for this repo and that environment:

```json
"Condition": {
  "StringEquals": {
    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
    "token.actions.githubusercontent.com:sub": "repo:<org>/<repo>:environment:production"
  }
}
```

The `sub` condition limits the role to jobs running in the `production` environment. It does **not** restrict branches by itself; the environment's "deployment branches: `main`" rule does that.

The roles are scoped as follows:

- **Deploy role:**
  - S3: read/write on its artifact bucket prefix; write, plus read of `config.json`, on the site bucket.
  - CodeDeploy: `CreateDeployment`, `GetDeployment`, `GetDeploymentGroup`, `GetDeploymentConfig`, `ListDeployments`, `StopDeployment`, all on its own deployment group.
  - CloudFront: `CreateInvalidation` and `GetInvalidation` on its own distribution.
- **Instance role:** read access to the artifact bucket.

The deployment group uses a rolling config (e.g. `OneAtATime`), the ALB target group, and CloudWatch alarms on 5xx and latency.

## What I verified

There is no AWS account, so nothing has been deployed. Everything below ran locally:

- **Backend:** lint and **7 tests** pass. They cover health, routes, CORS allow/deny, and preflight allow/deny. The packaged bundle starts and `/health` returns the stamped SHA.
- **Frontend:** lint and tests pass; the build produces hashed assets referenced from `index.html`.
- **`ci/codedeploy-wait.sh`, against a fake `aws` CLI, in 9 scenarios:**
  - success;
  - failure with rollback succeeding;
  - timeout → stop → rollback;
  - transient API errors;
  - failure with no rollback;
  - rollback failing;
  - waiting for an active deployment;
  - refusing to start while one is still active;
  - idle group.
- **`ci/release-guard.sh`, in a test git repo:** older-after-newer → skip; newer, same, unknown and diverged SHAs → deploy.
- **`ci/check-cors.sh`, against the real backend:** passes for the allowed origin, fails for others.
- **Workflows:**
  - YAML parses (this check caught and fixed one invalid line);
  - `needs` and step-output references exist;
  - reusable inputs match what callers pass;
  - actions are pinned;
  - all 35 `run:` scripts pass `bash -n`.

**Not verified:** `actionlint` (I couldn't install it), a real GitHub Actions run, and real CodeDeploy/S3/CloudFront behaviour.

## What I deliberately left out

- **Same-origin routing** (a CloudFront behavior sending `/api/*` to the ALB). It would remove CORS entirely and is a good option, but it couples the two apps' infrastructure. I kept them separate and made CORS explicit and tested.
- **Automatic rollback after a failed smoke/integration check.** It is manual today (see the table above). Automating it needs a reliable "previous good version" record per environment.
- **Queueing every release** instead of latest-wins, and a **deploy freeze** after rollbacks.
- **Infrastructure as code** (VPC, EC2/ASG, ALB, S3, CloudFront, IAM, CodeDeploy). It belongs in Terraform/CDK with its own pipeline.
- **Blue/green backend deployments,** the next step if instant cutover/rollback is needed.
- **Integration and end-to-end tests beyond the smoke and CORS checks,** e.g. a browser test against staging.
- **Deeper security scanning** (CodeQL, SBOM, artifact signing), **pruning of old frontend assets**, **notifications**, and **per-PR preview environments**.
