# 
# Módulo de monitoreo del servicio DNS
# 
function Show-ServiceStatus {
    Write-Header "Estado del servicio"
    
    try {
        $dnsService = Get-Service -Name "DNS" -ErrorAction Stop
        
        if ($dnsService.Status -eq 'Running') {
            Write-SuccessMessage "Estado: ACTIVO"
            
            # Obtener información del proceso
            $process = Get-Process -Name "dns" -ErrorAction SilentlyContinue
            
            Write-Host ""
            
            if ($process) {
                Write-Host "  PID: $($process.Id)"
                Write-Host "  CPU: $([math]::Round($process.CPU, 2)) segundos"
                Write-Host "  Memoria: $([math]::Round($process.WorkingSet64 / 1MB, 2)) MB"
                Write-Host "  Hilos: $($process.Threads.Count)"
                Write-Host "  Identificadores: $($process.HandleCount)"
                
                # Calcular tiempo de actividad
                $uptime = New-TimeSpan -Start $process.StartTime
                Write-Host "  Activo desde: $($process.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
                Write-Host "  Tiempo activo: $([math]::Round($uptime.TotalHours, 2)) horas"
            }
            
            # Verificar si está habilitado
            if ($dnsService.StartType -eq 'Automatic') {
                Write-Host "  Inicio automático: HABILITADO"
            }
            else {
                Write-Host "  Inicio automático: DESHABILITADO"
            }
        }
        else {
            Write-ErrorMessage "Estado: INACTIVO (Estado: $($dnsService.Status))"
        }
    }
    catch {
        Write-ErrorMessage "No se pudo obtener el estado del servicio: $($_.Exception.Message)"
    }
    
    Write-Host ""
    
    # Verificar puertos
    Write-InfoMessage "Puertos en escucha:"
    Write-Host ""
    
    $tcpPort = Get-NetTCPConnection -LocalPort 53 -State Listen -ErrorAction SilentlyContinue
    if ($tcpPort) {
        Write-Host "  [OK] 53/TCP - Escuchando"
    }
    else {
        Write-Host "  [--] 53/TCP - No escuchando"
    }
    
    $udpPort = Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue
    if ($udpPort) {
        Write-Host "  [OK] 53/UDP - Escuchando"
    }
    else {
        Write-Host "  [--] 53/UDP - No escuchando"
    }
}

function Show-CurrentConfiguration {
    Write-Host ""
    Write-Header "Configuración Actual"
    
    # Configuración de Red
    Write-InfoMessage "Configuracion de Red:"
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
        Write-Host "  Interfaz:    $interfaceDNS"
        Write-Host "  IP Servidor: $ipDNSServidor"

        $ipConfig = Get-NetIPAddress -InterfaceAlias $interfaceDNS `
                                     -AddressFamily IPv4 `
                                     -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ipConfig) {
            Write-Host "  Mascara:     /$($ipConfig.PrefixLength)"
        }

        $gateway = Get-NetRoute -InterfaceAlias $interfaceDNS `
                                -DestinationPrefix "0.0.0.0/0" `
                                -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gateway) {
            Write-Host "  Gateway:     $($gateway.NextHop)"
        }
    }
    else {
        Write-WarningCustom "No se encontro la interfaz DNS activa"
    }
    Write-Host ""
    
    # Configuración DNS
    Write-InfoMessage "Configuración DNS (Servidor):"
    Write-Host ""
    
    try {
        # Interfaces de escucha
        $listenAddresses = Get-DnsServerListenAddress -ErrorAction SilentlyContinue
        if ($listenAddresses -and $listenAddresses.IPAddress) {
            Write-Host "  Interfaces escucha: $($listenAddresses.IPAddress -join ', ')"
        }
        else {
            Write-Host "  Interfaces escucha: Todas"
        }
        
        # Reenviadores -> fprwarders
        $forwarders = Get-DnsServerForwarder -ErrorAction SilentlyContinue
        if ($forwarders -and $forwarders.IPAddress.Count -gt 0) {
            Write-Host "  Reenviadores: $($forwarders.IPAddress -join ', ')"
        }
        else {
            Write-Host "  Reenviadores: No configurados"
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
        
        $cache = Get-DnsServerCache -ErrorAction SilentlyContinue
        if ($cache) {
            Write-Host "  TTL máximo caché: $($cache.MaxTTL)"
        }
    }
    catch {
        Write-WarningCustom "No se pudo obtener toda la configuración DNS"
    }
}

