<#
.SYNOPSIS
  Runbook de Azure Automation (Windows PowerShell 5.1) que remedia PortalPagos cuando
  la alerta "E-remediacion-5xx" se dispara. Se invoca por webhook desde el Action Group.

  Salvaguardas:
   - Solo actua para la regla y el recurso permitidos (variable AppPermitida).
   - Cuando NO actuar: ventana de mantenimiento (etiqueta ventana-mantenimiento=true),
     health check ya en 200 (se recupero solo), reinicio hace menos de 5 min (enfriamiento).
   - Limite de intentos: MaxReiniciosHora reinicios en 60 min; al superarlo ESCALA y no reinicia.
   - Modo sugerir (variable ModoRemediacion): registra la accion sin ejecutarla.
   - Verifica el resultado; si no se recupera, ESCALA.
  Trazabilidad: cada decision se escribe como "REMEDIACION {json}" en la salida del job
  (JobStreams -> Log Analytics). Escalar = el job termina en error con "ESCALAR" y la
  alerta F-escalamiento avisa por correo a una persona.
  Sin secretos: usa la identidad administrada de la cuenta de Automation (solo REST, sin modulos).
#>
param([object]$WebhookData)
$ErrorActionPreference = 'Stop'
$api = 'api-version=2023-12-01'

function Registrar([string]$decision, [string]$detalle) {
    $o = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); decision = $decision; detalle = $detalle }
    Write-Output ('REMEDIACION ' + ($o | ConvertTo-Json -Compress))
}
function Obtener-Token {
    $uri = "$($env:IDENTITY_ENDPOINT)?resource=https://management.azure.com/&api-version=2019-08-01"
    (Invoke-RestMethod -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; 'Metadata' = 'true' }).access_token
}
function Probar-Salud([string]$url) {
    try { return [int](Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15).StatusCode }
    catch { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } else { return 0 } }
}

if (-not $WebhookData) { Registrar 'NO_ACTUA' 'Ejecucion sin datos de alerta'; return }
$alerta = ($WebhookData.RequestBody | ConvertFrom-Json).data.essentials
$appId = [string](Get-AutomationVariable -Name 'AppPermitida')
if ($alerta.alertRule -ne 'E-remediacion-5xx' -or $alerta.monitorCondition -ne 'Fired') {
    Registrar 'NO_ACTUA' "Alerta fuera del escenario: $($alerta.alertRule) / $($alerta.monitorCondition)"; return
}

$h = @{ Authorization = "Bearer $(Obtener-Token)" }
$app = Invoke-RestMethod -Uri "https://management.azure.com$($appId)?$api" -Headers $h
if ($app.tags.'ventana-mantenimiento' -eq 'true') { Registrar 'NO_ACTUA' 'Ventana de mantenimiento activa'; return }

$url = "https://$($app.properties.defaultHostName)/salud.aspx"
$salud = Probar-Salud $url
if ($salud -eq 200) { Registrar 'NO_ACTUA' 'El health check ya responde 200 (se recupero o la alerta mira una ventana pasada)'; return }

$ahora = (Get-Date).ToUniversalTime()
$hist = @()
$raw = [string](Get-AutomationVariable -Name 'ReiniciosPortal')
if ($raw) { $hist = @($raw | ConvertFrom-Json) }
$recientes = @($hist | Where-Object { $_ -and [DateTimeOffset]::Parse($_).UtcDateTime -gt $ahora.AddMinutes(-60) })
$ultimo = $recientes | ForEach-Object { [DateTimeOffset]::Parse($_).UtcDateTime } | Sort-Object | Select-Object -Last 1
if ($ultimo -and $ultimo -gt $ahora.AddMinutes(-5)) {
    Registrar 'NO_ACTUA' "Enfriamiento: hubo un reinicio a las $($ultimo.ToString('HH:mm:ss'))Z; se espera su efecto"; return
}
$max = [int](Get-AutomationVariable -Name 'MaxReiniciosHora')
if ($recientes.Count -ge $max) {
    Registrar 'ESCALAR' "Ya hubo $($recientes.Count) reinicios en 60 min (limite $max). No se reinicia: la falla vuelve, requiere una persona (posible fuga activa)"
    throw 'ESCALAR: limite de reinicios alcanzado'
}
$modo = [string](Get-AutomationVariable -Name 'ModoRemediacion')
if ($modo -ne 'automatico') { Registrar 'SUGERIR' "Health=$salud. Accion sugerida: reiniciar $($app.name). Modo sugerir: no se ejecuta"; return }

Registrar 'ACTUA' "Health=$salud. Reinicio de $($app.name), intento $($recientes.Count + 1) de $max en 60 min"
Invoke-RestMethod -Method Post -Uri "https://management.azure.com$($appId)/restart?$api" -Headers $h | Out-Null
$recientes += $ahora.ToString('o')
Set-AutomationVariable -Name 'ReiniciosPortal' -Value (ConvertTo-Json -InputObject @($recientes) -Compress)

foreach ($i in 1..8) {
    Start-Sleep -Seconds 15
    $salud = Probar-Salud $url
    if ($salud -eq 200) { Registrar 'RECUPERADO' "Health check 200 a los $($i * 15) s del reinicio"; return }
}
Registrar 'ESCALAR' "El reinicio no recupero el servicio (health=$salud)"
throw 'ESCALAR: reinicio sin recuperacion'
