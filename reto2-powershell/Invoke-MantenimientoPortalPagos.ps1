<#
.SYNOPSIS
    Mantenimiento diario de WEB-PAGOS-01 (reemplaza scripts\mantenimiento_diario.bat de 2019).

.DESCRIPTION
    Pasos (cada uno aislado: si uno falla, los demas se ejecutan y el codigo de salida lo refleja):
      1. Copia a auditoria los logs de IIS que falten, verificando hash.
      2. Borra logs viejos SOLO si ya tienen copia verificada en auditoria.
      3. Borra volcados de memoria viejos (los recientes se conservan: son evidencia).
      4. Revisa el espacio en disco.
      5. Recicla el pool SOLO si su memoria supera el umbral (nunca iisreset).
      6. Verifica que el servicio de notificaciones este en ejecucion (lo inicia solo si esta detenido).

    No contiene credenciales: la tarea programada debe ejecutarse con una gMSA con permiso de
    escritura en el share de auditoria.

.EXAMPLE
    .\Invoke-MantenimientoPortalPagos.ps1 -RutaAuditoria '\\fs-auditoria\logs$\WEB-PAGOS-01' -WhatIf
    Simulacion: registra en el log lo que haria, sin cambiar nada.

.NOTES
    Codigos de salida: 0 = OK, 1 = OK con advertencias, 2 = al menos un paso fallo, 3 = otra ejecucion en curso.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()][string]$Sitio = 'PortalPagos',
    [ValidateNotNullOrEmpty()][string]$Pool = 'PortalPagosPool',

    # Si no se indica, se lee de la configuracion de IIS (evita rutas fijas como la D: retirada)
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$RutaLogsIIS,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$RutaAuditoria,

    [ValidateRange(1, 365)][int]$DiasRetencionLogs = 7,

    [ValidateNotNullOrEmpty()][string]$RutaVolcados = 'C:\CrashDumps',
    [ValidateRange(1, 365)][int]$DiasRetencionVolcados = 14,

    [ValidateRange(1, 99)][int]$UmbralDiscoPct = 20,

    # 0 = no reciclar nunca (solo informar). Recomendado: ~1000 MB mientras se corrige la fuga.
    [ValidateRange(0, 65536)][int]$UmbralReciclajeMB = 0,

    [string]$ServicioNotificaciones = 'Servicio Notificaciones',

    [ValidateNotNullOrEmpty()][string]$RutaLog = (Join-Path $env:ProgramData 'MantenimientoPortalPagos\mantenimiento.jsonl')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\MantenimientoPortalPagos.psm1') -Force
Initialize-LogMantenimiento -Ruta $RutaLog

# Evita ejecuciones simultaneas (p. ej. tarea programada + ejecucion manual)
$mutex = New-Object System.Threading.Mutex($false, 'Global\MantenimientoPortalPagos')
if (-not $mutex.WaitOne(0)) {
    Write-LogMantenimiento WARN 'inicio' 'Otra ejecucion en curso: se cancela esta'
    exit 3
}

$resultado = @{ errores = 0; advertencias = 0 }
# IMPORTANTE: -WhatIf NO se propaga solo a las funciones de un modulo (scope distinto).
# Se pasa explicitamente a cada paso que cambia algo; sin esto la "simulacion" copiaria y borraria de verdad.
$sim = @{ WhatIf = [bool]$WhatIfPreference }
function Invoke-Paso {
    param([string]$Nombre, [scriptblock]$Accion)
    try { & $Accion }
    catch {
        $resultado.errores++
        Write-LogMantenimiento ERROR $Nombre $_.Exception.Message @{ linea = $_.InvocationInfo.ScriptLineNumber }
    }
}

try {
    Write-LogMantenimiento INFO 'inicio' 'Inicio de mantenimiento' @{ simulacion = [bool]$WhatIfPreference; sitio = $Sitio; pool = $Pool }

    Invoke-Paso 'rutas' {
        if (-not $RutaLogsIIS) { $script:RutaLogsIIS = Get-RutaLogsSitio -Sitio $Sitio }
        if (-not (Test-Path -LiteralPath $script:RutaLogsIIS)) { throw "Ruta de logs de IIS inexistente: $script:RutaLogsIIS" }
    }
    if ($script:RutaLogsIIS -and (Test-Path -LiteralPath $script:RutaLogsIIS)) {
        Invoke-Paso 'auditoria' { Copy-LogsAuditoria -Origen $script:RutaLogsIIS -Destino $RutaAuditoria @sim | Out-Null }
        Invoke-Paso 'limpieza'  {
            $r = Remove-ArchivosAntiguos -Ruta $script:RutaLogsIIS -Dias $DiasRetencionLogs -SoloSiExisteCopiaEn $RutaAuditoria @sim
            if ($r.Protegidos -gt 0) { $resultado.advertencias++ }
        }
    }
    Invoke-Paso 'volcados' {
        if (Test-Path -LiteralPath $RutaVolcados) {
            Remove-ArchivosAntiguos -Ruta $RutaVolcados -Dias $DiasRetencionVolcados -Filtro '*.dmp' @sim | Out-Null
        } else { Write-LogMantenimiento INFO 'volcados' 'No existe la carpeta de volcados' @{ ruta = $RutaVolcados } }
    }
    Invoke-Paso 'disco' {
        $d = Test-EspacioDisco -Ruta $env:SystemDrive\ -UmbralPct $UmbralDiscoPct
        if (-not $d.Ok) { $resultado.advertencias++ }
    }
    Invoke-Paso 'pool' {
        if ($UmbralReciclajeMB -gt 0) {
            $p = Invoke-ReciclajeCondicional -Pool $Pool -UmbralMB $UmbralReciclajeMB @sim
            if ($p.Accion -eq 'Escalar') { $resultado.errores++ } elseif ($p.Accion -eq 'Reciclado') { $resultado.advertencias++ }
        } else { Write-LogMantenimiento INFO 'pool' 'Reciclaje deshabilitado (UmbralReciclajeMB = 0)' }
    }
    Invoke-Paso 'servicio' {
        if ((Assert-ServicioEnEjecucion -Nombre $ServicioNotificaciones @sim) -eq 'Iniciado') { $resultado.advertencias++ }
    }
}
finally {
    $codigo = 0
    if ($resultado.advertencias -gt 0) { $codigo = 1 }
    if ($resultado.errores -gt 0) { $codigo = 2 }
    Write-LogMantenimiento INFO 'fin' 'Fin de mantenimiento' @{ codigo_salida = $codigo; errores = $resultado.errores; advertencias = $resultado.advertencias }
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
exit $codigo
