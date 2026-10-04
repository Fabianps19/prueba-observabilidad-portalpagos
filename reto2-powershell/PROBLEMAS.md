# Problemas de `mantenimiento_diario.bat`, ordenados por riesgo

| # | Problema | Riesgo | Evidencia en el kit | Qué pasa si sale mal |
|---|---|---|---|---|
| 1 | **Contraseña en texto plano** (`net use ... /user:ANDINA\svc_mantenimiento <clave>`; la clave se omite a propósito en este repositorio) | Crítico | Línea 31 del script | Cualquiera que lea el archivo (o un backup, o un repositorio) obtiene una cuenta de dominio con acceso al share de auditoría. Clave de 2019 sin rotar. |
| 2 | **Falla en silencio: `exit /b 0` fijo y "Proceso OK" incondicional** | Crítico | `mantenimiento.log` solo tiene "Proceso OK"; TaskScheduler 201 siempre devuelve 0 | Desde el 16-sep la unidad D: no existe y nada se copia ni se borra, pero el script y la tarea reportan éxito. Nadie se entera. |
| 3 | **Ruta fija a D:\logs\iis** (parámetro de la tarea) | Alto | Evento AndinaDeploy 1001 (16-sep 11:30): D: retirada, logs ahora en C:\inetpub\logs | Los logs de IIS ya no se depuran ni se copian a auditoría: incumplimiento de auditoría y disco C: llenándose. |
| 4 | **`iisreset /restart` cada noche** | Alto | Eventos 3201/3202 a las 02:00 todos los días | Reinicia **todos** los sitios de IIS (no solo el pool), corta sesiones y, sobre todo, **escondió la fuga de memoria** durante dos días (ver Reto 1). Es "arreglar" sin diagnosticar. |
| 5 | **Borrados peligrosos si `%1` llega vacío** | Alto | `forfiles /p %LOGDIR% /s ...` y `del /q /s %LOGDIR%\*.tmp` sin comillas ni validación | Sin parámetro, `del /q /s \*.tmp` borra todos los `.tmp` de la unidad completa (desde la raíz). Rutas con espacios rompen los comandos porque no hay comillas. Nada valida que la ruta exista. |
| 6 | **Borra volcados de memoria sin criterio** (`del /q C:\Dumps\*.*`) | Medio | Los volcados reales están en `C:\CrashDumps` (eventos WER 1001) | Hoy borra la carpeta equivocada (no libera nada). Si se "arregla" la ruta, borraría la evidencia necesaria para diagnosticar la fuga. |
| 7 | **Borra logs antes de asegurar la copia** (paso 1 borra, paso 6 copia) | Medio | Orden de los pasos en el script | Si la copia falla, los logs de más de 7 días ya se perdieron: hueco de auditoría. |
| 8 | **Reinicia el servicio de notificaciones aunque esté sano** (`net stop` / `net start`) | Medio | Script, paso 5; eventos 7036 | Cortes innecesarios todas las noches; si `net start` falla, el servicio queda detenido sin aviso. |
| 9 | **`net use Z:` con letra fija** | Bajo | Script, paso 6 | Si Z: ya está mapeada, falla; la desconexión no se garantiza ante errores. |
| 10 | **Log sin fecha, sin detalle y sin estructura** | Bajo | `mantenimiento.log` | Imposible saber qué hizo cada noche ni cuánto tardó; no se puede alertar sobre él. |
| 11 | **Sin control de ejecución concurrente ni modo simulación** | Bajo | — | Dos ejecuciones simultáneas pueden pisarse; no hay forma segura de probarlo. |
