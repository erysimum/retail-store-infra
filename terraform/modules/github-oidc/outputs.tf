output "role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes — copy this to GitHub Secrets"
  value       = aws_iam_role.github_actions.arn
}