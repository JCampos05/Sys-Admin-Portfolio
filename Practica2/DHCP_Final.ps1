$ErrorActionPreference = "Stop"

#
# Funciones Auxiliares
#
function validar_ip {
    param([string]$ip)
    
    if ($ip -notmatch '^(\d{1,3}\.){3}\d{1,3}$') {
        Write-Host ""
        Write-Host "Formato IPv4 Incorrecto. Verifique nuevamente" 
        return $false
    }
    
    $octetos = $ip.Split('.')
    foreach ($i in $octetos) {
        $num = [int]$i
        if ($num -lt 0 -or $num -gt 255) {
            Write-Host ""
            Write-Host "Formato IPv4 Incorrecto. Verifique nuevamente" 
            return $false
        }
    }
    
    Write-Host ""
    Write-Host "Formato IPv4 correcto" 
    return $true
}

#
# Funciones CLAVES -> DHCP
#

function deteccion_interfaces_red {
    # Obtener TODAS las interfaces con IP (incluyendo manuales y DHCP)
    $script:interfaces = Get-NetIPAddress -AddressFamily IPv4 | 
        Where-Object { 
            $_.IPAddress -notlike "127.*" -and
            $_.IPAddress -notlike "169.254.*"
        }
    
    if ($script:interfaces.Count -eq 0) {
        Write-Host ""
        Write-Host "No se detectaron interfaces de red" 
        exit 1
    }
    
    Write-Host ""
    Write-Host "Interfaces de red detectadas:"
    Write-Host ""
    
    $script:listaInterfaces = @()
    $index = 1
    
    foreach ($adapter in $script:interfaces) {
        $netAdapter = Get-NetAdapter -InterfaceIndex $adapter.InterfaceIndex
        
        $info = [PSCustomObject]@{
            Numero    = $index
            Interfaz  = $adapter.InterfaceAlias
            Direccion = $adapter.IPAddress
            Estado    = $netAdapter.Status
            IfIndex   = $adapter.InterfaceIndex
        }
        
        $script:listaInterfaces += $info
        Write-Host ("  {0}) {1,-15} (IP actual: {2})" -f $index, $adapter.InterfaceAlias, $adapter.IPAddress)
        $index++
    }
    Write-Host ""
    
    while ($true) {
        $selection = Read-Host "Seleccione el numero de la interfaz para DHCP [1-$($script:listaInterfaces.Count)]"
        
        if ($selection -match '^\d+$') {
            $selectionNum = [int]$selection
            
            if ($selectionNum -ge 1 -and $selectionNum -le $script:listaInterfaces.Count) {
                $script:interfazSeleccionada = $script:listaInterfaces[$selectionNum - 1]
                break
            }
        }
        
        Write-Host "Seleccion invalida. Ingrese un numero entre 1 y $($script:listaInterfaces.Count)" 
    }
    
    Write-Host ""
    Write-Host "Interfaz de red seleccionada: $($script:interfazSeleccionada.Interfaz)" 
}

#
# Funciones dependientes del usuario -> parametros de entrada
#

