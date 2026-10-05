<#
.SYNOPSIS
    Runbook de Azure Automation (PowerShell 7.2, identidad administrada): reinicia el pool de IIS cuando la
    ALERTA C (WAS 5002, pool deshabilitado) lo dispara via webhook del Action Group.

.DESCRIPTION
    Salvaguardas:
      1. Solo actua para la alerta y el pool permitidos, y solo si la alerta esta "Fired".
      2. No actua si la VM tiene la etiqueta ventana-mantenimiento = true.
      3. No actua si la VM no reporta Heartbeat en los ultimos 5 min (el problema no es el pool: escalar).
      4. Maximo 2 intentos por VM en 60 minutos; al tercero escala sin actuar (evita reinicios en bucle).
      5. Verifica el resultado (estado del pool + peticion HTTP local) y escala si no se recupero.
    Trazabilidad: cada decision se escribe como JSON en la salida del job (enviada a Log Analytics por
    configuracion de diagnostico de la cuenta de Automation: tabla AzureDiagnostics, categoria JobStreams).
    Sin secretos en el codigo: identidad administrada para Azure; la URL del webhook de escalamiento es una
    variable cifrada de Automation.
    Estado: DISENO. No se desplego en Azure por tiempo (ver README).
#>
param([object]$WebhookData)

$ErrorActionPreference = 'Stop'
$PoolPermitido   = 'PortalPagosPool'
$AlertaPermitida = 'PortalPagos-pool-detenido'
$MaxIntentos     = 2
$VentanaMinutos  = 60

function Write-Traza([string]$Decision, [hashtable]$Datos = @{}) {
    Write-Output (@{ ts = (Get-Date).ToUniversalTime().ToString('o'); runbook = 'Restaurar-PoolPortal'; decision = $Decision; datos = $Datos } | ConvertTo-Json -Compress -Depth 5)
}
function Send-Escalamiento([string]$Motivo, [hashtable]$Datos) {
    $url = Get-AutomationVariable -Name 'TeamsWebhookNOC'   # variable cifrada, no en el codigo
    $texto = "Auto-remediacion PortalPagos NO resolvio o NO actuo: $Motivo. Datos: $($Datos | ConvertTo-Json -Compress). Requiere una persona."
    Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/json' -Body (@{ text = $texto } | ConvertTo-Json)
    Write-Traza 'escalado' (@{ motivo = $Motivo } + $Datos)
}

# --- 1. Validar la alerta recibida ---------------------------------------------------------
if (-not $WebhookData) { throw 'Este runbook solo se ejecuta desde la alerta (webhook).' }
$alerta = (ConvertFrom-Json $WebhookData.RequestBody).data
$ess = $alerta.essentials
if ($ess.alertRule -ne $AlertaPermitida -or $ess.monitorCondition -ne 'Fired') {
    Write-Traza 'ignorado' @{ regla = $ess.alertRule; condicion = $ess.monitorCondition }; return
}
$vmId = $ess.alertTargetIDs[0]
$partes = $vmId -split '/'
$rg, $vm = $partes[4], $partes[-1]

Connect-AzAccount -Identity | Out-Null

# --- 2. Ventana de mantenimiento ----------------------------------------------------------
$vmObj = Get-AzVM -ResourceGroupName $rg -Name $vm
if ($vmObj.Tags['ventana-mantenimiento'] -eq 'true') { Write-Traza 'no_actua_mantenimiento' @{ vm = $vm }; return }

# --- 3. La VM debe estar viva (si no, no es un problema del pool) ------------------------
$ws = Get-AutomationVariable -Name 'LogAnalyticsWorkspaceId'
$hb = Invoke-AzOperationalInsightsQuery -WorkspaceId $ws -Query "Heartbeat | where TimeGenerated > ago(5m) and Computer startswith '$vm' | count"
if ([int]$hb.Results[0].Count -eq 0) { Send-Escalamiento 'La VM no reporta heartbeat' @{ vm = $vm }; return }

# --- 4. Limite de intentos (evita bucles de reinicio) ------------------------------------
$registro = @(Get-AutomationVariable -Name 'RemediacionIntentos' | ConvertFrom-Json)
$recientes = @($registro | Where-Object { $_.vm -eq $vm -and [datetime]$_.ts -gt (Get-Date).ToUniversalTime().AddMinutes(-$VentanaMinutos) })
if ($recientes.Count -ge $MaxIntentos) {
    Send-Escalamiento "Limite de $MaxIntentos intentos en $VentanaMinutos min alcanzado" @{ vm = $vm; intentos = $recientes.Count }; return
}
$registro += [pscustomobject]@{ vm = $vm; ts = (Get-Date).ToUniversalTime().ToString('o') }
Set-AutomationVariable -Name 'RemediacionIntentos' -Value ($registro | Select-Object -Last 50 | ConvertTo-Json -Compress)

# --- 5. Actuar: iniciar SOLO el pool (nunca iisreset ni reinicio de la VM) y verificar -----
$script = @"
Import-Module WebAdministration
`$antes = (Get-WebAppPoolState -Name '$PoolPermitido').Value
if (`$antes -ne 'Started') { Start-WebAppPool -Name '$PoolPermitido' }
Start-Sleep -Seconds 20
`$despues = (Get-WebAppPoolState -Name '$PoolPermitido').Value
try { `$http = (Invoke-WebRequest -UseBasicParsing -Uri 'http://localhost/' -TimeoutSec 15).StatusCode } catch { `$http = 0 }
@{ antes = `$antes; despues = `$despues; http = `$http } | ConvertTo-Json -Compress
"@
Write-Traza 'actuando' @{ vm = $vm; pool = $PoolPermitido; intento = $recientes.Count + 1 }
$r = Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $vm -CommandId 'RunPowerShellScript' -ScriptString $script
$res = $r.Value[0].Message | ConvertFrom-Json

if ($res.despues -eq 'Started' -and $res.http -eq 200) {
    Write-Traza 'recuperado' @{ vm = $vm; antes = $res.antes; despues = $res.despues; http = $res.http }
} else {
    Send-Escalamiento 'El pool no se recupero tras la accion' @{ vm = $vm; antes = $res.antes; despues = $res.despues; http = $res.http }
}
