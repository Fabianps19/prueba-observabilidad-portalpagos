<#
    Modulo de mantenimiento de WEB-PAGOS-01 (reemplaza mantenimiento_diario.bat de 2019).
    Compatible con Windows PowerShell 5.1 y PowerShell 7.
    Principios: no hace dano si algo sale mal, deja rastro (log JSON por linea), es idempotente
    y no contiene credenciales (corre con la identidad de la tarea programada, idealmente una gMSA).
#>
Set-StrictMode -Version Latest

$script:ArchivoLog = $null
$script:IdEjecucion = [guid]::NewGuid().ToString()

# ----------------------------------------------------------------------------- log estructurado
function Initialize-LogMantenimiento {
    param([Parameter(Mandatory)][string]$Ruta)
    $dir = Split-Path -Parent $Ruta
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:ArchivoLog = $Ruta
}

function Write-LogMantenimiento {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Nivel,
        [Parameter(Mandatory)][string]$Paso,
        [Parameter(Mandatory)][string]$Mensaje,
        [hashtable]$Datos = @{}
    )
    $registro = [ordered]@{
        ts        = (Get-Date).ToString('o')
        ejecucion = $script:IdEjecucion
        equipo    = $env:COMPUTERNAME
        nivel     = $Nivel
        paso      = $Paso
        mensaje   = $Mensaje
        datos     = $Datos
    }
    $linea = $registro | ConvertTo-Json -Compress -Depth 5
    if ($script:ArchivoLog) {
        # El log se escribe aun en modo -WhatIf: es la evidencia de lo que se habria hecho
        Add-Content -LiteralPath $script:ArchivoLog -Value $linea -Encoding UTF8 -WhatIf:$false
    }
    Write-Verbose $linea
}

# ----------------------------------------------------------------------------- envoltorios de IIS (se simulan en las pruebas)
function Get-RutaLogsSitio {
    <# Lee la ruta real de logs desde la configuracion de IIS en vez de recibirla fija (el .BAT apuntaba a D:, retirada el 16-sep). #>
    param([Parameter(Mandatory)][string]$Sitio)
    Import-Module WebAdministration -ErrorAction Stop
    $s = Get-Item -LiteralPath "IIS:\Sites\$Sitio" -ErrorAction Stop
    $base = [Environment]::ExpandEnvironmentVariables($s.logFile.directory)
    return (Join-Path $base ("W3SVC{0}" -f $s.id))
}

function Get-EstadoPool {
    param([Parameter(Mandatory)][string]$Pool)
    Import-Module WebAdministration -ErrorAction Stop
    return (Get-WebAppPoolState -Name $Pool -ErrorAction Stop).Value
}

function Get-MemoriaPoolMB {
    <# Suma Private Bytes de los w3wp.exe del pool indicado. #>
    param([Parameter(Mandatory)][string]$Pool)
    $procs = Get-CimInstance Win32_Process -Filter "Name='w3wp.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -match ('-ap "{0}"' -f [regex]::Escape($Pool)) }
    if (-not $procs) { return 0 }
    $total = 0
    foreach ($p in $procs) { $total += (Get-Process -Id $p.ProcessId -ErrorAction Stop).PrivateMemorySize64 }
    return [math]::Round($total / 1MB)
}

function Restart-PoolSitio {
    param([Parameter(Mandatory)][string]$Pool)
    Import-Module WebAdministration -ErrorAction Stop
    Restart-WebAppPool -Name $Pool -ErrorAction Stop
}

# ----------------------------------------------------------------------------- pasos
function Copy-LogsAuditoria {
    <#
        Copia al share de auditoria los logs que aun no esten alli (o cuya copia difiera) y verifica por hash.
        No usa credenciales: el acceso al share lo da la identidad de la tarea (gMSA con permiso de escritura).
        Idempotente: una segunda ejecucion no copia nada.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Origen,
        [Parameter(Mandatory)][string]$Destino,
        [string]$Filtro = '*.log',
        [int]$ExcluirModificadosEnMinutos = 60   # no copiar el log que IIS sigue escribiendo
    )
    if (-not (Test-Path -LiteralPath $Destino)) { throw "Destino de auditoria inaccesible: $Destino" }
    $limite = (Get-Date).AddMinutes(-$ExcluirModificadosEnMinutos)
    $copiados = 0; $omitidos = 0
    foreach ($f in Get-ChildItem -LiteralPath $Origen -Filter $Filtro -File) {
        if ($f.LastWriteTime -gt $limite) { $omitidos++; continue }
        $dst = Join-Path $Destino $f.Name
        if ((Test-Path -LiteralPath $dst) -and
            ((Get-FileHash -LiteralPath $dst).Hash -eq (Get-FileHash -LiteralPath $f.FullName).Hash)) { $omitidos++; continue }
        if ($PSCmdlet.ShouldProcess($f.FullName, "Copiar a $Destino")) {
            Copy-Item -LiteralPath $f.FullName -Destination $dst -Force -ErrorAction Stop
            if ((Get-FileHash -LiteralPath $dst).Hash -ne (Get-FileHash -LiteralPath $f.FullName).Hash) {
                throw "La copia de $($f.Name) no coincide (hash)"
            }
        }
        $copiados++
    }
    Write-LogMantenimiento INFO 'auditoria' 'Copia de logs a auditoria' @{ origen = $Origen; destino = $Destino; copiados = $copiados; omitidos = $omitidos }
    return [pscustomobject]@{ Copiados = $copiados; Omitidos = $omitidos }
}

