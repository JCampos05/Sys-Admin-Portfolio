#
#   validators.ps1
#   Modulo de validacion de redes IPv4 para PowerShell
#
#   Todas las validaciones de direcciones IPv4, mascaras,
#   rangos y calculos de subred se realizan aqui.
#   Usa operaciones nativas de .NET sobre uint32 como
#   alternativa directa a ipcalc, sin dependencias externas.
#
#   Variables de script que este modulo puede modificar:
#       $script:mascara      -> mascara en formato decimal punteado
#       $script:bitsMascara  -> prefijo CIDR numerico
#       $script:red          -> direccion de red calculada
#
#   Uso:
#       . "$PSScriptRoot\validators.ps1"
#

# ============================================================================
# FUNCIONES DE SOPORTE INTERNO
# ============================================================================

<#
.SYNOPSIS
    Convierte una direccion IPv4 a su representacion como entero uint32
.PARAMETER IP
    Cadena con la direccion IPv4 en formato decimal punteado
.OUTPUTS
    UInt32 - Representacion numerica de la IP
#>
function ip_a_numero {
    param([string]$ip)

    $octetos = $ip.Split('.')
    $oct1 = [uint32]$octetos[0]
    $oct2 = [uint32]$octetos[1]
    $oct3 = [uint32]$octetos[2]
    $oct4 = [uint32]$octetos[3]

    return ($oct1 * [uint32][math]::Pow(256, 3) + $oct2 * [uint32][math]::Pow(256, 2) + $oct3 * 256 + $oct4)
}

<#
.SYNOPSIS
    Convierte un entero uint32 a su representacion IPv4 decimal punteada
.PARAMETER Numero
    Entero sin signo que representa la IP
.OUTPUTS
    String - Direccion IPv4 en formato decimal punteado
#>
function numero_a_ip {
    param([uint32]$numero)

    $oct1 = [math]::Floor($numero / [math]::Pow(256, 3))
    $resto = $numero % [uint32][math]::Pow(256, 3)

    $oct2 = [math]::Floor($resto / [math]::Pow(256, 2))
    $resto = $resto % [uint32][math]::Pow(256, 2)

    $oct3 = [math]::Floor($resto / 256)
    $oct4 = $resto % 256

    return "$oct1.$oct2.$oct3.$oct4"
}

# ============================================================================
# FUNCIONES DE VALIDACION DE FORMATO
# ============================================================================

<#
.SYNOPSIS
    Valida el formato basico de una direccion IPv4
.DESCRIPTION
    Verifica el patron X.X.X.X y que cada octeto este en el rango 0-255
.PARAMETER IP
    Cadena con la direccion IPv4 a validar
.OUTPUTS
    Boolean - True si el formato es correcto, False si no
#>
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

<#
.SYNOPSIS
    Valida que el prefijo CIDR sea un entero entre 1 y 30
.DESCRIPTION
    Se excluyen /31 y /32 por no ser utiles para rangos DHCP.
    /31 solo tiene 2 IPs (red y broadcast), /32 es un host individual.
.PARAMETER Cidr
    Valor numerico del prefijo CIDR
.OUTPUTS
    Boolean - True si el prefijo es valido, False si no
#>
function validar_cidr {
    param([string]$cidr)

    if ($cidr -notmatch '^\d+$') {
        Write-ErrorMessage "El prefijo CIDR debe ser un numero entero"
        return $false
    }

    $cidrNum = [int]$cidr

    if ($cidrNum -lt 1 -or $cidrNum -gt 30) {
        Write-ErrorMessage "El prefijo CIDR debe estar entre /1 y /30"
        Write-InfoMessage "  /31 y /32 no permiten rangos DHCP validos"
        return $false
    }

    return $true
}

# ============================================================================
# FUNCIONES DE CALCULO DE RED
# ============================================================================

<#
.SYNOPSIS
    Obtiene la direccion de red aplicando AND bit a bit entre IP y mascara
.PARAMETER IP
    Direccion IPv4 de referencia
.PARAMETER Mascara
    Mascara de subred en formato decimal punteado
.OUTPUTS
    String - Direccion de red resultante
#>
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

<#
.SYNOPSIS
    Calcula la mascara de subred en formato decimal punteado a partir del prefijo CIDR
.DESCRIPTION
    Construye la mascara desplazando bits: los primeros N bits son 1, el resto 0.
    Equivalente nativo a lo que ipcalc reporta como NETMASK.
.PARAMETER Cidr
    Prefijo CIDR numerico (1-30)
