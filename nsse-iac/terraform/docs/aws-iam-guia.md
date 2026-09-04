# Guia Completo de AWS IAM

> Guia detalhado sobre Identity and Access Management na AWS — do conceito básico ao funcionamento interno.

---

## Índice

1. [O que é IAM](#1-o-que-é-iam)
2. [Policy — o que é, formato e particularidades](#2-policy--o-que-é-formato-e-particularidades)
3. [Identidades — quem são e particularidades](#3-identidades--quem-são-e-particularidades)
4. [Trust Policy](#4-trust-policy)
5. [Permission Policy](#5-permission-policy)
6. [Identity-based Policy](#6-identity-based-policy)
7. [Resource-based Policy](#7-resource-based-policy)
8. [Managed Policy](#8-managed-policy)
9. [Inline Policy](#9-inline-policy)
10. [Relação entre os conceitos](#10-relação-entre-os-conceitos)
11. [Assume Role](#11-assume-role)
12. [Instance Profile](#12-instance-profile)
13. [ExternalID](#13-externalid)
14. [Como a AWS valida permissões](#14-como-a-aws-valida-permissões)

---

## 1. O que é IAM

IAM significa **Identity and Access Management** — é o serviço da AWS responsável por controlar **quem pode fazer o quê** dentro da sua conta.

Pense na AWS como um prédio corporativo com várias salas (S3, EC2, RDS, Lambda...). O IAM é o sistema de segurança desse prédio: define quem tem crachá, quais salas cada crachá abre, e quais ações podem ser feitas dentro de cada sala.

O IAM responde duas perguntas fundamentais em toda requisição:

```
1. Autenticação → "Você é quem diz ser?"
2. Autorização  → "Você tem permissão para fazer isso?"
```

**Características importantes do IAM:**

- É **global** — não pertence a uma região específica
- É **gratuito** — você não paga pelo IAM, só pelos recursos que ele protege
- Toda requisição na AWS passa pelo IAM, sem exceção
- O princípio base é **least privilege** (menor privilégio) — por padrão, tudo é negado

---

## 2. Policy — o que é, formato e particularidades

Uma Policy é um **documento JSON que define permissões**. É a unidade básica de controle de acesso no IAM — tudo gira em torno dela.

Sozinha, uma policy não faz nada. Ela precisa estar **associada a uma identidade ou a um recurso** para ter efeito.

### Estrutura base de qualquer policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "NomeOpcionaldaRegra",
      "Effect": "Allow",
      "Principal": { },
      "Action": [ ],
      "Resource": [ ],
      "Condition": { }
    }
  ]
}
```

### Detalhamento de cada campo

**`Version`**

Sempre use `"2012-10-17"`. Existe uma versão anterior (`2008-10-17`) que não suporta variáveis de policy como `${aws:username}`. Na prática, sempre será esse valor.

**`Statement`**

Array de regras. Uma policy pode ter quantas regras quiser. Cada uma é avaliada independentemente.

**`Sid`** (Statement ID)

Opcional. Identificador textual da regra — serve como documentação. Sem espaços, sem caracteres especiais.

**`Effect`**

Obrigatório. Só aceita dois valores:
- `"Allow"` → permite a ação
- `"Deny"` → nega a ação (sempre tem prioridade sobre Allow)

**`Principal`**

Quem está sendo afetado pela regra. **Só existe em Resource-based Policies e Trust Policies** — não existe em Identity-based Policies.

```json
// Serviço AWS
"Principal": { "Service": "lambda.amazonaws.com" }

// Usuário IAM específico
"Principal": { "AWS": "arn:aws:iam::123456789012:user/joao" }

// Role específica
"Principal": { "AWS": "arn:aws:iam::123456789012:role/minha-role" }

// Conta inteira (qualquer identidade da conta)
"Principal": { "AWS": "arn:aws:iam::123456789012:root" }

// Provedor externo (OIDC)
"Principal": { "Federated": "token.actions.githubusercontent.com" }

// Qualquer entidade (CUIDADO — muito permissivo)
"Principal": "*"
```

**`Action`**

Quais operações são permitidas ou negadas. Segue o formato `serviço:Operação`.

```json
// Ação única
"Action": "s3:GetObject"

// Múltiplas ações
"Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]

// Wildcard — todas as ações de leitura do S3
"Action": "s3:Get*"

// Wildcard — todas as ações do S3
"Action": "s3:*"

// Wildcard — absolutamente tudo (AdministratorAccess)
"Action": "*"
```

**`Resource`**

Em qual recurso específico a ação se aplica. Usa o formato ARN.

```json
// Bucket inteiro (operações no bucket em si: ListBucket, etc.)
"Resource": "arn:aws:s3:::meu-bucket"

// Objetos dentro do bucket
"Resource": "arn:aws:s3:::meu-bucket/*"

// Tabela DynamoDB específica
"Resource": "arn:aws:dynamodb:us-east-1:123456789012:table/minha-tabela"

// Qualquer recurso
"Resource": "*"

// Múltiplos recursos
"Resource": [
  "arn:aws:s3:::bucket-a/*",
  "arn:aws:s3:::bucket-b/*"
]
```

**`Condition`**

Opcional mas poderoso. Adiciona critérios extras — a permissão só é válida se a condição for verdadeira.

```json
"Condition": {
  // Só permite se o upload usar criptografia
  "StringEquals": {
    "s3:x-amz-server-side-encryption": "AES256"
  },

  // Só permite com MFA ativo
  "Bool": {
    "aws:MultiFactorAuthPresent": "true"
  },

  // Só permite de IPs específicos
  "IpAddress": {
    "aws:SourceIp": ["192.168.1.0/24"]
  },

  // Só permite em regiões específicas
  "StringEquals": {
    "aws:RequestedRegion": "us-east-1"
  }
}
```

> Múltiplas condições dentro do mesmo bloco são tratadas como **AND** — todas precisam ser verdadeiras.

---

## 3. Identidades — quem são e particularidades

Identidades são **entidades que podem ser autenticadas e autorizadas** no IAM. Existem três tipos.

### 3.1 Usuário (IAM User)

Representa uma **pessoa ou sistema com credenciais fixas e permanentes**.

```
Credenciais de um usuário:
├── Login + senha        → acesso ao Console web
└── Access Key ID
    + Secret Access Key  → acesso programático (CLI, SDK, API)
```

**Particularidades:**
- As credenciais **não expiram automaticamente** — você precisa rotacionar manualmente
- Tem um **ARN único**: `arn:aws:iam::123456789012:user/joao`
- Pode ter **MFA** associado para aumentar segurança
- Pode assumir roles (recebe credenciais temporárias)
- Limite de **5.000 usuários** por conta AWS
- Considerado **legado** para humanos — o padrão atual é AWS SSO. Para humanos, usuários IAM só fazem sentido em cenários muito específicos ou sistemas legados

### 3.2 Grupo (IAM Group)

**Não é uma identidade de verdade** — é um organizador de usuários para facilitar gestão de permissões.

```
Grupo "time-backend"
  ├── Policy A anexada ao grupo
  ├── Policy B anexada ao grupo
  ├── usuário: joao   → herda Policy A e B
  ├── usuário: maria  → herda Policy A e B
  └── usuário: pedro  → herda Policy A e B
```

**Particularidades:**
- **Não pode ser usado como Principal** em nenhuma policy — você não assume um grupo
- **Não pode conter outros grupos** — sem hierarquia
- Um usuário pode estar em **até 10 grupos** simultaneamente
- As permissões do grupo somam com as permissões próprias do usuário
- Limite de **300 grupos** por conta

### 3.3 Role (IAM Role)

É uma **identidade temporária sem dono fixo**. Não pertence a uma pessoa — ela é *assumida* por quem a Trust Policy autorizar.

```
Quem pode assumir uma role:
├── Serviços AWS        (EC2, Lambda, ECS, Glue...)
├── Usuários IAM        (da mesma conta ou de outra)
├── Outras roles        (chain de roles)
└── Identidades externas (GitHub, Google, Active Directory via SAML/OIDC)
```

**Particularidades:**
- **Não tem credenciais fixas** — gera credenciais temporárias via STS a cada uso
- As credenciais expiram entre **15 minutos e 12 horas**
- Tem um **ARN único**: `arn:aws:iam::123456789012:role/minha-role`
- É o **padrão recomendado** para qualquer acesso — humanos ou máquinas
- Todo acesso via role fica registrado no CloudTrail com a sessão identificada

### Comparativo das identidades

| | Usuário | Grupo | Role |
|---|---|---|---|
| Representa | Pessoa ou sistema fixo | Coleção de usuários | Identidade temporária |
| Tem credenciais | Sim — fixas (chave/senha) | Não | Sim — temporárias (STS) |
| Pode fazer login | Sim | Não | Não diretamente |
| Pode ser Principal em policy | Sim | Não | Sim |
| Pode ter policy anexada | Sim | Sim | Sim |
| Expira | Nunca | N/A | Sim (15min a 12h) |
| Usado por serviços AWS | Não recomendado | Não | Sim — padrão |
| Recomendado para humanos | Apenas com SSO | Para organizar permissões | Via SSO + AssumeRole |

---

## 4. Trust Policy

Define **quem tem permissão de assumir a role**. É uma policy especial que vive dentro da role — sem ela, a role não pode ser usada por ninguém.

Tecnicamente é uma Resource-based Policy, porque está no recurso (a role) e define quem pode acessá-la. A ação que ela controla é sempre `sts:AssumeRole` (ou variantes).

### Estrutura completa

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PermiteEC2Assumir",
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "us-east-1"
        }
      }
    }
  ]
}
```

### Variantes da Action

| Action | Quando usar |
|---|---|
| `sts:AssumeRole` | Serviços AWS e usuários IAM |
| `sts:AssumeRoleWithWebIdentity` | OIDC externo (GitHub Actions, Google, Cognito) |
| `sts:AssumeRoleWithSAML` | SSO corporativo via SAML (Active Directory) |

### Exemplos de Principal

```json
// Serviço AWS
{ "Service": "lambda.amazonaws.com" }

// Usuário específico
{ "AWS": "arn:aws:iam::123456789012:user/joao" }

// Role de outra conta assumindo esta
{ "AWS": "arn:aws:iam::987654321098:role/role-deploy" }

// Toda a conta pode assumir (qualquer identidade dela)
{ "AWS": "arn:aws:iam::123456789012:root" }

// GitHub Actions via OIDC
{ "Federated": "token.actions.githubusercontent.com" }
```

### Trust Policy com Condition — exemplo GitHub Actions

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "token.actions.githubusercontent.com"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": "repo:minha-org/meu-repo:ref:refs/heads/main"
    }
  }
}
```

Este exemplo permite que **apenas** o branch `main` do repositório `minha-org/meu-repo` no GitHub assuma essa role.

---

## 5. Permission Policy

Define **o que a identidade pode fazer** após assumir a role. Fica separada da Trust Policy — uma cuida de quem assume, a outra cuida do que pode ser feito depois de assumir.

### Estrutura completa

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LerS3",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::meu-bucket",
        "arn:aws:s3:::meu-bucket/*"
      ]
    },
    {
      "Sid": "NegaDeleteSempre",
      "Effect": "Deny",
      "Action": "s3:DeleteObject",
      "Resource": "arn:aws:s3:::meu-bucket/*"
    }
  ]
}
```

**Não tem o campo `Principal`** — porque quando uma Permission Policy é avaliada, a identidade já é conhecida (é quem está fazendo a requisição).

---

## 6. Identity-based Policy

É qualquer policy **anexada a uma identidade** (usuário, grupo ou role). O termo engloba tanto Managed Policies quanto Inline Policies quando associadas a identidades.

A estrutura é idêntica à Permission Policy — porque Identity-based Policy **é** uma Permission Policy aplicada a uma identidade:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AcessoDynamoDB",
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:Scan"
      ],
      "Resource": "arn:aws:dynamodb:us-east-1:123456789012:table/minha-tabela"
    }
  ]
}
```

**Nunca tem o campo `Principal`** — a identidade já está definida por onde a policy foi anexada.

---

## 7. Resource-based Policy

Anexada **diretamente ao recurso**. Define quem pode acessar aquele recurso específico.

> Nem todo serviço AWS suporta Resource-based Policy. Os principais que suportam:

| Recurso | Nome |
|---|---|
| S3 Bucket | Bucket Policy |
| SQS | Queue Policy |
| SNS | Topic Policy |
| KMS Key | Key Policy |
| Lambda | Function Policy |
| ECR | Repository Policy |
| Secrets Manager | Resource Policy |

### Estrutura completa

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PermiteRoleLer",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::123456789012:role/minha-role"
      },
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": "arn:aws:s3:::meu-bucket/*"
    },
    {
      "Sid": "BloqueiaHTTP",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Condition": {
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    }
  ]
}
```

**Sempre tem `Principal`** — porque o recurso precisa saber quem pode acessá-lo.

---

## 8. Managed Policy

É uma policy que existe como **recurso independente** no IAM — tem seu próprio ARN e pode ser anexada a múltiplas identidades.

### 8.1 AWS Managed Policy

Criada e mantida pela AWS. Você não edita — só referencia pelo ARN.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
```

Este é o documento real da `AWSLambdaBasicExecutionRole`:
`arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole`

A AWS versiona automaticamente — se novos serviços forem adicionados, ela atualiza.

### 8.2 Customer Managed Policy

Você cria e controla. Reutilizável entre múltiplas identidades.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AcessoS3Producao",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::bucket-producao",
        "arn:aws:s3:::bucket-producao/*"
      ]
    }
  ]
}
```

Esta policy pode ser anexada à role da Lambda A, Lambda B, ECS Task C — uma mudança reflete em todos.

Em Terraform:

```hcl
resource "aws_iam_policy" "s3_producao" {
  name   = "acesso-s3-producao"
  policy = jsonencode({ ... })
}

# Reutilizada em múltiplas roles
resource "aws_iam_role_policy_attachment" "lambda_a" {
  role       = aws_iam_role.lambda_a.name
  policy_arn = aws_iam_policy.s3_producao.arn
}

resource "aws_iam_role_policy_attachment" "lambda_b" {
  role       = aws_iam_role.lambda_b.name
  policy_arn = aws_iam_policy.s3_producao.arn
}
```

---

## 9. Inline Policy

Embutida diretamente dentro de uma identidade. **Não existe fora dela** — se a identidade for deletada, a policy some junto.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ChaveKMSExclusiva",
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt",
        "kms:GenerateDataKey"
      ],
      "Resource": "arn:aws:kms:us-east-1:123456789012:key/abc-123-def-456",
      "Condition": {
        "StringEquals": {
          "aws:SourceVpc": "vpc-0abc1234"
        }
      }
    }
  ]
}
```

O documento JSON é **idêntico** às managed policies. A diferença não é no formato — é em como e onde ela vive.

### Managed vs Inline — quando usar cada uma

| | Managed Policy | Inline Policy |
|---|---|---|
| Existe como recurso separado | Sim | Não |
| Pode ser reutilizada | Sim | Não — é 1:1 com a identidade |
| Visível no console IAM | Sim | Só dentro da identidade |
| Deletada com a identidade | Não | Sim |
| Recomendado para | Regras compartilhadas | Permissões únicas e exclusivas |

---

## 10. Relação entre os conceitos

### O mapa completo

```
IDENTIDADES                    POLICIES
──────────                     ────────
Usuário  ──────────────────► Identity-based Policy
  │                              (Managed ou Inline)
  └── pertence a
