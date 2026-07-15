# Architecture v2 — AWS + CI/CD upgrade

**Status:** built and verified. Everything below was the plan agreed before touching any infrastructure — the intent was to build once against a clear design instead of iterating live, and that held up in practice with only tactical fixes needed along the way (see the "real problems hit and fixed" section in [docs/images/process-overview-v2.1.png](images/process-overview-v2.1.png)). All 6 Terraform stacks applied, all 3 demos (self-heal, manual promotion, CI-driven promotion) verified against the running EKS cluster, real ALB URL confirmed load-balancing across pods. Torn down with `terraform destroy` after the evidence above was captured — see the `## Cleanup` section of the main README for the exact command sequence.

## Why this upgrade

v1 (see main [README](../README.md)) proved the GitOps mechanics (declarative sync, self-heal, environment promotion) on a local minikube cluster, deliberately avoiding AWS cost during a critical runway window. v2 moves the same mechanics onto real AWS infrastructure and adds a full CI pipeline in front of it, closing the loop from "code change" to "running on a load-balanced cluster" without any manual `kubectl` step. Built to be shared as a LinkedIn portfolio piece.

## What changes vs. v1

| | v1 (minikube) | v2 (AWS) |
|---|---|---|
| Cluster | minikube, local | Amazon EKS (managed control plane) |
| App | `hashicorp/http-echo` (static text, same on every pod) | `kratosvil-replica-app` — custom nginx:alpine image, renders its own pod identity via the Downward API |
| Registry | Docker Hub (public) | Amazon ECR (private), image built and pushed by CI |
| CI | none (manual `git push`) | GitHub Actions — builds, pushes to ECR, bumps the Kustomize image tag |
| Exposure | `kubectl port-forward` | ALB (AWS Load Balancer Controller), shared across ArgoCD UI and the app via path-based routing |
| Access model for CI | n/a | GitHub Actions never touches the cluster — only ECR and Git. ArgoCD is the only component with cluster credentials. |

## Application: `kratosvil-replica-app`

`http-echo` can't answer "which replica served this request" — every pod in a `Deployment` renders from the same `PodTemplate`, so a fixed `-text=` argument is identical across all of them. To make replica identity visible (the actual goal — proving the load balancer is distributing across real pods), the container needs to read its own identity at runtime.

- Base image: `nginx:alpine`
- Pod identity via the **Kubernetes Downward API** (not manual numbering — a `Deployment`'s pods have no stable ordinal, unlike a `StatefulSet`, so the pod's own generated name is the correct identifier):
  ```yaml
  env:
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
  ```
- An entrypoint script (`/docker-entrypoint.d/`) runs `envsubst` against an `index.html.template` at container start, rendering: **"Kratosvil Replica \$POD_NAME"**.
- Built and pushed to ECR by CI — this is a real custom image, not a mirror of a public one.

## AWS infrastructure

- **VPC**: public subnets only, no NAT Gateway — deliberate cost decision for a short-lived lab (avoids ~$0.045/hr + data charges for a resource that adds no value at this scope).
- **EKS**: managed control plane ($0.10/hr, no free tier — confirmed current AWS pricing 2026-07-14).
- **Node group**: 1x `t3.medium` (2 vCPU / 4GB). Sized above the minimum (`t3.small`, 2GB) to leave headroom for ArgoCD's ~6 components plus the app pods without risking resource pressure mid-demo — the cost delta for a multi-hour session is cents, not worth the risk of a flaky demo.
- Provisioned with Terraform, reusing the existing EKS module from `aws-eks-forge` and the shared remote state backend (`tf-state-backend`: S3 `kratosvil-tfstate-805778285334` + DynamoDB `kratosvil-tflock`) instead of writing a new module from scratch.

## IAM / IRSA

Three distinct roles, each scoped to only what it needs (least privilege, not one broad role reused everywhere):

1. **ArgoCD → ECR**: IRSA role letting ArgoCD's service account pull from the private ECR repo.
2. **AWS Load Balancer Controller**: IRSA role with the permissions needed to provision/manage ALBs and target groups from Ingress resources.
3. **GitHub Actions → ECR**: **OIDC federation**, not static credentials. An IAM OIDC identity provider trusts `token.actions.githubusercontent.com`; the role's trust policy is scoped to `repo:kratosvil/argocd-gitops-aws:*` only — no other GitHub workflow anywhere can assume it. Permissions limited to ECR push actions (`ecr:GetAuthorizationToken`, `ecr:PutImage`, `ecr:*LayerUpload*`). No `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` is ever stored as a GitHub secret.

## CI/CD pipeline (GitHub Actions)

Repo is public → GitHub-hosted runners are free with no minute cap (confirmed current GitHub pricing 2026-07-14) — no cost or quota concern.

Flow:
1. Push to `main` with app source changes triggers the workflow (path-filtered — see gotcha below).
2. Build `kratosvil-replica-app`, tag with the commit SHA, push to ECR via the OIDC role.
3. `kustomize edit set image <ecr-repo>=<new-tag>` against `overlays/dev/kustomization.yaml`.
4. Commit + push that change back to `main` using the workflow's own `GITHUB_TOKEN` (repo-scoped write, no extra secret needed).
5. ArgoCD detects the new commit through its normal reconciliation and syncs — the exact same promotion mechanic demonstrated manually in v1, now triggered by CI instead of a human edit.

