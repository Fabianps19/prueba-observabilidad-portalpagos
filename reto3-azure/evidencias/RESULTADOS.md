# Evidencia Reto 3 (5-oct-2026, tiempos UTC; Bogota = UTC-5)

## Prueba 1: Auto-Heal (FUGA_KB=64, sin runbook)

Transcrito de las salidas de Cloud Shell (capturas en esta carpeta).

### Hitos
- T0 despliegue simulado v2.3.1 (FUGA_KB=64): 2026-10-05T15:45:00Z
- T1 rollback simulado a v2.3.0 (FUGA_KB=0): 2026-10-05T16:05:37Z

### Carga (cliente, carga.sh)
- 25.585 peticiones entre 15:45:58Z y 16:10:57Z; 142 HTTP 500 y 4 sin conexion (000)
- Ciclo 1: 30 x 500 entre 15:54:52Z y 15:54:54Z; 4 x 000 a las 15:54:54Z
- Ciclo 2: 112 x 500 entre 16:04:25Z y 16:04:34Z
- Sin errores despues de 16:04:34Z

### Log Analytics (evidencias.sh)
| minuto (UTC) | total | err | disponibilidad |
|---|---|---|---|
| 15:55 | 454 | 30 | 93,39 % |
| 16:05 | 1256 | 112 | 91,08 % |
| total prueba | 23.217 | 142 | 99,388 % |

(Los logs suman menos peticiones que el cliente porque la consulta corrio antes de que se ingirieran los ultimos minutos.)

Memoria MemoryWorkingSet, maximo por 2 min (MB): 15:44 133 · 15:46 133 · 15:48 242 · 15:50 373 · 15:52 513 · 15:54 549 · 15:56 121 · 15:58 239 · 16:00 382 · 16:02 442

### Alertas disparadas
| alerta | disparo (UTC) | resuelta |
|---|---|---|
| A-memoria-temprana | 15:52:57Z | - |
| B-errores-5xx | 15:59:04Z | 16:05:14Z |
| B-errores-5xx | 16:08:16Z | - |
| C-health-check | no disparo | |
| D-tasa-error-kql | no disparo | |

### Auto-Heal (az webapp config show)
autoHeal=true; regla: status 500, count 30, timeInterval 00:01:00; accion: Recycle

## Prueba 2: alerta E -> runbook con salvaguardas

Pendiente de ejecutar (ver README, seccion 0).
