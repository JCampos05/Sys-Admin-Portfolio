#
# mainHTTP.ps1
# Script principal — Gestor de Servicios HTTP en Windows Server 2022
#
# Equivalente exacto de mainHTTP.sh de la practica Linux.
# Punto unico de entrada del sistema.
# Este archivo NO contiene logica — solo carga modulos y llama funciones.
#
# Estructura del proyecto:
#   mainHTTP.ps1           <- este archivo (solo dot-source + llamadas)
#   utils.ps1              <- utilidades base (colores, aputs_*, draw_*, pause, agets)
#   utilsHTTP.ps1          <- constantes globales y helpers HTTP
#   validatorsHTTP.ps1     <- validaciones de entrada para servicios HTTP
#   FunctionsHTTP-A.ps1    <- Grupo A: Verificacion de estado
#   FunctionsHTTP-B.ps1    <- Grupo B: Instalacion de servicios
#   FunctionsHTTP-C.ps1    <- Grupo C: Configuracion y seguridad
#   FunctionsHTTP-D.ps1    <- Grupo D: Gestion de versiones
#   FunctionsHTTP-E.ps1    <- Grupo E: Monitoreo
#

#Requires -Version 5.1
#Requires -RunAsAdministrator

# Resolver la ruta absoluta del directorio donde vive este script,
# sin importar desde donde se ejecute.
# Equivalente a SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ── Capa 1: Base ──────────────────────────────────────────────────────────────
# Utilidades comunes: colores ANSI, aputs_*, draw_*, pause_menu, agets,
# check_privileges, check_service_active, check_service_enabled, etc.
. "$SCRIPT_DIR\utils.ps1"

# ── Capa 2: HTTP ──────────────────────────────────────────────────────────────
# Constantes globales (rutas, usuarios, nombres de servicio, puertos) y
# helpers especificos de HTTP (backup, reload, verificar respuesta, etc.)
. "$SCRIPT_DIR\utilsHTTP.ps1"

# ── Capa 3: Validacion ────────────────────────────────────────────────────────
# Funciones http_validar_* — cargadas antes de cualquier logica de negocio
. "$SCRIPT_DIR\validatorsHTTP.ps1"

# ── Capa 4: Logica por grupos ─────────────────────────────────────────────────
# Grupo A — Verificacion de estado (solo lectura, base de los demas grupos)
. "$SCRIPT_DIR\FunctionsHTTP-A.ps1"

# Grupo B — Instalacion de servicios (flujo encadenado completo)
. "$SCRIPT_DIR\FunctionsHTTP-B.ps1"

# Grupo C — Configuracion y seguridad (cambio de puerto, headers, metodos HTTP)
. "$SCRIPT_DIR\FunctionsHTTP-C.ps1"

# Grupo D — Gestion de versiones (upgrade, downgrade, consulta de version activa)
. "$SCRIPT_DIR\FunctionsHTTP-D.ps1"

# Grupo E — Monitoreo (estado, puertos, logs, headers en vivo con curl.exe -I)
. "$SCRIPT_DIR\FunctionsHTTP-E.ps1"

# 
#   MENU PRINCIPAL
#   Solo contiene la estructura visual del menu y llamadas a http_menu_*
#   Toda la logica real reside en los grupos A-E de FunctionsHTTP-*.ps1
#   Equivalente a main_menu() de mainHTTP.sh
# 

function main_menu {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "${CYAN}╔══════════════════════════════════════════════╗${NC}"
        Write-Host "${CYAN}║${NC}   Gestor de Servicios HTTP — Windows Server  ${CYAN}║${NC}"
        Write-Host "${CYAN}║${NC}   192.168.100.20                              ${CYAN}║${NC}"
        Write-Host "${CYAN}╚══════════════════════════════════════════════╝${NC}"
        Write-Host ""
        aputs_info "Seleccione una opcion:"
        Write-Host ""
        Write-Host "  ${BLUE}1)${NC} Verificar estado de servicios HTTP"
        Write-Host "  ${BLUE}2)${NC} Instalar servicio HTTP"
        Write-Host "  ${BLUE}3)${NC} Configurar servicio"
        Write-Host "  ${BLUE}4)${NC} Monitoreo"
        Write-Host "  ${BLUE}5)${NC} Salir"
        Write-Host ""

        $op = Read-Host "  Opcion"

        if (-not (http_validar_opcion_menu $op 5)) {
            Start-Sleep -Seconds 2
            continue
        }

        switch ($op) {
            "1" {
                # Grupo A — Panel general, puerto disponible, usuario del servicio
                http_menu_verificar
            }
            "2" {
                # Grupo B — Flujo encadenado: servicio -> version -> puerto -> instalacion
                http_menu_instalar
            }
            "3" {
                # Grupos C + D — Cambio de puerto, seguridad, metodos HTTP, versiones
                http_menu_configurar
            }
            "4" {
                # Grupo E — Estado, puertos, logs, headers HTTP en vivo (curl.exe -I)
                http_menu_monitoreo
            }
            "5" {
                Clear-Host
                Write-Host ""
                aputs_info "Saliendo del Gestor HTTP..."
                Write-Host ""
                exit 0
            }
        }

        Write-Host ""
        pause_menu
    }
}

# 
#  Punto de entrada
# 

# 1. Privilegios de Administrador
#    Requerido para: choco, Get-Service, New-NetFirewallRule,
#    Install-WindowsFeature, secedit, etc.
#    #Requires -RunAsAdministrator ya genera error automatico si no se cumple,
#    pero agregamos verificacion explicita para mensaje claro al usuario.
if (-not (check_privileges)) {
    Write-Host ""
    aputs_error "Este script requiere permisos de Administrador."
    aputs_info  "Haga clic derecho en PowerShell y seleccione 'Ejecutar como administrador'."
    aputs_info  "O use: Start-Process powershell -Verb RunAs"
    Write-Host ""
    exit 1
}

# 2. Dependencias criticas del sistema
#    Si falta choco, curl.exe, netsh o sc.exe el gestor no puede operar.
#    Equivalente a http_verificar_dependencias en mainHTTP.sh
if (-not (http_verificar_dependencias)) {
    Write-Host ""
    aputs_error "Dependencias faltantes. Resuelva los errores antes de continuar."
    aputs_info  "Chocolatey se instala automaticamente — verifique conectividad a Internet"
    Write-Host ""
    pause_menu
    exit 1
}

Write-Host ""
pause_menu

http_detectar_rutas_reales

# 3. Iniciar el menu principal
main_menu