output "iam_role_arn" {
  description = "IAM role ARN for Image Updater"
  value       = aws_iam_role.image_updater.arn
}