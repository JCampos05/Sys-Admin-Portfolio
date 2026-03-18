# 
# Validaciones de red
# 

# Valida que una dirección IPv4 tenga formato correcto (X.X.X.X)
# y que sea una IP de la red interna del laboratorio (192.168.100.0/24)
# Uso: Test-FtpIp "192.168.100.20"  -> $true / $false
function Test-FtpIp {
    param([string]$Ip)

    if ([string]::IsNullOrWhiteSpace($Ip)) {
        msg_error "La IP no puede estar vacía"
        return $false
    }

    # Patrón básico: cuatro grupos numéricos separados por punto
    if ($Ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        msg_error "Formato de IP inválido: '$Ip'"
        msg_info  "El formato correcto es X.X.X.X  (ej: 192.168.100.20)"
        return $false
    }

    $octetos = $Ip.Split('.')

    # Cada octeto debe estar en 0-255
    foreach ($oct in $octetos) {
        if ([int]$oct -lt 0 -or [int]$oct -gt 255) {
            msg_error "Octeto fuera de rango (0-255): $oct"
            return $false
        }
    }

    # Rechazar loopback
    if ($octetos[0] -eq '127') {
        msg_error "La IP $Ip es de loopback. No válida para FTP remoto"
        return $false
    }

    # Rechazar broadcast
    if ($Ip -eq '255.255.255.255') {
        msg_error "255.255.255.255 es broadcast. No válida para FTP"
        return $false
    }

    # Advertencia si la IP no está en las redes conocidas del laboratorio
    $esRedInterna = $Ip -match '^192\.168\.(100|70|75)\.\d{1,3}$'
    if (-not $esRedInterna) {
        msg_warn "La IP $Ip no pertenece a ninguna red del laboratorio"
        msg_info "Redes conocidas: 192.168.100.0/24 | 192.168.70.0/24 | 192.168.75.0/24"
    }

    return $true
}

# Valida un número de puerto para FTP (control o datos pasivos)
# Rango FTP PASV típico: 30000-31000 configurado en ftp.ps1
# Uso: Test-FtpPuerto "21"
function Test-FtpPuerto {
    param([string]$Puerto)

    if ($Puerto -notmatch '^\d+$') {
        msg_error "El puerto debe ser un número entero positivo"
        msg_info  "Ejemplos: 21 (control), 30000-31000 (PASV)"
        return $false
    }

    $p = [int]$Puerto

    if ($p -lt 1 -or $p -gt 65535) {
        msg_error "Puerto fuera de rango. Debe estar entre 1 y 65535"
        return $false
    }

    if ($p -lt 1024) {
        msg_warn "El puerto $p es un puerto de sistema (privilegiado)"
        msg_info "FTP estándar usa el puerto 21. Para PASV use >= 30000"
    }

    return $true
}

# Valida el rango de puertos pasivos (PASV)
# El rango debe ser coherente: min < max, mínimo 100 puertos de diferencia
# Uso: Test-FtpPasvRange "30000" "31000"
function Test-FtpPasvRange {
    param([string]$Min, [string]$Max)

    if (-not (Test-FtpPuerto $Min)) { return $false }
    if (-not (Test-FtpPuerto $Max)) { return $false }

    $pMin = [int]$Min
    $pMax = [int]$Max

    if ($pMin -ge $pMax) {
        msg_error "El puerto mínimo PASV ($pMin) debe ser menor que el máximo ($pMax)"
        return $false
    }

    $rango = $pMax - $pMin
    if ($rango -lt 100) {
        msg_warn "Rango PASV muy pequeño ($rango puertos). Se recomiendan al menos 100"
        msg_info "Un rango pequeño puede rechazar conexiones simultáneas"
    }

    return $true
}


# 
# Validaciones de rutas y directorios
# 

# Valida que una ruta de directorio tenga formato válido 
# No verifica que exista; solo que la cadena sea utilizable como ruta
# Uso: Test-FtpRuta "C:\FTP\LocalUser\alice"
function Test-FtpRuta {
    param([string]$Ruta)

    if ([string]::IsNullOrWhiteSpace($Ruta)) {
        msg_error "La ruta no puede estar vacía"
        return $false
    }

    # Caracteres prohibidos en rutas Windows: " * ? < > |
    # (la barra y los dos puntos son válidos en rutas absolutas)
    if ($Ruta -match '["\*\?<>\|]') {
        msg_error "La ruta contiene caracteres no permitidos en Windows: `"  *  ?  <  >  |"
        return $false
    }

    # Debe ser una ruta absoluta (letra de unidad o UNC)
    if ($Ruta -notmatch '^[A-Za-z]:\\' -and $Ruta -notmatch '^\\\\') {
        msg_error "Se requiere una ruta absoluta (ej: C:\FTP\LocalUser\alice)"
        return $false
    }

    return $true
}


# 
# Validaciones de usuarios FTP
# 

# Valida el formato de un nombre de usuario Windows local
# Reglas: no vacío, sin caracteres prohibidos, máximo 20 caracteres (SAM)
# Uso: Test-FtpNombreUsuario "ftpuser1"
function Test-FtpNombreUsuario {
    param([string]$Usuario)

    if ([string]::IsNullOrWhiteSpace($Usuario)) {
        msg_error "El nombre de usuario no puede estar vacío"
        return $false
    }

    # SAM Account Name: máximo 20 caracteres en Windows
    if ($Usuario.Length -gt 20) {
        msg_error "El nombre de usuario no puede superar 20 caracteres (límite SAM de Windows)"
        return $false
    }

    # Caracteres prohibidos en nombres de usuario Windows
    $prohibidos = '[\/\\\:\*\?\"\<\>\|\[\]]'
    if ($Usuario -match $prohibidos) {
        msg_error "El usuario contiene caracteres no permitidos en Windows"
        msg_info  "Evite usar: \ / : * ? `" < > | [ ]"
        return $false
    }

    # Advertencia si empieza con número (válido pero poco convencional)
    if ($Usuario -match '^\d') {
        msg_warn "El nombre '$Usuario' empieza con número. Es válido pero poco convencional"
    }

    return $true
}