.OUTPUTS
    String - Mascara de subred en formato decimal punteado
#>
function cidr_a_mascara {
    param([int]$cidr)

    # Construir mascara: N bits a 1 desde la izquierda de un uint32
    # Ejemplo: /24 -> 11111111.11111111.11111111.00000000 -> 255.255.255.0
    $mascara = [uint32]0

    for ($i = 0; $i -lt $cidr; $i++) {
        $mascara = $mascara -bor ([uint32]1 -shl (31 - $i))
    }

    $oct1 = ($mascara -shr 24) -band 0xFF
    $oct2 = ($mascara -shr 16) -band 0xFF
    $oct3 = ($mascara -shr 8)  -band 0xFF
    $oct4 =  $mascara           -band 0xFF

    return "$oct1.$oct2.$oct3.$oct4"
}

<#
.SYNOPSIS
    Calcula todos los parametros de subred a partir de la IP base y el prefijo CIDR
.DESCRIPTION
    Equivalente directo a ipcalc -n -m -b IP/CIDR.
    Actualiza las variables de script: mascara, bitsMascara y red.
    Muestra un resumen de la subred al usuario.
.PARAMETER IP
    Direccion IPv4 base ingresada por el usuario
.PARAMETER Cidr
    Prefijo CIDR numerico (1-30)
.OUTPUTS
    Boolean - True si el calculo fue exitoso, False si no
#>
function calcular_subred_cidr {
    param(
        [string]$ip,
        [int]$cidr
    )

    # Calcular mascara a partir del prefijo
    $mascaraCalculada = cidr_a_mascara $cidr

    if ([string]::IsNullOrEmpty($mascaraCalculada)) {
        Write-ErrorMessage "No se pudo calcular la mascara para /$cidr"
        return $false
    }

    # Calcular direccion de red (AND bit a bit)
    $redCalculada = obtener_ip_red $ip $mascaraCalculada

    # Calcular broadcast (OR bit a bit entre red e inverso de mascara)
    $redOctetos     = $redCalculada.Split('.')
    $mascaraOctetos = $mascaraCalculada.Split('.')

    $b1 = ([int]$redOctetos[0] -band [int]$mascaraOctetos[0]) -bor (255 - [int]$mascaraOctetos[0])
    $b2 = ([int]$redOctetos[1] -band [int]$mascaraOctetos[1]) -bor (255 - [int]$mascaraOctetos[1])
    $b3 = ([int]$redOctetos[2] -band [int]$mascaraOctetos[2]) -bor (255 - [int]$mascaraOctetos[2])
    $b4 = ([int]$redOctetos[3] -band [int]$mascaraOctetos[3]) -bor (255 - [int]$mascaraOctetos[3])

    $broadcastCalculado = "$b1.$b2.$b3.$b4"

    # Calcular IPs totales y usables: 2^(32-cidr) - 2
    $hostsBits   = 32 - $cidr
    $ipsTotales  = [math]::Pow(2, $hostsBits)
    $ipsUsables  = $ipsTotales - 2

    # Actualizar variables globales del script principal
    $script:mascara     = $mascaraCalculada
    $script:bitsMascara = $cidr
    $script:red         = $redCalculada

    # Mostrar resumen equivalente a la salida de ipcalc
    Write-Host ""
    Write-SeparatorLine
    Write-Host "  Informacion de subred /$cidr"
    Write-SeparatorLine
    Write-Host ("  Direccion de red    : {0}" -f $redCalculada)
    Write-Host ("  Mascara             : {0}" -f $mascaraCalculada)
    Write-Host ("  Broadcast           : {0}" -f $broadcastCalculado)
    Write-Host ("  IPs totales         : {0}" -f $ipsTotales)
    Write-Host ("  IPs usables         : {0}" -f $ipsUsables)
    Write-SeparatorLine
    Write-Host ""

    return $true
}

# ============================================================================
# FUNCIONES DE VALIDACION DE RANGO Y SEGMENTO
# ============================================================================

<#
.SYNOPSIS
    Valida que la IP no pertenezca a rangos reservados o no enrutables
.DESCRIPTION
    Comprueba: 0.0.0.0/8, 127.0.0.0/8, multicast 224-239, experimentales 240-255
    y el broadcast limitado 255.255.255.255
.PARAMETER IP
    Direccion IPv4 a validar
.OUTPUTS
    Boolean - True si la IP es utilizable, False si no
