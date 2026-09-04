# Guia Completo: AWS Security Groups

## Índice
1. [O que é Security Group](#o-que-é-security-group)
2. [Como funciona](#como-funciona)
3. [Por que precisamos](#por-que-precisamos)
4. [Vantagens](#vantagens)
5. [Exemplos práticos](#exemplos-práticos)
6. [Boas práticas](#boas-práticas)

---

## O que é Security Group?

**Security Group** é um **firewall virtual** que controla o tráfego de rede que entra e sai de recursos AWS, principalmente instâncias EC2.

### Analogia simples

Imagine um prédio corporativo:

```
┌─────────────────────────────────────────────┐
│        🏢 PRÉDIO (sua VPC)                  │
│                                             │
│  ┌───────────────────────────────────┐     │
│  │  👮 RECEPÇÃO COM SEGURANÇA        │     │
│  │  (Security Group)                 │     │
│  │                                   │     │
│  │  📋 Lista de acesso:              │     │
│  │  ✅ Funcionários (crachá válido)  │     │
│  │  ✅ Visitantes agendados          │     │
│  │  ✅ Entregas autorizadas          │     │
│  │  ❌ Pessoas sem autorização       │     │
│  └───────────────────────────────────┘     │
│                                             │
│         🖥️ Servidores (EC2)                │
└─────────────────────────────────────────────┘
```

O **Security Group** funciona como a **recepção do prédio**: verifica cada pessoa (pacote de rede) que tenta entrar ou sair, consultando uma lista de regras de acesso.

### Definição técnica

Security Group é um conjunto de regras de firewall que funciona no nível de instância (não no nível de subnet). Ele atua como uma camada de segurança virtual que controla:

- **Inbound traffic (tráfego de entrada)**: O que pode acessar seus recursos
- **Outbound traffic (tráfego de saída)**: Para onde seus recursos podem se conectar

---

## Como funciona

### Componentes principais

Um Security Group é composto por:

```
┌────────────────────────────────────────────┐
│  SECURITY GROUP                            │
├────────────────────────────────────────────┤
│                                            │
│  📥 INBOUND RULES (Entrada)               │
│  ├─ Regra 1: HTTP de 0.0.0.0/0           │
│  ├─ Regra 2: HTTPS de 0.0.0.0/0          │
│  └─ Regra 3: SSH de 203.0.113.5/32       │
│                                            │
│  📤 OUTBOUND RULES (Saída)                │
│  └─ Regra 1: Todo tráfego permitido       │
│                                            │
└────────────────────────────────────────────┘
```

### Anatomia de uma regra

Cada regra possui 4 componentes essenciais:

```
┌──────────────┬─────────┬──────────────────┬─────────────────┐
│ 1. TIPO      │ 2. PORTA│ 3. ORIGEM/DESTINO│ 4. DESCRIÇÃO    │
├──────────────┼─────────┼──────────────────┼─────────────────┤
│ HTTP         │ 80      │ 0.0.0.0/0        │ Acesso público  │
│ HTTPS        │ 443     │ 0.0.0.0/0        │ Acesso público  │
│ SSH          │ 22      │ 203.0.113.5/32   │ Admin somente   │
│ MySQL        │ 3306    │ sg-app-12345     │ App servers     │
│ Custom TCP   │ 8080    │ 10.0.0.0/24      │ Rede interna    │
└──────────────┴─────────┴──────────────────┴─────────────────┘
```

#### 1. Tipo/Protocolo
Define o tipo de tráfego:
- **HTTP** (porta 80)
- **HTTPS** (porta 443)
- **SSH** (porta 22)
- **RDP** (porta 3389)
- **MySQL** (porta 3306)
- **PostgreSQL** (porta 5432)
- **Custom** (portas personalizadas)

#### 2. Porta ou Range de Portas
- Porta única: `80`
- Range: `8000-8100`
- Todas: `0-65535`

#### 3. Origem (Inbound) ou Destino (Outbound)

**a) CIDR Block (endereços IP):**
```
0.0.0.0/0        → Qualquer lugar (Internet inteira)
203.0.113.5/32   → Um IP específico
10.0.0.0/24      → Range de IPs (10.0.0.0 até 10.0.0.255)
10.0.0.0/16      → Range maior (10.0.0.0 até 10.0.255.255)
```

**b) Security Group ID:**
```
sg-app-servers   → Qualquer instância com este SG
```

**c) Prefix List:**
```
pl-12345         → Lista de IPs gerenciada (ex: CloudFront)
```

#### 4. Descrição (opcional mas recomendado)
Comentário para explicar o propósito da regra.

### Características fundamentais

#### 1. Stateful (com memória)

Security Groups são **stateful**, o que significa que eles "lembram" das conexões:

```
┌─────────────────────────────────────────────────────┐
│ EXEMPLO: Usuário acessa seu site                   │
├─────────────────────────────────────────────────────┤
│                                                     │
│ 1. Requisição (ENTRADA):                           │
│    Internet → [SG verifica regra inbound] → EC2   │
│    ✅ Regra: HTTP porta 80 permitido               │
│                                                     │
│ 2. Resposta (SAÍDA):                               │
│    EC2 → [SG PERMITE AUTOMATICAMENTE] → Internet  │
│    ✅ Não precisa de regra outbound explícita!     │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Isso significa:**
- Se você permitir entrada na porta 80, a resposta na porta 80 é automática
- Não precisa criar regra de saída para cada entrada
- O firewall "rastreia" a conexão

**Comparação com firewalls stateless:**
```
STATEFUL (Security Group):
Entrada permitida → Saída AUTOMÁTICA ✅

STATELESS (Network ACL):
Entrada permitida → Precisa regra de saída EXPLÍCITA ❌
```

#### 2. Default Deny (bloqueio padrão)

```
Quando você cria um Security Group NOVO:

📥 INBOUND:  ❌ TUDO BLOQUEADO
             Você precisa ADICIONAR regras para permitir

📤 OUTBOUND: ✅ TUDO PERMITIDO
             Já vem com regra liberando tudo
```

**Implicação prática:**
- Security Group vazio = ninguém consegue acessar sua EC2
- Você precisa adicionar regras explícitas para permitir acesso
- Abordagem "segura por padrão"

#### 3. Allow-only (só permite, nunca nega)

Security Groups **só têm regras de PERMITIR**. Não existem regras de NEGAR.

```
❌ IMPOSSÍVEL fazer:
"Permitir todo mundo EXCETO o IP 1.2.3.4"

✅ VOCÊ DEVE fazer:
"Permitir apenas os IPs X, Y, Z"
Resultado: tudo que não está na lista é bloqueado
```

**Por quê?**
- Simplifica a lógica
- Tudo que não está explicitamente permitido = bloqueado
- Para negar IPs específicos, use Network ACL

#### 4. Avaliação de regras

Security Groups avaliam **TODAS as regras** antes de decidir:

```
Se QUALQUER regra permitir → ✅ PERMITE
Se NENHUMA regra permitir → ❌ BLOQUEIA
```

**Exemplo:**
```
Regra 1: Permitir SSH de 10.0.0.5
Regra 2: Permitir SSH de 10.0.0.6

Se conexão vem de 10.0.0.5 → ✅ PERMITIDO (Regra 1)
Se conexão vem de 10.0.0.6 → ✅ PERMITIDO (Regra 2)
Se conexão vem de 10.0.0.7 → ❌ BLOQUEADO (nenhuma regra)
```

### Fluxo de tráfego completo

```
INBOUND (Usuário acessando sua EC2):
┌────────────────────────────────────────────────────┐
│ 1. Pacote chega no Security Group                 │
│    Origem: 203.0.113.5                            │
│    Destino: sua-ec2                               │
│    Porta: 80                                      │
└────────────────────────────────────────────────────┘
                    ↓
┌────────────────────────────────────────────────────┐
│ 2. SG verifica TODAS as regras Inbound           │
│    Procura: porta 80 + origem 203.0.113.5 OU ANY │
└────────────────────────────────────────────────────┘
                    ↓
┌────────────────────────────────────────────────────┐
│ 3. Encontrou regra?                               │
│    ✅ SIM → Permite entrada                       │
│    ❌ NÃO → Descarta pacote (silenciosamente)     │
└────────────────────────────────────────────────────┘
                    ↓
┌────────────────────────────────────────────────────┐
│ 4. EC2 processa e responde                        │
└────────────────────────────────────────────────────┘
                    ↓
┌────────────────────────────────────────────────────┐
│ 5. Resposta AUTOMÁTICA permitida (stateful)       │
│    SG lembra da conexão e permite saída           │
└────────────────────────────────────────────────────┘

OUTBOUND (EC2 acessando Internet/outros serviços):
┌────────────────────────────────────────────────────┐
│ 1. EC2 inicia conexão para fora                   │
│    Origem: sua-ec2                                │
│    Destino: 8.8.8.8 (DNS Google)                  │
│    Porta: 53                                      │
└────────────────────────────────────────────────────┘
                    ↓
┌────────────────────────────────────────────────────┐
│ 2. SG verifica regras Outbound                    │
│    Procura: porta 53 + destino 8.8.8.8 OU ANY    │
└────────────────────────────────────────────────────┘
                    ↓
┌────────────────────────────────────────────────────┐
│ 3. Encontrou regra?                               │
│    ✅ SIM → Permite saída                         │
│    ❌ NÃO → Descarta pacote                       │
└────────────────────────────────────────────────────┘
                    ↓
┌────────────────────────────────────────────────────┐
│ 4. Resposta AUTOMÁTICA permitida (stateful)       │
│    SG permite entrada da resposta                 │
└────────────────────────────────────────────────────┘
```

---

## Por que precisamos

### 1. Segurança em camadas (Defense in Depth)

```
┌──────────────────────────────────────────────────┐
│  🌐 Internet (atacantes, bots, scanners)         │
└──────────────────────────────────────────────────┘
                    ↓
┌──────────────────────────────────────────────────┐
│  🛡️ CAMADA 1: Network ACL                       │
│     (firewall de subnet - stateless)            │
└──────────────────────────────────────────────────┘
                    ↓
┌──────────────────────────────────────────────────┐
│  🛡️ CAMADA 2: Security Group ← VOCÊ ESTÁ AQUI  │
│     (firewall de instância - stateful)          │
└──────────────────────────────────────────────────┘
                    ↓
┌──────────────────────────────────────────────────┐
│  🛡️ CAMADA 3: Firewall do SO (iptables)        │
│     (firewall dentro da EC2)                    │
└──────────────────────────────────────────────────┘
                    ↓
┌──────────────────────────────────────────────────┐
│  🛡️ CAMADA 4: Autenticação da aplicação        │
│     (login, tokens, etc.)                       │
└──────────────────────────────────────────────────┘
                    ↓
┌──────────────────────────────────────────────────┐
│  🎯 Aplicação                                    │
└──────────────────────────────────────────────────┘
```

Security Group é a **camada mais importante** de segurança na AWS porque:
- Está na borda do recurso (última linha antes da instância)
- Mais fácil de gerenciar que firewall do SO
- Integrado nativamente com AWS

### 2. Isolamento de recursos

**Problema sem Security Groups:**
```
┌─────────────────────────────────────────────┐
│  VPC (Rede)                                 │
│                                             │
│  🖥️ Web Server ──┐                         │
│                  │                          │
│  🗄️ Database ────┼─ TODOS podem acessar    │
│                  │   TODOS ❌               │
│  📊 Analytics ───┘                          │
│                                             │
└─────────────────────────────────────────────┘
```

**Com Security Groups:**
```
┌─────────────────────────────────────────────┐
│  VPC (Rede)                                 │
│                                             │
│  🖥️ Web (SG-Web)                           │
│      │                                      │
│      │ (pode acessar)                       │
│      ↓                                      │
│  🗄️ Database (SG-DB)                       │
│      ↑                                      │
│      │ (NÃO pode acessar)                   │
│      ✗                                      │
│  📊 Analytics (SG-Analytics)                │
│                                             │
└─────────────────────────────────────────────┘
```

**Princípio do menor privilégio:**
Cada recurso só pode acessar o que realmente precisa.

### 3. Proteção contra ataques comuns

#### a) Varredura de portas (Port Scanning)
```
Atacante tenta todas as portas:
┌────────────────────────────────┐
│ Tentativa 1: Porta 21 (FTP)   │ → ❌ Bloqueado
│ Tentativa 2: Porta 22 (SSH)   │ → ❌ Bloqueado
│ Tentativa 3: Porta 80 (HTTP)  │ → ✅ Permitido
│ Tentativa 4: Porta 3306 (DB)  │ → ❌ Bloqueado
└────────────────────────────────┘

Security Group bloqueia silenciosamente = atacante não sabe
o que está rodando no servidor.
```

#### b) Brute Force em SSH
```
❌ SEM Security Group:
   Qualquer um pode tentar SSH
   Milhares de tentativas de login

✅ COM Security Group:
   Apenas SEU IP pode tentar SSH
   Reduz superfície de ataque em 99.9%
```

#### c) DDoS (Distributed Denial of Service)
```
Security Group ajuda (mas não é solução completa):
- Limita portas de entrada
- Pode limitar origens (se conhecido)
- Reduz vetores de ataque

Para DDoS completo: AWS Shield + CloudFront
```

### 4. Controle de acesso granular

**Exemplo: Aplicação multi-tier**

```
┌──────────────────────────────────────────────────┐
│  🌐 INTERNET                                     │
└──────────────────────────────────────────────────┘
            ↓ (HTTP/HTTPS: 80, 443)
┌──────────────────────────────────────────────────┐
│  ⚖️ Load Balancer (SG-ALB)                      │
│  Inbound: 0.0.0.0/0 porta 80, 443               │
│  Outbound: SG-Web porta 80                      │
└──────────────────────────────────────────────────┘
            ↓ (HTTP: 80)
┌──────────────────────────────────────────────────┐
│  🖥️ Web Servers (SG-Web)                        │
│  Inbound: SG-ALB porta 80                       │
│  Outbound: SG-App porta 8080                    │
└──────────────────────────────────────────────────┘
            ↓ (API: 8080)
┌──────────────────────────────────────────────────┐
│  🔧 App Servers (SG-App)                        │
│  Inbound: SG-Web porta 8080                     │
│  Outbound: SG-DB porta 5432                     │
└──────────────────────────────────────────────────┘
            ↓ (PostgreSQL: 5432)
┌──────────────────────────────────────────────────┐
│  🗄️ Database (SG-DB)                            │
│  Inbound: SG-App porta 5432                     │
│  Outbound: Nada                                 │
└──────────────────────────────────────────────────┘
```

**Benefícios:**
- Database **nunca** está exposto à Internet
- Cada camada só fala com a próxima
- Se Web Server for comprometido, atacante não acessa Database direto
- Você controla exatamente quem fala com quem

### 5. Auditoria e compliance

Security Groups são rastreados pelo **AWS CloudTrail**:

```json
{
  "eventName": "AuthorizeSecurityGroupIngress",
  "userIdentity": {
    "userName": "pablo"
  },
  "requestParameters": {
    "groupId": "sg-12345",
    "ipPermissions": {
      "fromPort": 22,
      "toPort": 22,
      "ipRanges": ["0.0.0.0/0"]  ← Perigo!
    }
  }
}
```

**Vantagens para compliance:**
- Histórico de todas as mudanças
- Quem fez, quando fez, o quê fez
- Alertas automáticos (ex: porta 22 aberta para 0.0.0.0/0)
- Relatórios de conformidade

---

## Vantagens

### 1. Facilidade de gerenciamento

**Comparado com firewall tradicional (iptables):**

```bash
# ❌ iptables (complexo, manual):
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -s 203.0.113.5/32 -j ACCEPT
iptables -A INPUT -j DROP
iptables-save > /etc/iptables/rules.v4
```

```terraform
# ✅ Security Group (simples, declarativo):
resource "aws_security_group" "web" {
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
  
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["203.0.113.5/32"]
  }
}
```

**Vantagens:**
- Sintaxe mais simples
- Gerenciado pela AWS (não precisa manter no SO)
- Terraform/CloudFormation = Infrastructure as Code
- Mudanças aplicadas imediatamente

### 2. Escalabilidade automática

**Cenário: Auto Scaling Group**

```
Antes (1 instância):
EC2-1 (SG-Web)

Depois (100 instâncias):
EC2-1 (SG-Web)
EC2-2 (SG-Web)
...
EC2-100 (SG-Web)

✅ Todas herdam as mesmas regras automaticamente!
   Não precisa configurar firewall em cada instância.
```

**Mudança em massa:**
```
Você muda 1 regra no Security Group:
"Adicionar porta 8080"

↓

TODAS as 100 instâncias ganham a regra imediatamente!
```

### 3. Referência entre Security Groups

**Problema tradicional:**
```
Você tem 10 app servers com IPs:
10.0.1.10, 10.0.1.11, ..., 10.0.1.19

Database precisa permitir esses 10 IPs:
❌ Regra 1: 10.0.1.10/32
❌ Regra 2: 10.0.1.11/32
...
❌ Regra 10: 10.0.1.19/32

Novo app server? Adicionar IP manualmente ❌
App server morre e IP muda? Atualizar manualmente ❌
```

**Solução com Security Groups:**
```
✅ Database permite: SG-App (ID do Security Group)

Qualquer instância com SG-App → pode acessar
Nova instância com SG-App → automaticamente pode acessar
IP muda → não importa, SG que importa
```

**Exemplo Terraform:**
```terraform
resource "aws_security_group" "database" {
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]  # ← Referência!
  }
}
```

### 4. Alta disponibilidade e confiabilidade

Security Groups são:

```
✅ Gerenciados pela AWS (infra redundante)
✅ Distribuídos geograficamente
✅ Sem single point of failure
✅ Não adiciona latência perceptível
✅ Aplicação de regras em hardware/hypervisor (rápido)
```

**Comparado com:**
```
❌ Firewall físico: pode falhar, gargalo
❌ iptables na EC2: se EC2 cai, firewall cai
✅ Security Group: independente da EC2
```

### 5. Zero custo adicional

```
Security Groups são GRATUITOS! 🎉

