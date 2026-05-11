provider "aws" {
  region = data.terraform_remote_state.shared.outputs.region

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Repo      = "mrkrtmn/IaC"
      Stack     = "bots/${var.project_name}"
    }
  }
}
