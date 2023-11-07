# Aws - Kubernetes IaaC 
This repo contains a fully automated IaaC deployment with CloudFormation for a Private-Public Cloud Aws Infrastructure on top of which a Self Managed Kuberentes Cluster is created. 
The Self Managed Kuberentes Cluster is equipped with a lot of EKS features like ClusterAutoscaler, NodeTerminationHanlder in QueueProcess mode, EBS CSI Driver, AWS CloudProviderController, AWS LoadBalancerController, etc...
CNI of choice is Calico for its flexibility, deployed with Broader Gateway Protocol in IPIP encapsulation mode. 

Main Components:
1. VPC and VPC related resources
2. Bastion Host ASG
3. HA Keycloak Authorization Server as Custom IDP 
4. AuroraDB Cluster for persistence
5. HA Kubernetes Stack
