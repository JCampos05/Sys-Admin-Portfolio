$ErrorActionPreference = "Stop"
#
#   Variables Globales
#
$script:interfaces = @()
$script:listaInterfaces = @()
$script:interfazSeleccionada = $null
$script:nombreScope = ""
$script:red = ""
$script:mascara = ""
$script:bitsMascara = 0
$script:ipInicio = ""
$script:ipFin = ""
$script:gateway = ""
$script:dns = ""
$script:leaseTime = $null
#
#   Funciones de Validacion de IP
#
# Valida el formato basico de IPv4
function validar_formato_ip {
    param([string]$ip)
    
    # Verifica que tenga el patron correcto: numero.numero.numero.numero
    if ($ip -notmatch '^(\d{1,3}\.){3}\d{1,3}$') {
        return $false
    }
    
    # Verifica que cada octeto este en el rango 0-255
    $octetos = $ip.Split('.')
    foreach ($octeto in $octetos) {
        $num = [int]$octeto
        if ($num -lt 0 -or $num -gt 255) {
            return $false
        }
    }
    
    return $true
}

# Valida que la IP sea usable -> no reservada ej -> 127.0.0.0 -> 0.0.0.0
function validar_ip_usable {
    param([string]$ip)
    
    # Primero validar el formato
    if (-not (validar_formato_ip $ip)) {
        Write-Host "Error: Formato IPv4 incorrecto"
        return $false
    }
    
    # Extrae los octetos de la IP
    $octetos = $ip.Split('.')
    $oct1 = [int]$octetos[0]
    $oct2 = [int]$octetos[1]
    $oct3 = [int]$octetos[2]
    $oct4 = [int]$octetos[3]
    
    # Valida IPs reservadas que NO son usables
    
    # 1. Red 0.0.0.0/8
    if ($oct1 -eq 0) {
        Write-Host "Error: La red 0.0.0.0/8 es reservada -> No utilizable"
        return $false
    }
    
    # Red 127.0.0.0/8
    if ($oct1 -eq 127) {
        Write-Host "Error: La red 127.0.0.0/8 (localhost)"
        return $false
    }
    
    # 3. IP de broadcast
    if ($oct1 -eq 255 -and $oct2 -eq 255 -and $oct3 -eq 255 -and $oct4 -eq 255) {
        Write-Host "Error: 255.255.255.255 es direccion de broadcast"
        return $false
    }
    
    # 4. Redes multicast 224.0.0.0/4
    if ($oct1 -ge 224 -and $oct1 -le 239) {
        Write-Host "Error: Redes 224.0.0.0 a 239.255.255.255 son multicast"
        return $false
    }
    
    # 5. Redes experimentales 240.0.0.0/4
    if ($oct1 -ge 240 -and $oct1 -le 255) {
        Write-Host "Error: Redes 240.0.0.0 a 255.255.255.255 son experimentales"
        return $false
    }
    
    return $true
}

# Calcula -> mascara de subred
function calcular_mascara {
    param([string]$ip)
    
    $octetos = $ip.Split('.')
    $oct1 = [int]$octetos[0]
    
    # Determinar la clase de red y asignar mascara por defecto
    # Clase A: 1.0.0.0 a 126.0.0.0 -> Mascara /8 (255.0.0.0)
    # Clase B: 128.0.0.0 a 191.255.0.0 -> Mascara /16 (255.255.0.0)
    # Clase C: 192.0.0.0 a 223.255.255.0 -> Mascara /24 (255.255.255.0)
    
    if ($oct1 -ge 1 -and $oct1 -le 126) {
        # Clase A
        $script:mascara = "255.0.0.0"
        $script:bitsMascara = 8
        Write-Host "Clase A detectada - Mascara: $($script:mascara) (/8)"
        
    } elseif ($oct1 -ge 128 -and $oct1 -le 191) {
        # Clase B
        $script:mascara = "255.255.0.0"
        $script:bitsMascara = 16
        Write-Host "Clase B detectada - Mascara: $($script:mascara) (/16)"
        
    } elseif ($oct1 -ge 192 -and $oct1 -le 223) {
        # Clase C
        $script:mascara = "255.255.255.0"
        $script:bitsMascara = 24
        Write-Host "Clase C detectada - Mascara: $($script:mascara) (/24)"
        
    } else {
        Write-Host "Error: No se pudo determinar clase de red"
        return $false
    }
    
    # Calcula cantidad de IPs usables
    # Formula: 2^(32-bits_mascara) - 2
    # Resta 2 -> primera IP es la de red y la ultima es broadcast
    $hostsBits = 32 - $script:bitsMascara
    $ipsTotales = [math]::Pow(2, $hostsBits)
    $ipsUsables = $ipsTotales - 2
    
    Write-Host "IPs totales: $ipsTotales"
    Write-Host "IPs usables: $ipsUsables (excluyendo red y broadcast)"
    
    return $true
}

