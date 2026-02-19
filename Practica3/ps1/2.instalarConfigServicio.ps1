# 
# 2_InstalConfigServicio.ps1
# Módulo para instalar y configurar el servicio DNS en Windows Server
# 
# 
# Variables globales
# 
$script:RED_SERVIDOR = ""
$script:IP_ESPERADA = ""
$script:INTERFAZ_DNS = ""
$script:IP_SERVIDOR = ""
$script:RED_PERMITIDA = ""
$script:DNS_FORWARDER_1 = ""
$script:DNS_FORWARDER_2 = ""


function Test-DNSRoleInstalled {
    return (Test-WindowsFeatureInstalled -FeatureName "DNS")
}


function Install-DNSRole {
    Write-InfoMessage "Iniciando instalación del Rol DNS y herramientas..."
    Write-Host ""
    
    try {
        Write-InfoMessage "Instalando Rol DNS..."
        
        # Instalar el rol DNS
        $result = Install-WindowsFeature -Name DNS -IncludeManagementTools
        
        if ($result.Success) {
            Write-Host ""
            Write-SuccessMessage "Rol DNS instalado correctamente"
            
            # Obtener versión
            $dnsFeature = Get-WindowsFeature -Name DNS
            Write-Host "  Característica: $($dnsFeature.DisplayName)"
            
            # Verificar si se requiere reinicio
            if ($result.RestartNeeded -eq 'Yes') {
                Write-WarningCustom "Se requiere reiniciar el servidor para completar la instalación"
            }
            
            return $true
        }
        else {
            Write-Host ""
            Write-ErrorMessage "Error durante la instalación del Rol DNS"
            if ($result.ExitCode) {
                Write-Host "  Código de salida: $($result.ExitCode)"
            }
            return $false
        }
    }
    catch {
        Write-Host ""
        Write-ErrorMessage "Excepción durante la instalación: $($_.Exception.Message)"
        return $false
    }
}


function Enable-DNSService {
    Write-InfoMessage "Habilitando servicio DNS para inicio automático..."
    
    try {
        Set-Service -Name DNS -StartupType Automatic -ErrorAction Stop
        Write-SuccessMessage "Servicio DNS habilitado para inicio automático"
        return $true
    }
    catch {
        Write-ErrorMessage "No se pudo habilitar el servicio DNS: $($_.Exception.Message)"
        return $false
    }
}