function parametros_usuario {
    Write-Host ""
    Write-Host "Ingrese los siguientes parametros:"
    
    Write-Host ""
    $script:nombreScope = Read-Host "Nombre del Scope"
    if ([string]::IsNullOrWhiteSpace($script:nombreScope)) {
        $script:nombreScope = "RedInterna"
    }
    
    while ($true) {
        Write-Host ""
        $script:red = Read-Host "Segmento de red"
        if (validar_ip $script:red) { break }
    }
    
    while ($true) {
        Write-Host ""
        $script:mascara = Read-Host "Mascara de Red"
        if (validar_ip $script:mascara) { break }
    }
    
    while ($true) {
        Write-Host ""
        $script:ipInicio = Read-Host "IP donde inicia el rango del DHCP"
        if (validar_ip $script:ipInicio) { break }
    }
    
    while ($true) {
        Write-Host ""
        $script:ipFin = Read-Host "IP donde finaliza el rango del DHCP"
        if (validar_ip $script:ipFin) { break }
    }
    
    while ($true) {
        Write-Host ""
        $script:gateway = Read-Host "IP del servidor gateway"
        if (validar_ip $script:gateway) { break }
    }
    
    while ($true) {
        Write-Host ""
        $script:dns = Read-Host "IP del servidor DNS (presione Enter para omitir)"
        
        # Si el usuario deja el campo vacio, se omite el DNS
        if ([string]::IsNullOrWhiteSpace($script:dns)) {
            $script:dns = $null
            Write-Host ""
            Write-Host "DNS omitido - no se configurara servidor DNS" 
            break
        }
        
        # Si ingreso algo, validar que sea una IP valida
        if (validar_ip $script:dns) { break }
    }
    
    while ($true) {
        Write-Host ""
        $leaseSeconds = Read-Host "Lease Time (tiempo en segundos)"

        if ($leaseSeconds -match '^\d+$' -and [int]$leaseSeconds -gt 0) {
            $script:leaseTime = New-TimeSpan -Seconds ([int]$leaseSeconds)
            
            # Mostrar conversion para que el usuario sepa cuanto tiempo es
            $totalSegundos = [int]$leaseSeconds
            $dias = [math]::Floor($totalSegundos / 86400)
            $horas = [math]::Floor(($totalSegundos % 86400) / 3600)
            $minutos = [math]::Floor(($totalSegundos % 3600) / 60)
            $segs = $totalSegundos % 60
            
            Write-Host ""
            Write-Host "Tiempo configurado: $dias dias, $horas horas, $minutos minutos, $segs segundos" 
            break
        } else {
            Write-Host "Debe ser un numero entero positivo" 
        }
    }
}

