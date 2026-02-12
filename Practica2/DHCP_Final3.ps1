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
$script:ipServidorEstatica = ""  # Se calcula automaticamente
$script:ipInicio = ""              
$script:ipInicioClientes = ""      # IP calculada para el rango de clientes (ipInicio + 1)
$script:ipFin = ""
$script:gateway = ""
$script:dnsPrimario = ""
$script:dnsSecundario = ""
$script:leaseTime = $null
#
#   Funciones de Validacion de IP
#
# Valida el formato basico de IPv4
function validar_formato_ip {
    param([string]$ip)
    
    if ($ip -notmatch '^(\d{1,3}\.){3}\d{1,3}$') {
        return $false
    }
    
    $octetos = $ip.Split('.')
    foreach ($octeto in $octetos) {
        $num = [int]$octeto
        if ($num -lt 0 -or $num -gt 255) {
            return $false
        }
    }
    
    return $true
}

# Valida que la IP sea usable
function validar_ip_usable {
    param([string]$ip)
    
    if (-not (validar_formato_ip $ip)) {
        Write-Host "Error: Formato IPv4 incorrecto"
        return $false
    }
    
    $octetos = $ip.Split('.')
    $oct1 = [int]$octetos[0]
    $oct2 = [int]$octetos[1]
    $oct3 = [int]$octetos[2]
    $oct4 = [int]$octetos[3]
    
    # Red 0.0.0.0/8
    if ($oct1 -eq 0) {
        Write-Host "Error: La red 0.0.0.0/8 es reservada"
        return $false
    }
    
    # Red 127.0.0.0/8
    if ($oct1 -eq 127) {
        Write-Host "Error: La red 127.0.0.0/8 (localhost)"
        return $false
    }
    
    # IP de broadcast
    if ($oct1 -eq 255 -and $oct2 -eq 255 -and $oct3 -eq 255 -and $oct4 -eq 255) {
        Write-Host "Error: 255.255.255.255 es direccion de broadcast"
        return $false
    }
    
    # Redes multicast 224.0.0.0/4
    if ($oct1 -ge 224 -and $oct1 -le 239) {
        Write-Host "Error: Redes 224.0.0.0 a 239.255.255.255 son multicast"
        return $false
    }
    
    # Redes experimentales 240.0.0.0/4
    if ($oct1 -ge 240 -and $oct1 -le 255) {
        Write-Host "Error: Redes 240.0.0.0 a 255.255.255.255 son experimentales"
        return $false
    }
    
    return $true
}

# Calcula mascara de subred
function calcular_mascara {
    param([string]$ip)
    
    $octetos = $ip.Split('.')
    $oct1 = [int]$octetos[0]
    
    if ($oct1 -ge 1 -and $oct1 -le 126) {
        $script:mascara = "255.0.0.0"
        $script:bitsMascara = 8
        Write-Host "Clase A detectada - Mascara: $($script:mascara) (/8)"
        
    } elseif ($oct1 -ge 128 -and $oct1 -le 191) {
        $script:mascara = "255.255.0.0"
        $script:bitsMascara = 16
        Write-Host "Clase B detectada - Mascara: $($script:mascara) (/16)"
        
    } elseif ($oct1 -ge 192 -and $oct1 -le 223) {
        $script:mascara = "255.255.255.0"
        $script:bitsMascara = 24
        Write-Host "Clase C detectada - Mascara: $($script:mascara) (/24)"
        
    } else {
        Write-Host "Error: No se pudo determinar clase de red"
        return $false
    }
    
    $hostsBits = 32 - $script:bitsMascara
    $ipsTotales = [math]::Pow(2, $hostsBits)
    $ipsUsables = $ipsTotales - 2
    
    Write-Host "IPs totales: $ipsTotales"
    Write-Host "IPs usables: $ipsUsables (excluyendo red y broadcast)"
    
    return $true
}

# Convierte IP a numero
function ip_a_numero {
    param([string]$ip)
    
    $octetos = $ip.Split('.')
    $oct1 = [int64]$octetos[0]
    $oct2 = [int64]$octetos[1]
    $oct3 = [int64]$octetos[2]
    $oct4 = [int64]$octetos[3]
    
    return ($oct1 * [math]::Pow(256, 3) + $oct2 * [math]::Pow(256, 2) + $oct3 * 256 + $oct4)
}