function Test-NetworkConfiguration {
    Write-Header "Verificaciones de Red"

    Write-InfoMessage "Detectando interfaces de red disponibles..."
    Write-Host ""

    # Recopilar todas las interfaces activas que tengan IP asignada
    $interfaces = Get-NetworkInterfaces
    $interfacesConIP = @()

    foreach ($iface in $interfaces) {
        $ip = Get-InterfaceIPAddress -InterfaceAlias $iface
        if ($ip -ne 'Sin IP' -and $ip -match '^\d+\.\d+\.\d+\.\d+$') {
            $interfacesConIP += [PSCustomObject]@{
                Nombre = $iface
                IP     = $ip
            }
        }
    }

    if ($interfacesConIP.Count -eq 0) {
        Write-ErrorMessage "No se encontro ninguna interfaz de red activa con IP"
        Write-Host ""
        Write-WarningCustom "Verifique que al menos una interfaz tenga una IP configurada"
        Write-Host ""

        # Mostrar todas las interfaces aunque no tengan IP
        Write-InfoMessage "Interfaces de red disponibles:"
        Write-Host ""
        foreach ($iface in $interfaces) {
            $ip = Get-InterfaceIPAddress -InterfaceAlias $iface
            Write-Host "  - ${iface}: $ip"
        }

        return $false
    }

    # Mostrar tabla de interfaces disponibles para que el usuario elija
    Write-InfoMessage "Interfaces de red con IP asignada:"
    Write-Host ""

    $contador = 1
    foreach ($entry in $interfacesConIP) {
        Write-Host "  $contador) $($entry.Nombre) (IP: $($entry.IP))"
        $contador++
    }

    Write-Host ""

    # Solicitar seleccion
    $interfaceSeleccionada = $null
    $ipSeleccionada = $null

    while ($true) {
        $seleccion = Read-Host "Seleccione el numero de la interfaz a usar para DNS [1-$($interfacesConIP.Count)]"

        if ($seleccion -match '^\d+$' -and [int]$seleccion -ge 1 -and [int]$seleccion -le $interfacesConIP.Count) {
            $interfaceSeleccionada = $interfacesConIP[[int]$seleccion - 1].Nombre
            $ipSeleccionada        = $interfacesConIP[[int]$seleccion - 1].IP
            break
        }
        else {
            Write-ErrorMessage "Seleccion invalida. Ingrese un numero entre 1 y $($interfacesConIP.Count)"
        }
    }

    Write-Host ""
    Write-SuccessMessage "Interfaz seleccionada: $interfaceSeleccionada"
    Write-Host "  IP: $ipSeleccionada"
    Write-Host ""

    # Validar que la IP seleccionada sea usable para DNS
    if (Test-DNSIP -IPAddress $ipSeleccionada) {
        Write-SuccessMessage "IP validada correctamente para uso DNS"
        Write-Host ""

        $script:INTERFAZ_DNS = $interfaceSeleccionada
        $script:IP_SERVIDOR  = $ipSeleccionada

        return $true
    }
    else {
        Write-ErrorMessage "La IP seleccionada no es valida para uso DNS"
        Write-Host ""

        $respuesta = Read-Host "Desea continuar con la IP seleccionada de todas formas? (S/N)"

        if ($respuesta -eq 'S' -or $respuesta -eq 's') {
            Write-InfoMessage "Continuando con la IP: $ipSeleccionada"
            $script:INTERFAZ_DNS = $interfaceSeleccionada
            $script:IP_SERVIDOR  = $ipSeleccionada
            return $true
        }
        else {
            Write-InfoMessage "Configuracion cancelada"
            Write-Host ""
            Write-InfoMessage "Seleccione una interfaz con una IP valida para continuar"
            return $false
        }
    }
}

function Request-DNSParameters {
    Write-Header "Configuración de parámetros DNS"
    
    Write-InfoMessage "Se configurará el servidor DNS con los siguientes parámetros"
    Write-Host ""
    
    # Red permitida para consultas (calcular automaticamente)
    $octets = $script:IP_SERVIDOR -split '\.'
    $redBase = "$($octets[0]).$($octets[1]).$($octets[2])"
    $redDefault = "$redBase.0/24"

    Write-InfoMessage "IP del servidor DNS seleccionada: $script:IP_SERVIDOR"
    Write-Host ""
    Write-InfoMessage "Red permitida para consultas DNS:"
    Write-Host "  Red calculada: $redDefault"
    $respuestaRed = Read-Host "  Presione Enter para aceptar o ingrese otra red"
    $script:RED_PERMITIDA = if ($respuestaRed) { $respuestaRed } else { $redDefault }
    
    Write-Host ""
    
    # Reenviadores DNS
    Write-InfoMessage "Reenviadores DNS (servidores DNS externos para consultas)"
    
    $respuestaFwd1 = Read-Host "  Reenviador primario [Default: 8.8.8.8]"
    $script:DNS_FORWARDER_1 = if ($respuestaFwd1) { $respuestaFwd1 } else { "8.8.8.8" }

    $respuestaFwd2 = Read-Host "  Reenviador secundario [Default: 8.8.4.4]"
    $script:DNS_FORWARDER_2 = if ($respuestaFwd2) { $respuestaFwd2 } else { "8.8.4.4" }
    
    # Validar IPs de reenviadores
    if (-not (Test-IPv4Address -IPAddress $script:DNS_FORWARDER_1)) {
        Write-WarningCustom "IP de reenviador primario inválida, usando 8.8.8.8"
        $script:DNS_FORWARDER_1 = "8.8.8.8"
    }
    
    if (-not (Test-IPv4Address -IPAddress $script:DNS_FORWARDER_2)) {
        Write-WarningCustom "IP de reenviador secundario inválida, usando 8.8.4.4"
        $script:DNS_FORWARDER_2 = "8.8.4.4"
    }
    
    Write-SeparatorLine
    
    # Mostrar resumen
    Write-InfoMessage "Resumen de Configuración:"
    Write-Host ""
    Write-Host "  IP del Servidor DNS: $script:IP_SERVIDOR"
    Write-Host "  Interfaz: $script:INTERFAZ_DNS"
    Write-Host "  Red permitida: $script:RED_PERMITIDA"
    Write-Host "  Reenviador primario: $script:DNS_FORWARDER_1"
    Write-Host "  Reenviador secundario: $script:DNS_FORWARDER_2"
    Write-Host ""
    
    $confirmar = Read-Host "¿Es correcta esta configuración? (S/N)"
    
    if ($confirmar -ne 'S' -and $confirmar -ne 's') {
        Write-InfoMessage "Reingresando parámetros..."
        Write-Host ""
        Request-DNSParameters
    }
}