Grupo    ──────────────────► Identity-based Policy
                                 (Managed ou Inline)

Role ──────────────────────► Trust Policy (quem pode assumir)
  │   └──────────────────► Permission Policy (o que pode fazer)
  │                            (Managed ou Inline)
  │
  └── via Instance Profile (somente EC2)

Recurso (S3, SQS...) ──────► Resource-based Policy
                                 (quem pode acessar)
```

### As diferenças que mais confundem

| | Identity-based | Resource-based | Trust Policy |
|---|---|---|---|
| Onde vive | Na identidade | No recurso | Na role |
| Tem Principal | Não | Sim | Sim |
| Controla | O que a identidade faz | Quem acessa o recurso | Quem assume a role |
| Managed/Inline | Sim | Não (sempre inline no recurso) | Não (sempre inline na role) |

### Quando usar Resource-based vs Identity-based

**Identity-based sozinha funciona** para acesso dentro da mesma conta:

```
Lambda (role com s3:GetObject) → S3 na mesma conta ✓
```

**Resource-based Policy é necessária** em dois casos:

**1. Cross-account** — identidade de outra conta acessando seu recurso. Precisa de **ambas**:

```
Conta A: role com permissão para o bucket da Conta B   ✓
Conta B: bucket policy permitindo a role da Conta A     ✓
                                    └── as duas são necessárias
