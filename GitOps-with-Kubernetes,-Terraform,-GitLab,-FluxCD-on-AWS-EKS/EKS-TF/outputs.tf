output "cluster_endpoint" {
  value = aws_eks_cluster.example.endpoint
}

output "cluster_name" {
  value = aws_eks_cluster.example.name
}