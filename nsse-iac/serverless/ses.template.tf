resource "aws_ses_tempalte" "order_confirmed" {
  name    = "order-confirmed-template"
  subject = "Important"
  html    = "<h1>Invoice gerada {{InvoiceNumber}} com sucesso, para order {{OrderId}}!</h1>"
  text    = "Invoice gerada {{InvoiceNumber}} com sucesso, para order {{OrderId}}!"
}
