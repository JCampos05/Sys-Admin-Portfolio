#
#   utils.ps1
#   Funciones de utilidad comunes para todos los modulos en PowerShell
#

# ============================================================================
# DEFINICION DE COLORES DE CONSOLA
# ============================================================================

$script:Colors = @{
    Red    = 'Red'
    Green  = 'Green'
    Yellow = 'Yellow'
    Blue   = 'Cyan'
    Cyan   = 'Cyan'
    Gray   = 'DarkGray'
    Reset  = 'White'
}

# ============================================================================
# FUNCIONES DE SALIDA FORMATEADA
# ============================================================================

<#
.SYNOPSIS
    Muestra un mensaje informativo en color azul
.PARAMETER Message
    El mensaje a mostrar
#>
function Write-InfoMessage {
    param([string]$Message)
    Write-Host "[INFO] " -ForegroundColor $script:Colors.Blue -NoNewline
    Write-Host $Message
}

<#
.SYNOPSIS
    Muestra un mensaje de exito en color verde
.PARAMETER Message
    El mensaje a mostrar
#>
function Write-SuccessMessage {
    param([string]$Message)
    Write-Host "[SUCCESS] " -ForegroundColor $script:Colors.Green -NoNewline
    Write-Host $Message
}

<#
.SYNOPSIS
    Muestra un mensaje de advertencia en color amarillo
.PARAMETER Message
    El mensaje a mostrar
#>
function Write-WarningCustom {
    param([string]$Message)
    Write-Host "[WARNING] " -ForegroundColor $script:Colors.Yellow -NoNewline
    Write-Host $Message
}

<#
.SYNOPSIS
    Muestra un mensaje de error en color rojo
.PARAMETER Message
    El mensaje a mostrar
#>
function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "[ERROR] " -ForegroundColor $script:Colors.Red -NoNewline
    Write-Host $Message
}

<#
.SYNOPSIS
    Solicita entrada del usuario con un prompt personalizado
.PARAMETER Prompt
    El texto del prompt a mostrar
.OUTPUTS
    String - La entrada del usuario
#>
function Read-InputPrompt {
    param([string]$Prompt)
    Write-Host "[INPUT] " -ForegroundColor $script:Colors.Cyan -NoNewline
    Write-Host "$Prompt`: " -NoNewline
    return Read-Host
}

# ============================================================================
# FUNCIONES DE CONTROL DE FLUJO
# ============================================================================

<#
.SYNOPSIS
    Pausa la ejecucion y espera que el usuario presione Enter
#>
function Invoke-Pause {
    Write-Host ""
    Write-Host "Presiona Enter para continuar..." -NoNewline
    $null = Read-Host
}

<#
.SYNOPSIS
    Dibuja una linea separadora en la consola
#>
function Write-SeparatorLine {
    Write-Host ("-" * 42)
}

<#
.SYNOPSIS
    Dibuja una cabecera con titulo
.PARAMETER Title
    El titulo a mostrar en la cabecera
#>
function Write-Header {
    param([string]$Title)
    Write-SeparatorLine
    Write-Host "  $Title"
    Write-SeparatorLine
}

# ============================================================================
# FUNCIONES DE VERIFICACION DE PRIVILEGIOS
# ============================================================================

<#
.SYNOPSIS
    Verifica si el script se esta ejecutando con privilegios de administrador
.OUTPUTS
    Boolean - True si tiene privilegios, False si no
#>
function Test-AdminPrivileges {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
    $isAdmin     = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-ErrorMessage "Se requieren privilegios de administrador para ejecutar esta operacion"
        Write-Host ""
        Write-InfoMessage "Ejecute PowerShell como Administrador"
        return $false
    }

    return $true
}

# ============================================================================
# FUNCIONES DE VERIFICACION DE SERVICIOS Y ROLES
# ============================================================================

<#
.SYNOPSIS
    Verifica si una caracteristica o rol de Windows esta instalado
.PARAMETER FeatureName
    Nombre de la caracteristica o rol a verificar
.OUTPUTS
    Boolean - True si esta instalado, False si no
