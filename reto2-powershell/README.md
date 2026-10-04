# Reto 2 · Modernizar el mantenimiento

- `PROBLEMAS.md`: problemas del `.BAT` original, ordenados por riesgo, con evidencia del kit.
- `Invoke-MantenimientoPortalPagos.ps1`: script de reemplazo (Windows PowerShell 5.1 y PowerShell 7).
- `src/MantenimientoPortalPagos.psm1`: funciones de cada paso (separadas para poder probarlas).
- `tests/MantenimientoPortalPagos.Tests.ps1`: pruebas Pester 5.

## Cómo ejecutarlo

```powershell
# Simulación: no cambia nada, solo registra en el log lo que haría
.\Invoke-MantenimientoPortalPagos.ps1 -RutaAuditoria '\\fs-auditoria\logs$\WEB-PAGOS-01' -WhatIf -Verbose

# Ejecución real, con reciclaje condicional del pool por memoria (red de seguridad mientras se corrige la fuga)
.\Invoke-MantenimientoPortalPagos.ps1 -RutaAuditoria '\\fs-auditoria\logs$\WEB-PAGOS-01' -UmbralReciclajeMB 1000
```

Log estructurado (una línea JSON por evento): `%ProgramData%\MantenimientoPortalPagos\mantenimiento.jsonl`. Se puede enviar a Log Analytics como log personalizado y alertar sobre `nivel = ERROR`.

| Código de salida | Significado |
|---|---|
| 0 | Todo OK |
| 1 | OK con advertencias (disco bajo umbral, logs protegidos sin copia, pool reciclado, servicio iniciado) |
| 2 | Al menos un paso falló (o el pool estaba detenido: requiere una persona) |
| 3 | Otra ejecución en curso |

Si los parámetros son inválidos (p. ej. la ruta de auditoría no existe), PowerShell no ejecuta el script y la tarea termina con código distinto de 0.

## Tarea programada sin credenciales

La tarea debe correr con una **cuenta de servicio administrada de grupo (gMSA)** con permiso de escritura solo en el share de auditoría. Así el script no necesita usuario ni contraseña:

```powershell
$accion  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\scripts\mantenimiento\Invoke-MantenimientoPortalPagos.ps1" -RutaAuditoria "\\fs-auditoria\logs$\WEB-PAGOS-01" -UmbralReciclajeMB 1000'
$disparo = New-ScheduledTaskTrigger -Daily -At 02:00
$cuenta  = New-ScheduledTaskPrincipal -UserId 'ANDINA\gmsa-mant-web$' -LogonType Password
Register-ScheduledTask -TaskName '\Mantenimiento\MantenimientoPortalPagos' -Action $accion -Trigger $disparo -Principal $cuenta
```

## Qué hace distinto al `.BAT` y por qué

| Paso del `.BAT` | Decisión | Reemplazo |
|---|---|---|
| 1. Borrar logs > 7 días en `%1` | **Se mantiene, con salvaguardas** | La ruta se lee de la configuración de IIS; solo se borra lo que ya tiene **copia verificada por hash** en auditoría |
| 2. Borrar `*.tmp` | **Desaparece** | Supuesto: IIS no genera `.tmp` en la carpeta de logs, así que era un borrado recursivo sin objetivo y peligroso si `%1` venía vacío. Si alguna aplicación los genera, se agrega como paso con la misma función de limpieza por antigüedad |
| 3. Borrar volcados | **Se mantiene, con retención** | Solo volcados de más de 14 días en la carpeta real (`C:\CrashDumps`); los recientes se conservan como evidencia |
| 4. `iisreset` diario | **Desaparece** | Reciclaje **condicional** solo del pool y solo si supera un umbral de memoria (opcional); si el pool está detenido no actúa y escala. A mediano plazo: corregir la fuga y configurar en IIS `recycling.periodicRestart.privateMemory` como red de seguridad nativa |
| 5. `net stop` / `net start` del servicio | **Desaparece como reinicio** | Solo verifica que esté en ejecución y lo inicia si está detenido |
| 6. `net use` + `xcopy` a auditoría con contraseña | **Se mantiene, sin credenciales** | Copia con la identidad de la gMSA, solo lo pendiente, verificando hash; se ejecuta **antes** de borrar |
| — | **Nuevo** | Revisión de espacio en disco con umbral, log estructurado, código de salida confiable, `-WhatIf`, bloqueo contra ejecución concurrente |

Además, la contraseña expuesta (`svc_mantenimiento`) debe **rotarse** y la cuenta deshabilitarse cuando la gMSA esté en uso.

## Cómo se probó

1. **Pester** (en Windows): `Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck` y luego `Invoke-Pester -Path .\tests -Output Detailed`.
2. **Ejecución real en PowerShell 7** con carpetas de prueba (simulación, ejecución real, segunda ejecución idempotente, copia distinta protegida, fallo de un paso → código 2). Ver `evidencias/`.
