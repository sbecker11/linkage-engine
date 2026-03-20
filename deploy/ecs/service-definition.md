# ECS/Fargate Service Template Notes

Create an ECS service using this task definition family:

- Cluster: `linkage-engine-cluster`
- Service name: `linkage-engine-service`
- Launch type: `FARGATE`
- Desired tasks: `2`
- Task definition family: `linkage-engine`
- Platform version: `LATEST`
- Deployment strategy: rolling update (min healthy 50, max 200)

Networking:

- Subnets: private app subnets in your VPC
- Security group (service): allow inbound `8080` from ALB SG only
- Assign public IP: `DISABLED`

Load balancer:

- Type: Application Load Balancer
- Target group: HTTP `8080`, health check path `/actuator/health`
- Listener: HTTPS `443` forwarding to target group

IAM:

- Task execution role: pull from ECR + write CloudWatch logs
- Task role: `bedrock:InvokeModel`, `bedrock:InvokeModelWithResponseStream`, and Secrets Manager read permissions
