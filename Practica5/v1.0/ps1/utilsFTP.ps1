# 
# Colores y estilos de consola
# 
$script:COLOR_INFO    = "Cyan"
$script:COLOR_OK      = "Green"
$script:COLOR_WARN    = "Yellow"
$script:COLOR_ERROR   = "Red"
$script:COLOR_PROCESS = "Magenta"
$script:COLOR_INPUT   = "Cyan"
$script:COLOR_GRAY    = "DarkGray"
$script:COLOR_TITLE   = "White"


# 
# Mensajes de salida formateados
# Estas funciones son la base de toda la comunicación visual del menú.
# 

# Mensaje informativo general
function msg_info {
    param([string]$Mensaje)
    Write-Host "[INFO]    " -ForegroundColor $script:COLOR_INFO -NoNewline
    Write-Host $Mensaje
}

# Operación completada con éxito
function msg_success {
    param([string]$Mensaje)
    Write-Host "[SUCESS]      " -ForegroundColor $script:COLOR_OK -NoNewline
    Write-Host $Mensaje
}

# Advertencia (no es error, pero el usuario debe saber)
function msg_warn {
    param([string]$Mensaje)
    Write-Host "[WARNING]    " -ForegroundColor $script:COLOR_WARN -NoNewline
    Write-Host $Mensaje
}

# Error crítico
function msg_error {
    param([string]$Mensaje)
    Write-Host "[ERROR]   " -ForegroundColor $script:COLOR_ERROR -NoNewline
    Write-Host $Mensaje
}

# Proceso en curso (operaciones largas)
function msg_process {
    param([string]$Mensaje)
    Write-Host "[PROCESO] " -ForegroundColor $script:COLOR_PROCESS -NoNewline
    Write-Host $Mensaje
}

# Alerta leve (estado inesperado pero no grave)
function msg_alert {
    param([string]$Mensaje)
    Write-Host "[ALERTA]  " -ForegroundColor $script:COLOR_WARN -NoNewline
    Write-Host $Mensaje
}

# Entrada del usuario
function msg_input {
    param([string]$Prompt)
    Write-Host "[INPUT]   $Prompt`: " -ForegroundColor $script:COLOR_INPUT -NoNewline
}


# Línea separadora horizontal
function Write-Separator {
    Write-Host "────────────────────────────────────────────────" -ForegroundColor $script:COLOR_GRAY
}

# Encabezado con título centrado en caja
function Draw-Header {
    param([string]$Titulo)
    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │  $Titulo" -ForegroundColor Cyan -NoNewline
    $padding = 44 - $Titulo.Length
    Write-Host (" " * [Math]::Max($padding, 1) + "│") -ForegroundColor Cyan
    Write-Host "  └─────────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""
}

# Encabezado simple para submenús
function Draw-SubHeader {
    param([string]$Titulo)
    Write-Host ""
    Write-Separator
    Write-Host "  $Titulo" -ForegroundColor $script:COLOR_TITLE
    Write-Separator
}


# 
# Entrada de datos
# 

# Solicitar texto al usuario con prompt formateado
# Uso: $valor = Read-MenuInput "Nombre del sitio FTP"
function Read-MenuInput {
    param([string]$Prompt)
    msg_input $Prompt
    return Read-Host
}

# Solicitar contraseña (no se muestra en pantalla)
# Uso: $pass = Read-SecureMenuInput "Contrasena"
function Read-SecureMenuInput {
    param([string]$Prompt)
    msg_input $Prompt
    return Read-Host -AsSecureString
}

# Confirmar una acción destructiva o irreversible
function Confirm-MenuAction {
    param([string]$Prompt)
    $r = Read-MenuInput "$Prompt [s/N]"
    return ($r -match '^[Ss]$')
}

# Pausa: espera a que el usuario presione Enter antes de continuar
function Pause-Menu {
    Write-Host ""
    Read-Host "  Presiona Enter para continuar"
}


# 
# Verificaciones de entorno
# Se deben llamar al inicio del script principal.
# 

function Test-AdminPrivileges {
    $identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal  = New-Object Security.Principal.WindowsPrincipal($identidad)
    $esAdmin    = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $esAdmin) {
        msg_error "Este script requiere permisos de Administrador"
        msg_info  "Abra PowerShell con 'Ejecutar como administrador' e intente de nuevo"
        return $false
    }

    msg_warn "Ejecutando como Administrador — proceda con cuidado"
    return $true
}

# Comprueba si un servicio Windows está activo
# Uso: Test-ServiceRunning "FTPSVC"
function Test-ServiceRunning {
    param([string]$NombreServicio)
    try {
        $svc = Get-Service -Name $NombreServicio -ErrorAction Stop
        return ($svc.Status -eq 'Running')
    } catch {
        return $false
    }
}

# Comprueba si un servicio está configurado para arranque automático
# Uso: Test-ServiceAutoStart "FTPSVC"
function Test-ServiceAutoStart {
    param([string]$NombreServicio)
    try {
        $svc = Get-Service -Name $NombreServicio -ErrorAction Stop
        return ($svc.StartType -eq 'Automatic')
    } catch {
        return $false
    }
}

# Verifica si un puerto TCP está en escucha en este equipo
# Uso: Test-PuertoEscuchando 21
function Test-PuertoEscuchando {
    param([int]$Puerto)
    $conexiones = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $conexiones)
}

# Verifica conectividad básica (ping) hacia otro nodo
function Test-Conectividad {
    param([string]$Host)
    return (Test-Connection -ComputerName $Host -Count 1 -Quiet -ErrorAction SilentlyContinue)
}


# 
# Resumen de estado del servidor FTP
# Se muestra en el encabezado del menú principal para dar contexto rápido.
# 
function Show-FtpStatusBar {
    $ftpRunning  = Test-ServiceRunning "FTPSVC"
    $iisRunning  = Test-ServiceRunning "W3SVC"
    $port21      = Test-PuertoEscuchando 21

    $svcColor  = if ($ftpRunning)  { "Green"  } else { "Red"    }
    $iisColor  = if ($iisRunning)  { "Green"  } else { "Yellow" }
    $portColor = if ($port21)      { "Green"  } else { "Red"    }

    Write-Host ""
    Write-Host "  Estado rápido:" -ForegroundColor $script:COLOR_GRAY
    Write-Host "    FTPSVC : " -NoNewline
    Write-Host (if ($ftpRunning) { "Activo  " } else { "Inactivo" }) -ForegroundColor $svcColor
    Write-Host "    IIS    : " -NoNewline
    Write-Host (if ($iisRunning) { "Activo  " } else { "Inactivo" }) -ForegroundColor $iisColor
    Write-Host "    Puerto 21: " -NoNewline
    Write-Host (if ($port21) { "Escuchando" } else { "Cerrado   " }) -ForegroundColor $portColor
    Write-Host ""
}