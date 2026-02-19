#
# validators_dns.ps1
# Funciones de validacion para DNS
# 
# Requiere:
#   - utils.ps1 debe estar cargado antes
#
#
#   Validaciones de Formato
#
# Valida el formato basico de una direccion IPv4
# Comprueba patron X.X.X.X y que cada octeto sea 0-255
function Test-DNSIPFormat {
    param([string]$IPAddress)
    
    $ipRegex = '^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
    
    if ($IPAddress -match $ipRegex) {
        return $true
    }
    return $false
}

# Valida que la IP no pertenezca a rangos reservados o no usables
# Reservados: 0.0.0.0/8, 127.0.0.0/8, multicast 224-239, experimentales 240-255
function Test-DNSIPUsable {
    param([string]$IPAddress)
    
    if (-not (Test-DNSIPFormat -IPAddress $IPAddress)) {
        Write-ErrorMessage "Formato IPv4 incorrecto: $IPAddress"
        return $false
    }
    
    $octets = $IPAddress -split '\.'
    $oct1 = [int]$octets[0]
    $oct2 = [int]$octets[1]
    $oct3 = [int]$octets[2]
    $oct4 = [int]$octets[3]
    
    if ($oct1 -eq 0) {
        Write-ErrorMessage 'La red 0.0.0.0/8 es reservada y no es utilizable'
        return $false
    }
    
    if ($oct1 -eq 127) {
        Write-ErrorMessage 'La red 127.0.0.0/8 es de loopback y no es utilizable'
        return $false
    }
    
    if ($oct1 -eq 255 -and $oct2 -eq 255 -and $oct3 -eq 255 -and $oct4 -eq 255) {
        Write-ErrorMessage '255.255.255.255 es la direccion de broadcast limitado'
        return $false
    }
    
    if ($oct1 -ge 224 -and $oct1 -le 239) {
        Write-ErrorMessage 'El rango 224.0.0.0 - 239.255.255.255 es multicast'
        return $false
    }
    
    if ($oct1 -ge 240 -and $oct1 -le 255) {
        Write-ErrorMessage 'El rango 240.0.0.0 - 255.255.255.255 es experimental'
        return $false
    }
    
    return $true
}

# Valida una IP completa: formato + usable
# Uso: Test-DNSIP "192.168.1.1"
function Test-DNSIP {
    param([string]$IPAddress)
    
    if (-not (Test-DNSIPFormat -IPAddress $IPAddress)) {
        Write-ErrorMessage "Formato de IP invalido: $IPAddress"
        Write-InfoMessage 'El formato debe ser X.X.X.X donde cada X es 0-255'
        return $false
    }
    
    if (-not (Test-DNSIPUsable -IPAddress $IPAddress)) {
        return $false
    }
    
    return $true
}

#
#   Validaciones de Nombres
#

# Valida el formato de un nombre de dominio
# Acepta: letras, numeros, guiones y puntos
# No acepta: espacios, caracteres especiales, dominio vacio
# Ejemplos validos: ejemplo.com, sub.ejemplo.com, mi-sitio.org
function Test-DNSDomainName {
    param([string]$Domain)
    
    if ([string]::IsNullOrWhiteSpace($Domain)) {
        Write-ErrorMessage 'El nombre del dominio no puede estar vacio'
        return $false
    }
    
    # Debe tener al menos un punto (TLD obligatorio)
    if ($Domain -notlike '*.*') {
        Write-ErrorMessage 'El dominio debe tener al menos un punto (ej: ejemplo.com)'
        return $false
    }
    
    # Solo letras, numeros, guiones y puntos
    if ($Domain -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)+$') {
        Write-ErrorMessage "Nombre de dominio invalido: $Domain"
        Write-InfoMessage 'Solo se permiten letras, numeros, guiones y puntos'
        Write-InfoMessage 'No puede comenzar ni terminar con guion o punto'
        return $false
    }
    
    # Longitud maxima de etiqueta DNS es 63 caracteres
    $labels = $Domain -split '\.'
    foreach ($label in $labels) {
        if ($label.Length -gt 63) {
            Write-ErrorMessage 'Cada parte del dominio no puede superar 63 caracteres'
            return $false
        }
    }
    
    # Longitud total maxima de un FQDN es 253 caracteres
    if ($Domain.Length -gt 253) {
        Write-ErrorMessage 'El nombre del dominio no puede superar 253 caracteres'
        return $false
    }
    
    return $true
}

# Valida el nombre de un host o subdominio (sin puntos)
# Ejemplos validos: www, mail, ns1, ftp, servidor-1
function Test-DNSHostName {
    param([string]$HostName)
    
    if ([string]::IsNullOrWhiteSpace($HostName)) {
        Write-ErrorMessage 'El nombre del host no puede estar vacio'
        return $false
    }
    
    if ($HostName -notmatch '^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?$') {
        Write-ErrorMessage "Nombre de host invalido: $HostName"
        Write-InfoMessage 'Solo letras, numeros y guiones. No puede comenzar ni terminar con guion'
        return $false
    }
    
    if ($HostName.Length -gt 63) {
        Write-ErrorMessage 'El nombre del host no puede superar 63 caracteres'
        return $false
    }
    
    return $true
}

#
#   Validaciones de Parametros DNS
#

# Valida que el TTL sea un numero entero positivo
# Rango razonable: 60 segundos (1 minuto) a 604800 (1 semana)
function Test-DNSTTL {
    param([string]$TTL)
    
    if ($TTL -notmatch '^\d+$') {
        Write-ErrorMessage 'El TTL debe ser un numero entero positivo'
        return $false
    }
    
    $ttlInt = [int]$TTL
    
    if ($ttlInt -lt 60) {
        Write-ErrorMessage 'El TTL minimo es 60 segundos'
        Write-InfoMessage 'Un TTL muy bajo genera trafico excesivo en el DNS'
        return $false
    }
    
    if ($ttlInt -gt 604800) {
        Write-ErrorMessage 'El TTL maximo recomendado es 604800 (1 semana)'
        return $false
    }
    
    return $true
}

# Valida que la prioridad MX sea un entero entre 0 y 65535
function Test-DNSMXPriority {
    param([string]$Priority)
    
    if ($Priority -notmatch '^\d+$') {
        Write-ErrorMessage 'La prioridad MX debe ser un numero entero'
        return $false
    }
    
    $prioInt = [int]$Priority
    
    if ($prioInt -lt 0 -or $prioInt -gt 65535) {
        Write-ErrorMessage 'La prioridad MX debe estar entre 0 y 65535'
        return $false
    }
    
    return $true
}

#
#   Exportar funciones del modulo
#
Export-ModuleMember -Function *