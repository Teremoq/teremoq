#!/usr/bin/env bash
set -euo pipefail

OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
MODEL="${OLLAMA_MODEL:-llama3.2}"

echo "Esperando a Ollama en ${OLLAMA_HOST}..."
until curl -sf "${OLLAMA_HOST}/api/tags" >/dev/null; do
  sleep 2
done

echo "Descargando modelo ${MODEL} (idempotente si ya existe)..."
curl -sfN "${OLLAMA_HOST}/api/pull" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${MODEL}\"}"

echo "Modelo ${MODEL} listo."