**Security property worth calling out explicitly**: GitHub Actions never holds Kubernetes credentials — not a kubeconfig, not a service account token. It can only reach ECR and this Git repo. The only component with real cluster access is ArgoCD, running inside the cluster itself. A compromised CI pipeline in this design can push a bad image; it cannot touch the cluster directly.

**Known gotcha to handle in the workflow**: step 4's commit touches files inside the repo the workflow watches, which can re-trigger the same workflow in a loop. Mitigated with a `paths` filter on the trigger (only fire the build job on app source changes, not on the Kustomize manifest) or a `[skip ci]` marker in the automated commit message.

## Exposure

- One shared **ALB** via the AWS Load Balancer Controller, using `alb.ingress.kubernetes.io/group.name` so both Ingress resources (ArgoCD UI and `kratosvil-replica-app`) merge into a single Load Balancer with path-based routing (`/argocd`, `/`) instead of provisioning two. Chosen deliberately over two separate ALBs: lower cost, and it mirrors how a real multi-service environment routes traffic through a shared edge instead of one load balancer per service.
- `target-type: ip` — the ALB routes directly to pod IPs via the VPC CNI (default on EKS), no extra networking setup required.
- **No TLS/ACM in this iteration** — deliberate scope cut: ACM requires a validated domain, which this lab doesn't have. HTTP-only still proves everything that matters here (real AWS infra, real load balancing across pods). Documented here as the explicit next step for a production-grade version, not silently skipped.

## App replica counts

- `overlays/dev`: **2 replicas** — the minimum needed to visibly prove load-balancing behavior (refresh the page, see the pod identity alternate).
- `overlays/prod`: **3 replicas** — unchanged from v1, keeps the dev→prod promotion story (fewer replicas in dev, more in prod).

## Demos (same mechanics as v1, now on real infrastructure)

1. **Self-heal** — manual `kubectl scale` drift, reverted automatically.
2. **Promotion via Git** — now demonstrable two ways: manual edit+push (as in v1), and fully automated via the CI pipeline (code change → new image → manifest bump → ArgoCD sync), with no human touching the cluster or even the manifest by hand.
3. **Load balancing** — refreshing the app's URL repeatedly shows the ALB distributing requests across the 2 dev pods, each identifying itself by its real pod name via the Downward API.

## Execution plan

Built in dependency order — each block produces something the next one needs. Everything through Block 6 is code/config (no AWS cost yet); the clock on billing starts at Block 7.

| Block | Scope | Est. |
|---|---|---|
| 1 | Terraform: VPC (public subnets) + EKS control plane + `t3.medium` node group, reusing the `aws-eks-forge` module and the shared remote state backend | 40 min |
| 2 | Terraform: IAM — OIDC provider for GitHub Actions, 3 IRSA/OIDC roles (ArgoCD→ECR, ALB Controller, GitHub Actions→ECR), ECR repository | 30 min |
| 3 | App: `kratosvil-replica-app` — Dockerfile, `index.html.template`, entrypoint script, Downward API wiring in the base Deployment manifest; build and test the image locally before wiring CI to it | 30 min |
| 4 | Kustomize: update `base/` + `overlays/dev` (2 replicas) + `overlays/prod` (3 replicas) for the new app; remove the old `http-echo` args-patch pattern | 20 min |
| 5 | `kubectl`/Helm: apply Terraform outputs, install ArgoCD on EKS, re-point the existing `hello-gitops-dev`/`-prod` Applications (or recreate them) at the new manifests | 25 min |
| 6 | GitHub Actions workflow: build+push to ECR via OIDC, `kustomize edit set image`, commit-back with loop guard (`paths` filter) | 40 min |
| 7 | Helm: install AWS Load Balancer Controller via its IRSA role; create the shared ALB Ingress (`group.name`, path-based `/argocd` + `/`) | 30 min |
| 8 | End-to-end validation: push a real app change → watch CI build/push/bump → ArgoCD sync → confirm the ALB alternates between the 2 pods' real `POD_NAME` | 20 min |
| 9 | Demos: self-heal, manual promotion, CI-triggered promotion — capture evidence (same "one consolidated diagram" approach as v1, rebuilt with real v2 data) | 30 min |
| 10 | README + `docs/` final pass with real screenshots/diagram, `terraform destroy`, verify no residual AWS resources | 30 min |

**Total: ~4.5–5 hours core.** Same discipline as v1: nothing in blocks 7–10 gets left running past the working session.

## Cost model

Everything above is provisioned with Terraform and torn down with `terraform destroy` at the end of the working session — same ephemeral discipline as v1's `minikube delete`. For a multi-hour session: EKS control plane (~$0.10/hr) + 1 node (~$0.04/hr) + ALB (~$0.03/hr) ≈ **under $1 total** if destroyed promptly. Left running unattended, the EKS control plane alone bills ~$73/month regardless of workload — this is the one number worth remembering before walking away from a session without destroying.
