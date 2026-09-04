# Guia Completo de Terraform

> Estruturas, Remote Backend, State Locking e boas práticas — com exemplos reais do projeto.

---

## Sumário

**Fundamentos**
1. [O que é o State File](#1-o-que-é-o-state-file)
2. [Backend Local vs Remote](#2-backend-local-vs-remote)
3. [Remote Backend com S3](#3-remote-backend-com-s3)
4. [State Locking com DynamoDB](#4-state-locking-com-dynamodb)
5. [Como o projeto está estruturado](#5-como-o-projeto-está-estruturado)

**Estruturas do Terraform**
6. [terraform {}](#6-terraform--configuração-global)
7. [provider {}](#7-provider--configuração-do-provider)
8. [variable {}](#8-variable--entradas-do-módulo)
9. [locals {}](#9-locals--valores-internos-calculados)
10. [output {}](#10-output--valores-exportados)
11. [resource {}](#11-resource--cria-infraestrutura)
12. [data {}](#12-data--lê-infraestrutura-existente)
13. [module {}](#13-module--reutilização-de-código)
14. [dynamic {}](#14-dynamic--blocos-dinâmicos)
15. [count](#15-count--múltiplos-recursos-por-índice)
16. [for_each](#16-for_each--múltiplos-recursos-por-chave)
17. [depends_on](#17-depends_on--dependência-explícita)
18. [lifecycle {}](#18-lifecycle--controle-do-ciclo-de-vida)
19. [moved {}](#19-moved--refatoração-segura)
20. [for expressions](#20-for-expressions--transformação-de-dados)
21. [templatefile()](#21-templatefile--templates-de-arquivos)

**Referência**
22. [Mapa mental de todas as estruturas](#22-mapa-mental-de-todas-as-estruturas)
23. [Operadores de versão](#23-operadores-de-versão)
24. [Comandos essenciais](#24-comandos-essenciais)

---

## 1. O que é o State File

O Terraform precisa de um mecanismo para saber o que ele já criou na infraestrutura real. Esse mecanismo é o **state file** — um arquivo JSON (`terraform.tfstate`) que representa o estado atual de todos os recursos gerenciados.

```
Código HCL  ──► terraform plan ──► compara com state ──► calcula diff
                                                              │
                                                    o que criar, alterar
                                                    ou destruir na AWS
```

### Estrutura interna do state file

```json
{
  "version": 4,
  "terraform_version": "1.7.0",
  "serial": 42,
  "lineage": "abc-123-def-456",
  "outputs": {
    "key_pair_private_key": { "value": "...", "sensitive": true }
  },
  "resources": [
    {
      "mode": "managed",
      "type": "aws_s3_bucket",
      "name": "this",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        {
          "schema_version": 0,
          "attributes": {
            "id":     "nsse-terraform-state-files-2026",
            "bucket": "nsse-terraform-state-files-2026",
            "arn":    "arn:aws:s3:::nsse-terraform-state-files-2026",
            "region": "us-east-1"
          }
        }
      ]
    }
  ]
}
```

Campos importantes:

- `serial` → incrementa a cada mudança. O Terraform usa isso para detectar conflitos
- `lineage` → ID único do state. Dois states com lineages diferentes não são compatíveis
- `resources` → lista completa de todos os recursos e seus atributos atuais

### O que acontece sem o state file

Se você perder o state, o Terraform não sabe mais o que criou. Na próxima execução ele tentará criar tudo novamente — gerando erros de recurso duplicado ou, pior, destruindo recursos existentes sem saber.

Por isso o state file é tratado como **dado crítico de infraestrutura** — tão importante quanto os próprios recursos.

---

## 2. Backend Local vs Remote

### Backend Local (padrão)

Sem configuração explícita, o Terraform salva o state na sua máquina:

```
projeto/
  ├── main.tf
  ├── variables.tf
  └── terraform.tfstate   ← state local, gerado automaticamente
```

**Problemas do backend local:**

```
Colaboração impossível:
  Dev A tem o state na máquina dele
  Dev B tem o state na máquina dele
  → States divergem → infraestrutura inconsistente

Sem locking:
  Dev A e Dev B rodam apply ao mesmo tempo
  → Ambos leram o mesmo state antigo
  → Ambos calcularam diffs baseados no estado antigo
  → Dev A grava novo state
  → Dev B sobrescreve o state do Dev A
  → State corrompido, recursos duplicados ou deletados

Sem histórico:
  Deletou o arquivo → perdeu todo o histórico
  Apply corrompeu o state → sem como voltar atrás

Pipelines CI/CD impossíveis:
  O runner não tem acesso ao state local da sua máquina
```

### Backend Remote

O state fica em um serviço centralizado, acessível por todos:

```
Qualquer dev ou pipeline  ──► Remote Backend (S3)
                                    │
                                    ├── state versionado
                                    ├── acessível de qualquer lugar
                                    └── protegido por locking (DynamoDB)
```

---

## 3. Remote Backend com S3

### Por que S3

- **Durabilidade**: 99.999999999% (11 noves) — praticamente impossível perder dados
- **Versionamento**: cada mudança no state gera uma nova versão automaticamente
- **Criptografia**: suporte nativo a SSE (Server-Side Encryption)
- **Custo**: praticamente zero para arquivos de state (poucos KB)
- **Integração nativa**: o provider AWS do Terraform tem suporte oficial

### Criando o bucket de backend

Este é exatamente o padrão do seu projeto (`backend/s3.bucket.tf`):

```hcl
resource "aws_s3_bucket" "this" {
  bucket        = var.remote_backend.bucket
  force_destroy = true  # CUIDADO: deleta todos os objetos ao destruir o bucket
                        # útil em desenvolvimento, perigoso em produção
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"  # guarda histórico de cada versão do state
  }
}
```

O versionamento é essencial — se um `terraform apply` corrompeu o state, você restaura a versão anterior diretamente pelo console S3 ou CLI:

```bash
# Listar versões do state
aws s3api list-object-versions \
  --bucket nsse-terraform-state-files-2026 \
  --prefix server/terraform.tfstate

# Restaurar versão anterior
aws s3api copy-object \
  --bucket nsse-terraform-state-files-2026 \
  --copy-source nsse-terraform-state-files-2026/server/terraform.tfstate?versionId=VERSION_ID \
  --key server/terraform.tfstate
```

### Configurando o backend S3 no módulo

Do seu projeto (`server/main.tf`):

```hcl
terraform {
  backend "s3" {
    bucket         = "nsse-terraform-state-files-2026"  # bucket criado pelo módulo backend/
    key            = "server/terraform.tfstate"          # caminho dentro do bucket
    region         = "us-east-1"
    dynamodb_table = "nsse-terraform-state-locking"     # tabela de locking
  }
}
```

O campo `key` é o caminho do arquivo dentro do bucket. Como você tem múltiplos módulos, cada um tem um `key` diferente — os states são completamente isolados:

```
nsse-terraform-state-files-2026/
  ├── backend/terraform.tfstate     ← state do módulo backend (se migrado)
  ├── networking/terraform.tfstate  ← state do módulo networking
  └── server/terraform.tfstate      ← state do módulo server
```

### Boas práticas adicionais para o bucket

```hcl
# Bloquear acesso público — state file pode conter senhas e chaves
resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Criptografia em repouso
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
```

---

## 4. State Locking com DynamoDB

### O problema que o locking resolve

```
Sem locking — dois applies simultâneos:

  Dev A:  lê state (serial=10) → calcula diff → aplica → grava state (serial=11)
  Dev B:  lê state (serial=10) → calcula diff → aplica → grava state (serial=11)
                                  (leu antes do Dev A gravar)

  Resultado:
  → Dev B sobrescreveu o state do Dev A
  → Mudanças do Dev A desapareceram do state
  → Infraestrutura real diverge do state
  → State corrompido
```

### Como o DynamoDB funciona como mutex

O DynamoDB garante **atomicidade** nas operações — só um processo consegue criar o mesmo item ao mesmo tempo. O Terraform usa isso como um lock distribuído:

```
Dev A inicia terraform apply:
  1. Tenta inserir item: { LockID: "server/terraform.tfstate" }
  2. DynamoDB aceita (tabela vazia para essa chave)
  3. Lock adquirido ✓ → Dev A aplica as mudanças

Dev B inicia terraform apply ao mesmo tempo:
  1. Tenta inserir item: { LockID: "server/terraform.tfstate" }
  2. DynamoDB rejeita — item já existe (Dev A tem o lock)
  3. Terraform exibe:
     ┌─────────────────────────────────────────────────────┐
     │ Error: Error acquiring the state lock               │
     │                                                     │
     │ Lock Info:                                          │
     │   ID:        abc-123-def-456                        │
     │   Path:      server/terraform.tfstate               │
     │   Operation: OperationTypeApply                     │
     │   Who:       dev-a@maquina-a                        │
     │   Version:   1.7.0                                  │
     │   Created:   2026-03-12 10:00:00                    │
     └─────────────────────────────────────────────────────┘
  4. Dev B aguarda ou aborta

Dev A termina:
  1. Deleta o item do DynamoDB: { LockID: "server/terraform.tfstate" }
  2. Lock liberado → Dev B pode tentar novamente
```

### Criando a tabela DynamoDB

Do seu projeto (`backend/dynamodb.table.tf`):

```hcl
resource "aws_dynamodb_table" "this" {
  name         = var.remote_backend.state_locking.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"   # paga por operação, sem capacidade provisionada
  hash_key     = "LockID"            # OBRIGATÓRIO — nome exato que o Terraform espera

  attribute {
    name = "LockID"
    type = "S"   # String
  }
}
```

> O nome da hash key **precisa ser exatamente `LockID`**. Se usar outro nome, o locking silenciosamente não funciona.

### Force Unlock — quando o lock trava

Se um processo morreu no meio do `apply` (crash, timeout, CTRL+C) sem liberar o lock, ele fica preso indefinidamente. Para desbloquear:

```bash
# O ID do lock aparece na mensagem de erro
terraform force-unlock "abc-123-def-456"
```

> **Use com extrema cautela.** Só faça isso se tiver certeza absoluta de que nenhum outro processo está rodando. Liberar o lock enquanto outro `apply` está em execução coloca você de volta no cenário de state corrompido.

---

## 5. Como o projeto está estruturado

O projeto usa um padrão que resolve o problema de **bootstrapping** — você não pode usar um backend remoto que ainda não existe:

```
Execução 1:
  backend/   → roda com backend LOCAL
              → cria o bucket S3 e a tabela DynamoDB
              → state fica em backend/terraform.tfstate (local)

Execução 2:
  networking/ → usa o S3 + DynamoDB criados acima como backend remoto
  server/     → usa o S3 + DynamoDB criados acima como backend remoto
```

```
nsse-iac/
  ├── backend/            ← cria a infraestrutura do backend
  │     ├── main.tf       ← usa backend LOCAL (padrão)
  │     ├── s3.bucket.tf
  │     └── dynamodb.table.tf
  │
  ├── networking/         ← usa backend REMOTO (S3 + DynamoDB)
  │     └── main.tf       ← backend "s3" { key = "networking/..." }
  │
  └── server/             ← usa backend REMOTO (S3 + DynamoDB)
        └── main.tf       ← backend "s3" { key = "server/..." }
```

Cada módulo tem seu próprio state isolado. O módulo `server` não sabe nada sobre o state do `networking` — se precisar de dados entre módulos, usa `data "terraform_remote_state"` ou outputs compartilhados.

---

## 6. `terraform {}` — Configuração global

O bloco `terraform` configura o comportamento do próprio Terraform: versão mínima exigida, providers necessários e backend.

```hcl
terraform {
  # Versão mínima do Terraform CLI
  required_version = ">= 1.2"

  # Providers necessários
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.92"   # aceita 5.92.x, não aceita 6.x
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }

  # Backend remoto
  backend "s3" {
    bucket         = "nsse-terraform-state-files-2026"
    key            = "server/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "nsse-terraform-state-locking"
  }
}
```

> O bloco `backend` **não aceita variáveis ou referências** — todos os valores precisam ser literais. Isso é uma limitação intencional do Terraform para garantir que o backend possa ser inicializado antes de qualquer avaliação de variáveis.

---

## 7. `provider {}` — Configuração do provider

Configura como o Terraform se autentica e se comporta com um serviço específico. Do seu projeto:

```hcl
provider "aws" {
  region = var.region

  # Tags aplicadas automaticamente em TODOS os recursos criados
  default_tags {
    tags = var.tags
  }

  # Terraform assume esta role antes de criar qualquer recurso
  # Padrão de segurança: Terraform não usa credenciais de admin diretamente
  assume_role {
    role_arn     = var.assume_role.role_arn
    session_name = var.assume_role.session_name
    external_id  = var.assume_role.external_id
  }
}
```

O bloco `assume_role` no provider é o padrão mais seguro para pipelines CI/CD:

```
Pipeline CI/CD tem credenciais com permissão MÍNIMA:
  └── sts:AssumeRole na role "terraform-role"

"terraform-role" tem as permissões para criar a infraestrutura:
  └── ec2:*, iam:*, s3:*, etc.

Resultado:
  → Credenciais do pipeline nunca têm poder direto
  → Todo acesso é auditável via CloudTrail com o session_name
  → ExternalID previne Confused Deputy
```

**Múltiplos providers** — para multi-region ou multi-account:

```hcl
provider "aws" {
  region = "us-east-1"
  alias  = "us_east"
}

provider "aws" {
  region = "sa-east-1"
  alias  = "sa_east"
}

resource "aws_s3_bucket" "us" {
  provider = aws.us_east
  bucket   = "meu-bucket-us"
}

resource "aws_s3_bucket" "br" {
  provider = aws.sa_east
  bucket   = "meu-bucket-br"
}
```

---

## 8. `variable {}` — Entradas do módulo

Define **parâmetros de entrada** do módulo — valores que vêm de fora, tornando o código configurável e reutilizável.

### Tipos disponíveis

```hcl
# Primitivos
variable "nome"     { type = string }
variable "quantidade" { type = number }
variable "ativo"    { type = bool }

# Coleções
variable "lista"    { type = list(string) }
variable "mapa"     { type = map(string) }
variable "conjunto" { type = set(string) }

# Estruturado
variable "objeto"   { type = object({ nome = string, porta = number }) }

# Qualquer tipo (sem validação)
variable "qualquer" { type = any }
```

### Exemplos do projeto

```hcl
# Objeto simples
variable "ec2_resources" {
  type = object({
    key_pair_name    = string
    instance_role    = string
    instance_profile = string
  })
  default = {
    key_pair_name    = "nsse-production-key-pair"
    instance_role    = "nsse-production-instance-role"
    instance_profile = "nsse-production-instance-profile"
  }
}

# Objeto aninhado com lista de objetos
variable "debian_patch_baseline" {
  type = object({
    name             = string
    operating_system = string
    approval_rule = list(object({
      approve_after_days = number
      compliance_level   = string
      patch_filter = object({
        product  = list(string)
        priority = list(string)
      })
    }))
  })
}
```

### Validação de variáveis

```hcl
variable "environment" {
  type = string

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment deve ser dev, staging ou production."
  }
}

variable "instance_type" {
  type = string

  validation {
    condition     = startswith(var.instance_type, "t3.")
    error_message = "Apenas instâncias t3 são permitidas neste módulo."
  }
}
```

### Como passar valores (ordem de precedência — maior para menor)

```
1. -var="region=sa-east-1"              CLI direto
2. -var-file="prod.tfvars"              arquivo explícito via CLI
3. *.auto.tfvars                        arquivo automático na pasta
4. terraform.tfvars                     arquivo automático padrão
5. TF_VAR_region="sa-east-1"           variável de ambiente
6. default no código                    valor padrão
```

### Sensitive — oculta valores nos logs

```hcl
variable "db_password" {
  type      = string
  sensitive = true   # nunca aparece em plan/apply output nem em logs
}
```

---

## 9. `locals {}` — Valores internos calculados

Define **valores computados dentro do módulo** — não são entradas nem saídas. Evitam repetição e centralizam lógica complexa.

### Uso básico

```hcl
locals {
  # Composição de strings
  prefix = "${var.tags.Project}-${var.tags.Environment}"

  # Condicional
  instance_type = var.tags.Environment == "production" ? "t3.medium" : "t3.micro"

  # Merge de maps — padrão muito usado para tags
  common_tags = merge(var.tags, {
    ManagedBy = "Terraform"
    Region    = data.aws_region.current.name
  })
}
```

### Exemplo real do projeto

Do módulo `ec2` (`server/modules/ec2/ec2.auto-scaling-group.tf`):

```hcl
locals {
  # Transforma map de tags em lista de objetos
  # O ASG da AWS espera tags no formato [{key, value}], não map
  asg_tags_dictionary = [for key, value in var.auto_scaling_group.instance_tags : {
    key   = key
    value = value
  }]
}
```

Sem o `locals`, essa transformação precisaria ser repetida em cada lugar onde as tags do ASG são usadas.

### Quando usar `locals` vs `variable`

```
variable  → valor vem de FORA   → quem chama o módulo define
locals    → valor calculado DENTRO → lógica interna, sem exposição externa

Bom candidato para locals:
  → Expressão usada mais de uma vez
  → Transformação de tipo (list → map, map → list)
  → Lógica condicional complexa
  → Composição de strings longas
```

---

## 10. `output {}` — Valores exportados

Exporta valores do módulo para exibição no terminal ou consumo por outros módulos.

### Exemplos do projeto

```hcl
# server/outputs.tf
output "key_pair_private_key" {
  value     = tls_private_key.this.private_key_pem
  sensitive = true   # não aparece no terminal, mas pode ser usado por outros módulos
}

# server/modules/ec2/outputs.tf
output "launch_template_name" {
  value = aws_launch_template.this.name
}

output "auto_scaling_group_name" {
  value = aws_autoscaling_group.this.name
}
```

### Outputs estruturados

```hcl
output "ec2_info" {
  description = "Informações das instâncias criadas"
  value = {
    launch_template_name = aws_launch_template.this.name
    asg_name             = aws_autoscaling_group.this.name
    asg_arn              = aws_autoscaling_group.this.arn
  }
}

output "subnet_ids" {
  value = data.aws_subnets.private_subnets.ids   # lista de IDs
}
```

### Consumindo outputs entre módulos

```hcl
# Módulo networking exporta subnet_ids
# Módulo server consome:

module "networking" {
  source = "../networking"
}

module "ec2_control_plane" {
  source = "./modules/ec2"
  auto_scaling_group = {
    vpc_zone_identifier = module.networking.subnet_ids  # usando output do outro módulo
  }
}
```

### Exibindo outputs após apply

```bash
terraform output                          # todos os outputs
terraform output key_pair_private_key     # output específico
terraform output -json                    # em formato JSON
terraform output -raw key_pair_private_key # valor puro (sem aspas)
```

---

## 11. `resource {}` — Cria infraestrutura

O bloco central do Terraform — declara um recurso real que será criado, atualizado ou destruído na AWS.

```hcl
resource "TIPO_DO_RECURSO" "NOME_LOCAL" {
  # atributos do recurso
}
```

- `TIPO_DO_RECURSO` → definido pelo provider (ex: `aws_s3_bucket`, `aws_iam_role`)
- `NOME_LOCAL` → identificador dentro do Terraform (não é o nome na AWS)
- Referência: `aws_s3_bucket.this.id`, `aws_iam_role.instance_role.arn`

```hcl
# Exemplo do projeto
resource "aws_iam_role" "instance_role" {
  name               = var.ec2_resources.instance_role
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_instance_profile" "instance_profile" {
  name = var.ec2_resources.instance_profile
  role = aws_iam_role.instance_role.name  # referência ao recurso acima
}
```

A referência `aws_iam_role.instance_role.name` cria uma **dependência implícita** — o Terraform garante que a role existe antes de criar o instance profile.

---

## 12. `data {}` — Lê infraestrutura existente

Busca informações de recursos que já existem na AWS **sem criar, alterar ou destruir** nada. É somente leitura.

### Exemplos do projeto

```hcl
# Busca VPC por ID e tag (server/data.vpc.tf)
data "aws_vpc" "this" {
  id = var.vpc_resources.vpc

  filter {
    name   = "tag:Name"
    values = [var.vpc_resources.vpc]
  }
}

# Busca AMI mais recente do Debian (server/data.ec2.ami.tf)
data "aws_ami" "this" {
  most_recent = true
  owners      = ["136693071363"]   # conta oficial Debian

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "name"
    values = ["debian-12*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Busca subnets privadas da VPC (server/data.vpc.private-subnets.tf)
data "aws_subnets" "private_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]   # usa o resultado do data acima
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = [false]   # false = subnets privadas
  }
}
```

### Outros data sources úteis

```hcl
# Gera documento JSON de policy IAM
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

# Identidade atual (quem está rodando o Terraform)
data "aws_caller_identity" "current" {}

# Região atual
data "aws_region" "current" {}

# Zonas de disponibilidade
data "aws_availability_zones" "available" {
  state = "available"
}

# Uso
locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  azs        = data.aws_availability_zones.available.names
}
```

### `resource` vs `data`

```
resource "aws_s3_bucket" "this" { ... }
  → CRIA um bucket na AWS
  → Terraform gerencia o ciclo de vida (cria, atualiza, deleta)
  → Aparece no state

data "aws_s3_bucket" "existente" { bucket = "bucket-que-ja-existe" }
  → LEIA informações de um bucket que já existe
  → Terraform não cria nem modifica nada
  → Não aparece como recurso gerenciado no state
```

---

## 13. `module {}` — Reutilização de código

Encapsula um conjunto de recursos em uma unidade reutilizável. É o principal mecanismo de organização e reuso no Terraform.

### Exemplo real do projeto

O projeto usa um módulo `ec2` que é chamado duas vezes — uma para control-plane, outra para worker:

```hcl
# server/ec2.instances.control-plane.tf
module "ec2_instances_control_plane" {
  source                = "./modules/ec2"
  tags                  = var.tags
  instance_profile_name = aws_iam_instance_profile.instance_profile.name

  launch_template = {
    name          = var.control_plane_launch_template.name
    instance_type = var.control_plane_launch_template.instance_type
    image_id      = data.aws_ami.this.image_id
    key_pair_name = aws_key_pair.this.key_name
    vpc_security_group_ids = [aws_security_group.control_plane.id]
    user_data     = filebase64(var.control_plane_launch_template.user_data)
    ebs = {
      size                  = var.control_plane_launch_template.ebs.size
      delete_on_termination = var.control_plane_launch_template.ebs.delete_on_termination
    }
    # ...
  }

  auto_scaling_group = {
    name                = var.control_plane_auto_scaling_group.name
    vpc_zone_identifier = data.aws_subnets.private_subnets.ids
    instance_tags = merge(
      var.tags,
      var.control_plane_auto_scaling_group.instance_tags,
      { PatchGroup = var.patch_group }
    )
    # ...
  }
}

# server/ec2.instances.worker.tf
module "ec2_instances_worker" {
  source = "./modules/ec2"   # mesmo módulo, configuração diferente
  # ...
}
```

O módulo `ec2` (`server/modules/ec2/`) contém:
- `ec2.launch-template.tf` → `aws_launch_template`
- `ec2.auto-scaling-group.tf` → `aws_autoscaling_group`
- `variables.tf` → interface do módulo
- `outputs.tf` → o que ele expõe para fora

### Fontes de módulos

```hcl
source = "./modules/ec2"                              # local (mais comum em monorepos)
source = "../shared-modules/networking"               # local relativo
source = "git::https://github.com/org/repo.git//ec2" # git
source = "git::https://github.com/org/repo.git//ec2?ref=v1.2.0" # git com tag
source = "hashicorp/consul/aws"                       # Terraform Registry
source = "hashicorp/consul/aws" + version = "0.1.0"  # Registry com versão
```

### Acessando outputs do módulo

```hcl
output "asg_name" {
  value = module.ec2_instances_control_plane.auto_scaling_group_name
  #                                          └── output definido em modules/ec2/outputs.tf
}
```

---

## 14. `dynamic {}` — Blocos dinâmicos

Gera blocos de configuração repetidos ou condicionais a partir de uma lista ou map. Resolve o problema de blocos que variam em quantidade.

### O problema que resolve

```hcl
# Sem dynamic — repetição manual, não escalável
resource "aws_security_group" "this" {
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # e mais 10 regras...
}
```

### Com dynamic

```hcl
variable "ingress_rules" {
  default = [
    { port = 80,   cidr = "0.0.0.0/0"   },
    { port = 443,  cidr = "0.0.0.0/0"   },
    { port = 8080, cidr = "10.0.0.0/8"  }
  ]
}

resource "aws_security_group" "this" {
  name   = "meu-sg"
  vpc_id = data.aws_vpc.this.id

  dynamic "ingress" {
    for_each = var.ingress_rules  # itera sobre cada regra
    content {
      from_port   = ingress.value.port  # "ingress" é o nome do bloco
      to_port     = ingress.value.port
      protocol    = "tcp"
      cidr_blocks = [ingress.value.cidr]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

O iterador assume o nome do bloco (`ingress`). Você pode renomear:
```hcl
dynamic "ingress" {
  for_each = var.ingress_rules
  iterator = regra            # renomeia o iterador
  content {
    from_port = regra.value.port
  }
}
```

### Bloco condicional com dynamic

O padrão `[1] : []` cria o bloco uma vez ou não cria:

```hcl
variable "enable_detailed_monitoring" {
  type    = bool
  default = false
}

resource "aws_launch_template" "this" {
  name          = "meu-lt"
  instance_type = "t3.micro"

  dynamic "monitoring" {
    for_each = var.enable_detailed_monitoring ? [1] : []
    content {
      enabled = true
    }
  }
}
```

### Exemplo real do projeto

Do módulo `ec2` (`server/modules/ec2/ec2.auto-scaling-group.tf`):

```hcl
locals {
  # Transforma o map de tags em lista de objetos {key, value}
  # porque o bloco "tag" do ASG espera esse formato
  asg_tags_dictionary = [for key, value in var.auto_scaling_group.instance_tags : {
    key   = key
    value = value
  }]
}

resource "aws_autoscaling_group" "this" {
  # ...

  dynamic "tag" {
    for_each = local.asg_tags_dictionary
    content {
      key                 = tag.value.key
      value               = tag.value.value
      propagate_at_launch = true   # propaga a tag para as instâncias criadas pelo ASG
    }
  }
}
```

Sem o `dynamic`, você precisaria de um bloco `tag` separado para cada tag — o que tornaria o código rígido e não reutilizável.

---

## 15. `count` — Múltiplos recursos por índice

Cria N cópias de um recurso. Cada cópia é acessada pelo índice numérico (0, 1, 2...).

```hcl
# Cria 3 instâncias
resource "aws_instance" "workers" {
  count         = 3
  ami           = data.aws_ami.this.image_id
  instance_type = "t3.micro"

  tags = {
    Name = "worker-${count.index}"   # worker-0, worker-1, worker-2
  }
}

# Condicional — cria ou não cria
resource "aws_eip" "nat" {
  count = var.tags.Environment == "production" ? 1 : 0
}

# Referências
resource "aws_route53_record" "workers" {
  count  = 3
  name   = "worker-${count.index}.exemplo.com"
  records = [aws_instance.workers[count.index].private_ip]
}

output "worker_ips" {
  value = aws_instance.workers[*].private_ip   # splat expression → lista de todos os IPs
}
```

### O problema do count com listas

```hcl
variable "nomes" {
  default = ["alpha", "beta", "gamma"]
}

resource "aws_iam_user" "this" {
  count = length(var.nomes)
  name  = var.nomes[count.index]
}

# State atual:
# aws_iam_user.this[0] → alpha
# aws_iam_user.this[1] → beta
# aws_iam_user.this[2] → gamma

# Se você REMOVER "beta" da lista:
# aws_iam_user.this[0] → alpha (ok)
# aws_iam_user.this[1] → gamma (era beta, agora é gamma → DESTROI beta, CRIA gamma)
# aws_iam_user.this[2] → DESTROI gamma

# Resultado: Terraform destroi e recria recursos desnecessariamente
# Use for_each para evitar isso
```

---

## 16. `for_each` — Múltiplos recursos por chave

Mais robusto que `count` — cada recurso tem uma **chave única** que não muda quando outros são adicionados ou removidos.

### Com map

```hcl
variable "buckets" {
  default = {
    logs    = "nsse-production-logs"
    backups = "nsse-production-backups"
    assets  = "nsse-production-assets"
  }
}

resource "aws_s3_bucket" "this" {
  for_each = var.buckets

  bucket = each.value   # each.key = "logs", each.value = "nsse-production-logs"

  tags = {
    Name    = each.key
    Purpose = each.key
  }
}

# Referência
output "bucket_arns" {
  value = { for k, v in aws_s3_bucket.this : k => v.arn }
  # → { logs = "arn:...:logs", backups = "arn:...:backups", ... }
}
```

### Com set de strings

```hcl
# Anexando múltiplas policies a uma role
resource "aws_iam_role_policy_attachment" "this" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  ])

  role       = aws_iam_role.instance_role.name
  policy_arn = each.value
}
```

### `count` vs `for_each`

```
count   → recursos verdadeiramente idênticos, identificados por índice
          ex: "quero 3 instâncias idênticas"
          problema: reindexação ao remover item do meio

for_each → recursos com identidade própria, identificados por chave
           ex: "quero um bucket para logs, um para backups"
           seguro: remover "logs" não afeta "backups" e "assets"

Regra geral: prefira for_each sempre que os recursos tiverem nomes
             ou configurações distintas.
```

---

## 17. `depends_on` — Dependência explícita

O Terraform detecta dependências automaticamente por referências (`aws_iam_role.this.name`). O `depends_on` é para casos onde a dependência é **implícita** — o Terraform não consegue ver pelo código.

```hcl
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_autoscaling_group" "this" {
  name = "meu-asg"
  # ...

  # O ASG não referencia a policy diretamente no código
  # mas as instâncias precisam que a policy exista antes de iniciar
  # o SSM Agent precisa das permissões para registrar a instância
  depends_on = [aws_iam_role_policy_attachment.ssm]
}
```

> **Use com moderação.** O `depends_on` força serialização e aumenta o tempo total do apply. Sempre prefira referências diretas — o Terraform constrói o grafo de dependências automaticamente a partir delas.

---

## 18. `lifecycle {}` — Controle do ciclo de vida

Controla como o Terraform cria, atualiza e destrói um recurso específico.

### `create_before_destroy`

Por padrão, o Terraform **destrói primeiro, depois cria**. Isso causa downtime em recursos que precisam existir continuamente.

```hcl
resource "aws_launch_template" "this" {
  name          = "meu-lt"
  instance_type = "t3.micro"

  lifecycle {
    create_before_destroy = true   # cria o novo, depois destrói o antigo
  }
}
```

### `prevent_destroy`

Protege recursos críticos contra exclusão acidental:

```hcl
resource "aws_dynamodb_table" "producao" {
  name = "tabela-critica"
  # ...

  lifecycle {
    prevent_destroy = true   # terraform destroy falha com erro explicativo
  }
}
```

```
╷
│ Error: Instance cannot be destroyed
│
│ Resource aws_dynamodb_table.producao has lifecycle.prevent_destroy
│ set, but the plan calls for this resource to be destroyed.
╵
```

### `ignore_changes`

Ignora mudanças em campos específicos — útil quando algo é modificado fora do Terraform:

```hcl
resource "aws_autoscaling_group" "this" {
  name         = "meu-asg"
  desired_capacity = 2
  # ...

  lifecycle {
    ignore_changes = [
      desired_capacity,   # o ASG pode escalar — Terraform não vai reverter
      launch_template,    # AMI pode ser atualizada pelo ASG automaticamente
    ]
  }
}
```

### `precondition` e `postcondition`

Validações antes e depois da aplicação:

```hcl
resource "aws_instance" "servidor" {
  ami           = data.aws_ami.this.image_id
  instance_type = var.instance_type

  lifecycle {
    precondition {
      condition     = !startswith(var.instance_type, "t2.")
      error_message = "Instâncias t2 não são permitidas. Use t3 ou superior."
    }

    postcondition {
      condition     = self.public_ip == ""
      error_message = "Instância recebeu IP público. Verifique a configuração da subnet."
    }
  }
}
```

---

## 19. `moved {}` — Refatoração segura

Informa ao Terraform que um recurso foi **renomeado ou movido para um módulo** sem destruir e recriar na infraestrutura real.

### O problema que resolve

```
Sem moved:
  Terraform vê: recurso "aws_launch_template.this" sumiu do código
  Terraform vê: novo recurso "module.ec2.aws_launch_template.this" apareceu
  Terraform decide: destroi o antigo, cria o novo
  Resultado: downtime desnecessário

Com moved:
  Terraform vê o bloco moved
  Terraform entende: é o mesmo recurso, só mudou de endereço no state
  Terraform apenas atualiza o state
  Resultado: zero impacto na infraestrutura real
```

### Exemplos do projeto

Do seu `server/moved.tf`:

```hcl
# Recursos foram movidos de nível root para dentro do módulo ec2
moved {
  from = aws_launch_template.this
  to   = module.ec2_instances_control_plane.aws_launch_template.this
}

moved {
  from = aws_autoscaling_group.this
  to   = module.ec2_instances_control_plane.aws_autoscaling_group.this
}
```

### Outros casos de uso

```hcl
# Renomear um recurso
moved {
  from = aws_s3_bucket.logs
  to   = aws_s3_bucket.application_logs
}

# Mover para módulo
moved {
  from = aws_iam_role.lambda_role
  to   = module.lambda.aws_iam_role.this
}

# Mover dentro de for_each
moved {
  from = aws_iam_user.this["admin"]
  to   = aws_iam_user.admins["admin"]
}
```

> Depois que todos os times aplicaram o `moved`, você pode remover o bloco do código. Ele só precisa existir durante a transição.

---

## 20. `for` expressions — Transformação de dados

Transforma listas e maps inline — equivalente ao `map()` e `filter()` de outras linguagens.

### Lista → lista

```hcl
locals {
  # Transformação simples
  upper_envs = [for e in ["dev", "staging", "prod"] : upper(e)]
  # → ["DEV", "STAGING", "PROD"]

  # Com filtro
  private_subnet_ids = [
    for subnet in data.aws_subnets.all.ids : subnet
    if !contains(subnet, "public")
  ]
}
```

### Lista → map

```hcl
locals {
  # Índice como chave
  subnet_map = {
    for idx, id in data.aws_subnets.private_subnets.ids :
    "subnet-${idx}" => id
  }
  # → { "subnet-0" = "subnet-abc123", "subnet-1" = "subnet-def456" }
}
```

### Map → map

```hcl
locals {
  # Filtrar somente recursos de produção
  prod_resources = {
    for k, v in var.resources : k => v
    if v.environment == "production"
  }

  # Transformar valores
  upper_tags = {
    for k, v in var.tags : k => upper(v)
  }
}
```

### Exemplo real do projeto

```hcl
# server/modules/ec2/ec2.auto-scaling-group.tf
locals {
  # Map de tags → lista de objetos {key, value}
  # Necessário porque o bloco "tag" do ASG espera lista, não map
  asg_tags_dictionary = [for key, value in var.auto_scaling_group.instance_tags : {
    key   = key
    value = value
  }]
}
```

---

## 21. `templatefile()` — Templates de arquivos

Renderiza um arquivo de template substituindo variáveis — muito usado para `user_data` de EC2 e scripts de inicialização.

### Arquivo de template

```bash
# scripts/user_data.sh.tpl
#!/bin/bash
set -euo pipefail

# Configurar hostname
hostnamectl set-hostname ${hostname}

# Configurar environment
echo "Environment: ${environment}" >> /etc/environment

# Instalar pacotes
%{ for pkg in packages ~}
apt-get install -y ${pkg}
%{ endfor ~}

# Configurar tags para SSM
echo "PatchGroup=${patch_group}" >> /etc/environment
```

### Uso no Terraform

```hcl
resource "aws_launch_template" "this" {
  name          = "meu-lt"
  instance_type = "t3.micro"

  user_data = base64encode(templatefile("${path.module}/scripts/user_data.sh.tpl", {
    hostname    = "meu-servidor-producao"
    environment = var.tags.Environment
    patch_group = var.patch_group
    packages    = ["nginx", "curl", "jq", "awscli"]
  }))
}
```

### `filebase64()` vs `templatefile()` + `base64encode()`

```hcl
# filebase64 — lê arquivo e converte para base64, SEM substituição de variáveis
user_data = filebase64("${path.module}/scripts/user_data.sh")

# templatefile + base64encode — substitui variáveis ANTES de converter
user_data = base64encode(templatefile("${path.module}/scripts/user_data.sh.tpl", {
  hostname = "meu-servidor"
}))
```

O seu projeto usa `filebase64` diretamente:
```hcl
user_data = filebase64(var.control_plane_launch_template.user_data)
```

Isso significa que o script de user_data não usa variáveis do Terraform — as configurações são feitas diretamente no script shell.

---

## 22. Mapa mental de todas as estruturas

```
CONFIGURAÇÃO
  terraform {}      → versão do Terraform, providers, backend
  provider {}       → autenticação e config do provider (region, assume_role)

DADOS
  variable {}       → ENTRADA    — vem de fora do módulo
  locals {}         → INTERNO    — calculado dentro do módulo
  output {}         → SAÍDA      — exportado para fora do módulo

INFRAESTRUTURA
  resource {}       → CRIA e GERENCIA recursos na AWS
  data {}           → LÊ recursos existentes (somente leitura)
  module {}         → ENCAPSULA e REUTILIZA conjuntos de recursos

META-ARGUMENTOS (dentro de resource ou module)
  count             → N cópias por índice numérico
  for_each          → N cópias por chave única (mais seguro)
  depends_on        → dependência explícita
  lifecycle {}      → comportamento de create/update/destroy

DENTRO DE RESOURCE
  dynamic {}        → gera blocos repetidos ou condicionais

EXPRESSÕES
  for []  {}        → transforma listas e maps
  templatefile()    → renderiza arquivos com variáveis

REFATORAÇÃO
  moved {}          → renomeia/move recursos sem destruir
```

---

## 23. Operadores de versão

```
= 1.2.0     → exatamente 1.2.0
!= 1.2.0    → qualquer versão exceto 1.2.0
> 1.2.0     → maior que 1.2.0
>= 1.2.0    → maior ou igual a 1.2.0
< 2.0.0     → menor que 2.0.0
~> 1.2.0    → >=1.2.0 e <1.3.0  (apenas patch releases)
~> 1.2      → >=1.2.0 e <2.0.0  (apenas minor releases)
~> 5.92     → >=5.92.0 e <6.0.0 ← padrão do seu projeto
```

O operador `~>` (pessimistic constraint) é o mais usado em produção — permite atualizações de patch/minor mas bloqueia major versions que podem ter breaking changes.

---

## 24. Comandos essenciais

```bash
# Inicialização — baixa providers, configura backend
terraform init

# Reinicializa migrando o backend (ex: local → S3)
terraform init -migrate-state

# Valida a sintaxe dos arquivos .tf
terraform validate

# Formata os arquivos .tf (padrão canônico)
terraform fmt
terraform fmt -recursive   # formata subdiretórios também

# Mostra o plano de execução sem aplicar
terraform plan
terraform plan -out=tfplan   # salva o plano para aplicar depois

# Aplica as mudanças
terraform apply
terraform apply tfplan        # aplica um plano salvo
terraform apply -auto-approve # sem confirmação interativa (CI/CD)

# Destroi todos os recursos
terraform destroy
terraform destroy -auto-approve

# Gerenciar state
terraform state list                          # lista todos os recursos no state
terraform state show aws_instance.servidor    # mostra detalhes de um recurso
terraform state mv aws_bucket.old aws_bucket.new  # renomeia no state (use moved {})
terraform state rm aws_instance.servidor      # remove do state (não destroi na AWS)

# Importar recurso existente para o state
terraform import aws_s3_bucket.this meu-bucket-existente

# Forçar unlock se tiver lock preso
terraform force-unlock LOCK_ID

# Ver outputs
terraform output
terraform output -json
terraform output -raw nome_do_output

# Ver versão dos providers instalados
terraform providers

# Baixar e atualizar módulos
terraform get
terraform get -update
```

### Fluxo de trabalho padrão

```
1. terraform init        → baixa providers e configura backend
2. terraform validate    → verifica sintaxe
3. terraform fmt         → formata o código
4. terraform plan        → revisa o que vai mudar
5. terraform apply       → aplica as mudanças
```

### Fluxo em CI/CD (pipeline)

```
1. terraform init -backend-config="..."   → configura backend com vars do CI
2. terraform validate
3. terraform plan -out=tfplan             → salva plano para auditoria
4. (aprovação manual se necessário)
5. terraform apply tfplan                 → aplica exatamente o plano aprovado
```
