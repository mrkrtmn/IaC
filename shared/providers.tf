provider "aws" {
  region = var.region

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Repo      = "mrkrtmn/IaC"
      Stack     = "shared"
    }
  }
}
