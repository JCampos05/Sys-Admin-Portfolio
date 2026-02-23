#
# Punto unico de entrada. Carga modulos con Import-Module y llama a sus funciones.
#

#   DIRECTORIO BASE
#   $PSScriptRoot es la carpeta donde está main.ps1
$scriptDir = $PSScriptRoot

#   Carga de modulos (Import-Module)
. "$scriptDir\utils.ps1"
. "$scriptDir\validator_ssh.ps1"

. "$scriptDir\1.verificar_ssh.ps1"
. "$scriptDir\2.instalar_configurar.ps1"
. "$scriptDir\3.hardening.ps1"
. "$scriptDir\4.claves.ps1"
. "$scriptDir\5.monitor_ssh.ps1"
. "$scriptDir\6.firewall.ps1"

#   Verificacion de privilegios -> admin

if (-not (Test-AdminPrivileges)) {
    Write-Host ""
    Write-Host "[ERROR] Este script requiere permisos de Administrador." -ForegroundColor Red
    Write-Host "        Abra PowerShell con 'Ejecutar como administrador' e intente de nuevo." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Presione Enter para salir"
    exit 1
}

function Show-MainMenu {
    $salir = $false

    while (-not $salir) {
        Clear-Host
        Write-Host ""
        Write-Host "[INFO] +-----------------------------------------+" -ForegroundColor Cyan
        Write-Host "[INFO] |---|   Gestor del Servicio SSH       |---|" -ForegroundColor Cyan
        Write-Host "[INFO] +-----------------------------------------+" -ForegroundColor Cyan
        Write-Host ""
        Write-Info "Seleccione una opcion:"
        Write-Host ""
        Write-Info "  1) Verificar instalacion SSH"
        Write-Info "  2) Instalar y configurar SSH"
        Write-Info "  3) Hardening (seguridad)"
        Write-Info "  4) Gestion de claves"
        Write-Info "  5) Monitor SSH"
        Write-Info "  6) Firewall"
        Write-Info "  7) Salir"
        Write-Host ""

        $op = Read-Input "Opcion"

        switch ($op) {
            "1" {
                Invoke-VerificarSSH
                Pause-Menu
            }
            "2" {
                Invoke-InstalarConfigurarSSH
                Pause-Menu
            }
            "3" {
                Invoke-HardeningSSH
                Pause-Menu
            }
            "4" {
                Invoke-GestionarClavesSSH
            }
            "5" {
                Invoke-MonitorSSH
                Pause-Menu
            }
            "6" {
                Invoke-GestionarFirewallSSH
            }
            "7" {
                Clear-Host
                Write-Host ""
                Write-Info "Saliendo del Gestor SSH..."
                Write-Host ""
                $salir = $true
            }
            default {
                Write-Err "Opcion invalida. Seleccione una opcion del 1 al 7"
                Start-Sleep -Seconds 2
            }
        }
    }
}

Show-MainMenu