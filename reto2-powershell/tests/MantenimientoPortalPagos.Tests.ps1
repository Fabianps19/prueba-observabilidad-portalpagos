# Pester 5.  Ejecutar:  Invoke-Pester -Path .\tests -Output Detailed
BeforeAll {
    $modulo = Join-Path $PSScriptRoot '..\src\MantenimientoPortalPagos.psm1'
    Import-Module $modulo -Force
    Initialize-LogMantenimiento -Ruta (Join-Path $TestDrive 'log.jsonl')

    function New-ArchivoViejo([string]$Ruta, [int]$Dias, [string]$Contenido = 'x') {
        Set-Content -LiteralPath $Ruta -Value $Contenido
        (Get-Item -LiteralPath $Ruta).LastWriteTime = (Get-Date).AddDays(-$Dias)
    }
}

Describe 'Remove-ArchivosAntiguos' {
    BeforeEach {
        $logs = Join-Path $TestDrive ([guid]::NewGuid()); $aud = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $logs, $aud | Out-Null
        New-ArchivoViejo (Join-Path $logs 'viejo.log') 10 'A'
        New-ArchivoViejo (Join-Path $logs 'nuevo.log') 1 'B'
    }
    It 'con -WhatIf no borra nada' {
        Remove-ArchivosAntiguos -Ruta $logs -Dias 7 -WhatIf | Out-Null
        (Get-ChildItem $logs).Count | Should -Be 2
    }
    It 'no borra un log viejo que no tiene copia en auditoria' {
        $r = Remove-ArchivosAntiguos -Ruta $logs -Dias 7 -SoloSiExisteCopiaEn $aud
        $r.Protegidos | Should -Be 1
        Test-Path (Join-Path $logs 'viejo.log') | Should -BeTrue
    }
    It 'no borra si la copia en auditoria es distinta (hash)' {
        Set-Content (Join-Path $aud 'viejo.log') 'OTRO'
        Remove-ArchivosAntiguos -Ruta $logs -Dias 7 -SoloSiExisteCopiaEn $aud | Out-Null
        Test-Path (Join-Path $logs 'viejo.log') | Should -BeTrue
    }
    It 'borra solo lo viejo con copia verificada y es idempotente' {
        Copy-Item (Join-Path $logs 'viejo.log') $aud
        (Remove-ArchivosAntiguos -Ruta $logs -Dias 7 -SoloSiExisteCopiaEn $aud).Borrados | Should -Be 1
        (Remove-ArchivosAntiguos -Ruta $logs -Dias 7 -SoloSiExisteCopiaEn $aud).Borrados | Should -Be 0
        Test-Path (Join-Path $logs 'nuevo.log') | Should -BeTrue
    }
    It 'falla con error claro si la ruta no existe (no opera sobre otra carpeta)' {
        { Remove-ArchivosAntiguos -Ruta (Join-Path $TestDrive 'no-existe') -Dias 7 } | Should -Throw '*inexistente*'
    }
}

Describe 'Copy-LogsAuditoria' {
    BeforeEach {
        $logs = Join-Path $TestDrive ([guid]::NewGuid()); $aud = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $logs, $aud | Out-Null
        New-ArchivoViejo (Join-Path $logs 'a.log') 2
        Set-Content (Join-Path $logs 'en-uso.log') 'IIS escribiendo'
    }
    It 'copia lo pendiente, omite el log en uso y no repite en la segunda ejecucion' {
        (Copy-LogsAuditoria -Origen $logs -Destino $aud).Copiados | Should -Be 1
        Test-Path (Join-Path $aud 'en-uso.log') | Should -BeFalse
        (Copy-LogsAuditoria -Origen $logs -Destino $aud).Copiados | Should -Be 0
    }
    It 'falla si el destino de auditoria no es accesible' {
        { Copy-LogsAuditoria -Origen $logs -Destino (Join-Path $TestDrive 'share-caido') } | Should -Throw '*inaccesible*'
    }
}

