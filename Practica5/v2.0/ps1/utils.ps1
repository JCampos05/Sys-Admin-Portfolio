#
# Funciones de utilidad comunes para todos los módulos SSH en Windows
#

# Mensaje informativo (azul)
function Write-Info {
    param([string]$Mensaje)
    Write-Host "[INFO] " -ForegroundColor Cyan -NoNewline
    Write-Host $Mensaje
}

# Mensaje de éxito (verde)
function Write-Success {
    param([string]$Mensaje)
    Write-Host "[SUCCESS]   " -ForegroundColor Green -NoNewline
    Write-Host $Mensaje
}

# Mensaje de advertencia (amarillo)
function Write-Warn {
    param([string]$Mensaje)
    Write-Host "[WARN] " -ForegroundColor Yellow -NoNewline
    Write-Host $Mensaje
}

# Mensaje de error (rojo)
function Write-Err {
    param([string]$Mensaje)
    Write-Host "[ERROR]" -ForegroundColor Red -NoNewline
    Write-Host " $Mensaje"
}

# Solicitar input formateado
# Uso: $valor = Read-Input "Ingrese el usuario"
function Read-Input {
    param([string]$Prompt)
    Write-Host "[INPUT] $Prompt`: " -ForegroundColor Cyan -NoNewline
    return Read-Host
}


function Draw-Line {
    Write-Host "────────────────────────────────────────"
}

# Cabecera con título
# Uso: Draw-Header "Monitor SSH"
function Draw-Header {
    param([string]$Titulo)
    Write-Host ""
    Draw-Line
    Write-Host "  $Titulo"
    Draw-Line
}

# Pausa hasta que el usuario presione Enter
function Pause-Menu {
    Write-Host ""
    Read-Host "  Presiona Enter para continuar"
}

# Verifica que el script se ejecute como Administrador
# En Windows, muchas operaciones de sistema requieren este nivel
function Test-AdminPrivileges {
    $identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identidad)
    $esAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $esAdmin) {
        Write-Err "Este script requiere permisos de Administrador"
        Write-Info "Abra PowerShell con 'Ejecutar como administrador' e intente de nuevo"
        return $false
    }

    Write-Warn "Ejecutando como Administrador"
    return $true
}

# Verifica si un servicio de Windows está en ejecución
# Uso: Test-ServiceRunning "sshd"
function Test-ServiceRunning {
    param([string]$NombreServicio)
    try {
        $svc = Get-Service -Name $NombreServicio -ErrorAction Stop
        return ($svc.Status -eq 'Running')
    } catch {
        return $false
    }
}

# Verifica si un servicio está configurado para inicio automático
# Uso: Test-ServiceAutoStart "sshd"
function Test-ServiceAutoStart {
    param([string]$NombreServicio)
    try {
        $svc = Get-Service -Name $NombreServicio -ErrorAction Stop
        return ($svc.StartType -eq 'Automatic')
    } catch {
        return $false
    }
}

# Verifica conectividad con ping a un host
# Uso: Test-Conectividad "192.168.100.30"
function Test-Conectividad {
    param([string]$Host)
    return (Test-Connection -ComputerName $Host -Count 1 -Quiet -ErrorAction SilentlyContinue)
}

# Verifica si un puerto TCP está en escucha en este equipo
# Uso: Test-PuertoEscuchando 22
function Test-PuertoEscuchando {
    param([int]$Puerto)
    $conexiones = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $conexiones)
}
