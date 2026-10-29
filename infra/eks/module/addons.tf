# The add-ons values-eks.yaml expects, as helm_release resources rather than a documented
# helm sequence: the IRSA role ARNs, the VPC id, the domain and the zone flow in from the
# resources above without being copied by hand, the chart versions are pinned in one place
# (var.addon_versions; kind-up.sh uses the same Envoy Gateway and cert-manager), and
# `terraform destroy` removes them in reverse order — the Load Balancer Controller must go
# after the chart's Gateway (eks-down) or the NLB is orphaned. The cost: the helm provider
# needs the cluster at plan time; on a first apply the exec auth defers until the cluster
# exists, and the runbook's fallback is `terraform apply -target=module.eks` first.
#
# Envoy Gateway and cert-manager are installed exactly as scripts/kind-up.sh installs them.
resource "helm_release" "envoy_gateway" {
  name             = "eg"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  version          = var.addon_versions.envoy_gateway
  namespace        = "envoy-gateway-system"
  create_namespace = true
  wait             = true
  # the gRPC-web EnvoyPatchPolicy in the chart (templates/gateway/routes.yaml)
  set {
    name  = "config.envoyGateway.extensionApis.enableEnvoyPatchPolicy"
    value = "true"
  }
  depends_on = [module.eks]
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.addon_versions.cert_manager
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true
  set {
    name  = "crds.enabled"
    value = "true"
  }
  # Route53 DNS-01 through IRSA (module.cert_manager_irsa)
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.cert_manager_irsa.iam_role_arn
  }
  depends_on = [module.eks]
}

resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.addon_versions.lb_controller
  namespace  = "kube-system"
  wait       = true
  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "region"
    value = local.region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.lb_controller_irsa.iam_role_arn
  }
  depends_on = [module.eks]
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.addon_versions.external_secrets
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true
  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "external-secrets"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_secrets_irsa.iam_role_arn
  }
  depends_on = [module.eks]
}

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = var.addon_versions.external_dns
  namespace        = "external-dns"
  create_namespace = true
  wait             = true
  set {
    name  = "provider.name"
    value = "aws"
  }
  set {
    name  = "txtOwnerId"
    value = var.name
  }
  set {
    name  = "policy"
    value = "sync"
  }
  set_list {
    name  = "domainFilters"
    value = [var.domain]
  }
  # the chart annotates the Envoy Service with external-dns.alpha.kubernetes.io/hostname
  set_list {
    name  = "sources"
    value = ["service"]
  }
  set {
    name  = "serviceAccount.name"
    value = "external-dns"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_dns_irsa.iam_role_arn
  }
  depends_on = [module.eks]
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.addon_versions.metrics_server
  namespace  = "kube-system"
  wait       = true
  depends_on = [module.eks]
}

# kube-prometheus-stack: the ServiceMonitor CRD the chart's monitoring.serviceMonitor needs, plus
# Prometheus, Alertmanager and Grafana (ClusterIP; reach Grafana with kubectl port-forward).
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.addon_versions.kube_prometheus_stack
  namespace        = "monitoring"
  create_namespace = true
  wait             = true
  timeout          = 900
  # scrape every ServiceMonitor, not only those with the release label
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "15d"
  }
  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName"
    value = "gp3"
  }
  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage"
    value = "50Gi"
  }
  depends_on = [module.eks, kubernetes_storage_class.gp3]
}

# The two cluster-scoped objects the chart's values reference by name — ClusterIssuer
# letsencrypt-prod and ClusterSecretStore aws-secrets-manager — as a tiny local chart
# (charts/cluster-config): a kubernetes_manifest would need both CRDs at plan time, a
# helm_release installs them after the operators that own the CRDs.
resource "helm_release" "cluster_config" {
  name      = "cluster-config"
  chart     = "${path.module}/charts/cluster-config"
  namespace = "kube-system"
  wait      = true
  set {
    name  = "acmeEmail"
    value = var.acme_email
  }
  set {
    name  = "region"
    value = local.region
  }
  set {
    name  = "hostedZoneId"
    value = var.hosted_zone_id
  }
  depends_on = [helm_release.cert_manager, helm_release.external_secrets]
}
