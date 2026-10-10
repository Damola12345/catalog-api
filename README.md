# catalog-api

A small REST API taken through the full onboarding path: **container → CI pipeline → Kubernetes → AWS infrastructure (Terraform)**. The app is deliberately minimal; the focus is everything around it.

| Brief requirement | Where |
|---|---|
| Containerisation | [`docker/`](docker/) |
| CI pipeline | [`.github/workflows/ci.yml`](.github/workflows/ci.yml) |
| Kubernetes manifests | [`k8s/base/`](k8s/base/) |
| Terraform (registry, CI role, state bucket) | [`terraform/`](terraform/) |
| Migration question | [Importing existing resources](#importing-an-existing-resource-into-terraform) |
| Assumptions & trade-offs | [Assumptions and trade-offs](#assumptions-and-trade-offs) |

```
app/                 Go REST API + unit tests
docker/              Dockerfile, .dockerignore
.github/workflows/   ci.yml
k8s/base/            Deployment, Service, Ingress, NetworkPolicy, ConfigMap, Secret, PDB
k8s/overlays/local/  overrides for a local kind cluster
scripts/             local-cluster-test.sh (end-to-end test on kind)
terraform/           modules/ (ecr, github-oidc-ci-role, state-bucket), bootstrap/, live/
```

---

## 1. The app

Go, standard library only, in-memory data.

| Endpoint | Purpose |
|---|---|
| `GET /healthz` | Liveness: the process is up |
| `GET /readyz` | Readiness: returns 503 while starting up or shutting down |
| `GET /api/v1/items` | List items |
| `POST /api/v1/items` | Create an item; requires the `X-API-Key` header (value from the Kubernetes Secret) |

On shutdown (`SIGTERM`) it fails readiness first, waits for traffic to drain, then stops, so rolling updates don't drop requests.

```bash
make test    # unit tests
make run     # build and run the container on :8080
```

## 2. Container: `docker/Dockerfile`

- **Multi-stage build:** compile in `golang:1.24-alpine`, copy only the static binary into the final image.
- **Minimal base:** `gcr.io/distroless/static-debian12:nonroot`. No shell or package manager, about 2 MB.
- **Non-root:** runs as UID 65532.
- **`.dockerignore`:** allow-list (ignore everything, re-include `app/`), so `.git`, Terraform state and secrets never enter the build. Docker reads it from the repo root, so `/.dockerignore` is a symlink to `docker/.dockerignore`.

## 3. CI pipeline: `.github/workflows/ci.yml`

**What it does:**

1. **Lint & test:** Go formatting, golangci-lint, unit tests with the race detector.
2. **Lint config:** hadolint (Dockerfile), kubeconform (Kubernetes manifests), `terraform fmt`/`validate`, Trivy misconfiguration scan.
3. **Build, scan & push:** runs only if 1 and 2 pass:
   - builds the image **once**
   - scans it with Trivy (full report to GitHub's Security tab; fails on fixable HIGH/CRITICAL)
   - on `main` only, pushes **that same image** to ECR, tagged `sha-<commit>`.

**How to trigger it:**

| Event | Result |
|---|---|
| Open or update a pull request to `main` | Everything except the push |
| Merge or push to `main` | Everything, including the push to ECR |
| Manual | Actions → **ci** → *Run workflow* |

**Setup:** after applying the Terraform, add three **repository secrets** (Settings → Secrets and variables → Actions → Secrets): `AWS_REGION`, `AWS_ACCOUNT_ID`, `AWS_CI_ROLE_ARN`. Get them with `terraform -chdir=terraform/live output github_actions_variables`.

**No AWS keys are stored anywhere.** CI logs in with GitHub OIDC and gets 1-hour credentials. The role only trusts this repository's `main` branch, so pull requests can't get credentials. The three values above aren't credentials, but they're kept as secrets so they're masked in this public repo's logs.

## 4. Kubernetes: `k8s/base/`

| File | What it does |
|---|---|
| `deployment.yaml` | 2 replicas, zero-downtime rollouts, CPU/memory requests and limits, startup/liveness/readiness probes, non-root with a read-only filesystem |
| `service.yaml` | Internal ClusterIP service on port 80 |
| `ingress.yaml` | ingress-nginx with TLS from cert-manager (Let's Encrypt) |
| `networkpolicy.yaml` | Deny all traffic by default. **In:** only from ingress-nginx, on port 8080. **Out:** only DNS. |
| `configmap.yaml` | Non-sensitive settings (port, log level) |
| `secret.yaml` | `API_KEY`. **Placeholder value only**; see [Secrets](#secrets) |
| `namespace.yaml` | Enforces the Kubernetes `restricted` Pod Security standard |
| `pdb.yaml`, `serviceaccount.yaml` | Keeps 1 pod up during node maintenance; dedicated identity with no API token |

**Apply to a cluster** (needs ingress-nginx, cert-manager and a CNI that enforces NetworkPolicy):

```bash
# point at the image CI pushed
cd k8s/base && kustomize edit set image catalog-api=<registry>/catalog-api:sha-<commit> && cd ../..

kubectl apply -k k8s/base/ --dry-run=server   # validate against the cluster
kubectl apply -k k8s/base/
kubectl -n catalog rollout status deploy/catalog-api
kubectl -n catalog get pods,svc,ingress,networkpolicy
```

### Local test on kind

`scripts/local-cluster-test.sh` creates a kind cluster with Calico (so NetworkPolicy is enforced) and ingress-nginx. It deploys `k8s/overlays/local` and checks:
- the deployment rolls out and the probes pass
- the app responds through the Ingress
- POST is rejected without the API key and accepted with it
- the NetworkPolicy blocks traffic from other namespaces and blocks outbound internet
- a rolling restart drops no requests

The local overlay changes only what must differ on a laptop: a locally built image, plain HTTP (Let's Encrypt needs a public domain), and a throwaway test key.

```bash
./scripts/local-cluster-test.sh           # run
./scripts/local-cluster-test.sh cleanup   # delete the cluster
```


### Secrets

`secret.yaml` contains an obvious placeholder (`REPLACE_ME_VIA_EXTERNAL_SECRETS`); real values never go in Git. In a real cluster, the key lives in **AWS Secrets Manager** and **External Secrets Operator** syncs it into a Secret with the same name, so the Deployment doesn't change.

## 5. Terraform: `terraform/`

| Module | Creates |
|---|---|
| `modules/state-bucket` | S3 bucket for Terraform state: versioned, encrypted, private, HTTPS-only, protected from deletion |
| `modules/ecr` | ECR repository: immutable tags, scan on push. **Lifecycle policy:** delete untagged images after 7 days, keep the last 30 `sha-*` images |
| `modules/github-oidc-ci-role` | IAM role for CI: only this repo's `main` branch can assume it, and it can only push images to this one repository |

- **`bootstrap/`** creates the state bucket (run once).
- **`live/`** uses the ECR and CI-role modules, with state stored in that bucket. Locking uses Terraform's built-in S3 lock file, so no DynamoDB table is needed.

```bash
# 1. state bucket
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply

# 2. registry + CI role
cd terraform/live
cp backend.hcl.example backend.hcl                 # set the bucket name from step 1
cp terraform.tfvars.example terraform.tfvars       # set your GitHub repo details
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan && terraform apply tfplan
```

`backend.hcl` and `terraform.tfvars` are gitignored, so no account-specific values are committed.

**The CI role is least-privilege:**
- Only the seven ECR actions needed to push, on one repository.
- No delete permissions and no wildcard resources, except `ecr:GetAuthorizationToken`, which AWS doesn't allow scoping.
- Sessions last at most 1 hour.
- The trust policy accepts both formats GitHub uses for the OIDC subject: plain `repo:owner/repo:…` and the ID-based `repo:owner@id/repo@id:…`. CI prints the subject it receives, to make any mismatch easy to debug.

### Importing an existing resource into Terraform

Goal: Terraform adopts the resource **as it is**, with no changes, downtime or recreation.

1. **Inspect** the real resource (for example `aws ecr describe-repositories`) and note any setting that would force a replacement if it differed (for ECR: name, encryption).
2. **Write matching config** and add an `import` block (Terraform 1.5+). An example is in [`terraform/live/imports.tf`](terraform/live/imports.tf):
```hcl
   import {
     to = module.ecr.aws_ecr_repository.this
     id = "catalog-api"
   }
```
   `terraform plan -generate-config-out=generated.tf` can draft the config for you.
3. **Run `terraform plan` until it shows only `1 to import, 0 to add, 0 to change, 0 to destroy`.** Anything that says "must be replaced" means the config doesn't match yet. Fix it before applying.
4. **Apply**, then run `plan` again to confirm there are no changes, and remove the `import` block.
5. **Prevent drift:** remove console write access for that resource and run a scheduled `terraform plan` to detect manual changes.

Import only writes to Terraform's state; it never touches the live resource. The risk is applying with config that doesn't match, which is why step 3 matters.

---

## Assumptions and trade-offs

**Assumptions**
- AWS (ECR, IAM, S3) with an existing Kubernetes cluster. The manifests aren't EKS-specific.
- One ECR repository and CI role serve all environments; images are promoted by tag, not rebuilt.

**Shortcuts taken on purpose**
- **The app is a stub:** in-memory storage, so replicas don't share data. A real service would add a database (plus a NetworkPolicy rule and a secret for it).
- **CI builds and pushes, but doesn't deploy.** Deployment is `kubectl apply`. In production I'd use GitOps (Argo CD), so CI never needs cluster credentials.
- **One Kustomize base**, with no dev/staging/prod overlays yet.
- **No autoscaling (HPA):** fixed 2 replicas until there's real load data.
- **AWS-managed encryption keys** instead of customer-managed KMS keys. The modules accept a `kms_key_arn` if needed.
- **Actions are pinned to version tags, not commit SHAs.** SHA pinning is stronger; Dependabot is configured to keep them updated.
- **No image signing or SBOM yet.** Next step: cosign signing in CI, plus an admission policy that only allows signed images.

## Next steps
- **GitOps:** Argo CD watches the manifests; CI opens a PR to bump the image tag.
- **Observability:** Prometheus metrics endpoint, OpenTelemetry traces, SLO-based alerts. Logs are already structured JSON.