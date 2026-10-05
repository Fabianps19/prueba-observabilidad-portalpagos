# Bitácora de uso de IA

## 1. Herramientas y modelos usados

| Herramienta / modelo | Para qué la usé |
|---|---|
| Claude (Anthropic), en conversación con acceso a archivos | Lectura del enunciado y del kit, análisis exploratorio, borradores de código (Python, PowerShell, KQL), redacción del post-mortem y revisión de cifras |
| GitHub Models (`openai/gpt-4.1-mini`), opcional | Modelo que consume el componente de triage del Reto 4 en ejecución real |
| Proveedor simulado (respuestas grabadas) | Pruebas deterministas del Reto 4, incluyendo respuestas erróneas a propósito |

## 2. Prompts clave (5 a 10)

| # | Prompt (resumen) | Qué respondió la IA (resumen) | Qué hice con eso |
|---|---|---|---|
| 1 | "Analiza el adjunto" (enunciado de la prueba) | Resumen de lo que evalúan, trampas probables del kit (UTC, 503 solo en HTTP.sys, duplicados) y plan por días | Lo usé para priorizar; las trampas las verifiqué una por una con el kit |
| 2 | "Este es el kit" (zip) | Hallazgos: duplicado por hash, `#Fields` que cambia, OOM en `SesionPagoCache`, despliegue del 15-sep, disco y DCOM como pista falsa | Base del diagnóstico; corregí el supuesto de abandono de clientes (error 2) |
| 3 | "¿Hay forma de llevar el análisis a un siguiente nivel?" | Correlación memoria-pagos (0,993), reintentos de confirmación, detección simulada con reglas de alerta | Lo incorporé al script; la IA tuvo que corregir la hora de las alertas (al cierre de la ventana) |
| 4 | "Realiza una última revisión: que todo lo que se suministra sea cierto" | Recalculó las cifras con un script independiente y encontró pagos fallidos subestimados (141 → 250) | Corregí el post-mortem y agregué causas descartadas con datos |
| 5 | "El post-mortem debe ser de 3 hojas" | Versión condensada verificada con un PDF A4 real (3 páginas) | Acepté; revisé que no se perdieran cifras clave |
| 6 | Siguiente paso: script PowerShell del Reto 2 | Módulo con `-WhatIf`, log JSON, códigos de salida y pruebas Pester | Detecté que el `-WhatIf` borraba archivos (error 3) y corrí las 15 pruebas en mi Windows |
| 7 | Siguiente paso: triage con IA del Reto 4 | Esquema, catálogo cerrado, validación de citas, respaldo y casos de prueba (incluido uno de inyección en un log) | Revisé cada caso; el de inyección lo puedo defender desde mi especialización en seguridad |
| 8 | "Inicia el punto 3 en mi equipo" (Reto 3 en Azure) | Desplegó por Cloud Shell la app simulada, Log Analytics, alertas A–D con correo y Auto-Heal; corrió la simulación de la fuga y midió los tiempos | La contraseña de la VM la escribí yo (la IA no maneja credenciales). Revisé los tiempos contra los CSV y las alertas, y documenté las alertas que **no** se dispararon |
| 9 | "Verifica punto a punto contra el enunciado antes del último push" | Tabla de cumplimiento: el punto 14 (remediación desde una alerta con límite de intentos y escalamiento) y el 15 (tablero) no se cumplían; faltaban p95 y 5xx por endpoint en KQL y un script para reproducir el Reto 3 | Pedí completar todo: runbook con salvaguardas disparado por alerta, Workbook, `desplegar.sh` y una segunda prueba medida |

## 3. Situaciones en que la IA se equivocó o propuso algo riesgoso (mínimo 3)

