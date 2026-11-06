output "api_url" {
  description = "POST form submissions to this URL"
  value       = "${aws_apigatewayv2_api.api.api_endpoint}/submit"
}

output "table_name" {
  description = "DynamoDB table holding the submissions"
  value       = aws_dynamodb_table.submissions.name
}