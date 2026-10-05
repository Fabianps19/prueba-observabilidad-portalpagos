#!/usr/bin/env bash
# Reto 3 - Monitoreo y auto-remediacion de PortalPagos (simulado) en Azure App Service.
# Requiere: RG, APP, LAW, LOC y EMAIL definidos en el entorno. No contiene secretos.
set -euo pipefail
az config set extension.use_dynamic_install=yes_without_prompt -o none 2>/dev/null
APPID=$(az webapp show -g "$RG" -n "$APP" --query id -o tsv)
LAWID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query id -o tsv)

echo "1) Diagnostic settings -> Log Analytics (logs HTTP de IIS, plataforma, app + metricas)"
CATS=$(az monitor diagnostic-settings categories list --resource "$APPID" --query "value[?categoryType=='Logs'].name" -o tsv | grep -E 'AppServiceHTTPLogs|AppServicePlatformLogs|AppServiceAppLogs' || true)
LOGS=$(for c in $CATS; do printf '{"category":"%s","enabled":true},' "$c"; done); LOGS="[${LOGS%,}]"
az monitor diagnostic-settings create -n diag-portalpagos --resource "$APPID" --workspace "$LAWID" \
  --logs "$LOGS" --metrics '[{"category":"AllMetrics","enabled":true}]' -o none
echo "   categorias: $CATS"

echo "2) Grupo de acciones (correo)"
AGID=$(az monitor action-group create -g "$RG" -n ag-portalpagos --short-name PortalPagos \
  --action email correo-oncall "$EMAIL" --query id -o tsv)

echo "3) Alertas de metricas (evaluacion cada minuto)"
az monitor metrics alert create -g "$RG" -n "A-memoria-temprana" --scopes "$APPID" \
  --condition "max MemoryWorkingSet > 262144000" --window-size 5m --evaluation-frequency 1m \
  --severity 2 --action "$AGID" --description "Alerta temprana: memoria del proceso > 250 MB (fuga en SesionPagoCache)" -o none
az monitor metrics alert create -g "$RG" -n "B-errores-5xx" --scopes "$APPID" \
  --condition "total Http5xx > 20" --window-size 5m --evaluation-frequency 1m \
  --severity 1 --action "$AGID" --description "Mas de 20 respuestas 5xx en 5 minutos" -o none
az monitor metrics alert create -g "$RG" -n "C-health-check" --scopes "$APPID" \
  --condition "avg HealthCheckStatus < 100" --window-size 5m --evaluation-frequency 1m \
  --severity 1 --action "$AGID" --description "Health check /salud.aspx no responde 200 (lo que el NOC no veia)" -o none

echo "4) Alerta de logs (KQL sobre logs W3C de IIS): tasa de error > 5% con volumen minimo"
Q='AppServiceHTTPLogs | summarize total=count(), errores=countif(ScStatus >= 500) | extend pct=round(100.0*errores/total,1) | where total >= 50 and pct > 5'
az monitor scheduled-query create -g "$RG" -n "D-tasa-error-kql" --scopes "$LAWID" \
  --condition "count 'Q1' > 0" --condition-query Q1="$Q" \
  --window-size 5m --evaluation-frequency 5m --severity 1 --action-groups "$AGID" \
  --description "Tasa de error HTTP > 5% (logs W3C de IIS)" -o none

echo "5) Auto-Heal (primera linea opcional, AUTOHEAL=true): >30 respuestas 500 en 1 min -> reciclar proceso"
AH=${AUTOHEAL:-false}
az rest --method patch --url "https://management.azure.com${APPID}/config/web?api-version=2023-12-01" \
  --body '{"properties":{"autoHealEnabled":'"$AH"',"autoHealRules":{"triggers":{"statusCodes":[{"status":500,"subStatus":0,"win32Status":0,"count":30,"timeInterval":"00:01:00"}]},"actions":{"actionType":"Recycle","minProcessExecutionTime":"00:01:00"}}}}' -o none
az webapp config show -g "$RG" -n "$APP" --query "{autoHeal:autoHealEnabled,healthCheck:healthCheckPath,alwaysOn:alwaysOn}" -o table
az monitor metrics alert list -g "$RG" --query "[].{alerta:name,sev:severity,activa:enabled}" -o table
echo "Listo."
