variable "region" {
  description = "AWS region for every resource in this environment."
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Environment name, used in resource names and tags."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}$", var.environment))
    error_message = "Use 2-16 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "powertools_layer_arn" {
  description = "Powertools for AWS Lambda (Python) 3.40.0, arm64, Python 3.13 (from the public SSM parameter /aws/service/powertools/python/arm64/python3.13/3.40.0)."
  type        = string
  default     = "arn:aws:lambda:eu-west-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python313-arm64:43"
}