```

**2. Acesso público ou a serviços** — como CloudFront acessando S3 privado, ou SNS publicando no SQS.

---

## 11. Assume Role

AssumeRole é o mecanismo pelo qual uma identidade **temporariamente se torna** outra identidade (a role), recebendo as permissões dela.

### Por que existe

Sem AssumeRole, você teria que dar todas as permissões diretamente ao usuário ou serviço — o que viola o princípio de menor privilégio e dificulta auditoria.

Com AssumeRole:
- O usuário tem **poucas permissões fixas**
- Assume temporariamente uma role com permissões específicas para uma tarefa
- Tudo rastreado no CloudTrail com o nome da sessão

### O que precisa existir para funcionar

**1. Trust Policy da role precisa permitir o chamador:**

```json
{
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::123456789012:user/joao"
  },
  "Action": "sts:AssumeRole"
}
```

**2. O chamador precisa ter permissão para chamar `sts:AssumeRole`:**

```json
{
  "Effect": "Allow",
  "Action": "sts:AssumeRole",
  "Resource": "arn:aws:iam::123456789012:role/role-deploy-prod"
}
```

Sem isso, mesmo estando na Trust Policy, o usuário recebe `AccessDenied`.

### O fluxo completo passo a passo

```
1. "joao" quer fazer deploy em produção

