variable "project_id" {
  type        = string
  description = "The project id under which all resources will be created"
}

variable "quarantine_pusher" {
  type        = set(string)
  description = "Identities who are allowed to push into the quarantine registry"
}

variable "location" {
  type        = string
  description = "The location in which all resources will be created"
  default     = "europe-west3"
}
