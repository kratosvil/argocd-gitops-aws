# ArgoCD GitOps Pipeline on AWS EKS

A GitOps deployment pipeline for Kubernetes on Amazon EKS: ArgoCD handles declarative environment promotion, automated sync, and self-healing against manual drift, fronted by a GitHub Actions CI pipeline that builds, pushes to ECR, and promotes automatically — authenticated via OIDC, no static AWS credentials, no manual `kubectl apply`.

**Status:** complete. All infrastructure is provisioned with Terraform across 6 independent stacks (VPC, EKS, ECR, IAM, ArgoCD, ALB Controller), verified live on AWS, then torn down — full design rationale and build log in [docs/architecture-v2.md](docs/architecture-v2.md). An earlier local-only version (minikube) is also documented for reference.

## Why this project

I have production experience with EKS (Terraform-provisioned clusters, Blue/Green deployments, IRSA, HPA — see [aws-eks-forge](https://github.com/kratosvil/aws-eks-forge)) but no hands-on GitOps tooling until now. This project proves the ArgoCD/GitOps mechanics specifically — declarative sync, drift correction, environment promotion — first cheaply on minikube (v1), then for real on AWS with a full CI/CD pipeline in front of it (v2).

## Architecture (v2, current)

```
GitHub (this repo, public)
  app/kratosvil-replica-app/  → nginx:alpine, renders its own pod identity
                                 via the Kubernetes Downward API
  base/ + overlays/{dev,prod}/ → Kustomize, dev=3 replicas / prod=3 replicas
  .github/workflows/           → build image → push ECR → bump manifest tag → commit

AWS (Terraform, 6 independent stacks under terraform/)
  vpc            → 10.20.0.0/16, public subnets only, no NAT (cost)
  eks            → EKS 1.31, managed node group (Free-Tier-eligible instances only)
  ecr            → private repo for the app image
  iam            → 2 IRSA/OIDC roles: GitHub Actions → ECR, ALB Controller
  argocd         → ArgoCD via Helm, serves under /argocd on a shared ALB
  alb-controller → AWS Load Balancer Controller

Runtime (inside EKS)
  ArgoCD watches `main`, 2 Applications:
    kratosvil-replica-app-dev  (automated: prune + selfHeal)
    kratosvil-replica-app-prod (manual sync)
  1 shared ALB, path-based routing: /argocd → ArgoCD UI, / → the app
```

GitHub Actions never touches the cluster — it only reaches ECR and this repo (via OIDC, no static AWS credentials). ArgoCD is the only component with real cluster access.

## Repo structure

```
.
├── app/kratosvil-replica-app/   # the demo app (Dockerfile + HTML template)
├── base/                        # shared Deployment + Service
├── overlays/
│   ├── dev/                     # 3 replicas, Ingress, CI-managed image tag
│   └── prod/                    # 3 replicas, manual promotion
├── argocd/                      # Application manifests (dev + prod) + ArgoCD's own Ingress
├── terraform/                   # 6 stacks: vpc, eks, ecr, iam, argocd, alb-controller
├── .github/workflows/           # CI: build, push, promote dev
└── docs/
    ├── architecture-v2.md       # full design rationale + build log
    └── images/                  # process diagrams (v1 + v2)
```

## Setup (v2, AWS)

```bash
# Apply in dependency order — each stack reads the previous one's state
cd terraform/vpc            && terraform init && terraform apply
cd ../eks                   && terraform init && terraform apply
cd ../ecr                   && terraform init && terraform apply
cd ../iam                   && terraform init && terraform apply
cd ../argocd                && terraform init && terraform apply
cd ../alb-controller        && terraform init && terraform apply

# Seed the first image (until CI has run at least once)
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com
docker build -t <ecr-repo>:latest app/kratosvil-replica-app
docker push <ecr-repo>:latest

kubectl apply -f argocd/application-dev.yaml -f argocd/application-prod.yaml -f argocd/ingress.yaml
```

## Setup (v1, local)

```bash
minikube start --cpus=2 --memory=4096
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argocd-server 8080:443
kubectl apply -f argocd/application-dev.yaml
```

## Demos

### v2 — on real AWS infrastructure

![Process overview v2, part 1: architecture and the three demo mechanisms](docs/images/process-overview-v2.png)
![Process overview v2, part 2: real problems hit and fixed, and live access](docs/images/process-overview-v2.1.png)

Three separate mechanisms, all verified against the running EKS cluster:

- **Self-healing** — a manual `kubectl scale` (2→4 replicas) is reverted by ArgoCD in under 5 seconds.
- **Manual promotion via Git** — editing `overlays/dev/kustomization.yaml` directly and pushing gets applied automatically, no `kubectl apply`.
- **CI-driven promotion** — a real app change pushed to `app/kratosvil-replica-app/` triggers GitHub Actions (build → ECR → bump manifest tag → commit), and ArgoCD picks up that commit through its own polling cycle and syncs — verified end to end including the rendered content actually changing on the live ALB.

The second image also documents four real problems hit during the build (a KMS backend policy mismatch, an account-level Free-Tier-only EC2 restriction, a per-node pod capacity limit, and a stale IAM policy missing a newer required permission) and how each was diagnosed and fixed.

### v1 — on minikube

![Process overview v1: architecture, self-heal timeline, Git promotion timeline and live endpoints](docs/images/process-overview.png)

Same two demos (self-healing, promotion via Git), proven first on a local cluster before spending anything on AWS.

## Cleanup

```bash
# v2 — reverse order, since each stack depends on the previous one's state
cd terraform/alb-controller  && terraform destroy
cd ../argocd                 && terraform destroy
cd ../iam                    && terraform destroy
cd ../eks                    && terraform destroy
cd ../ecr                    && terraform destroy
cd ../vpc                    && terraform destroy

# v1
minikube delete
```