2. Joao chama:
   aws sts assume-role \
     --role-arn "arn:aws:iam::123456789012:role/role-deploy-prod" \
     --role-session-name "deploy-joao-20260312"

3. STS verifica:
   a. A Trust Policy da role permite joao como Principal?
   b. Joao tem permissão para sts:AssumeRole no ARN da role?
   c. (se configurado) Joao passou o MFA correto?
   d. (se configurado) O ExternalID confere?

4. Tudo ok → STS gera e retorna:
   {
     "Credentials": {
       "AccessKeyId":     "ASIA...",
       "SecretAccessKey": "wJalr...",
       "SessionToken":    "FwoGZX...",
       "Expiration":      "2026-03-12T20:00:00Z"
     },
     "AssumedRoleUser": {
       "AssumedRoleId":  "AROA...:deploy-joao-20260312",
       "Arn": "arn:aws:sts::123456789012:assumed-role/role-deploy-prod/deploy-joao-20260312"
     }
   }

5. Joao usa as três credenciais retornadas
   (AccessKeyId + SecretAccessKey + SessionToken)
   para fazer chamadas como se fosse a role

6. As credenciais expiram no horário indicado
   Joao volta a ser apenas ele mesmo
```

### Rastreabilidade no CloudTrail

Toda ação feita sob a role assumida aparece no CloudTrail com a identidade completa:

```
arn:aws:sts::123456789012:assumed-role/role-deploy-prod/deploy-joao-20260312
                                       ─────────────────  ───────────────────
                                       nome da role       nome da sessão (você define)
