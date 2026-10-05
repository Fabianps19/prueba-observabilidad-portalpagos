#!/usr/bin/env bash
# Reto 3 - Auto-remediacion disparada por alerta: Automation (identidad administrada) + runbook + webhook.
# Requiere RG, LOC, LAW, APP, EMAIL. El URI del webhook es un secreto: solo vive en Azure (Action Group), nunca se imprime.
set -euo pipefail
cd "$(dirname "$0")"
AA=${AA:-aa-portalpagos}; RB=Remediar-PortalPagos
SUB=$(az account show --query id -o tsv)
BASE="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Automation/automationAccounts/$AA"
V='api-version=2023-11-01'
APPID=$(az webapp show -g "$RG" -n "$APP" --query id -o tsv)
LAWID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query id -o tsv)

echo "1) Cuenta de Automation con identidad administrada"
az rest --method put --url "$BASE?$V" --body "{\"location\":\"$LOC\",\"identity\":{\"type\":\"SystemAssigned\"},\"properties\":{\"sku\":{\"name\":\"Basic\"}}}" -o none
AAPID=$(az rest --method get --url "$BASE?$V" --query identity.principalId -o tsv)

echo "2) Permiso minimo: Website Contributor solo sobre la app"
for i in 1 2 3 4 5 6; do
  az role assignment create --assignee-object-id "$AAPID" --assignee-principal-type ServicePrincipal \
    --role "Website Contributor" --scope "$APPID" -o none 2>/dev/null && break; sleep 20; done

echo "3) Variables del runbook (configuracion, sin secretos)"
var() { az rest --method put --url "$BASE/variables/$1?$V" --body "{\"properties\":{\"value\":$(python3 -c 'import json,sys;print(json.dumps(json.dumps(sys.argv[1])))' "$2"),\"isEncrypted\":false}}" -o none; }
var AppPermitida "$APPID"
var MaxReiniciosHora "2"
var ModoRemediacion "${MODO:-automatico}"
var ReiniciosPortal "h:"

echo "4) Runbook (Windows PowerShell 5.1, solo REST con la identidad administrada)"
az rest --method put --url "$BASE/runbooks/$RB?$V" --body "{\"location\":\"$LOC\",\"properties\":{\"runbookType\":\"PowerShell\",\"logProgress\":false,\"logVerbose\":false,\"description\":\"Remedia PortalPagos con salvaguardas\"}}" -o none
az rest --method put --url "$BASE/runbooks/$RB/draft/content?$V" --headers "Content-Type=text/powershell" --body @remediacion/Remediar-PortalPagos.ps1 -o none
az rest --method post --url "$BASE/runbooks/$RB/publish?$V" -o none

echo "5) Webhook del runbook y Action Group de remediacion"
if az rest --method get --url "$BASE/webhooks/wh-remediacion?api-version=2015-10-31" -o none 2>/dev/null; then
  echo "   El webhook y el Action Group ya existen: se reutilizan (el URI no se puede leer ni cambiar)"
else
  URI=$(az rest --method post --url "$BASE/webhooks/generateUri?api-version=2015-10-31" | tr -d '"')
  EXP=$(date -u -d '+7 days' +%FT%TZ)
  az rest --method put --url "$BASE/webhooks/wh-remediacion?api-version=2015-10-31" \
    --body "{\"name\":\"wh-remediacion\",\"properties\":{\"isEnabled\":true,\"uri\":\"$URI\",\"expiryTime\":\"$EXP\",\"runbook\":{\"name\":\"$RB\"}}}" -o none
  az monitor action-group create -g "$RG" -n ag-remediacion --short-name Remediar \
    --action webhook runbook-remediacion "$URI" usecommonalertschema -o none
  unset URI
fi
AGR=$(az monitor action-group show -g "$RG" -n ag-remediacion --query id -o tsv)
AGID=$(az monitor action-group show -g "$RG" -n ag-portalpagos --query id -o tsv)

echo "6) Trazabilidad: salidas de los jobs a Log Analytics"
AAID=$(az rest --method get --url "$BASE?$V" --query id -o tsv)
az monitor diagnostic-settings create -n diag-automation --resource "$AAID" --workspace "$LAWID" \
  --logs '[{"category":"JobLogs","enabled":true},{"category":"JobStreams","enabled":true}]' -o none

echo "7) Alerta E (dispara el runbook) y alerta F (escalamiento a una persona)"
QE='AppServiceHTTPLogs | where CsUriStem has "pagos" | summarize errores = countif(ScStatus >= 500) | where errores >= 20'
az monitor scheduled-query create -g "$RG" -n "E-remediacion-5xx" --scopes "$LAWID" \
  --condition "count 'Q1' > 0" --condition-query Q1="$QE" --window-size 5m --evaluation-frequency 1m \
  --auto-mitigate false --severity 1 --action-groups "$AGR" \
  --description "Dispara el runbook de remediacion: >= 20 respuestas 5xx en 5 min (sin estado: reevalua cada minuto)" -o none
QF='AzureDiagnostics | where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobStreams" | where ResultDescription has "ESCALAR"'
az monitor scheduled-query create -g "$RG" -n "F-escalamiento" --scopes "$LAWID" \
  --condition "count 'Q1' > 0" --condition-query Q1="$QF" --window-size 15m --evaluation-frequency 5m \
  --severity 1 --action-groups "$AGID" \
  --description "El runbook no pudo o no debio remediar: requiere una persona" -o none
az monitor scheduled-query list -g "$RG" --query "[].{alerta:name,sev:severity,cada:evaluationFrequency}" -o table
echo "Listo. Modo de remediacion: ${MODO:-automatico} (en produccion se empieza en 'sugerir')."
