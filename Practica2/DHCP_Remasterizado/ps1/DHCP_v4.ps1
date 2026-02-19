$ErrorActionPreference = "Stop"
#
#   Gestor de Servicio DHCP - Windows Server
#
#   Requiere:
#       utils.ps1      -> funciones de salida formateada y utilidades comunes
#       validators.ps1 -> validaciones de IP, mascara y calculo de subred nativo .NET
#
#   NOTA: Este script esta disenado para Windows Server en modo Workgroup (sin Active Directory).
#         Se utiliza el parametro -Force en Set-DhcpServerv4OptionValue para omitir la
#         validacion de PTR que Windows realiza cuando no hay AD disponible.
#
. "$PSScriptRoot\utils.ps1"
. "$PSScriptRoot\validators.ps1"
#
#   Variables Globales
#
$script:interfaces           = @()
$script:listaInterfaces      = @()
$script:interfazSeleccionada = $null
$script:nombreScope          = ""
$script:red                  = ""
$script:mascara              = ""
$script:bitsMascara          = 0
$script:ipServidorEstatica   = ""   # Se asigna automaticamente como primera IP del rango
$script:ipInicio             = ""
$script:ipInicioClientes     = ""   # IP calculada para clientes (ipInicio + 1)
$script:ipFin                = ""
$script:gateway              = ""
$script:dnsPrimario          = ""
$script:dnsSecundario        = ""
$script:leaseTime            = $null
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
        Write-ErrorMessage "No se detectaron interfaces de red"
        exit 1
    }

    Write-Host ""
    Write-InfoMessage "Interfaces de red detectadas:"
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

        Write-ErrorMessage "Seleccion invalida. Ingrese un numero entre 1 y $($script:listaInterfaces.Count)"
    }

    Write-Host ""
    Write-SuccessMessage "Interfaz seleccionada: $($script:interfazSeleccionada.Interfaz)"
}
#
#   Funciones semi principales -> usadas por las principales
#
function parametros_usuario {
    Write-Host ""
    Write-Header "Configuracion de parametros"

    # NOMBRE DEL SCOPE
    Write-Host ""
    $script:nombreScope = Read-Host "Nombre del Scope"
    if ([string]::IsNullOrWhiteSpace($script:nombreScope)) {
        $script:nombreScope = "RedInterna"
    }

    # SEGMENTO DE RED
    # Se solicita primero la IP base y luego el prefijo CIDR por separado.
    # calcular_subred_cidr calcula mascara, broadcast e IPs usables
    # y actualiza las variables de script: red, mascara, bitsMascara
    while ($true) {
        Write-Host ""
        Write-InfoMessage "Ingrese el segmento de red (sin prefijo, solo la IP base)"
        $script:red = Read-Host "Segmento de red"

        Write-Host ""

        if (-not (validar_formato_ip $script:red)) {
            Write-ErrorMessage "Formato de IP invalido"
            continue
        }

        if (-not (validar_ip_usable $script:red)) {
            continue
        }

        # Solicita el prefijo CIDR
        # calcular_subred_cidr actualiza $script:red, $script:mascara y $script:bitsMascara
        while ($true) {
            Write-Host ""
            Write-InfoMessage "Ingrese el prefijo CIDR (ej: 24 para /24 -> 255.255.255.0)"
            $cidrInput = Read-Host "Prefijo CIDR"

            if (-not (validar_cidr $cidrInput)) {
                continue
            }

            if (-not (calcular_subred_cidr $script:red ([int]$cidrInput))) {
                continue
            }

            break
        }

        # Verificar que la IP ingresada sea la IP de red correcta
        $redCalculada = obtener_ip_red $script:red $script:mascara

        if ($script:red -ne $redCalculada) {
            Write-Host ""
            Write-WarningCustom "El segmento ingresado no es la IP de red"
            Write-InfoMessage "  IP ingresada      : $($script:red)"
            Write-InfoMessage "  IP de red correcta: $redCalculada"
            Write-Host ""

            $confirmar = Read-Host "Usar la IP de red correcta ($redCalculada)? (s/n)"

            if ($confirmar -match '^[Ss]$') {
                $script:red = $redCalculada
                Write-SuccessMessage "IP de red actualizada a: $($script:red)"
                break
            } else {
                Write-InfoMessage "Por favor, ingrese nuevamente el segmento de red"
                continue
            }
        }

        break
    }

    # RANGO DE IPS
    Write-Host ""
    Write-Header "Rango de IPs"
    Write-Host ""
    Write-InfoMessage "IMPORTANTE: Ingrese el rango que desea asignar"
    Write-InfoMessage "El servidor tomara automaticamente la IP inicial del rango"
    Write-Host ""

    # IP Inicio del rango
    while ($true) {
        Write-InfoMessage "Ingrese la IP INICIAL del rango"
        $script:ipInicio = Read-Host "IP inicial"

        Write-Host ""

        if (-not (validar_formato_ip $script:ipInicio)) {
            Write-ErrorMessage "Formato de IP invalido"
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

        # El servidor toma la IP inicial, los clientes comienzan en la siguiente
        $numInicio = ip_a_numero $script:ipInicio
        $script:ipServidorEstatica = $script:ipInicio

        $numRangoClientes = $numInicio + 1
        $ipInicioClientes = numero_a_ip $numRangoClientes

        if (-not (validar_ip_no_especial $ipInicioClientes $script:red $script:mascara)) {
            Write-Host ""
            Write-ErrorMessage "La IP calculada para clientes ($ipInicioClientes) no es valida"
            Write-InfoMessage "Por favor, ingrese una IP inicial menor"
            Write-Host ""
            continue
        }

        $script:ipInicioClientes = $ipInicioClientes

        if (-not (validar_ip_no_especial $script:ipServidorEstatica $script:red $script:mascara)) {
            Write-Host ""
            Write-ErrorMessage "La IP calculada para el servidor ($($script:ipServidorEstatica)) no es valida"
            Write-InfoMessage "Por favor, ingrese una IP inicial mayor"
            Write-Host ""
            continue
        }

        Write-SuccessMessage "IP inicial validada: $($script:ipInicio)"
        Write-Host ""
        Write-InfoMessage "IP del servidor DHCP (estatica) : $($script:ipServidorEstatica)"
        Write-InfoMessage "Rango para clientes inicia en   : $ipInicioClientes"
        Write-Host ""
        break
    }

    # IP Fin del rango
    while ($true) {
        Write-InfoMessage "Ingrese la IP FINAL del rango"
        $script:ipFin = Read-Host "IP final"

        Write-Host ""

        if (-not (validar_formato_ip $script:ipFin)) {
            Write-ErrorMessage "Formato de IP invalido"
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

        Write-SuccessMessage "IP final validada: $($script:ipFin)"
        break
    }

    # GATEWAY -> opcional
    Write-Host ""
    Write-Header "Gateway (Opcional)"
    Write-Host ""

    while ($true) {
        $script:gateway = Read-Host "Ingrese la IP del Gateway (o presione ENTER para omitir)"

        if ([string]::IsNullOrWhiteSpace($script:gateway)) {
            $script:gateway = $null
            Write-Host ""
            Write-InfoMessage "Gateway: NO CONFIGURADO"
            break
        }

        Write-Host ""

        if (-not (validar_formato_ip $script:gateway)) {
            Write-ErrorMessage "Formato de IP invalido"
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

        Write-SuccessMessage "Gateway validado: $($script:gateway)"
        break
    }

    # DNS (Opcional)
    Write-Host ""
    Write-Header "Servidores DNS (Opcional)"
    Write-Host ""

    while ($true) {
        # Mostrar la IP del servidor para que el operador sepa que valor ingresar
        Write-InfoMessage "IP del servidor Windows en esta red: $($script:ipServidorEstatica)"
        Write-Host ""
        $respuestaDnsPrimario = Read-Host "Desea configurar un servidor DNS primario? (s/n)"

        if ($respuestaDnsPrimario -match '^[Ss]$') {
            Write-Host ""

            while ($true) {
                $script:dnsPrimario = Read-Host "Ingrese la IP del DNS primario"

                Write-Host ""

                if (-not (validar_formato_ip $script:dnsPrimario)) {
                    Write-ErrorMessage "Formato de IP invalido"
                    continue
                }

                if (-not (validar_ip_usable $script:dnsPrimario)) {
                    continue
                }

                # Advertir si el DNS primario no pertenece al segmento del scope
                if (-not (validar_mismo_segmento $script:red $script:dnsPrimario $script:mascara)) {
                    Write-WarningCustom "El DNS primario no pertenece al segmento $($script:red)/$($script:bitsMascara)"
                    Write-InfoMessage "Los clientes podrian no alcanzar ese servidor DNS"
                    $continuar = Read-Host "Desea usar esta IP de todas formas? (s/n)"
                    if ($continuar -notmatch '^[Ss]$') {
                        continue
                    }
                }

                Write-SuccessMessage "DNS primario validado: $($script:dnsPrimario)"
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
                            Write-ErrorMessage "Formato de IP invalido"
                            continue
                        }

                        if (-not (validar_ip_usable $script:dnsSecundario)) {
                            continue
                        }

                        Write-SuccessMessage "DNS secundario validado: $($script:dnsSecundario)"
                        break
                    }
                    break

                } elseif ($respuestaDnsSecundario -match '^[Nn]$') {
                    $script:dnsSecundario = $null
                    Write-Host ""
                    Write-InfoMessage "DNS secundario: NO CONFIGURADO"
                    break

                } else {
                    Write-ErrorMessage "Respuesta invalida. Ingrese 's' o 'n'"
                }
            }
            break

        } elseif ($respuestaDnsPrimario -match '^[Nn]$') {
            $script:dnsPrimario   = $null
            $script:dnsSecundario = $null
            Write-Host ""
            Write-InfoMessage "DNS: NO CONFIGURADO"
            break

        } else {
            Write-ErrorMessage "Respuesta invalida. Ingrese 's' o 'n'"
        }
    }

    # LEASE TIME
    while ($true) {
        Write-Host ""
        $leaseSeconds = Read-Host "Lease Time en segundos (ej: 86400 para 24 horas)"

        if ($leaseSeconds -match '^\d+$' -and [int]$leaseSeconds -gt 0) {
            $script:leaseTime = New-TimeSpan -Seconds ([int]$leaseSeconds)

            $totalSegundos = [int]$leaseSeconds
            $dias    = [math]::Floor($totalSegundos / 86400)
            $horas   = [math]::Floor(($totalSegundos % 86400) / 3600)
            $minutos = [math]::Floor(($totalSegundos % 3600) / 60)
            $segs    = $totalSegundos % 60

            Write-Host ""
            Write-SuccessMessage "Tiempo configurado: $dias dias, $horas horas, $minutos minutos, $segs segundos"
            break
        } else {
            Write-ErrorMessage "Debe ser un numero entero positivo"
        }
    }

    # RESUMEN
    Write-Host ""
    Write-Header "Resumen de la configuracion"
    Write-Host ""
    Write-Host "  Nombre del Scope   : $($script:nombreScope)"
    Write-Host "  Segmento de red    : $($script:red)"
    Write-Host "  Mascara de subred  : $($script:mascara) (/$($script:bitsMascara))"
    Write-Host ""
    Write-Host "  IP del servidor    : $($script:ipServidorEstatica)"
    Write-Host ""
    Write-Host "  Rango para clientes:"
    Write-Host "    IP inicial       : $($script:ipInicioClientes)"
    Write-Host "    IP final         : $($script:ipFin)"
    Write-Host ""

    if ($script:gateway) {
        Write-Host "  Gateway            : $($script:gateway)"
    } else {
        Write-Host "  Gateway            : NO CONFIGURADO"
    }

    Write-Host ""

    if ($script:dnsPrimario) {
        Write-Host "  DNS primario       : $($script:dnsPrimario)"
        if ($script:dnsSecundario) {
            Write-Host "  DNS secundario     : $($script:dnsSecundario)"
        } else {
            Write-Host "  DNS secundario     : NO CONFIGURADO"
        }
    } else {
        Write-Host "  DNS                : NO CONFIGURADO"
    }

    Write-Host ""
    Write-Host "  Lease Time         : $($script:leaseTime)"
    Write-Host ""
    Write-SeparatorLine
    Write-Host ""
}