#>
function Test-WindowsFeatureInstalled {
    param([string]$FeatureName)

    try {
        $feature = Get-WindowsFeature -Name $FeatureName -ErrorAction SilentlyContinue
        if ($feature -and $feature.Installed) {
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Verifica si un servicio esta en ejecucion
.PARAMETER ServiceName
    Nombre del servicio a verificar
.OUTPUTS
    Boolean - True si esta activo, False si no
#>
function Test-ServiceActive {
    param([string]$ServiceName)

    try {
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Running') {
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Verifica si un servicio esta configurado para inicio automatico
.PARAMETER ServiceName
    Nombre del servicio a verificar
.OUTPUTS
    Boolean - True si esta habilitado, False si no
#>
function Test-ServiceEnabled {
    param([string]$ServiceName)

    try {
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($service -and $service.StartType -eq 'Automatic') {
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

# ============================================================================
# FUNCIONES DE VALIDACION DE RED
# ============================================================================

<#
.SYNOPSIS
    Valida el formato de una direccion IPv4
.PARAMETER IPAddress
    La direccion IP a validar
.OUTPUTS
    Boolean - True si es valida, False si no
#>
function Test-IPv4Address {
    param([string]$IPAddress)

    $ipRegex = '^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'

    if ($IPAddress -match $ipRegex) {
        return $true
    }
    return $false
}

<#
.SYNOPSIS
    Obtiene la direccion IP de una interfaz de red
.PARAMETER InterfaceAlias
    Alias o nombre de la interfaz de red
.OUTPUTS
    String - La direccion IP o "Sin IP" si no tiene
#>
function Get-InterfaceIPAddress {
    param([string]$InterfaceAlias)

    try {
        $adapter = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Where-Object { $_.PrefixOrigin -ne "WellKnown" } |
                   Select-Object -First 1

        if ($adapter) {
            return $adapter.IPAddress
        }
        return "Sin IP"
    }
    catch {
        return "Sin IP"
    }
}

<#
.SYNOPSIS
    Obtiene todas las interfaces de red activas excepto loopback
.OUTPUTS
    Array - Lista de nombres de interfaces de red
#>
function Get-NetworkInterfaces {
    try {
        $interfaces = Get-NetAdapter |
                     Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notlike '*Loopback*' } |
                     Select-Object -ExpandProperty Name

        return $interfaces
    }
    catch {
        return @()
    }
}

<#
.SYNOPSIS
    Verifica la conectividad a un host
.PARAMETER HostAddress
    Direccion del host a verificar (por defecto 8.8.8.8)
.OUTPUTS
    Boolean - True si hay conectividad, False si no
#>
function Test-NetworkConnectivity {
    param([string]$HostAddress = "8.8.8.8")

    try {
        $ping = Test-Connection -ComputerName $HostAddress -Count 1 -Quiet -ErrorAction SilentlyContinue
        return $ping
    }
    catch {
        return $false
    }
}

# ============================================================================
# FUNCIONES AUXILIARES PARA DNS
# ============================================================================

<#
.SYNOPSIS
    Genera un numero serial para zona DNS en formato YYYYMMDDnn
.OUTPUTS
    String - Serial en formato YYYYMMDDnn
#>
function New-DNSZoneSerial {
    $date = Get-Date -Format "yyyyMMdd"
    return "${date}01"
}

<#
.SYNOPSIS
    Verifica si el puerto 53 esta en uso
.OUTPUTS
    Boolean - True si el puerto esta en uso, False si esta libre
#>
function Test-Port53InUse {
    try {
        $tcpConnections = Get-NetTCPConnection -LocalPort 53 -ErrorAction SilentlyContinue
        $udpConnections = Get-NetUDPEndpoint   -LocalPort 53 -ErrorAction SilentlyContinue

        if ($tcpConnections -or $udpConnections) {
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Obtiene el proceso que esta usando el puerto 53
.OUTPUTS
    String - Nombre del proceso o "Ninguno" si el puerto esta libre
#>
function Get-Port53Process {
    try {
        $tcpConnection = Get-NetTCPConnection -LocalPort 53 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($tcpConnection) {
            $process = Get-Process -Id $tcpConnection.OwningProcess -ErrorAction SilentlyContinue
            if ($process) {
                return $process.ProcessName
            }
        }
        return "Ninguno"
    }
    catch {
        return "Ninguno"
    }
}

# ============================================================================
# FUNCIONES DE FIREWALL DE WINDOWS
# ============================================================================

<#
.SYNOPSIS
    Verifica si el Firewall de Windows esta activo
.OUTPUTS
    Boolean - True si esta activo, False si no
#>
function Test-WindowsFirewallActive {
    try {
        $profiles   = Get-NetFirewallProfile -ErrorAction SilentlyContinue
        $anyEnabled = $profiles | Where-Object { $_.Enabled -eq $true }

        if ($anyEnabled) {
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Verifica si existe una regla de firewall para DNS habilitada
.OUTPUTS
    Boolean - True si existe la regla, False si no
#>
function Test-DNSFirewallRule {
    try {
        $rule = Get-NetFirewallRule -DisplayName "*DNS*" -ErrorAction SilentlyContinue |
                Where-Object { $_.Enabled -eq $true } |
                Select-Object -First 1

        if ($rule) {
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

# ============================================================================
# FUNCIONES DE VERIFICACION DE DEPENDENCIAS
# ============================================================================

<#
.SYNOPSIS
    Verifica que un comando o cmdlet externo este disponible en el sistema
.DESCRIPTION
    Util para comprobar herramientas externas antes de usarlas.
    Muestra un mensaje de error con instrucciones de instalacion si no se encuentra.
.PARAMETER Comando
    Nombre del comando o ejecutable a verificar
.PARAMETER Instruccion
    Texto opcional con instrucciones para instalar la dependencia
.OUTPUTS
    Boolean - True si el comando esta disponible, False si no
#>
function Test-Dependency {
    param(
        [string]$Comando,
        [string]$Instruccion = ""
    )

    if (-not (Get-Command $Comando -ErrorAction SilentlyContinue)) {
        Write-ErrorMessage "Dependencia no encontrada: $Comando"
        if (-not [string]::IsNullOrWhiteSpace($Instruccion)) {
            Write-InfoMessage "Para instalarla ejecute: $Instruccion"
        }
        return $false
    }

    return $true
}

# ============================================================================
# EXPORTAR FUNCIONES
# ============================================================================
# Con dot-sourcing todas las funciones quedan disponibles automaticamente
# No se requiere Export-ModuleMember (solo se usa en modulos .psm1)