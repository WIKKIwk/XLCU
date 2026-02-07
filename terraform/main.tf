# ============================================
# TITAN - Terraform Infrastructure
# ============================================
# File: terraform/main.tf
# ============================================
terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.0"
    }
  }
  
  backend "s3" {
    bucket         = "titan-terraform-state"
    key            = "infrastructure/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "titan-terraform-locks"
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

provider "kubectl" {
  config_path = var.kubeconfig_path
}

# ============================================
# File: terraform/variables.tf
# ============================================
variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/config"
}

variable "domain" {
  description = "Domain name for the application"
  type        = string
  default     = "titan.accord.uz"
}

variable "image_registry" {
  description = "Container image registry"
  type        = string
  default     = "registry.accord.uz"
}

variable "core_replicas" {
  description = "Number of Titan Core replicas"
  type        = number
  default     = 1
}

variable "bridge_replicas" {
  description = "Number of Titan Bridge replicas"
  type        = number
  default     = 3
}

variable "db_password" {
  description = "PostgreSQL password"
  type        = string
  sensitive   = true
}

variable "telegram_bot_token" {
  description = "Telegram Bot Token"
  type        = string
  sensitive   = true
}

variable "erp_api_key" {
  description = "ERP API Key"
  type        = string
  sensitive   = true
}

variable "erp_api_secret" {
  description = "ERP API Secret"
  type        = string
  sensitive   = true
}

# ============================================
# File: terraform/namespaces.tf
# ============================================
resource "kubernetes_namespace" "titan" {
  metadata {
    name = "titan-${var.environment}"
    
    labels = {
      name        = "titan-${var.environment}"
      environment = var.environment
      managed_by  = "terraform"
    }
    
    annotations = {
      description = "Titan RFID/Zebra Warehouse System"
    }
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    
    labels = {
      name       = "monitoring"
      managed_by = "terraform"
    }
  }
}

# ============================================
# File: terraform/secrets.tf
# ============================================
resource "kubernetes_secret" "titan_secrets" {
  metadata {
    name      = "titan-secrets"
    namespace = kubernetes_namespace.titan.metadata[0].name
  }
  
  type = "Opaque"
  
  data = {
    "ConnectionStrings__PostgreSQL" = "Host=postgres.${kubernetes_namespace.titan.metadata[0].name}.svc.cluster.local;Database=titan;Username=titan;Password=${var.db_password}"
    "DATABASE_URL"                  = "ecto://titan:${var.db_password}@postgres.${kubernetes_namespace.titan.metadata[0].name}.svc.cluster.local/titan_bridge_${var.environment}"
    "SECRET_KEY_BASE"               = random_password.secret_key_base.result
    "SESSION_ENCRYPTION_KEY"        = random_password.session_key.result
    "TITAN_API_TOKEN"               = random_password.api_token.result
    "TELEGRAM_BOT_TOKEN"            = var.telegram_bot_token
    "ERP_API_KEY"                   = var.erp_api_key
    "ERP_API_SECRET"                = var.erp_api_secret
  }
}

resource "random_password" "secret_key_base" {
  length  = 64
  special = false
}

resource "random_password" "session_key" {
  length  = 32
  special = false
}

resource "random_password" "api_token" {
  length  = 32
  special = false
}

# ============================================
# File: terraform/postgres.tf
# ============================================
resource "helm_release" "postgres" {
  name       = "postgres"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "postgresql"
  version    = "13.2.0"
  namespace  = kubernetes_namespace.titan.metadata[0].name
  
  values = [
    <<-EOT
    auth:
      username: titan
      password: ${var.db_password}
      database: titan_${var.environment}
    
    primary:
      persistence:
        enabled: true
        size: 50Gi
        storageClass: standard
      
      resources:
        requests:
          memory: 512Mi
          cpu: 500m
        limits:
          memory: 2Gi
          cpu: 2000m
      
      podDisruptionBudget:
        enabled: true
        minAvailable: 1
    
    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
    EOT
  ]
  
  depends_on = [kubernetes_namespace.titan]
}

