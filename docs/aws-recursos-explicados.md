# Recursos AWS — Explicação a Fundo

> Cada serviço e recurso utilizado no projeto — o que é, como funciona internamente, por que existe e como se relaciona com os demais.

---

## Sumário

1. [VPC — Virtual Private Cloud](#1-vpc--virtual-private-cloud)
2. [Subnets — Segmentação da rede](#2-subnets--segmentação-da-rede)
3. [Internet Gateway](#3-internet-gateway)
4. [NAT Gateway](#4-nat-gateway)
5. [Route Tables — Tabelas de roteamento](#5-route-tables--tabelas-de-roteamento)
6. [Security Groups — Firewall stateful](#6-security-groups--firewall-stateful)
7. [AMI — Amazon Machine Image](#7-ami--amazon-machine-image)
8. [EC2 — Instâncias de computação](#8-ec2--instâncias-de-computação)
9. [Key Pair — Par de chaves SSH](#9-key-pair--par-de-chaves-ssh)
10. [Launch Template — Blueprint da instância](#10-launch-template--blueprint-da-instância)
11. [Auto Scaling Group](#11-auto-scaling-group)
12. [IAM Role e Instance Profile](#12-iam-role-e-instance-profile)
13. [S3 — Simple Storage Service](#13-s3--simple-storage-service)
14. [SSM — Systems Manager](#14-ssm--systems-manager)
15. [Como tudo se conecta — visão end-to-end](#15-como-tudo-se-conecta--visão-end-to-end)

---

## 1. VPC — Virtual Private Cloud

### O que é

A VPC é a sua **rede privada dentro da AWS**. Antes de criar qualquer recurso de computação, você precisa de uma rede onde esses recursos vão viver. A VPC é exatamente isso — um ambiente de rede logicamente isolado que você controla completamente.

Por padrão, cada conta AWS vem com uma VPC padrão em cada região. Em produção, você sempre cria VPCs customizadas para ter controle total sobre o espaço de endereços e a topologia.

### Como funciona internamente

A VPC é definida por um bloco CIDR — um intervalo de endereços IP que você declara como seu:

```
VPC: 10.0.0.0/24
  └── 256 endereços IP disponíveis (10.0.0.0 até 10.0.0.255)
```

No projeto:
```hcl
resource "aws_vpc" "this" {
  cidr_block = "10.0.0.0/24"   # 256 endereços
  tags = { Name = "nsse-production-vpc" }
}
```

A AWS reserva 5 endereços em qualquer subnet (primeiro, segundo, terceiro, penúltimo e último), então o total utilizável é sempre N-5.

### Isolamento e segurança

Recursos dentro de VPCs diferentes **não se comunicam por padrão**, mesmo que estejam na mesma conta e região. A comunicação entre VPCs exige configuração explícita (VPC Peering, Transit Gateway). Isso cria um isolamento real — comprometimento de uma VPC não afeta outra.

### O que a VPC fornece para os outros recursos

```
VPC "nsse-production-vpc" (10.0.0.0/24)
    │
    ├── Subnets         → onde os recursos ficam fisicamente alocados
    ├── Route Tables    → como o tráfego é roteado
    ├── Security Groups → firewall associado aos recursos
    ├── Internet GW     → porta de entrada/saída para a internet
    └── NAT Gateway     → saída controlada para subnets privadas
```

---

## 2. Subnets — Segmentação da rede

### O que é

Uma subnet é um **segmento da VPC** — uma fatia do bloco CIDR maior. Cada subnet fica em uma única **Availability Zone (AZ)** — um datacenter físico da AWS. Você distribui recursos em múltiplas subnets/AZs para ter alta disponibilidade.

### Subnets no projeto

```
VPC: 10.0.0.0/24 (256 IPs)
  │
  ├── Subnet Pública us-east-1a  → 10.0.0.0/27   (32 IPs)
  ├── Subnet Pública us-east-1b  → 10.0.0.64/27  (32 IPs)
  ├── Subnet Privada us-east-1a  → 10.0.0.32/27  (32 IPs)
  └── Subnet Privada us-east-1b  → 10.0.0.96/27  (32 IPs)
```

### Pública vs Privada — a diferença real

A distinção entre pública e privada não é uma propriedade da subnet em si — é uma consequência de **qual rota de tráfego ela usa** e **se atribui IP público**.

```hcl
# Subnet pública
resource "aws_subnet" "public" {
  map_public_ip_on_launch = true   # instâncias recebem IP público automaticamente
  # + route table aponta 0.0.0.0/0 para Internet Gateway
}

# Subnet privada
resource "aws_subnet" "private" {
  map_public_ip_on_launch = false  # instâncias NÃO recebem IP público
  # + route table aponta 0.0.0.0/0 para NAT Gateway
}
```

| Característica | Subnet Pública | Subnet Privada |
|---|---|---|
| IP público | Sim (automático) | Não |
| Acessível da internet | Sim (se SG permitir) | Não |
| Acesso à internet (saída) | Via Internet Gateway | Via NAT Gateway |
| Para que serve | Load Balancers, Bastion Hosts, NAT GW | EC2, RDS, caches |

### Por que as instâncias EC2 ficam em subnets privadas

As instâncias do projeto ficam em subnets privadas porque:

1. **Sem IP público** → não há como alguém da internet iniciar uma conexão diretamente
2. **Sem rota direta para internet** → tráfego de entrada impossível sem passar por um intermediário
3. **Saída controlada** → o NAT Gateway permite saída (para SSM, apt-get) sem permitir entrada
4. **Defense in depth** → mesmo que o Security Group tenha uma regra errada, a ausência de IP público e de rota de entrada protege a instância

### Availability Zones — por que duas subnets

Cada AZ é um datacenter **fisicamente separado** com energia, refrigeração e rede independentes. Ter subnets em duas AZs significa que se um datacenter inteiro cair, suas instâncias podem ser recriadas na outra AZ automaticamente pelo ASG.

```
us-east-1a (Datacenter A)          us-east-1b (Datacenter B)
  private-subnet-us-east-1a          private-subnet-us-east-1b
  └── instância control-plane        └── (criada aqui se 1a cair)
```

---

## 3. Internet Gateway

### O que é

O Internet Gateway (IGW) é o **portão de entrada e saída** entre a VPC e a internet pública. É um recurso gerenciado pela AWS — altamente disponível, sem necessidade de manutenção.

```hcl
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
}
```

### Como funciona

O IGW faz duas coisas:

**1. NAT para instâncias com IP público (subnets públicas):**
```
Instância (10.0.0.5, IP público 52.x.x.x)
  → pacote sai com IP de origem 10.0.0.5
  → IGW troca pelo IP público 52.x.x.x (NAT)
  → pacote chega na internet com IP 52.x.x.x

Resposta volta para 52.x.x.x
  → IGW faz o NAT reverso: entrega para 10.0.0.5
```

**2. Roteamento (route table das subnets públicas):**
```
Route Table Pública:
  10.0.0.0/24 → local (tráfego dentro da VPC)
  0.0.0.0/0   → Internet Gateway (todo tráfego externo)
```

### Por que o IGW não é usado pelas instâncias EC2

As instâncias do projeto ficam em subnets privadas — suas route tables apontam para o NAT Gateway, não para o IGW. O IGW é usado apenas:
- Pelo NAT Gateway (que fica na subnet pública)
- Por recursos futuros em subnets públicas (ex: load balancer)

---

## 4. NAT Gateway

### O que é

O NAT Gateway (Network Address Translation) permite que recursos em **subnets privadas saiam para a internet**, sem que a internet possa iniciar conexões de entrada para eles.

```hcl
resource "aws_nat_gateway" "this" {
  count         = length(aws_subnet.public)   # um por AZ
  allocation_id = aws_eip.this[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_eip" "this" {
  count  = length(aws_subnet.public)
  domain = "vpc"   # Elastic IP — IP público fixo para o NAT GW
}
```

### Como funciona

```
Instância Privada (10.0.0.33)
  → quer fazer apt-get update (destino: repositório debian)
  → consulta route table: "0.0.0.0/0 → NAT Gateway"
  → envia pacote para o NAT Gateway

NAT Gateway (IP privado: 10.0.0.5, IP público: 52.x.x.x via EIP)
  → recebe pacote de 10.0.0.33
  → faz NAT: troca origem por 52.x.x.x
  → envia para internet via Internet Gateway
  → guarda registro: "52.x.x.x:PORT = 10.0.0.33:PORT"

Resposta da internet chega em 52.x.x.x
  → NAT Gateway consulta registro
  → entrega para 10.0.0.33
  → instância privada recebe a resposta

Tentativa de entrada (atacante tenta 52.x.x.x):
  → NAT Gateway não tem registro para essa conexão
  → descarta o pacote
  → instância privada nunca vê o tráfego
```

### Por que um NAT Gateway por AZ

O projeto cria um NAT Gateway em cada AZ (um em `us-east-1a`, outro em `us-east-1b`):

```
private-subnet-us-east-1a → NAT Gateway us-east-1a → Internet
private-subnet-us-east-1b → NAT Gateway us-east-1b → Internet
```

Se você usar apenas um NAT Gateway e a AZ onde ele está cair, **todas** as instâncias privadas perdem acesso à internet — mesmo as que estão em outra AZ saudável. Um NAT por AZ evita esse single point of failure.

**Custo:** NAT Gateway cobra por hora + por GB processado. Um por AZ é mais caro mas necessário para alta disponibilidade real.

### O Elastic IP (EIP)

O EIP é um **IP público fixo e permanente** alocado para sua conta. O NAT Gateway precisa de um IP público estático para funcionar — diferente dos IPs públicos normais que mudam ao reiniciar recursos.

```
EIP: 52.x.x.x (fixo, não muda nunca enquanto alocado)
  └── associado ao NAT Gateway
        └── todo tráfego de saída das subnets privadas aparece como 52.x.x.x
```

Isso é útil quando serviços externos precisam de whitelist de IP — você sempre sabe qual IP vai usar.

---

## 5. Route Tables — Tabelas de roteamento

### O que é

Uma Route Table é a **tabela de decisão de roteamento** da subnet — ela define para onde cada pacote vai dependendo do IP de destino.

### Route Tables no projeto

```hcl
# Route Table das subnets PÚBLICAS
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id   # saída pela internet diretamente
  }
}

# Route Table das subnets PRIVADAS (uma por AZ)
resource "aws_route_table" "private" {
  count  = length(var.vpc.private_subnets)
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id   # saída pelo NAT
  }
}
```

### Como a decisão de roteamento funciona

Quando um pacote sai de uma instância, o sistema operacional consulta a route table da subnet:

```
Pacote com destino 8.8.8.8 (DNS Google):

Route Table Privada:
  10.0.0.0/24  → local          (rede interna — match mais específico)
  0.0.0.0/0    → nat-gateway    (qualquer outro destino — match padrão)

Decisão: 8.8.8.8 não está em 10.0.0.0/24 → vai para nat-gateway
```

A regra mais específica (menor bloco CIDR) sempre vence. A `0.0.0.0/0` é o "default gateway" — captura tudo que não casou com nenhuma rota mais específica.

### Association — vinculando subnet à route table

```hcl
resource "aws_route_table_association" "private" {
  count          = length(var.vpc.private_subnets)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
```

Sem a associação, a subnet usa a route table padrão da VPC, que só tem a rota `local`. Isso significa que instâncias sem associação explícita não têm saída para a internet.

---

## 6. Security Groups — Firewall stateful

### O que é

Um Security Group é um **firewall virtual stateful** associado a recursos (instâncias EC2, RDS, Lambda, etc.). Ele controla o tráfego de rede no nível da interface de rede elástica (ENI) da instância.

**Stateful** é a palavra-chave aqui — se você permite tráfego de entrada na porta 80, a resposta (tráfego de saída correspondente) é automaticamente permitida, sem precisar de regra de egress explícita.

### Como funciona internamente

O Security Group opera na camada do **hypervisor** da AWS — antes mesmo do tráfego chegar ao sistema operacional da instância. Isso significa que não importa o que esteja rodando dentro da VM: se o SG bloquear, o pacote nunca chega.

```
Internet → pacote TCP:443 → ENI da instância
                              │
                              ▼
                     Security Group avalia:
                     "Existe regra de ingress para porta 443?"
                              │
                      Sim → entrega à instância
                      Não → descarta silenciosamente (sem RST)
```

### Security Groups no projeto

```hcl
resource "aws_security_group" "control_plane" {
  name   = "nsse-production-control-plane-security-group"
  vpc_id = data.aws_vpc.this.id

  # Nenhuma regra de ingress — zero portas abertas de entrada

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"         # todos os protocolos
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}
```

**Por que só egress?**

O acesso às instâncias é feito via **SSM Session Manager**, que funciona de forma completamente diferente do SSH:

```
SSH tradicional:
  Usuário → inicia conexão TCP:22 → instância
  (requer ingress rule na porta 22)

SSM Session Manager:
  Instância → SSM Agent → abre conexão de SAÍDA para ssm.us-east-1.amazonaws.com
  Usuário → console SSM → AWS roteia pelo canal já aberto pela instância
  (sem ingress necessário — a instância iniciou a conexão)
```

### Diferença entre Security Group e NACL

Ambos controlam tráfego de rede, mas em camadas diferentes:

| | Security Group | NACL |
|---|---|---|
| Nível | Instância (ENI) | Subnet inteira |
| Stateful | Sim | Não |
| Regras | Allow apenas | Allow e Deny |
| Avaliação | Todas as regras | Primeira que casar (numeradas) |
| Uso | Controle por recurso | Controle por subnet |

O projeto usa apenas Security Groups — NACLs ficam com as regras padrão (allow all), pois o controle granular é feito no nível do SG.

### Regras de referência entre Security Groups

Em vez de usar IPs como origem/destino, você pode referenciar outro SG:

```hcl
# Workers podem receber tráfego do control plane na porta 10250 (kubelet)
ingress {
  from_port       = 10250
  to_port         = 10250
  protocol        = "tcp"
  security_groups = [aws_security_group.control_plane.id]  # só o control plane
}
```

Isso é mais robusto que IPs — se as instâncias forem recriadas com novos IPs, a regra continua válida.

---

## 7. AMI — Amazon Machine Image

### O que é

A AMI é o **template de disco** de uma instância EC2 — ela contém o sistema operacional, configurações iniciais e, opcionalmente, software pré-instalado. É o ponto de partida de toda instância.

Pense na AMI como um "snapshot congelado" de um disco configurado. Quando uma instância EC2 é criada, a AWS copia esse snapshot para um novo volume EBS e inicializa a VM a partir dele.

### Como funciona

```
AMI = manifesto + snapshots EBS

Manifesto:
  - ID da AMI
  - Arquitetura (x86_64, arm64)
  - Tipo de virtualização (hvm)
  - Tipo de root device (ebs)
  - Lista de block devices

Snapshots:
  - /dev/xvda (root) → S3 interno da AWS (não acessível diretamente)
```

Quando você lança uma instância:
```
AMI snapshot → copiado para novo EBS volume → anexado como /dev/xvda → instância boot
```

### A AMI no projeto

```hcl
data "aws_ami" "this" {
  most_recent = true
  owners      = ["136693071363"]   # conta oficial Debian

  filter { name = "name",                values = ["debian-12*"]  }
  filter { name = "architecture",        values = ["x86_64"]      }
  filter { name = "root-device-type",    values = ["ebs"]         }
  filter { name = "virtualization-type", values = ["hvm"]         }
}
```

**Por que validar o `owners`:**
Qualquer pessoa pode publicar AMIs no marketplace e dar qualquer nome. Sem fixar o `owners`, você poderia instanciar uma AMI maliciosa chamada "debian-12-oficial" publicada por um atacante. O account ID `136693071363` é verificável na documentação oficial da Debian.

**Por que `most_recent = true`:**
A Debian publica novas AMIs quando há atualizações do kernel ou patches de segurança importantes. Com `most_recent`, você sempre usa a versão mais atual — novas instâncias já sobem com os últimos patches de SO, reduzindo o trabalho do Patch Manager no primeiro boot.

**HVM vs Paravirtual:**
- **HVM (Hardware Virtual Machine):** a VM tem acesso virtualizado ao hardware real — usa extensões de virtualização da CPU (Intel VT-x, AMD-V). Melhor performance, suporte a todos os tipos de instância modernos.
- **Paravirtual (PV):** modelo legado onde o kernel precisa ser modificado para rodar na AWS. Mais lento, não suporta instâncias modernas. Evitar.

**EBS vs Instance Store:**
- **EBS:** disco em rede, persiste mesmo após stop/terminate (se configurado), pode ser snapshotado
- **Instance Store:** disco físico no host, **perde todos os dados ao parar ou terminar** a instância. Mais rápido mas efêmero.

O projeto usa EBS — correto para workloads que precisam de persistência.

---

## 8. EC2 — Instâncias de computação

### O que é

EC2 (Elastic Compute Cloud) é o serviço de **máquinas virtuais** da AWS. Uma instância EC2 é uma VM rodando em hardware físico da AWS, com CPU, memória, rede e disco alocados para você.

### Tipos de instância — famílias e tamanhos

A nomenclatura segue o padrão: `família + geração + tamanho`

```
t3.micro
│ │ └── micro (menor, mais barato)
│ └──── 3ª geração
└────── família t (burstable)
```

**Família `t` (Burstable Performance):**

As instâncias `t` têm uma peculiaridade importante: elas acumulam **CPU credits** quando ficam ociosas e gastam esses créditos quando precisam de CPU intensa. Quando os créditos acabam, a CPU é limitada ao "baseline" da instância.

```
t3.micro:
  vCPU:     2
  Memória:  1 GB
  Baseline: 10% de 1 vCPU
  Burst:    até 20% de 2 vCPUs (enquanto tiver créditos)
```

Para workloads que ficam ociosas a maior parte do tempo (como este cluster que aguarda patches) mas ocasionalmente precisam de CPU (durante instalação de patches), a família `t3` é ideal e muito mais barata que instâncias de performance dedicada.

**Outras famílias para referência:**

| Família | Otimizada para | Exemplos |
|---|---|---|
| `t3` | Uso geral burstable | web servers, dev, testes |
| `m6i` | Uso geral dedicado | APIs, backends |
| `c6i` | CPU intensiva | encoding, HPC |
| `r6i` | Memória intensiva | Redis, Elasticsearch |
| `g4dn` | GPU | ML inference |
| `i3` | Storage NVMe local | bancos de dados |

### O ciclo de boot de uma instância EC2

Entender o boot é essencial para debugar problemas de inicialização:

```
1. HYPERVISOR
   AWS recebe requisição de criação
   Aloca hardware físico no pool disponível
   Copia AMI snapshot para novo volume EBS
   Inicializa a VM

2. FIRMWARE / BIOS
   VM detecta o hardware virtualizado
   Localiza o disco root (/dev/xvda)

3. BOOTLOADER (GRUB)
   Carrega o kernel Linux da imagem
   Passa parâmetros de boot

4. KERNEL LINUX
   Inicializa drivers (virtio para hardware virtualizado)
   Monta o filesystem root (EBS volume)
   Inicia o processo init (systemd no Debian 12)

5. SYSTEMD
   Inicializa serviços na ordem correta
   Monta filesystems adicionais
   Configura rede
   Inicia cloud-init

6. CLOUD-INIT (fase 1 — metadata)
   Busca metadados em 169.254.169.254
   Configura hostname, usuários, chaves SSH
   Configura rede

7. USER DATA (cloud-init fase 2)
   Baixa o user data de 169.254.169.254/latest/user-data
   Detecta que é um script shell (#!/bin/bash)
   Executa UMA ÚNICA VEZ na primeira inicialização
   → instala o SSM Agent

8. INSTÂNCIA PRONTA
   SSM Agent inicia como serviço systemd
   Registra a instância no serviço SSM
   Instância fica "Online" no console SSM
```

### EBS — Elastic Block Store

O disco da instância é um volume EBS — armazenamento em bloco em rede:

```hcl
block_device_mappings {
  device_name = "/dev/xvda"   # nome do dispositivo root no Linux
  ebs {
    volume_size           = 20    # GB
    delete_on_termination = true  # deleta o disco quando a instância for terminada
  }
}
```

**`delete_on_termination = true`:** Em instâncias gerenciadas por ASG, que podem ser terminadas e recriadas, manter o disco seria um desperdício. O estado de configuração é gerenciado via user data e SSM, não em disco local.

### Instance Metadata Service (IMDS)

Todo recurso que o SO da instância precisa para se autoconfigurar está disponível em `http://169.254.169.254`:

```bash
# De dentro da instância
curl http://169.254.169.254/latest/meta-data/instance-id
# → i-0abc1234def56789

curl http://169.254.169.254/latest/meta-data/local-ipv4
# → 10.0.0.33

curl http://169.254.169.254/latest/meta-data/iam/security-credentials/
# → nsse-production-instance-role

curl http://169.254.169.254/latest/meta-data/iam/security-credentials/nsse-production-instance-role
# → { AccessKeyId, SecretAccessKey, Token, Expiration }
```

O IMDS é interceptado pelo hypervisor Nitro — nunca sai da VM.

---

## 9. Key Pair — Par de chaves SSH

### O que é

Um Key Pair é um **par de chaves criptográficas** (RSA, ED25519) usado para autenticação SSH sem senha. A chave pública fica na instância (`~/.ssh/authorized_keys`), a chave privada fica com você.

### Como é gerado no projeto

```hcl
# Provider TLS (HashiCorp) gera o par localmente, em memória
resource "tls_private_key" "this" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Envia apenas a chave pública para a AWS
resource "aws_key_pair" "this" {
  key_name   = "nsee-production-key-pair"
  public_key = tls_private_key.this.public_key_openssh
}
```

**Fluxo:**
```
Terraform executa terraform apply
    │
    ▼
Provider TLS gera par RSA 4096 bits (em memória)
    ├── chave privada (4096 bits)  → fica no STATE FILE
    └── chave pública              → enviada para AWS

AWS registra a chave pública com o nome "nsee-production-key-pair"

Quando a instância é criada com key_name = "nsee-production-key-pair":
    └── cloud-init coloca a chave pública em /home/admin/.ssh/authorized_keys
```

### RSA 4096 vs outros algoritmos

```
RSA 2048  → mínimo aceitável hoje, marginalmente mais rápido
RSA 4096  → mais seguro, ligeiramente mais lento na autenticação
ED25519   → moderno, mais rápido, chave menor, igualmente seguro
            (não disponível no provider tls do Terraform facilmente)
```

Para um par de chaves de emergência raramente usado, RSA 4096 é uma escolha sólida.

### O output sensível

```hcl
output "key_pair_private_key" {
  sensitive = true
  value     = tls_private_key.this.private_key_pem
}
```

```bash
# Como recuperar para uso de emergência
terraform output -raw key_pair_private_key > emergencia.pem
chmod 400 emergencia.pem

# Para usar seria necessário também:
# 1. Adicionar regra ingress SSH no security group temporariamente
# 2. Ter conectividade de rede para a subnet privada (VPN ou bastion)
ssh -i emergencia.pem admin@<IP-PRIVADO>
```

**Alerta de segurança:** A chave privada fica no state file no S3. O acesso ao bucket de state deve ser controlado rigorosamente com bucket policy e IAM.

---

## 10. Launch Template — Blueprint da instância

### O que é

O Launch Template é um **template de configuração** que define todos os parâmetros de uma instância EC2. O Auto Scaling Group usa esse template como receita para criar novas instâncias.

Pense como um "Dockerfile" para EC2 — define tudo que a instância precisa ser, sem criar nada por si só.

### Todos os atributos no projeto

```hcl
resource "aws_launch_template" "this" {
  name = "nsse-production-debian-control-plane-lt"

  # Sistema operacional
  image_id = data.aws_ami.this.image_id          # Debian 12 latest

  # Hardware
  instance_type = "t3.micro"                     # 2 vCPU, 1GB RAM

  # Acesso
  key_name             = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.control_plane.id]

  # Script de inicialização
  user_data = filebase64("./cli/control-plane-user-data.sh")

  # Disco
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      delete_on_termination = true
    }
  }

  # Identidade IAM
  iam_instance_profile {
    name = "nsse-production-instance-profile"
  }

  # Proteções
  disable_api_stop        = true    # impede aws ec2 stop-instances
  disable_api_termination = true    # impede aws ec2 terminate-instances

  # Comportamento ao shutdown do SO
  instance_initiated_shutdown_behavior = "terminate"
  # shutdown dentro da instância = termina (não para)

  # Tags nas instâncias criadas por este template
  tag_specifications {
    resource_type = "instance"
    tags = { Project = "nsse", Environment = "production" }
  }
}
```

### Launch Template vs Launch Configuration (legado)

A AWS tem dois mecanismos para definir instâncias em ASGs. O Launch Configuration é o legado (não suporta versionamento, imutável). O Launch Template é o atual:

| | Launch Template | Launch Configuration |
|---|---|---|
| Versionamento | Sim (v1, v2, v3...) | Não |
| Modificável | Cria nova versão | Imutável |
| Múltiplos instance types | Sim | Não |
| Spot + On-demand mix | Sim | Não |
| Recomendado | Sim | Não (legacy) |

### Versionamento do Launch Template

```hcl
launch_template {
  name    = aws_launch_template.this.name
  version = "$Latest"   # sempre usa a versão mais recente
}
```

Com `$Latest`, ao fazer update do template (nova AMI, por exemplo), o ASG usa a nova versão nas próximas substituições de instância — sem precisar recriar o ASG.

Versões disponíveis:
- `$Latest` → sempre a versão mais recente
- `$Default` → a versão marcada como padrão
- `"3"` → versão específica (imutável)

### `disable_api_stop` e `disable_api_termination`

Esses campos adicionam uma camada de proteção contra operações acidentais:

```bash
# Com disable_api_termination = true:
aws ec2 terminate-instances --instance-ids i-0abc1234
# Erro: The instance 'i-0abc1234' may not be terminated.
# Modify its 'disableApiTermination' instance attribute and try again.

# O Terraform sabe contornar isso — remove a proteção antes de destruir
```

Em um cluster gerenciado por ASG, isso previne que alguém delete instâncias individualmente — forçando que toda mudança passe pelo Terraform ou pelo ASG.

---

## 11. Auto Scaling Group

### O que é

O Auto Scaling Group (ASG) é o **gestor da frota de instâncias**. Ele garante que o número correto de instâncias esteja sempre rodando, recria instâncias que falharam, e distribui instâncias entre AZs automaticamente.

### Como funciona

```
ASG com min=1, max=1, desired=1:

Estado atual: 0 instâncias
  → ASG detecta: "desired=1, atual=0 → preciso criar 1"
  → Usa o Launch Template para criar a instância
  → Seleciona a subnet com menos instâncias (balanceamento entre AZs)
  → Instância criada e iniciada

Instância fica unhealthy:
  → ASG detecta via health check
  → Termina a instância unhealthy
  → Cria uma nova usando o Launch Template
  → Estado retorna a: desired=1

Terraform destrói o ASG:
  → ASG reduz desired para 0
  → Termina todas as instâncias
  → ASG é deletado
```

### Health Checks — como o ASG sabe se a instância está saudável

```hcl
health_check_type   = "EC2"
health_check_grace_period = 180   # espera 180s antes de iniciar health checks
```

**Tipo EC2 (usado no projeto):**
Verifica se a instância está em estado `running` e acessível no nível do hypervisor. É o check mais básico — instância ligada = saudável. Não verifica se a aplicação dentro está funcionando.

**Tipo ELB (para uso futuro):**
Verifica se a instância está respondendo às health checks do Load Balancer. Mais rigoroso — instância pode estar "ligada" mas com a aplicação travada.

O `health_check_grace_period = 180` dá 180 segundos para a instância completar o boot antes de começar os checks. Sem esse período, o ASG poderia terminar instâncias que ainda estão inicializando.

### `vpc_zone_identifier` — distribuição entre AZs

```hcl
vpc_zone_identifier = data.aws_subnets.private_subnets.ids
# → ["subnet-abc (us-east-1a)", "subnet-def (us-east-1b)"]
```

Com múltiplas subnets, o ASG distribui instâncias tentando manter equilíbrio entre AZs. Com `desired=1`, a instância fica em uma AZ. Se essa AZ falhar, o ASG recria em outra.

### `instance_maintenance_policy` — zero downtime em updates

```hcl
instance_maintenance_policy {
  min_healthy_percentage = 100   # nunca baixe do 100% de capacidade saudável
  max_healthy_percentage = 110   # pode ter até 10% a mais durante transição
}
```

Quando o launch template é atualizado (nova AMI, por exemplo) e o ASG faz um refresh:

```
Capacidade atual: 1 instância (100%)
min_healthy = 100%, max_healthy = 110%

Processo de refresh:
1. Cria nova instância com novo template (capacidade: 200%)
   Mas 200% > 110% → aguarda nova ficar healthy
2. Nova instância sobe (healthy)
   Agora tem 200% de capacidade saudável → dentro do max 110%? Não
   → Na verdade funciona assim: cria a nova, verifica health, aí termina a antiga

Resultado: novo boot sem downtime
```

### Tags com `propagate_at_launch`

```hcl
dynamic "tag" {
  for_each = local.asg_tags_dictionary
  content {
    key                 = tag.value.key
    value               = tag.value.value
    propagate_at_launch = true   # propaga para cada instância criada
  }
}
```

Sem `propagate_at_launch = true`, as tags ficam apenas no ASG — as instâncias criadas por ele não herdam as tags. Com `true`, cada nova instância já nasce com todas as tags — incluindo `PatchGroup = "Production"` que o SSM usa para identificação.

---

## 12. IAM Role e Instance Profile

*(Cobertos em profundidade no guia aws-iam-guia-completo.md. Aqui o foco é no contexto específico do EC2.)*

### O fluxo de credenciais na instância

```
aws_iam_role "nsse-production-instance-role"
  └── Trust Policy: "ec2.amazonaws.com pode assumir"
  └── Permission: AmazonSSMManagedInstanceCore

aws_iam_instance_profile "nsse-production-instance-profile"
  └── referencia a role acima

aws_launch_template
  └── iam_instance_profile { name = "nsse-production-instance-profile" }

EC2 instância
  └── hypervisor Nitro sabe: "esta VM tem o profile X → role Y"

SSM Agent (dentro da instância)
  └── curl GET 169.254.169.254/latest/meta-data/iam/security-credentials/
      → "nsse-production-instance-role"
  └── curl GET 169.254.169.254/.../nsse-production-instance-role
      → { AccessKeyId, SecretAccessKey, Token, Expiration }
  └── usa as credenciais para chamar ssm:UpdateInstanceInformation
      → instância registrada no SSM
```

### Por que o `aws_iam_role.instance_role.arn` aparece na Bucket Policy dos logs

```hcl
data "aws_iam_policy_document" "allow_access_from_instances" {
  statement {
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.instance_role.arn]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.ssm_logs.arn}/*"]
  }
}
```

A `AmazonSSMManagedInstanceCore` dá permissão de `s3:GetObject` apenas em buckets `aws-ssm-*` (buckets internos da AWS). Para escrever logs em **seu** bucket, é necessário conceder `s3:PutObject` explicitamente.

A Bucket Policy usa o ARN da role como Principal — qualquer instância que assumir essa role (via Instance Profile) pode gravar logs no bucket.

---

## 13. S3 — Simple Storage Service

### O que é

S3 é o serviço de **armazenamento de objetos** da AWS. Diferente de um filesystem tradicional (que organiza arquivos em diretórios com hierarquia real), o S3 organiza dados em **buckets** e **objetos** — pares de chave-valor onde a chave é o "caminho" e o valor é o conteúdo binário.

```
Filesystem tradicional:
  /var/log/ssm/patch-results/2026-03-12/i-0abc1234.log
  (hierarquia real, inodes, permissões POSIX)

S3:
  Bucket: nsse-production-ssm-patching-logs
  Key:    patching-logs/2026-03-12/i-0abc1234.log
  (apenas string como chave — não há diretórios reais)
```

### Como S3 funciona internamente

O S3 é um sistema distribuído com redundância automática em múltiplas AZs. Quando você faz `PUT` de um objeto:

```
PUT s3://meu-bucket/meu-arquivo.log

1. AWS recebe o objeto no edge location
2. Distribui automaticamente para pelo menos 3 AZs da região
3. Confirma durabilidade: 11 noves (99.999999999%)
4. Responde 200 OK com o ETag (hash MD5 do conteúdo)
```

A "chave" do objeto pode conter `/` — o console da AWS simula hierarquia de pastas, mas internamente é só uma string:

```
"patching-logs/2026-03-12/i-0abc1234.log"
 ─────────────────────────────────────────
 tudo isso é a chave — uma única string
```

### Os dois buckets S3 no projeto

**1. Bucket de backend (módulo `backend/`):**
```hcl
resource "aws_s3_bucket" "this" {
  bucket = "nsse-terraform-state-files-2026"
}
```
Armazena os state files do Terraform. Acesso controlado por IAM.

**2. Bucket de logs SSM (módulo `server/`):**
```hcl
resource "aws_s3_bucket" "ssm_logs" {
  bucket        = "nsse-production-ssm-patching-logs"
  force_destroy = true
  tags          = var.tags
}
```
Armazena os resultados das execuções de patch do SSM. As instâncias escrevem nele via SSM Agent.

### Bucket Policy

Uma Bucket Policy é uma **Resource-based Policy** aplicada diretamente no bucket. Define quem pode acessar o bucket e o que pode fazer — complementando as identity policies.

```hcl
data "aws_iam_policy_document" "allow_access_from_instances" {
  statement {
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.instance_role.arn]
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

**O que essa policy permite:**
- Principal: `arn:aws:iam::705777573148:role/nsse-production-instance-role`
- Ação: `s3:PutObject` (gravar objetos)
- Recurso: qualquer objeto dentro do bucket (`/*`)
- Implícito: `s3:GetObject`, `s3:DeleteObject` e tudo mais está **negado**

### `force_destroy = true` — atenção

```hcl
force_destroy = true
```

Por padrão, um bucket S3 não pode ser deletado se contiver objetos. O `force_destroy = true` faz o Terraform deletar todos os objetos antes de deletar o bucket — útil em ambientes de desenvolvimento para não ter recursos orphanados.

**Em produção real:** considere `force_destroy = false` para logs. Se alguém rodar `terraform destroy` acidentalmente, os logs são preservados.

---

## 14. SSM — Systems Manager

O SSM é um conjunto de ferramentas da AWS para **gerenciar instâncias sem acesso SSH**. No projeto, três sub-serviços são usados: Session Manager, Patch Manager e State Manager.

### 14.1 SSM Agent

O SSM Agent é um **daemon** (processo em background) que roda dentro da instância e serve como canal de comunicação entre a instância e o serviço SSM da AWS.

**Instalação via User Data:**
```bash
#!/bin/bash

function installSystemsManagerAgentOnEC2() {
  apt-get update -y
  mkdir -p /tmp/ssm
  cd /tmp/ssm
  wget https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
  dpkg -i amazon-ssm-agent.deb
}

installSystemsManagerAgentOnEC2
```

**Como o SSM Agent funciona:**

```
SSM Agent inicia como serviço systemd
    │
    ▼
Busca credenciais em 169.254.169.254
    │
    ▼
Chama ssm:RegisterManagedInstance
  → informa: instance-id, region, agent version, platform
    │
    ▼
Abre conexão persistente de SAÍDA para:
  ssm.us-east-1.amazonaws.com (controle)
  ssmmessages.us-east-1.amazonaws.com (mensagens)
  ec2messages.us-east-1.amazonaws.com (EC2 messages)
    │
    ▼
Aguarda comandos do serviço SSM
  → "execute este documento"
  → "abra canal de session manager"
  → "verifique e instale patches"
```

A instância **nunca recebe conexões de entrada**. O SSM Agent abre a conexão de saída e a mantém aberta. Quando você inicia uma sessão ou executa um comando, o serviço SSM roteia pelo canal já estabelecido.

**Por que `apt-get update` antes do wget:**

O Debian 12 em AMIs recentes pode ter índices de pacotes desatualizados. O `apt-get update` sincroniza a lista de pacotes disponíveis. O SSM Agent é baixado diretamente do S3 da AWS (não dos repositórios Debian) — mas o `wget` precisa estar atualizado e funcional.

**`function` com typo `fucntion`:**

```bash
fucntion installSystemsManagerAgentOnEC2() {   # typo: "fucntion" em vez de "function"
```

O Bash é permissivo com definições de função — esse typo específico ainda funciona porque `fucntion` não é uma keyword reservada, o Bash trata como nome de variável e continua parseando. Mas é um bug latente que deve ser corrigido.

### 14.2 Session Manager

O Session Manager permite **acesso shell às instâncias sem SSH**, sem portas abertas no Security Group e sem chaves SSH.

**Como funciona o tunnel:**

```
Você (console AWS ou CLI)
    │
    ▼
aws ssm start-session --target i-0abc1234
    │
    ▼
Serviço SSM recebe o pedido
    │
    ▼
SSM roteia pelo canal já aberto pelo SSM Agent da instância
    │
    ▼
SSM Agent recebe: "abra um shell"
    │
    ▼
SSM Agent cria /bin/bash e conecta stdin/stdout ao canal
    │
    ▼
Você tem um shell interativo na instância

Todo o tráfego:
  → Criptografado (TLS 1.2+)
  → Via canal já estabelecido pela instância (sem ingress)
  → Auditado no CloudTrail
  → Sessão pode ser gravada em S3/CloudWatch
```

**Controle de acesso via IAM:**

```json
{
  "Effect": "Allow",
  "Action": "ssm:StartSession",
  "Resource": "arn:aws:ec2:us-east-1:*:instance/i-0abc1234"
}
```

Você pode restringir acesso por instância específica, tag, ou qualquer condição IAM — granularidade impossível com SSH tradicional.

### 14.3 Patch Manager

O Patch Manager automatiza a **aplicação de patches de SO** nas instâncias. Funciona em três camadas:

```
Patch Baseline  → "quais patches aplicar?"
Patch Group     → "em quais instâncias?"
SSM Association → "quando e como executar?"
```

#### Patch Baseline

```hcl
resource "aws_ssm_patch_baseline" "this" {
  name             = "DebianProductionPatchBaseline"
  operating_system = "DEBIAN"
  approved_patches_enable_non_security = false

  dynamic "approval_rule" {
    for_each = var.debian_patch_baseline.approval_rules
    content {
      approve_after_days = approval_rule.value.approve_after_days   # 0
      compliance_level   = approval_rule.value.compliance_level

      dynamic "patch_filter" {
        for_each = approval_rule.value.patch_filter
        content {
          key    = upper(tostring(patch_filter.key))
          values = patch_filter.value
        }
      }
    }
  }
}
```

A Patch Baseline é o **catálogo de regras de aprovação** — define quais patches o Patch Manager pode instalar.

**Como o SSM avalia os patches disponíveis:**

```
SSM consulta repositórios Debian em busca de patches
    │
    ▼
Para cada patch disponível, avalia as regras:

Patch: linux-image-6.1.85-security
  PRODUCT  = "Debian12"  ✓
  SECTION  = "main"      ✓ (matches "*")
  PRIORITY = "Required"  ✓ (matches ["Required", "Important"])
  → approve_after_days = 0 → aprovado imediatamente
  → compliance_level = CRITICAL → obrigatório

Patch: gimp-2.10.36-update
  PRODUCT  = "Debian12"  ✓
  SECTION  = "graphics"  ✓
  PRIORITY = "Optional"  ✗ (não está em ["Required", "Important", "Standard"])
  → nenhuma regra casa → patch ignorado
```

**`approve_after_days = 0`:**
Patches são aprovados **imediatamente** quando disponíveis. Uma estratégia mais conservadora usaria 7-14 dias para observar se o patch causa problemas antes de aprovar amplamente. Para patches de segurança críticos, 0 é justificável.

**`compliance_level`:**
```
CRITICAL        → não ter o patch = NON_COMPLIANT (falha)
HIGH            → não ter = NON_COMPLIANT
MEDIUM          → não ter = NON_COMPLIANT
LOW             → não ter = NON_COMPLIANT
INFORMATIONAL   → não ter = aparece como informação, não falha compliance
UNSPECIFIED     → sem nível definido
```

O compliance é visível no console SSM → Compliance — você pode ver quais instâncias estão em conformidade ou não.

#### Patch Group

```hcl
resource "aws_ssm_patch_group" "this" {
  baseline_id = aws_ssm_patch_baseline.this.id
  patch_group = "Production"
}
```

O Patch Group é o **conector** entre a baseline e as instâncias. Ele diz: "instâncias com tag `PatchGroup=Production` devem usar esta baseline".

```
Tag na instância: PatchGroup = "Production"
                       │
                       ▼
         aws_ssm_patch_group.patch_group = "Production"
                       │
                       ▼
         aws_ssm_patch_baseline (DebianProductionPatchBaseline)
                       │
                       ▼
         Regras de aprovação aplicadas a essa instância
```

Você pode ter múltiplos Patch Groups com baselines diferentes:
```
PatchGroup = "Production"  → baseline conservadora (approve_after_days = 7)
PatchGroup = "Staging"     → baseline agressiva (approve_after_days = 0)
PatchGroup = "Development" → baseline mínima (só CRITICAL)
```

#### SSM Association (State Manager)

```hcl
resource "aws_ssm_association" "debian_production" {
  name                = "AWS-RunPatchBaseline"
  schedule_expression = "cron(*/30 * * * ? *)"   # a cada 30 minutos
  association_name    = "DebianRunPatchBaselineAssociation"
  max_concurrency     = 1    # 1 instância por vez
  max_errors          = 0    # aborta se qualquer falhar

  parameters = {
    Operation    = "Install"
    RebootOption = "RebootIfNeeded"
  }

  output_location {
    s3_bucket_name = aws_s3_bucket.ssm_logs.bucket
    s3_key_prefix  = "patching-logs"
  }

  targets {
    key    = "tag:PatchGroup"
    values = ["Production"]
  }
}
```

A SSM Association é um recurso do **State Manager** — o sub-serviço do SSM responsável por manter instâncias em um estado desejado através de execuções periódicas.

**O documento `AWS-RunPatchBaseline`:**

Documentos SSM são scripts/receitas pré-definidos que o SSM sabe executar. `AWS-RunPatchBaseline` é um documento oficial da AWS que:

```
1. Consulta qual Patch Baseline se aplica a esta instância (via PatchGroup)
2. Escaneia os pacotes instalados
3. Compara com a lista de patches aprovados pela baseline
4. Instala os patches pendentes via apt-get
5. Se RebootOption = "RebootIfNeeded" e algum patch exigiu reboot:
   → reinicia a instância
6. Pós-reboot: relata status de compliance ao SSM
7. Grava output detalhado no S3
```

**`cron(*/30 * * * ? *)`:**

```
*/30 → a cada 30 minutos (0, 30 de cada hora)
*    → qualquer hora
*    → qualquer dia do mês
*    → qualquer mês
?    → qualquer dia da semana (? é obrigatório quando dia do mês for *)
*    → qualquer ano
```

Na prática, o SSM verifica a cada 30 minutos se há patches pendentes. Se não houver, a execução é rápida (apenas scan). Se houver, instala.

**`max_concurrency = 1` e `max_errors = 0`:**

```
max_concurrency = 1:
  Em um cluster de 10 instâncias:
  → Patcha instância 1
  → Aguarda conclusão (sucesso ou falha)
  → Patcha instância 2
  → ... (rolling patch)
  
  Garante que nunca todo o cluster está sendo patchado simultaneamente
  → disponibilidade mantida durante patches

max_errors = 0:
  Se instância 3 falhar ao patchar:
  → Para o processo imediatamente
  → Instâncias 4-10 não são afetadas
  → Você investiga o problema na instância 3 antes de continuar
```

**`RebootOption = "RebootIfNeeded"`:**

Alguns patches de kernel ou libc exigem reboot para entrar em vigor. Com `RebootIfNeeded`, o SSM reinicia automaticamente quando necessário. Alternativas:
- `NoReboot` → nunca reinicia (patches podem não estar ativos até próximo reboot manual)
- `RebootIfNeeded` → reinicia apenas se necessário (padrão sensato)

**Output no S3:**

```
s3://nsse-production-ssm-patching-logs/
  └── patching-logs/
        └── <region>/
              └── <account-id>/
                    └── <instance-id>/
                          └── <association-id>/
                                └── <execution-id>/
                                      ├── stdout   (output do apt-get)
                                      └── stderr   (erros, se houver)
```

Cada execução gera um arquivo de log completo — auditoria total de quais patches foram instalados, quando, em qual instância.

---

## 15. Como tudo se conecta — visão end-to-end

### O grafo completo de relações

```
REDE (módulo networking/)
  VPC (10.0.0.0/24)
    ├── Subnet Pública us-east-1a (10.0.0.0/27)
    │     └── NAT Gateway us-east-1a ← EIP
    ├── Subnet Pública us-east-1b (10.0.0.64/27)
    │     └── NAT Gateway us-east-1b ← EIP
    ├── Subnet Privada us-east-1a (10.0.0.32/27) ← instâncias ficam aqui
    │     └── Route Table → NAT Gateway us-east-1a
    └── Subnet Privada us-east-1b (10.0.0.96/27)
          └── Route Table → NAT Gateway us-east-1b

IDENTIDADE (server/)
  IAM Role "nsse-production-instance-role"
    ├── Trust Policy: ec2.amazonaws.com pode assumir
    ├── AmazonSSMManagedInstanceCore (Managed Policy)
    └── S3 PutObject no bucket ssm_logs (via Bucket Policy)
  Instance Profile → encapsula a role para EC2

ACESSO (server/)
  Key Pair "nsee-production-key-pair"
    └── tls_private_key (RSA 4096) → chave pública na AWS, privada no state

REDE INTRA-VPC (server/)
  Security Group control_plane
    └── egress: tudo liberado / ingress: nenhum
  Security Group worker
    └── egress: tudo liberado / ingress: nenhum

COMPUTE (server/ → modules/ec2/)
  Launch Template control_plane
    ├── AMI: Debian 12 latest
    ├── Instance Type: t3.micro
    ├── Key Pair: nsee-production-key-pair
    ├── Security Group: control_plane
    ├── Instance Profile: nsse-production-instance-profile
    ├── User Data: instala SSM Agent
    └── EBS: 20GB, delete_on_termination=true

  Auto Scaling Group control_plane
    ├── Launch Template: control_plane
    ├── min=1, max=1, desired=1
    ├── Subnets: [private-us-east-1a, private-us-east-1b]
    └── Tags propagadas: Project, Environment, PatchGroup=Production

  Launch Template worker  (idem, com SG worker)
  Auto Scaling Group worker (idem)

PATCHES (server/)
  Patch Baseline "DebianProductionPatchBaseline"
    └── Regras: CRITICAL (Required/Important) + INFORMATIONAL (Standard)

  Patch Group "Production"
    └── Baseline: DebianProductionPatchBaseline
    └── Conecta instâncias com tag PatchGroup=Production à baseline

  SSM Association "DebianRunPatchBaselineAssociation"
    ├── Documento: AWS-RunPatchBaseline
    ├── Schedule: cron(*/30 * * * ? *)
    ├── Targets: instâncias com tag PatchGroup=Production
    ├── max_concurrency=1, max_errors=0
    └── Output: s3://nsse-production-ssm-patching-logs/patching-logs/

  S3 Bucket "nsse-production-ssm-patching-logs"
    └── Bucket Policy: permite s3:PutObject para instance_role
```

### A jornada completa de uma instância

```
t=0   terraform apply
      └── cria todos os recursos em paralelo

t=30s ASG detecta desired=1, cria instância no Launch Template
      └── instância criada na subnet privada us-east-1a

t=60s Instância boot: BIOS → GRUB → Kernel → systemd → cloud-init

t=90s cloud-init executa User Data:
      └── apt-get update
      └── wget amazon-ssm-agent.deb
      └── dpkg -i amazon-ssm-agent.deb
      └── SSM Agent inicia como serviço systemd

t=2min SSM Agent se registra:
       └── pega credenciais de 169.254.169.254
       └── chama ssm:RegisterManagedInstance
       └── instância aparece "Online" no console SSM

t=30min SSM Association executa:
        └── identifica instância: PatchGroup=Production
        └── consulta Patch Baseline
        └── escaneia pacotes instalados
        └── instala patches pendentes
        └── se necessário: reinicia instância
        └── grava resultado em S3

A cada 30min: ciclo de patch se repete (scan rápido se sem patches)

Instância unhealthy (crash, OOM):
  └── ASG detecta via health check
  └── Termina instância
  └── Cria nova (t=0 do ciclo acima se repete)
  └── Estado never perde: desired=1 sempre satisfeito
```

### Por que esta arquitetura é segura

```
Sem IP público
  → ninguém de fora pode iniciar conexão

Zero ingress no Security Group
  → mesmo com IP público hipotético, nenhuma porta está aberta

Acesso via SSM Session Manager
  → instância inicia conexão de saída
  → acesso controlado por IAM
  → auditado no CloudTrail

Identidade via Instance Profile
  → sem Access Keys fixas em disco ou variáveis de ambiente
  → credenciais temporárias, expiram automaticamente

Patches automáticos a cada 30 minutos
  → vulnerabilidades corrigidas rapidamente
  → sem intervenção manual necessária

Instâncias em subnets privadas
  → saída controlada via NAT Gateway
  → sem rota direta da internet para as instâncias
```
