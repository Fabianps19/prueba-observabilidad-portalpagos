# Validar el diagnóstico en Power BI

Objetivo: comprobar con una segunda herramienta, independiente del código Python, que cada cifra del post-mortem es correcta. Si Power BI y Python dan el mismo número partiendo de los mismos datos, la cifra está respaldada.

## 1. Generar los datos

```bash
python analizar.py --kit ../kit --salida resultados
```

Crea `resultados/powerbi/` con cuatro tablas limpias, todas en **hora de Colombia**:

| Archivo | Una fila por | Columnas clave |
|---|---|---|
| `peticiones.csv` | Petición HTTP (IIS + rechazos de HTTP.sys) | `fecha_hora`, `fecha`, `hora`, `ventana_10min`, `fuente`, `endpoint`, `status`, `tiempo_ms`, `es_cliente`, `es_error`, `es_pago`, `es_sonda_noc` |
| `perfmon.csv` | Muestra de 5 min | `fecha_hora`, `w3wp_mb`, `disco_libre_mb`, `cpu_pct` |
| `eventos.csv` | Evento de Windows | `fecha_hora`, `ProviderName`, `Id`, `Message`, `es_ruido` |
| `tickets.csv` | Ticket | `FechaHoraReporte`, `Descripcion`, `NotaCierre` |

Ya están resueltas las trampas del kit: duplicado excluido, UTC convertido, columnas variables y 503 de HTTP.sys incluidos (`fuente = "HTTP.sys"`).

## 2. Cargar en Power BI Desktop

1. **Obtener datos → Texto/CSV** para cada archivo.
2. En Power Query, verifica los tipos: `fecha_hora` y `ventana_10min` = Fecha/hora; `fecha` = Fecha; `status`, `tiempo_ms`, `w3wp_mb` = Número; columnas `es_*` = Verdadero/Falso. Configuración regional **Inglés (Estados Unidos)** para que el punto decimal se lea bien.
3. Tabla calendario (Modelado → Nueva tabla):

```DAX
Calendario = CALENDAR(DATE(2026,9,14), DATE(2026,9,20))
```

4. Relaciones: `Calendario[Date]` → `peticiones[fecha]`; para perfmon y eventos agrega antes en Power Query una columna `fecha = DateTime.Date([fecha_hora])` y relaciónala igual.

## 3. Medidas DAX

```DAX
Peticiones cliente = CALCULATE(COUNTROWS(peticiones), peticiones[es_cliente] = TRUE())

Peticiones fallidas = CALCULATE([Peticiones cliente], peticiones[es_error] = TRUE())

Disponibilidad % = DIVIDE([Peticiones cliente] - [Peticiones fallidas], [Peticiones cliente])

Rechazos HTTP.sys = CALCULATE(COUNTROWS(peticiones), peticiones[fuente] = "HTTP.sys", peticiones[status] = 503)

p95 ms =
CALCULATE(
    PERCENTILE.INC(peticiones[tiempo_ms], 0.95),
    peticiones[fuente] = "IIS", peticiones[es_sonda_noc] = FALSE()
)

Tasa de error % = DIVIDE([Peticiones fallidas], [Peticiones cliente])

Confirmaciones por inicio =
VAR c = CALCULATE(COUNTROWS(peticiones), peticiones[fuente] = "IIS", peticiones[endpoint] = "/api/pagos/confirmar")
VAR i = CALCULATE(COUNTROWS(peticiones), peticiones[fuente] = "IIS", peticiones[endpoint] = "/api/pagos/iniciar")
RETURN DIVIDE(c, i)

Memoria pico MB = MAX(perfmon[w3wp_mb])

Disco libre GB (final) = DIVIDE(LASTNONBLANKVALUE(perfmon[fecha_hora], MAX(perfmon[disco_libre_mb])), 1024)

Fallos sonda NOC = CALCULATE(COUNTROWS(peticiones), peticiones[es_sonda_noc] = TRUE(), peticiones[es_error] = TRUE())
```

## 4. Un visual por cada afirmación

| Afirmación del post-mortem | Visual | Configuración |
|---|---|---|
| Disponibilidad real 94,5 % el viernes y 98,6 % la semana | Tabla | Filas `Calendario[Date]`; valores `Peticiones cliente`, `Peticiones fallidas`, `Disponibilidad %` |
| El NOC vio 100 % pero hubo 52 fallos de `/health` | Tarjetas | `Fallos sonda NOC` filtrado por `fuente` = HTTP.sys |
| Lentitud desde 11:20, errores desde 13:23, caída 14:38–15:04 | Gráfico de líneas + gráfico de columnas, **uno debajo del otro** | Eje X `ventana_10min` (filtro: 18-sep, 08:00–17:00); líneas `p95 ms`; columnas `Peticiones fallidas` |
| La fuga: serrucho de memoria desde el 16 | Gráfico de líneas | Eje X `perfmon[fecha_hora]`; valor `w3wp_mb`. Agrega una línea constante en 1.000 MB |
| Memoria pico ~320 MB antes y 1.091 / 1.186 / 1.478 MB después | Columnas | Eje `Calendario[Date]`; valor `Memoria pico MB` |
| p95 diario 544 → 572 → 686 → 1.912 ms | Columnas | Eje `Calendario[Date]`; valor `p95 ms` |
| ~630 reintentos de confirmación (1,01 vs ~0,84) | Columnas | Eje `Calendario[Date]`; valor `Confirmaciones por inicio` |
| Disco se llena el martes 22 | Líneas con **pronóstico** | Eje `perfmon[fecha_hora]`; valor `disco_libre_mb`; panel Analytics → Forecast (comparar con el método por tráfico del script) |
| Eventos clave y descarte de DCOM | Tabla | `eventos` con filtro `es_ruido` = Falso; segunda tabla con `Id` = 10016 contada por día (constante) |

## 5. Valores esperados (deben coincidir con Python)

| Medida | Filtro | Valor esperado |
|---|---|---|
| `Disponibilidad %` | 18-sep | 94,48 % |
| `Disponibilidad %` | Semana completa | 98,57 % |
| `Peticiones fallidas` | 18-sep | 1.985 |
| `Rechazos HTTP.sys` | 18-sep | 1.541 (1.489 de clientes + 52 de la sonda) |
| `p95 ms` | 14 / 17 / 18-sep | 544 / 686 / 1.912 |
| `Memoria pico MB` | 16 / 17 / 18-sep | 1.091 / 1.186 / 1.478 |
| `Confirmaciones por inicio` | 18-sep | 1,01 |
| `Disco libre GB (final)` | 20-sep | 10,91 |

Si un valor no coincide, revisa primero los tipos de datos y la configuración regional en Power Query.