| # | Qué propuso la IA | Cómo me di cuenta | Cómo lo corregí |
|---|---|---|---|
| 1 | El script de análisis detectaba el duplicado del 16, pero marcaba como duplicado el archivo **original** y conservaba `u_ex260916 - copia.log` (al ordenar por nombre, el espacio va antes del punto). | Al leer la salida, el reporte decía que el original era la copia. | Hice que los archivos con "copia" se procesen de últimos. Las cifras no cambiaban, pero la trazabilidad del reporte sí. |
| 2 | En el diagnóstico inicial la IA afirmó que "muchos clientes abandonaron por la lentitud", porque las peticiones cada 10 min bajaron de ~700 a ~340 entre las 11:00 y las 13:00. | Al comparar contra la **misma hora** de los días anteriores, el tráfico del 18 se mantuvo en ~1,5x hasta la caída: la baja era el patrón normal del mediodía. | Quité la afirmación del post-mortem y agregué al script la comparación por hora contra la línea base (`analisis_avanzado.md`, sección 3). |
| 3 | En el Reto 2, la primera versión del script PowerShell pasaba `-WhatIf` al script principal, pero **en modo simulación copiaba y borraba archivos de verdad**: la preferencia `-WhatIf` no se propaga a las funciones de un módulo (scope distinto). | Probando en carpetas de prueba: después de la "simulación" los logs ya estaban borrados. | Se pasa `-WhatIf` explícitamente a cada paso (`@sim`), se agregaron pruebas Pester que verifican que `-WhatIf` no cambia nada y la demo `demo-local.ps1` lo comprueba antes y después. |
| 4 | Al documentar los problemas del `.BAT`, la IA copió la línea del `net use` **con la contraseña real incluida** en `PROBLEMAS.md`, que iba a subirse al repositorio. | Revisión de secretos antes de cada commit (búsqueda de la clave en todos los archivos a versionar). | Se reemplazó por `<clave>` y se dejó explícito que se omite a propósito. |
| 5 | En el Reto 3 la IA intentó crear la VM con tamaños que mi suscripción de prueba no permitía (cuota 0 o sin capacidad), y al pasar a App Service el plan quedó en **Linux** porque así lo crea ahora la CLI por defecto, lo que no sirve para una app ASP.NET sobre IIS. | Los errores `SkuNotAvailable`/cuota de Azure y el mensaje "Linux Runtime ASPNET is not supported". | Se consultaron cuotas y capacidad antes de reintentar, se pasó a App Service Windows (`--is-linux false`), se borró el plan Linux vacío y se documentó la adaptación en el README del reto. |
| 6 | Tras la primera prueba en Azure, la IA presentó Auto-Heal como la auto-remediación del Reto 3. Pero el enunciado pide que **se dispare desde una alerta** y tenga **límite de intentos, cuándo no actuar y escalamiento**; Auto-Heal no tiene nada de eso, y en la prueba reinició dos veces sin frenarse. | Revisión punto a punto contra el enunciado antes del último push. | Se implementó un runbook disparado por la alerta E con límite de 2 reinicios por hora, enfriamiento, ventana de mantenimiento, modo sugerir, verificación y escalamiento (alerta F). Auto-Heal quedó documentado como primera línea opcional. |
| 7 | El PDF del post-mortem mostraba la lista de "Comprobado con los datos" como un solo párrafo con guiones (el conversor de Markdown no reconoce una lista sin línea en blanco antes). | Al revisar las páginas renderizadas del PDF en la misma revisión. | Se regeneró con el formato GFM; se verificó que sigue en 3 páginas A4. |

## 4. Cómo validé lo que generó la IA

- Toda cifra del post-mortem sale de `analizar.py`, que se puede volver a ejecutar; ninguna se copió de una respuesta de la IA.
- Pruebas automáticas (`pytest`) para las dos trampas del parser: cambio de `#Fields` y conversión UTC → Colombia.
- Verifiqué a mano hitos clave contra los archivos crudos (p. ej. primer 503 en `httperr1.log`, evento WAS 5002 en el CSV de eventos).
- Las reglas de alerta simuladas se probaron también sobre los días normales para medir falsas alarmas.
- Reto 3: los tiempos de detección y recuperación salen del CSV de la carga y de las alertas registradas en Azure, no de estimaciones (`reto3-azure/evidencias/RESULTADOS.md`).

## 5. Qué decidí NO delegarle a la IA y por qué

- **Las conclusiones de causa raíz:** la IA propone, pero yo decido qué es hecho y qué es hipótesis, porque soy quien responde por el diagnóstico.
- **Los umbrales de las alertas:** se fijaron probándolos contra los datos (falsas alarmas y tiempo de aviso), no por sugerencia del modelo.
- **Las salvaguardas de la auto-remediación y del triage** (límite de intentos, cuándo no actuar, catálogo cerrado, aprobación humana): son decisiones de riesgo operativo.
- **El control antes de cada commit:** reviso `git status` para que no se suban el kit, las notas privadas ni secretos. La revisión de secretos encontró un error de la IA (error 4).
- **La ejecución de las pruebas en mi equipo** (Pester y pytest): la evidencia debía salir de mi entorno, no de la conversación.
