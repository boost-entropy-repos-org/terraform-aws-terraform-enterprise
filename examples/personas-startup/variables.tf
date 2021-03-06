variable "prefix" {
  type        = string
  default     = "tfe"
  description = "This prefix is used in the subdomain and friendly_name generation."
}

variable "tfe_subdomain" {
  type        = string
  default     = null
  description = <<DOC
    Subdomain for accessing the Terraform Enterprise UI. If this value is null,
    a random_pet-based name will be generated and used.
DOC
}

variable "domain_name" {
  type        = string
  description = "Domain for creating the Terraform Enterprise subdomain on."
}

variable "license_path" {
  type        = string
  description = "File path to Replicated license file"
}

variable "existing_aws_keypair" {
  type        = string
  default     = null
  description = "An existing AWS Key Pair to SSH into the Bastion host."
}

variable "acm_certificate_arn" {
  type        = string
  description = "The ARN of an existing ACM certificate."
}
