output "repository_urls" {
  description = "Map of repository name to URL"
  value = {
    for name, repo in aws_ecr_repository.this :
    name => repo.repository_url
  }
}

output "registry_id" {
  description = "The account ID of the registry"
  value       = values(aws_ecr_repository.this)[0].registry_id
}