#!/bin/bash

set -e

echo "================================"
echo "🚀 Aplicando toda infraestrutura"
echo "================================"
echo ""

# Obter o diretório raiz do script
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Aplicar backend
if [ -d "$ROOT_DIR/backend" ]; then
  echo "🗄️  [1/4] Aplicando módulo BACKEND..."
  cd "$ROOT_DIR/backend"
  terraform init -reconfigure
  terraform apply -auto-approve
  echo "✅ Backend aplicado"
  echo ""
fi

# 2. Aplicar networking
if [ -d "$ROOT_DIR/networking" ]; then
  echo "🌐 [2/4] Aplicando módulo NETWORKING..."
  cd "$ROOT_DIR/networking"
  terraform init -reconfigure
  terraform apply -auto-approve
  echo "✅ Networking aplicado"
  echo ""
fi

# 3. Aplicar server
if [ -d "$ROOT_DIR/server" ]; then
  echo "📦 [3/4] Aplicando módulo SERVER..."
  cd "$ROOT_DIR/server"
  terraform init -reconfigure
  terraform apply -auto-approve
  echo "✅ Server aplicado"
  echo ""
fi

# 4. Aplicar serverless
if [ -d "$ROOT_DIR/serverless" ]; then
  echo "📦 [4/4] Aplicando módulo SERVERLESS..."
  cd "$ROOT_DIR/serverless"
  terraform init -reconfigure
  terraform apply -auto-approve
  echo "✅ Serverless aplicado"
  echo ""
fi

echo "================================"
echo "🎉 Toda infraestrutura foi criada!"
echo "================================"