function configurar_interfaz_red {
    Write-Host ""
    Write-Header "Configurando Interfaz de Red"
    Write-Host ""

    $interfazIndex = $script:interfazSeleccionada.IfIndex

    Write-InfoMessage "Eliminando configuracion IP anterior..."

    Get-NetIPAddress -InterfaceIndex $interfazIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" } |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    Get-NetRoute -InterfaceIndex $interfazIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    Write-InfoMessage "Configurando IP estatica: $($script:ipServidorEstatica)..."

    try {
        if ($script:gateway) {
            New-NetIPAddress `
                -InterfaceIndex $interfazIndex `
                -IPAddress $script:ipServidorEstatica `
                -PrefixLength $script:bitsMascara `
                -DefaultGateway $script:gateway `
                -ErrorAction Stop | Out-Null

            Write-SuccessMessage "IP estatica y gateway configurados"
        } else {
            New-NetIPAddress `
                -InterfaceIndex $interfazIndex `
                -IPAddress $script:ipServidorEstatica `
                -PrefixLength $script:bitsMascara `
                -ErrorAction Stop | Out-Null

            Write-SuccessMessage "IP estatica configurada (sin gateway)"
        }
    } catch {
        Write-ErrorMessage "Error al configurar la interfaz de red: $_"
        exit 1
    }

    if ($script:dnsPrimario) {
        try {
            if ($script:dnsSecundario) {
                Set-DnsClientServerAddress -InterfaceIndex $interfazIndex `
                    -ServerAddresses @($script:dnsPrimario, $script:dnsSecundario) `
                    -ErrorAction SilentlyContinue
                Write-SuccessMessage "DNS configurados en la interfaz: $($script:dnsPrimario), $($script:dnsSecundario)"
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $interfazIndex `
                    -ServerAddresses $script:dnsPrimario `
                    -ErrorAction SilentlyContinue
                Write-SuccessMessage "DNS configurado en la interfaz: $($script:dnsPrimario)"
            }
        } catch {
            Write-WarningCustom "No se pudo configurar DNS en la interfaz: $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 2

    Write-Host ""
    Write-InfoMessage "Verificando configuracion de red..."
    Get-NetIPAddress -InterfaceIndex $interfazIndex -AddressFamily IPv4 |
        Format-Table InterfaceAlias, IPAddress, PrefixLength -AutoSize
    Write-Host ""
}

function config_dhcp {
    Write-Host ""
    Write-Header "Configuracion del Servicio DHCP"
    Write-Host ""

    Write-InfoMessage "Verificando scopes anteriores..."

    $existingScopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue

    if ($existingScopes) {
        Write-WarningCustom "Se encontraron $($existingScopes.Count) scope(s) anterior(es)"
        Write-InfoMessage "Eliminando TODOS los scopes anteriores..."

        foreach ($scope in $existingScopes) {
            Write-InfoMessage "  - Eliminando scope: $($scope.Name) (Red: $($scope.ScopeId))"
            Remove-DhcpServerv4Scope -ScopeId $scope.ScopeId -Force -ErrorAction SilentlyContinue
        }

        Write-SuccessMessage "Todos los scopes anteriores han sido eliminados"
    } else {
        Write-InfoMessage "No se encontraron scopes anteriores"
    }

    Write-Host ""
    Write-InfoMessage "Creando scope DHCP..."

    try {
        Add-DhcpServerv4Scope `
            -Name $script:nombreScope `
            -StartRange $script:ipInicioClientes `
            -EndRange $script:ipFin `
            -SubnetMask $script:mascara `
            -LeaseDuration $script:leaseTime `
            -State Active `
            -ErrorAction Stop | Out-Null

        Write-SuccessMessage "Scope creado exitosamente"
    } catch {
        Write-ErrorMessage "Error al crear scope: $_"
        exit 1
    }

    Write-Host ""
    Write-InfoMessage "Configurando opciones del scope..."

    if ($script:gateway) {
        try {
            # -Force omite la validacion de Active Directory en servidores Workgroup
            Set-DhcpServerv4OptionValue `
                -ScopeId $script:red `
                -Router $script:gateway `
                -Force `
                -ErrorAction Stop | Out-Null

            Write-SuccessMessage "Gateway configurado: $($script:gateway)"
        } catch {
            Write-ErrorMessage "Error al configurar gateway: $($_.Exception.Message)"
        }
    } else {
        Write-InfoMessage "Gateway: NO CONFIGURADO"
    }

    if ($script:dnsPrimario) {
        try {
            # -Force omite la validacion de registro PTR que Windows realiza cuando no hay
            # Active Directory disponible. Sin este parametro el cmdlet devuelve el error:
            # "La IP no es un servidor DNS valido" (WIN32 87 / InvalidArgument).
            if ($script:dnsSecundario) {
                Set-DhcpServerv4OptionValue `
                    -ScopeId $script:red `
                    -DnsServer @($script:dnsPrimario, $script:dnsSecundario) `
                    -Force `
                    -ErrorAction Stop | Out-Null

                Write-SuccessMessage "DNS configurados en el scope: $($script:dnsPrimario), $($script:dnsSecundario)"
            } else {
                Set-DhcpServerv4OptionValue `
                    -ScopeId $script:red `
                    -DnsServer $script:dnsPrimario `
                    -Force `
                    -ErrorAction Stop | Out-Null

                Write-SuccessMessage "DNS configurado en el scope: $($script:dnsPrimario)"
            }
        } catch {
            Write-ErrorMessage "Error al configurar DNS en el scope: $($_.Exception.Message)"
            Write-ErrorMessage "Detalle: $_"
            exit 1
        }
    } else {
        Write-InfoMessage "DNS: NO CONFIGURADO"
    }

    Write-Host ""
    Write-InfoMessage "Configurando firewall..."

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

    Write-SuccessMessage "Regla de firewall creada"
    Write-Host ""
}

function iniciar_dhcp {
    Write-Host ""
    Write-Header "Iniciando Servicio DHCP"
    Write-Host ""

    Write-InfoMessage "Iniciando servicio DHCPServer..."

    try {
        Restart-Service -Name DHCPServer -Force -ErrorAction Stop
        Write-SuccessMessage "Servicio iniciado correctamente"
        Write-Host ""

        $service = Get-Service -Name DHCPServer
        Write-InfoMessage "Estado del servicio: $($service.Status)"

        # Verificar que las opciones del scope quedaron registradas correctamente
        Write-Host ""
        $scopesActivos = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
        foreach ($scope in $scopesActivos) {
            Write-InfoMessage "Verificando opciones del scope: $($scope.Name)"

            $opcionDNS = Get-DhcpServerv4OptionValue `
                -ScopeId $scope.ScopeId `
                -OptionId 6 `
                -ErrorAction SilentlyContinue

            if ($opcionDNS) {
                Write-SuccessMessage "Opcion 6 (DNS) registrada: $($opcionDNS.Value)"
            } else {
                Write-WarningCustom "El scope '$($scope.Name)' NO tiene la opcion 6 (DNS) configurada"
                Write-InfoMessage "Los clientes no recibiran servidor DNS por DHCP"
            }

            $opcionGW = Get-DhcpServerv4OptionValue `
                -ScopeId $scope.ScopeId `
                -OptionId 3 `
                -ErrorAction SilentlyContinue

            if ($opcionGW) {
                Write-SuccessMessage "Opcion 3 (Gateway) registrada: $($opcionGW.Value)"
            } else {
                Write-InfoMessage "Opcion 3 (Gateway): NO CONFIGURADA"
            }
        }

    } catch {
        Write-ErrorMessage "Error al iniciar el servicio: $_"
        exit 1
    }
}
#
#   Monitor tiempo real
#
function monitoreo_info {
    Write-Header "Monitor de Servicio DHCP"
    Write-Host ""
    Write-InfoMessage "Actualizacion: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host ""

    $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue

    if ($scopes) {
        foreach ($scope in $scopes) {
            Write-Host "  Scope  : $($scope.Name)"
            Write-Host "  Red    : $($scope.ScopeId)"
            Write-Host "  Rango  : $($scope.StartRange) - $($scope.EndRange)"
            Write-Host ""

            # Obtener la IP del servidor buscando una IP en el mismo segmento que el scope
            $octetsScope = $scope.ScopeId.ToString().Split('.')
            $prefijoScope = "$($octetsScope[0]).$($octetsScope[1]).$($octetsScope[2])."

            $serverIP = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.IPAddress -notlike "127.*" -and
                    $_.IPAddress -notlike "169.254.*" -and
                    $_.IPAddress.StartsWith($prefijoScope)
                } |
                Select-Object -ExpandProperty IPAddress -First 1

            if ($serverIP) {
                Write-InfoMessage "IP del servidor DHCP: $serverIP"
                Write-Host ""
            }

            try {
                $leases = @(Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction Stop)

                if ($leases.Count -gt 0) {
                    Write-InfoMessage "Concesiones activas: $($leases.Count)"
                    Write-Host ""

                    foreach ($lease in $leases) {
                        $estado   = if ($lease.AddressState -eq "Active") { "ACTIVO" } else { $lease.AddressState }
                        $hostname = if ($lease.HostName) { $lease.HostName } else { "Sin nombre" }
                        $expira   = if ($lease.LeaseExpiryTime) { $lease.LeaseExpiryTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "N/A" }

                        Write-Host "  IP     : $($lease.IPAddress)"
                        Write-Host "    Host   : $hostname"
                        Write-Host "    MAC    : $($lease.ClientId)"
                        Write-Host "    Estado : $estado"
                        Write-Host "    Expira : $expira"
                        Write-Host ""
                    }
                } else {
                    Write-InfoMessage "Sin concesiones activas"
                    Write-Host ""
                }
            } catch {
                Write-ErrorMessage "Error al obtener concesiones: $_"
                Write-Host ""
            }
        }
    } else {
        Write-InfoMessage "No hay scopes configurados"
        Write-Host ""
    }
}
#
#   Funciones del Menu Principal
#
function verificar_instalacion {
    Write-Host ""
    Write-Header "Verificando instalacion del servicio DHCP"
    Write-Host ""

    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue

    if ($dhcpFeature.Installed) {
        Write-SuccessMessage "Estado: INSTALADO"
        Write-Host ""

        $service = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue

        if ($service) {
            Write-Host "  Servicio DHCPServer:"
            Write-Host "    Estado : $($service.Status)"
            Write-Host "    Inicio : $($service.StartType)"
        }
    } else {
        Write-WarningCustom "Estado: NO INSTALADO"
        Write-Host ""
        Write-InfoMessage "Use la opcion 2 del menu para instalar el servicio"
    }
    Write-Host ""
}