```

Você sempre sabe **quem** assumiu **qual role** e **quando**.

### Via CLI no dia a dia

```bash
# ~/.aws/config
[profile joao]
aws_access_key_id     = AKIA...
aws_secret_access_key = ...

[profile deploy-prod]
role_arn       = arn:aws:iam::123456789012:role/role-deploy-prod
source_profile = joao
```

```bash
# O CLI assume a role automaticamente
aws s3 ls --profile deploy-prod
```

### Cross-account AssumeRole

Um dos padrões mais poderosos — identidade de uma conta acessa recursos de outra:

```
Conta DEV (123456789012)           Conta PROD (987654321098)
────────────────────               ────────────────────────────
Role "role-pipeline"               Role "role-deploy-prod"
  └── permissão:                     └── Trust Policy:
      sts:AssumeRole                     Principal:
      na role da Conta PROD               AWS: 123456789012:role/role-pipeline
```

O pipeline na conta DEV assume a role na conta PROD para fazer deploy — sem credenciais fixas na conta PROD, sem usuários criados lá.

### AssumeRole com MFA obrigatório

```json
{
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::123456789012:user/joao"
  },
  "Action": "sts:AssumeRole",
  "Condition": {
    "Bool": {
      "aws:MultiFactorAuthPresent": "true"
    }
  }
}
```

```bash
aws sts assume-role \
  --role-arn "arn:aws:iam::123456789012:role/role-deploy-prod" \
  --role-session-name "sessao-joao" \
  --serial-number "arn:aws:iam::123456789012:mfa/joao" \
  --token-code "123456"
