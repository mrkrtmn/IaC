terraform {
  backend "s3" {
    bucket         = "mrkrtmn-iac-tfstate"
    key            = "bots/faitpro-bot/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-locks"
    encrypt        = true
  }
}
