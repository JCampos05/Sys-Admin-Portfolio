# 
# Módulo para reiniciar el servicio DNS de forma segura
# 
function Test-DNSZonesConfiguration {
    Write-InfoMessage "Validando sintaxis de zonas DNS..."
    
    $errores = 0
    $zonasValidadas = 0
    
    try {
        $zonas = Get-DnsServerZone -ErrorAction Stop | 
                Where-Object { $_.IsAutoCreated -eq $false -and $_.ZoneName -notlike "_*" }
        
        if ($zonas) {
            foreach ($zona in $zonas) {
                try {
                    # Intentar leer registros de la zona como forma de validación
                    $records = Get-DnsServerResourceRecord -ZoneName $zona.ZoneName -ErrorAction Stop
                    
                    if ($records) {
                        Write-SuccessMessage "Zona $($zona.ZoneName): VÁLIDA"
                        $zonasValidadas++
                    }
                }
                catch {
                    Write-ErrorMessage "Zona $($zona.ZoneName): INVÁLIDA"
                    Write-Host "  Error: $($_.Exception.Message)"
                    $errores++
                }
            }
            
            Write-Host ""
            Write-InfoMessage "Total de zonas validadas: $zonasValidadas"
        }
        else {
            Write-InfoMessage "No se encontraron zonas personalizadas para validar"
        }
    }
    catch {
        Write-WarningCustom "No se pudo completar la validación de zonas: $($_.Exception.Message)"
        return $false
    }
    
    if ($errores -gt 0) {
        return $false
    }
    
    return $true
}