```

---

## 12. Instance Profile

O Instance Profile é o **mecanismo exclusivo da EC2** para associar uma IAM Role a uma instância.

### Por que a EC2 não usa a role diretamente

Serviços gerenciados como Lambda, ECS ou Glue são criados e gerenciados pela própria AWS — ela mesma injeta as credenciais. A EC2 é uma VM que você controla e que pode existir antes de qualquer role ser associada. O Instance Profile é a camada que resolve esse problema.

### O que o Instance Profile realmente é

Um objeto IAM com seu próprio ARN que **referencia uma role**:

```json
{
  "InstanceProfileName": "meu-perfil-ec2",
  "InstanceProfileId":   "AIPA...",
  "Arn":                 "arn:aws:iam::123456789012:instance-profile/meu-perfil",
  "Roles": [
    {
      "RoleName": "minha-role-ec2",
      "Arn":      "arn:aws:iam::123456789012:role/minha-role-ec2"
    }
  ]
}
```

**Regras importantes:**
- Um Instance Profile contém **exatamente uma role**
- Múltiplas EC2s podem usar o **mesmo Instance Profile**
- A EC2 aponta para o Instance Profile — o Instance Profile não conhece as EC2s

### O fluxo completo de credenciais

```
Tempo 1 — Criação da infraestrutura (Terraform/Console):
  ├── Cria a IAM Role com Trust Policy para ec2.amazonaws.com
  ├── Anexa Permission Policies na role
  ├── Cria o Instance Profile referenciando a role
  └── Lança a EC2 com o Instance Profile associado

Tempo 2 — EC2 em execução, processo precisa de credenciais:
  │
  ├── 1. SDK/CLI dentro da EC2 chama o endpoint de metadados:
  │      GET http://169.254.169.254/latest/meta-data/iam/security-credentials/
  │      → retorna: "minha-role-ec2"
  │
  ├── 2. SDK chama:
  │      GET http://169.254.169.254/latest/meta-data/iam/security-credentials/minha-role-ec2
  │      → AWS (via STS) gera credenciais temporárias neste momento
  │      → retorna: { AccessKeyId, SecretAccessKey, Token, Expiration }
  │
  ├── 3. SDK usa as credenciais para chamar S3, SSM, etc.
  │
  └── 4. ~5 minutos antes de expirar, SDK renova automaticamente
         repetindo os passos 1 e 2