# Verifica que un usuario local exista Y esté habilitado en Windows
# Usado antes de crear carpetas o asignar permisos FTP
# Uso: Test-FtpUsuarioExiste "ftpuser1"
function Test-FtpUsuarioExiste {
    param([string]$Usuario)

    if (-not (Test-FtpNombreUsuario $Usuario)) { return $false }

    try {
        $user = Get-LocalUser -Name $Usuario -ErrorAction Stop
        if ($user.Enabled) {
            return $true
        } else {
            msg_warn "El usuario '$Usuario' existe pero está DESHABILITADO"
            msg_info "Habilítelo con: Enable-LocalUser -Name '$Usuario'"
            return $false
        }
    } catch {
        msg_error "El usuario '$Usuario' no existe en este sistema"
        msg_info  "Usuarios locales activos disponibles:"
        Get-LocalUser | Where-Object { $_.Enabled } | ForEach-Object {
            Write-Host "    - $($_.Name)" -ForegroundColor DarkGray
        }
        return $false
    }
}


# 
# Validaciones de grupos FTP
# 

# Valida el nombre de un grupo FTP (nombre lógico, no grupo Windows)
# Se guarda en ftp_groups.txt y se usa para organizar carpetas compartidas
# Uso: Test-FtpNombreGrupo "ventas"
function Test-FtpNombreGrupo {
    param([string]$Grupo)

    if ([string]::IsNullOrWhiteSpace($Grupo)) {
        msg_error "El nombre del grupo no puede estar vacío"
        return $false
    }

    if ($Grupo.Length -gt 32) {
        msg_error "El nombre del grupo no puede superar 32 caracteres"
        return $false
    }

    # Solo letras, números, guion y guion bajo
    if ($Grupo -notmatch '^[a-zA-Z0-9_\-]+$') {
        msg_error "El nombre del grupo solo puede contener: letras, números, _ y -"
        msg_info  "Ejemplo válido: 'ventas', 'grupo_01', 'area-ti'"
        return $false
    }

    return $true
}

# Verifica que un grupo FTP ya esté registrado en memoria ($script:FTP_GROUPS)
# Requiere que Load-FtpGroups haya sido llamado antes (lo hace ftp.ps1)
# Uso: Test-FtpGrupoExiste "ventas"
function Test-FtpGrupoExiste {
    param([string]$Grupo)

    if (-not (Test-FtpNombreGrupo $Grupo)) { return $false }

    if ($script:FTP_GROUPS -contains $Grupo) {
        return $true
    }

    msg_error "El grupo '$Grupo' no está registrado"
    if ($script:FTP_GROUPS.Count -gt 0) {
        msg_info "Grupos disponibles: $($script:FTP_GROUPS -join ', ')"
    } else {
        msg_info "No hay grupos definidos aún. Créelos desde el menú de Grupos"
    }
    return $false
}


# 
# Validaciones del servicio y configuración FTP
# 

# Verifica que el sitio IIS/FTP esté creado y sea accesible
# Uso: Test-FtpSitioExiste
function Test-FtpSitioExiste {
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $sitePath = "IIS:\Sites\$script:FTP_SITE_NAME"
    if (-not (Test-Path $sitePath)) {
        msg_error "El sitio FTP '$script:FTP_SITE_NAME' no existe en IIS"
        msg_info  "Instale el servidor FTP primero desde la opción de instalación"
        return $false
    }
    return $true
}

# Valida el texto del banner FTP (aviso legal previo al login)
# Mínimo 10 caracteres, máximo 500
# Uso: Test-FtpBanner "Acceso restringido a personal autorizado"
function Test-FtpBanner {
    param([string]$Texto)

    if ([string]::IsNullOrWhiteSpace($Texto)) {
        msg_error "El texto del banner no puede estar vacío"
        msg_info  "El banner es el aviso legal que aparece al conectarse por FTP"
        return $false
    }

    if ($Texto.Length -lt 10) {
        msg_warn "El banner es muy corto ($($Texto.Length) caracteres)"
        msg_info "Un banner efectivo menciona: acceso restringido y consecuencias legales"
    }

    if ($Texto.Length -gt 500) {
        msg_error "El banner no puede superar 500 caracteres (actual: $($Texto.Length))"
        return $false
    }

    return $true
}

# Valida el número de líneas de log a mostrar en pantalla (10-500)
# Uso: Test-FtpLineasLog "50"
function Test-FtpLineasLog {
    param([string]$Lineas)

    if ($Lineas -notmatch '^\d+$') {
        msg_error "El número de líneas debe ser un entero positivo"
        return $false
    }

    $v = [int]$Lineas

    if ($v -lt 10) {
        msg_error "Mínimo 10 líneas de log"
        return $false
    }

    if ($v -gt 500) {
        msg_error "Máximo recomendado: 500 líneas (valor ingresado: $v)"
        msg_info  "Para análisis extenso use el Visor de Eventos de Windows"
        return $false
    }

    return $true
}