provider "aws" {
  profile = var.profile
  region  = var.region
}

variable "env_id" {
  type        = string
  description = "identifier for the cluster"
  default     = "chen"
}

variable "profile" {
  type        = string
  description = "credentials profile to use"
  default     = null
}

variable "region" {
  type        = string
  description = "region to depoly into"
  default     = "eu-west-1"
}

variable "vpc_cidr_block" {
  type        = string
  description = "cidr block for the vpc"
  default     = "172.16.0.0/16"
}

variable "node_count" {
  type        = number
  description = "number of nodes excluding the controller, for e.g node_count=3 then 1 controller and 3 nodes, 4 vms in total."
  default     = 2
}

variable "ami" {
  type        = string
  description = "ami for node vm"
  default     = "ami-089cc16f7f08c4457"
}

variable "node_instance_type" {
  type        = string
  description = "instance type for node"
  default     = "t3.medium"
}

variable "key_pair" {
  type        = string
  description = "key pair for instance ssh access"
  //  validation {
  //    condition     = var.key_pair != null
  //    error_message = "Enter key-pair name."
  //  }
}

data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}
data "aws_iam_role" "caller" {
  name = split("/", data.aws_caller_identity.current.arn)[1]
}


