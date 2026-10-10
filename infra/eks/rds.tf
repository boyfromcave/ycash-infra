# RDS Postgres for yindex (values-eks.yaml: yindex.postgres.enabled=false, the url from Secrets
# Manager `<secrets_prefix>/yindex-postgres` {url}). The index is rebuilt from the node in
# minutes, so the instance is small and single-AZ by default (var.rds_multi_az); the data is
# derived state, not the system of record.
resource "random_password" "yindex_postgres" {
  length  = 32
  special = false
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds"
  description = "yindex Postgres: 5432 from the EKS nodes"
  vpc_id      = module.vpc.vpc_id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.10"

  identifier = "${var.name}-yindex"

  engine               = "postgres"
  engine_version       = "17"
  family               = "postgres17"
  major_engine_version = "17"
  instance_class       = var.rds_instance_class

  allocated_storage     = var.rds_allocated_gb
  max_allocated_storage = var.rds_allocated_gb * 5
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "yindex"
  username = "yindex"
  port     = 5432
  # terraform owns the password so it can compose the url below; not manage_master_user_password.
  manage_master_user_password = false
  password                    = random_password.yindex_postgres.result

  multi_az               = var.rds_multi_az
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]

  backup_retention_period = 3
  deletion_protection     = false
  skip_final_snapshot     = true
  apply_immediately       = true

  performance_insights_enabled = false
  create_monitoring_role       = false
  monitoring_interval          = 0
}

locals {
  # RDS Postgres 15+ forces TLS (rds.force_ssl=1); pgx honours sslmode=require.
  yindex_postgres_url = "postgres://yindex:${random_password.yindex_postgres.result}@${module.rds.db_instance_address}:5432/yindex?sslmode=require"
}
