#
# mainFTP.ps1
# Punto de entrada — Gestor de Servidor FTP en Windows Server 2022
#
# Carga en orden:
#   utilsFTP.ps1        <- msg_*, Write-Separator, Draw-Header, Pause-Menu, etc.
#   validatorsFTP.ps1   <- validaciones de red, usuario, grupo, etc.
#   subMainFTP.ps1      <- variables globales + Read-Input, Confirm-Action
#                          (subMainFTP carga FunctionsFTP-A/B/C/D internamente)
#
# Todos los archivos deben estar en el mismo directorio que mainFTP.ps1
#

$_MAIN_DIR = $PSScriptRoot

. "$_MAIN_DIR\utilsFTP.ps1"
. "$_MAIN_DIR\validatorsFTP.ps1"
. "$_MAIN_DIR\subMainFTP.ps1"

if (-not (Test-AdminPrivileges)) {
    exit 1
}

function Menu-Principal {
    $salir = $false

    while (-not $salir) {
        Clear-Host

        Write-Host ""
        Write-Host "  ┌─────────────────────────────────────────────┐" -ForegroundColor Cyan
        Write-Host "  │───│   Servidor FTP — Windows Server 2022  │───│" -ForegroundColor Cyan
        Write-Host "  └─────────────────────────────────────────────┘" -ForegroundColor Cyan

        Write-Separator
        msg_info "Seleccione una opcion:"
        Write-Host ""
        msg_info "  1) Instalacion del servidor FTP"
        msg_info "  2) Gestion de usuarios FTP"
        msg_info "  3) Gestion de grupos FTP"
        msg_info "  4) Directorios y permisos"
        msg_info "  5) Configuracion del sitio"
        msg_info "  6) Control del servicio"
        msg_info "  7) Salir"
        Write-Host ""

        $op = Read-MenuInput "Opcion"
        switch ($op) {
            "1" { Menu-Instalacion   }
            "2" { Menu-Usuarios      }
            "3" { Menu-Grupos        }
            "4" { Menu-Directorios   }
            "5" { Menu-Configuracion }
            "6" { Menu-Servicio      }
            "7" {
                Clear-Host
                Write-Host ""
                msg_info "Saliendo del administrador FTP..."
                Write-Host ""
                $salir = $true
            }
            default {
                msg_error "Opcion invalida. Seleccione del 1 al 7"
                Start-Sleep -Seconds 2
            }
        }
    }
}

Menu-Principal