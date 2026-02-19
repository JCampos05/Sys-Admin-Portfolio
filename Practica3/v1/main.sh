#!/bin/bash
#
# main.sh
# Script principal - Gestor de Servicio DNS
#
# Obtener directorio del script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cargar utilidades
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/validators_dns.sh"

# Cargar módulos
source "${SCRIPT_DIR}/1.verificar_instalacion.sh"
source "${SCRIPT_DIR}/2.InstalConfigServicio.sh"
source "${SCRIPT_DIR}/3.ver_config.sh"
source "${SCRIPT_DIR}/4.reiniciar_servicio.sh"
source "${SCRIPT_DIR}/5.monitor_dns.sh"
source "${SCRIPT_DIR}/6.crud_dominios.sh"

# Variables globales
INTERFACES=()
INTERFAZ_SELECCIONADA=""

# Función de detección de interfaces de red
deteccion_interfaces_red(){
    mapfile -t INTERFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo")

    if [ "${#INTERFACES[@]}" -eq 0 ]; then
        echo ""
        aputs_warning "No se detectaron interfaces de red"
        exit 1
    fi

    echo ""
    aputs_info "Interfaces de red detectadas:"
    
    for i in "${!INTERFACES[@]}"; do
        local iface="${INTERFACES[$i]}"
        local current_ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[^/]+' || echo "Sin IP")
        echo ""
        printf "  %d) %-10s (IP actual: %s)\n" $((i+1)) "$iface" "$current_ip"
    done
    echo ""

    while true; do
        read -rp "Seleccione el numero de la interfaz [1-${#INTERFACES[@]}]: " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && 
            [ "$selection" -ge 1 ] && 
            [ "$selection" -le "${#INTERFACES[@]}" ]; then
            INTERFAZ_SELECCIONADA="${INTERFACES[$((selection-1))]}"
            break
        else
            aputs_error "Seleccion invalida. Ingrese un numero entre 1 y ${#INTERFACES[@]}"
        fi
    done
    
    echo ""
    aputs_success "Interfaz de red seleccionada: $INTERFAZ_SELECCIONADA"
}

# Menú principal
main_menu() {
    while true; do
        clear
        echo ""
        aputs_info "┌────────────────────────────────┐"
        aputs_info "|---| Gestor de Servicio DNS |---|"
        aputs_info "└────────────────────────────────┘"
        echo ""
        aputs_info "Seleccione una opcion:"
        echo ""
        aputs_info "1) Verificar instalacion"
        aputs_info "2) Instalar/config servicio DNS"
        aputs_info "3) Ver configuracion actual"
        aputs_info "4) Reiniciar servicio"
        aputs_info "5) Monitor DNS"
        aputs_info "6) ABC Dominios"
        aputs_info "7) Salir"
        echo ""
        read -rp "Opcion: " OP

        case $OP in
        1)
            verificar_instalacion
            ;;
        2)
            instalar_config_servicio
            ;;
        3)
            ver_config_actual
            ;;
        4)
            reiniciar_servicio
            ;;
        5) 
            monitor_dns
            ;;
        6)
            crud_dominios
            ;;
        7)
            clear
            echo ""
            aputs_info "Saliendo del Gestor de Servicio DNS..."
            echo ""
            exit 0
            ;;
        *)
            echo ""
            aputs_error "Opcion invalida. Por favor seleccione una opcion del 1 al 7"
            sleep 2
            continue
            ;;
        esac
        
        echo ""
        pause
    done
}

# Punto de entrada principal
main_menu