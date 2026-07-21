output "alertmanager_webhook_url" {
  value = "${trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")}/alertmanager-webhook"
}

output "dispatcher_function_name" {
  value = aws_lambda_function.dispatcher.function_name
}

output "dispatcher_log_group" {
  value = aws_cloudwatch_log_group.dispatcher.name
}
