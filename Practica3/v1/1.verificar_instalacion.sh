#!/bin/bash
#
#
# verificar_instalacion.sh
#
#
# Cargar utilidades
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Función principal de verificación
verificar_instalacion() {
    clear
    draw_header "Verificacion de Instalacion DNS"
    
    local errores=0
    local advertencias=0
    
    # 1. Verificar instalación de BIND
    aputs_info "Verificando instalacion de BIND..."
    echo ""
    
    if check_package_installed "bind"; then
        local version=$(rpm -q bind 2>/dev/null | head -n 1)
        aputs_success "BIND instalado: $version"
        
        # Verificar paquetes adicionales
        if check_package_installed "bind-utils"; then
            local utils_version=$(rpm -q bind-utils 2>/dev/null | head -n 1)
            aputs_success "BIND Utils instalado: $utils_version"
        else
            aputs_warning "BIND Utils NO instalado"
            ((advertencias++))
        fi
    else
        aputs_error "BIND NO esta instalado"
        ((errores++))
    fi
    
    echo ""
    draw_line
    
    # 2. Verificar puertos en escucha
    aputs_info "Verificando puertos en escucha..."
    echo ""
    
    local puerto_tcp=$(sudo ss -tlnp 2>/dev/null | grep ":53 " | grep "named")
    local puerto_udp=$(sudo ss -ulnp 2>/dev/null | grep ":53 " | grep "named")
    
    if [[ -n "$puerto_tcp" ]]; then
        aputs_success "Puerto 53/TCP: ESCUCHANDO"
        echo "$puerto_tcp" | awk '{print "  "$1" "$4" "$5}'
    else
        aputs_warning "Puerto 53/TCP: NO escuchando"
        ((advertencias++))
    fi
    
    if [[ -n "$puerto_udp" ]]; then
        aputs_success "Puerto 53/UDP: ESCUCHANDO"
        echo "$puerto_udp" | awk '{print "  "$1" "$4" "$5}'
    else
        aputs_warning "Puerto 53/UDP: NO escuchando"
        ((advertencias++))
    fi
    
    echo ""
    draw_line
    
    # 4. Verificar firewall
    aputs_info "Verificando configuracion de firewall..."
    echo ""
    
    if sudo systemctl is-active --quiet firewalld; then
        aputs_success "Firewalld: ACTIVO"
        
        if sudo firewall-cmd --list-services 2>/dev/null | grep -q "dns"; then
            aputs_success "Servicio DNS: PERMITIDO en firewall"
        else
            aputs_warning "Servicio DNS: NO permitido en firewall"
            echo "  Ejecute: sudo firewall-cmd --permanent --add-service=dns"
            echo "           sudo firewall-cmd --reload"
            ((advertencias++))
        fi
    else
        aputs_warning "Firewalld: INACTIVO"
        ((advertencias++))
    fi
    
    echo ""
    draw_line
    
    # 7. Verificar configuración de red
    aputs_info "Verificando configuracion de red..."
    echo ""
    
    # Detectar interfaz en la red 192.168.100.0/24
    local interface_found=""
    while IFS= read -r iface; do
        local ip=$(get_interface_ip "$iface")
        if [[ "$ip" == 192.168.100.* ]]; then
            interface_found="$iface"
            aputs_success "Interfaz de red DNS encontrada: $iface"
            echo "  IP: $ip"
            break
        fi
    done < <(get_network_interfaces)
    
    if [[ -z "$interface_found" ]]; then
        aputs_warning "No se encontro interfaz en la red 192.168.100.0/24"
        ((advertencias++))
    else
        # Verificar si es la IP esperada del servidor
        local server_ip=$(get_interface_ip "$interface_found")
        if [[ "$server_ip" == "192.168.100.10" ]]; then
            aputs_success "IP del servidor DNS: 192.168.100.10 (correcta)"
        else
            aputs_warning "IP del servidor: $server_ip (esperada: 192.168.100.10)"
            ((advertencias++))
        fi
    fi
    
    echo ""
    draw_line
    
    # Resumen final
    aputs_info "Resumen de verificacion"
    echo ""
    
    if [[ $errores -eq 0 && $advertencias -eq 0 ]]; then
        aputs_success "Sistema DNS completamente funcional"
    elif [[ $errores -eq 0 ]]; then
        aputs_warning "Sistema DNS funcional con $advertencias advertencia(s)"
    else
        aputs_error "Sistema DNS con $errores error(es) y $advertencias advertencia(s)"
    fi
    
    echo ""
    echo "Errores criticos: $errores"
    echo "Advertencias: $advertencias"
    echo ""
}

# Ejecutar si se llama directamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    verificar_instalacion
    pause
fi