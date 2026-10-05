#!/usr/bin/env bash
# Reto 3 - Despliegue completo y repetible del laboratorio (Azure Cloud Shell, bash).
# Uso: EMAIL=correo@dominio ./desplegar.sh      (opcionales: RG, LOC, LAW)
# Crea: grupo de recursos, Log Analytics, App Service Windows B1 con la app simulada,
# monitoreo y alertas (monitoreo.sh), auto-remediacion con runbook (remediacion.sh) y tablero (tablero.sh).
# No contiene secretos. Al terminar la prueba: az group delete -n "$RG" --yes --no-wait
set -euo pipefail
cd "$(dirname "$0")"
: "${EMAIL:?Defina EMAIL (correo que recibe las alertas)}"
RG=${RG:-rg-prueba-portalpagos}; LOC=${LOC:-centralus}; LAW=${LAW:-law-portalpagos-cus}; PLAN=${PLAN:-plan-portalpagos-win}

for p in Microsoft.Web Microsoft.OperationalInsights Microsoft.Insights Microsoft.Automation Microsoft.AlertsManagement; do
  az provider register -n "$p" -o none; done
az group create -n "$RG" -l "$LOC" --tags proyecto=prueba-skandia -o none
az monitor log-analytics workspace show -g "$RG" -n "$LAW" -o none 2>/dev/null || \
  az monitor log-analytics workspace create -g "$RG" -n "$LAW" -l "$LOC" --retention-time 30 -o none
az appservice plan show -g "$RG" -n "$PLAN" -o none 2>/dev/null || \
  az appservice plan create -g "$RG" -n "$PLAN" -l "$LOC" --sku B1 --is-linux false -o none
APP=${APP:-$(az webapp list -g "$RG" --query "[0].name" -o tsv)}
APP=${APP:-portalpagos-$RANDOM}
az webapp show -g "$RG" -n "$APP" -o none 2>/dev/null || \
  az webapp create -g "$RG" -p "$PLAN" -n "$APP" --runtime "ASPNET:V4.8" --https-only true -o none
az webapp config appsettings set -g "$RG" -n "$APP" --settings FUGA_KB=0 LIMITE_MB=600 -o none
az webapp config set -g "$RG" -n "$APP" --always-on true --generic-configurations '{"healthCheckPath":"/salud.aspx"}' -o none
az webapp log config -g "$RG" -n "$APP" --web-server-logging filesystem --detailed-error-messages true \
  --application-logging filesystem --level error -o none
(cd app && rm -f ../app.zip && zip -q ../app.zip pagos.aspx salud.aspx default.htm)
az webapp deploy -g "$RG" -n "$APP" --src-path app.zip --type zip -o none
printf 'export RG=%s LOC=%s LAW=%s APP=%s EMAIL=%s\n' "$RG" "$LOC" "$LAW" "$APP" "$EMAIL" > entorno.sh
export RG LOC LAW APP EMAIL
echo "App: https://$APP.azurewebsites.net  (variables en entorno.sh)"
./monitoreo.sh
./remediacion.sh
./tablero.sh