function Backup-DNSConfigurations {
    $backupDir = Join-Path $env:USERPROFILE "dns_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    
    Write-InfoMessage "Creando backup de configuraciones existentes..."
    
    try {
        New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
        
        # Backup de zonas DNS
        $zonasPath = "$env:SystemRoot\System32\dns"
        if (Test-Path $zonasPath) {
            Copy-Item -Path "$zonasPath\*" -Destination $backupDir -Recurse -ErrorAction SilentlyContinue
            Write-SuccessMessage "Backup de configuraciones DNS creado"
        }
        
        Write-SuccessMessage "Backup guardado en: $backupDir"
        return $backupDir
    }
    catch {
        Write-WarningCustom "No se pudo crear backup completo: $($_.Exception.Message)"
        return $backupDir
    }
}

function Set-DNSServerConfiguration {
    Write-Header "Configuración del Servidor DNS"
    
    Write-InfoMessage "Configurando parámetros del servidor DNS..."
    Write-Host ""
    
    try {
        # Configurar interfaces de escucha (escuchar en todas las interfaces)
        Write-InfoMessage "Configurando interfaces de escucha..."
        Set-DnsServerRecursion -Enable $true -ErrorAction Stop
        Write-SuccessMessage "Servidor DNS configurado para escuchar en todas las interfaces"
        
        Write-Host ""
        
        # Configurar reenviadores DNS
        Write-InfoMessage "Configurando reenviadores DNS..."
        $forwarders = @($script:DNS_FORWARDER_1, $script:DNS_FORWARDER_2)
        Set-DnsServerForwarder -IPAddress $forwarders -ErrorAction Stop
        Write-SuccessMessage "Reenviadores DNS configurados: $($forwarders -join ', ')"
        
        Write-Host ""
        
        # Configurar alcance de recursión (scope)
        Write-InfoMessage "Configurando alcance de recursión..."
        Set-DnsServerScavenging -ScavengingState $true -ScavengingInterval "7.00:00:00" -ErrorAction SilentlyContinue
        Write-SuccessMessage "Alcance de recursión configurado"
        
        Write-Host ""
        
        # Configurar caché DNS
        Write-InfoMessage "Configurando caché DNS..."
        Set-DnsServerCache -MaxTTL "1.00:00:00" -ErrorAction Stop
        Write-SuccessMessage "Caché DNS configurado"
        
        Write-Host ""
        
        # Habilitar DNSSEC si está disponible
        try {
            Write-InfoMessage "Configurando DNSSEC..."
            Set-DnsServerDsSetting -EnableDnsSec $true -ErrorAction SilentlyContinue
            Write-SuccessMessage "DNSSEC configurado"
        }
        catch {
            Write-InfoMessage "DNSSEC no disponible en esta versión"
        }
        
        Write-Host ""
        Write-SuccessMessage "Configuración del servidor DNS completada"
        
        return $true
    }
    catch {
        Write-ErrorMessage "Error al configurar el servidor DNS: $($_.Exception.Message)"
        return $false
    }
}

