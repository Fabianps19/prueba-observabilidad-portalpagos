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

## Prueba 3 (6-oct): despliegue desde cero y runbook v3 (FUGA_KB=128)

Grupo de recursos nuevo (el del 5-oct se habia eliminado). Capturas 13, 14, 15, 17 y 18.

| Hora (UTC) | Hecho |
|---|---|
| 13:32:36 - 13:36:57 | `desplegar.sh` crea todo desde cero sin intervencion manual (4 min 21 s) |
| 13:41:37 | T0: version con fuga e inicio de la carga |
| 13:46 | Ciclo 1: primeras respuestas 500 (~1.090 por minuto) |
| 13:49:17 | Alerta B (5xx) disparada: correo |
| 13:50:19 | Primera alerta E (workspace recien creado: ingesta inicial mas lenta) |
| 13:51:01 | Runbook ACTUA, intento 1 de 2 |
| 13:51:32 | RECUPERADO (30 s) |
| 13:53:09 | Alerta D (tasa de error > 5 %) disparada: esta vez la falla duro ~5 min |
| 13:55-13:56 | Ciclo 2: errores |
| 13:56:29 | Runbook ACTUA, intento 2 de 2 |
| 13:57:00 | RECUPERADO (30 s) |
| 14:01 | Ciclo 3: errores |
| **14:05:01** | **Runbook ESCALAR**: "Ya hubo 2 reinicios en 60 min (limite 2). No se reinicia". El job termina en Failed a proposito y la app queda caida esperando a una persona. Se repite cada minuto (8 veces) mientras la falla sigue |
| **14:10:24** | **Alerta F (escalamiento) disparada: correo a la persona de turno** |
| 14:13:22 | Intervencion humana: rollback (FUGA_KB=0) y reinicio manual |
| 14:14:02 | Ultima respuesta 500; servicio sano |
| 14:14:16 | Alerta C (health check) disparada por la caida sostenida del ciclo 3 |

Cliente (carga.sh): 33.340 peticiones, 16.601 con 5xx (49,8 %). La tasa es alta a proposito: el ciclo 3 deja la app caida ~13 min para demostrar el escalamiento.

Log Analytics (evidencias.sh, HORAS=1): /pagos.aspx 500 = 13.511 en los logs W3C. p95 entre 21 y 52 ms: las fallas son instantaneas (500 inmediato), asi que la latencia no es buena senal para este modo de falla. Memoria de plataforma entre 138 y 178 MB: confirma la observacion de la prueba 2 (la alerta A no se disparo).

### Resultado
- Limite de intentos y escalamiento: **verificado en Azure**. 2 reinicios automaticos y, al tercero, escalamiento con correo (alerta F) en lugar de reiniciar en bucle.
- Deteccion: alerta B ~3 min despues del primer error; runbook en 1 a 5 min segun el ciclo.
- Recuperacion automatica: 30 s tras la accion del runbook (~2 a 5 min desde el primer error).
- Escalamiento a una persona: correo 9 min despues del inicio del ciclo 3 (4 min de deteccion + 5 min de evaluacion de la alerta F).

Tablero de la prueba 3: capturas 19 (decisiones del runbook: 59 NO_ACTUA, 12 RECUPERADO, 11 ACTUA, 8 ESCALAR en 24 h, sumando la prueba 2 del 5-oct porque el workspace se recreo con el mismo nombre y Azure lo recupera), 20 (5xx por minuto) y 21 (bitacora con las decisiones ESCALAR de 09:07 a 09:13, hora Bogota).

## Presupuesto

Presupuesto "SK" sobre la suscripcion: USD 10 mensuales, alertas al 50 % del costo previsto y al 90 % del costo real, por correo. Capturas 22 y 23 (ID de suscripcion omitido).

## Tablero (Azure Workbook "PortalPagos - Direccion y NOC")

Capturas 10 (Direccion: disponibilidad cada 15 min y decisiones del runbook: 49 NO_ACTUA, 11 ACTUA, 11 RECUPERADO), 11 (NOC: 5xx por minuto y p95) y 12 (NOC: memoria del proceso y endpoints con error: /pagos.aspx, 11.018 respuestas 500). Horas en Bogota.
