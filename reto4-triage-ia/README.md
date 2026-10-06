# Reto 4 · IA para el triage de incidentes

`triage.py` recibe una alerta (esquema común de Azure Monitor) y el contexto del momento, y usa un modelo de lenguaje para producir un **resumen del incidente en JSON**, validado contra un esquema propio. **Sugiere; no ejecuta nada.**

## Flujo

```
alerta.json ─► contexto (±30 min: IIS, HTTP.sys, eventos, Perfmon, cambios recientes)
            ─► cada línea recibe un ID (E01, E02...) y se enmascaran IPs y números largos
            ─► prompt: evidencias como DATOS + catálogo cerrado de runbooks + esquema
            ─► modelo (GitHub Models / Azure OpenAI)
            ─► validación 1: JSON + esquema (runbook ∈ catálogo, campos obligatorios)
            ─► validación 2: cada cita existe en la evidencia que dice citar
            ─► resultado + meta (estado, intentos, problemas, inyección detectada, requiere_aprobacion_humana = true)
```

## Esquema y catálogo

- `esquema/resumen_incidente.schema.json`: qué está pasando, impacto y severidad, hipótesis (cada una con evidencia `{id, cita}`), acción sugerida, confianza y datos faltantes. `additionalProperties: false` en todo.
- `esquema/catalogo_runbooks.json`: **RB-01** reciclar pool · **RB-02** iniciar pool detenido · **RB-03** liberar disco · **RB-04** escalar a desarrollo / rollback · **RB-05** escalar a infraestructura · **RB-06** observar. El campo `runbook` es un `enum`: el modelo no puede proponer una acción fuera del catálogo.

## Qué pasa si el modelo falla, se demora o responde algo inválido

| Situación | Comportamiento |
|---|---|
| No responde a tiempo (timeout, por defecto 30 s) o error de red | No se insiste: se entrega un **resumen de respaldo sin IA** por reglas fijas, con `confianza = baja` y `estado = respaldo_sin_ia` |
| JSON inválido o fuera del esquema | **Un reintento** enviándole al modelo el error exacto; si vuelve a fallar, respaldo sin IA |
| JSON válido pero con citas inventadas (ID inexistente o texto que no está en la evidencia) | Se entrega marcado `ok_con_advertencias`, la confianza se baja a `baja` y los problemas se listan en `datos_faltantes` y `meta.problemas_contenido` |
| Texto malicioso en un log ("ignore previous instructions…") | La evidencia se marca como sospechosa (`meta.inyeccion_detectada`), el prompt la trata como dato, y aunque el modelo obedezca, la acción queda limitada al catálogo |
| Responde en otro idioma (p. ej. inglés) | El prompt exige español; la validación compara palabras frecuentes del español y del inglés en los textos libres y, si no está en español, **pide corregir con un reintento** (las citas se copian literalmente, aunque el log esté en inglés) |
| Cualquier caso | `requiere_aprobacion_humana = true` y `ejecuta_acciones = false`: una persona decide |

## Casos de prueba (`tests/test_triage.py`, proveedor simulado)

| Caso | Qué se prueba | Resultado esperado |
|---|---|---|
| 1. Correcto | Respuesta bien fundamentada | `ok`, RB-04, confianza alta |
| 2. **El modelo se inventa algo** | Cita "Deadlock en SQL Server" en E07 y una evidencia E99 que no existe | **Detectado**: `ok_con_advertencias`, confianza degradada a `baja` |
| 3. JSON inválido | Primera respuesta con texto + JSON cortado | Reintento y `ok` en el intento 2 |
| 4. Timeout | El modelo no responde | Respaldo sin IA |
| 5. Inyección en un log | Un log pide "run reboot" y el modelo propone `REINICIAR-SERVIDOR` | Esquema lo rechaza, respaldo sin IA, inyección marcada |
| 6. Responde en inglés | Primera respuesta válida pero en inglés | Detectado y corregido: reintento pidiendo español, `ok` en el intento 2 |
| 7. Privacidad | IPs y cédulas | Enmascaradas antes de enviarse |

```bash
python -m pip install -r requirements.txt
python -m pytest -q tests          # 7 pruebas
python ejecutar_casos.py           # guarda cada caso en ../evidencias/reto4/
```

## Ejecución con un modelo real (GitHub Models, gratuito)

1. Crea un token en GitHub → Settings → Developer settings → **Fine-grained tokens**, con permiso **Models: read**.
2. Sin escribirlo en ningún archivo:

```powershell
$env:GITHUB_TOKEN = Read-Host "Token de GitHub Models"   # solo vive en esta terminal
python triage.py --alerta ..\kit\alertas\alerta_ejemplo.json --kit ..\kit --proveedor github --salida ..\evidencias\reto4\real_github.json
```

Modelo por defecto `openai/gpt-4.1-mini` (cambiable con `TRIAGE_MODELO`). Para Azure OpenAI: `--proveedor azure` con `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_KEY` y `AZURE_OPENAI_DEPLOYMENT`.

## Hallazgo: no creerle a ciegas a la alerta

La alerta de ejemplo dice **23,4 %** de errores, pero recalculando con los logs de IIS de esa ventana (13:55–14:00) da **12,8 %** (23 de 180). El componente agrega ese recálculo como evidencia (E02) para que la persona vea la discrepancia. Posibles causas: otra ventana de evaluación o una consulta de alerta distinta a la documentada.

## Conexión con el Reto 3 (diseño, no implementado)

El Reto 3 ya tiene alertas reales con Action Group en Azure. El siguiente paso sería agregar a ese Action Group una Azure Function con este mismo código: la alerta llega en el esquema común (el mismo de `alerta_ejemplo.json`), el contexto se obtiene con KQL (`AppServiceHTTPLogs`, `AzureMetrics` y la bitácora del runbook en el laboratorio; `W3CIISLog`, `Event` y `Perf` en la VM real) y el resumen se publica en el canal del NOC. La Function solo sugiere: la remediación sigue en manos del runbook con salvaguardas y de una persona.