# Convierte la IP a numero entero (para comparaciones)
function ip_a_numero {
    param([string]$ip)
    
    $octetos = $ip.Split('.')
    $oct1 = [int64]$octetos[0]
    $oct2 = [int64]$octetos[1]
    $oct3 = [int64]$octetos[2]
    $oct4 = [int64]$octetos[3]
    
    return ($oct1 * [math]::Pow(256, 3) + $oct2 * [math]::Pow(256, 2) + $oct3 * 256 + $oct4)
}

# Obtiene la IP de red a partir de IP y mascara
function obtener_ip_red {
    param(
        [string]$ip,
        [string]$mascara
    )
    
    $ipOctetos = $ip.Split('.')
    $mascaraOctetos = $mascara.Split('.')
    
    # AND bit a bit entre IP y mascara
    $red1 = [int]$ipOctetos[0] -band [int]$mascaraOctetos[0]
    $red2 = [int]$ipOctetos[1] -band [int]$mascaraOctetos[1]
    $red3 = [int]$ipOctetos[2] -band [int]$mascaraOctetos[2]
    $red4 = [int]$ipOctetos[3] -band [int]$mascaraOctetos[3]
    
    return "$red1.$red2.$red3.$red4"
}

# Valida que una IP pertenezca al mismo segmento
function validar_mismo_segmento {
    param(
        [string]$ipBase,
        [string]$ipComparar,
        [string]$mascara
    )
    
    # Obtene la red de ambas IPs
    $redBase = obtener_ip_red $ipBase $mascara
    $redComparar = obtener_ip_red $ipComparar $mascara
    
    # Compara si pertenecen a la misma red
    if ($redBase -ne $redComparar) {
        Write-Host "Error: La IP $ipComparar no pertenece al segmento $redBase"
        return $false
    }
    
    return $true
}

# Valida que IP inicial sea menor que IP final
function validar_rango_ips {
    param(
        [string]$ipInicio,
        [string]$ipFin
    )
    
    # Convierte las IPs completas a numeros para comparar
    $numInicio = ip_a_numero $ipInicio
    $numFin = ip_a_numero $ipFin
    
    # Compara los valores numericos de las IPs
    if ($numInicio -ge $numFin) {
        Write-Host "Error: La IP inicial debe ser menor que la IP final"
        Write-Host "IP Inicial: $ipInicio (valor: $numInicio)"
        Write-Host "IP Final: $ipFin (valor: $numFin)"
        return $false
    }
    
    return $true
}

