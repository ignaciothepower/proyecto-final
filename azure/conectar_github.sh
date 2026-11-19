#!/usr/bin/env bash
# Da permiso a GitHub Actions para desplegar en tu Azure SIN guardar ninguna contrasena (OIDC).
#
# Crea una "identidad" para el workflow cd.yml y le dice a Azure: "fiate de los tokens que firme GitHub
# para la rama main de ESTE repositorio". Esa identidad solo puede tocar el grupo de recursos del proyecto.
# Se ejecuta UNA vez, despues de azure/desplegar.sh.
# Uso:   REPO=tu-usuario/proyecto-final bash azure/conectar_github.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1  # Git Bash en Windows: que no convierta "/subscriptions/..." en una ruta de disco

REPO=${REPO:?Pon tu repositorio: export REPO=tu-usuario/proyecto-final}
RG=${RG:-rg-tienda-final}
NOMBRE=${NOMBRE:-github-cd-proyecto-final}

SUB=$(az account show --query id -o tsv)
TENANT=$(az account show --query tenantId -o tsv)

echo "== 1. La identidad del workflow (app registration + service principal)"
APP_ID=$(az ad app list --display-name "$NOMBRE" --query "[0].appId" -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$NOMBRE" --query appId -o tsv)
fi
az ad sp show --id "$APP_ID" -o none 2>/dev/null || az ad sp create --id "$APP_ID" -o none

echo "== 2. Confianza: solo los tokens de GitHub para la rama main de $REPO"
CRED=$(az ad app federated-credential list --id "$APP_ID" --query "[?name=='rama-main'] | length(@)" -o tsv)
if [ "$CRED" = "0" ]; then
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"rama-main\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:$REPO:ref:refs/heads/main\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" -o none
fi

echo "== 3. Permiso minimo: Contributor SOLO sobre el grupo $RG (nada mas de tu cuenta)"
az role assignment create --assignee "$APP_ID" --role Contributor \
  --scope "/subscriptions/$SUB/resourceGroups/$RG" -o none

echo "== 4. Copia estos tres valores en GitHub: Settings > Secrets and variables > Actions > New repository secret"
echo "AZURE_CLIENT_ID       = $APP_ID"
echo "AZURE_TENANT_ID       = $TENANT"
echo "AZURE_SUBSCRIPTION_ID = $SUB"
echo "(No son contrasenas: sin la confianza del paso 2 no sirven de nada. Aun asi, van como Secrets.)"
