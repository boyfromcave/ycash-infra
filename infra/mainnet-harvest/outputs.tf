output "bucket_name" {
  description = "The results bucket: runs/<run>/ (status.json, harvest.log, result.json) and prefix/<release_tag>/ (the bundles)."
  value       = aws_s3_bucket.results.bucket
}

output "launch_template_id" {
  description = "The launch template (its default version is always the newest): aws ec2 run-instances --launch-template LaunchTemplateId=<id>."
  value       = aws_launch_template.harvest.id
}

output "launch_template_name" {
  description = "The launch template's name (= name_prefix)."
  value       = aws_launch_template.harvest.name
}

output "instance_profile_name" {
  description = "The instance profile the template attaches; the launching role needs iam:PassRole on its role."
  value       = aws_iam_instance_profile.harvest.name
}

output "instance_role_name" {
  description = "The instance role's name (the ARN is account-specific, so it is not an output)."
  value       = aws_iam_role.harvest.name
}

output "subnet_ids" {
  description = "Per zone: the public subnet to launch into (the workflow tries them in order)."
  value       = { for az, s in aws_subnet.public : az => s.id }
}

output "security_group_id" {
  description = "The egress-only security group."
  value       = aws_security_group.harvest.id
}
