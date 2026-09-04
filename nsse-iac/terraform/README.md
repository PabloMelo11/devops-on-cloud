# devops-on-cloud

Infraestrutura como código (Terraform) do Not So Simple Ecommerce na AWS.

## Módulos

Aplique na ordem:

1. **backend** — bucket S3 e tabela DynamoDB para o state remoto
2. **networking** — VPC, subnets, NAT, Internet Gateway e rotas
3. **server** — EC2 (control plane e workers) e patching via SSM
4. **serverless** — filas, tópicos, storage, bancos, Lambdas e e-mail

```bash
./apply-all.sh
```

Para destruir (ordem inversa nos módulos críticos):

```bash
./destroy-all.sh
```