function instalar_y_configurar_servicio {
    Write-Host ""
    Write-Header "INSTALACION Y CONFIGURACION COMPLETA"
    Write-Host ""

    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue

    if (-not $dhcpFeature.Installed) {
        Write-InfoMessage "Instalando rol DHCP..."
        Write-InfoMessage "Esto puede tardar varios minutos..."
        Write-Host ""

        try {
            Install-WindowsFeature -Name DHCP -IncludeManagementTools -ErrorAction Stop | Out-Null

            Write-Host ""
            Write-SuccessMessage "Rol DHCP instalado correctamente"
            Write-Host ""

            Set-Service -Name DHCPServer -StartupType Automatic

        } catch {
            Write-Host ""
            Write-ErrorMessage "Error durante la instalacion: $_"
            return
        }
    } else {
        Write-InfoMessage "El servicio DHCP ya esta instalado"
        Write-Host ""
    }

    Write-InfoMessage "Iniciando configuracion..."
    Write-Host ""

    deteccion_interfaces_red
    parametros_usuario
    configurar_interfaz_red
    config_dhcp
    iniciar_dhcp

    Write-Host ""
    Write-SeparatorLine
    Write-SuccessMessage "Instalacion y configuracion completada"
    Write-SeparatorLine
    Write-Host ""
}

