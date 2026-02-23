#
# Validaciones específicas para la configuración del servicio SSH en Windows
#
# Requiere:
#   utils.ps1 debe estar importado antes (para Write-Err / Write-Info)
#


# Valida el formato de una dirección IPv4 (X.X.X.X, cada octeto 0-255)
# Uso: Test-SSHIp "192.168.100.20"   → $true / $false
function Test-SSHIp {
    param([string]$Ip)

    if ([string]::IsNullOrWhiteSpace($Ip)) {
        Write-Err "La IP no puede estar vacia"
        return $false
    }

    # Verificar patrón X.X.X.X con regex
    if ($Ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        Write-Err "Formato de IP invalido: '$Ip'"
        Write-Info "El formato correcto es X.X.X.X  (ej: 192.168.100.20)"
        return $false
    }

    # Verificar que cada octeto esté entre 0 y 255
    $octetos = $Ip.Split('.')
    foreach ($oct in $octetos) {
        if ([int]$oct -lt 0 -or [int]$oct -gt 255) {
            Write-Err "Octeto fuera de rango (0-255): $oct"
            return $false
        }
    }

    # Rechazar loopback
    if ($octetos[0] -eq '127') {
        Write-Err "La IP $Ip es de loopback y no es valida para SSH remoto"
        return $false
    }

    # Rechazar red 0.x.x.x
    if ($octetos[0] -eq '0') {
        Write-Err "La red 0.0.0.0/8 esta reservada y no es valida"
        return $false
    }

    # Rechazar broadcast total
    if ($Ip -eq '255.255.255.255') {
        Write-Err "255.255.255.255 es broadcast y no es valida para SSH"
        return $false
    }

    return $true
}

# Valida que un número de puerto sea válido para SSH
# Rango: 1-65535. Puertos < 1024 generan advertencia.
# Uso: Test-SSHPuerto "22"   → $true / $false
function Test-SSHPuerto {
    param([string]$Puerto)

    # Debe ser numérico
    if ($Puerto -notmatch '^\d+$') {
        Write-Err "El puerto debe ser un numero entero positivo"
        Write-Info "Ejemplo: 22, 2222, 2200"
        return $false
    }

    $p = [int]$Puerto

    if ($p -lt 1 -or $p -gt 65535) {
        Write-Err "Puerto fuera de rango. Debe estar entre 1 y 65535"
        return $false
    }

    if ($p -lt 1024) {
        Write-Warn "El puerto $p es un puerto de sistema (privilegiado)"
        Write-Info "Se recomienda usar puertos >= 1024 para mayor seguridad"
    }

    if ($p -eq 22) {
        Write-Info "Usando el puerto SSH estandar (22)"
    }

    return $true
}

# Valida MaxAuthTries: intentos máximos de autenticación (1-10)
# Uso: Test-SSHMaxAuthTries "3"
function Test-SSHMaxAuthTries {
    param([string]$Valor)

    if ($Valor -notmatch '^\d+$') {
        Write-Err "MaxAuthTries debe ser un numero entero positivo"
        return $false
    }

    $v = [int]$Valor

    if ($v -lt 1) {
        Write-Err "MaxAuthTries minimo es 1"
        return $false
    }

    if ($v -gt 10) {
        Write-Err "MaxAuthTries maximo recomendado es 10"
        Write-Info "Un valor muy alto facilita ataques de fuerza bruta"
        return $false
    }

    if ($v -gt 3) {
        Write-Warn "Se recomienda MaxAuthTries <= 3 para mayor seguridad"
    }

    return $true
}

# Valida LoginGraceTime: segundos para completar el login (10-300)
# Uso: Test-SSHLoginGraceTime "30"
function Test-SSHLoginGraceTime {
    param([string]$Valor)

    if ($Valor -notmatch '^\d+$') {
        Write-Err "LoginGraceTime debe ser un numero entero de segundos"
        return $false
    }

    $v = [int]$Valor

    if ($v -lt 10) {
        Write-Err "LoginGraceTime minimo es 10 segundos"
        Write-Info "Un valor muy bajo puede cortar conexiones legitimas lentas"
        return $false
    }

    if ($v -gt 300) {
        Write-Err "LoginGraceTime maximo recomendado es 300 segundos (5 minutos)"
        return $false
    }

    if ($v -gt 60) {
        Write-Warn "Se recomienda LoginGraceTime <= 60 segundos para mejor seguridad"
    }

    return $true
}

