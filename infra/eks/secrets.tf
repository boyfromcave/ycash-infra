# The two secrets External Secrets syncs into the chart's namespace (templates/externalsecrets.yaml):
#   <secrets_prefix>/ycashd-rpc      {rpcuser, rpcpassword}   -> Secret ycashd-rpc
#   <secrets_prefix>/yindex-postgres {url}                    -> Secret yindex-postgres
# Both are generated here, never typed, never in git (AGENTS.md rule 7).
resource "random_password" "ycashd_rpc" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "ycashd_rpc" {
  name                    = "${var.secrets_prefix}/ycashd-rpc"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "ycashd_rpc" {
  secret_id     = aws_secretsmanager_secret.ycashd_rpc.id
  secret_string = jsonencode({ rpcuser = "ycash", rpcpassword = random_password.ycashd_rpc.result })
}

resource "aws_secretsmanager_secret" "yindex_postgres" {
  name                    = "${var.secrets_prefix}/yindex-postgres"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "yindex_postgres" {
  secret_id     = aws_secretsmanager_secret.yindex_postgres.id
  secret_string = jsonencode({ url = local.yindex_postgres_url })
}
