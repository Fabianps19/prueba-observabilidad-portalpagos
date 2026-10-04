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

## Cómo reproducir

> Requisitos: Python 3.12, PowerShell 5.1 o 7, Git.

1. Clonar este repositorio.
2. Descomprimir `kit_prueba_portalpagos.zip` dentro de una carpeta `kit/` en la raíz del repositorio.
   El kit **no se versiona** (está en `.gitignore`) porque es material de entrada y el script original contiene una credencial.
3. Instrucciones por reto: ver el README de cada carpeta.

## Supuestos

_Se documentan a medida que se toman decisiones sin información completa._

1. Los logs W3C de IIS están en UTC (comportamiento por defecto de IIS); eventos de Windows y contadores de Perfmon están en hora local de Bogotá (UTC-05:00). Todo el análisis se presenta en hora de Colombia.
2. El archivo `u_ex260916 - copia.log` es un duplicado exacto (mismo hash) de `u_ex260916.log` y se excluye del análisis.

## Seguridad

- No se versionan datos crudos, secretos, cadenas de conexión ni tokens.
- La credencial presente en `scripts/mantenimiento_diario.bat` del kit no se reproduce en este repositorio.
