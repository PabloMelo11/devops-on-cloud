resource "aws_sns_topic" "order_confirmed_topic" {
  name                             = var.order_confirmed_topic.name
  policy                           = data.aws_iam_policy_document.sns_policy.json
  sqs_success_feedback_sample_rate = var.order_confirmed_topic.sqs_success_feedback_sample_rate
  sqs_success_feedback_role_arn    = aws_iam_role.sns_topic_role.arn
  sqs_failure_feedback_role_arn    = aws_iam_role.sns_topic_role.arn
  tags                             = var.tags
}
