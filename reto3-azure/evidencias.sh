#!/usr/bin/env bash
# Reto 3 - Consultas KQL de evidencia sobre los datos del laboratorio (UTC; Bogota = UTC-5).
# Responden las preguntas del Reto 1: disponibilidad real, errores 5xx, latencia p95 y eventos del "pool".
set -uo pipefail
H=${HORAS:-3}
WS=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query customerId -o tsv)
q() { echo; echo "### $1"; az monitor log-analytics query -w "$WS" --analytics-query "$2" -o table 2>/dev/null | grep -v -E '^TableName|^-+[ -]*$' | sed 's/^PrimaryResult *//'; }
P="AppServiceHTTPLogs | where TimeGenerated > ago(${H}h) and CsUriStem has 'pagos'"
q "1. Disponibilidad real total" "$P | summarize total=count(), err=countif(ScStatus>=500) | extend disponibilidad=round(100.0*(total-err)/total,3) | project total, err, disponibilidad"
q "2. Minutos con errores 5xx (disponibilidad por minuto)" "$P | summarize total=count(), err=countif(ScStatus>=500) by minuto=bin(TimeGenerated,1m) | where err>0 | extend disp=round(100.0*(total-err)/total,1) | project minuto, total, err, disp | order by minuto asc"
q "3. Errores 5xx por endpoint y codigo" "$P | where ScStatus>=500 | summarize errores=count() by CsUriStem, ScStatus | order by errores desc"
q "4. Latencia p95 (ms) cada 5 min" "$P | summarize p95_ms=round(percentile(TimeTaken,95),0), peticiones=count() by t=bin(TimeGenerated,5m) | project t, p95_ms, peticiones | order by t asc"
q "5. Memoria del proceso (MB, max cada 2 min)" "AzureMetrics | where TimeGenerated > ago(${H}h) and MetricName == 'MemoryWorkingSet' | summarize mb=round(max(Maximum)/1048576,0) by t=bin(TimeGenerated,2m) | project t, mb | order by t asc"
echo; echo "### 6. Eventos del 'pool': reinicios y cambios de la app (registro de actividad de Azure)"
az monitor activity-log list -g "$RG" --offset ${H}h --query "[?contains(operationName.value,'sites/restart') || contains(operationName.value,'sites/config/write')].[eventTimestamp, operationName.value, status.value, caller]" -o tsv 2>/dev/null | sort | uniq | sed 's#Microsoft.Web/sites/##'
q "7. Decisiones del runbook de auto-remediacion" "AzureDiagnostics | where TimeGenerated > ago(${H}h) and Category == 'JobStreams' and ResultDescription has 'REMEDIACION' | extend d=parse_json(substring(ResultDescription, indexof(ResultDescription, '{'))) | project hora=todatetime(d.ts), decision=tostring(d.decision), detalle=substring(tostring(d.detalle),0,90) | order by hora asc"
echo; echo "### 8. Alertas disparadas"
az graph query -q "alertsmanagementresources | where properties.essentials.targetResourceGroup =~ '$RG' or properties.essentials.alertRule has 'remediacion' or properties.essentials.alertRule has 'escalamiento' | project alerta=tostring(properties.essentials.alertRule), estado=tostring(properties.essentials.monitorCondition), inicio=tostring(properties.essentials.startDateTime) | order by inicio asc" --first 100 --query "data[].[alerta,estado,inicio]" -o tsv 2>/dev/null | sed 's#^[^\t]*/##'