Não importa:
- Quantos SGs você cria
- Quantas regras você tem
- Quanto tráfego passa

Você só paga pelos recursos (EC2, RDS, etc.)
```

### 6. Integração com serviços AWS

**Security Groups funcionam com:**

```
✅ EC2 (instâncias, interfaces de rede)
✅ RDS (bancos de dados)
✅ ElastiCache (Redis, Memcached)
✅ ELB (Load Balancers)
✅ Lambda (com VPC)
✅ ECS/EKS (containers)
✅ EMR (Hadoop/Spark)
✅ Redshift (Data Warehouse)
✅ WorkSpaces (desktops virtuais)
```

**Experiência consistente em todos os serviços.**

### 7. Mudanças instantâneas sem downtime

```
Você muda uma regra:
"Adicionar porta 443"

↓ (< 1 segundo)

✅ Regra ativa em TODAS as instâncias
✅ SEM reiniciar nada
✅ SEM downtime
✅ SEM perda de conexões existentes (stateful)
```

**Comparado com:**
```
❌ iptables: precisa reload, pode derrubar conexões
❌ Firewall físico: mudanças lentas, precisa aplicar
✅ Security Group: instantâneo e seguro
```

### 8. Versionamento e auditoria integrados

```
AWS CloudTrail registra TUDO:

