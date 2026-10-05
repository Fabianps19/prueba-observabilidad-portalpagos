#!/usr/bin/env bash
# Reto 3 - Tablero: Azure Workbook con una seccion para la Direccion y otra para el NOC.
set -euo pipefail
cd "$(dirname "$0")"
LAWID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query id -o tsv)
WBID=$(python3 -c "import uuid;print(uuid.uuid5(uuid.NAMESPACE_URL,'$LAWID/portalpagos'))")
python3 tablero/workbook.py "$LAWID" > /tmp/wb.json
python3 - "$LOC" "$LAWID" > /tmp/wb_body.json <<'PY'
import json, sys
print(json.dumps({"location": sys.argv[1], "kind": "shared", "properties": {
  "displayName": "PortalPagos - Direccion y NOC", "category": "workbook", "sourceId": sys.argv[2],
  "serializedData": open('/tmp/wb.json').read()}, "tags": {"proyecto": "prueba-skandia"}}))
PY
az rest --method put --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG/providers/Microsoft.Insights/workbooks/$WBID?api-version=2022-04-01" \
  --body @/tmp/wb_body.json --query "{tablero:properties.displayName,id:name}" -o table