# Valida MaxSessions: sesiones simultáneas por conexión (1-20)
# Uso: Test-SSHMaxSessions "3"
function Test-SSHMaxSessions {
    param([string]$Valor)

    if ($Valor -notmatch '^\d+$') {
        Write-Err "MaxSessions debe ser un numero entero positivo"
        return $false
    }

    $v = [int]$Valor

    if ($v -lt 1) {
        Write-Err "MaxSessions minimo es 1"
        return $false
    }

    if ($v -gt 20) {
        Write-Err "MaxSessions maximo recomendado es 20"
        Write-Info "Un numero muy alto puede saturar el servidor"
        return $false
    }

    return $true
}

# Valida que el nombre de usuario tenga formato válido 
# Reglas: no vacío, sin caracteres especiales prohibidos, máx 20 chars
# Uso: Test-SSHNombreUsuario "Administrador"
function Test-SSHNombreUsuario {
    param([string]$Usuario)

    if ([string]::IsNullOrWhiteSpace($Usuario)) {
        Write-Err "El nombre de usuario no puede estar vacio"
        return $false
    }

    # Longitud máxima en Windows: 20 caracteres (SAM account)
    if ($Usuario.Length -gt 20) {
        Write-Err "El nombre de usuario no puede superar 20 caracteres en Windows"
        return $false
    }

    # Caracteres prohibidos en nombres de usuario Windows
    # \ / : * ? " < > | [ ]  y algunos más
    $prohibidos = '[\/\\\:\*\?\"\<\>\|\[\]]'
    if ($Usuario -match $prohibidos) {
        Write-Err "El usuario contiene caracteres no permitidos en Windows"
        Write-Info "Evite usar: \ / : * ? `" < > | [ ]"
        return $false
    }

    return $true
}

# Valida que un usuario exista realmente en el sistema 
# Uso: Test-SSHUsuarioExiste "Administrador"
function Test-SSHUsuarioExiste {
    param([string]$Usuario)

    if (-not (Test-SSHNombreUsuario $Usuario)) {
        return $false
    }

    try {
        $user = Get-LocalUser -Name $Usuario -ErrorAction Stop
        if ($user.Enabled) {
            return $true
        } else {
            Write-Warn "El usuario '$Usuario' existe pero esta DESHABILITADO"
            Write-Info "Habilite el usuario antes de usarlo para SSH"
            return $false
        }
    } catch {
        Write-Err "El usuario '$Usuario' no existe en este sistema"
        Write-Info "Usuarios locales disponibles:"
        Get-LocalUser | Where-Object { $_.Enabled } | ForEach-Object {
            Write-Host "  - $($_.Name)"
        }
        return $false
    }
}

# Valida el texto del banner SSH
# No vacío, mínimo 10 chars, máximo 500 chars
# Uso: Test-SSHBanner "Acceso restringido..."
function Test-SSHBanner {
    param([string]$Texto)

    if ([string]::IsNullOrWhiteSpace($Texto)) {
        Write-Err "El texto del banner no puede estar vacio"
        Write-Info "El banner es el aviso legal que ve el usuario antes de autenticarse"
        return $false
    }

    if ($Texto.Length -lt 10) {
        Write-Warn "El banner es muy corto ($($Texto.Length) caracteres)"
        Write-Info "Un banner efectivo incluye: aviso de acceso restringido y consecuencias"
    }

    if ($Texto.Length -gt 500) {
        Write-Err "El banner no puede superar 500 caracteres (actual: $($Texto.Length))"
        return $false
    }

    return $true
}

# Valida el número de líneas de log a mostrar (10-500)
# Uso: Test-SSHLineasLog "50"
function Test-SSHLineasLog {
    param([string]$Lineas)

    if ($Lineas -notmatch '^\d+$') {
        Write-Err "El numero de lineas debe ser un entero positivo"
        return $false
    }

    $v = [int]$Lineas

    if ($v -lt 10) {
        Write-Err "Minimo 10 lineas de log"
        return $false
    }

    if ($v -gt 500) {
        Write-Err "Maximo recomendado: 500 lineas (valor ingresado: $v)"
        Write-Info "Para analisis extenso, use el Visor de Eventos de Windows"
        return $false
    }

    return $true
}

Export-ModuleMember -Function @(
    'Test-SSHIp',
    'Test-SSHPuerto',
    'Test-SSHMaxAuthTries',
    'Test-SSHLoginGraceTime',
    'Test-SSHMaxSessions',
    'Test-SSHNombreUsuario',
    'Test-SSHUsuarioExiste',
    'Test-SSHBanner',
    'Test-SSHLineasLog'
)