2026-02-03 14:30:00 | pablo | Criou SG sg-web
2026-02-03 14:31:15 | pablo | Adicionou regra HTTP
2026-02-03 15:45:20 | maria | Adicionou regra SSH (0.0.0.0/0) ⚠️
2026-02-03 15:46:00 | AWS Config | ALERTA: SSH público detectado
2026-02-03 15:47:30 | pablo | Removeu regra SSH pública
```

**Vantagens:**
- Histórico completo
- Quem fez cada mudança
- Alertas automáticos
- Rollback fácil (saber o que mudou)

### 9. Testes e ambientes isolados

```
Ambiente de DEV:
EC2-dev (SG-dev) → permite SSH de qualquer lugar

Ambiente de PROD:
EC2-prod (SG-prod) → permite SSH apenas de IPs corporativos

✅ Mesma EC2, diferentes SGs = diferentes níveis de segurança
✅ Fácil de separar ambientes
✅ Promover de dev → prod = trocar SG
```

### 10. Compliance facilitado

Principais frameworks suportados:

```
✅ PCI-DSS: Firewall em todas as conexões
✅ HIPAA: Controle de acesso à rede
✅ SOC 2: Segurança de rede documentada
✅ GDPR: Proteção de dados em trânsito
✅ ISO 27001: Controles de segurança de rede
```

**AWS Security Hub** verifica automaticamente:
- Portas de banco expostas (3306, 5432, etc.)
- SSH/RDP público (22, 3389 com 0.0.0.0/0)
- Regras muito permissivas
- Security Groups não utilizados

---

## Exemplos práticos

### Exemplo 1: Servidor web público simples

```terraform
resource "aws_security_group" "web_simples" {
  name        = "web-simples"
  description = "Servidor web público - HTTP/HTTPS"
  vpc_id      = aws_vpc.main.id

  # Permite HTTP de qualquer lugar
  ingress {
    description = "HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Permite HTTPS de qualquer lugar
  ingress {
    description = "HTTPS from Internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Permite SSH apenas do seu IP
  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["203.0.113.5/32"]  # Substitua pelo seu IP
  }

  # Permite toda saída (para updates, APIs, etc.)
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "web-simples"
    Environment = "production"
  }
}
```

### Exemplo 2: Aplicação três camadas

```terraform
# Security Group para Load Balancer (público)
resource "aws_security_group" "alb" {
  name        = "alb-public"
  description = "Load Balancer público"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from Internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "To web servers"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  tags = {
    Name = "alb-public"
  }
}

