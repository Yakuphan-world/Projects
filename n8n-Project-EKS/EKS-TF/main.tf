################################################################################
# NETWORK DATA
################################################################################

data "aws_vpc" "default" {
  default = true
}

# Public subnets only (required for internet-facing ALB)
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "tag:kubernetes.io/role/elb"
    values = ["1"]
  }
}


################################################################################
# EKS CLUSTER ROLE
################################################################################

resource "aws_iam_role" "cluster_role" {
  name = "eks-cluster-cloud-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster_role.name
}

################################################################################
# EKS CLUSTER
################################################################################

resource "aws_eks_cluster" "example" {
  name     = var.cluster_name # Değişken kullanıyorsan var.cluster_name olarak bırakabilirsin
  role_arn = aws_iam_role.cluster_role.arn

  vpc_config {
    subnet_ids = data.aws_subnets.public.ids
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

################################################################################
# NODE GROUP ROLE
################################################################################

resource "aws_iam_role" "node_role" {
  name = "eks-node-group-cloud-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  ])

  policy_arn = each.value
  role       = aws_iam_role.node_role.name
}

################################################################################
# NODE GROUP
################################################################################

resource "aws_eks_node_group" "example" {
  cluster_name    = aws_eks_cluster.example.name
  node_group_name = "Node-cloud"
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = data.aws_subnets.public.ids

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.medium"]

  depends_on = [aws_iam_role_policy_attachment.node_policies]
}

################################################################################
# OIDC PROVIDER (IRSA BASE)
################################################################################

data "tls_certificate" "eks" {
  url = aws_eks_cluster.example.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.example.identity[0].oidc[0].issuer
}

################################################################################
# EBS CSI DRIVER
################################################################################

resource "aws_iam_role" "ebs_csi_role" {
  name = "eks-ebs-csi-driver-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Condition = {
        StringEquals = {
          # DÜZELTME: Fonksiyon kullanılan anahtarlar parantez içine alınmalıdır.
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" : "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_role.name
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.example.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_role.arn

  depends_on = [aws_eks_node_group.example]
}

################################################################################
# AWS LOAD BALANCER CONTROLLER (ALB)
################################################################################

resource "aws_iam_policy" "alb_controller_policy" {
  name   = "AWSLoadBalancerControllerIAMPolicy-V2"
  # Not: alb_iam_policy.json dosyasının bu dizinde olduğundan emin ol.
  policy = file("${path.module}/alb_iam_policy.json")
}

resource "aws_iam_role" "alb_controller_role" {
  name = "eks-alb-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # DÜZELTME: Fonksiyon kullanılan anahtarlar parantez içine alınmalıdır.
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" : "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "alb_attach" {
  policy_arn = aws_iam_policy.alb_controller_policy.arn
  role       = aws_iam_role.alb_controller_role.name
}

resource "kubernetes_service_account" "alb_sa" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.alb_controller_role.arn
    }
  }

  depends_on = [aws_iam_role_policy_attachment.alb_attach]
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"

  set {
    name  = "clusterName"
    value = aws_eks_cluster.example.name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.alb_sa.metadata[0].name
  }

  set {
    name  = "region"
    value = "eu-central-1"
  }

  set {
    name  = "vpcId"
    value = data.aws_vpc.default.id
  }

  depends_on = [
    aws_eks_node_group.example,
    kubernetes_service_account.alb_sa
  ]
}

