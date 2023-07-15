data "terraform_remote_state" "aws_tfstate" {
  backend = "local"
  config = {
    path = "${path.root}/../aws/terraform.tfstate"
  }
}

data "aws_eks_cluster_auth" "this" {
  name = local.cluster_name
}

data "aws_region" "current" {}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = base64decode(local.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", local.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = base64decode(local.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", local.cluster_name]
    }
  }
}

locals {
  cluster_name                       = data.terraform_remote_state.aws_tfstate.outputs.cluster_name
  cluster_endpoint                   = data.terraform_remote_state.aws_tfstate.outputs.cluster_endpoint
  cluster_version                    = data.terraform_remote_state.aws_tfstate.outputs.cluster_version
  oidc_provider_arn                  = data.terraform_remote_state.aws_tfstate.outputs.oidc_provider_arn
  cluster_certificate_authority_data = data.terraform_remote_state.aws_tfstate.outputs.cluster_certificate_authority_data
  region                             = data.aws_region.current.name
  kubeconfig = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = "terraform"
    clusters = [{
      name = local.cluster_name
      cluster = {
        certificate-authority-data = local.cluster_certificate_authority_data
        server                     = local.cluster_endpoint
      }
    }]
    contexts = [{
      name = "terraform"
      context = {
        cluster = local.cluster_name
        user    = "terraform"
      }
    }]
    users = [{
      name = "terraform"
      user = {
        token = data.aws_eks_cluster_auth.this.token
      }
    }]
  })
  tags = {}
}

module "eks_blueprints_addons" {
  source = "aws-ia/eks-blueprints-addons/aws"

  cluster_name      = local.cluster_name
  cluster_endpoint  = local.cluster_endpoint
  cluster_version   = local.cluster_version
  oidc_provider_arn = local.oidc_provider_arn

  eks_addons = {
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

  enable_metrics_server = true
  metrics_server = {
    name          = "metrics-server"
    chart_version = "3.10.0"
    repository    = "https://kubernetes-sigs.github.io/metrics-server/"
    namespace     = "kube-system"
    values        = [templatefile("${path.module}/helm_values/values-metrics-server.yaml", {})]
  }

  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller = {
    name       = "aws-load-balancer-controller"
    chart      = "aws-load-balancer-controller"
    repository = "https://aws.github.io/eks-charts"
    version    = "1.4.8"
    namespace  = "kube-system"
    values = [templatefile("${path.module}/helm_values/values-aws-load-balancer-controller.yaml", {
      clusterName = "${local.cluster_name}"
      region      = "${local.region}"
    })]
  }

  enable_ingress_nginx = true
  ingress_nginx = {
    name       = "ingress"
    chart      = "ingress-nginx"
    repository = "https://kubernetes.github.io/ingress-nginx"
    version    = "v4.5.2"
    namespace  = "ingress"
    values     = [templatefile("${path.module}/helm_values/values-nginx-ingress.yaml", {})]
  }

  tags = {}
}

resource "null_resource" "install_calico_enterprise_crds" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KUBECONFIG = base64encode(local.kubeconfig)
    }
    command = <<-EOT
      kubectl apply --server-side --force-conflicts -f https://downloads.tigera.io/ee/v3.17.0/manifests/operator-crds.yaml --kubeconfig <(echo $KUBECONFIG | base64 -d)
      kubectl apply --server-side --force-conflicts -f https://downloads.tigera.io/ee/v3.17.0/manifests/prometheus-operator-crds.yaml --kubeconfig <(echo $KUBECONFIG | base64 -d)
      kubectl apply --server-side --force-conflicts -f https://downloads.tigera.io/ee/v3.17.0/manifests/eck-operator-crds.yaml --kubeconfig <(echo $KUBECONFIG | base64 -d)
    EOT
  }
}