# Security Group para Web Servers (privados)
resource "aws_security_group" "web" {
  name        = "web-servers"
  description = "Servidores web (recebem do ALB)"
  vpc_id      = aws_vpc.main.id

  # Apenas ALB pode acessar
  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # SSH da rede interna
  ingress {
    description = "SSH from corporate network"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    description     = "To app servers"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    description = "HTTPS for updates"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "web-servers"
  }
}

# Security Group para App Servers (privados)
resource "aws_security_group" "app" {
  name        = "app-servers"
  description = "Servidores de aplicação (recebem do Web)"
  vpc_id      = aws_vpc.main.id

  # Apenas Web Servers podem acessar
  ingress {
    description     = "API from web servers"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  egress {
    description     = "To database"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.database.id]
  }

  egress {
    description = "HTTPS for APIs/updates"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "app-servers"
  }
}

# Security Group para Database (totalmente isolado)
resource "aws_security_group" "database" {
  name        = "database"
  description = "Banco de dados PostgreSQL (isolado)"
  vpc_id      = aws_vpc.main.id

  # Apenas App Servers podem acessar
  ingress {
    description     = "PostgreSQL from app servers"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  # Database não precisa acessar nada externo
  # (sem egress rules = apenas respostas permitidas)

  tags = {
    Name = "database"
  }
}
```

### Exemplo 3: Bastion Host (Jump Server)

```terraform
# Security Group para Bastion (porta de entrada segura)
resource "aws_security_group" "bastion" {
  name        = "bastion-host"
  description = "Bastion host para acesso SSH"
  vpc_id      = aws_vpc.main.id

  # SSH apenas de IPs corporativos
  ingress {
    description = "SSH from corporate office"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [
      "203.0.113.10/32",  # Escritório 1
      "198.51.100.20/32"  # Escritório 2
    ]
  }

  # Bastion pode fazer SSH nos servidores internos
  egress {
    description     = "SSH to internal servers"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.internal.id]
  }

  tags = {
    Name = "bastion-host"
  }
}

