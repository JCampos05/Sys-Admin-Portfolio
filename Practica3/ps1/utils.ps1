#
# utils.ps1
# Funciones de utilidad comunes para todos los módulos DNS en PowerShell
#

# Definición de colores para la consola
$script:Colors = @{
    Red     = 'Red'
    Green   = 'Green'
    Yellow  = 'Yellow'
    Blue    = 'Cyan'
    Cyan    = 'Cyan'
    Gray    = 'DarkGray'
    Reset   = 'White'
}

function Write-InfoMessage {
    param([string]$Message)
    Write-Host "[INFO] " -ForegroundColor $Colors.Blue -NoNewline
    Write-Host $Message
}


function Write-SuccessMessage {
    param([string]$Message)
    Write-Host "[SUCCESS] " -ForegroundColor $Colors.Green -NoNewline
    Write-Host $Message
}

function Write-WarningCustom {
    param([string]$Message)
    Write-Host "[WARNING] " -ForegroundColor $Colors.Yellow -NoNewline
    Write-Host $Message
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "[ERROR] " -ForegroundColor $Colors.Red -NoNewline
    Write-Host $Message
}

function Read-InputPrompt {
    param([string]$Prompt)
    Write-Host "[INPUT] " -ForegroundColor $Colors.Cyan -NoNewline
    Write-Host "$Prompt`: " -NoNewline
    return Read-Host
}

function Invoke-Pause {
    Write-Host ""
    Write-Host "Presiona Enter para continuar..." -NoNewline
    $null = Read-Host
}

function Write-SeparatorLine {
    Write-Host ("─" * 80)
}

function Write-Header {
    param([string]$Title)
    Write-SeparatorLine
    Write-Host "  $Title"
    Write-SeparatorLine
}

function Test-AdminPrivileges {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Write-ErrorMessage "Se requieren privilegios de administrador para ejecutar esta operación"
        Write-Host ""
        Write-InfoMessage "Ejecute PowerShell como Administrador"
        return $false
    }
    
    return $true
}

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

function Test-IPv4Address {
    param([string]$IPAddress)
    
    $ipRegex = '^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
    
    if ($IPAddress -match $ipRegex) {
        return $true
    }
    return $false
}

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

function New-DNSZoneSerial {
    $date = Get-Date -Format "yyyyMMdd"
    return "${date}01"
}

function Test-Port53InUse {
    try {
        $tcpConnections = Get-NetTCPConnection -LocalPort 53 -ErrorAction SilentlyContinue
        $udpConnections = Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue
        
        if ($tcpConnections -or $udpConnections) {
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

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

function Test-WindowsFirewallActive {
    try {
        $profiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
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

#
# EXPORTAR FUNCIONES
#

# Exportar todas las funciones para que estén disponibles en otros scripts
Export-ModuleMember -Function *