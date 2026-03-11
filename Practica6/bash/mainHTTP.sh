#!/bin/bash
#
# main_http.sh
# Script principal — Gestor de Servicios HTTP en Fedora Server
#
# Punto único de entrada del sistema.
# Este archivo NO contiene lógica — solo carga módulos y llama funciones.
#
# Estructura del proyecto:
#   main_http.sh          ← este archivo (solo source + llamadas)
#   utils.sh              ← utilidades base (práctica 4, sin modificar)
#   utils_http.sh         ← constantes globales y helpers HTTP
#   validators_http.sh    ← validaciones de entrada para servicios HTTP
#   http_functions_A.sh   ← Grupo A: Verificación de estado
#   http_functions_B.sh   ← Grupo B: Instalación de servicios
#   http_functions_C.sh   ← Grupo C: Configuración y seguridad      [pendiente]
#   http_functions_D.sh   ← Grupo D: Gestión de versiones           [pendiente]
#   http_functions_E.sh   ← Grupo E: Monitoreo                      [pendiente]
#
# Uso desde cliente vía SSH:
#   ssh usuario@192.168.100.10 "sudo bash /opt/practica6/main_http.sh"
# O conectado directamente al servidor:
#   sudo bash /opt/practica6/main_http.sh
#

#
#   CARGA DE MÓDULOS
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Capa 1: Base ──────────────────────────────────────────────────────────────
# Utilidades compartidas con práctica 4 (colores, aputs_*, draw_*, pause, agets)
source "${SCRIPT_DIR}/utils.sh"

# ── Capa 2: HTTP ──────────────────────────────────────────────────────────────
# Constantes globales (rutas, usuarios, puertos) y helpers específicos de HTTP
source "${SCRIPT_DIR}/utilsHTTP.sh"

# ── Capa 3: Validación ────────────────────────────────────────────────────────
# Funciones http_validar_* — se cargan antes que cualquier función de lógica
source "${SCRIPT_DIR}/validatorsHTTP.sh"

# ── Capa 4: Lógica por grupos ─────────────────────────────────────────────────
# Grupo A — Verificación de estado (solo lectura, base de los demás grupos)
source "${SCRIPT_DIR}/FunctionsHTTP-A.sh"

# Grupo B — Instalación de servicios (flujo encadenado completo)
source "${SCRIPT_DIR}/FunctionsHTTP-B.sh"

# Grupo C — Configuración y seguridad (cambio de puerto, headers, métodos HTTP)
source "${SCRIPT_DIR}/FunctionsHTTP-C.sh"

# Grupo D — Gestión de versiones (upgrade, downgrade, consulta de versión activa)
source "${SCRIPT_DIR}/FunctionsHTTP-D.sh"

# Grupo E — Monitoreo (estado, puertos, logs, headers en vivo con curl -I)
source "${SCRIPT_DIR}/FunctionsHTTP-E.sh"

#
#   MENÚ PRINCIPAL
# 

main_menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}   Gestor de Servicios HTTP — Fedora Server   ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}   192.168.100.10                              ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        aputs_info "Seleccione una opcion:"
        echo ""
        echo -e "  ${BLUE}1)${NC} Verificar estado de servicios HTTP"
        echo -e "  ${BLUE}2)${NC} Instalar servicio HTTP"
        echo -e "  ${BLUE}3)${NC} Configurar servicio"
        echo -e "  ${BLUE}4)${NC} Monitoreo"
        echo -e "  ${BLUE}5)${NC} Salir"
        echo ""

        local op
        read -rp "  Opcion: " op

        # Validar que la opción sea un número entre 1 y 5
        if ! http_validar_opcion_menu "$op" "5"; then
            sleep 2
            continue
        fi

        case "$op" in
            1)
                # Grupo A — Panel general, puerto disponible, usuario del servicio
                http_menu_verificar
                ;;
            2)
                # Grupo B — Flujo encadenado: servicio -> versión -> puerto -> instalación
                http_menu_instalar
                continue   # http_menu_instalar tiene su propio ciclo while
                ;;
            3)
                # Grupos C + D — Cambio de puerto, seguridad, métodos HTTP, versiones
                http_menu_configurar
                continue
                ;;
            4)
                # Grupo E — Estado, puertos, logs, headers HTTP en vivo (curl -I)
                http_menu_monitoreo
                continue
                ;;
            5)
                clear
                echo ""
                aputs_info "Saliendo del Gestor HTTP..."
                echo ""
                exit 0
                ;;
        esac

        echo ""
        pause
    done
}

#
#   Punto de entrada
#  

if ! check_privileges; then
    echo ""
    aputs_error "Este script requiere permisos de sudo."
    aputs_info  "Ejecute: sudo -v   para activar sudo en esta sesion."
    aputs_info  "O use directamente: sudo bash main_http.sh"
    echo ""
    exit 1
fi

#    Si falta curl, dnf, firewall-cmd o ss el script no puede operar
if ! http_verificar_dependencias; then
    echo ""
    aputs_error "Dependencias faltantes. Resuelva los errores antes de continuar."
    echo ""
    exit 1
fi

echo ""
pause

main_menu