# Security Group para servidores internos
resource "aws_security_group" "internal" {
  name        = "internal-servers"
  description = "Servidores internos (acesso via bastion)"
  vpc_id      = aws_vpc.main.id

  # SSH apenas do bastion
  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "internal-servers"
  }
}
```

---

## Boas práticas

### 1. Princípio do menor privilégio

```terraform
# ❌ RUIM: Muito permissivo
ingress {
  from_port   = 0
  to_port     = 65535
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}

# ✅ BOM: Específico e restrito
ingress {
  description = "HTTPS from CloudFront"
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  prefix_list_ids = ["pl-12345"]  # CloudFront IPs
}
```

### 2. Nunca expor portas administrativas publicamente

```terraform
# ❌ PERIGO: SSH público
ingress {
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]  # Todo mundo pode tentar!
}

# ✅ SEGURO: SSH restrito
ingress {
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = ["203.0.113.5/32"]  # Apenas seu IP
}

# ✅ MELHOR AINDA: Usar SSM Session Manager
# (não precisa porta 22 aberta)
```

### 3. Usar descrições em todas as regras

```terraform
# ❌ SEM descrição (você vai esquecer o motivo)
ingress {
  from_port   = 8080
  to_port     = 8080
  protocol    = "tcp"
  cidr_blocks = ["10.0.0.0/24"]
}