# Valida que las IPs no sean direccion de red ni broadcast
function validar_ip_no_especial {
    param(
        [string]$ip,
        [string]$red,
        [string]$mascara
    )
    
    # Calcular IP de broadcast
    $redOctetos = $red.Split('.')
    $mascaraOctetos = $mascara.Split('.')
    
    # Broadcast
    $b1 = ([int]$redOctetos[0] -band [int]$mascaraOctetos[0]) -bor (255 - [int]$mascaraOctetos[0])
    $b2 = ([int]$redOctetos[1] -band [int]$mascaraOctetos[1]) -bor (255 - [int]$mascaraOctetos[1])
    $b3 = ([int]$redOctetos[2] -band [int]$mascaraOctetos[2]) -bor (255 - [int]$mascaraOctetos[2])
    $b4 = ([int]$redOctetos[3] -band [int]$mascaraOctetos[3]) -bor (255 - [int]$mascaraOctetos[3])
    
    $broadcast = "$b1.$b2.$b3.$b4"
    
    # Verifica que no sea la IP de red
    if ($ip -eq $red) {
        Write-Host "Error: No puede usar la IP de red ($red)"
        return $false
    }
    
    # Verifica que no sea la IP de broadcast
    if ($ip -eq $broadcast) {
        Write-Host "Error: No puede usar la IP de broadcast ($broadcast)"
        return $false
    }
    
    return $true
}
#
#   Funciones de Deteccion y Configuracion
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
#   Funciones semi principales -> usadas por las principales
#
function parametros_usuario {
    Write-Host ""
    Write-Host "-------------------------------"
    Write-Host " Configuracion de parametros"
    Write-Host "--------------------------------"
    
    Write-Host ""
    $script:nombreScope = Read-Host "Nombre del Scope"
    if ([string]::IsNullOrWhiteSpace($script:nombreScope)) {
        $script:nombreScope = "RedInterna"
    }
    
    # Solicita y valida segmento de red
    while ($true) {
        Write-Host ""
        Write-Host "Ingrese el segmento de red (ej: 192.168.100.0)"
        $script:red = Read-Host "Segmento de red"
        
        Write-Host ""
        # 1 -> Validar formato
        if (-not (validar_formato_ip $script:red)) {
            Write-Host "Formato de IP invalido"
            continue
        }
        
        # 2 -> Validar que sea usable
        if (-not (validar_ip_usable $script:red)) {
            continue
        }
        
        # 3 -> Calcular mascara automatica
        if (-not (calcular_mascara $script:red)) {
            continue
        }
        
        # 4 -> Normalizar a IP de red
        $redCalculada = obtener_ip_red $script:red $script:mascara
        
        if ($script:red -ne $redCalculada) {
            Write-Host ""
            Write-Host "Aviso: El segmento ingresado no es la IP de red"
            Write-Host "IP ingresada: $($script:red)"
            Write-Host "IP de red correcta: $redCalculada"
            Write-Host ""
            
            $confirmar = Read-Host "Usar la IP de red correcta ($redCalculada)? (s/n)"
            
            if ($confirmar -match '^[Ss]$') {
                $script:red = $redCalculada
                Write-Host "IP de red actualizada a: $($script:red)"
                break
            } else {
                Write-Host "Por favor, ingrese nuevamente el segmento de red"
                continue
            }
        }
        
        break
    }
    
    # Gateway
    while ($true) {
        Write-Host ""
        Write-Host "Ingrese la IP del gateway (servidor DHCP)"
        $script:gateway = Read-Host "Gateway"
        
        Write-Host ""
        
        # Validar formato
        if (-not (validar_formato_ip $script:gateway)) {
            Write-Host "Formato de IP invalido"
            continue
        }
        
        # Validar que sea usable
        if (-not (validar_ip_usable $script:gateway)) {
            continue
        }
        
        # Validar que pertenezca al segmento
        if (-not (validar_mismo_segmento $script:red $script:gateway $script:mascara)) {
            continue
        }
        
        # Validar que no sea red ni broadcast
        if (-not (validar_ip_no_especial $script:gateway $script:red $script:mascara)) {
            continue
        }
        
        Write-Host "Gateway validado correctamente"
        break
    }
    
    # IP Inicio del rango
    while ($true) {
        Write-Host ""
        Write-Host "Ingrese la IP donde inicia el rango DHCP"
        $script:ipInicio = Read-Host "IP inicial"
        
        Write-Host ""
        
        # Validar formato
        if (-not (validar_formato_ip $script:ipInicio)) {
            Write-Host "Formato de IP invalido"
            continue
        }
        
        # Validar que sea usable
        if (-not (validar_ip_usable $script:ipInicio)) {
            continue
        }
        
        # Validar que pertenezca al segmento
        if (-not (validar_mismo_segmento $script:red $script:ipInicio $script:mascara)) {
            continue
        }
        
        # Validar que no sea red ni broadcast
        if (-not (validar_ip_no_especial $script:ipInicio $script:red $script:mascara)) {
            continue
        }
        
        Write-Host "IP inicial validada correctamente"
        break
    }
    
    # IP Fin del rango
    while ($true) {
        Write-Host ""
        Write-Host "Ingrese la IP donde finaliza el rango DHCP"
        $script:ipFin = Read-Host "IP final"
        
        Write-Host ""
        
        # Validar formato
        if (-not (validar_formato_ip $script:ipFin)) {
            Write-Host "Formato de IP invalido"
            continue
        }
        
        # Validar que sea usable
        if (-not (validar_ip_usable $script:ipFin)) {
            continue
        }
        
        # Validar que pertenezca al segmento
        if (-not (validar_mismo_segmento $script:red $script:ipFin $script:mascara)) {
            continue
        }
        
        # Validar que no sea red ni broadcast
        if (-not (validar_ip_no_especial $script:ipFin $script:red $script:mascara)) {
            continue
        }
        
        # Validar que IP inicial < IP final
        if (-not (validar_rango_ips $script:ipInicio $script:ipFin)) {
            continue
        }
        
        Write-Host "IP final validada correctamente"
        break
    }
    
    # DNS (opcional)
    while ($true) {
        Write-Host ""
        Write-Host "Ingrese la IP del servidor DNS (presione Enter para omitir)"
        $script:dns = Read-Host "DNS"
        
        # Si el usuario deja el campo vacio, se omite el DNS
        if ([string]::IsNullOrWhiteSpace($script:dns)) {
            $script:dns = $null
            Write-Host ""
            Write-Host "DNS omitido - no se configurara servidor DNS"
            break
        }
        
        Write-Host ""
        
        # Si ingreso algo, validar que sea una IP valida
        if (-not (validar_formato_ip $script:dns)) {
            Write-Host "Formato de IP invalido"
            continue
        }
        
        # Validar que sea usable (puede estar fuera del segmento)
        if (-not (validar_ip_usable $script:dns)) {
            continue
        }
        
        Write-Host "DNS validado correctamente"
        break
    }
    
    # Lease Time
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
    
    # Resumen de configuracion
    Write-Host ""
    Write-Host "-------------------------------"
    Write-Host " Resumen de Configuracion"
    Write-Host "-------------------------------"
    Write-Host "Nombre del Scope: $($script:nombreScope)"
    Write-Host "Segmento de red: $($script:red)"
    Write-Host "Mascara de subred: $($script:mascara) (/$($script:bitsMascara))"
    Write-Host "Rango DHCP: $($script:ipInicio) - $($script:ipFin)"
    Write-Host "Gateway: $($script:gateway)"
    if ($script:dns) {
        Write-Host "DNS: $($script:dns)"
    } else {
        Write-Host "DNS: No configurado"
    }
    Write-Host "Lease Time: $($script:leaseTime)"
    Write-Host "-------------------------------"
    Write-Host ""
}