function nueva_configuracion {
    Write-Host ""
    Write-Header "Nueva configuracion del servicio DHCP"
    Write-Host ""

    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue

    if (-not $dhcpFeature.Installed) {
        Write-ErrorMessage "El servicio DHCP no esta instalado"
        Write-Host ""
        Write-InfoMessage "Use la opcion 2 del menu para instalar"
        return
    }

    Write-InfoMessage "Iniciando configuracion..."

    deteccion_interfaces_red
    parametros_usuario
    configurar_interfaz_red
    config_dhcp
    iniciar_dhcp

    Write-Host ""
    Write-SeparatorLine
    Write-SuccessMessage "Configuracion Completada"
    Write-SeparatorLine
    Write-Host ""
}

function reiniciar_servicio {
    Write-Header "Reiniciando servicio DHCP"

    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue

    if (-not $dhcpFeature.Installed) {
        Write-ErrorMessage "El servicio no esta instalado"
        return
    }

    try {
        Restart-Service -Name DHCPServer -Force -ErrorAction Stop
        Write-SuccessMessage "Servicio reiniciado correctamente"
        Write-Host ""

        $service = Get-Service -Name DHCPServer
        Write-InfoMessage "Estado: $($service.Status)"
    } catch {
        Write-ErrorMessage "Error al reiniciar el servicio"
        Write-ErrorMessage "Detalle: $_"
    }
}

