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

## Prueba 2: alerta E -> runbook con salvaguardas (FUGA_KB=128, Auto-Heal apagado)

Fuente: salidas de los jobs del runbook (lineas REMEDIACION) y CSV de la carga, leidos en Cloud Shell. Capturas 07, 08 y 09.

### Corrida A (T0 20:50:49Z, runbook v1)
| Hora (UTC) | Hecho |
|---|---|
| 20:56 | Primeras respuestas 500 (la app queda caida hasta que alguien reinicie) |
| 20:58:50 | Alerta E dispara el runbook: ACTUA, health=503, reinicio (intento 1 de 2) |
| 20:59:43 | RECUPERADO: health 200 a los 45 s del reinicio |
| 20:59-21:01 | Nuevas ejecuciones de la alerta (sin estado): NO_ACTUA, "el health check ya responde 200" |
| 21:10:50 / 21:17:08 / 21:22:44 | ACTUA en cada nueva falla, **todas "intento 2 de 2"**: el limite no contaba (error 1 del runbook) |

### Corrida B (T0 21:30:29Z, runbook v2)
| Ciclo | Errores (min UTC: cantidad) | Runbook ACTUA | Recuperado |
|---|---|---|---|
| 1 | 21:33: 111x500 · 21:34: 400x500 + 120x503 · 21:35: 50x503 | 21:34:43 (intento 1 de 2) | 21:35:18 (30 s) |
| 2 | 21:39: 102x500 · 21:40: 565x500 · 21:41: 151x500 + 243x503 | 21:40:48 (intento 2 de 2) | 21:41:50 (60 s) |
| 3 | 21:46: 389x500 + 249x503 · 21:47: 55x503 | 21:46:45 (**otra vez "intento 2 de 2"**, debia ESCALAR) | 21:47:16 (30 s) |

Los 503 son la app reiniciandose.

### Resultado
- Deteccion (primer 5xx -> runbook en marcha): 1 a 3 min. Recuperacion automatica (primer 5xx -> health 200): ~2 a 4 min, frente a 26 min manuales el 18-sep.
- "Cuando no actuar" funciono: con la app sana el runbook no reinicio (decenas de NO_ACTUA registrados).
- **El limite de intentos no funciono en Azure en ninguna de las dos versiones**, aunque la logica pasaba en pruebas locales: Windows PowerShell 5.1 y la variable de Automation transforman el historial al leerlo (v1: fechas a DateTime; v2: JSON ya deserializado). La v3 guarda texto plano `h:<seg>,<seg>`, se probo localmente con ambos casos y **queda pendiente verificarla en Azure** junto con la alerta F (escalamiento por correo).

## Tablero (Azure Workbook "PortalPagos - Direccion y NOC")

Capturas 10 (Direccion: disponibilidad cada 15 min y decisiones del runbook: 49 NO_ACTUA, 11 ACTUA, 11 RECUPERADO), 11 (NOC: 5xx por minuto y p95) y 12 (NOC: memoria del proceso y endpoints con error: /pagos.aspx, 11.018 respuestas 500). Horas en Bogota.
