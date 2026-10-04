# Bitácora de uso de IA

## 1. Herramientas y modelos usados

| Herramienta / modelo | Para qué la usé |
|---|---|
| Claude (claude.ai) | Análisis exploratorio del kit, planeación, revisión de código |
| _(completar)_ | |

## 2. Prompts clave (5 a 10)

| # | Prompt (resumen) | Qué respondió la IA (resumen) | Qué hice con eso |
|---|---|---|---|
| 1 | _(completar)_ | | |

## 3. Situaciones en que la IA se equivocó o propuso algo riesgoso (mínimo 3)

| # | Qué propuso la IA | Cómo me di cuenta | Cómo lo corregí |
|---|---|---|---|
| 1 | El script de análisis detectaba el duplicado del 16, pero marcaba como duplicado el archivo **original** y conservaba `u_ex260916 - copia.log` (al ordenar por nombre, el espacio va antes del punto). | Al leer la salida, el reporte decía que el original era la copia. | Hice que los archivos con "copia" se procesen de últimos. Las cifras no cambiaban, pero la trazabilidad del reporte sí. |
| 2 | En el diagnóstico inicial la IA afirmó que "muchos clientes abandonaron por la lentitud", porque las peticiones cada 10 min bajaron de ~700 a ~340 entre las 11:00 y las 13:00. | Al comparar contra la **misma hora** de los días anteriores, el tráfico del 18 se mantuvo en ~1,5x hasta la caída: la baja era el patrón normal del mediodía. | Quité la afirmación del post-mortem y agregué al script la comparación por hora contra la línea base (`analisis_avanzado.md`, sección 3). |
| 3 | En el Reto 2, la primera versión del script PowerShell pasaba `-WhatIf` al script principal, pero **en modo simulación copiaba y borraba archivos de verdad**: la preferencia `-WhatIf` no se propaga a las funciones de un módulo (scope distinto). | Probando en carpetas de prueba: después de la "simulación" los logs ya estaban borrados. | Se pasa `-WhatIf` explícitamente a cada paso (`@sim`), se agregaron pruebas Pester que verifican que `-WhatIf` no cambia nada y la demo `demo-local.ps1` lo comprueba antes y después. |
| 4 | Al documentar los problemas del `.BAT`, la IA copió la línea del `net use` **con la contraseña real incluida** en `PROBLEMAS.md`, que iba a subirse al repositorio. | Revisión de secretos antes de cada commit (búsqueda de la clave en todos los archivos a versionar). | Se reemplazó por `<clave>` y se dejó explícito que se omite a propósito. |

## 4. Cómo validé lo que generó la IA

- Toda cifra del post-mortem sale de `analizar.py`, que se puede volver a ejecutar; ninguna se copió de una respuesta de la IA.
- Pruebas automáticas (`pytest`) para las dos trampas del parser: cambio de `#Fields` y conversión UTC → Colombia.
- Verifiqué a mano hitos clave contra los archivos crudos (p. ej. primer 503 en `httperr1.log`, evento WAS 5002 en el CSV de eventos).
- Las reglas de alerta simuladas se probaron también sobre los días normales para medir falsas alarmas.

## 5. Qué decidí NO delegarle a la IA y por qué

- _(completar)_
