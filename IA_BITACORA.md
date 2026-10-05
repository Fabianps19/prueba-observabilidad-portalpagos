# Bitácora de uso de IA

**Autor:** Fabián Augusto Pinzón Silva · **Entrega:** 5 de octubre de 2026

Usé IA en los cinco retos como copiloto: para leer y explorar datos, escribir borradores de código y documentos, y operar Azure desde Cloud Shell con mi aprobación. Las decisiones las tomé yo, y verifiqué cada resultado contra los datos o ejecutándolo. Esta bitácora resume qué le pedí, qué entregó, dónde se equivocó y cómo lo controlé.

**En cifras:** 9 prompts clave · **8 errores de la IA detectados y corregidos** · 0 secretos en el historial del repositorio (verificado sobre los 8 commits).

## 1. Herramientas y modelos

| Herramienta / modelo | Uso | Dónde |
|---|---|---|
| **Claude (Anthropic)**, asistente con acceso a archivos y al navegador | Análisis exploratorio del kit, borradores de código (Python, PowerShell, KQL, bash), redacción y revisión de documentos, y operación de Azure Cloud Shell con mi aprobación | Retos 1–5 |
| **GitHub Models** (`openai/gpt-4.1-mini`) | Modelo que consume el componente de triage en ejecución real | Reto 4 |
| **Proveedor simulado** (respuestas grabadas) | Pruebas deterministas, incluidas respuestas erróneas a propósito (alucinación, JSON inválido, timeout, inyección) | Reto 4 |

## 2. Prompts clave

| # | Prompt (resumen) | Qué respondió la IA | Qué hice con eso |
|---|---|---|---|
| 1 | "Analiza el adjunto" (enunciado) | Qué se evalúa, trampas probables del kit (UTC, 503 solo en HTTP.sys, duplicados) y plan por días | Prioricé con eso y verifiqué cada trampa contra el kit |
| 2 | "Este es el kit" | Hallazgos: duplicado por hash, `#Fields` que cambia, `OutOfMemoryException` en `SesionPagoCache`, despliegue del 15-sep, DCOM como pista falsa | Base del diagnóstico. Descarté una conclusión falsa (error 2) |
| 3 | "¿Cómo llevo el análisis a un siguiente nivel?" | Correlación memoria-pagos (0,993), reintentos de confirmación y detección simulada con reglas de alerta | Lo incorporé al script. Corregí la hora de las alertas para que cuente al cierre de la ventana |
| 4 | "Revisa que todo lo que se entrega sea cierto" | Recálculo independiente de las cifras: los pagos fallidos estaban subestimados (141 → 250) | Corregí el post-mortem y agregué las causas descartadas con datos |
| 5 | "El post-mortem debe tener máximo 3 páginas" | Versión condensada, verificada en un PDF A4 real | Revisé que no se perdiera ninguna cifra clave |
| 6 | Script PowerShell del Reto 2 | Módulo con `-WhatIf`, log JSON, códigos de salida y pruebas Pester | Detecté que `-WhatIf` borraba archivos (error 3). Corrí las 15 pruebas en mi equipo |
| 7 | Triage con IA del Reto 4 | Esquema, catálogo cerrado, validación de citas, respaldo sin IA y casos de prueba | Revisé cada caso. El de inyección lo sustento desde mi especialización en seguridad |
| 8 | "Inicia el Reto 3 en mi equipo" | Despliegue por Cloud Shell: app simulada, Log Analytics, alertas con correo y simulación de la falla con tiempos medidos | Escribí yo las credenciales. Revisé los tiempos contra los datos y documenté las alertas que **no** se dispararon |
| 9 | "Verifica punto a punto contra el enunciado antes del último push" | Tabla de cumplimiento: faltaban la remediación disparada por alerta con salvaguardas (punto 14), el tablero (15), p95 y 5xx en KQL (12) y un script de despliegue reproducible | Completé todo y repetí la prueba en Azure, lo que reveló el error 8 |

## 3. Errores de la IA y cómo los corregí

