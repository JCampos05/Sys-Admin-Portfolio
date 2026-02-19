# 
#
# Módulo para verificar la instalación y configuración del servicio DNS
# 
#
<#
    Verifica la instalación completa del servicio DNS en Windows Server
    Realiza verificaciones exhaustivas de:
    - Rol DNS instalado
    - Servicio DNS activo
    - Puertos en escucha
    - Configuración de firewall
    - Configuración de red
    - Zonas DNS configuradas
#>
function Invoke-VerificarInstalacion {
    Clear-Host
    Write-Header "Verificación de Instalación DNS"
    
    $errores = 0
    $advertencias = 0
    
    Write-InfoMessage "Verificando instalación del Rol DNS..."
    Write-Host ""
    
    if (Test-WindowsFeatureInstalled -FeatureName "DNS") {
        $dnsFeature = Get-WindowsFeature -Name DNS
        Write-SuccessMessage "Rol DNS instalado: $($dnsFeature.DisplayName)"
        
        # Verificar herramientas de administración
        if (Test-WindowsFeatureInstalled -FeatureName "RSAT-DNS-Server") {
            Write-SuccessMessage "Herramientas de administración DNS: Instaladas"
        }
        else {
            Write-WarningCustom "Herramientas de administración DNS: NO instaladas"
            $advertencias++
        }
    }
    else {
        Write-ErrorMessage "Rol DNS NO está instalado"
        $errores++
    }
    
    Write-Host ""
    Write-SeparatorLine

    Write-InfoMessage "Verificando estado del servicio DNS..."
    Write-Host ""
    
    try {
        $dnsService = Get-Service -Name "DNS" -ErrorAction Stop
        
        if ($dnsService.Status -eq 'Running') {
            Write-SuccessMessage "Servicio DNS: ACTIVO"
            Write-Host "  Estado: $($dnsService.Status)"
            Write-Host "  Tipo de inicio: $($dnsService.StartType)"
            
            # Obtener información del proceso
            $process = Get-Process -Name "dns" -ErrorAction SilentlyContinue
            if ($process) {
                Write-Host "  PID: $($process.Id)"
                Write-Host "  Memoria: $([math]::Round($process.WorkingSet64 / 1MB, 2)) MB"
            }
        }
        else {
            Write-ErrorMessage "Servicio DNS: INACTIVO (Estado: $($dnsService.Status))"
            $errores++
        }
        
        if ($dnsService.StartType -eq 'Automatic') {
            Write-Host "  Inicio automático: HABILITADO"
        }
        else {
            Write-WarningCustom "  Inicio automático: DESHABILITADO"
            $advertencias++
        }
    }
    catch {
        Write-ErrorMessage "No se pudo obtener información del servicio DNS"
        $errores++
    }
    
    Write-Host ""
    Write-SeparatorLine
    
    Write-InfoMessage "Verificando puertos en escucha..."
    Write-Host ""
    
    # Puerto 53 TCP
    $tcpPort = Get-NetTCPConnection -LocalPort 53 -State Listen -ErrorAction SilentlyContinue
    if ($tcpPort) {
        Write-SuccessMessage "Puerto 53/TCP: ESCUCHANDO"
        $tcpPort | ForEach-Object {
            Write-Host "  $($_.LocalAddress):$($_.LocalPort)"
        }
    }
    else {
        Write-WarningCustom "Puerto 53/TCP: NO escuchando"
        $advertencias++
    }
    
    Write-Host ""
    
    # Puerto 53 UDP
    $udpPort = Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue
    if ($udpPort) {
        Write-SuccessMessage "Puerto 53/UDP: ESCUCHANDO"
        $udpPort | Select-Object -First 3 | ForEach-Object {
            Write-Host "  $($_.LocalAddress):$($_.LocalPort)"
        }
    }
    else {
        Write-WarningCustom "Puerto 53/UDP: NO escuchando"
        $advertencias++
    }
    
    Write-Host ""
    Write-SeparatorLine
    
    Write-InfoMessage "Verificando configuración de firewall..."
    Write-Host ""
    
    if (Test-WindowsFirewallActive) {
        Write-SuccessMessage "Firewall de Windows: ACTIVO"
        
        # Verificar reglas DNS
        $dnsRules = Get-NetFirewallRule | 
                   Where-Object { $_.DisplayName -like "*DNS*" -and $_.Enabled -eq $true }
        
        if ($dnsRules) {
            Write-SuccessMessage "Reglas DNS en firewall: CONFIGURADAS"
            $dnsRules | Select-Object -First 3 | ForEach-Object {
                Write-Host "  - $($_.DisplayName)"
            }
        }
        else {
            Write-WarningCustom "Reglas DNS en firewall: NO configuradas"
            Write-Host "  Puede ser necesario crear reglas manualmente"
            $advertencias++
        }
    }
    else {
        Write-WarningCustom "Firewall de Windows: INACTIVO"
        $advertencias++
    }
    
    Write-Host ""
    Write-SeparatorLine
    
    Write-InfoMessage "Verificando configuración de red..."
    Write-Host ""
    
    # Detectar cualquier interfaz activa con IP asignada
    $interfaceEncontrada = $null
    $serverIP = $null
    
    $interfaces = Get-NetworkInterfaces
    
    foreach ($iface in $interfaces) {
        $ip = Get-InterfaceIPAddress -InterfaceAlias $iface
        if ($ip -ne 'Sin IP' -and $ip -match '^\d+\.\d+\.\d+\.\d+$') {
            $interfaceEncontrada = $iface
            $serverIP = $ip
            break
        }
    }
    
    if (-not $interfaceEncontrada) {
        Write-WarningCustom 'No se encontro ninguna interfaz con IP asignada'
        $advertencias++
    }
    else {
        Write-SuccessMessage "Interfaz de red encontrada: $interfaceEncontrada"
        Write-Host "  IP: $serverIP"
    }
    
    Write-Host ""
    Write-SeparatorLine
    
    Write-InfoMessage "Verificando zonas DNS configuradas..."
    Write-Host ""
    
    try {
        $zonas = Get-DnsServerZone -ErrorAction SilentlyContinue | 
                Where-Object { $_.IsAutoCreated -eq $false -and $_.ZoneName -notlike "_*" }
        
        if ($zonas) {
            Write-SuccessMessage "Zonas DNS configuradas: $($zonas.Count)"
            Write-Host ""
            
            $zonas | Select-Object -First 5 | ForEach-Object {
                Write-Host "  - $($_.ZoneName) (Tipo: $($_.ZoneType))"
            }
            
            if ($zonas.Count -gt 5) {
                Write-Host "  ... y $($zonas.Count - 5) zonas más"
            }
        }
        else {
            Write-InfoMessage "No hay zonas DNS personalizadas configuradas"
            Write-Host "  Las zonas se pueden crear desde el menú 'ABC Dominios'"
        }
    }
    catch {
        Write-WarningCustom "No se pudo obtener información de zonas DNS"
        $advertencias++
    }
    
    Write-Host ""
    Write-SeparatorLine
    
    Write-InfoMessage "Verificando reenviadores DNS configurados..."
    Write-Host ""
    
    try {
        $forwarders = Get-DnsServerForwarder -ErrorAction SilentlyContinue
        
        if ($forwarders -and $forwarders.IPAddress.Count -gt 0) {
            Write-SuccessMessage "Reenviadores DNS configurados:"
            foreach ($fwd in $forwarders.IPAddress) {
                Write-Host "  - $fwd"
            }
        }
        else {
            Write-InfoMessage "No hay reenviadores DNS configurados"
            Write-Host "  El servidor resolverá consultas directamente"
        }
    }
    catch {
        Write-WarningCustom "No se pudo obtener información de reenviadores"
        $advertencias++
    }
    
    Write-Host ""
    Write-SeparatorLine
    
    Write-InfoMessage "Resumen de verificación"
    Write-Host ""
    
    if ($errores -eq 0 -and $advertencias -eq 0) {
        Write-SuccessMessage "Sistema DNS completamente funcional"
    }
    elseif ($errores -eq 0) {
        Write-WarningCustom "Sistema DNS funcional con $advertencias advertencia(s)"
    }
    else {
        Write-ErrorMessage "Sistema DNS con $errores error(es) y $advertencias advertencia(s)"
    }
    
    Write-Host ""
    Write-Host "Errores críticos: $errores"
    Write-Host "Advertencias: $advertencias"
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
    
    Invoke-VerificarInstalacion
    Invoke-Pause
}