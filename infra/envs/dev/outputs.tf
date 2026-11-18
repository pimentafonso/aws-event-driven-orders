output "api_endpoint" {
  description = "Base URL of the orders API (requests must be SigV4-signed)."
  value       = module.api.api_endpoint
}

output "function_name" {
  description = "Name of the orders API function."
  value       = module.api.function_name
}
