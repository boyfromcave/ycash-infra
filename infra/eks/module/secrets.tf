# The secrets External Secrets syncs into each chart namespace (templates/externalsecrets.yaml):
#   <secrets_prefix>[/<network>]/ycashd-rpc      {rpcuser, rpcpassword}   -> Secret ycashd-rpc
#   <secrets_prefix>[/<network>]/yindex-postgres {url}                    -> Secret yindex-postgres
# One pair per network with var.networks (each network its own RPC credential and its own
# database), one pair without a network segment otherwise. All generated here, never typed, never
# in git (AGENTS.md rule 7).
locals {
  # stack key -> its database: "" is the single, network-less endpoint (var.networks empty)
  stacks = length(var.networks) == 0 ? { "" = "yindex" } : { for n in var.networks : n => "yindex_${replace(n, "-", "_")}" }
}

resource "random_password" "ycashd_rpc" {
  for_each = local.stacks
  length   = 40
  special  = false
}

resource "aws_secretsmanager_secret" "ycashd_rpc" {
  for_each = local.stacks
  #checkov:skip=CKV2_AWS_57:a node RPC password between pods of one namespace; rotation is a terraform taint (docs/eks-runbook.md, day two)
  #checkov:skip=CKV_AWS_149:the account's aws/secretsmanager key; a customer key adds a key policy to run for a testnet credential
  name                    = join("/", compact([var.secrets_prefix, each.key, "ycashd-rpc"]))
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "ycashd_rpc" {
  for_each      = local.stacks
  secret_id     = aws_secretsmanager_secret.ycashd_rpc[each.key].id
  secret_string = jsonencode({ rpcuser = "ycash", rpcpassword = random_password.ycashd_rpc[each.key].result })
}

resource "aws_secretsmanager_secret" "yindex_postgres" {
  for_each = local.stacks
  #checkov:skip=CKV2_AWS_57:derived from the RDS password terraform owns; rotation is a terraform taint
  #checkov:skip=CKV_AWS_149:the account's aws/secretsmanager key, as above
  name                    = join("/", compact([var.secrets_prefix, each.key, "yindex-postgres"]))
  recovery_window_in_days = 0
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "yindex_postgres" {
  for_each      = local.stacks
  secret_id     = aws_secretsmanager_secret.yindex_postgres[each.key].id
  secret_string = jsonencode({ url = local.yindex_postgres_url[each.key] })
}
