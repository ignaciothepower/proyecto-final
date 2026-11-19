#!/usr/bin/env bash
# Sube TODO el proyecto final a Azure: el chatbot (agente + web), su modelo y sus herramientas MCP.
#
#   Navegador --> chatbot-tienda (Container App, HTTPS publico)
#                    |-- Azure OpenAI (el modelo, gpt-4.1-mini)
#                    |-- mcp-tienda (Container App INTERNA: solo la ve el chatbot)
#                    |-- Neon (memoria + RAG)  y  LangFuse (trazas)   <- fuera de Azure, como en local
#
# Requisitos: Azure CLI con la sesion iniciada (az login) y el .env del proyecto relleno
# (DATABASE_URL y claves de LangFuse). No hace falta Docker: las imagenes se construyen en la nube.
# Las dos piezas viven en este repo: agente/ (el chatbot) y mcp/ (las herramientas).
# Uso (desde la raiz del repo):           bash azure/desplegar.sh
# Al terminar el curso:                   bash azure/apagar.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1  # Git Bash en Windows: que no convierta "/subscriptions/..." en una ruta de disco

RG=${RG:-rg-tienda-final}         # grupo de recursos: todo vive aqui y se borra de una vez
LOC=${LOC:-swedencentral}         # region con Azure OpenAI y Container Apps
SUFIJO=$(az account show --query id -o tsv | tr -d '-' | cut -c1-6)  # nombres unicos y estables por cuenta
AO=${AO:-aoai-tienda-$SUFIJO}     # Azure OpenAI
ACR=${ACR:-acrtienda$SUFIJO}      # registro de imagenes Docker
ENTORNO=${ENTORNO:-env-tienda}    # entorno de Container Apps (la "red" compartida por las dos apps)
VERSION=${VERSION:-v$(date +%Y%m%d%H%M)}

# Lee una variable del .env SIN ejecutarlo (las URLs de Postgres llevan & y ? que bash interpretaria)
leer() { grep -E "^$1=" .env | head -1 | cut -d= -f2-; }
DATABASE_URL=$(leer DATABASE_URL); LF_PK=$(leer LANGFUSE_PUBLIC_KEY); LF_SK=$(leer LANGFUSE_SECRET_KEY)
LF_HOST=$(leer LANGFUSE_HOST)
: "${DATABASE_URL:?Falta DATABASE_URL en el .env}" "${LF_PK:?Falta LANGFUSE_PUBLIC_KEY}" "${LF_SK:?Falta LANGFUSE_SECRET_KEY}"

echo "== 1. Extension y proveedores (solo la primera vez tarda)"
az extension add --name containerapp --upgrade --only-show-errors
for p in Microsoft.App Microsoft.OperationalInsights Microsoft.ContainerRegistry Microsoft.CognitiveServices; do
  az provider register --namespace "$p" --wait
done

echo "== 2. Grupo de recursos"
az group create --name "$RG" --location "$LOC" -o none

echo "== 3. Azure OpenAI y el modelo (si ya existen, se reutilizan)"
if ! az cognitiveservices account show -n "$AO" -g "$RG" -o none 2>/dev/null; then
  az cognitiveservices account create -n "$AO" -g "$RG" -l "$LOC" --kind OpenAI --sku S0 --custom-domain "$AO" --yes -o none
fi
if ! az cognitiveservices account deployment show -n "$AO" -g "$RG" --deployment-name gpt-4.1-mini -o none 2>/dev/null; then
  az cognitiveservices account deployment create -n "$AO" -g "$RG" --deployment-name gpt-4.1-mini \
    --model-name gpt-4.1-mini --model-version 2025-04-14 --model-format OpenAI \
    --sku-name GlobalStandard --sku-capacity 50 -o none   # 50.000 tokens/min: tope de gasto natural
fi
AO_ENDPOINT=$(az cognitiveservices account show -n "$AO" -g "$RG" --query properties.endpoint -o tsv)
AO_KEY=$(az cognitiveservices account keys list -n "$AO" -g "$RG" --query key1 -o tsv)

