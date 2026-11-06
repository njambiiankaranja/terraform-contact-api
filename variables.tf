variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region to deploy into"
}

variable "project_name" {
  type        = string
  default     = "contact-api"
  description = "Prefix for resource names and the Project tag"
}

variable "notification_email" {
  type        = string
  description = "Email address that receives a message for every submission"

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.notification_email))
    error_message = "notification_email must be a valid email address."
  }
}

variable "allowed_origins" {
  type        = list(string)
  default     = ["*"]
  description = "Websites allowed to call the API from a browser. Restrict this to your site's URL once it is live."
}