Describe 'Invoke-ReciclajeCondicional' {
    It 'no recicla si la memoria esta bajo el umbral' {
        Mock -ModuleName MantenimientoPortalPagos Get-EstadoPool { 'Started' }
        Mock -ModuleName MantenimientoPortalPagos Get-MemoriaPoolMB { 400 }
        Mock -ModuleName MantenimientoPortalPagos Restart-PoolSitio { }
        (Invoke-ReciclajeCondicional -Pool 'P' -UmbralMB 1000).Accion | Should -Be 'Ninguna'
        Should -Invoke -ModuleName MantenimientoPortalPagos Restart-PoolSitio -Times 0
    }
    It 'recicla solo el pool (no iisreset) si supera el umbral' {
        Mock -ModuleName MantenimientoPortalPagos Get-EstadoPool { 'Started' }
        Mock -ModuleName MantenimientoPortalPagos Get-MemoriaPoolMB { 1400 }
        Mock -ModuleName MantenimientoPortalPagos Restart-PoolSitio { }
        (Invoke-ReciclajeCondicional -Pool 'P' -UmbralMB 1000).Accion | Should -Be 'Reciclado'
        Should -Invoke -ModuleName MantenimientoPortalPagos Restart-PoolSitio -Times 1 -ParameterFilter { $Pool -eq 'P' }
    }
    It 'con -WhatIf no recicla' {
        Mock -ModuleName MantenimientoPortalPagos Get-EstadoPool { 'Started' }
        Mock -ModuleName MantenimientoPortalPagos Get-MemoriaPoolMB { 1400 }
        Mock -ModuleName MantenimientoPortalPagos Restart-PoolSitio { }
        Invoke-ReciclajeCondicional -Pool 'P' -UmbralMB 1000 -WhatIf | Out-Null
        Should -Invoke -ModuleName MantenimientoPortalPagos Restart-PoolSitio -Times 0
    }
    It 'si el pool esta detenido no actua y pide escalar' {
        Mock -ModuleName MantenimientoPortalPagos Get-EstadoPool { 'Stopped' }
        Mock -ModuleName MantenimientoPortalPagos Restart-PoolSitio { }
        (Invoke-ReciclajeCondicional -Pool 'P' -UmbralMB 1000).Accion | Should -Be 'Escalar'
        Should -Invoke -ModuleName MantenimientoPortalPagos Restart-PoolSitio -Times 0
    }
}

Describe 'Assert-ServicioEnEjecucion' {
    It 'no reinicia un servicio que ya esta en ejecucion' {
        Mock -ModuleName MantenimientoPortalPagos Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock -ModuleName MantenimientoPortalPagos Start-Service { }
        Assert-ServicioEnEjecucion -Nombre 'S' | Should -Be 'SinCambios'
        Should -Invoke -ModuleName MantenimientoPortalPagos Start-Service -Times 0
    }
    It 'inicia el servicio solo si esta detenido' {
        Mock -ModuleName MantenimientoPortalPagos Get-Service { [pscustomobject]@{ Status = 'Stopped' } }
        Mock -ModuleName MantenimientoPortalPagos Start-Service { }
        Assert-ServicioEnEjecucion -Nombre 'S' | Should -Be 'Iniciado'
        Should -Invoke -ModuleName MantenimientoPortalPagos Start-Service -Times 1
    }
}

Describe 'Script principal' {
    BeforeAll { $script = Join-Path $PSScriptRoot '..\Invoke-MantenimientoPortalPagos.ps1' }
    It 'no contiene credenciales ni comandos peligrosos del .BAT' {
        $texto = Get-Content $script, (Join-Path $PSScriptRoot '..\src\MantenimientoPortalPagos.psm1') -Raw
        # se buscan como comandos (inicio de linea), no en comentarios que explican por que se eliminaron
        $texto | Should -Not -Match '(?m)^\s*iisreset'
        $texto | Should -Not -Match '(?m)^\s*net\s+(use|stop)'
        $texto | Should -Not -Match '(?i)password\s*='
        $texto | Should -Not -Match 'ConvertTo-SecureString'
    }
    It 'rechaza una ruta de auditoria inexistente (validacion de parametros)' {
        { & $script -RutaAuditoria (Join-Path $TestDrive 'no-existe') -WhatIf } | Should -Throw
    }
}
