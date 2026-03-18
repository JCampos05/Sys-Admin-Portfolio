#!/bin/bash
#
# mainFTP.sh — Gestor de Servidor FTP (vsftpd) — Fedora Server
#
# Punto único de entrada. Este archivo NO contiene lógica —
# solo carga módulos y llama funciones.
#
# Estructura del proyecto:
#   mainFTP.sh          <- este archivo (source + main_menu)
#   utils.sh            <- utilidades base (colores, aputs_*, draw_*, pause)
#   utilsFTP.sh         <- constantes globales y helpers FTP
#   validatorsFTP.sh    <- validaciones, metadatos de usuarios, helpers de entrada
#   FunctionsFTP-A.sh   <- Grupo A: Monitoreo general
#   FunctionsFTP-B.sh   <- Grupo B: Instalación y control del servicio
#   FunctionsFTP-C.sh   <- Grupo C: Gestión de usuarios y grupos
#   FunctionsFTP-D.sh   <- Grupo D: Configuración y mantenimiento
#
# Uso:
#   sudo bash /home/adminuser/scripts/Practica5/mainFTP.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Capa 1: Base ──────────────────────────────────────────────────────────────
source "${SCRIPT_DIR}/utils.sh"

# ── Capa 2: FTP ───────────────────────────────────────────────────────────────
source "${SCRIPT_DIR}/utilsFTP.sh"

# ── Capa 3: Validación ────────────────────────────────────────────────────────
source "${SCRIPT_DIR}/validatorsFTP.sh"

# ── Capa 4: Lógica por grupos ─────────────────────────────────────────────────
source "${SCRIPT_DIR}/FunctionsFTP-A.sh"   # Monitoreo general
source "${SCRIPT_DIR}/FunctionsFTP-B.sh"   # Instalación y control del servicio
source "${SCRIPT_DIR}/FunctionsFTP-C.sh"   # Gestión de usuarios y grupos
source "${SCRIPT_DIR}/FunctionsFTP-D.sh"   # Configuración y mantenimiento

# Cargar grupos guardados en disco (si ya existen de ejecuciones anteriores)
_ftp_cargar_grupos

#
#   MENÚ PRINCIPAL
#

main_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}   Gestor de Servidor FTP — Fedora Server     ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
        echo ""

        if check_service_active "vsftpd"; then
            echo -e "  Estado vsftpd : ${GREEN}● ACTIVO${NC}"
        else
            echo -e "  Estado vsftpd : ${RED}● INACTIVO${NC}"
        fi

        if [[ ${#FTP_GROUPS[@]} -gt 0 ]]; then
            echo -e "  Grupos FTP    : ${GRAY}${FTP_GROUPS[*]}${NC}"
        else
            echo -e "  Grupos FTP    : ${YELLOW}(ninguno configurado)${NC}"
        fi

        echo ""
        aputs_info "Seleccione una opción:"
        echo ""
        echo -e "  ${BLUE}1)${NC} Monitoreo general"
        echo -e "  ${BLUE}2)${NC} Instalación y control del servicio"
        echo -e "  ${BLUE}3)${NC} Gestión de usuarios y grupos"
        echo -e "  ${BLUE}4)${NC} Configuración y mantenimiento"
        echo -e "  ${BLUE}5)${NC} Salir"
        echo ""

        local op
        read -rp "  Opción: " op

        case "$op" in
            1) ftp_menu_monitoreo    ;;
            2) ftp_menu_instalacion  ;;
            3) ftp_menu_gestion      ;;
            4) ftp_menu_extras       ;;
            5) clear; echo ""; aputs_info "Saliendo del Gestor FTP..."; echo ""; exit 0 ;;
            *) aputs_error "Opción inválida — elige entre 1 y 5"; sleep 1 ;;
        esac
    done
}

#
#   Punto de entrada
#

if ! check_privileges; then
    echo ""
    aputs_error "Este script requiere permisos de sudo."
    aputs_info  "Ejecute: sudo bash mainFTP.sh"
    echo ""
    exit 1
fi

if ! ftp_verificar_dependencias; then
    echo ""
    aputs_error "Dependencias faltantes. Resuelva los errores antes de continuar."
    echo ""
    exit 1
fi

echo ""
pause

main_menu