function modo_monitor {
    Write-Host ""
    Write-InfoMessage "Iniciando modo monitor..."
    Write-InfoMessage "Presiona Ctrl+C para salir"
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
    Write-Header "Configuracion Actual del Servidor"
    Write-Host ""

    $dhcpFeature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue

    if (-not $dhcpFeature.Installed) {
        Write-WarningCustom "El servicio DHCP no esta instalado"
        return
    }

    Write-Host "1. Estado del Servicio:"
    Write-SeparatorLine

    $service = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue

    if ($service) {
        if ($service.Status -eq 'Running') {
            Write-SuccessMessage "Estado: ACTIVO"
        } else {
            Write-WarningCustom "Estado: $($service.Status)"
        }
        if ($service.StartType -eq 'Automatic') {
            Write-SuccessMessage "Inicio automatico: HABILITADO"
        } else {
            Write-WarningCustom "Inicio automatico: $($service.StartType)"
        }
    } else {
        Write-WarningCustom "Servicio no encontrado"
    }
    Write-Host ""

    Write-Host "2. Configuracion DHCP:"
    Write-SeparatorLine

    $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue

    if ($scopes) {
        foreach ($scope in $scopes) {
            Write-Host "  Nombre del Scope   : $($scope.Name)"
            Write-Host "  ScopeId            : $($scope.ScopeId)"
            Write-Host "  Mascara            : $($scope.SubnetMask)"
            Write-Host "  Rango              : $($scope.StartRange) - $($scope.EndRange)"
            Write-Host "  Estado             : $($scope.State)"
            Write-Host "  Lease Duration     : $($scope.LeaseDuration)"
            Write-Host ""

            $options = Get-DhcpServerv4OptionValue -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue

            $gatewayOpt = ($options | Where-Object { $_.OptionId -eq 3 }).Value
            $dnsOpt     = ($options | Where-Object { $_.OptionId -eq 6 }).Value

            if ($gatewayOpt) {
                Write-Host "  Gateway            : $gatewayOpt"
            } else {
                Write-InfoMessage "Gateway: NO CONFIGURADO"
            }

            if ($dnsOpt) {
                Write-Host "  DNS                : $dnsOpt"
            } else {
                Write-InfoMessage "DNS: NO CONFIGURADO"
            }

            Write-Host ""
        }
    } else {
        Write-InfoMessage "No hay scopes configurados"
    }
    Write-Host ""

    Write-Host "3. Estadisticas:"
    Write-SeparatorLine

    if ($scopes) {
        foreach ($scope in $scopes) {
            Write-Host "  Scope: $($scope.Name)"

            try {
                $leases = @(Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction Stop)

                if ($leases.Count -gt 0) {
                    $totalLeases  = $leases.Count
                    $activeLeases = @($leases | Where-Object { $_.AddressState -eq "Active" }).Count

                    Write-Host "    Concesiones totales : $totalLeases"
                    Write-Host "    Concesiones activas : $activeLeases"
                    Write-Host ""

                    foreach ($lease in $leases) {
                        $estado   = if ($lease.AddressState -eq "Active") { "ACTIVO" } else { $lease.AddressState }
                        $hostname = if ($lease.HostName) { $lease.HostName } else { "Sin nombre" }
                        Write-Host "    - IP: $($lease.IPAddress) | Estado: $estado | Host: $hostname"
                    }
                } else {
                    Write-InfoMessage "Sin concesiones"
                }
            } catch {
                Write-ErrorMessage "Error al obtener concesiones: $_"
            }
            Write-Host ""
        }
    } else {
        Write-InfoMessage "Sin scopes configurados"
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
        Write-Header "Gestor de Servicio DHCP"
        Write-Host ""
        Write-Host "Seleccione una opcion:"
        Write-Host ""
        Write-Host "  1) Verificar instalacion"
        Write-Host "  2) Instalar y configurar servicio"
        Write-Host "  3) Nueva configuracion (requiere instalacion previa)"
        Write-Host "  4) Reiniciar servicio"
        Write-Host "  5) Monitor de concesiones"
        Write-Host "  6) Ver configuracion actual"
        Write-Host "  7) Salir"
        Write-Host ""
        $OP = Read-Host "Opcion"

        switch ($OP) {
            "1" { verificar_instalacion }
            "2" { instalar_y_configurar_servicio }
            "3" { nueva_configuracion }
            "4" { reiniciar_servicio }
            "5" { modo_monitor }
            "6" { ver_configuracion_actual }
            "7" {
                Write-Host ""
                Write-InfoMessage "Saliendo del programa..."
                exit 0
            }
            default {
                Write-Host ""
                Write-ErrorMessage "Opcion invalida"
            }
        }

        Write-Host ""
        Invoke-Pause
    }
}
#
#   Punto de Entrada Principal
#
if (-not (Test-AdminPrivileges)) {
    Write-Host ""
    Read-Host "Presiona Enter para salir"
    exit 1
}

main_menu