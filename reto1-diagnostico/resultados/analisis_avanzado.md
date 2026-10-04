## Analisis avanzado

### 1. La memoria crece con cada pago

- Correlacion por hora entre crecimiento de memoria y operaciones de pago: **0.993** (contra 0.935 con el total de peticiones).
- Cada operacion de pago deja ~**0.25 MB** retenidos en memoria.
- El 18-sep el primer OutOfMemory llego tras **4,242 operaciones de pago** desde el reinicio de 02:00. El 16 y 17 hubo ~3.600 y ~4.000 en el dia completo: estuvieron cerca del limite.
- Implicacion: el portal aguanta ~4.200 operaciones de pago por dia. Cualquier dia por encima se cae.

### 2. Reintentos de confirmacion de pago

cs-uri-stem  /api/pagos/confirmar  /api/pagos/iniciar  confirmar/iniciar
ts                                                                      
2026-09-14                   1601                1914               0.84
2026-09-15                   1539                1797               0.86
2026-09-16                   1597                1968               0.81
2026-09-17                   1805                2117               0.85
2026-09-18                   3935                3908               1.01
2026-09-19                    735                 849               0.87
2026-09-20                    409                 550               0.74

- En un dia normal se confirman ~84% de los pagos iniciados. El 18-sep hubo **mas confirmaciones que inicios** (1.01): ~633 intentos de confirmacion de mas.
- Hipotesis: los clientes reintentaron al recibir errores. **Riesgo:** si `/api/pagos/confirmar` no es idempotente, pudo haber cobros duplicados. Se debe cruzar con el sistema de pagos.

### 3. Trafico del 18 frente a un dia habil promedio (misma hora)

7h: 1.52x | 8h: 1.53x | 9h: 1.56x | 10h: 1.52x | 11h: 1.54x | 12h: 1.56x | 13h: 1.48x | 14h: 0.89x | 15h: 1.42x | 16h: 1.51x | 17h: 1.56x | 18h: 1.63x

- El trafico se mantuvo ~1,5x durante la degradacion y solo cayo en la hora de la caida (14h). No hay evidencia de abandono masivo por lentitud; el impacto fue sobre todo errores y espera.

### 4. Cuando habria avisado un monitoreo adecuado

| Regla | Habria disparado |
|---|---|
| Memoria w3wp > 1 GB | mie 16-09 18:40 |
| Disco C: < 30 % libre | jue 17-09 14:40 |
| p95 > 2x linea base (1055 ms) por 15 min, con >=100 pet/5 min | vie 18-09 12:00 |
| Errores (5xx + 503) > 5 % en 5 min, con >=50 pet | vie 18-09 13:25 |
| Sonda sintetica externa (falla de /health) | vie 18-09 14:38 |
| Primer ticket de cliente (real) | vie 18-09 13:34 |
| Recuperacion manual (real) | vie 18-09 15:04 |

- La regla de latencia no habria dado falsas alarmas los dias 14 a 17 (dias con disparo: 0).
- Con la alerta de latencia se habria detectado **1 h 34 min antes del primer ticket** y **2 h 38 min antes de la caida**; con la de memoria, casi **dos dias antes**.
