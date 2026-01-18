variable "project_name" {
  type        = string
  description = "Name of the project"
}

variable "git_repository" {
  type        = string
  description = "git respository from which this resource is from"
}

variable "role_to_assume_arn" {
  type        = string
  description = "ARN of the role to assume to deploy the resources"
  default     = ""
}

variable "failure_notification_receivers" {
  type        = string
  description = "List of emails to which to send failure notifications in the form of a string, with each email adress separated by a coma"
}

variable "authorized_slack_users" {
  type        = string
  description = "List of user slack ids which are authorized to use this chatbot in the form of a string, with each id separated by a comma"
}