function Remove-ArchivosAntiguos {
    <#
        Borra archivos mas viejos que -Dias. Si se indica -SoloSiExisteCopiaEn, SOLO borra los que tengan
        copia identica (hash) alli: un log nunca se borra antes de estar en auditoria.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [Parameter(Mandatory)][ValidateRange(1, 3650)][int]$Dias,
        [string]$Filtro = '*.log',
        [string]$SoloSiExisteCopiaEn
    )
    if (-not (Test-Path -LiteralPath $Ruta)) { throw "Ruta inexistente: $Ruta" }
    $limite = (Get-Date).AddDays(-$Dias)
    $borrados = 0; $protegidos = 0; $bytes = 0
    foreach ($f in Get-ChildItem -LiteralPath $Ruta -Filter $Filtro -File | Where-Object { $_.LastWriteTime -lt $limite }) {
        if ($SoloSiExisteCopiaEn) {
            $copia = Join-Path $SoloSiExisteCopiaEn $f.Name
            if (-not (Test-Path -LiteralPath $copia) -or
                (Get-FileHash -LiteralPath $copia).Hash -ne (Get-FileHash -LiteralPath $f.FullName).Hash) {
                $protegidos++
                Write-LogMantenimiento WARN 'limpieza' 'Archivo sin copia verificada: no se borra' @{ archivo = $f.FullName }
                continue
            }
        }
        if ($PSCmdlet.ShouldProcess($f.FullName, 'Eliminar')) {
            $bytes += $f.Length
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
        }
        $borrados++
    }
    Write-LogMantenimiento INFO 'limpieza' 'Limpieza por antiguedad' @{ ruta = $Ruta; dias = $Dias; borrados = $borrados; protegidos = $protegidos; mb_liberados = [math]::Round($bytes / 1MB, 1) }
    return [pscustomobject]@{ Borrados = $borrados; Protegidos = $protegidos }
}

function Test-EspacioDisco {
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [ValidateRange(1, 99)][int]$UmbralPct = 20
    )
    $raiz = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Ruta).ProviderPath)
    $d = New-Object System.IO.DriveInfo($raiz)
    $pct = [math]::Round(100 * $d.AvailableFreeSpace / $d.TotalSize, 1)
    $ok = $pct -ge $UmbralPct
    $nivel = 'INFO'; if (-not $ok) { $nivel = 'WARN' }
    Write-LogMantenimiento $nivel 'disco' 'Espacio libre' @{ unidad = $raiz; libre_pct = $pct; umbral_pct = $UmbralPct; libre_gb = [math]::Round($d.AvailableFreeSpace / 1GB, 1) }
    return [pscustomobject]@{ Unidad = $raiz; LibrePct = $pct; Ok = $ok }
}

function Invoke-ReciclajeCondicional {
    <#
        Reemplaza el iisreset nocturno a ciegas: recicla SOLO el pool indicado y SOLO si su memoria supera el umbral.
        No actua si el pool esta detenido (eso es un incidente: se escala, no se "arregla" a ciegas).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Pool,
        [Parameter(Mandatory)][ValidateRange(100, 65536)][int]$UmbralMB
    )
    $estado = Get-EstadoPool -Pool $Pool
    if ($estado -ne 'Started') {
        Write-LogMantenimiento ERROR 'pool' 'Pool no esta en ejecucion: no se recicla, requiere revision humana' @{ pool = $Pool; estado = $estado }
        return [pscustomobject]@{ Accion = 'Escalar'; Estado = $estado; MemoriaMB = $null }
    }
    $mb = Get-MemoriaPoolMB -Pool $Pool
    if ($mb -lt $UmbralMB) {
        Write-LogMantenimiento INFO 'pool' 'Memoria bajo el umbral: no se recicla' @{ pool = $Pool; memoria_mb = $mb; umbral_mb = $UmbralMB }
        return [pscustomobject]@{ Accion = 'Ninguna'; Estado = $estado; MemoriaMB = $mb }
    }
    if ($PSCmdlet.ShouldProcess($Pool, "Reciclar (memoria $mb MB >= $UmbralMB MB)")) {
        Restart-PoolSitio -Pool $Pool
    }
    Write-LogMantenimiento WARN 'pool' 'Pool reciclado por memoria (sintoma de fuga: revisar)' @{ pool = $Pool; memoria_mb = $mb; umbral_mb = $UmbralMB }
    return [pscustomobject]@{ Accion = 'Reciclado'; Estado = $estado; MemoriaMB = $mb }
}

function Assert-ServicioEnEjecucion {
    <# Reemplaza el net stop/net start incondicional: solo inicia el servicio si esta detenido. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Nombre)
    $s = Get-Service -Name $Nombre -ErrorAction Stop
    if ($s.Status -eq 'Running') {
        Write-LogMantenimiento INFO 'servicio' 'Servicio en ejecucion' @{ servicio = $Nombre }
        return 'SinCambios'
    }
    if ($PSCmdlet.ShouldProcess($Nombre, 'Iniciar servicio')) { Start-Service -Name $Nombre -ErrorAction Stop }
    Write-LogMantenimiento WARN 'servicio' 'Servicio estaba detenido y se inicio' @{ servicio = $Nombre; estado_previo = "$($s.Status)" }
    return 'Iniciado'
}

Export-ModuleMember -Function *-*
