#!/usr/bin/env bash
# Reto 3 - Provoca la falla: "despliega" la version con fuga y genera trafico de pagos.
# Uso: ./simular.sh inicio [FUGA_KB]   |   ./simular.sh rollback   (requiere variables de entorno.sh)
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-}" in
  inicio)
    K=${2:-128}
    echo "T0 despliegue simulado con fuga (FUGA_KB=$K): $(date -u +%FT%TZ)" | tee -a hitos.txt
    az webapp config appsettings set -g "$RG" -n "$APP" --settings FUGA_KB="$K" -o none
    sleep 40
    DURACION=${DURACION:-3000} PARALELO=${PARALELO:-5} nohup ./carga.sh > carga.log 2>&1 &
    echo "Carga en segundo plano (PID $!). Ver avance: ./carga.sh resumen \$(ls -t carga_*.csv | head -1)";;
  rollback)
    echo "T1 rollback simulado (FUGA_KB=0): $(date -u +%FT%TZ)" | tee -a hitos.txt
    az webapp config appsettings set -g "$RG" -n "$APP" --settings FUGA_KB=0 -o none;;
  *) echo "Uso: $0 inicio [FUGA_KB] | rollback"; exit 1;;
esac