function configurar_interfaz_red {
    Write-Host ""
    Write-Host "Configurando interfaz de red con IP estatica..."

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
            -PrefixLength $script:bitsMascara `
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
        Add-DhcpServerv4Scope `
            -Name $script:nombreScope `
            -StartRange $script:ipInicio `
            -EndRange $script:ipFin `
            -SubnetMask $script:mascara `
            -LeaseDuration $script:leaseTime `
            -State Active `
            -ErrorAction Stop | Out-Null
        
        Write-Host "Scope creado exitosamente"
    } catch {
        Write-Host "Error al crear scope: $_"
        exit 1
    }
    
    Write-Host ""
    Write-Host "Configurando opciones del scope..."
    
    try {
        Set-DhcpServerv4OptionValue `
            -ScopeId $script:red `
            -Router $script:gateway `
            -ErrorAction Stop | Out-Null
        
        Write-Host "Gateway configurado correctamente"
    } catch {
        Write-Host "Error al configurar gateway: $_"
        exit 1
    }
    
    # Configurar DNS solo si fue proporcionado
    if ($script:dns) {
        Write-Host ""
        Write-Host "Validando los servidores DNS..."
        
        # Intentar hacer ping al DNS para validar
        $pingResult = Test-Connection -ComputerName $script:dns -Count 1 -Quiet -ErrorAction SilentlyContinue
        
        if ($pingResult) {
            Write-Host "Validando el servidor DNS $($script:dns)."
            
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
            Write-Host "Advertencia: El servidor DNS $($script:dns) no responde a ping."
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
#   Monitor tiempo real
#
function monitoreo_info {
    Write-Host ""
    Write-Host " Informacion de Monitoreo DHCP"
    Write-Host ""
    
    Write-Host "Estado del servicio:"
    Write-Host "--------------------"
    $service = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq "Running") {
        Write-Host "Servicio: ACTIVO"
    } else {
        Write-Host "Servicio: $($service.Status)"
    }
    Write-Host ""
    
    Write-Host ""
    Write-Host "Configuracion de red:"
    Write-Host "---------------------"
    
    # Obtener información del scope para determinar la interfaz
    try {
        $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
        
        if ($scopes) {
            $scopeId = $scopes[0].ScopeId.ToString()
            $redOctetos = $scopeId.Split('.')
            
            # Buscar la interfaz que corresponde al scope configurado
            $interfazDHCP = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
                Where-Object {
                    $_.IPAddress -notlike "127.*" -and
                    $_.IPAddress -notlike "169.254.*" -and
                    $_.IPAddress -like "$($redOctetos[0]).$($redOctetos[1]).*"
                } | Select-Object -First 1
            
            if ($interfazDHCP) {
                $adapter = Get-NetAdapter -InterfaceIndex $interfazDHCP.InterfaceIndex -ErrorAction SilentlyContinue
                Write-Host "Interfaz: $($adapter.Name)"
                Write-Host "IP: $($interfazDHCP.IPAddress)/$($interfazDHCP.PrefixLength)"
            } else {
                Write-Host "Interfaz: No detectada automaticamente"
                Write-Host "IP: Verificar configuracion manual"
            }
        } else {
            Write-Host "Interfaz: Sin scope configurado"
            Write-Host "IP: N/A"
        }
    } catch {
        Write-Host "Interfaz: Error al obtener informacion"
        Write-Host "IP: N/A"
    }
    Write-Host ""
    
    Write-Host ""
    Write-Host "Concesiones activas:"
    Write-Host "--------------------"
    
    # Obtener scopes y sus concesiones
    try {
        $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
        
        if ($scopes) {
            $allLeases = @()
            
            foreach ($scope in $scopes) {
                $leases = Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue
                
                if ($leases) {
                    $allLeases += $leases
                }
            }
            
            if ($allLeases.Count -gt 0) {
                # Agrupar por IP y tomar solo la mas reciente
                $uniqueLeases = @($allLeases | Group-Object IPAddress | ForEach-Object {
                    $_.Group | Sort-Object LeaseExpiryTime -Descending | Select-Object -First 1
                })
                
                foreach ($lease in $uniqueLeases) {
                    $estado = if ($lease.AddressState -eq "Active") { "ACTIVO" } else { $lease.AddressState }
                    Write-Host "  - $($lease.IPAddress) [$estado] - $($lease.HostName)"
                }
                
                Write-Host ""
                Write-Host "Total de clientes conectados: $($uniqueLeases.Count)"
            } else {
                Write-Host "Sin concesiones activas"
            }
        } else {
            Write-Host "No hay scopes configurados"
        }
    } catch {
        Write-Host "Error al obtener concesiones: $_"
    }
    
    Write-Host ""
    Write-Host "Presiona Ctrl+C para salir del monitoreo"
    Write-Host ""
}
#
#   Funciones del Menu Principal
#
function verificar_instalacion {
    Write-Host ""
    Write-Host "Verificando instalacion del servicio DHCP..."
    Write-Host ""
    
    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    
    if ($dhcpFeature.Installed) {
        Write-Host "Estado: INSTALADO"
        Write-Host ""
        
        $service = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
        
        if ($service) {
            Write-Host "Nombre: DHCP Server"
            Write-Host "Estado del servicio: $($service.Status)"
            Write-Host "Tipo de inicio: $($service.StartType)"
        }
        Write-Host ""
        
        $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
        if ($scopes) {
            Write-Host "Scopes configurados:"
            foreach ($scope in $scopes) {
                Write-Host "  - $($scope.Name): $($scope.ScopeId)/$($scope.SubnetMask)"
            }
        } else {
            Write-Host "No hay scopes configurados"
        }
    } else {
        Write-Host "Estado: NO INSTALADO"
        Write-Host ""
        $respuesta = Read-Host "Desea instalar el servicio ahora? (s/n)"
        
        if ($respuesta -match '^[Ss]$') {
            Write-Host ""
            Write-Host "Iniciando instalacion..."
            
            try {
                Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
                Write-Host "Instalacion finalizada correctamente"
            } catch {
                Write-Host "Error: Fallo la instalacion del servicio"
                Write-Host "Verifique los permisos y requisitos del sistema"
            }
        } else {
            Write-Host "Instalacion cancelada"
        }
    }
}

function instalar_servicio {
    Write-Host ""
    Write-Host "-----------------------------------"
    Write-Host "  Proceso de Instalacion Completo"
    Write-Host "-----------------------------------"
    Write-Host ""
    Write-Host "Este proceso instalara y configurara el servidor DHCP"
    Write-Host ""
    
    # Verifica si ya esta instalado
    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    
    if ($dhcpFeature.Installed) {
        Write-Host "El servicio ya esta instalado"
        Write-Host ""
        $reconfig = Read-Host "Desea reconfigurar el servicio? (s/n)"
        
        if ($reconfig -notmatch '^[Ss]$') {
            Write-Host "Operacion cancelada"
            return
        }
    } else {
        # Servicio NO instalado, confirmar instalacion
        $respuesta = Read-Host "Desea instalar el servicio DHCP? (s/n)"
        
        if ($respuesta -notmatch '^[Ss]$') {
            Write-Host "Instalacion cancelada"
            return
        }
        
        Write-Host ""
        Write-Host "Iniciando instalacion..."
        
        # Instalacion
        try {
            Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
            Write-Host "Instalacion finalizada correctamente"
            Write-Host ""
            
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
        } catch {
            Write-Host "Error: Fallo la instalacion del servicio"
            Write-Host "Verifique los permisos y requisitos del sistema"
            return
        }
    }
    
    # Configuracion completa
    Write-Host "Procediendo con la configuracion..."
    Write-Host ""
    
    deteccion_interfaces_red
    parametros_usuario
    configurar_interfaz_red
    config_dhcp
    iniciar_dhcp
    
    Write-Host ""
    Write-Host "--------------------------------"
    Write-Host "Instalacion y configuracion completadas"
    Write-Host "El servicio DHCP esta activo y funcionando"
    Write-Host "--------------------------------"
}

function nueva_configuracion {
    Write-Host ""
    Write-Host "--------------------------------"
    Write-Host "  NUEVA CONFIGURACION DHCP"
    Write-Host "--------------------------------"
    Write-Host ""
    Write-Host "Esta opcion permite reconfigurar un servidor DHCP ya instalado."
    Write-Host "Si existe una configuracion previa, sera reemplazada."
    Write-Host ""
    Write-Host "Nota: Si el servicio no esta instalado, use la opcion 2"
    Write-Host ""
    $respuesta = Read-Host "Desea continuar? (s/n)"
    
    if ($respuesta -notmatch '^[Ss]$') {
        Write-Host "Configuracion cancelada"
        return
    }
    
    Write-Host ""
    Write-Host "Verificando instalacion del servicio..."
    
    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    
    if (-not $dhcpFeature.Installed) {
        Write-Host ""
        Write-Host "Error: El servicio DHCP no esta instalado"
        Write-Host ""
        Write-Host "Por favor, use la opcion 2 del menu para instalar y configurar"
        Write-Host "el servicio por primera vez."
        return
    }
    
    Write-Host ""
    Write-Host "Iniciando reconfiguracion..."
    
    deteccion_interfaces_red
    parametros_usuario
    configurar_interfaz_red
    config_dhcp
    iniciar_dhcp
    
    Write-Host ""
    Write-Host "--------------------------------"
    Write-Host "Reconfiguracion completada exitosamente"
    Write-Host "--------------------------------"
}

function reiniciar_servicio {
    Write-Host "--------------------------------"
    Write-Host "Reiniciando servicio DHCP..."
    Write-Host "--------------------------------"
    
    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    
    if (-not $dhcpFeature.Installed) {
        Write-Host "Error: El servicio no esta instalado"
        return
    }
    
    try {
        Restart-Service -Name DHCPServer -Force -ErrorAction Stop
        Write-Host "Servicio reiniciado correctamente"
        Write-Host ""
        
        $service = Get-Service -Name DHCPServer
        Write-Host "Estado: $($service.Status)"
    } catch {
        Write-Host "Error al reiniciar el servicio"
        Write-Host "Error: $_"
    }
}

function modo_monitor {
    Write-Host ""
    Write-Host "Iniciando modo monitor..."
    Write-Host "Presiona Ctrl+C para salir"
    Write-Host ""
    Start-Sleep -Seconds 2
    
    while ($true) {
        Clear-Host
        monitoreo_info
        Start-Sleep -Seconds 5
    }
}

function ver_configuracion_actual {
    Write-Host ""
    Write-Host "------------------------------------"
    Write-Host " Configuracion Actual del Servidor"
    Write-Host "------------------------------------"
    Write-Host ""
    
    # Verificar si el servicio esta instalado
    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    
    if (-not $dhcpFeature.Installed) {
        Write-Host "El servicio DHCP no esta instalado"
        return
    }
    
    Write-Host "1. Estado del Servicio:"
    Write-Host "----------------------"
    $service = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    
    if ($service) {
        Write-Host "Estado: $($service.Status)"
        Write-Host "Inicio automatico: $($service.StartType)"
    } else {
        Write-Host "Servicio no encontrado"
    }
    Write-Host ""
    
    # Obtener configuracion de scopes
    Write-Host "2. Configuracion DHCP:"
    Write-Host "---------------------"
    
    $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
    
    if ($scopes) {
        foreach ($scope in $scopes) {
            Write-Host "Nombre del Scope: $($scope.Name)"
            Write-Host "ScopeId: $($scope.ScopeId)"
            Write-Host "Segmento de red: $($scope.ScopeId)"
            Write-Host "Mascara: $($scope.SubnetMask)"
            Write-Host "Rango: $($scope.StartRange) - $($scope.EndRange)"
            Write-Host "Estado: $($scope.State)"
            Write-Host "Lease Duration: $($scope.LeaseDuration)"
            Write-Host ""
            
            # Obtener opciones del scope (Gateway y DNS)
            $options = Get-DhcpServerv4OptionValue -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue
            
            $gateway = ($options | Where-Object { $_.OptionId -eq 3 }).Value
            $dns = ($options | Where-Object { $_.OptionId -eq 6 }).Value
            
            if ($gateway) {
                Write-Host "Gateway: $gateway"
            }
            
            if ($dns) {
                Write-Host "DNS: $dns"
            }
            
            Write-Host ""
        }
    } else {
        Write-Host "No hay scopes configurados"
    }
    Write-Host ""
    
    # Estadisticas de concesiones
    Write-Host "3. Estadisticas:"
    Write-Host "---------------"
    
    if ($scopes) {
        foreach ($scope in $scopes) {
            Write-Host "Scope: $($scope.Name)"
            
            try {
                $leases = @(Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction Stop)
                
                if ($leases.Count -gt 0) {
                    $totalLeases = $leases.Count
                    $activeLeases = @($leases | Where-Object { $_.AddressState -eq "Active" }).Count
                    
                    Write-Host "  Concesiones totales: $totalLeases"
                    Write-Host "  Concesiones activas: $activeLeases"
                    
                    # Mostrar detalles de cada concesión
                    Write-Host "  Detalles:"
                    foreach ($lease in $leases) {
                        $estado = if ($lease.AddressState -eq "Active") { "ACTIVO" } else { $lease.AddressState }
                        $hostname = if ($lease.HostName) { $lease.HostName } else { "Sin nombre" }
                        Write-Host "    - IP: $($lease.IPAddress) | Estado: $estado | Host: $hostname"
                    }
                } else {
                    Write-Host "  Sin concesiones"
                }
            } catch {
                Write-Host "  Error al obtener concesiones: $_"
            }
            Write-Host ""
        }
    } else {
        Write-Host "Sin scopes configurados"
    }
    Write-Host ""
}
#
#   Menu Principal
#
function main_menu {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "--------------------------------"
        Write-Host "  Gestor de Servicio DHCP"
        Write-Host "--------------------------------"
        Write-Host ""
        Write-Host "Seleccione una opcion:"
        Write-Host ""
        Write-Host "1) Verificar instalacion"
        Write-Host "2) Instalar servicio"
        Write-Host "3) Nueva configuracion"
        Write-Host "4) Reiniciar servicio"
        Write-Host "5) Monitor de concesiones"
        Write-Host "6) Ver configuracion actual"
        Write-Host "7) Salir"
        Write-Host ""
        $OP = Read-Host "Opcion"
        
        switch ($OP) {
            "1" {
                verificar_instalacion
            }
            "2" {
                instalar_servicio
            }
            "3" {
                nueva_configuracion
            }
            "4" {
                reiniciar_servicio
            }
            "5" {
                modo_monitor
            }
            "6" {
                ver_configuracion_actual
            }
            "7" {
                Write-Host ""
                Write-Host "Saliendo del programa..."
                exit 0
            }
            default {
                Write-Host ""
                Write-Host "Error: Opcion invalida"
            }
        }
        
        Write-Host ""
        Read-Host "Presiona Enter para continuar..."
    }
}
#
#   Punto de Entrada Principal
#
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

main_menu