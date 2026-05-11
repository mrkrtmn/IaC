# IAM user para Jenkins: solo permisos para push a ECR, registrar task defs y update services.
# La access key se obtiene como output sensible y se mete en Jenkins Credentials con id `aws-jenkins`.

resource "aws_iam_user" "jenkins" {
  name = "${var.name_prefix}-jenkins"
}

resource "aws_iam_access_key" "jenkins" {
  user = aws_iam_user.jenkins.name
}

resource "aws_iam_user_policy" "jenkins" {
  name = "${var.name_prefix}-jenkins-policy"
  user = aws_iam_user.jenkins.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
          "ecr:ListImages"
        ]
        Resource = "arn:aws:ecr:${var.region}:*:repository/*"
      },
      {
        Sid    = "ECSDeploy"
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
          "ecs:ListServices",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService"
        ]
        Resource = "*"
      },
      {
        Sid    = "PassRoleECS"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          aws_iam_role.ecs_task_execution.arn,
          aws_iam_role.ecs_task.arn
        ]
      },
      {
        Sid      = "STSIdentity"
        Effect   = "Allow"
        Action   = "sts:GetCallerIdentity"
        Resource = "*"
      }
    ]
  })
}