function configurar_interfaz_red {
    Write-Host ""
    Write-Host "Configurando interfaz de red con IP estatica..."
    
    $interfazNombre = $script:interfazSeleccionada.Interfaz
    $interfazIndex = $script:interfazSeleccionada.IfIndex
    
    Write-Host "Eliminando configuracion IP anterior..."
    
    # Eliminar todas las IPs de la interfaz
    Get-NetIPAddress -InterfaceIndex $interfazIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
        Where-Object { $_.IPAddress -notlike "127.*" } |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    
    # Eliminar gateway anterior
    Get-NetRoute -InterfaceIndex $interfazIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    
    Write-Host "Creando perfil de red con IP: $($script:gateway)..."
    
    # Agregar nueva IP estatica (la IP del gateway = IP del servidor)
    try {
        New-NetIPAddress `
            -InterfaceIndex $interfazIndex `
            -IPAddress $script:gateway `
            -PrefixLength 24 `
            -DefaultGateway $script:gateway `
            -ErrorAction Stop | Out-Null
        
        Write-Host "Perfil de red creado" 
    } catch {
        Write-Host "Error al crear perfil de red: $_" 
        exit 1
    }
    
    Write-Host "Activando conexion..."
    
    # Configurar DNS (opcional, pero util)
    if ($script:dns) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $interfazIndex -ServerAddresses $script:dns -ErrorAction SilentlyContinue
        } catch {
            # No es critico si falla
        }
    }
    
    Start-Sleep -Seconds 2
    
    Write-Host "Interfaz configurada con IP: $($script:gateway)" 
    
    Write-Host ""
    Write-Host "Verificando configuracion de red..."
    Get-NetIPAddress -InterfaceIndex $interfazIndex -AddressFamily IPv4 | 
        Format-Table InterfaceAlias, IPAddress, PrefixLength -AutoSize
}

function config_dhcp {
    Write-Host ""
    Write-Host "Configuracion del servidor DHCP"
    
    Write-Host ""
    Write-Host "Verificando scope anterior..."
    
    # Buscar scope por nombre ya que el ScopeId aun no existe
    $existingScope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -eq $script:nombreScope }

    if ($existingScope) {
        Write-Host "Eliminando scope anterior..." 
        Remove-DhcpServerv4Scope -ScopeId $existingScope.ScopeId -Force
        Write-Host "Scope anterior eliminado" 
    }
    
    Write-Host ""
    Write-Host "Generando scope DHCP..."
    
    try {
        $nuevoScope = Add-DhcpServerv4Scope `
            -Name $script:nombreScope `
            -StartRange $script:ipInicio `
            -EndRange $script:ipFin `
            -SubnetMask $script:mascara `
            -LeaseDuration $script:leaseTime `
            -State Active `
            -ErrorAction Stop -PassThru
        
        # Guardar el ScopeId generado automaticamente
        $script:red = $nuevoScope.ScopeId
        
        Write-Host ""
        Write-Host "Scope creado exitosamente" 
    } catch {
        Write-Host ""
        Write-Host "Error al crear scope: $_" 
        exit 1
    }
    
    Write-Host ""
    Write-Host "Configurando opciones de red (Gateway y DNS)..."
    
    # Configurar siempre el Gateway (Router)
    try {
        Set-DhcpServerv4OptionValue `
            -ScopeId $script:red `
            -Router $script:gateway `
            -ErrorAction Stop | Out-Null
        
        Write-Host "Gateway configurado correctamente" 
    } catch {
        Write-Host "Error al configurar Gateway: $_" 
        exit 1
    }
    
    # Configurar DNS solo si fue proporcionado
    if ($script:dns) {
        Write-Host ""
        Write-Host "Validando los servidores DNS..."
        
        # Intentar hacer ping al DNS para validar
        $pingResult = Test-Connection -ComputerName $script:dns -Count 1 -Quiet -ErrorAction SilentlyContinue
        
        if ($pingResult) {
            Write-Host "Validando el servidor DNS $script:dns." 
            
            try {
                Set-DhcpServerv4OptionValue `
                    -ScopeId $script:red `
                    -DnsServer $script:dns `
                    -ErrorAction Stop | Out-Null
                
                Write-Host ""
                Write-Host "0/1+ completado" 
                Write-Host "[" 
            } catch {
                Write-Host ""
                Write-Host "Advertencia: No se pudo configurar el DNS. Continuando sin DNS..." 
                Write-Host "Error: $_" 
            }
        } else {
            Write-Host ""
            Write-Host "Advertencia: El servidor DNS $script:dns no responde a ping." 
            Write-Host "Continuando sin configurar DNS..." 
        }
    } else {
        Write-Host ""
        Write-Host "DNS no configurado (omitido por el usuario)" 
    }
    
    Write-Host ""
    Write-Host "Configurando firewall..."
    
    $ruleName = "DHCP_Server_Monitor"
    
    $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existingRule) {
        Remove-NetFirewallRule -DisplayName $ruleName
    }
    
    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Direction Inbound `
        -Protocol UDP `
        -LocalPort 67 `
        -Action Allow `
        -Enabled True `
        -ErrorAction SilentlyContinue | Out-Null
    
    Write-Host ""
    Write-Host "Firewall reconfigurado correctamente" 
}

function iniciar_dhcp {
    Write-Host ""
    Write-Host "Iniciando servicio DHCP"
    
    $serviceName = "DHCPServer"
    
    Write-Host ""
    Write-Host "Habilitando servicio..."
    Set-Service -Name $serviceName -StartupType Automatic
    
    Write-Host ""
    Write-Host "Iniciando servicio..."
    
    try {
        Restart-Service -Name $serviceName -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        
        $service = Get-Service -Name $serviceName
        
        if ($service.Status -eq "Running") {
            Write-Host ""
            Write-Host "Servicio DHCP iniciado correctamente" 
        } else {
            Write-Host ""
            Write-Host "Fallo el inicio del servicio" 
            Write-Host "Estado: $($service.Status)" 
        }
    } catch {
        Write-Host ""
        Write-Host "Fallo el inicio del servicio" 
        Write-Host "Error: $_" 
        exit 1
    }
}

#
# Funcion de monitoreo constante
#

function monitoreo_info {
    Write-Host ""
    Write-Host " Informacion de Monitoreo DHCP"
    Write-Host ""
    
    # Estado del servicio
    Write-Host "Estado del servicio:"
    Write-Host "--------------------"
    $service = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq "Running") {
        Write-Host "Servicio: ACTIVO (running)" 
    } else {
        Write-Host "Servicio: $($service.Status)" 
    }
    Write-Host ""
    
    # Configuracion de red
    Write-Host ""
    Write-Host "Configuracion de red:"
    Write-Host "---------------------"
    Write-Host "Interfaz: $($script:interfazSeleccionada.Interfaz)"
    
    $currentIP = Get-NetIPAddress -InterfaceIndex $script:interfazSeleccionada.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" } |
        Select-Object -First 1
    
    if ($currentIP) {
        Write-Host "IP: $($currentIP.IPAddress)/$($currentIP.PrefixLength)"
    }
    Write-Host ""
    
    # Concesiones activas (solo IPs unicas)
    Write-Host ""
    Write-Host "Concesiones activas:"
    Write-Host "--------------------"
    
    $leases = Get-DhcpServerv4Lease -ScopeId $script:red -ErrorAction SilentlyContinue
    
    if ($leases) {
        # Agrupar por IP y tomar solo la mas reciente
        # Forzar array con @() para que .Count funcione con 1 elemento
        $uniqueLeases = @($leases | Group-Object IPAddress | ForEach-Object {
            $_.Group | Sort-Object LeaseExpiryTime -Descending | Select-Object -First 1
        })
        
        foreach ($lease in $uniqueLeases) {
            Write-Host "  * $($lease.IPAddress)"
        }
        
        Write-Host ""
        Write-Host "Total de clientes conectados: $($uniqueLeases.Count)"
    } else {
        Write-Host "Sin concesiones activas"
    }
    
    Write-Host ""
    Write-Host "Presiona Ctrl+C para salir del monitoreo"
    Write-Host ""
}

#
# Funcion preparativa e idempotente
#

function pre_main {
    # Detectar si el DHCP esta instalado
    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    
    if (-not $dhcpFeature.Installed) {
        Write-Host ""
        Write-Host "DHCP Server no esta instalado"
        Write-Host "Instalando DHCP Server..." 
        
        Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
        
        Write-Host ""
        Write-Host "dhcp-server instalado correctamente" 
        Write-Host "prosiguiendo con la configuracion..."
        
        # Configuracion post-instalacion
        try {
            $serverName = $env:COMPUTERNAME
            Add-DhcpServerInDC -DnsName "$serverName" -IPAddress (
                Get-NetIPAddress -AddressFamily IPv4 | 
                Where-Object {$_.IPAddress -notlike "127.*"} | 
                Select-Object -First 1
            ).IPAddress -ErrorAction SilentlyContinue | Out-Null
        } catch {
            # No critico
        }
        
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" `
                         -Name "ConfigurationState" -Value 2 -ErrorAction SilentlyContinue
        
        deteccion_interfaces_red
        parametros_usuario
        configurar_interfaz_red
        config_dhcp
        iniciar_dhcp
        return
    } else {
        Write-Host ""
        Write-Host "dhcp-server ya esta instalado" 
        deteccion_interfaces_red
        Write-Host "prosiguiendo al monitoreo..."
        
        # Obtener el primer scope para monitoreo
        $existingScope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($existingScope) {
            $script:red = $existingScope.ScopeId
        }
        return
    }
}

function main {
    Clear-Host
    
    Write-Host "======================================" 
    Write-Host "  Sistema de Monitoreo DHCP" 
    Write-Host "======================================" 
    
    # Verificar privilegios de administrador
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    $isAdmin = $currentPrincipal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    
    if (-not $isAdmin) {
        Write-Host ""
        Write-Host "ERROR: Este script debe ejecutarse con privilegios de Administrador" 
        Write-Host "Haz clic derecho en PowerShell y selecciona 'Ejecutar como administrador'" 
        Write-Host ""
        Read-Host "Presiona Enter para salir"
        exit 1
    }
    
    Write-Host ""
    pre_main
    
    # Monitoreo continuo con actualizacion cada 30 segundos
    while ($true) {
        Clear-Host
        monitoreo_info
        Start-Sleep -Seconds 10
    }
}

main