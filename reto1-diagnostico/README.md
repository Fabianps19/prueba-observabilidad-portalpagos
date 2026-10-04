# Reto 1 · Diagnóstico basado en datos

## Cómo reproducir

```bash
cd reto1-diagnostico
python -m pip install -r requirements.txt
python analizar.py --kit ../kit --salida resultados
python -m pytest -q tests
```

Requiere el kit descomprimido en `../kit` (ver README principal).

## Qué produce (`resultados/`)

| Archivo | Contenido |
|---|---|
| `calidad_datos.md` | Problemas de los datos crudos, visión del NOC e hitos del 18-sep |
| `disponibilidad_diaria.csv` | Disponibilidad real por día (incluye los 503 que solo registra HTTP.sys) |
| `linea_tiempo_18sep.csv` | Peticiones, errores y p95 cada 10 min el día del incidente |
| `senales_diarias.csv` | Memoria pico de w3wp, p95 y disco libre por día |
| `pronostico_disco.md` | Fecha estimada de llenado del disco C: y método |
| `eventos_clave.csv` | Eventos de Windows relevantes, sin ruido (DCOM, Schannel, SCM) |
| `*.png` | Memoria de w3wp, disco libre e incidente del 18-sep |

## Decisiones del análisis

- **Hora:** todo en hora de Colombia (UTC-05:00). IIS y HTTP.sys se convierten desde UTC; eventos y Perfmon ya vienen en hora local.
- **Duplicados:** se detectan por hash MD5, no por nombre.
- **Columnas variables:** el parser relee `#Fields` cada vez que aparece.
- **Disponibilidad:** peticiones de usuarios (sin `/health` ni escaneos 404). Fallo = 5xx en IIS o 503 en HTTP.sys. Se reporta además una versión que exige respuesta en menos de 3 s (supuesto).
