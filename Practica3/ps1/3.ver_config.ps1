# 
# 3_ver_config.ps1
# Módulo para ver la configuración actual del servidor DNS
# 
#
function Invoke-VerConfigActual {
    Clear-Host
    Write-Header "Configuración actual del servidor DNS"
    
    # Verificar privilegios
    if (-not (Test-AdminPrivileges)) {
        return
    }
    
    # Verificar que DNS esté instalado
    if (-not (Test-WindowsFeatureInstalled -FeatureName "DNS")) {
        Write-ErrorMessage "Rol DNS no está instalado"
        Write-Host ""
        Write-InfoMessage "Ejecute primero la opción '2) Instalar/config servicio DNS'"
        return
    }
    
    Write-SeparatorLine
    
    Write-InfoMessage "1. Estado del Servicio DNS"
    Write-Host ""
    
    try {
        $dnsService = Get-Service -Name "DNS" -ErrorAction Stop
        
        if ($dnsService.Status -eq 'Running') {
            Write-SuccessMessage "Servicio: ACTIVO"
            
            # Obtener información del proceso
            $process = Get-Process -Name "dns" -ErrorAction SilentlyContinue
            if ($process) {
                Write-Host "  PID: $($process.Id)"
                Write-Host "  Memoria: $([math]::Round($process.WorkingSet64 / 1MB, 2)) MB"
                Write-Host "  CPU: $($process.CPU) segundos"
            }
            
            if ($dnsService.StartType -eq 'Automatic') {
                Write-Host "  Inicio automático: HABILITADO"
            }
            else {
                Write-Host "  Inicio automático: DESHABILITADO"
            }
        }
        else {
            Write-ErrorMessage "Servicio: INACTIVO (Estado: $($dnsService.Status))"
        }
    }
    catch {
        Write-ErrorMessage "No se pudo obtener información del servicio"
    }
    
    Write-SeparatorLine
    
    Write-InfoMessage "2. Configuracion de Red"
    Write-Host ""

    $ipDNSServidor = $null
    $interfaceDNS  = $null

    try {
        $listenAddresses = Get-DnsServerListenAddress -ErrorAction SilentlyContinue
        if ($listenAddresses -and $listenAddresses.IPAddress) {
            foreach ($addr in $listenAddresses.IPAddress) {
                if ($addr -ne '127.0.0.1' -and $addr -match '^\d+\.\d+\.\d+\.\d+$') {
                    $ipDNSServidor = $addr
                    break
                }
            }
        }
    }
    catch { }

    if (-not $ipDNSServidor) {
        $interfaces = Get-NetworkInterfaces
        foreach ($iface in $interfaces) {
            $ip = Get-InterfaceIPAddress -InterfaceAlias $iface
            if ($ip -ne 'Sin IP' -and $ip -match '^\d+\.\d+\.\d+\.\d+$') {
                $ipDNSServidor = $ip
                $interfaceDNS  = $iface
            }
        }
    }
    else {
        # Buscar a qué interfaz pertenece esa IP
        $interfaces = Get-NetworkInterfaces
        foreach ($iface in $interfaces) {
            $ip = Get-InterfaceIPAddress -InterfaceAlias $iface
            if ($ip -eq $ipDNSServidor) {
                $interfaceDNS = $iface
                break
            }
        }
    }

    if ($interfaceDNS -and $ipDNSServidor) {
        Write-Host "  Interfaz DNS: $interfaceDNS"
        Write-Host "  IP Servidor:  $ipDNSServidor"

        $ipConfig = Get-NetIPAddress -InterfaceAlias $interfaceDNS `
                                     -AddressFamily IPv4 `
                                     -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ipConfig) {
            Write-Host "  Mascara:      /$($ipConfig.PrefixLength)"
        }

        $gateway = Get-NetRoute -InterfaceAlias $interfaceDNS `
                                -DestinationPrefix "0.0.0.0/0" `
                                -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gateway) {
            Write-Host "  Gateway:      $($gateway.NextHop)"
        }
    }
    else {
        Write-WarningCustom "No se encontro la interfaz DNS activa"
    }
    
    Write-InfoMessage "3. Parámetros DNS (Configuración del servidor)"
    Write-Host ""
    
    try {
        # Interfaces de escucha
        $listenAddresses = Get-DnsServerListenAddress -ErrorAction SilentlyContinue
        if ($listenAddresses) {
            Write-Host "  Escuchando en: $($listenAddresses.IPAddress -join ', ')"
        }
        else {
            Write-Host "  Escuchando en: Todas las interfaces"
        }
        
        # Reenviadores
        $forwarders = Get-DnsServerForwarder -ErrorAction SilentlyContinue
        if ($forwarders -and $forwarders.IPAddress.Count -gt 0) {
            Write-Host "  DNS Forwarders: $($forwarders.IPAddress -join ', ')"
        }
        else {
            Write-Host "  DNS Forwarders: No configurados"
        }
        
        # Recursión
        $recursion = Get-DnsServerRecursion -ErrorAction SilentlyContinue
        if ($recursion) {
            if ($recursion.Enable) {
                Write-Host "  Recursión: HABILITADA"
            }
            else {
                Write-Host "  Recursión: DESHABILITADA"
            }
        }
        
        # Configuración de caché
        $cache = Get-DnsServerCache -ErrorAction SilentlyContinue
        if ($cache) {
            Write-Host "  TTL máximo de caché: $($cache.MaxTTL)"
        }
    }
    catch {
        Write-WarningCustom "No se pudo obtener toda la configuración DNS"
    }
    
    Write-SeparatorLine
    
    # Puertos
    Write-InfoMessage "4. Puertos en escucha"
    Write-Host ""
    
    # Puerto 53 TCP
    $tcpPort = Get-NetTCPConnection -LocalPort 53 -State Listen -ErrorAction SilentlyContinue
    if ($tcpPort) {
        Write-Host "  [OK] 53/TCP: Escuchando"
        $tcpPort | Select-Object -First 2 | ForEach-Object {
            Write-Host "       $($_.LocalAddress):$($_.LocalPort)"
        }
    }
    else {
        Write-Host "  [--] 53/TCP: No escuchando"
    }
    
    Write-Host ""
    
    # Puerto 53 UDP
    $udpPort = Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue
    if ($udpPort) {
        Write-Host "  [OK] 53/UDP: Escuchando"
        $udpPort | Select-Object -First 2 | ForEach-Object {
            Write-Host "       $($_.LocalAddress):$($_.LocalPort)"
        }
    }
    else {
        Write-Host "  [--] 53/UDP: No escuchando"
    }
    
    Write-SeparatorLine
    
    # Firewall
    Write-InfoMessage "5. Firewall"
    Write-Host ""
    
    if (Test-WindowsFirewallActive) {
        Write-Host "  Firewall de Windows: ACTIVO"
        
        # Verificar reglas DNS
        $dnsRules = Get-NetFirewallRule | 
                   Where-Object { $_.DisplayName -like "*DNS*" -and $_.Enabled -eq $true }
        
        if ($dnsRules) {
            Write-Host "  Reglas DNS: CONFIGURADAS"
            $dnsRules | Select-Object -First 3 | ForEach-Object {
                Write-Host "    - $($_.DisplayName)"
            }
        }
        else {
            Write-Host "  Reglas DNS: NO configuradas"
        }
    }
    else {
        Write-Host "  Firewall de Windows: INACTIVO"
    }
    
    Write-SeparatorLine
    
    # Zonas configuradas
    Write-InfoMessage "6. Zonas configuradas"
    Write-Host ""
    
    try {
        $zonas = Get-DnsServerZone -ErrorAction SilentlyContinue | 
                Where-Object { $_.IsAutoCreated -eq $false -and $_.ZoneName -notlike "_*" }
        
        if ($zonas) {
            $zonasDirectas = @($zonas | Where-Object { $_.IsReverseLookupZone -eq $false })
            $zonasInversas = @($zonas | Where-Object { $_.IsReverseLookupZone -eq $true })
            
            Write-Host "  Zonas directas: $($zonasDirectas.Count)"
            Write-Host "  Zonas inversas: $($zonasInversas.Count)"
            Write-Host "  Total: $($zonas.Count)"
            
            if ($zonasDirectas.Count -gt 0) {
                Write-Host ""
                Write-Host "  Dominios:"
                foreach ($zona in $zonasDirectas | Select-Object -First 5) {
                    Write-Host "    - $($zona.ZoneName)"
                    Write-Host "      Tipo: $($zona.ZoneType)"
                    
                    # Intentar obtener registro A principal
                    $recordA = Get-DnsServerResourceRecord -ZoneName $zona.ZoneName -RRType A -ErrorAction SilentlyContinue | 
                              Where-Object { $_.HostName -eq "@" } | Select-Object -First 1
                    
                    if ($recordA) {
                        Write-Host "      IP: $($recordA.RecordData.IPv4Address)"
                    }
                }
                
                if ($zonasDirectas.Count -gt 5) {
                    Write-Host "    ... y $($zonasDirectas.Count - 5) zonas más"
                }
            }
        }
        else {
            Write-Host "  No hay zonas DNS personalizadas configuradas"
            Write-Host "  Las zonas se pueden crear desde el menú 'ABC Dominios'"
        }
    }
    catch {
        Write-WarningCustom "No se pudo obtener información de zonas DNS"
    }
    
    Write-SeparatorLine
    
    # Archivos de config
    Write-InfoMessage "7. Archivos de configuración"
    Write-Host ""
    
    $dnsPath = "$env:SystemRoot\System32\dns"
    
    Write-Host "  Directorio de configuración:"
    Write-Host "    $dnsPath"
    
    if (Test-Path $dnsPath) {
        $archivos = Get-ChildItem -Path $dnsPath -File -ErrorAction SilentlyContinue
        Write-Host "    Archivos de configuración: $($archivos.Count)"
        
        # Mostrar archivos de zona
        $zonasArchivos = Get-ChildItem -Path $dnsPath -Filter "*.dns" -File -ErrorAction SilentlyContinue
        if ($zonasArchivos) {
            Write-Host "    Archivos de zona: $($zonasArchivos.Count)"
        }
    }
    
    Write-SeparatorLine
    Write-SuccessMessage "Configuración mostrada completamente"
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
    
    Invoke-VerConfigActual
    Invoke-Pause
}