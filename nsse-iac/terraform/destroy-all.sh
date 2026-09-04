#!/bin/bash

set -e

echo "================================"
echo "🔥 Destruindo toda infraestrutura"
echo "================================"
echo ""

# Obter o diretório raiz do script
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Destruir server
if [ -d "$ROOT_DIR/server" ]; then
  echo "📦 [1/4] Destruindo módulo SERVER..."
  cd "$ROOT_DIR/server"
  terraform destroy -auto-approve
  echo "✅ Server destruído"
  echo ""
fi

# 2. Destruir networking
if [ -d "$ROOT_DIR/networking" ]; then
  echo "🌐 [2/4] Destruindo módulo NETWORKING..."
  cd "$ROOT_DIR/networking"
  terraform destroy -auto-approve
  echo "✅ Networking destruído"
  echo ""
fi

# 3. Destruir backend
if [ -d "$ROOT_DIR/backend" ]; then
  echo "🗄️  [3/4] Destruindo módulo BACKEND..."
  cd "$ROOT_DIR/backend"
  terraform destroy -auto-approve
  echo "✅ Backend destruído"
  echo ""
fi

# 4. Destruir serverless
if [ -d "$ROOT_DIR/serverless" ]; then
  echo "📦 [4/4] Destruindo módulo SERVERLESS..."
  cd "$ROOT_DIR/serverless"
  terraform destroy -auto-approve
  echo "✅ Serverless destruído"
  echo ""
fi

echo "================================"
echo "🎉 Toda infraestrutura foi destruída!"
echo "================================"
