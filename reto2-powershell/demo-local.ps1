<#
    Demostracion reproducible en cualquier Windows (no requiere IIS):
    crea carpetas de prueba en %TEMP%, ejecuta el mantenimiento en simulacion, real y por segunda vez,
    y deja la evidencia en ..\evidencias\reto2\.
    Uso:  .\demo-local.ps1
#>
$ErrorActionPreference = 'Stop'
$base = Join-Path ([IO.Path]::GetTempPath()) 'demo-mantenimiento'
if (Test-Path $base) { Remove-Item $base -Recurse -Force }
$logs = New-Item -ItemType Directory (Join-Path $base 'W3SVC2')
$aud  = New-Item -ItemType Directory (Join-Path $base 'auditoria')
$dmp  = New-Item -ItemType Directory (Join-Path $base 'CrashDumps')
foreach ($d in 10, 9, 8) {
    $f = Join-Path $logs ("u_ex2609{0:00}.log" -f (20 - $d)); Set-Content $f "log de hace $d dias"
    (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-$d)
}
Set-Content (Join-Path $logs 'u_ex260920.log') 'log de hoy (IIS lo esta escribiendo)'
Set-Content (Join-Path $dmp 'w3wp.viejo.dmp') 'x'; (Get-Item (Join-Path $dmp 'w3wp.viejo.dmp')).LastWriteTime = (Get-Date).AddDays(-30)
Set-Content (Join-Path $dmp 'w3wp.reciente.dmp') 'x'

$evid = Join-Path $PSScriptRoot '..\evidencias\reto2'
New-Item -ItemType Directory $evid -Force | Out-Null
$log = Join-Path $evid 'mantenimiento-demo.jsonl'; if (Test-Path $log) { Remove-Item $log }
$script = Join-Path $PSScriptRoot 'Invoke-MantenimientoPortalPagos.ps1'
$comun = @{ RutaLogsIIS = "$logs"; RutaAuditoria = "$aud"; RutaVolcados = "$dmp"; RutaLog = $log; ServicioNotificaciones = 'Spooler' }

$resumen = @()
function Foto([string]$Momento) {
    "== $Momento"
    "   logs:      " + ((Get-ChildItem $logs).Name -join ', ')
    "   auditoria: " + ((Get-ChildItem $aud).Name -join ', ')
    "   volcados:  " + ((Get-ChildItem $dmp).Name -join ', ')
}
$resumen += Foto 'Estado inicial'
& $script @comun -WhatIf | Out-Null;  $resumen += "   [simulacion] codigo de salida: $LASTEXITCODE"; $resumen += Foto 'Tras -WhatIf (no debe cambiar nada)'
& $script @comun | Out-Null;          $resumen += "   [real] codigo de salida: $LASTEXITCODE";       $resumen += Foto 'Tras ejecucion real'
& $script @comun | Out-Null;          $resumen += "   [repeticion] codigo de salida: $LASTEXITCODE"; $resumen += Foto 'Tras segunda ejecucion (idempotente)'
$resumen | Tee-Object -FilePath (Join-Path $evid 'resumen-demo.txt')
"Log estructurado: $log"