# Convierte numero a IP
function numero_a_ip {
    param([int64]$numero)
    
    $oct1 = [math]::Floor($numero / [math]::Pow(256, 3))
    $resto = $numero % [math]::Pow(256, 3)
    
    $oct2 = [math]::Floor($resto / [math]::Pow(256, 2))
    $resto = $resto % [math]::Pow(256, 2)
    
    $oct3 = [math]::Floor($resto / 256)
    $oct4 = $resto % 256
    
    return "$oct1.$oct2.$oct3.$oct4"
}

# Obtiene IP de red
function obtener_ip_red {
    param(
        [string]$ip,
        [string]$mascara
    )
    
    $ipOctetos = $ip.Split('.')
    $mascaraOctetos = $mascara.Split('.')
    
    $red1 = [int]$ipOctetos[0] -band [int]$mascaraOctetos[0]
    $red2 = [int]$ipOctetos[1] -band [int]$mascaraOctetos[1]
    $red3 = [int]$ipOctetos[2] -band [int]$mascaraOctetos[2]
    $red4 = [int]$ipOctetos[3] -band [int]$mascaraOctetos[3]
    
    return "$red1.$red2.$red3.$red4"
}

# Valida mismo segmento
function validar_mismo_segmento {
    param(
        [string]$ipBase,
        [string]$ipComparar,
        [string]$mascara
    )
    
    $redBase = obtener_ip_red $ipBase $mascara
    $redComparar = obtener_ip_red $ipComparar $mascara
    
    if ($redBase -ne $redComparar) {
        Write-Host "Error: La IP $ipComparar no pertenece al segmento $redBase"
        return $false
    }
    
    return $true
}

# Valida rango de IPs
function validar_rango_ips {
    param(
        [string]$ipInicio,
        [string]$ipFin
    )
    
    $numInicio = ip_a_numero $ipInicio
    $numFin = ip_a_numero $ipFin
    
    if ($numInicio -ge $numFin) {
        Write-Host "Error: La IP inicial debe ser menor que la IP final"
        Write-Host "IP Inicial: $ipInicio (valor: $numInicio)"
        Write-Host "IP Final: $ipFin (valor: $numFin)"
        return $false
    }
    
    return $true
}

