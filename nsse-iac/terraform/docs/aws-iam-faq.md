# AWS IAM — FAQ: Principais Dúvidas e Confusões

> Perguntas reais de engenheiros sobre IAM — respondidas com profundidade.

---

## Sumário

**Roles e Identidades**
1. [Role e Instance Profile são a mesma coisa?](#1-role-e-instance-profile-são-a-mesma-coisa)
2. [Por que a EC2 precisa de Instance Profile se já existe a Role?](#2-por-que-a-ec2-precisa-de-instance-profile-se-já-existe-a-role)
3. [Usuário, Grupo e Role — qual a diferença real?](#3-usuário-grupo-e-role--qual-a-diferença-real)
4. [Uma Role pode assumir outra Role?](#4-uma-role-pode-assumir-outra-role)

**Trust Policy e Permissões**
5. [Qual a diferença entre Trust Policy e Permission Policy?](#5-qual-a-diferença-entre-trust-policy-e-permission-policy)
6. [Se eu estou na Trust Policy já não tenho acesso?](#6-se-eu-estou-na-trust-policy-já-não-tenho-acesso)
7. [Por que um Deny sempre vence um Allow?](#7-por-que-um-deny-sempre-vence-um-allow)
8. [Resource Policy vs Identity Policy — quando usar cada uma?](#8-resource-policy-vs-identity-policy--quando-usar-cada-uma)
9. [Cross-account precisa de permissão nos dois lados?](#9-cross-account-precisa-de-permissão-nos-dois-lados)

**Credenciais e STS**
10. [O que é o SessionToken e por que ele existe junto com AccessKey e SecretKey?](#10-o-que-é-o-sessiontoken-e-por-que-ele-existe-junto-com-accesskey-e-secretkey)
11. [O que acontece quando as credenciais temporárias expiram?](#11-o-que-acontece-quando-as-credenciais-temporárias-expiram)
12. [Posso ter múltiplas roles associadas a uma EC2?](#12-posso-ter-múltiplas-roles-associadas-a-uma-ec2)

**Erros comuns**
13. [Por que minha Lambda recebe AccessDenied mesmo com a policy correta?](#13-por-que-minha-lambda-recebe-accessdenied-mesmo-com-a-policy-correta)
14. [Coloquei Allow em tudo (Action: *) e ainda recebo AccessDenied — por quê?](#14-coloquei-allow-em-tudo-action--e-ainda-recebo-accessdenied--por-quê)
15. [Qual a diferença entre arn:aws:iam::123:root e um usuário específico como Principal?](#15-qual-a-diferença-entre-arnawsiam123root-e-um-usuário-específico-como-principal)

**Conceitos avançados**
16. [Permission Boundary bloqueia até o administrador?](#16-permission-boundary-bloqueia-até-o-administrador)
17. [Qual a diferença entre SCP e Permission Policy?](#17-qual-a-diferença-entre-scp-e-permission-policy)
18. [Inline Policy vs Managed Policy — qual usar?](#18-inline-policy-vs-managed-policy--qual-usar)
19. [O que é o endpoint 169.254.169.254 e por que ele é seguro?](#19-o-que-é-o-endpoint-169254169254-e-por-que-ele-é-seguro)
20. [Como o IAM sabe que sou eu fazendo a requisição?](#20-como-o-iam-sabe-que-sou-eu-fazendo-a-requisição)

---

## Roles e Identidades

### 1. Role e Instance Profile são a mesma coisa?

**Não. São dois objetos distintos no IAM.**

A confusão é comum porque no Terraform você cria os dois e eles parecem redundantes.

| | Role | Instance Profile |
|---|---|---|
| O que é | Identidade com permissões | Wrapper que conecta a role à EC2 |
| Tem ARN próprio | Sim | Sim |
| Tem Trust Policy | Sim | Não |
| Tem permissões | Sim | Não — só referencia a role |
| Usado por quem | Qualquer serviço AWS | Exclusivo da EC2 |

```
Instance Profile  →  aponta para a Role
Role              →  tem as permissões de verdade
```

O Instance Profile existe por uma limitação histórica e arquitetural da EC2: ela é uma VM que precisa de um mecanismo especial para receber credenciais em tempo de execução via hipervisor. Outros serviços como Lambda e ECS referenciam a role diretamente, sem precisar desse intermediário.

---

### 2. Por que a EC2 precisa de Instance Profile se já existe a Role?

Porque a EC2 é um **recurso de infraestrutura** gerenciado por você, não pela AWS.

Serviços como Lambda, ECS e Glue são criados e destruídos pela própria AWS — ela injeta as credenciais diretamente no processo de execução. A EC2 é uma VM que pode existir por meses, ser parada, reiniciada, ter a role trocada enquanto está rodando. O Instance Profile é o mecanismo que permite essa associação dinâmica.

Por baixo dos panos:
```
1. Você cria uma EC2 com um Instance Profile
2. O hipervisor (AWS Nitro) registra: "esta VM tem esta role"
3. O endpoint 169.254.169.254 é servido pelo hipervisor
4. Quando qualquer processo na VM chama esse endpoint,
   o hipervisor intercepta, chama o STS e devolve as credenciais
5. A VM nunca armazena credenciais em disco
```

---

### 3. Usuário, Grupo e Role — qual a diferença real?

A confusão principal é tratar Role como se fosse um "usuário mais poderoso". Não é.

| | Usuário | Grupo | Role |
|---|---|---|---|
| Representa | Pessoa ou sistema fixo | Coleção de usuários | Identidade temporária |
| Tem credenciais | Sim — fixas | Não tem | Sim — temporárias (STS) |
| Pode fazer login | Sim | Não | Não diretamente |
| Pode ser Principal | Sim | **Não** | Sim |
| Expira | Nunca | N/A | Sim (15min a 12h) |
| Usado por serviços AWS | Não recomendado | Não | Sim — padrão |

O Grupo é frequentemente mal entendido: **você não age como um grupo**. Ele é apenas um atalho administrativo — em vez de anexar 10 policies em 50 usuários individualmente, você cria um grupo, anexa as policies no grupo, e adiciona os usuários.

---

### 4. Uma Role pode assumir outra Role?

**Sim.** Isso se chama **role chaining** e é um padrão válido.

```
Role A assume Role B → Role B assume Role C
```

**Porém existem restrições importantes:**

- O tempo máximo de sessão em role chaining é **1 hora**, independente do que foi configurado na role
- Sem chaining, o tempo máximo pode ser até 12 horas
- Cada AssumeRole na cadeia gera um novo token com prazo reduzido
- Toda a cadeia fica registrada no CloudTrail

**Caso de uso real:**
```
Pipeline CI/CD (Role A)
  └── assume Role de deploy na conta STAGING (Role B)
        └── assume Role de acesso ao RDS para migração (Role C)
```

Para funcionar, cada role na cadeia precisa ter na sua Trust Policy a role anterior como Principal.

---

## Trust Policy e Permissões

### 5. Qual a diferença entre Trust Policy e Permission Policy?

É a confusão mais comum de quem está aprendendo IAM.

```
Trust Policy      →  "QUEM pode se tornar esta role?"
Permission Policy →  "O QUE esta role pode fazer?"
```

Pense assim: a Trust Policy é a **porta de entrada** da role. A Permission Policy é o **que você pode fazer depois de entrar**.

```json
// Trust Policy — controla quem pode assumir
{
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"      ← ação SEMPRE é sts:AssumeRole
  }]
}

// Permission Policy — controla o que pode fazer
{
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject"],     ← ação é o que você quer fazer
    "Resource": "arn:aws:s3:::meu-bucket/*"
  }]
}
```

Uma sem a outra não funciona:
- Role com Trust Policy mas sem Permission Policy → pode ser assumida, mas não faz nada
- Role com Permission Policy mas sem Trust Policy → impossível — toda role exige Trust Policy

---

### 6. Se eu estou na Trust Policy já não tenho acesso?

**Não. Estar na Trust Policy só autoriza ASSUMIR a role — não dá as permissões dela.**

São duas verificações independentes:

```
Verificação 1 (Trust Policy):
  "Você está autorizado a assumir esta role?"
  → Se não: AccessDenied no sts:AssumeRole

Verificação 2 (Permission Policy):
  "Você tem permissão para fazer esta ação?"
  → Se não: AccessDenied na ação (s3:GetObject, etc.)
```

Além disso, para um usuário IAM assumir uma role, **duas coisas precisam ser verdade simultaneamente**:

1. O usuário está listado como Principal na Trust Policy da role
2. O usuário tem uma Permission Policy que permite `sts:AssumeRole` no ARN da role

Se só uma das duas existir, o AssumeRole falha.

---

### 7. Por que um Deny sempre vence um Allow?

Por design de segurança — o modelo de **fail-closed** (falha fechada).

```
Se Deny e Allow coexistem → NEGA

Exemplo:
  Policy A: Allow s3:DeleteObject em *
  Policy B: Deny  s3:DeleteObject em *
  Resultado: NEGA
```

Isso garante que um administrador pode adicionar um Deny explícito em qualquer nível (SCP, Boundary, Resource Policy) e ter **certeza absoluta** de que aquela ação será bloqueada, independente de quantos Allows existam em outros lugares.

O inverso seria perigoso: se Allow pudesse vencer Deny, um usuário mal-intencionado com acesso a criar policies poderia contornar qualquer bloqueio de segurança simplesmente adicionando um Allow.

**Hierarquia de avaliação (ordem importa):**
```
1. Deny em SCP          → nega tudo imediatamente
2. Allow em SCP         → sem Allow aqui, nega
3. Deny em Resource Policy → nega
4. Allow em Resource Policy → permite (same-account)
5. Permission Boundary  → se fora do boundary, nega
6. Deny em Identity Policy → nega
7. Allow em Identity Policy → permite
8. (nenhum Allow encontrado) → nega implicitamente
```

---

### 8. Resource Policy vs Identity Policy — quando usar cada uma?

A confusão é saber quando cada uma é suficiente e quando precisa das duas.

**Regra prática:**

```
Mesma conta, acesso simples:
  → Identity Policy na role/usuário é suficiente
  → Resource Policy é opcional (mas pode adicionar segurança extra)

Cross-account (conta A acessa recurso na conta B):
  → Precisa das DUAS obrigatoriamente
  → Identity Policy na conta A permitindo acessar o recurso
  → Resource Policy na conta B permitindo a identidade da conta A

Acesso público ou a serviços externos:
  → Resource Policy é necessária
  → Ex: CloudFront acessando S3, SNS publicando no SQS
```

**Por que cross-account precisa das duas?**

A AWS trata isso como duas "fronteiras" de segurança independentes. A conta B não confia automaticamente em nenhuma identidade de fora — mesmo que a conta A diga "minha role pode acessar". A conta B precisa explicitamente concordar via Resource Policy.

---

### 9. Cross-account precisa de permissão nos dois lados?

**Sim, sempre.** Esse é um dos erros mais comuns em cross-account.

```
Conta A (123456789012)              Conta B (987654321098)
──────────────────────              ─────────────────────────
Role "role-acesso"                  Bucket "bucket-prod"
  └── Identity Policy:                └── Bucket Policy:
      Allow s3:GetObject                  Allow Principal:
      no bucket da Conta B                  role-acesso da Conta A
      ↑ SEM ISSO → NEGA               ↑ SEM ISSO → NEGA
```

**Ambas precisam existir.** Se só a Identity Policy existir, a Conta B nega. Se só a Bucket Policy existir, a Conta A nega.

**Exceção:** Para recursos que **não suportam Resource Policy** (como DynamoDB, SQS em alguns casos), você precisa usar IAM Role cross-account com a Identity Policy configurando o acesso. Nesses casos, a Identity Policy sozinha é suficiente se o recurso não tiver Resource Policy.

---

## Credenciais e STS

### 10. O que é o SessionToken e por que ele existe junto com AccessKey e SecretKey?

Quando você usa credenciais **permanentes** (usuário IAM com Access Key), você tem apenas dois valores:
- `AccessKeyId`
- `SecretAccessKey`

Quando você usa credenciais **temporárias** (via AssumeRole ou Instance Profile), você recebe três:
- `AccessKeyId`
- `SecretAccessKey`
- `SessionToken`

**Por que o terceiro valor?**

O `SessionToken` é o mecanismo que permite à AWS saber que aquela credencial é temporária e verificar se ainda está válida. Ele contém (de forma criptografada) metadados como: quando foi gerado, quando expira, qual role foi assumida, quem assumiu.

```
Sem SessionToken → credencial permanente de usuário IAM
Com SessionToken → credencial temporária de role assumida
```

Quando você faz uma requisição com credencial temporária, a AWS valida o SessionToken para confirmar que ele não expirou e que corresponde ao AccessKeyId apresentado. Se você tentar usar as credenciais sem o SessionToken, ou com um SessionToken incorreto, a requisição falha.

**Na prática:** O SDK da AWS gerencia isso automaticamente. Você raramente manipula o SessionToken diretamente — mas se estiver configurando credenciais manualmente em variáveis de ambiente ou arquivos, precisa incluir os três valores:

```bash
export AWS_ACCESS_KEY_ID="ASIA..."
export AWS_SECRET_ACCESS_KEY="wJalr..."
export AWS_SESSION_TOKEN="FwoGZX..."   # obrigatório para credenciais temporárias
```

---

### 11. O que acontece quando as credenciais temporárias expiram?

**Depende de onde as credenciais estão sendo usadas.**

**Dentro de uma EC2 (via Instance Profile):**
O SDK renova automaticamente antes de expirar. O processo não percebe — o SDK faz uma nova chamada ao endpoint de metadados `169.254.169.254` transparentemente.

**Em uma Lambda:**
A Lambda tem um tempo de execução máximo de 15 minutos. A AWS injeta novas credenciais no ambiente a cada invocação. Se uma execução longa precisar renovar, o SDK também faz isso automaticamente.

**Em um processo local (CLI/SDK na sua máquina):**
Se você fez `aws sts assume-role` manualmente e as credenciais expiraram, a próxima chamada retornará `ExpiredTokenException`. Você precisará fazer um novo `assume-role`.

**Em qualquer caso, quando expiram e não foram renovadas:**
```
Chamada à API → AWS valida o SessionToken → Token expirado
→ Retorna: ExpiredTokenException
→ HTTP 400: "The security token included in the request is expired"
```

O processo ou sistema precisa lidar com esse erro e renovar as credenciais.

---

### 12. Posso ter múltiplas roles associadas a uma EC2?

**Não diretamente.** Um Instance Profile contém exatamente **uma role**, e uma EC2 tem exatamente **um Instance Profile**.

```
EC2  →  1 Instance Profile  →  1 Role
```

**Mas existe uma solução:** a role associada à EC2 pode ter permissão para fazer `sts:AssumeRole` em outras roles. O processo dentro da EC2 pode então assumir roles adicionais conforme necessário:

```
EC2 com Role A
  └── Role A tem permissão para assumir Role B e Role C

Processo na EC2:
  ├── Usa credenciais da Role A para operações gerais
  ├── Faz AssumeRole para Role B quando precisa de permissões específicas
  └── Faz AssumeRole para Role C para acessar recursos de outra conta
```

---

## Erros comuns

### 13. Por que minha Lambda recebe AccessDenied mesmo com a policy correta?

São as causas mais frequentes, em ordem de probabilidade:

**1. A policy está na role errada**
```bash
# Verifique qual role a Lambda está usando
aws lambda get-function-configuration --function-name minha-lambda \
  | jq .Role

# Verifique as policies dessa role
aws iam list-attached-role-policies --role-name nome-da-role
```

**2. O recurso está em outra conta e falta a Resource Policy**
Se o S3, SQS ou outro recurso está em outra conta, só a Identity Policy na role da Lambda não é suficiente. A conta do recurso precisa ter uma Resource Policy permitindo a role.

**3. O ARN do recurso na policy está errado**
```json
// Errado — falta a região ou o account ID
"Resource": "arn:aws:dynamodb:::table/minha-tabela"

// Correto
"Resource": "arn:aws:dynamodb:us-east-1:123456789012:table/minha-tabela"
```

**4. A ação está errada**
S3 tem duas camadas de permissão que confundem bastante:
```json
// Para listar objetos: precisa de ListBucket no bucket (sem /* no final)
{ "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::meu-bucket" }

// Para ler/escrever objetos: precisa da ação nos objetos (com /*)
{ "Action": "s3:GetObject", "Resource": "arn:aws:s3:::meu-bucket/*" }
```

**5. Existe um Deny explícito em alguma policy**
Um Deny em qualquer nível (SCP, Boundary, outra policy) anula todos os Allows. Use o IAM Policy Simulator para identificar:
```
Console AWS → IAM → Policy Simulator
```

**6. A policy foi criada mas ainda não propagou**
IAM é eventually consistent em raras situações. Aguarde alguns segundos e tente novamente.

---

### 14. Coloquei Allow em tudo (Action: *) e ainda recebo AccessDenied — por quê?

Isso acontece porque a avaliação de permissões tem múltiplas camadas e um Allow em Identity Policy não é suficiente se houver bloqueio em outra camada.

**Causas possíveis em ordem:**

```
1. SCP bloqueando na Organization
   → Verifique SCPs aplicados à conta em AWS Organizations

2. Resource Policy com Deny explícito
   → Ex: Bucket Policy com Deny para seu IP ou sua role

3. Permission Boundary limitando o escopo
   → Se a role/usuário tem um Boundary, o Allow precisa estar
     dentro do escopo do Boundary também

4. VPC Endpoint Policy bloqueando
   → Se o acesso é via VPC Endpoint, a endpoint policy pode
     estar restringindo as ações

5. Recurso em outra conta sem Resource Policy
   → Action: * na sua Identity Policy não basta para cross-account
```

**Ferramenta para diagnosticar:**
```
Console → IAM → Policy Simulator → simule a ação específica
```
O simulador mostra exatamente qual policy ou regra está causando o bloqueio.

---

### 15. Qual a diferença entre `arn:aws:iam::123:root` e um usuário específico como Principal?

É uma diferença **enorme** que causa muito problema quando mal entendida.

```json
// Permite QUALQUER identidade da conta 123 assumir
"Principal": { "AWS": "arn:aws:iam::123456789012:root" }

// Permite APENAS o usuário "joao" assumir
"Principal": { "AWS": "arn:aws:iam::123456789012:user/joao" }
```

O sufixo `:root` **não significa o usuário root da conta**. Significa **a conta inteira** — qualquer usuário, role ou serviço dessa conta que tenha permissão de `sts:AssumeRole` na sua Identity Policy poderá assumir.

**Quando usar cada um:**

| Principal | Quando usar |
|---|---|
| `arn:aws:iam::123:root` | Cross-account onde qualquer identidade da conta pode assumir (com controle via Identity Policy na conta de origem) |
| ARN de role específica | Quando quer restringir a uma identidade exata |
| ARN de usuário específico | Quando quer restringir a um usuário exato (evite — prefira roles) |

**Armadilha comum:** Colocar `:root` achando que só o usuário root pode assumir, quando na verdade está permitindo toda a conta.

---

## Conceitos avançados

### 16. Permission Boundary bloqueia até o administrador?

**Sim — dentro do escopo onde foi aplicado.**

O Permission Boundary é um teto de permissões aplicado a uma identidade específica. Se uma role tem um Boundary que não inclui `iam:*`, ela não pode fazer nada no IAM — mesmo que você anexe `AdministratorAccess` nela.

```
Role com AdministratorAccess (Allow *)
  + Permission Boundary (Allow apenas s3:* e dynamodb:*)
  = Permissão efetiva: apenas s3:* e dynamodb:*

Mesmo sendo "admin" pela policy, o Boundary limita.
```

**Mas o Boundary não afeta:**
- O usuário root da conta
- Identidades que não têm Boundary configurado
- SCPs (que operam em uma camada acima)

**Caso de uso real — delegação segura:**
Você quer que um desenvolvedor crie roles para suas Lambdas, mas sem que ele possa criar uma role mais poderosa do que ele mesmo. Você dá a ele permissão de `iam:CreateRole`, mas com a condição de que o Boundary obrigatório seja anexado:

```json
{
  "Effect": "Allow",
  "Action": "iam:CreateRole",
  "Resource": "*",
  "Condition": {
    "StringEquals": {
      "iam:PermissionsBoundary": "arn:aws:iam::123:policy/dev-boundary"
    }
  }
}
```

Sem essa condição, o dev poderia criar uma role com `AdministratorAccess` e usá-la para escalar privilégios.

---

### 17. Qual a diferença entre SCP e Permission Policy?

São camadas completamente diferentes que operam em escopos distintos.

| | SCP | Permission Policy |
|---|---|---|
| Onde vive | AWS Organizations | IAM (role/usuário) |
| Escopo | Conta inteira ou OU | Identidade específica |
| Pode conceder permissão | **Não** — só define o teto | Sim |
| Afeta o root da conta | Sim | Não |
| Quem configura | Conta master da Org | Admin da conta |

**SCP não concede permissões — só restringe.**

Por isso toda conta nova na Organization recebe automaticamente a policy `FullAWSAccess` (Allow em tudo). Sem ela, nada funcionaria — o SCP por si só não dá nenhuma permissão.

```
SCP com Allow s3:*
  → NÃO significa que todos podem usar S3
  → Significa que o S3 está "desbloqueado" para ser usado
  → Ainda precisa de Identity Policy permitindo s3:* na identidade

SCP com Deny cloudtrail:*
  → Bloqueia CloudTrail para TODA a conta
  → Ninguém na conta consegue desativar o CloudTrail
  → Nem o root, nem o admin, ninguém
```

---

### 18. Inline Policy vs Managed Policy — qual usar?

**Na grande maioria dos casos: Customer Managed Policy.**

| Situação | Recomendação |
|---|---|
| Permissão usada por múltiplos recursos | Customer Managed — muda em 1 lugar, reflete em todos |
| Permissão muito específica de 1 role | Inline — fica junto, some com a role |
| Precisa auditar e versionar | Customer Managed — tem ARN, aparece no console |
| Quer garantir que some com a identidade | Inline |
| Ambiente IaC (Terraform) | Customer Managed — mais fácil de gerenciar |

**O maior problema da Inline Policy em produção:**

Se você tem 30 Lambdas com Inline Policies e precisa adicionar uma permissão nova em todas, você precisa editar 30 recursos. Com Customer Managed Policy, você edita 1 policy e todas as 30 herdam automaticamente.

**Quando Inline faz sentido:**
- A permissão é absolutamente única para aquela identidade
- Você quer garantir que não será acidentalmente reutilizada
- O ciclo de vida da permissão é idêntico ao da identidade

---

### 19. O que é o endpoint 169.254.169.254 e por que ele é seguro?

É o **Instance Metadata Service (IMDS)** — um endpoint especial disponível apenas dentro de instâncias EC2 (e alguns outros serviços de computação AWS).

**Por que é seguro:**

`169.254.x.x` é um bloco de endereços **link-local** (RFC 3927) — por definição, não é roteável. Um pacote destinado a esse IP nunca sai da interface de rede local. Na AWS, esse endereço é interceptado pelo **hipervisor Nitro** antes de chegar à rede física.

```
Processo dentro da VM
  └── chama GET 169.254.169.254
          │
          └── [interceptado pelo Nitro antes de sair da VM]
                  │
                  └── Nitro sabe qual role a VM tem
                          │
                          └── Nitro chama STS internamente
                                  │
                                  └── STS retorna credenciais
                                          │
                                          └── Nitro responde à VM
```

Nenhum processo externo pode fazer esse curl — o endereço simplesmente não existe fora da VM.

**IMDSv2 — a versão mais segura (recomendada):**

A versão 1 do IMDS era vulnerável a ataques SSRF (Server-Side Request Forgery): se uma aplicação dentro da EC2 tivesse uma vulnerabilidade que permitia fazer requisições HTTP arbitrárias, um atacante poderia roubar as credenciais fazendo `curl http://169.254.169.254/...`.

A versão 2 (IMDSv2) resolve isso exigindo um token de sessão obtido via requisição PUT antes de qualquer GET:

```bash
# IMDSv1 (vulnerável a SSRF)
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/

# IMDSv2 (requer token de sessão primeiro)
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

Em Terraform, force o IMDSv2:
```hcl
resource "aws_instance" "servidor" {
  metadata_options {
    http_tokens = "required"   # força IMDSv2
  }
}
```

---

### 20. Como o IAM sabe que sou eu fazendo a requisição?

Toda requisição à API da AWS é **assinada criptograficamente** usando o algoritmo **AWS Signature Version 4 (SigV4)**.

**O processo:**

```
1. Você tem: AccessKeyId + SecretAccessKey (+ SessionToken se temporário)

2. Ao fazer uma requisição, o SDK:
   a. Monta o payload da requisição
   b. Cria um hash SHA-256 do payload
   c. Cria uma string canônica com: método HTTP + URI + headers + hash do payload
   d. Assina essa string usando o SecretAccessKey com HMAC-SHA256
   e. Inclui a assinatura no header Authorization da requisição

3. A AWS recebe a requisição:
   a. Identifica o AccessKeyId no header
   b. Busca o SecretAccessKey correspondente internamente
   c. Refaz o mesmo processo de assinatura
   d. Compara a assinatura recebida com a calculada
   e. Se conferirem → autenticado ✓
   f. Se não conferirem → InvalidSignatureException ✗

4. Após autenticado, verifica o SessionToken (se existir)
   e em seguida avalia as policies (autorização)
```

**Por que isso é seguro:**
- O `SecretAccessKey` nunca é enviado na requisição — apenas a assinatura derivada dele
- A assinatura inclui timestamp — replay attacks expiram em 15 minutos
- Qualquer alteração no payload invalida a assinatura
- Sem o SecretAccessKey, é computacionalmente impossível forjar uma assinatura válida

---

## Referência rápida de diagnóstico

### Checklist para AccessDenied

```
□ A identidade correta está sendo usada?
  → aws sts get-caller-identity

□ A policy está na role/usuário correto?
  → aws iam list-attached-role-policies --role-name NOME

□ O ARN do recurso na policy está correto?
  → Verifique região, account ID e nome do recurso

□ A ação na policy está correta?
  → Consulte a documentação do serviço para o nome exato da ação

□ É cross-account? Existe Resource Policy na conta destino?
  → Ambos os lados precisam ter Allow

□ Existe algum Deny explícito em alguma policy?
  → Use o IAM Policy Simulator no console

□ Existe SCP bloqueando na Organization?
  → Console → Organizations → Policies

□ Existe Permission Boundary limitando?
  → aws iam get-role --role-name NOME | jq .Role.PermissionsBoundary
```

### Comandos CLI úteis para diagnóstico

```bash
# Quem sou eu agora?
aws sts get-caller-identity

# Quais policies estão na role?
aws iam list-attached-role-policies --role-name NOME-DA-ROLE

# Ver o documento de uma policy
aws iam get-policy-version \
  --policy-arn ARN-DA-POLICY \
  --version-id v1

# Ver a Trust Policy de uma role
aws iam get-role --role-name NOME-DA-ROLE \
  | jq '.Role.AssumeRolePolicyDocument'

# Simular uma ação (verifica se seria permitida)
aws iam simulate-principal-policy \
  --policy-source-arn ARN-DA-ROLE \
  --action-names s3:GetObject \
  --resource-arns arn:aws:s3:::meu-bucket/arquivo.txt
```
