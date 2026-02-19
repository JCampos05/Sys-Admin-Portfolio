#
# main.ps1
# Script principal - Gestor de Servicio DNS para Windows Server
#

# Obtener directorio del script
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Cargar módulo de utilidades
. (Join-Path $ScriptDir "utils.ps1")
. (Join-Path $ScriptDir 'validators_dns.ps1')

# Cargar módulos funcionales
. (Join-Path $ScriptDir "1.verificar_instalacion.ps1")
. (Join-Path $ScriptDir "2.instalarConfigServicio.ps1")
. (Join-Path $ScriptDir "3.ver_config.ps1")
. (Join-Path $ScriptDir "4.reiniciar_servicio.ps1")
. (Join-Path $ScriptDir "5.monitor_dns.ps1")
. (Join-Path $ScriptDir "6.crud_dominios.ps1")

#
# VARIABLES GLOBALES
#

$script:InterfacesRed = @()
$script:InterfazSeleccionada = ""

#
# FUNCIÓN DE DETECCIÓN DE INTERFACES DE RED
#

<#
.SYNOPSIS
    Detecta y permite seleccionar la interfaz de red a utilizar
.DESCRIPTION
    Muestra todas las interfaces de red disponibles y permite al usuario
    seleccionar cuál será utilizada para el servicio DNS
#>
function Select-NetworkInterface {
    # Obtener interfaces de red activas (excluyendo loopback)
    $script:InterfacesRed = Get-NetAdapter | 
                           Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notlike '*Loopback*' } |
                           Select-Object Name, InterfaceDescription, Status
    
    if ($script:InterfacesRed.Count -eq 0) {
        Write-Host ""
        Write-WarningCustom "No se detectaron interfaces de red"
        exit 1
    }
    
    Write-Host ""
    Write-InfoMessage "Interfaces de red detectadas:"
    
    $contador = 1
    foreach ($iface in $script:InterfacesRed) {
        $currentIP = Get-InterfaceIPAddress -InterfaceAlias $iface.Name
        Write-Host ""
        Write-Host "  $contador) $($iface.Name) (IP actual: $currentIP)"
        $contador++
    }
    Write-Host ""
    
    # Solicitar selección
    while ($true) {
        $selection = Read-Host "Seleccione el número de la interfaz [1-$($script:InterfacesRed.Count)]"
        
        if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $script:InterfacesRed.Count) {
            $script:InterfazSeleccionada = $script:InterfacesRed[[int]$selection - 1].Name
            break
        }
        else {
            Write-ErrorMessage "Selección inválida. Ingrese un número entre 1 y $($script:InterfacesRed.Count)"
        }
    }
    
    Write-Host ""
    Write-SuccessMessage "Interfaz de red seleccionada: $script:InterfazSeleccionada"
}
#
# menu principal
#
function Show-MainMenu {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-InfoMessage "┌────────────────────────────────┐"
        Write-InfoMessage "|---| Gestor de Servicio DNS |---|"
        Write-InfoMessage "└────────────────────────────────┘"
        Write-Host ""
        Write-InfoMessage "Seleccione una opción:"
        Write-Host ""
        Write-InfoMessage "1) Verificar instalación"
        Write-InfoMessage "2) Instalar/config servicio DNS"
        Write-InfoMessage "3) Ver configuración actual"
        Write-InfoMessage "4) Reiniciar servicio"
        Write-InfoMessage "5) Monitor DNS"
        Write-InfoMessage "6) ABC Dominios"
        Write-InfoMessage "7) Salir"
        Write-Host ""
        
        $opcion = Read-Host "Opción"
        
        switch ($opcion) {
            "1" {
                Invoke-VerificarInstalacion
            }
            "2" {
                Invoke-InstalarConfigServicio
            }
            "3" {
                Invoke-VerConfigActual
            }
            "4" {
                Invoke-ReiniciarServicio
            }
            "5" {
                Invoke-MonitorDNS
            }
            "6" {
                Invoke-CrudDominios
            }
            "7" {
                Clear-Host
                Write-Host ""
                Write-InfoMessage "Saliendo del Gestor de Servicio DNS..."
                Write-Host ""
                exit 0
            }
            default {
                Write-Host ""
                Write-ErrorMessage "Opción inválida. Por favor seleccione una opción del 1 al 7"
                Start-Sleep -Seconds 2
                continue
            }
        }
        
        Write-Host ""
        Invoke-Pause
    }
}

#
# Punto de entrada
#

# Verificar privilegios de administrador
if (-not (Test-AdminPrivileges)) {
    Write-Host ""
    Invoke-Pause
    exit 1
}

# Mostrar mensaje de bienvenida
Clear-Host
Write-Host ""
Write-Host "─────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  GESTOR DE SERVICIO DNS - WINDOWS SERVER" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host ""
Write-InfoMessage "Sistema operativo: $([System.Environment]::OSVersion.VersionString)"
Write-InfoMessage "PowerShell versión: $($PSVersionTable.PSVersion)"
Write-Host ""
Write-SeparatorLine
Write-Host ""

# Iniciar menú principal
Show-MainMenu