```

> `169.254.169.254` é um endereço **link-local** — acessível APENAS de dentro da instância, nunca externamente. É o canal que a AWS usa para entregar credenciais temporárias sem precisar armazenar nada em disco ou variável de ambiente.

### Em Terraform

```hcl
# Trust Policy
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# A Role
resource "aws_iam_role" "instance_role" {
  name               = "minha-role-ec2"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

# Permission Policy anexada
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance Profile — wrapper obrigatório para EC2
resource "aws_iam_instance_profile" "perfil" {
  name = "meu-perfil-ec2"
  role = aws_iam_role.instance_role.name
}

# EC2 usando o Instance Profile
resource "aws_instance" "servidor" {
  ami                  = "ami-..."
  instance_type        = "t3.micro"
  iam_instance_profile = aws_iam_instance_profile.perfil.name
}
```

---

## 13. ExternalID

### O problema que ele resolve: Confused Deputy

Imagine o seguinte cenário:

```
Você contrata uma empresa de monitoramento "MonitorCorp"
Você cria uma role na sua conta e diz:
  "MonitorCorp pode assumir esta role para monitorar minha conta"

Trust Policy da sua role:
{
  "Principal": { "AWS": "arn:aws:iam::CONTA_MONITORCORP:root" },
  "Action": "sts:AssumeRole"
}
```

O problema: **qualquer cliente da MonitorCorp** poderia, acidentalmente ou maliciosamente, dizer ao sistema deles: *"use minha role de acesso para acessar a conta do outro cliente"*.

O sistema da MonitorCorp não sabe que está sendo enganado — ele é o **confused deputy** (deputado confuso). Ele tem poder (pode assumir roles), mas não sabe distinguir para qual conta deveria estar agindo.

### Como o ExternalID resolve

Você gera um valor secreto (o ExternalID) que **só você e a MonitorCorp conhecem**. A Trust Policy exige que esse valor seja apresentado ao assumir a role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::CONTA_MONITORCORP:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "xK9mP2qR7nL4vW8j"
        }
      }
    }
  ]
}
```

A MonitorCorp agora precisa passar o ExternalID ao chamar AssumeRole:

```bash
aws sts assume-role \
  --role-arn "arn:aws:iam::SUA_CONTA:role/role-monitorcorp" \
  --role-session-name "monitorcorp-sessao" \
  --external-id "xK9mP2qR7nL4vW8j"
```

Se outro cliente da MonitorCorp tentar usar o ARN da sua role, o AssumeRole falha — porque eles não têm o seu ExternalID.

### Quando usar ExternalID

| Cenário | Usar ExternalID? |
|---|---|
| Serviço AWS assumindo sua role (EC2, Lambda) | Não — a AWS gerencia internamente |
| Usuário IAM da sua conta assumindo role | Não — você controla os dois lados |
| Terceiro (SaaS, parceiro) assumindo role na sua conta | **Sim — sempre** |
| Cross-account interno (suas próprias contas) | Opcional, mas recomendado |

### Boas práticas para ExternalID

- Gere um valor **único por cliente** — nunca reutilize o mesmo ExternalID para diferentes clientes
- Use um UUID ou valor aleatório longo — não use algo previsível como o nome da empresa
- Trate como um segredo — não exponha em logs ou código
- O ExternalID não precisa ser criptografado — ele é validado pela AWS no momento do AssumeRole

---

## 14. Como a AWS valida permissões

Quando qualquer requisição chega na AWS, ela passa por uma cadeia de validação com ordem definida.

### Fase 1 — Autenticação

```
Quem está fazendo essa requisição?

├── Credencial válida?          → se não: InvalidClientTokenId
├── Credencial expirou?         → se sim: ExpiredToken
└── Credencial pertence a
    uma identidade ativa?       → se não: InvalidClientTokenId
```

### Fase 2 — Avaliação de Autorização

Após autenticado, a AWS avalia as policies nesta ordem exata:

```
REQUISIÇÃO AUTENTICADA
        │
        ▼
┌─────────────────────────────────────────────┐
│ 1. Existe Deny explícito em algum SCP?      │──► SIM → NEGA (imediato, sem exceção)
└─────────────────────────────────────────────┘
        │ NÃO
        ▼
┌─────────────────────────────────────────────┐
│ 2. Existe Allow em algum SCP?               │──► NÃO → NEGA
└─────────────────────────────────────────────┘
        │ SIM
        ▼
┌─────────────────────────────────────────────┐
│ 3. Existe Deny em Resource-based Policy?    │──► SIM → NEGA
└─────────────────────────────────────────────┘
        │ NÃO
        ▼
┌─────────────────────────────────────────────┐
│ 4. Existe Allow em Resource-based Policy?   │
│    (E é same-account?)                      │──► SIM → PERMITE ✓
└─────────────────────────────────────────────┘
        │ NÃO
        ▼
┌─────────────────────────────────────────────┐
│ 5. Ação está dentro do Permission Boundary? │──► NÃO → NEGA
└─────────────────────────────────────────────┘
        │ SIM (ou boundary não configurado)
        ▼
┌─────────────────────────────────────────────┐
│ 6. Existe Deny em Identity-based Policy?    │──► SIM → NEGA
└─────────────────────────────────────────────┘
        │ NÃO
        ▼
┌─────────────────────────────────────────────┐
│ 7. Existe Allow em Identity-based Policy?   │──► SIM → PERMITE ✓
└─────────────────────────────────────────────┘
        │ NÃO
        ▼
      NEGA (Deny implícito — padrão)
```

### Regras de ouro

```
Deny explícito  →  SEMPRE vence, em qualquer nível
Allow explícito →  só vale se nenhum Deny existir
Ausência de Allow → NEGA (tudo é negado por padrão)
```

### Caso especial: Cross-account

No acesso cross-account, **tanto a Identity Policy da conta de origem quanto a Resource Policy da conta destino precisam ter Allow**:

```
Conta A: role com Allow para s3:GetObject no bucket da Conta B   ✓
Conta B: bucket policy com Allow para a role da Conta A           ✓
                                              └── as duas são necessárias
```

Se só uma existir, a AWS nega.

### O que é SCP (Service Control Policy)

SCP opera no nível da **AWS Organizations** — é o único mecanismo que pode negar ações mesmo para o root da conta.

```
Organization Root
    └── OU: producao
        ├── Conta: prod-app     ← SCP aplicado aqui
        └── Conta: prod-db      ← SCP aplicado aqui
    └── OU: desenvolvimento
        └── Conta: dev-app      ← SCP diferente aqui
```

Exemplo de SCP que bloqueia regiões e protege auditoria:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BloqueiaRegioes",
      "Effect": "Deny",
      "Action": "*",
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestedRegion": ["us-east-1", "sa-east-1"]
        }
      }
    },
    {
      "Sid": "BloqueiaDesativarCloudTrail",
      "Effect": "Deny",
      "Action": [
        "cloudtrail:DeleteTrail",
        "cloudtrail:StopLogging",
        "cloudtrail:UpdateTrail"
      ],
      "Resource": "*"
    }
  ]
}
```

> SCP com `Allow` **não concede permissão** — apenas define o teto máximo permitido. SCP com `Deny` nega absolutamente, sem exceção, para qualquer identidade incluindo o root da conta.

### O que é Permission Boundary

Um **teto de permissões** para uma identidade específica. Define o máximo que ela pode ter, independente do que as outras policies permitam.

```
Permissão efetiva = (O que a Identity Policy PERMITE)
                    ∩
                    (O que o Boundary PERMITE)