function Invoke-ReiniciarServicio {
    Clear-Host
    Write-Header "Reiniciar Servicio DNS"
    
    # Verificar privilegios
    if (-not (Test-AdminPrivileges)) {
        return
    }
    
    Write-InfoMessage "Verificando existencia del servicio DNS..."
    
    try {
        $dnsService = Get-Service -Name "DNS" -ErrorAction Stop
        Write-SuccessMessage "Servicio DNS encontrado"
    }
    catch {
        Write-ErrorMessage "El servicio DNS no está instalado o no existe"
        return
    }
    
    Write-Host ""
    Write-SeparatorLine
    
    Write-InfoMessage "PASO 1: Validando configuración antes de reiniciar"
    Write-Host ""
    
    $configValida = Test-DNSZonesConfiguration
    
    Write-Host ""
    Write-SeparatorLine
    
    if (-not $configValida) {
        Write-ErrorMessage "Se encontraron errores en la configuración"
        Write-Host ""
        Write-WarningCustom "NO se recomienda reiniciar el servicio con errores de sintaxis"
        Write-Host ""
        
        $respuesta = Read-Host "¿Desea continuar con el reinicio de todas formas? (S/N)"
        
        if ($respuesta -ne 'S' -and $respuesta -ne 's') {
            Write-InfoMessage "Reinicio cancelado por el usuario"
            return
        }
        
        Write-Host ""
        Write-SeparatorLine
        Write-Host ""
    }
    else {
        Write-SuccessMessage "Todas las validaciones pasaron correctamente"
        Write-SeparatorLine
    }
    
    Write-InfoMessage "PASO 2: Estado actual del servicio"
    Write-Host ""
    
    $dnsService = Get-Service -Name "DNS"
    
    if ($dnsService.Status -eq 'Running') {
        Write-InfoMessage "El servicio DNS está ACTIVO"
        
        # Mostrar información básica
        $process = Get-Process -Name "dns" -ErrorAction SilentlyContinue
        if ($process) {
            Write-Host "  PID: $($process.Id)"
            Write-Host "  Memoria: $([math]::Round($process.WorkingSet64 / 1MB, 2)) MB"
            Write-Host "  Tiempo de actividad: $([math]::Round((New-TimeSpan -Start $process.StartTime).TotalHours, 2)) horas"
        }
    }
    else {
        Write-InfoMessage "El servicio DNS está INACTIVO (Estado: $($dnsService.Status))"
    }
    
    Write-SeparatorLine
    
    Write-WarningCustom "El servicio DNS se reiniciará"
    Write-Host ""
    Write-InfoMessage "Esto puede causar una breve interrupción en las consultas DNS"
    Write-Host ""
    
    $confirmar = Read-Host "¿Confirma que desea reiniciar el servicio? (S/N)"
    
    if ($confirmar -ne 'S' -and $confirmar -ne 's') {
        Write-InfoMessage "Reinicio cancelado por el usuario"
        return
    }
    
    Write-Host ""
    Write-SeparatorLine
    
    Write-InfoMessage "PASO 3: Reiniciando servicio DNS..."
    Write-Host ""
    
    try {
        Restart-Service -Name DNS -Force -ErrorAction Stop
        Write-SuccessMessage "Comando de reinicio ejecutado"
    }
    catch {
        Write-ErrorMessage "Error al ejecutar comando de reinicio: $($_.Exception.Message)"
        Write-Host ""
        Write-ErrorMessage "Detalles del error:"
        Write-Host "  $($_.Exception.Message)"
        return
    }
    
    # Esperar a que el servicio se estabilice
    Start-Sleep -Seconds 3
    
    Write-Host ""
    Write-SeparatorLine
    
    Write-InfoMessage "PASO 4: Verificando estado post-reinicio"
    Write-Host ""
    
    $dnsService = Get-Service -Name "DNS"
    
    if ($dnsService.Status -eq 'Running') {
        Write-SuccessMessage "Servicio DNS: ACTIVO"
        
        # Mostrar información actualizada
        $process = Get-Process -Name "dns" -ErrorAction SilentlyContinue
        if ($process) {
            Write-Host "  Nuevo PID: $($process.Id)"
            Write-Host "  Memoria: $([math]::Round($process.WorkingSet64 / 1MB, 2)) MB"
        }
        
        # Verificar puertos
        Write-Host ""
        Start-Sleep -Seconds 2
        
        $tcpPort = Get-NetTCPConnection -LocalPort 53 -State Listen -ErrorAction SilentlyContinue
        if ($tcpPort) {
            Write-SuccessMessage "Puerto 53/TCP: ESCUCHANDO"
        }
        else {
            Write-WarningCustom "Puerto 53/TCP: NO escuchando"
        }
        
        $udpPort = Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue
        if ($udpPort) {
            Write-SuccessMessage "Puerto 53/UDP: ESCUCHANDO"
        }
        else {
            Write-WarningCustom "Puerto 53/UDP: NO escuchando"
        }
        
        Write-Host ""
        Write-SeparatorLine
        
        Write-SuccessMessage "REINICIO COMPLETADO EXITOSAMENTE"
    }
    else {
        Write-ErrorMessage "Servicio DNS: NO se inició correctamente"
        Write-Host "  Estado actual: $($dnsService.Status)"
        Write-Host ""
        Write-ErrorMessage "Revise el Visor de eventos de Windows para más detalles"
        Write-Host "  Ruta: Aplicaciones y servicios > DNS Server"
        return
    }
    
    Write-Host ""
    
    Write-InfoMessage "Eventos recientes del servicio (últimas 5 entradas):"
    Write-Host ""
    
    try {
        $eventos = Get-WinEvent -LogName "DNS Server" -MaxEvents 5 -ErrorAction SilentlyContinue | 
                  Select-Object TimeCreated, Id, LevelDisplayName, Message
        
        if ($eventos) {
            foreach ($evento in $eventos) {
                $nivel = switch ($evento.LevelDisplayName) {
                    "Error" { Write-Host "  [$($evento.TimeCreated.ToString('HH:mm:ss'))] ERROR" -ForegroundColor Red -NoNewline }
                    "Warning" { Write-Host "  [$($evento.TimeCreated.ToString('HH:mm:ss'))] WARNING" -ForegroundColor Yellow -NoNewline }
                    default { Write-Host "  [$($evento.TimeCreated.ToString('HH:mm:ss'))] INFO" -ForegroundColor Cyan -NoNewline }
                }
                Write-Host " - ID: $($evento.Id)"
                
                # Mostrar primeras líneas del mensaje
                $mensajeCorto = ($evento.Message -split "`n" | Select-Object -First 2) -join " "
                if ($mensajeCorto.Length -gt 80) {
                    $mensajeCorto = $mensajeCorto.Substring(0, 80) + "..."
                }
                Write-Host "      $mensajeCorto"
                Write-Host ""
            }
        }
        else {
            Write-InfoMessage "No hay eventos recientes disponibles"
        }
    }
    catch {
        Write-InfoMessage "No se pudo acceder al registro de eventos DNS"
    }
    
    Write-Host ""
}

# Ejecutar si se llama directamente
if ($MyInvocation.InvocationName -ne '.') {
    # Cargar utilidades si no están cargadas
    if (-not (Get-Command Write-InfoMessage -ErrorAction SilentlyContinue)) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        . (Join-Path $scriptDir "utils.ps1")
    }
    
    # Verificar privilegios
    if (-not (Test-AdminPrivileges)) {
        Invoke-Pause
        exit 1
    }
    
    Invoke-ReiniciarServicio
    Invoke-Pause
}