function Set-DNSFirewallRules {
    Write-Header "Configuración de Firewall"
    
    Write-InfoMessage "Configurando reglas de firewall para DNS..."
    Write-Host ""
    
    try {
        # Habilitar reglas DNS predefinidas si existen
        $predefinedRules = Get-NetFirewallRule -DisplayName "*DNS*" -ErrorAction SilentlyContinue
        
        if ($predefinedRules) {
            Write-InfoMessage "Habilitando reglas DNS predefinidas..."
            $predefinedRules | Enable-NetFirewallRule
            Write-SuccessMessage "Reglas DNS predefinidas habilitadas"
        }
        else {
            # Crear reglas personalizadas
            Write-InfoMessage "Creando reglas de firewall personalizadas..."
            
            # Regla para DNS TCP
            if (-not (Get-NetFirewallRule -DisplayName "DNS Server - TCP" -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName "DNS Server - TCP" `
                                   -Direction Inbound `
                                   -Protocol TCP `
                                   -LocalPort 53 `
                                   -Action Allow `
                                   -Profile Any `
                                   -Enabled True | Out-Null
                Write-SuccessMessage "Regla DNS TCP creada"
            }
            
            # Regla para DNS UDP
            if (-not (Get-NetFirewallRule -DisplayName "DNS Server - UDP" -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName "DNS Server - UDP" `
                                   -Direction Inbound `
                                   -Protocol UDP `
                                   -LocalPort 53 `
                                   -Action Allow `
                                   -Profile Any `
                                   -Enabled True | Out-Null
                Write-SuccessMessage "Regla DNS UDP creada"
            }
        }
        
        Write-Host ""
        
        # Verificar configuración
        Write-InfoMessage "Verificando configuración de firewall..."
        
        $dnsRules = Get-NetFirewallRule | 
                   Where-Object { $_.DisplayName -like "*DNS*" -and $_.Enabled -eq $true }
        
        if ($dnsRules) {
            Write-SuccessMessage "Reglas DNS: ACTIVAS en firewall"
            $dnsRules | Select-Object -First 3 | ForEach-Object {
                Write-Host "  - $($_.DisplayName)"
            }
        }
        else {
            Write-ErrorMessage "No se pudieron verificar las reglas DNS en firewall"
            return $false
        }
        
        return $true
    }
    catch {
        Write-ErrorMessage "Error al configurar firewall: $($_.Exception.Message)"
        return $false
    }
}

function Start-DNSService {
    Write-Header "Inicio del servicio DNS"
    
    # Verificar si el puerto 53 está en uso
    if (Test-Port53InUse) {
        $process = Get-Port53Process
        Write-WarningCustom "El puerto 53 está en uso por: $process"
        Write-Host ""
        
        if ($process -ne "dns") {
            Write-InfoMessage "Se intentará detener el servicio que está usando el puerto 53"
            
            # Intentar detener servicios comunes que usan puerto 53
            $servicesToStop = @("WinRM", "RemoteAccess")
            foreach ($svc in $servicesToStop) {
                try {
                    $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
                    if ($service -and $service.Status -eq 'Running') {
                        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                        Write-InfoMessage "Servicio $svc detenido"
                    }
                }
                catch {
                    # Continuar si no se puede detener
                }
            }
        }
    }
    
    Write-InfoMessage "Iniciando servicio DNS..."
    
    try {
        Start-Service -Name DNS -ErrorAction Stop
        Write-SuccessMessage "Servicio DNS iniciado"
        
        # Esperar a que se estabilice
        Start-Sleep -Seconds 2
        
        # Verificar que está activo
        if (Test-ServiceActive -ServiceName "DNS") {
            Write-SuccessMessage "Servicio DNS: ACTIVO"
            
            # Mostrar información del servicio
            $service = Get-Service -Name DNS
            Write-Host "  Estado: $($service.Status)"
            Write-Host "  Tipo de inicio: $($service.StartType)"
            
            $process = Get-Process -Name "dns" -ErrorAction SilentlyContinue
            if ($process) {
                Write-Host "  PID: $($process.Id)"
            }
            
            return $true
        }
        else {
            Write-ErrorMessage "Servicio DNS no se inició correctamente"
            return $false
        }
    }
    catch {
        Write-ErrorMessage "Error al iniciar servicio DNS: $($_.Exception.Message)"
        Write-Host ""
        Write-ErrorMessage "Detalles del error:"
        Write-Host "  $($_.Exception.Message)"
        return $false
    }
}

function Test-DNSPorts {
    Write-InfoMessage "Verificando puertos en escucha..."
    Write-Host ""
    
    Start-Sleep -Seconds 1
    
    # Puerto 53 TCP
    $tcpPort = Get-NetTCPConnection -LocalPort 53 -State Listen -ErrorAction SilentlyContinue
    if ($tcpPort) {
        Write-SuccessMessage "Puerto 53/TCP: ESCUCHANDO"
    }
    else {
        Write-WarningCustom "Puerto 53/TCP: NO escuchando"
    }
    
    # Puerto 53 UDP
    $udpPort = Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue
    if ($udpPort) {
        Write-SuccessMessage "Puerto 53/UDP: ESCUCHANDO"
    }
    else {
        Write-WarningCustom "Puerto 53/UDP: NO escuchando"
    }
}

function Invoke-InstalarConfigServicio {
    Clear-Host
    Write-Header "Instalar y Configurar Servicio DNS"
    
    # Verificar privilegios
    if (-not (Test-AdminPrivileges)) {
        return
    }
    
    Write-Host ""
    
    Write-InfoMessage "PASO 1: Verificando instalación existente..."
    Write-Host ""
    
    if (Test-DNSRoleInstalled) {
        Write-WarningCustom "Rol DNS ya está instalado"
        
        $dnsFeature = Get-WindowsFeature -Name DNS
        Write-Host "  Característica: $($dnsFeature.DisplayName)"
        Write-Host ""
        
        $respuesta = Read-Host "¿Desea continuar con la configuración? (S/N)"
        
        if ($respuesta -ne 'S' -and $respuesta -ne 's') {
            Write-InfoMessage "Instalación cancelada"
            return
        }
        
        # Hacer backup si ya existe configuración
        Write-Host ""
        Backup-DNSConfigurations
    }
    else {
        Write-InfoMessage "Rol DNS no está instalado - se procederá con la instalación"
        Write-Host ""
        
        Write-SeparatorLine
        Write-Host ""
        
        # Instalar Rol DNS
        if (-not (Install-DNSRole)) {
            return
        }
        
        Write-Host ""
        
        # Habilitar servicio
        Enable-DNSService
    }
    
    Write-SeparatorLine
    
    Write-InfoMessage "PASO 2: Verificando configuración de red..."
    
    if (-not (Test-NetworkConfiguration)) {
        return
    }
    
    Invoke-Pause
    Clear-Host
    
    Write-InfoMessage "PASO 3: Configuración de parámetros DNS..."
    
    Request-DNSParameters
    
    Write-Host ""
    Invoke-Pause
    Clear-Host
    
    Write-InfoMessage "PASO 4: Configurando servidor DNS..."
    Write-Host ""
    
    if (-not (Set-DNSServerConfiguration)) {
        Write-ErrorMessage "Error al configurar el servidor DNS"
        return
    }
    
    Write-Host ""
    Write-SeparatorLine
    
    Write-InfoMessage "PASO 5: Configurando firewall..."
    Write-Host ""
    
    Set-DNSFirewallRules
    
    Write-SeparatorLine
    
    Write-InfoMessage "PASO 6: Iniciando servicio DNS..."
    Write-Host ""
    
    if (-not (Start-DNSService)) {
        Write-ErrorMessage "Error al iniciar el servicio"
        return
    }
    
    Write-Host ""
    Test-DNSPorts
    
    Write-SeparatorLine
    Write-Host ""
    
    Write-SuccessMessage "Instalación y Configuración Completa"
    Write-Host ""
    Write-InfoMessage "El servidor DNS está operativo"
    Write-InfoMessage "Puede agregar dominios usando la opción '6) ABC Dominios'"
    Write-Host ""
}

# Ejecutar si se llama directamente
if ($MyInvocation.InvocationName -ne '.') {
    # Cargar utilidades si no están cargadas
    if (-not (Get-Command Write-InfoMessage -ErrorAction SilentlyContinue)) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        . (Join-Path $scriptDir "utils.ps1")
    }
    
    Invoke-InstalarConfigServicio
    Invoke-Pause
}