# ============================================
# File: terraform/titan.tf
# ============================================
resource "helm_release" "titan" {
  name       = "titan"
  chart      = "${path.module}/../helm/titan"
  namespace  = kubernetes_namespace.titan.metadata[0].name
  
  values = [
    <<-EOT
    core:
      replicaCount: ${var.core_replicas}
      image:
        registry: ${var.image_registry}
        repository: titan/core
        tag: latest
      nodeSelector:
        hardware: enabled
      tolerations:
        - key: "dedicated"
          operator: "Equal"
          value: "titan-hardware"
          effect: "NoSchedule"
    
    bridge:
      replicaCount: ${var.bridge_replicas}
      image:
        registry: ${var.image_registry}
        repository: titan/bridge
        tag: latest
      autoscaling:
        enabled: true
        minReplicas: ${var.bridge_replicas}
        maxReplicas: 10
    
    ingress:
      enabled: true
      hosts:
        - host: ${var.domain}
          paths:
            - path: /
              pathType: Prefix
              service: bridge
        - host: api.${var.domain}
          paths:
            - path: /
              pathType: Prefix
              service: core
    
    postgresql:
      enabled: false
    EOT
  ]
  
  depends_on = [
    kubernetes_namespace.titan,
    helm_release.postgres,
    kubernetes_secret.titan_secrets
  ]
}

# ============================================
# File: terraform/cert-manager.tf
# ============================================
resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "1.13.0"
  namespace  = "cert-manager"
  
  create_namespace = true
  
  set {
    name  = "installCRDs"
    value = "true"
  }
}

resource "kubectl_manifest" "cluster_issuer" {
  yaml_body = <<-YAML
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: letsencrypt-prod
    spec:
      acme:
        server: https://acme-v02.api.letsencrypt.org/directory
        email: devops@accord.uz
        privateKeySecretRef:
          name: letsencrypt-prod
        solvers:
          - http01:
              ingress:
                class: nginx
  YAML
  
  depends_on = [helm_release.cert_manager]
}

# ============================================
# File: terraform/monitoring.tf
# ============================================
resource "helm_release" "prometheus_stack" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "54.2.2"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  
  values = [
    <<-EOT
    grafana:
      enabled: true
      adminPassword: admin123
      ingress:
        enabled: true
        hosts:
          - grafana.${var.domain}
        tls:
          - secretName: grafana-tls
            hosts:
              - grafana.${var.domain}
    
    prometheus:
      prometheusSpec:
        retention: 30d
        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: standard
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 50Gi
    
    alertmanager:
      enabled: true
      config:
        global:
          slack_api_url: ''
        route:
          receiver: 'default'
          routes:
            - match:
                severity: critical
              receiver: 'critical'
        receivers:
          - name: 'default'
          - name: 'critical'
    EOT
  ]
  
  depends_on = [kubernetes_namespace.monitoring]
}

# ============================================
# File: terraform/outputs.tf
# ============================================
output "namespace" {
  description = "Titan namespace"
  value       = kubernetes_namespace.titan.metadata[0].name
}

output "domain" {
  description = "Application domain"
  value       = var.domain
}

output "api_endpoint" {
  description = "API endpoint"
  value       = "https://api.${var.domain}"
}

output "grafana_url" {
  description = "Grafana URL"
  value       = "https://grafana.${var.domain}"
}

# ============================================
# File: terraform/terraform.tfvars.example
# ============================================
# Copy this file to terraform.tfvars and fill in the values

environment     = "production"
kubeconfig_path = "~/.kube/config"
domain          = "titan.accord.uz"
image_registry  = "registry.accord.uz"

core_replicas   = 1
bridge_replicas = 3

# Sensitive values - use environment variables or secure vault
db_password        = "changeme-strong-password"
telegram_bot_token = "1234567890:ABCdef..."
erp_api_key        = "api_key_here"
erp_api_secret     = "api_secret_here"
