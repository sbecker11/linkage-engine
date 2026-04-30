# ALB security group — accepts HTTP and HTTPS from the internet
resource "aws_security_group" "alb" {
  name        = "${var.app}-alb-sg"
  description = "ALB security group for ${var.app}"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.app}-alb-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Allow HTTP from internet"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Allow HTTPS from internet"
}

resource "aws_vpc_security_group_egress_rule" "alb_egress" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all outbound from ALB"
}

# ECS task security group — accepts traffic only from the ALB SG
resource "aws_security_group" "ecs" {
  name        = "${var.app}-ecs-sg"
  description = "ECS task security group for ${var.app}"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.app}-ecs-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "ecs_from_alb" {
  security_group_id            = aws_security_group.ecs.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  description                  = "Allow container port traffic from ALB only"
}

resource "aws_vpc_security_group_egress_rule" "ecs_egress" {
  security_group_id = aws_security_group.ecs.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all outbound from ECS tasks (AWS API, Bedrock, etc.)"
}

# Aurora security group — accepts PostgreSQL only from the ECS task SG
resource "aws_security_group" "db" {
  name        = "${var.app}-db-sg"
  description = "Aurora security group for ${var.app}"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.app}-db-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "db_from_ecs" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.ecs.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "Allow PostgreSQL from ECS tasks only"
}
