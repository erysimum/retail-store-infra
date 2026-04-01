# =============================================================================
# ECR MODULE — Container Image Registry
# =============================================================================
# Creates ECR repositories for microservice images.
# 
# WHY ECR:
#   - Same region as EKS = fast pulls (no cross-ocean downloads)
#   - Private by default (IAM controls access)
#   - No pull rate limits within AWS
#   - No external dependency (Docker Hub outage = your problem)
#
# LIFECYCLE POLICY:
#   - Keeps last 10 tagged images (recent deployments)
#   - Deletes untagged images after 1 day (failed/intermediate builds)
#   - Prevents registry from growing forever and costing money
# =============================================================================

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = "${var.project_name}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# --- Lifecycle Policy: auto-cleanup old images ---
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus   = "tagged"
          tagPrefixList = ["v", "sha-"]
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Delete untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}