# ✅ COM descrição (futuro você agradece)
ingress {
  description = "Prometheus scraping from monitoring subnet"
  from_port   = 8080
  to_port     = 8080
  protocol    = "tcp"
  cidr_blocks = ["10.0.0.0/24"]
}
```

### 4. Agrupar recursos similares no mesmo SG

```terraform
# ✅ BOM: Web servers compartilham SG
resource "aws_instance" "web1" {
  vpc_security_group_ids = [aws_security_group.web.id]
}

resource "aws_instance" "web2" {
  vpc_security_group_ids = [aws_security_group.web.id]
}

# Mudança em 1 SG → afeta todos os web servers
```

### 5. Nomear Security Groups de forma clara

```terraform
# ❌ RUIM: Nome genérico
resource "aws_security_group" "sg1" { ... }

# ✅ BOM: Nome descritivo
resource "aws_security_group" "web_public_http_https" {
  name = "web-public-http-https"
  description = "Public web servers - allows HTTP/HTTPS from Internet"
}
```

### 6. Revisar Security Groups periodicamente

```bash
# Encontrar SGs não utilizados
aws ec2 describe-security-groups \
  --query 'SecurityGroups[?length(IpPermissions)==`0`]'

# Encontrar portas perigosas abertas
aws ec2 describe-security-groups \
  --query 'SecurityGroups[?IpPermissions[?FromPort==`22` && IpRanges[?CidrIp==`0.0.0.0/0`]]]'