echo "== 4. Registro de imagenes y build en la nube (el del chatbot tarda unos minutos: torch)"
az acr show -n "$ACR" -o none 2>/dev/null || az acr create -n "$ACR" -g "$RG" -l "$LOC" --sku Basic --admin-enabled true -o none
az acr build -r "$ACR" -t "mcp-tienda:$VERSION" mcp --no-logs -o none
az acr build -r "$ACR" -t "chatbot-tienda:$VERSION" agente --no-logs -o none
ACR_USER=$(az acr credential show -n "$ACR" --query username -o tsv)
ACR_PASS=$(az acr credential show -n "$ACR" --query "passwords[0].value" -o tsv)
REG=(--registry-server "$ACR.azurecr.io" --registry-username "$ACR_USER" --registry-password "$ACR_PASS")

echo "== 5. Entorno de Container Apps"
az containerapp env show -n "$ENTORNO" -g "$RG" -o none 2>/dev/null || \
  az containerapp env create -n "$ENTORNO" -g "$RG" -l "$LOC" -o none

echo "== 6. Servidor MCP: ingress INTERNO (desde internet no se ve; el chatbot lo llama por http://mcp-tienda)"
if az containerapp show -n mcp-tienda -g "$RG" -o none 2>/dev/null; then
  az containerapp update -n mcp-tienda -g "$RG" --image "$ACR.azurecr.io/mcp-tienda:$VERSION" -o none
else
  az containerapp create -n mcp-tienda -g "$RG" --environment "$ENTORNO" "${REG[@]}" \
    --image "$ACR.azurecr.io/mcp-tienda:$VERSION" --ingress internal --target-port 8000 \
    --env-vars MCP_TRANSPORT=http PORT=8000 --min-replicas 0 --max-replicas 1 -o none
fi

echo "== 7. Chatbot: ingress EXTERNO (HTTPS publico). Las claves van como secretos, nunca en la imagen"
SECRETOS=(db="$DATABASE_URL" lfpk="$LF_PK" lfsk="$LF_SK" aoaikey="$AO_KEY")
VARIABLES=(DATABASE_URL=secretref:db LANGFUSE_PUBLIC_KEY=secretref:lfpk LANGFUSE_SECRET_KEY=secretref:lfsk
  LANGFUSE_HOST="${LF_HOST:-https://cloud.langfuse.com}" AZURE_OPENAI_API_KEY=secretref:aoaikey
  AZURE_OPENAI_ENDPOINT="$AO_ENDPOINT" AZURE_OPENAI_DEPLOYMENT=gpt-4.1-mini OPENAI_API_VERSION=2024-10-21
  MCP_URL=http://mcp-tienda)
if az containerapp show -n chatbot-tienda -g "$RG" -o none 2>/dev/null; then
  az containerapp secret set -n chatbot-tienda -g "$RG" --secrets "${SECRETOS[@]}" -o none
  az containerapp update -n chatbot-tienda -g "$RG" --image "$ACR.azurecr.io/chatbot-tienda:$VERSION" \
    --set-env-vars "${VARIABLES[@]}" -o none
else
  az containerapp create -n chatbot-tienda -g "$RG" --environment "$ENTORNO" "${REG[@]}" \
    --image "$ACR.azurecr.io/chatbot-tienda:$VERSION" --ingress external --target-port 8000 \
    --cpu 2 --memory 4Gi --min-replicas 0 --max-replicas 1 \
    --secrets "${SECRETOS[@]}" --env-vars "${VARIABLES[@]}" -o none
fi

URL="https://$(az containerapp show -n chatbot-tienda -g "$RG" --query properties.configuration.ingress.fqdn -o tsv)"
echo "== 8. Listo"
echo "Chatbot: $URL"
echo "La primera visita tarda ~1 min (escala a cero: el contenedor se enciende al llegar alguien)."
echo "Comprobacion: curl $URL/salud"