function Show-ZonesSummary {
    Write-Header "Resumen de las zonas"
    
    try {
        $todasZonas = Get-DnsServerZone -ErrorAction Stop | 
                     Where-Object { $_.IsAutoCreated -eq $false -and $_.ZoneName -notlike "_*" }
        
        if (-not $todasZonas) {
            Write-InfoMessage "No hay zonas personalizadas configuradas"
            return
        }
        
        $zonasDirectas = @($todasZonas | Where-Object { $_.IsReverseLookupZone -eq $false })
        $zonasInversas = @($todasZonas | Where-Object { $_.IsReverseLookupZone -eq $true })
        
        Write-InfoMessage "Total de zonas configuradas: $($todasZonas.Count)"
        Write-Host "  Zonas directas: $($zonasDirectas.Count)"
        Write-Host "  Zonas inversas: $($zonasInversas.Count)"
        Write-Host ""
        
        # Listar zonas directas
        if ($zonasDirectas.Count -gt 0) {
            Write-InfoMessage "Zonas Directas:"
            Write-Host ""
            
            foreach ($zona in $zonasDirectas) {
                Write-Host "  - $($zona.ZoneName)"
                Write-Host "    Tipo: $($zona.ZoneType)"
                
                # Obtener cantidad de registros
                try {
                    $registros = Get-DnsServerResourceRecord -ZoneName $zona.ZoneName -ErrorAction SilentlyContinue
                    Write-Host "    Registros: $($registros.Count)"
                }
                catch {
                    Write-Host "    Registros: N/A"
                }
                
                # Obtener registro A principal
                try {
                    $recordA = Get-DnsServerResourceRecord -ZoneName $zona.ZoneName -RRType A -ErrorAction SilentlyContinue |
                              Where-Object { $_.HostName -eq "@" } | Select-Object -First 1
                    
                    if ($recordA) {
                        Write-Host "    IP: $($recordA.RecordData.IPv4Address)"
                    }
                }
                catch {
                    # si
                }
                
                Write-Host "    Estado: OK"
                Write-Host ""
            }
        }
        
        # Listar zonas inversas
        if ($zonasInversas.Count -gt 0) {
            Write-InfoMessage "Zonas Inversas:"
            Write-Host ""
            
            foreach ($zona in $zonasInversas) {
                Write-Host "  - $($zona.ZoneName) (inversa)"
                Write-Host "    Tipo: $($zona.ZoneType)"
                
                # Obtener cantidad de registros PTR
                try {
                    $registrosPTR = Get-DnsServerResourceRecord -ZoneName $zona.ZoneName -RRType PTR -ErrorAction SilentlyContinue
                    Write-Host "    Registros PTR: $($registrosPTR.Count)"
                }
                catch {
                    Write-Host "    Registros PTR: N/A"
                }
                
                Write-Host "    Estado: OK"
                Write-Host ""
            }
        }
    }
    catch {
        Write-WarningCustom "No se pudo obtener información de zonas: $($_.Exception.Message)"
    }
}

function Show-DNSStatistics {
    Write-Header "Estadísticas DNS"
    
    try {
        $stats = Get-DnsServerStatistics -ErrorAction Stop
        
        Write-InfoMessage "Consultas totales:"
        Write-Host "  Total recibidas: $($stats.TotalQueries)"
        Write-Host "  Respuestas enviadas: $($stats.TotalResponse)"
        
        Write-Host ""
        Write-InfoMessage "Tipos de consultas:"
        Write-Host "  A (IPv4): $($stats.TypeAQueries)"
        Write-Host "  AAAA (IPv6): $($stats.TypeAAAAQueries)"
        Write-Host "  SOA: $($stats.TypeSOAQueries)"
        Write-Host "  PTR (reversas): $($stats.TypePTRQueries)"
        
        Write-Host ""
        Write-InfoMessage "Caché:"
        Write-Host "  Aciertos de caché: $($stats.CacheHit)"
        Write-Host "  Fallos de caché: $($stats.CacheMiss)"
        
        if ($stats.TotalQueries -gt 0) {
            $hitRate = [math]::Round(($stats.CacheHit / $stats.TotalQueries) * 100, 2)
            Write-Host "  Tasa de aciertos: $hitRate%"
        }
    }
    catch {
        Write-InfoMessage "Las estadísticas detalladas no están disponibles"
        Write-Host "  Esto es normal en servidores recién iniciados"
    }
}

function Invoke-MonitorDNS {
    Clear-Host
    
    # Verificar privilegios
    if (-not (Test-AdminPrivileges)) {
        return
    }
    
    # Verificar que DNS esté instalado
    if (-not (Test-WindowsFeatureInstalled -FeatureName "DNS")) {
        Write-ErrorMessage "Rol DNS no está instalado"
        Write-Host ""
        Write-InfoMessage "Ejecute la opción 'Instalar/config servicio DNS' primero"
        return
    }
    
    # Mostrar todas las secciones del monitor
    Show-ServiceStatus
    Show-CurrentConfiguration
    Show-ZonesSummary
    Show-DNSStatistics
    
    Write-SeparatorLine
    Write-InfoMessage "Monitor actualizado: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
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
    
    Invoke-MonitorDNS
    Invoke-Pause
}