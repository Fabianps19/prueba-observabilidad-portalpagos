# Prueba técnica – Especialista en Observabilidad y Automatización

Caso ficticio **PortalPagos** (Andina Financiera): diagnóstico del incidente del viernes 18 de septiembre de 2026, modernización del mantenimiento, diseño de observabilidad y auto-remediación, triage de incidentes con IA y propuesta para los primeros 90 días.

## Estructura

| Carpeta | Contenido |
|---|---|
| `reto1-diagnostico/` | Código reproducible del análisis de logs y post-mortem |
| `reto2-powershell/` | Problemas del .BAT, script PowerShell de reemplazo y pruebas Pester |
| `reto3-azure/` | Diseño de observabilidad, consultas KQL, alertas y auto-remediación |
| `reto4-triage-ia/` | Componente de triage de incidentes con IA |
| `reto5-propuesta/` | Propuesta para los primeros 90 días |
| `evidencias/` | Capturas y salidas de ejecución |
| `IA_BITACORA.md` | Bitácora de uso de IA |

## Estado de cada reto

| Reto | Entregado | Cómo reproducir |
|---|---|---|
| 1. Diagnóstico | Código reproducible, `POSTMORTEM.md`/`.pdf` (3 págs.), análisis avanzado, presentación HTML, guía de validación en Power BI | `cd reto1-diagnostico` → `python -m pip install -r requirements.txt` → `python analizar.py --kit ../kit --salida resultados` → `python -m pytest -q tests` |
| 2. PowerShell | `PROBLEMAS.md`, script de reemplazo, 15 pruebas Pester, demo con evidencia | `cd reto2-powershell` → `.\demo-local.ps1` → `Invoke-Pester -Path .\tests` |
| 3. Azure | **Diseño** con consultas KQL, reglas de alerta validadas con datos del kit y runbook de auto-remediación con salvaguardas. **No desplegado por tiempo** (ver su README) | Revisar `reto3-azure/README.md` |
| 4. Triage con IA | Componente con esquema JSON, catálogo cerrado de runbooks, validación de citas, respaldo sin IA y 6 pruebas | `cd reto4-triage-ia` → `python -m pip install -r requirements.txt` → `python -m pytest -q tests` → `python ejecutar_casos.py` |
| 5. Propuesta 90 días | `PROPUESTA_90_DIAS.md`/`.pdf` (2 págs.) | — |

## Cómo reproducir

> Requisitos: Python 3.12, PowerShell 5.1 o 7 (Pester 5+), Git.

1. Clonar este repositorio.
2. Descomprimir `kit_prueba_portalpagos.zip` dentro de una carpeta `kit/` en la raíz del repositorio.
   El kit **no se versiona** (está en `.gitignore`) porque es material de entrada y el script original contiene una credencial.
3. Seguir la columna "Cómo reproducir" de la tabla anterior. Cada carpeta tiene su propio README.

## Prioridades y decisiones

La prueba indica que es mejor entregar menos cosas bien hechas y probadas. Con el tiempo disponible prioricé: 1) el diagnóstico con evidencia, 2) el script de mantenimiento con pruebas, 3) el triage con IA, y entregué el Reto 3 como diseño detallado en vez de un montaje a medias. Si tuviera más tiempo, en este orden: desplegar el Reto 3 con Bicep, medir detección y recuperación reales con un video, y conectar el triage (Reto 4) a la alerta real.

## Supuestos

_Se documentan a medida que se toman decisiones sin información completa._

1. Los logs W3C de IIS están en UTC (comportamiento por defecto de IIS); eventos de Windows y contadores de Perfmon están en hora local de Bogotá (UTC-05:00). Todo el análisis se presenta en hora de Colombia.
2. El archivo `u_ex260916 - copia.log` es un duplicado exacto (mismo hash) de `u_ex260916.log` y se excluye del análisis.
3. **Disponibilidad** = peticiones de clientes sin error de servidor. Se excluyen `/health` (sonda del NOC) y los 404 (escaneos automáticos). Los 503 que solo registra HTTP.sys cuentan como fallo.
4. Se considera mala experiencia una respuesta de más de **3 segundos** (umbral elegido para una operación de pago; es un parámetro del script).
5. "Día normal" para comparar = promedio de lunes a jueves de la misma semana (antes del cierre de plazo).
6. La IP 10.20.4.4 que aparece en `c-ip` desde el 16-sep 22:12 se interpreta como un proxy o balanceador; la IP real del cliente se toma de `X-Forwarded-For`.
7. El consumo de disco posterior al despliegue se atribuye a los logs de aplicación en nivel Debug (el evento del despliegue lo menciona); no hay inventario de archivos del disco para confirmarlo.
8. La caída de ~7,6 GB de disco entre 14:15 y 14:45 del 18-sep se atribuye a los volcados de memoria de las 5 caídas (eventos 1001 los referencian); no se tiene su tamaño exacto.

9. Reto 2: la tarea programada correrá con una cuenta de servicio administrada (gMSA) con permiso de escritura en el share de auditoría; por eso el script no maneja credenciales.
10. Reto 4: los logs se tratan como datos no confiables; los datos personales (IPs, números largos) se enmascaran antes de enviarse al modelo.

## Seguridad

- No se versionan datos crudos, secretos, cadenas de conexión ni tokens.
- La credencial presente en `scripts/mantenimiento_diario.bat` del kit no se reproduce en este repositorio.
- La IA nunca ejecuta acciones: el triage (Reto 4) solo sugiere desde un catálogo cerrado y requiere aprobación humana.
