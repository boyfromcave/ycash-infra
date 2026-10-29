# One database per network on the one RDS instance (var.networks; secrets.tf local.stacks). The
# instance is in the database subnets, reachable only from the cluster's nodes (rds.tf), so the
# databases are created from inside the cluster: a Job that runs psql against the instance's own
# `yindex` database and creates each missing `yindex_<network>`. Idempotent (CREATE only if absent;
# a database is never dropped here). Its name carries a hash of the list, so adding a network runs
# it again; a removed network's database stays until dropped by hand (docs/eks-runbook.md).
locals {
  network_databases = length(var.networks) == 0 ? [] : sort(values(local.stacks))
  db_job_suffix     = substr(sha1(join(",", local.network_databases)), 0, 8)
}

resource "kubernetes_secret_v1" "yindex_admin" {
  count = length(var.networks) == 0 ? 0 : 1
  metadata {
    name      = "yindex-db-admin"
    namespace = "kube-system"
  }
  data = {
    url = "postgres://yindex:${random_password.yindex_postgres.result}@${module.rds.db_instance_address}:5432/yindex?sslmode=require"
  }
  depends_on = [module.eks]
}

resource "kubernetes_job_v1" "yindex_databases" {
  count = length(var.networks) == 0 ? 0 : 1
  metadata {
    name      = "yindex-databases-${local.db_job_suffix}"
    namespace = "kube-system"
    labels    = { "app.kubernetes.io/name" = "yindex-databases" }
  }
  spec {
    backoff_limit = 6
    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "yindex-databases" }
      }
      spec {
        restart_policy                  = "OnFailure"
        automount_service_account_token = false
        security_context {
          run_as_non_root = true
          run_as_user     = 70 # postgres:17-alpine's postgres user
          run_as_group    = 70
          seccomp_profile { type = "RuntimeDefault" }
        }
        container {
          name              = "psql"
          image             = "postgres:17-alpine"
          image_pull_policy = "IfNotPresent"
          command           = ["/bin/sh", "-c"]
          args = [<<-EOT
            set -eu
            for db in $DATABASES; do
              if [ "$(psql "$ADMIN_URL" -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'")" = 1 ]; then
                echo "$db: exists"
              else
                psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$db\""
                echo "$db: created"
              fi
            done
          EOT
          ]
          env {
            name  = "DATABASES"
            value = join(" ", local.network_databases)
          }
          env {
            name = "ADMIN_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.yindex_admin[0].metadata[0].name
                key  = "url"
              }
            }
          }
          env {
            name  = "HOME"
            value = "/tmp"
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            privileged                 = false
            capabilities { drop = ["ALL"] }
          }
          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "128Mi" }
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }
        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }
  wait_for_completion = true
  timeouts {
    create = "10m"
    update = "10m"
  }
  depends_on = [module.rds]
}