# Valida que no sea IP de red ni broadcast
function validar_ip_no_especial {
    param(
        [string]$ip,
        [string]$red,
        [string]$mascara
    )
    
    $redOctetos = $red.Split('.')
    $mascaraOctetos = $mascara.Split('.')
    
    $b1 = ([int]$redOctetos[0] -band [int]$mascaraOctetos[0]) -bor (255 - [int]$mascaraOctetos[0])
    $b2 = ([int]$redOctetos[1] -band [int]$mascaraOctetos[1]) -bor (255 - [int]$mascaraOctetos[1])
    $b3 = ([int]$redOctetos[2] -band [int]$mascaraOctetos[2]) -bor (255 - [int]$mascaraOctetos[2])
    $b4 = ([int]$redOctetos[3] -band [int]$mascaraOctetos[3]) -bor (255 - [int]$mascaraOctetos[3])
    
    $broadcast = "$b1.$b2.$b3.$b4"
    
    if ($ip -eq $red) {
        Write-Host "Error: No puede usar la IP de red ($red)"
        return $false
    }
    
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

function parametros_usuario {
    Write-Host ""
    Write-Host "-------------------------------"
    Write-Host " Configuracion de parametros"
    Write-Host "--------------------------------"
    
    # NOMBRE DEL SCOPE
    Write-Host ""
    $script:nombreScope = Read-Host "Nombre del Scope"
    if ([string]::IsNullOrWhiteSpace($script:nombreScope)) {
        $script:nombreScope = "RedInterna"
    }
    
    # SEGMENTO DE RED
    while ($true) {
        Write-Host ""
        Write-Host "Ingrese el segmento de red: "
        $script:red = Read-Host "Segmento de red"
        
        Write-Host ""
        
        if (-not (validar_formato_ip $script:red)) {
            Write-Host "Formato de IP invalido"
            continue
        }
        
        if (-not (validar_ip_usable $script:red)) {
            continue
        }
        
        if (-not (calcular_mascara $script:red)) {
            continue
        }
        
        # Normalizar a IP de red
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
    
    # RANGO DE IPS
    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host "            Rango de IPs"
    Write-Host "------------------------------------------"
    Write-Host ""
    Write-Host "IMPORTANTE: Ingrese el rango que desea asignar"
    Write-Host "El servidor tomara automaticamente (IP inicial - 1)"
    Write-Host ""
    
    # IP Inicio del rango
    while ($true) {
        Write-Host "Ingrese la IP INICIAL del rango. "
        $script:ipInicio = Read-Host "IP inicial"
        
        Write-Host ""
        
        if (-not (validar_formato_ip $script:ipInicio)) {
            Write-Host "Formato de IP invalido"
            continue
        }
        
        if (-not (validar_ip_usable $script:ipInicio)) {
            continue
        }
        
        if (-not (validar_mismo_segmento $script:red $script:ipInicio $script:mascara)) {
            continue
        }
        
        if (-not (validar_ip_no_especial $script:ipInicio $script:red $script:mascara)) {
            continue
        }
        
        # Calcula la IP del servidor
        $numInicio = ip_a_numero $script:ipInicio
        $script:ipServidorEstatica = $script:ipInicio  # Ahora el servidor toma la IP inicial

        # Calcular el nuevo inicio del rango para clientes (IP inicial + 1)
        $numRangoClientes = $numInicio + 1
        $ipInicioClientes = numero_a_ip $numRangoClientes
        
        # Validar que la IP inicial para clientes sea válida
        if (-not (validar_ip_no_especial $ipInicioClientes $script:red $script:mascara)) {
            Write-Host ""
            Write-Host "Error: La IP calculada para el inicio del rango de clientes ($ipInicioClientes) no es valida"
            Write-Host "Por favor, ingrese una IP inicial menor"
            Write-Host ""
            continue
        }
        
        # Guardar en variable global
        $script:ipInicioClientes = $ipInicioClientes

        # Validar que la IP del servidor calculada sea valida
        if (-not (validar_ip_no_especial $script:ipServidorEstatica $script:red $script:mascara)) {
            Write-Host ""
            Write-Host "Error: La IP calculada para el servidor ($($script:ipServidorEstatica)) no es valida"
            Write-Host "Por favor, ingrese una IP inicial mayor"
            Write-Host ""
            continue
        }
        
        Write-Host "IP inicial validada: $($script:ipInicio)"
        Write-Host ""
        Write-Host "IP del servidor DHCP (estatica): $($script:ipServidorEstatica)"
        Write-Host "Rango para clientes inicia en: $ipInicioClientes"
        Write-Host ""
        break
    }
    
    # IP Fin del rango
    while ($true) {
        Write-Host "Ingrese la IP FINAL del rango"
        $script:ipFin = Read-Host "IP final"
        
        Write-Host ""
        
        if (-not (validar_formato_ip $script:ipFin)) {
            Write-Host "Formato de IP invalido"
            continue
        }
        
        if (-not (validar_ip_usable $script:ipFin)) {
            continue
        }
        
        if (-not (validar_mismo_segmento $script:red $script:ipFin $script:mascara)) {
            continue
        }
        
        if (-not (validar_ip_no_especial $script:ipFin $script:red $script:mascara)) {
            continue
        }
        
        if (-not (validar_rango_ips $script:ipInicio $script:ipFin)) {
            continue
        }
        
        Write-Host "IP final validada: $($script:ipFin)"
        break
    }
    
    # GATEWAY -> opcional
    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host " Gateway (Opcional)"
    Write-Host "------------------------------------------"
    Write-Host ""
    
    while ($true) {
        $script:gateway = Read-Host "Ingrese la IP del Gateway (o presione ENTER para omitir)"
        
        if ([string]::IsNullOrWhiteSpace($script:gateway)) {
            $script:gateway = $null
            Write-Host ""
            Write-Host "Gateway: NO CONFIGURADO"
            break
        }
        
        Write-Host ""
        
        if (-not (validar_formato_ip $script:gateway)) {
            Write-Host "Formato de IP invalido"
            continue
        }
        
        if (-not (validar_ip_usable $script:gateway)) {
            continue
        }
        
        if (-not (validar_mismo_segmento $script:red $script:gateway $script:mascara)) {
            continue
        }
        
        if (-not (validar_ip_no_especial $script:gateway $script:red $script:mascara)) {
            continue
        }
        
        Write-Host "Gateway validado: $($script:gateway)"
        break
    }
    
    # DNS (Opcional)
    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host " Servidores DNS (Opcional)"
    Write-Host "------------------------------------------"
    Write-Host ""
    
    while ($true) {
        $respuestaDnsPrimario = Read-Host "Desea configurar un servidor DNS primario? (s/n)"
        
        if ($respuestaDnsPrimario -match '^[Ss]$') {
            Write-Host ""
            
            while ($true) {
                $script:dnsPrimario = Read-Host "Ingrese la IP del DNS primario"
                
                Write-Host ""
                
                if (-not (validar_formato_ip $script:dnsPrimario)) {
                    Write-Host "Formato de IP invalido"
                    continue
                }
                
                if (-not (validar_ip_usable $script:dnsPrimario)) {
                    continue
                }
                
                Write-Host "DNS primario validado: $($script:dnsPrimario)"
                break
            }
            
            Write-Host ""
            
            while ($true) {
                $respuestaDnsSecundario = Read-Host "Desea configurar un servidor DNS secundario? (s/n)"
                
                if ($respuestaDnsSecundario -match '^[Ss]$') {
                    Write-Host ""
                    
                    while ($true) {
                        $script:dnsSecundario = Read-Host "Ingrese la IP del DNS secundario"
                        
                        Write-Host ""
                        
                        if (-not (validar_formato_ip $script:dnsSecundario)) {
                            Write-Host "Formato de IP invalido"
                            continue
                        }
                        
                        if (-not (validar_ip_usable $script:dnsSecundario)) {
                            continue
                        }
                        
                        Write-Host "DNS secundario validado: $($script:dnsSecundario)"
                        break
                    }
                    break
                    
                } elseif ($respuestaDnsSecundario -match '^[Nn]$') {
                    $script:dnsSecundario = $null
                    Write-Host ""
                    Write-Host "DNS secundario: NO CONFIGURADO"
                    break
                    
                } else {
                    Write-Host "Error: Respuesta invalida. Ingrese 's' o 'n'"
                }
            }
            break
            
        } elseif ($respuestaDnsPrimario -match '^[Nn]$') {
            $script:dnsPrimario = $null
            $script:dnsSecundario = $null
            Write-Host ""
            Write-Host "DNS: NO CONFIGURADO"
            break
            
        } else {
            Write-Host "Error: Respuesta invalida. Ingrese 's' o 'n'"
        }
    }
    
    # LEASE TIME
    while ($true) {
        Write-Host ""
        $leaseSeconds = Read-Host "Lease Time en segundos (ej: 86400 para 24 horas)"
        
        if ($leaseSeconds -match '^\d+$' -and [int]$leaseSeconds -gt 0) {
            $script:leaseTime = New-TimeSpan -Seconds ([int]$leaseSeconds)
            
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
    
    # RESUMEN
    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host " Resumen de la configuracion"
    Write-Host "------------------------------------------"
    Write-Host ""
    Write-Host "Nombre del Scope: $($script:nombreScope)"
    Write-Host "Segmento de red: $($script:red)"
    Write-Host "Mascara de subred: $($script:mascara) (/$($script:bitsMascara))"
    Write-Host ""
    Write-Host "IP del servidor DHCP: $($script:ipServidorEstatica)"
    Write-Host ""
    Write-Host "Rango para clientes:"
    Write-Host "  - IP inicial: $($script:ipInicioClientes)"
    Write-Host "  - IP final: $($script:ipFin)"
    Write-Host ""
    
    if ($script:gateway) {
        Write-Host "Gateway: $($script:gateway)"
    } else {
        Write-Host "Gateway: NO CONFIGURADO"
    }
    
    Write-Host ""
    
    if ($script:dnsPrimario) {
        Write-Host "DNS primario: $($script:dnsPrimario)"
        
        if ($script:dnsSecundario) {
            Write-Host "DNS secundario: $($script:dnsSecundario)"
        } else {
            Write-Host "DNS secundario: NO CONFIGURADO"
        }
    } else {
        Write-Host "DNS: NO CONFIGURADO"
    }
    
    Write-Host ""
    Write-Host "Lease Time: $($script:leaseTime)"
    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host ""
}

function configurar_interfaz_red {
    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host " Configurando Interfaz de Red"
    Write-Host "------------------------------------------"
    Write-Host ""

    $interfazIndex = $script:interfazSeleccionada.IfIndex
    
    Write-Host "Eliminando configuracion IP anterior..."
    
    Get-NetIPAddress -InterfaceIndex $interfazIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
        Where-Object { $_.IPAddress -notlike "127.*" } |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    
    Get-NetRoute -InterfaceIndex $interfazIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    
    Write-Host "Configurando IP estatica: $($script:ipServidorEstatica)..."
    
    try {
        if ($script:gateway) {
            New-NetIPAddress `
                -InterfaceIndex $interfazIndex `
                -IPAddress $script:ipServidorEstatica `
                -PrefixLength $script:bitsMascara `
                -DefaultGateway $script:gateway `
                -ErrorAction Stop | Out-Null
            
            Write-Host "IP estatica y gateway configurados"
        } else {
            New-NetIPAddress `
                -InterfaceIndex $interfazIndex `
                -IPAddress $script:ipServidorEstatica `
                -PrefixLength $script:bitsMascara `
                -ErrorAction Stop | Out-Null
            
            Write-Host "IP estatica configurada (sin gateway)"
        }
    } catch {
        Write-Host "Error al configurar la interfaz de red: $_"
        exit 1
    }
    
    if ($script:dnsPrimario) {
        try {
            if ($script:dnsSecundario) {
                Set-DnsClientServerAddress -InterfaceIndex $interfazIndex `
                    -ServerAddresses @($script:dnsPrimario, $script:dnsSecundario) `
                    -ErrorAction SilentlyContinue
                Write-Host "DNS configurados: $($script:dnsPrimario), $($script:dnsSecundario)"
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $interfazIndex `
                    -ServerAddresses $script:dnsPrimario `
                    -ErrorAction SilentlyContinue
                Write-Host "DNS configurado: $($script:dnsPrimario)"
            }
        } catch {
            Write-Host "Advertencia: No se pudo configurar DNS en la interfaz"
        }
    }
    
    Start-Sleep -Seconds 2
    
    Write-Host ""
    Write-Host "Verificando configuracion de red..."
    Get-NetIPAddress -InterfaceIndex $interfazIndex -AddressFamily IPv4 | 
        Format-Table InterfaceAlias, IPAddress, PrefixLength -AutoSize
    Write-Host ""
}

function config_dhcp {
    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host " Configuracion del Servicio DHCP"
    Write-Host "------------------------------------------"
    Write-Host ""
    
    Write-Host "Verificando scopes anteriores..."

    $existingScopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue

    if ($existingScopes) {
        Write-Host "Se encontraron $($existingScopes.Count) scope(s) anterior(es)"
        Write-Host "Eliminando TODOS los scopes anteriores..."
    
        foreach ($scope in $existingScopes) {
            Write-Host "  - Eliminando scope: $($scope.Name) (Red: $($scope.ScopeId))"
            Remove-DhcpServerv4Scope -ScopeId $scope.ScopeId -Force -ErrorAction SilentlyContinue
        }
    
        Write-Host "Todos los scopes anteriores han sido eliminados"
    } else {
        Write-Host "No se encontraron scopes anteriores"
    }
    
    Write-Host ""
    Write-Host "Creando scope DHCP..."
    
    try {
        Add-DhcpServerv4Scope `
            -Name $script:nombreScope `
            -StartRange $script:ipInicioClientes `
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
    
    if ($script:gateway) {
        try {
            Set-DhcpServerv4OptionValue `
                -ScopeId $script:red `
                -Router $script:gateway `
                -ErrorAction Stop | Out-Null
            
            Write-Host "Gateway configurado: $($script:gateway)"
        } catch {
            Write-Host "Advertencia: No se pudo configurar gateway"
        }
    } else {
        Write-Host "- Gateway: NO CONFIGURADO"
    }
    
    if ($script:dnsPrimario) {
        try {
            if ($script:dnsSecundario) {
                Set-DhcpServerv4OptionValue `
                    -ScopeId $script:red `
                    -DnsServer @($script:dnsPrimario, $script:dnsSecundario) `
                    -ErrorAction Stop | Out-Null
                
                Write-Host "DNS configurados: $($script:dnsPrimario), $($script:dnsSecundario)"
            } else {
                Set-DhcpServerv4OptionValue `
                    -ScopeId $script:red `
                    -DnsServer $script:dnsPrimario `
                    -ErrorAction Stop | Out-Null
                
                Write-Host "DNS configurado: $($script:dnsPrimario)"
            }
        } catch {
            Write-Host "Advertencia: No se pudo configurar DNS"
        }
    } else {
        Write-Host "- DNS: NO CONFIGURADO"
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
        -ErrorAction SilentlyContinue | Out-Null
    
    Write-Host "Regla de firewall creada"
    Write-Host ""
}

function iniciar_dhcp {
    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host " Iniciando Servicio DHCP"
    Write-Host "------------------------------------------"
    Write-Host ""
    
    Write-Host "Iniciando servicio DHCPServer..."
    
    try {
        Restart-Service -Name DHCPServer -Force -ErrorAction Stop
        Write-Host "Servicio iniciado correctamente"
        Write-Host ""
        
        $service = Get-Service -Name DHCPServer
        Write-Host "Estado del servicio: $($service.Status)"
        
    } catch {
        Write-Host "Error al iniciar el servicio: $_"
        exit 1
    }
}

function monitoreo_info {
    Write-Host "------------------------------------------"
    Write-Host " Monitor de Servicio DHCP"
    Write-Host "------------------------------------------"
    Write-Host ""
    Write-Host "Actualizacion: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host ""
    
    $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
    
    if ($scopes) {
        foreach ($scope in $scopes) {
            Write-Host "Scope: $($scope.Name)"
            Write-Host "Red: $($scope.ScopeId)"
            Write-Host "Rango: $($scope.StartRange) - $($scope.EndRange)"
            Write-Host ""

            # Mostrar IP del servidor DHCP
            $serverIP = Get-NetIPAddress -InterfaceAlias $scope.ScopeId -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
                Where-Object { $_.IPAddress -notlike "169.254.*" } | 
                Select-Object -ExpandProperty IPAddress -First 1

            if (-not $serverIP) {
                # Si no funciona por alias, buscar por todas las interfaces
                $serverIP = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
                Where-Object { 
                    $_.IPAddress -notlike "127.*" -and 
                    $_.IPAddress -notlike "169.254.*" -and
                    $_.IPAddress -match "^$($scope.ScopeId.ToString().Split('.')[0])\."
                } | 
                Select-Object -ExpandProperty IPAddress -First 1
            }

            if ($serverIP) {
                Write-Host "IP del servidor DHCP: $serverIP"
                Write-Host ""
            }
            
            try {
                $leases = @(Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction Stop)
                
                if ($leases.Count -gt 0) {
                    Write-Host "Concesiones activas: $($leases.Count)"
                    Write-Host ""
                    
                    foreach ($lease in $leases) {
                        $estado = if ($lease.AddressState -eq "Active") { "ACTIVO" } else { $lease.AddressState }
                        $hostname = if ($lease.HostName) { $lease.HostName } else { "Sin nombre" }
                        $expira = if ($lease.LeaseExpiryTime) { $lease.LeaseExpiryTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "N/A" }
                        
                        Write-Host "  IP: $($lease.IPAddress)"
                        Write-Host "    Host: $hostname"
                        Write-Host "    MAC: $($lease.ClientId)"
                        Write-Host "    Estado: $estado"
                        Write-Host "    Expira: $expira"
                        Write-Host ""
                    }
                } else {
                    Write-Host "Sin concesiones activas"
                    Write-Host ""
                }
            } catch {
                Write-Host "Error al obtener concesiones: $_"
                Write-Host ""
            }
        }
    } else {
        Write-Host "No hay scopes configurados"
        Write-Host ""
    }
}

function verificar_instalacion {
    Write-Host ""
    Write-Host "----------------------------------------------"
    Write-Host "Verificando instalacion del servicio DHCP..."
    Write-Host "----------------------------------------------"
    Write-Host ""
    
    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    
    if ($dhcpFeature.Installed) {
        Write-Host "Estado: INSTALADO"
        Write-Host ""
        
        $service = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
        
        if ($service) {
            Write-Host "Servicio DHCPServer:"
            Write-Host "  Estado: $($service.Status)"
            Write-Host "  Inicio: $($service.StartType)"
        }
    } else {
        Write-Host "Estado: NO INSTALADO"
        Write-Host ""
        Write-Host "Use la opcion 2 del menu para instalar el servicio"
    }
    Write-Host ""
}

function instalar_y_configurar_servicio {
    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host " INSTALACION Y CONFIGURACION COMPLETA"
    Write-Host "------------------------------------------"
    Write-Host ""
    
    # Verificar si ya esta instalado
    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    
    if (-not $dhcpFeature.Installed) {
        Write-Host "Instalando rol DHCP..."
        Write-Host "Esto puede tardar varios minutos..."
        Write-Host ""
        
        try {
            Install-WindowsFeature -Name DHCP -IncludeManagementTools -ErrorAction Stop | Out-Null
            
            Write-Host ""
            Write-Host "Rol DHCP instalado correctamente"
            Write-Host ""
            
            # Habilitar servicio
            Set-Service -Name DHCPServer -StartupType Automatic
            
        } catch {
            Write-Host ""
            Write-Host "Error durante la instalacion: $_"
            return
        }
    } else {
        Write-Host "El servicio DHCP ya esta instalado"
        Write-Host ""
    }
    
    # Ahora configurar
    Write-Host "Iniciando configuracion..."
    Write-Host ""
    
    deteccion_interfaces_red
    parametros_usuario
    configurar_interfaz_red
    config_dhcp
    iniciar_dhcp
    
    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host " Instalacion y configuracion completada"
    Write-Host "------------------------------------------"
    Write-Host ""
}

function nueva_configuracion {
    Write-Host ""
    Write-Host "----------------------------------------"
    Write-Host "Nueva configuracion del servicio DHCP"
    Write-Host "----------------------------------------"
    Write-Host ""
    
    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    
    if (-not $dhcpFeature.Installed) {
        Write-Host "Error: El servicio DHCP no esta instalado"
        Write-Host ""
        Write-Host "Use la opcion 2 del menu para instalar"
        return
    }
    
    Write-Host "Iniciando configuracion..."
    
    deteccion_interfaces_red
    parametros_usuario
    configurar_interfaz_red
    config_dhcp
    iniciar_dhcp
    
    Write-Host ""
    Write-Host "------------------------------------------"
    Write-Host " Configuracion Completada"
    Write-Host "------------------------------------------"
    Write-Host ""
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
    
    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
    
    if (-not $dhcpFeature.Installed) {
        Write-Host "El servicio DHCP no esta instalado"
        return
    }
    
    Write-Host "1. Estado del Servicio:"
    Write-Host "------------------------------------"

    $service = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    
    if ($service) {
        Write-Host "Estado: $($service.Status)"
        Write-Host "Inicio automatico: $($service.StartType)"
    } else {
        Write-Host "Servicio no encontrado"
    }
    Write-Host ""
    
    Write-Host "2. Configuracion DHCP:"
    Write-Host "------------------------------------"
    
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
            
            $options = Get-DhcpServerv4OptionValue -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue
            
            $gateway = ($options | Where-Object { $_.OptionId -eq 3 }).Value
            $dns = ($options | Where-Object { $_.OptionId -eq 6 }).Value
            
            if ($gateway) {
                Write-Host "Gateway: $gateway"
            } else {
                Write-Host "Gateway: NO CONFIGURADO"
            }
            
            if ($dns) {
                Write-Host "DNS: $dns"
            } else {
                Write-Host "DNS: NO CONFIGURADO"
            }
            
            Write-Host ""
        }
    } else {
        Write-Host "No hay scopes configurados"
    }
    Write-Host ""
    
    Write-Host "3. Estadisticas:"
    Write-Host "------------------------------------"
    
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

function main_menu {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "------------------------------------"
        Write-Host "      Gestor de Servicio DHCP"
        Write-Host "------------------------------------"
        Write-Host ""
        Write-Host "Seleccione una opcion:"
        Write-Host ""
        Write-Host "1) Verificar instalacion"
        Write-Host "2) Instalar y configurar servicio"
        Write-Host "3) Nueva configuracion (requiere instalacion previa)"
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
                instalar_y_configurar_servicio
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