#>
function validar_ip_usable {
    param([string]$ip)

    if (-not (validar_formato_ip $ip)) {
        Write-ErrorMessage "Formato IPv4 incorrecto"
        return $false
    }

    $octetos = $ip.Split('.')
    $oct1    = [int]$octetos[0]
    $oct2    = [int]$octetos[1]
    $oct3    = [int]$octetos[2]
    $oct4    = [int]$octetos[3]

    if ($oct1 -eq 0) {
        Write-ErrorMessage "La red 0.0.0.0/8 es reservada y no es utilizable"
        return $false
    }

    if ($oct1 -eq 127) {
        Write-ErrorMessage "La red 127.0.0.0/8 es de loopback y no es utilizable"
        return $false
    }

    if ($oct1 -eq 255 -and $oct2 -eq 255 -and $oct3 -eq 255 -and $oct4 -eq 255) {
        Write-ErrorMessage "255.255.255.255 es la direccion de broadcast limitado"
        return $false
    }

    if ($oct1 -ge 224 -and $oct1 -le 239) {
        Write-ErrorMessage "El rango 224.0.0.0 - 239.255.255.255 es multicast"
        return $false
    }

    if ($oct1 -ge 240 -and $oct1 -le 255) {
        Write-ErrorMessage "El rango 240.0.0.0 - 255.255.255.255 es experimental"
        return $false
    }

    return $true
}

<#
.SYNOPSIS
    Valida que una IP no sea la direccion de red ni la de broadcast de la subred
.PARAMETER IP
    Direccion IPv4 a verificar
.PARAMETER Red
    Direccion de red de la subred
.PARAMETER Mascara
    Mascara de la subred en formato decimal punteado
.OUTPUTS
    Boolean - True si la IP es valida, False si es una direccion especial
#>
function validar_ip_no_especial {
    param(
        [string]$ip,
        [string]$red,
        [string]$mascara
    )

    $redOctetos     = $red.Split('.')
    $mascaraOctetos = $mascara.Split('.')

    $b1 = ([int]$redOctetos[0] -band [int]$mascaraOctetos[0]) -bor (255 - [int]$mascaraOctetos[0])
    $b2 = ([int]$redOctetos[1] -band [int]$mascaraOctetos[1]) -bor (255 - [int]$mascaraOctetos[1])
    $b3 = ([int]$redOctetos[2] -band [int]$mascaraOctetos[2]) -bor (255 - [int]$mascaraOctetos[2])
    $b4 = ([int]$redOctetos[3] -band [int]$mascaraOctetos[3]) -bor (255 - [int]$mascaraOctetos[3])

    $broadcast = "$b1.$b2.$b3.$b4"

    if ($ip -eq $red) {
        Write-ErrorMessage "No puede usar la direccion de red ($red)"
        return $false
    }

    if ($ip -eq $broadcast) {
        Write-ErrorMessage "No puede usar la direccion de broadcast ($broadcast)"
        return $false
    }

    return $true
}

<#
.SYNOPSIS
    Valida que dos IPs pertenezcan al mismo segmento de red
.PARAMETER IPBase
    Direccion IPv4 de referencia (la red configurada)
.PARAMETER IPComparar
    Direccion IPv4 a verificar
.PARAMETER Mascara
    Mascara de la subred en formato decimal punteado
.OUTPUTS
    Boolean - True si pertenecen al mismo segmento, False si no
#>
function validar_mismo_segmento {
    param(
        [string]$ipBase,
        [string]$ipComparar,
        [string]$mascara
    )

    $redBase     = obtener_ip_red $ipBase $mascara
    $redComparar = obtener_ip_red $ipComparar $mascara

    if ($redBase -ne $redComparar) {
        Write-ErrorMessage "La IP $ipComparar no pertenece al segmento $redBase"
        return $false
    }

    return $true
}

<#
.SYNOPSIS
    Valida que la IP inicial del rango sea estrictamente menor que la IP final
.PARAMETER IPInicio
    Direccion IPv4 de inicio del rango
.PARAMETER IPFin
    Direccion IPv4 de fin del rango
.OUTPUTS
    Boolean - True si el rango es valido, False si no
#>
function validar_rango_ips {
    param(
        [string]$ipInicio,
        [string]$ipFin
    )

    $numInicio = ip_a_numero $ipInicio
    $numFin    = ip_a_numero $ipFin

    if ($numInicio -ge $numFin) {
        Write-ErrorMessage "La IP inicial debe ser menor que la IP final"
        Write-InfoMessage "  IP Inicial : $ipInicio  (valor: $numInicio)"
        Write-InfoMessage "  IP Final   : $ipFin  (valor: $numFin)"
        return $false
    }

    return $true
}