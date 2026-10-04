# Post-mortem · Caída de PortalPagos del viernes 18 de septiembre de 2026

**Formato sin culpables.** El objetivo es entender qué falló en el sistema y en los procesos, no señalar personas.
**Horas:** todas en hora de Colombia.

## 1. Resumen para la Dirección

El viernes 18 de septiembre, último día de un plazo de pago, el portal se puso lento desde las **11:20**, empezó a fallar al confirmar pagos a las **13:23** y quedó **totalmente caído de 14:38 a 15:04** (26 minutos). Ese día fallaron unas **2.000 operaciones** de clientes, entre ellas **141 confirmaciones de pago**, y muchos clientes abandonaron por la lentitud.

**La causa:** una actualización del portal instalada el martes 15 en la noche trajo un componente que **acumula memoria y no la libera**. Cada madrugada, el mantenimiento automático reiniciaba el servidor y "borraba" el problema sin que nadie lo notara. El viernes, con 44 % más clientes que un día normal, la memoria se agotó antes de la noche.

**Por qué nos enteramos por los clientes:** el monitoreo del NOC solo pregunta "¿el servidor responde?", no "¿los pagos funcionan?". Por eso reportó 100 % de disponibilidad la misma semana en que los clientes no pudieron pagar.

**Riesgo vigente:** el problema de memoria **sigue en producción** y el disco del servidor se está llenando; al ritmo actual se llena alrededor del **martes 22 de septiembre**.

## 2. Impacto

| Indicador | Valor |
|---|---|
| Degradación (lentitud) | 11:20 – 15:04 (3 h 44 min) |
| Errores al pagar | 13:23 – 15:04 (1 h 41 min) |
| Caída total | 14:38 – 15:04 (26 min) |
| Operaciones fallidas el 18-sep | ~1.985 (496 errores de la aplicación + 1.489 rechazos con el portal apagado) |
| Confirmaciones / inicios de pago fallidos | 141 / 134 |
| Disponibilidad real del viernes | **94,5 %** (92,7 % si se exige respuesta en menos de 3 s) |
| Disponibilidad real de la semana | 98,6 % |
| Disponibilidad reportada por el NOC | 100 % |

## 3. Línea de tiempo

| Hora | Qué pasó | Qué vio el cliente | Evidencia |
|---|---|---|---|
| Mar 15, 22:03 | Se instala PortalPagos v2.3.1 (nuevo caché de sesiones de pago, logs en nivel Debug) | Nada | Evento AndinaDeploy 1000 |
| Mié 16 y jue 17 | La memoria del portal sube todo el día (~1,1–1,2 GB) y el reinicio de las 02:00 la baja | Lentitud en la tarde (ticket T-10240, cerrado "monitoreo en verde") | Perfmon, `memoria_w3wp.png` |
| Vie 18, 08:00–11:00 | La memoria crece más rápido por el alto tráfico | Nada | Perfmon |
| **11:20** | Empieza la degradación: el tiempo de respuesta pasa de ~0,5 s a 1–3 s | Lentitud; muchos abandonan | Logs IIS (p95) |
| **13:23** | Primer error al confirmar pagos por falta de memoria | "Ha ocurrido un error inesperado" (T-10252) | IIS + evento ASP.NET 1309 |
| 14:22 – 14:38 | El proceso del portal se cae 5 veces | Errores intermitentes | Eventos .NET 1026 / WAS 5011 |
| **14:38** | IIS apaga el portal por fallas repetidas (protección automática) | "Service Unavailable" para todos (T-10255) | Evento WAS 5002, log HTTP.sys |
| **15:04** | Se reinicia el portal manualmente | Servicio normal | Último error 15:03:59 |
| 16:37 | Alerta de disco casi lleno | Nada | Evento srv 2013 |

## 4. Causa raíz y factores que contribuyeron

**Hechos (con evidencia):**
- Los errores son `OutOfMemoryException` dentro de `SesionPagoCache.Agregar`, componente que llegó con la v2.3.1.
- Antes de la actualización, la memoria máxima diaria era ~320 MB; después: 1.091 MB (16-sep), 1.186 MB (17-sep) y 1.478 MB al caer (18-sep). Tras el reinicio manual del viernes volvió a subir a casi 1 GB esa misma noche.

**Hipótesis (por confirmar):**
- El caché no expulsa sesiones antiguas, por lo que crece con el número de pagos.
- El portal falla cerca de 1,4 GB aunque el servidor tenía ~4,7 GB libres: probablemente el pool corre en modo 32 bits. Se confirma revisando `enable32BitAppOnWindows`.

**Factores que contribuyeron:**
1. **El reinicio nocturno ocultó la falla** durante dos días.
2. **El monitoreo no mide lo que importa:** `/health` respondió en 2 ms incluso cuando pagar tardaba 25 s, y sus fallos solo quedaron en un log que nadie revisa.
3. **Una señal temprana se descartó:** el ticket del jueves se cerró porque "el monitoreo estaba en verde".
4. **Cambios sin seguimiento:** no hubo revisión después de la actualización, y el 16-sep se instaló un proxy delante del servidor sin registro.
5. **Pico de demanda previsible:** cierre de plazo de pago, 44 % más tráfico.

**Descartado:** las advertencias DCOM 10016 (ticket T-10261) aparecen igual toda la semana y no tienen relación con la caída.

## 5. ¿Se podía ver venir?

Sí, **desde el miércoles 16 en la mañana**, con más de dos días de anticipación:
- Memoria máxima del portal: se triplicó frente a los días previos a la actualización.
- Disco: empezó a perder ~7 GB diarios.
- Tiempo de respuesta (p95): 544 → 572 → 686 ms, y 1.912 ms el viernes.

## 6. Otros riesgos encontrados

| Riesgo | Urgencia | Detalle |
|---|---|---|
| Disco C: lleno | 🔴 Inmediata | Consumo ~240 MB por cada 1.000 operaciones; con 10,9 GB libres se llena **el martes 22-sep**. Una nueva caída lo llena en horas (volcados de memoria) |
| Fuga de memoria en producción | 🔴 Inmediata | El próximo día de alto tráfico se repite la caída |
| Logs de auditoría sin copiar desde el 16-sep | 🟠 Alta | El mantenimiento apunta a la unidad D:, retirada ese día, y aun así reporta "Proceso OK" |
| Logs en nivel Debug en producción | 🟠 Alta | Llenan el disco y pueden contener datos sensibles |
| Contraseña en texto plano en el script de mantenimiento | 🟡 Media | Cuenta de servicio de 2019 |

## 7. Acciones

| # | Acción | Tipo | Plazo |
|---|---|---|---|
| 1 | Liberar disco y bajar el nivel de logs a Information | Contener | Inmediato |
| 2 | Revertir a v2.3.0 o corregir el caché (límite de tamaño y expiración) | Corregir | Antes del próximo cierre de pagos |
| 3 | Reciclaje del pool por umbral de memoria como red de seguridad temporal | Contener | Esta semana |
| 4 | Health check profundo que pruebe una transacción real, y monitoreo sintético externo | Detectar | 2 semanas |
| 5 | Alertas por tasa de errores, latencia p95, memoria y disco | Detectar | 2 semanas |
| 6 | Revisión post-despliegue obligatoria a las 24 h y registro de todo cambio | Prevenir | 1 mes |
| 7 | Reemplazar el script de mantenimiento (ver Reto 2) y rotar la credencial expuesta | Prevenir | 2 semanas |

_Cifras reproducibles con `python analizar.py`; detalle en `resultados/`._
