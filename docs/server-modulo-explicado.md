# Módulo Server — Explicação Completa

> Análise detalhada de todos os recursos, suas relações e o design por trás das decisões.

---

## Sumário

1. [Visão geral da arquitetura](#1-visão-geral-da-arquitetura)
2. [Mapa de dependências](#2-mapa-de-dependências)
3. [Camada 1 — Data Sources (leitura da infraestrutura existente)](#3-camada-1--data-sources)
4. [Camada 2 — Identidade IAM (quem são as instâncias)](#4-camada-2--identidade-iam)
5. [Camada 3 — Key Pair (acesso SSH)](#5-camada-3--key-pair)
6. [Camada 4 — Security Groups (controle de rede)](#6-camada-4--security-groups)
7. [Camada 5 — Módulo EC2 (o blueprint das instâncias)](#7-camada-5--módulo-ec2)
8. [Camada 6 — SSM Patching (gestão de patches)](#8-camada-6--ssm-patching)
9. [Camada 7 — User Data (inicialização das instâncias)](#9-camada-7--user-data)
10. [Decisões de design e segurança](#10-decisões-de-design-e-segurança)
11. [Linha do tempo de criação](#11-linha-do-tempo-de-criação)
12. [Fluxo operacional completo](#12-fluxo-operacional-completo)

---

## 1. Visão geral da arquitetura

O módulo `server/` provisiona um cluster com dois tipos de instâncias EC2 gerenciadas por Auto Scaling Groups, sem acesso SSH direto, usando exclusivamente o AWS Systems Manager (SSM) para acesso remoto e gestão de patches.

```
┌─────────────────────────────────────────────────────────────────┐
│                        Módulo server/                           │
│                                                                 │
│  ┌──────────────────────────────┐                               │
│  │   VPC (existente)            │                               │
│  │   ┌────────────────────────┐ │                               │
│  │   │  Subnets Privadas      │ │                               │
│  │   │  ┌──────────────────┐  │ │                               │
│  │   │  │  ASG Control     │  │ │                               │
│  │   │  │  Plane (1 inst)  │──┼─┼──► SSM Agent ──► AWS SSM     │
│  │   │  └──────────────────┘  │ │         │                     │
│  │   │  ┌──────────────────┐  │ │         │                     │
│  │   │  │  ASG Worker      │  │ │         ▼                     │
│  │   │  │  (1 inst)        │──┼─┼──► Patch Baseline             │
│  │   │  └──────────────────┘  │ │         │                     │
│  │   └────────────────────────┘ │         ▼                     │
│  └──────────────────────────────┘   S3 Logs Bucket              │
│                                                                 │
│  IAM Role ──► Instance Profile ──► EC2 Instances               │
│  Security Groups ──► EC2 Instances                              │
│  Key Pair ──► EC2 Instances (SSH desabilitado no SG)            │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. Mapa de dependências

Este é o grafo real de dependências que o Terraform constrói internamente para determinar a ordem de criação:

```
data.aws_vpc.this
    └──► data.aws_subnets.private_subnets
    └──► aws_security_group.control_plane
    └──► aws_security_group.worker

data.aws_ami.this ──────────────────────────────────┐
                                                     │
tls_private_key.this                                 │
    └──► aws_key_pair.this ──────────────────────────┤
                                                     │
data.aws_iam_policy_document.assume_role             │
    └──► aws_iam_role.instance_role ─────────────────┤
             └──► aws_iam_role_policy_attachment      │
             └──► aws_iam_instance_profile ───────────┤
             └──► aws_s3_bucket_policy (ssm logs)     │
                                                     │
aws_security_group.control_plane ────────────────────┤
aws_security_group.worker ───────────────────────────┤
                                                     ▼
                                    module.ec2_instances_control_plane
                                      ├── aws_launch_template.this
                                      └── aws_autoscaling_group.this

aws_ssm_patch_baseline.this
    └──► aws_ssm_patch_group.this

aws_s3_bucket.ssm_logs
    └──► aws_s3_bucket_policy (via aws_iam_role.instance_role)
    └──► aws_ssm_association.debian_production
```

---

## 3. Camada 1 — Data Sources

Os data sources são o ponto de partida — eles lêem a infraestrutura que o módulo `networking/` já criou. O módulo `server/` não sabe como a VPC foi criada, só precisa que ela exista.

### `data.aws_vpc.this`

```hcl
# server/data.vpc.tf
data "aws_vpc" "this" {
  id = var.vpc_resources.vpc

  filter {
    name   = "tag:Name"
    values = [var.vpc_resources.vpc]
  }
}
```

**O que faz:** Busca a VPC pelo ID **e** confirma que ela tem a tag `Name` correspondente. A combinação de `id` + `filter` é uma validação extra — se a VPC existir mas a tag estiver errada, o data source falha antes de criar qualquer coisa.

**O que expõe:**
- `data.aws_vpc.this.id` → ID da VPC (usado pelos security groups e no data de subnets)
- `data.aws_vpc.this.cidr_block` → CIDR da VPC (disponível se precisar de regras de SG baseadas em CIDR)

---

### `data.aws_subnets.private_subnets`

```hcl
# server/data.vpc.private-subnets.tf
data "aws_subnets" "private_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]   # depende do data de VPC acima
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = [false]   # false = subnets privadas (não atribuem IP público)
  }
}
```

**O que faz:** Busca todas as subnets privadas da VPC. O filtro `map-public-ip-on-launch = false` é a forma programática de distinguir subnets privadas de públicas — subnets públicas têm esse atributo como `true` para atribuir IP público automaticamente.

**O que expõe:**
- `data.aws_subnets.private_subnets.ids` → lista de IDs de todas as subnets privadas, usada no `vpc_zone_identifier` do ASG para distribuir instâncias entre AZs

---

### `data.aws_ami.this`

```hcl
# server/data.ec2.ami.tf
data "aws_ami" "this" {
  most_recent = true
  owners      = ["136693071363"]   # Account ID oficial da Debian na AWS

  filter { name = "architecture",        values = ["x86_64"]  }
  filter { name = "name",                values = ["debian-12*"] }
  filter { name = "root-device-type",    values = ["ebs"] }
  filter { name = "virtualization-type", values = ["hvm"] }
}
```

**O que faz:** Busca a AMI Debian 12 mais recente publicada pela própria Debian. O `most_recent = true` garante que você sempre usa a versão mais atual disponível.

**Por que validar o `owner`:** Qualquer pessoa pode publicar uma AMI na AWS com o nome "debian-12". Fixar o `owners` no account ID oficial da Debian (`136693071363`) evita que você instale uma AMI falsa ou comprometida.

**Por que os múltiplos filtros:**
- `architecture = x86_64` → garante compatibilidade com tipos de instância t3
- `name = debian-12*` → filtra apenas Debian 12 (sem versões antigas)
- `root-device-type = ebs` → instâncias com EBS como root (padrão — mais flexível que instance-store)
- `virtualization-type = hvm` → Hardware Virtual Machine (padrão atual, melhor performance que paravirtual)

**O que expõe:**
- `data.aws_ami.this.image_id` → ID da AMI mais recente, passado para o launch template

---

## 4. Camada 2 — Identidade IAM

Esta camada responde: **"quem são as instâncias EC2 para a AWS?"**

### `ec2.instance-profile.tf` — os 4 recursos IAM

```hcl
# 1. Trust Policy — define que apenas EC2 pode assumir a role
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# 2. A Role em si
resource "aws_iam_role" "instance_role" {
  name               = var.ec2_resources.instance_role
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

# 3. Permissões — anexa a AWS Managed Policy do SSM
resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 4. Wrapper para EC2
resource "aws_iam_instance_profile" "instance_profile" {
  name = var.ec2_resources.instance_profile
  role = aws_iam_role.instance_role.name
}
```

**Relação entre os 4:**

```
Trust Policy (documento JSON)
    │
    └──► IAM Role "nsse-production-instance-role"
              │
              ├──► Policy Attachment (AmazonSSMManagedInstanceCore)
              │         └── permite SSM, EC2Messages, S3 para SSM
              │
              └──► Instance Profile "nsse-production-instance-profile"
                        └──► associado às instâncias EC2 no launch template
```

**O que a `AmazonSSMManagedInstanceCore` permite:**

Essa AWS Managed Policy inclui as permissões mínimas para o SSM Agent funcionar:

```json
{
  "Statement": [
    { "Action": ["ssm:DescribeAssociation", "ssm:GetDocument",
                 "ssm:UpdateInstanceInformation", "ssm:ListAssociations",
                 "ssm:GetDeployablePatchSnapshotForInstance",
                 "ssm:PutInventory", "ssm:PutComplianceItems"],
      "Resource": "*" },

    { "Action": ["ec2messages:AcknowledgeMessage", "ec2messages:DeleteMessage",
                 "ec2messages:FailMessage", "ec2messages:GetEndpoint",
                 "ec2messages:GetMessages", "ec2messages:SendReply"],
      "Resource": "*" },

    { "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::aws-ssm-*/*" }
  ]
}
```

Sem essa policy, o SSM Agent nas instâncias não consegue se comunicar com o serviço SSM — as instâncias ficariam invisíveis no console do SSM.

**Por que a role do instance_role também aparece no bucket policy de logs:**

```
aws_iam_role.instance_role.arn
    │
    ├──► Instance Profile ──► EC2 assume essa role via STS
    │
    └──► aws_s3_bucket_policy (ssm_logs)
              └── permite s3:PutObject para essa role
              └── instâncias escrevem logs de patch no S3
```

A mesma identidade (role) que dá poder ao SSM Agent também é usada como `Principal` na bucket policy dos logs — as instâncias precisam poder escrever os resultados dos patches nesse bucket.

---

## 5. Camada 3 — Key Pair

```hcl
# server/ec2.key-pair.tf

# Gera o par de chaves RSA 4096 bits DENTRO DO TERRAFORM (no state)
resource "tls_private_key" "this" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Envia a chave PÚBLICA para a AWS
resource "aws_key_pair" "this" {
  key_name   = var.ec2_resources.key_pair_name
  public_key = tls_private_key.this.public_key_openssh

  tags = merge(var.tags, {
    Name = var.ec2_resources.key_pair_name
  })
}
```

**O que acontece aqui:**

O provider `tls` (não é AWS) gera um par de chaves RSA localmente, em memória, no momento do `terraform apply`. A **chave privada** fica armazenada no state file. A **chave pública** é enviada para a AWS e associada ao nome `key_name`.

```
tls_private_key.this
    ├── private_key_pem  → fica no state file (sensitive)
    └── public_key_openssh → enviada para a AWS

aws_key_pair.this
    └── registra a chave pública na AWS com um nome
```

**O output sensível:**

```hcl
# server/outputs.tf
output "key_pair_private_key" {
  sensitive = true
  value     = tls_private_key.this.private_key_pem
}
```

Para recuperar a chave privada e conectar via SSH (se o SG permitir):
```bash
terraform output -raw key_pair_private_key > chave.pem
chmod 400 chave.pem
ssh -i chave.pem admin@<IP>
```

**Detalhe importante de segurança:** A chave privada **fica no state file**. Isso significa que qualquer pessoa com acesso ao bucket S3 de backend pode extrair a chave privada. Em produção, o ideal é controlar rigorosamente o acesso ao bucket de state (bucket policy + IAM + KMS encryption).

**Por que o SSH está comentado nos Security Groups:**

O par de chaves existe e está associado às instâncias, mas os Security Groups **não têm regra de ingress na porta 22**. Isso é intencional — o acesso é feito exclusivamente via SSM Session Manager, sem precisar abrir portas ou gerenciar chaves SSH.

---

## 6. Camada 4 — Security Groups

```hcl
# server/ec2.security-groups-control-plane.tf
resource "aws_security_group" "control_plane" {
  name        = var.ec2_resources.control_plane_security_group
  description = "Allow SSH inbound traffic"   # descrição desatualizada
  vpc_id      = data.aws_vpc.this.id

  # Sem ingress — nenhuma porta aberta de entrada

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"        # -1 = todos os protocolos
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge(var.tags, {
    Name = var.ec2_resources.control_plane_security_group
  })
}
```

O security group do worker é idêntico em estrutura — só difere no nome.

**O que cada regra significa:**

```
Ingress (entrada):
  NENHUMA REGRA → zero portas abertas para tráfego externo
  Ninguém pode iniciar uma conexão PARA as instâncias

Egress (saída):
  from_port = 0, to_port = 0, protocol = "-1"
  → qualquer porta, qualquer protocolo, qualquer destino
  → as instâncias podem iniciar conexões para qualquer lugar
```

**Por que egress liberado é necessário:**

As instâncias precisam de saída para:
- Comunicar com o endpoint SSM (`ssm.us-east-1.amazonaws.com`)
- Baixar pacotes via `apt-get` (Debian repositories)
- Baixar o SSM Agent no user data
- Escrever logs no S3

**O que está comentado e por quê:**

O código comentado mostra a configuração SSH que existia anteriormente:

```hcl
# ingress {
#   description = "SSH from VPC"
#   from_port   = 22
#   to_port     = 22
#   protocol    = "tcp"
#   cidr_blocks = [var.ec2_resources.ssh_source_ip]
# }
```

Isso foi removido em favor do SSM Session Manager — uma decisão de segurança que elimina a necessidade de gerenciar chaves SSH e abrir portas.

**Control Plane vs Worker — dois security groups separados:**

Cada tipo de instância tem seu próprio SG. Isso permite que no futuro você adicione regras específicas por tipo:
- Control Plane pode precisar de portas abertas para workers (ex: Kubernetes API 6443)
- Workers podem precisar de portas entre si (ex: kubelets, CNI)
- A separação hoje facilita essa evolução sem refatoração

---

## 7. Camada 5 — Módulo EC2

O módulo `./modules/ec2` é invocado duas vezes — criando infraestrutura de EC2 idêntica em estrutura mas com configurações diferentes para cada tipo.

### Como o módulo é chamado

```hcl
# server/ec2.instances.control-plane.tf
module "ec2_instances_control_plane" {
  source                = "./modules/ec2"
  tags                  = var.tags
  instance_profile_name = aws_iam_instance_profile.instance_profile.name

  launch_template = {
    name          = var.control_plane_launch_template.name
    instance_type = var.control_plane_launch_template.instance_type   # t3.micro
    image_id      = data.aws_ami.this.image_id                        # Debian 12 latest
    key_pair_name = aws_key_pair.this.key_name
    vpc_security_group_ids = [aws_security_group.control_plane.id]    # SG do control plane
    user_data     = filebase64(var.control_plane_launch_template.user_data)
    ebs = {
      size                  = 20
      delete_on_termination = true
    }
    # ...
  }

  auto_scaling_group = {
    name                = var.control_plane_auto_scaling_group.name
    max_size            = 1
    min_size            = 1
    desired_capacity    = 1
    vpc_zone_identifier = data.aws_subnets.private_subnets.ids   # subnets privadas
    instance_tags = merge(
      var.tags,
      var.control_plane_auto_scaling_group.instance_tags,
      { PatchGroup = var.patch_group }   # "Production" — tag usada pelo SSM
    )
    # ...
  }
}
```

O módulo `worker` é chamado da mesma forma, com os valores de `worker_launch_template` e `worker_auto_scaling_group` — cada um com seu próprio SG.

### Dentro do módulo: Launch Template

```hcl
# server/modules/ec2/ec2.launch-template.tf
resource "aws_launch_template" "this" {
  name                                 = var.launch_template.name
  instance_type                        = var.launch_template.instance_type
  image_id                             = var.launch_template.image_id
  key_name                             = var.launch_template.key_pair_name
  vpc_security_group_ids               = var.launch_template.vpc_security_group_ids
  user_data                            = var.launch_template.user_data
  disable_api_stop                     = var.launch_template.disable_api_stop
  disable_api_termination              = var.launch_template.disable_api_termination
  instance_initiated_shutdown_behavior = var.launch_template.instance_initiated_shutdown_behavior

  block_device_mappings {
    device_name = "/dev/xvda"   # nome do disco root no Linux
    ebs {
      volume_size           = var.launch_template.ebs.size             # 20 GB
      delete_on_termination = var.launch_template.ebs.delete_on_termination  # true
    }
  }

  iam_instance_profile {
    name = var.instance_profile_name   # nsse-production-instance-profile
  }

  tag_specifications {
    resource_type = "instance"
    tags          = var.tags
  }
}
```

**O Launch Template é o blueprint da instância.** Pense nele como uma "receita" que o ASG usa toda vez que precisa criar uma nova instância. Ele define:

```
Launch Template
  ├── AMI              → qual sistema operacional (Debian 12)
  ├── Instance Type    → hardware (t3.micro)
  ├── Key Pair         → qual chave SSH (mesmo sem SSH aberto no SG)
  ├── Security Groups  → regras de rede
  ├── IAM Profile      → identidade da instância
  ├── User Data        → script executado na primeira inicialização
  ├── EBS              → disco root (20GB, deletar ao terminar)
  ├── disable_api_stop       → impede Stop via API (proteção)
  ├── disable_api_termination → impede Terminate via API (proteção)
  └── shutdown_behavior = "terminate" → desligar via SO termina a instância
```

**`disable_api_stop` e `disable_api_termination`:**

Esses campos são proteções contra operações acidentais ou mal-intencionadas:
- `disable_api_stop = true` → `aws ec2 stop-instances` falha. A instância só para via shutdown do SO
- `disable_api_termination = true` → `aws ec2 terminate-instances` falha. Só o Terraform (que sabe contornar) pode destruir
- `shutdown_behavior = "terminate"` → se alguém rodar `shutdown` dentro da instância, ela termina (não para)

Combinados, esses três campos garantem que as instâncias são gerenciadas apenas pelo Terraform e pelo ASG.

### Dentro do módulo: Auto Scaling Group

```hcl
# server/modules/ec2/ec2.auto-scaling-group.tf
locals {
  # Transforma map → lista de {key, value} porque o bloco "tag" do ASG exige esse formato
  asg_tags_dictionary = [for key, value in var.auto_scaling_group.instance_tags : {
    key   = key
    value = value
  }]
}

resource "aws_autoscaling_group" "this" {
  name                = var.auto_scaling_group.name
  max_size            = var.auto_scaling_group.max_size            # 1
  min_size            = var.auto_scaling_group.min_size            # 1
  desired_capacity    = var.auto_scaling_group.desired_capacity    # 1
  health_check_type   = var.auto_scaling_group.health_check_type  # "EC2"
  vpc_zone_identifier = var.auto_scaling_group.vpc_zone_identifier # subnets privadas

  launch_template {
    name    = aws_launch_template.this.name
    version = "$Latest"   # sempre usa a versão mais recente do launch template
  }

  instance_maintenance_policy {
    min_healthy_percentage = 100   # 100% das instâncias devem estar saudáveis antes de update
    max_healthy_percentage = 110   # pode ter até 10% a mais temporariamente durante update
  }

  dynamic "tag" {
    for_each = local.asg_tags_dictionary
    content {
      key                 = tag.value.key
      value               = tag.value.value
      propagate_at_launch = true   # propaga as tags para as instâncias criadas pelo ASG
    }
  }
}
```

**O Auto Scaling Group é o gestor da frota.** Ele garante que sempre haverá o número correto de instâncias rodando:

```
ASG com min=1, max=1, desired=1:
  → Sempre exatamente 1 instância
  → Se a instância morrer → ASG cria uma nova automaticamente
  → Se tentar criar uma segunda → ASG não permite (max=1)
```

**`vpc_zone_identifier` com múltiplas subnets:**

```hcl
vpc_zone_identifier = data.aws_subnets.private_subnets.ids
# → ["subnet-abc", "subnet-def", "subnet-ghi"]  (uma por AZ)
```

Com múltiplas subnets (uma por AZ), o ASG distribui instâncias entre zonas de disponibilidade. Se uma AZ cair, as instâncias são recriadas em outra AZ automaticamente.

**`version = "$Latest"` no launch template:**

O ASG usa a versão mais recente do launch template. Isso significa que ao atualizar o launch template (nova AMI, por exemplo), o ASG usará a nova versão nas próximas substituições de instância.

**`instance_maintenance_policy`:**

```
min_healthy_percentage = 100 → antes de remover instâncias antigas,
                               garanta que 100% das novas estão saudáveis
max_healthy_percentage = 110 → pode ter temporariamente 10% a mais
                               durante uma atualização rolling
```

Na prática com `desired=1`: o ASG cria 1 nova instância, espera ela estar saudável, depois termina a antiga. Zero downtime durante updates.

**A tag `PatchGroup`:**

```hcl
instance_tags = merge(
  var.tags,
  var.control_plane_auto_scaling_group.instance_tags,
  { PatchGroup = var.patch_group }   # PatchGroup = "Production"
)
```

Com `propagate_at_launch = true`, essa tag é propagada para cada instância criada pelo ASG. O SSM Patch Group usa exatamente essa tag para identificar quais instâncias devem receber patches — conectando a camada de compute com a camada de patching.

---

## 8. Camada 6 — SSM Patching

Esta é a camada de **operações** — define como e quando as instâncias recebem atualizações de segurança, sem necessidade de acesso SSH.

### Os 4 recursos e como se conectam

```
aws_ssm_patch_baseline.this
  "Quais patches aplicar?"
        │
        ▼
aws_ssm_patch_group.this
  "Em quais instâncias aplicar?"
  (baseline_id + tag PatchGroup="Production")
        │
        ▼
aws_ssm_association.debian_production
  "Quando executar?"
  (schedule cron + documento AWS-RunPatchBaseline)
        │
        ▼
aws_s3_bucket.ssm_logs
  "Onde guardar os resultados?"
  └── aws_s3_bucket_policy → permite que as instâncias escrevam
```

### `aws_ssm_patch_baseline`

```hcl
resource "aws_ssm_patch_baseline" "this" {
  name             = "DebianProductionPatchBaseline"
  operating_system = "DEBIAN"
  approved_patches_enable_non_security = false   # só patches de segurança

  dynamic "approval_rule" {
    for_each = var.debian_patch_baseline.approval_rules
    content {
      approve_after_days = approval_rule.value.approve_after_days   # 0 = imediato
      compliance_level   = approval_rule.value.compliance_level

      dynamic "patch_filter" {
        for_each = approval_rule.value.patch_filter
        content {
          key    = upper(tostring(patch_filter.key))   # "PRODUCT", "SECTION", "PRIORITY"
          values = patch_filter.value
        }
      }
    }
  }
}
```

A baseline define as **regras de aprovação de patches** — quais patches devem ser instalados e com qual urgência. O `dynamic "approval_rule"` dentro de `dynamic "patch_filter"` é um aninhamento de blocos dinâmicos que substitui o que seriam dezenas de linhas de código repetido.

**As duas regras de aprovação:**

```
Regra 1 (CRITICAL):
  approve_after_days = 0         → aplica imediatamente, sem espera
  compliance_level   = CRITICAL  → falha de compliance se não instalado
  patch_filter:
    PRODUCT  = ["Debian12"]
    SECTION  = ["*"]             → qualquer seção de pacote
    PRIORITY = ["Required", "Important"]  → patches essenciais

Regra 2 (INFORMATIONAL):
  approve_after_days = 0
  compliance_level   = INFORMATIONAL  → avisa mas não falha compliance
  patch_filter:
    PRODUCT  = ["Debian12"]
    SECTION  = ["*"]
    PRIORITY = ["Standard"]     → patches menos urgentes
```

**`approve_after_days = 0`** significa que patches são aprovados imediatamente quando disponíveis — sem período de quarentena. Em ambientes mais conservadores, usa-se 7 ou 14 dias para observar se o patch causa problemas antes de aprovar.

---

### `aws_ssm_patch_group`

```hcl
resource "aws_ssm_patch_group" "this" {
  baseline_id = aws_ssm_patch_baseline.this.id
  patch_group = var.patch_group   # "Production"
}
```

Este recurso faz a **ligação entre a baseline e as instâncias**. O SSM usa a tag `PatchGroup` das instâncias para associá-las a uma baseline:

```
Instância EC2
  └── tag: PatchGroup = "Production"
                │
                ▼
aws_ssm_patch_group
  └── patch_group = "Production"
  └── baseline_id = "pb-abc123"
                │
                ▼
aws_ssm_patch_baseline
  └── regras de quais patches aplicar
```

Sem essa ligação, as instâncias usariam a baseline padrão da AWS para Debian — que pode não ter as configurações específicas que você quer.

---

### `aws_ssm_association`

```hcl
resource "aws_ssm_association" "debian_production" {
  name                = "AWS-RunPatchBaseline"   # documento SSM oficial da AWS
  schedule_expression = "cron(*/30 * * * ? *)"  # a cada 30 minutos
  association_name    = "DebianRunPatchBaselineAssociation"
  max_concurrency     = 1   # patcha 1 instância por vez
  max_errors          = 0   # aborta se qualquer instância falhar

  parameters = {
    Operation    = "Install"        # instala os patches (não apenas escaneia)
    RebootOption = "RebootIfNeeded" # reinicia se o patch exigir
  }

  output_location {
    s3_bucket_name = aws_s3_bucket.ssm_logs.bucket
    s3_key_prefix  = "patching-logs"
  }

  targets {
    key    = "tag:PatchGroup"       # filtra instâncias pela tag
    values = ["Production"]         # var.patch_group
  }
}
```

A `aws_ssm_association` é o **agendador e executor** — ela conecta:
- **Quem executar:** instâncias com `tag:PatchGroup = Production`
- **O que executar:** documento `AWS-RunPatchBaseline` (script oficial da AWS)
- **Quando executar:** a cada 30 minutos
- **Como executar:** instalar patches, reiniciar se necessário, máximo 1 instância simultânea
- **Onde guardar resultados:** S3 bucket de logs

**`max_concurrency = 1` e `max_errors = 0`:**

```
max_concurrency = 1 → em um cluster de N instâncias,
                      patcha 1 de cada vez (rolling patch)
                      evita que todo o cluster fique indisponível durante patches

max_errors = 0      → se a primeira instância falhar ao patchar,
                      aborta para as demais
                      previne propagar um problema para todo o cluster
```

**`cron(*/30 * * * ? *)`:**

Executa a cada 30 minutos. Na prática, o SSM verifica se há patches pendentes — se não houver, o scan é rápido e não causa impacto. Isso garante que patches críticos sejam aplicados dentro de 30 minutos após disponibilização.

---

### S3 Bucket de logs e sua Bucket Policy

```hcl
# server/ssm.patching.association.logs.tf

resource "aws_s3_bucket" "ssm_logs" {
  bucket        = "nsse-production-ssm-patching-logs"
  force_destroy = true
  tags          = var.tags
}

data "aws_iam_policy_document" "allow_access_from_instances" {
  statement {
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.instance_role.arn]  # a role das instâncias
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.ssm_logs.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "allow_access_from_instances" {
  bucket = aws_s3_bucket.ssm_logs.id
  policy = data.aws_iam_policy_document.allow_access_from_instances.json
}
```

**Por que o bucket policy em vez de só a identity policy:**

As instâncias precisam de **duas permissões** para escrever neste bucket:
1. Identity Policy (via `AmazonSSMManagedInstanceCore`) — já tem permissão de `s3:GetObject` nos buckets `aws-ssm-*` mas **não** `s3:PutObject` neste bucket customizado
2. Bucket Policy — concede `s3:PutObject` explicitamente para a role das instâncias

A Bucket Policy também age como uma proteção adicional — mesmo que alguém adicione uma policy permissiva à role das instâncias, só o `s3:PutObject` está autorizado neste bucket.

**O `aws_iam_role.instance_role.arn` como Principal na Bucket Policy:**

```
Instância EC2
  └── assume aws_iam_role.instance_role (via instance profile)
          │
          ▼
  SSM Agent tenta escrever log em S3
          │
          ▼
  AWS avalia:
    1. Identity Policy da role → tem s3:PutObject aqui? Não explicitamente
    2. Bucket Policy do bucket → permite s3:PutObject para essa role? SIM ✓
          │
          ▼
  Log escrito com sucesso
```

---

## 9. Camada 7 — User Data

Os scripts de user data são executados **uma única vez**, na primeira inicialização da instância. São idênticos para control plane e worker.

```bash
#!/bin/bash

function installSystemsManagerAgentOnEC2() {
  apt-get update -y

  if [ ! -d "/tmp/ssm" ]; then
    mkdir -p /tmp/ssm
  fi

  cd /tmp/ssm

  if [ ! -f "amazon-ssm-agent.deb" ]; then
    wget https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
  fi

  dpkg -i amazon-ssm-agent.deb
}

installSystemsManagerAgentOnEC2
```

**O que faz:**
1. Atualiza os repositórios de pacotes do Debian
2. Cria o diretório temporário `/tmp/ssm`
3. Baixa o pacote `.deb` do SSM Agent diretamente do S3 da AWS
4. Instala o SSM Agent via `dpkg`

**Por que isso é necessário:**

A AMI Debian 12 da AWS não vem com o SSM Agent instalado por padrão (ao contrário das AMIs Amazon Linux). Sem o SSM Agent, as instâncias são invisíveis para o SSM — não podem receber comandos, não podem ser patchadas, não têm acesso via Session Manager.

**O ciclo que fecha:**

```
User Data instala SSM Agent
    │
    ▼
SSM Agent inicia e registra a instância no serviço SSM
    │
    ▼
SSM verifica a tag PatchGroup da instância
    │
    ▼
SSM aplica a Patch Baseline associada ao grupo "Production"
    │
    ▼
Resultado do patch escrito no S3 (via Bucket Policy)
```

**Como o user data chega à instância:**

```hcl
# No módulo:
user_data = filebase64(var.control_plane_launch_template.user_data)
# filebase64 lê o arquivo .sh e converte para base64

# No launch template:
user_data = var.launch_template.user_data  # já está em base64
```

O EC2 espera o user data em base64 — é o formato padrão para evitar problemas com caracteres especiais no script.

---

## 10. Decisões de design e segurança

### Sem SSH, tudo via SSM

Esta é a decisão mais importante do módulo. Os Security Groups não têm nenhuma regra de `ingress` — zero portas abertas.

```
Modelo tradicional (inseguro):
  → Abrir porta 22
  → Gerenciar chaves SSH
  → Rotacionar chaves
  → Auditar quem tem qual chave
  → Controlar acesso individual

Modelo SSM (atual):
  → Zero portas abertas
  → Acesso via IAM (quem tem permissão de ssm:StartSession)
  → Toda sessão auditada automaticamente no CloudTrail
  → Sem chaves para gerenciar ou rotacionar
  → Session Manager registra toda a sessão no S3/CloudWatch
```

O par de chaves existe como fallback de emergência — se o SSM falhar (ex: problema de rede antes do agent inicializar), você pode temporariamente adicionar a regra de ingress SSH no SG e conectar com a chave privada do state.

### Instâncias em subnets privadas

As instâncias ficam em subnets privadas — sem IP público, sem rota direta para a internet. O tráfego de saída vai via NAT Gateway (provisionado pelo módulo `networking/`).

```
Internet
    │
    ▼ (apenas saída, via NAT Gateway)
Subnet Privada
    └── Instâncias EC2 (sem IP público)
```

Para o SSM funcionar em subnets privadas, existem duas opções:
1. **NAT Gateway** (usado aqui) — tráfego SSM sai pela subnet pública via NAT
2. **VPC Endpoints** — cria endpoints privados para SSM dentro da VPC (mais seguro, sem tráfego passando pela internet)

### Proteção contra exclusão acidental

```hcl
disable_api_stop        = true   # não pode parar via API
disable_api_termination = true   # não pode terminar via API
```

Em produção, isso previne que um acidente no CLI ou Console destrua instâncias em uso. Para destruir com Terraform, o provider automaticamente remove essas proteções antes de terminar a instância.

### Dois SGs separados para control plane e worker

Mesmo sem regras hoje, a separação permite evoluir:

```
Futuro Control Plane (Kubernetes):
  → ingress 6443 dos workers (API Server)
  → ingress 2379-2380 entre control planes (etcd)

Futuro Worker:
  → ingress 10250 do control plane (kubelet)
  → ingress entre workers para CNI (Flannel, Calico)
```

---

## 11. Linha do tempo de criação

Quando você roda `terraform apply` no módulo `server/`, esta é a ordem que o Terraform executa (em paralelo onde possível):

```
Fase 1 — Dados (sem dependências, tudo em paralelo):
  ├── data.aws_vpc.this
  ├── data.aws_ami.this
  └── (data.aws_subnets aguarda data.aws_vpc)

Fase 2 — Recursos base (após dados):
  ├── tls_private_key.this
  ├── data.aws_iam_policy_document.assume_role
  └── (security groups aguardam data.aws_vpc.this.id)

Fase 3 — Recursos que dependem da fase 2:
  ├── aws_key_pair.this              (aguarda tls_private_key)
  ├── aws_iam_role.instance_role     (aguarda policy_document)
  └── aws_security_group.control_plane (aguarda data.aws_vpc)
  └── aws_security_group.worker        (aguarda data.aws_vpc)

Fase 4 — Recursos que dependem da fase 3:
  ├── aws_iam_role_policy_attachment  (aguarda iam_role)
  ├── aws_iam_instance_profile        (aguarda iam_role)
  └── aws_ssm_patch_baseline.this     (sem dependências externas)

Fase 5 — S3 e módulos EC2 (após instance profile e security groups):
  ├── aws_s3_bucket.ssm_logs
  └── module.ec2_instances_control_plane
      └── aws_launch_template.this   (aguarda instance_profile, ami, key_pair, sg)
  └── module.ec2_instances_worker
      └── aws_launch_template.this

Fase 6 — Recursos finais:
  ├── aws_autoscaling_group (aguarda launch_template)
  ├── aws_s3_bucket_policy  (aguarda s3_bucket + iam_role)
  ├── aws_ssm_patch_group   (aguarda patch_baseline)
  └── aws_ssm_association   (aguarda s3_bucket)
```

---

## 12. Fluxo operacional completo

**O que acontece desde o `terraform apply` até a instância patchada:**

```
1. Terraform cria todos os recursos (veja linha do tempo acima)

2. ASG detecta: "desired_capacity=1, instâncias atuais=0"
   → Solicita criação de instância usando o Launch Template

3. AWS cria a instância EC2:
   → Na subnet privada selecionada pelo ASG
   → Com o Security Group atribuído
   → Com o Instance Profile associado
   → Com o User Data encodado em base64

4. Instância inicializa o SO Debian 12

5. EC2 executa o User Data (uma única vez):
   → apt-get update
   → wget amazon-ssm-agent.deb
   → dpkg -i amazon-ssm-agent.deb
   → SSM Agent instalado e iniciado como serviço systemd

6. SSM Agent inicia e registra a instância:
   → Chama 169.254.169.254 para obter credenciais temporárias da role
   → Usa credenciais para chamar ssm:RegisterManagedInstance
   → Instância aparece como "Online" no console do SSM

7. SSM Association verifica o schedule (a cada 30 min):
   → "Há instâncias com tag:PatchGroup=Production? Sim"
   → Inicia execução do documento AWS-RunPatchBaseline

8. AWS-RunPatchBaseline executa na instância:
   → Verifica quais patches estão aprovados na Patch Baseline
   → Compara com o estado atual dos pacotes
   → Instala os patches pendentes via apt-get
   → Se necessário, reinicia a instância
   → Grava resultado em /var/log/amazon/ssm/

9. SSM Agent envia o resultado para o S3:
   → Usa credenciais da role (Instance Profile)
   → s3:PutObject no bucket nsse-production-ssm-patching-logs
   → Autorizado pela Bucket Policy (principal = iam_role.instance_role.arn)

10. Resultado visível no console SSM → Compliance
    → COMPLIANT: todos os patches instalados
    → NON_COMPLIANT: algum patch falhou
```

**Para acessar as instâncias sem SSH:**

```bash
# Via AWS CLI — abre um shell na instância
aws ssm start-session \
  --target i-0abc1234 \
  --region us-east-1

# Via console AWS:
# Systems Manager → Session Manager → Start session → seleciona a instância
```

O acesso via Session Manager:
- Não requer portas abertas no Security Group
- Não requer chave SSH
- Toda sessão é auditada no CloudTrail
- Opcional: toda a sessão pode ser gravada no S3 ou CloudWatch
- Controlado via IAM (`ssm:StartSession`)