| # | Qué propuso la IA | Cómo lo detecté | Corrección | Impacto si no se detectaba |
|---|---|---|---|---|
| 1 | La detección de duplicados marcaba como copia el archivo **original** y conservaba `u_ex260916 - copia.log` (el espacio se ordena antes del punto) | Leyendo la salida del reporte | Los archivos "copia" se procesan de últimos | Trazabilidad incorrecta en el reporte |
| 2 | Afirmó que "muchos clientes abandonaron por la lentitud" porque el tráfico bajó de ~700 a ~340 peticiones entre las 11:00 y las 13:00 | Comparando cada hora con la **misma hora** de días anteriores: el tráfico se mantuvo en ~1,5× (era el patrón normal del mediodía) | Retiré la afirmación y agregué al script la comparación contra la línea base | Una conclusión falsa en el post-mortem |
| 3 | En modo `-WhatIf` el script **borraba archivos de verdad**: la preferencia no se propaga a las funciones de un módulo | Probando en carpetas de prueba: tras la "simulación" los logs no estaban | `-WhatIf` explícito en cada paso (`@sim`), pruebas Pester que lo verifican y demo antes/después | Pérdida de datos en producción al usar la simulación |
| 4 | Copió la línea `net use` **con la contraseña real** en `PROBLEMAS.md` | Revisión de secretos antes de cada commit | Reemplazada por `<clave>`. Historial verificado sin secretos | Credencial publicada en el repositorio |
| 5 | Intentó crear la VM con tamaños sin cuota en la suscripción de prueba, y luego dejó el App Service en **Linux** (valor por defecto de la CLI), incompatible con ASP.NET sobre IIS | Errores de cuota de Azure y "Linux Runtime ASPNET is not supported" | Consultar cuotas antes de reintentar, App Service Windows explícito y documentar la adaptación | Tiempo perdido. Ningún recurso quedó huérfano |
| 6 | Presentó Auto-Heal como la auto-remediación del Reto 3, aunque no se dispara desde una alerta ni tiene límite de intentos ni escalamiento | Revisión punto a punto contra el enunciado | Runbook disparado por alerta con límite, enfriamiento, ventana de mantenimiento, modo sugerir, verificación y escalamiento | Incumplir el punto 14 |
| 7 | El PDF del post-mortem mostraba una lista como un solo párrafo | Revisando las páginas renderizadas | Regenerado con GFM y verificado en 3 páginas A4 | Documento menos legible para la Dirección |
| 8 | El límite de "2 reinicios por hora" del runbook **nunca se cumplió en Azure**: el historial se perdía al leerlo (v1: fechas convertidas por PowerShell 5.1; v2: la variable devolvía el JSON ya deserializado). El código "se veía bien" y la v2 pasaba pruebas locales | Ejecutándolo en Azure: cada falla decía "intento 2 de 2" y nunca escaló | v3 con historial en texto plano, probada contra ambos comportamientos. **Verificación en Azure pendiente** (ver `reto3-azure/README.md`) | Reinicios en bucle sobre una fuga activa, el mismo patrón que escondió el incidente |

**Lección principal:** los errores 3 y 8 solo aparecieron al **ejecutar**, no al leer el código. Por eso una salvaguarda solo la doy por buena cuando la veo funcionar en el entorno real.

## 4. Cómo validé lo que generó la IA

- **Cifras:** cada número del post-mortem sale de `analizar.py`, que se puede volver a ejecutar. Ninguna se copió de una respuesta del modelo.
- **Pruebas automáticas:** `pytest` para las trampas del parser (cambio de `#Fields`, UTC → Colombia) y para los 6 casos del triage. Pester (15 pruebas) para el script de mantenimiento, ejecutado en mi equipo.
- **Datos crudos:** verifiqué a mano los hitos clave, como el primer 503 en `httperr1.log` y el evento WAS 5002 en el CSV de eventos.
- **Umbrales:** las reglas de alerta se probaron también sobre los días normales, para medir falsas alarmas.
- **Azure:** los tiempos de detección y recuperación salen de las ejecuciones del runbook, de los logs en Log Analytics y del CSV de la carga, no de estimaciones (`reto3-azure/evidencias/RESULTADOS.md`).
- **Seguridad:** revisé el historial completo (8 commits) en busca de la contraseña del kit, tokens, llaves y URLs de webhook. Resultado: 0 hallazgos.

## 5. Qué no le delegué a la IA y por qué

| Decisión | Por qué la mantuve |
|---|---|
| Qué es hecho y qué es hipótesis en la causa raíz | Respondo por el diagnóstico ante la Dirección |
| Umbrales y severidades de las alertas | Se fijan con datos (falsas alarmas y tiempo de aviso), no por sugerencia del modelo |
| Salvaguardas de la auto-remediación y del triage | Son decisiones de riesgo operativo: límite de intentos, cuándo no actuar, catálogo cerrado y aprobación humana |
| Credenciales | Las escribí yo. La IA no las manipula y no quedan en archivos ni en el historial |
| Revisión antes de cada commit y push | Que no se suban el kit, las notas privadas ni secretos. Así encontré el error 4 |
| Ejecutar las pruebas en mi equipo | La evidencia debía salir de mi entorno, no de la conversación |

## 6. Controles sobre lo que la IA ejecutó en mi entorno

- Los comandos en Azure se ejecutaron en Cloud Shell con mi cuenta y mi aprobación, y todos se pueden leer en los scripts del repositorio.
- Cuando la IA intentó transferir los scripts como un paquete codificado (no legible), el control de seguridad lo bloqueó. Los subí yo desde el repositorio.
- El runbook usa una identidad administrada con permiso solo sobre la app. El URI del webhook (secreto) vive únicamente en Azure.
- Los recursos de Azure se eliminan al terminar (`az group delete`), con un presupuesto con alerta como red de seguridad.
