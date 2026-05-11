resource "aws_iam_user" "terraform" {
  name = "${var.name_prefix}-iac-terraform"
}

resource "aws_iam_access_key" "terraform" {
  user = aws_iam_user.terraform.name
}

resource "aws_iam_user_policy_attachment" "terraform_admin" {
  user       = aws_iam_user.terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
