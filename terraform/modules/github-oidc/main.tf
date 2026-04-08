# =============================================================================
# GITHUB OIDC MODULE — Lets GitHub Actions assume an AWS IAM role
# =============================================================================
# WHY OIDC instead of AWS access keys:
#   - No long-lived credentials in GitHub Secrets
#   - Temporary tokens (expire in 1 hour)
#   - Trust is scoped to specific repos and branches
#   - Industry standard for CI/CD → AWS authentication
#
# HOW IT WORKS:
#   1. GitHub Actions presents an OIDC token to AWS
#   2. AWS verifies the token came from GitHub (via OIDC provider)
#   3. AWS checks the token matches the trust policy (right repo, right branch)
#   4. AWS issues temporary credentials
#   5. GitHub uses those credentials to push to ECR
# =============================================================================

# --- OIDC Provider ---
# One-time setup — tells AWS "trust GitHub's identity tokens"
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  tags = {
    Project = var.project_name
  }
}
# --- IAM Role for GitHub Actions ---
resource "aws_iam_role" "github_actions" {
  name = "${var.project_name}-github-actions"
# Trust policy: ONLY this specific repo can assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"
          }
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "ecr_power_user" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}