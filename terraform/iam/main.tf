data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket = "kratosvil-tfstate-805778285334"
    key    = "argocd-gitops-aws/eks/terraform.tfstate"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "ecr" {
  backend = "s3"

  config = {
    bucket = "kratosvil-tfstate-805778285334"
    key    = "argocd-gitops-aws/ecr/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  eks_oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  eks_oidc_issuer        = replace(data.terraform_remote_state.eks.outputs.oidc_provider_url, "https://", "")
}

# ---------------------------------------------------------------------------
# GitHub Actions -> ECR, via GitHub's own OIDC provider (not the EKS one).
# No static AWS credentials stored anywhere: the workflow assumes this role
# with a short-lived token, scoped to this repo only.
# ---------------------------------------------------------------------------

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]

  tags = {
    Project = var.project
  }
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoped to this repo, any branch/ref - tighten to a specific ref
    # (e.g. "repo:kratosvil/argocd-gitops-aws:ref:refs/heads/main") if the
    # workflow ever needs a stricter trust boundary.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json

  tags = {
    Project = var.project
  }
}

data "aws_iam_policy_document" "github_actions_ecr" {
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level scoping
  }

  statement {
    sid    = "ECRPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [data.terraform_remote_state.ecr.outputs.repository_arn]
  }
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name   = "ecr-push"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_ecr.json
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller, via the EKS cluster's own OIDC provider.
# Official AWS-published IAM policy for this controller (reused verbatim
# from the working aws-eks-forge setup).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "alb_controller_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.eks_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_issuer}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.project}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume.json

  tags = {
    Project = var.project
  }
}

resource "aws_iam_policy" "alb_controller" {
  name        = "${var.project}-alb-controller-policy"
  description = "IAM policy for AWS Load Balancer Controller"

  # Official policy from kubernetes-sigs/aws-load-balancer-controller,
  # fetched fresh instead of reusing the older copy from aws-eks-forge -
  # that older copy was missing elasticloadbalancing:DescribeListenerAttributes
  # (added since), which caused ALB provisioning to fail with AccessDenied.
  policy = file("${path.module}/aws-load-balancer-controller-policy.json")

  tags = {
    Project = var.project
  }
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}