```

### 7. Usar tags para organização

```terraform
resource "aws_security_group" "web" {
  # ...
  
  tags = {
    Name        = "web-servers"
    Environment = "production"
    Project     = "ecommerce"
    ManagedBy   = "terraform"
    Owner       = "team-platform"
    CostCenter  = "engineering"
  }
}
```

### 8. Documentar regras complexas

```terraform
# Regra complexa? Adicione comentário!
resource "aws_security_group" "app" {
  # ...
  
  # IMPORTANTE: Porta 9200 é para Elasticsearch
  # Referência: https://wiki.company.com/elasticsearch-setup
  # Contato: team-data@company.com
  ingress {
    description = "Elasticsearch from analytics team (JIRA-1234)"
    from_port   = 9200
    to_port     = 9200
    protocol    = "tcp"
    cidr_blocks = ["10.20.0.0/24"]
  }
}
```

### 9. Evitar ciclos de dependência

```terraform
# ❌ CICLO: SG-A referencia SG-B e vice-versa
resource "aws_security_group" "a" {
  ingress {
    security_groups = [aws_security_group.b.id]
  }
}

resource "aws_security_group" "b" {
  ingress {
    security_groups = [aws_security_group.a.id]  # ← Ciclo!
  }
}

# ✅ SOLUÇÃO: Usar aws_security_group_rule separado
resource "aws_security_group_rule" "a_to_b" {
  type                     = "ingress"
  security_group_id        = aws_security_group.b.id
  source_security_group_id = aws_security_group.a.id
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
}
```

### 10. Monitorar mudanças com alertas

```terraform
# EventBridge rule para alertar mudanças em SG
resource "aws_cloudwatch_event_rule" "security_group_changes" {
  name        = "security-group-changes"
  description = "Alerta quando Security Groups são modificados"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = [
        "AuthorizeSecurityGroupIngress",
        "RevokeSecurityGroupIngress",
        "AuthorizeSecurityGroupEgress",
        "RevokeSecurityGroupEgress",
        "CreateSecurityGroup",
        "DeleteSecurityGroup"
      ]
    }
  })
}

