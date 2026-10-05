#!/usr/bin/env bash
# Genera trafico de pagos contra PortalPagos simulado y registra cada respuesta (UTC) en un CSV.
# Uso: DURACION=900 PARALELO=5 ./carga.sh   -> carga_HHMM.csv ; resumen con ./carga.sh resumen archivo.csv
set -uo pipefail
if [ "${1:-}" = "resumen" ]; then
  f=$2
  awk -F, '{n++; if($2>=500){e++; if(!p)p=$1; u=$1; enf=1} else if(enf && $2==200 && !r){r=$1}} END{
    printf "peticiones=%d errores_5xx=%d (%.1f%%)\nprimer_5xx=%s\nultimo_5xx=%s\nprimera_recuperacion_200=%s\n",n,e,100*e/n,p,u,r}' "$f"
  awk -F, '{m=substr($1,1,16); t[m]++; if($2>=500)x[m]++} END{for(k in t) printf "%s total=%d 5xx=%d\n",k,t[k],x[k]}' "$f" | sort
  exit 0
fi
URL="https://$APP.azurewebsites.net/pagos.aspx"
out="carga_$(date -u +%H%M).csv"; fin=$((SECONDS+${DURACION:-900})); par=${PARALELO:-5}
echo "Registrando en $out (Ctrl+C para detener)"
while [ $SECONDS -lt $fin ]; do
  for i in $(seq 1 "$par"); do
    op=$([ $((i%2)) -eq 0 ] && echo confirmar || echo iniciar)
    curl -s -o /dev/null -m 20 -w "$(date -u +%FT%TZ),%{http_code},%{time_total},$op\n" "$URL?op=$op" &
  done; wait
done >> "$out"
echo "Fin. Resumen:"; "$0" resumen "$out"
