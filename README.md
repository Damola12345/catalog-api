# catalog-api

A small REST API taken through the full onboarding path: **container → CI pipeline → Kubernetes → AWS infrastructure (Terraform)**. The app is deliberately minimal; the focus is everything around it.

**Status: all parts working and verified.** CI is green and pushes to ECR via OIDC, the Terraform is applied in AWS, and the Kubernetes manifests pass 13/13 end-to-end checks on a local cluster. See [Evidence](#evidence).

| Brief requirement | Where |
|---|---|
| 1. Containerisation | [`docker/`](docker/) |
| 2. CI pipeline | [`.github/workflows/ci.yml`](.github/workflows/ci.yml) |
| 3. Kubernetes manifests | [`k8s/base/`](k8s/base/) |
| 4. Terraform (registry, CI role, state bucket) | [`terraform/`](terraform/) |
| Migration question | [Importing an existing resource](#importing-an-existing-resource-into-terraform) |
| Assumptions and trade-offs | [Assumptions and trade-offs](#assumptions-and-trade-offs) |

```
app/                 Go REST API + unit tests
docker/              Dockerfile, .dockerignore
.github/workflows/   ci.yml
k8s/base/            Deployment, Service, Ingress, NetworkPolicy, ConfigMap, Secret, PDB
k8s/overlays/local/  small overrides for a local kind cluster
scripts/             local-cluster-test.sh (end-to-end test)
terraform/           modules/ (ecr, github-oidc-ci-role, state-bucket), bootstrap/, live/
docs/evidence/       screenshots and test log
```

---

## 1. The app

Go, standard library only, in-memory data.

| Endpoint | Purpose |
|---|---|
| `GET /healthz` | Liveness: the process is up |
| `GET /readyz` | Readiness: returns 503 while starting up or shutting down |
| `GET /api/v1/items` | List items |
| `POST /api/v1/items` | Create an item; needs the `X-API-Key` header (from the Kubernetes Secret) |

On shutdown it stops accepting new traffic first, waits for in-flight requests, then exits, so rolling updates don't drop requests.

## 2. Container: `docker/Dockerfile`

- **Multi-stage build:** compile in `golang:1.27-alpine`; copy only the binary into the final image.
- **Minimal base:** `gcr.io/distroless/static-debian12:nonroot`. No shell or package manager, about 2 MB.
- **Non-root:** runs as UID 65532.
- **`.dockerignore`:** ignore everything except `app/`, so `.git`, Terraform state and secrets never get into the image.

## 3. CI pipeline: `.github/workflows/ci.yml`

Three jobs. The image is only built if the first two pass.

1. **Lint & test:** Go formatting, golangci-lint, unit tests.
2. **Lint config:** Dockerfile (hadolint), Kubernetes manifests (kubeconform), Terraform (`fmt`/`validate`), Trivy misconfiguration scan.
3. **Build, scan & push:** builds the image **once**, scans it with Trivy (fails on fixable HIGH/CRITICAL), then pushes **that same image** to ECR as `sha-<commit>`.

| How to trigger | What runs |
|---|---|
| Pull request to `main` | Everything except the push |
| Push or merge to `main` | Everything, including the push to ECR |
| Manual | Actions → **ci** → *Run workflow* on `main` |

**Setup:** add three repository **secrets**: `AWS_REGION`, `AWS_ACCOUNT_ID`, `AWS_CI_ROLE_ARN` (values from `terraform -chdir=terraform/live output github_actions_variables`).

**No AWS keys are stored anywhere.** CI logs in with GitHub OIDC and gets 1-hour credentials, and only the `main` branch of this repo is trusted. The three values aren't credentials; they're secrets only so they stay masked in this public repo's logs.

## 4. Kubernetes: `k8s/base/`

| File | What it does |
|---|---|
| `deployment.yaml` | 2 replicas, zero-downtime rollouts, CPU/memory requests and limits, startup/liveness/readiness probes, non-root, read-only filesystem |
| `service.yaml` | Internal ClusterIP service on port 80 |
| `ingress.yaml` | ingress-nginx, with TLS from cert-manager (Let's Encrypt) |
| `networkpolicy.yaml` | Deny everything by default. **In:** only from ingress-nginx on port 8080. **Out:** only DNS. |
| `configmap.yaml` | Non-sensitive settings |
| `secret.yaml` | `API_KEY`, **placeholder value only** (see [Secrets](#secrets)) |
| `namespace.yaml` | Enforces the Kubernetes `restricted` Pod Security standard |
| `pdb.yaml`, `serviceaccount.yaml` | Keeps 1 pod up during node maintenance; dedicated identity with no API token |

**Apply to a cluster** (needs ingress-nginx, cert-manager and a CNI that enforces NetworkPolicy):

```bash
cd k8s/base && kustomize edit set image catalog-api=<registry>/catalog-api:sha-<commit> && cd ../..
kubectl apply -k k8s/base/ --dry-run=server
kubectl apply -k k8s/base/
kubectl -n catalog rollout status deploy/catalog-api
```

**Test locally** with `scripts/local-cluster-test.sh`. It creates a kind cluster with Calico (so NetworkPolicy is enforced) and ingress-nginx, deploys the manifests and runs 13 checks.

```bash
# Deploy the exact image CI pushed to ECR (recommended)
ECR_IMAGE=<registry>/catalog-api:sha-<commit> ./scripts/local-cluster-test.sh

# ...or build the image locally instead
./scripts/local-cluster-test.sh

./scripts/local-cluster-test.sh cleanup   # delete the cluster
```

The local overlay changes only what has to differ on a laptop: the image source, plain HTTP (Let's Encrypt needs a public domain) and a throwaway test key.

### Secrets

`secret.yaml` holds an obvious placeholder (`REPLACE_ME_VIA_EXTERNAL_SECRETS`); real values never go in Git. In a real cluster the key lives in **AWS Secrets Manager**, and **External Secrets Operator** syncs it into a Secret with the same name, so the Deployment doesn't change.

## 5. Terraform: `terraform/`

| Module | Creates |
|---|---|
| `modules/state-bucket` | S3 bucket for Terraform state: versioned, encrypted, private, HTTPS-only, protected from deletion |
| `modules/ecr` | ECR repository: immutable tags, scan on push. **Lifecycle policy:** delete untagged images after 7 days; keep the last 30 `sha-*` images |
| `modules/github-oidc-ci-role` | IAM role for CI: only this repo's `main` branch can use it, and it can only push to this one repository |

- **`bootstrap/`** creates the state bucket (run once).
- **`live/`** creates the ECR repository and CI role, storing its state in that bucket. Locking uses Terraform's built-in S3 lock file (no DynamoDB needed).

```bash
terraform -chdir=terraform/bootstrap init && terraform -chdir=terraform/bootstrap apply

cd terraform/live
cp backend.hcl.example backend.hcl            # bucket name from the bootstrap output
cp terraform.tfvars.example terraform.tfvars  # your GitHub repo details
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan && terraform apply tfplan
```

`backend.hcl` and `terraform.tfvars` are gitignored, so no account-specific values are committed.

**The CI role is least-privilege:**
- Only the ECR actions needed to push, on one repository. No delete permissions.
- 1-hour sessions.
- The trust policy accepts both formats GitHub uses for its OIDC identity (`repo:owner/repo:…` and the ID-based `repo:owner@id/repo@id:…`). CI prints the identity it receives, so a mismatch is easy to spot.

### Importing an existing resource into Terraform

Goal: Terraform takes over the resource **as it is**, with no changes, downtime or recreation.

1. **Inspect** the real resource (for example `aws ecr describe-repositories`) and note any setting that would force a replacement if it differed.
2. **Write matching config** plus an `import` block (Terraform 1.5+). Example in [`terraform/live/imports.tf`](terraform/live/imports.tf):
```hcl
   import {
     to = module.ecr.aws_ecr_repository.this
     id = "catalog-api"
   }
```
   `terraform plan -generate-config-out=generated.tf` can draft the config for you.
3. **Run `terraform plan` until it shows only `1 to import, 0 to add, 0 to change, 0 to destroy`.** "Must be replaced" means the config doesn't match yet; fix it before applying.
4. **Apply**, run `plan` again to confirm nothing changes, then remove the `import` block.
5. **Prevent drift:** remove console write access for that resource and run a scheduled `terraform plan`.

Importing only updates Terraform's state; it never touches the live resource. The real risk is applying with config that doesn't match, which is why step 3 matters.

---

## Evidence

### Kubernetes: local cluster test, 13/13 passed

The test deployed the **exact image CI built, scanned and pushed to ECR** (`sha-c2f3a0a`). Full output: [`docs/evidence/local-cluster-test.log`](docs/evidence/local-cluster-test.log).

| # | What it proves | Screenshot |
|---|---|---|
| 1 | Manifests apply and roll out under the `restricted` Pod Security standard | [01-deploy](docs/evidence/01-deploy.png) |
| 2 | Deployment, Service, Ingress, NetworkPolicies, ConfigMap, Secret and PDB all created | [02-resources](docs/evidence/02-resources.png) |
| 3 | Requests/limits and probes set; config from ConfigMap and Secret; non-root, read-only filesystem; 2/2 ready | [03-deployment-spec](docs/evidence/03-deployment-spec.png) |
| 4 | App works through the Ingress; POST rejected without the key (401), accepted with it (201). **NetworkPolicy (in):** a pod in another namespace is blocked | [04-ingress-and-networkpolicy-in](docs/evidence/04-ingress-and-networkpolicy-in.png) |
| 5 | **NetworkPolicy (out):** DNS allowed; internet and Kubernetes API blocked. Rolling restart under live traffic: **283/283 requests succeeded** | [05-networkpolicy-out-and-rollout](docs/evidence/05-networkpolicy-out-and-rollout.png) |

### CI and AWS

| # | What it proves | Screenshot |
|---|---|---|
| 6 | CI green on `main`: OIDC login to AWS and push to ECR | [06-ci-pipeline](docs/evidence/06-ci-pipeline.png) |
| 7 | ECR repository (immutable tags, scan on push), lifecycle policy and pushed images | [07-ecr](docs/evidence/07-ecr.png) |
| 8 | Terraform state bucket: versioning, encryption, public access blocked | [08-s3-state](docs/evidence/08-s3-state.png) |

---

## Assumptions and trade-offs

**Assumptions**
- AWS (ECR, IAM, S3) with an existing Kubernetes cluster. The manifests aren't EKS-specific.
- One ECR repository and CI role serve all environments; images are promoted by tag, not rebuilt.

**Shortcuts taken on purpose**
- **The app is a stub:** data is in memory, so replicas don't share it. A real service would add a database.
- **CI builds and pushes, but doesn't deploy.** In production I'd use GitOps (Argo CD) so CI never needs cluster credentials.
- **One Kustomize base**, with no dev/staging/prod overlays yet.
- **No autoscaling:** fixed 2 replicas until there's real load data.
- **AWS-managed encryption keys** rather than customer-managed KMS keys (the modules support either).
- **Actions pinned to version tags, not commit SHAs.** Dependabot keeps them updated.
- **No image signing yet.** Next: cosign signing in CI and a policy that only admits signed images.

**Lesson from the first CI run:** the vulnerability scan blocked the first push on 22 Go standard-library CVEs. Upgrading the build toolchain fixed it with no code changes, which is the gate doing its job.

## Next steps
- **GitOps:** Argo CD watches the manifests; CI opens a PR to bump the image tag.
- **Observability:** Prometheus metrics, OpenTelemetry traces, SLO-based alerts. Logs are already structured JSON.