```

Exemplo:

```
Permission Boundary permite: s3:*, dynamodb:*
Identity Policy permite:     s3:*, ec2:*, iam:*

Resultado efetivo:
  s3:*       → PERMITIDO  (está em ambos)
  dynamodb:* → NEGADO     (Identity não tem, Boundary teria)
  ec2:*      → NEGADO     (Identity tem, Boundary não tem)
  iam:*      → NEGADO     (Identity tem, Boundary não tem)
```

---

## Visão geral — tudo junto

```
┌─────────────────────────────────────────────────────┐
│                    AWS IAM                          │
│                                                     │
│  IDENTIDADES           POLICIES                     │
│  ──────────            ────────                     │
│  Usuário ──────────► Identity-based                 │
│    │                  (Managed ou Inline)            │
│    └── em                                           │
│  Grupo  ──────────► Identity-based                  │
│                       (Managed ou Inline)            │
│                                                     │
│  Role ────────────► Trust Policy (quem assume)      │
│    │   └──────────► Permission Policy (o que faz)   │
│    │                  (Managed ou Inline)            │
│    │                                                 │
│    └── via                                          │
│  Instance Profile  (só para EC2)                    │
│                                                     │
│  Recurso ─────────► Resource-based Policy           │
│  (S3, SQS...)         (quem acessa)                 │
│                                                     │
│  VALIDAÇÃO (em ordem):                              │
│  SCP → Resource Policy → Boundary → Identity Policy │
└─────────────────────────────────────────────────────┘
```

### Linha do tempo de criação em Terraform

```
1. Criar Trust Policy (data source — só gera o JSON)
2. Criar a Role (usando a Trust Policy)
3. Criar a Permission Policy (Customer Managed ou usar AWS Managed)
4. Anexar a Permission Policy na Role
5. [Se EC2] Criar o Instance Profile referenciando a Role
6. [Se EC2] Associar o Instance Profile à instância
   [Se Lambda] Referenciar a Role diretamente na função
   [Se outro serviço] Referenciar o ARN da Role no recurso
```

> Nenhuma credencial existe até que a identidade seja utilizada — o STS gera credenciais temporárias **sob demanda**, no momento da chamada.