# Enviar para SNS (email, Slack, etc.)
resource "aws_cloudwatch_event_target" "sns" {
  rule      = aws_cloudwatch_event_rule.security_group_changes.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.alerts.arn
}
```

---

## Comparação: Security Group vs Network ACL

| **Característica** | **Security Group** | **Network ACL** |
|--------------------|-------------------|-----------------|
| **Nível** | Instância (EC2, ENI) | Subnet |
| **Stateful** | ✅ Sim (lembra conexões) | ❌ Não (precisa regras bidirecionais) |
| **Regras** | Apenas ALLOW | ALLOW e DENY |
| **Avaliação** | Todas as regras | Ordem numérica (menor primeiro) |
| **Aplicação** | Escolhe quais instâncias | Todas as instâncias da subnet |
| **Padrão** | Bloqueia entrada, permite saída | Permite tudo |
| **Uso comum** | 99% dos casos | Bloqueios específicos de IP |

---

## Limites (Quotas)

```
┌────────────────────────────────────────────────────┐
│ Limites padrão por região:                        │
├────────────────────────────────────────────────────┤
│ Security Groups por VPC:           2.500          │
│ Regras por Security Group:         60 (in + out)  │
│ Security Groups por interface:     5 (até 16)     │
│ Tamanho descrição:                 255 caracteres │
└────────────────────────────────────────────────────┘

Limites podem ser aumentados via AWS Support.
```

---

## Recursos adicionais

- [Documentação oficial AWS](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_SecurityGroups.html)
- [AWS Security Best Practices](https://aws.amazon.com/architecture/security-identity-compliance/)
- [Terraform AWS Provider - Security Group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group)
- [AWS Security Hub](https://aws.amazon.com/security-hub/)

---

**Última atualização:** 2026-02-03  
**Versão:** 1.0
