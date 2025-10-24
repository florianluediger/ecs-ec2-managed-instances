terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.18.0"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region = "eu-central-1"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.5.0"

  name = "ecs-vpc"
  cidr = "10.0.0.0/16"

  azs = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
}

resource "aws_ecs_cluster" "main" {
  name = "ecs-cluster"
}

resource "aws_security_group" "ecs_sg" {
  name        = "ecs-sg"
  description = "Security group for ECS instances"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow all traffic from within the SG"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "ecs_instance_role" {
  name = "ecs-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

# The attached policy allows the EC2 Instance to perform actions on the ECS Cluster via the ECS Agent
resource "aws_iam_role_policy_attachment" "ecs_instance_role_attachment" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSInstanceRolePolicyForManagedInstances"
}

resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "ecs-instance-profile"
  role = aws_iam_role.ecs_instance_role.name
}

resource "aws_iam_role" "ecs_infrastructure" {
  name               = "ECSInfrastructure"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = ["sts:AssumeRole"]
        Effect  = "Allow"
        Sid = ""
        Principal = {
          Service = "ecs.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_infrastructure" {
  role       = aws_iam_role.ecs_infrastructure.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForManagedInstances"
}

resource "aws_ecs_capacity_provider" "managed_instances" {
  name = "ec2-capacity-provider"
  cluster = aws_ecs_cluster.main.name

  managed_instances_provider {
    infrastructure_role_arn = aws_iam_role.ecs_infrastructure.arn

    instance_launch_template {
      ec2_instance_profile_arn = aws_iam_instance_profile.ecs_instance_profile.arn

      network_configuration {
        subnets         = module.vpc.private_subnets
        security_groups = [aws_security_group.ecs_sg.id]
      }

      storage_configuration {
        storage_size_gib = 30
      }

      instance_requirements {
        memory_mib {
          min = 1024
          max = 4096
        }

        vcpu_count {
          min = 1
          max = 2
        }

        instance_generations = ["current"]
        cpu_manufacturers    = ["intel", "amd"]
      }
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "ecs_cluster_capacity_providers" {
  cluster_name = aws_ecs_cluster.main.name
  capacity_providers = [aws_ecs_capacity_provider.managed_instances.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.managed_instances.name
    base = 0
    weight = 100
  }
}

resource "aws_ecs_task_definition" "nginx_task" {
  family       = "nginx-task"
  requires_compatibilities = ["EC2"]
  network_mode = "awsvpc"
  cpu          = 256
  memory       = 128
  container_definitions = jsonencode([
    {
      name      = "nginx-container"
      image     = "nginx:latest"
      essential = true
    }
  ])
}

resource "aws_ecs_service" "nginx_service" {
  name                               = "nginx-service"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.nginx_task.arn
  desired_count                      = 0
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.managed_instances.name
    weight            = 100
  }
  network_configuration {
    subnets = module.vpc.public_subnets
  }
}

resource "aws_appautoscaling_target" "task_scaling_target" {
  max_capacity       = 3
  min_capacity       = 0
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.nginx_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "task_scaling_policy" {
  name               = "ecs-scale"
  resource_id        = aws_appautoscaling_target.task_scaling_target.resource_id
  scalable_dimension = aws_appautoscaling_target.task_scaling_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.task_scaling_target.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ExactCapacity"
    cooldown                = 30
    metric_aggregation_type = "Minimum"

    step_adjustment {
      metric_interval_upper_bound = 1.0
      scaling_adjustment          = 0
    }
    step_adjustment {
      metric_interval_lower_bound = 1.0
      scaling_adjustment          = 3
    }
  }
}

resource "aws_sqs_queue" "testing_queue" {
  name = "testing-queue"
}

resource "aws_cloudwatch_metric_alarm" "queue_messages_alarm" {
  alarm_name          = "queue-messages-alarm"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = "30"
  statistic           = "Sum"
  threshold           = "0"
  alarm_description   = "Alarm when there are messages in the testing queue."
  alarm_actions = [aws_appautoscaling_policy.task_scaling_policy.arn]
  ok_actions = [aws_appautoscaling_policy.task_scaling_policy.arn]
  dimensions = {
    QueueName = aws_sqs_queue.testing_queue.name
  }
}
