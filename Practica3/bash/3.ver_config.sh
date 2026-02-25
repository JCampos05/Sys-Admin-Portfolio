#!/bin/bash#
#
# 
# Módulo para ver la configuración actual del servidor DNS
# 
#
# Cargar utilidades
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Función principal para ver configuración actual
ver_config_actual() {
    clear
    draw_header "Configuracion actual del servidor DNS"
    
    # Verificar privilegios
    if ! check_privileges; then
        return 1
    fi
    
    # Verificar que BIND esté instalado
    if ! check_package_installed "bind"; then
        aputs_error "BIND no esta instalado"
        echo ""
        aputs_info "Ejecute primero la opcion '2) Instalar/config servicio DNS'"
        return 1
    fi
    
    # Verificar que existe named.conf
    if [[ ! -f /etc/named.conf ]]; then
        aputs_error "No existe archivo /etc/named.conf"
        echo ""
        aputs_info "Ejecute primero la opcion '2) Instalar/config servicio DNS'"
        return 1
    fi

    draw_line
    # 1 --> Estado del servicio
    aputs_info "1. Estado del Servicio DNS"
    echo ""
    
    if check_service_active "named"; then
        aputs_success "Servicio: ACTIVO"
        
        local pid=$(sudo systemctl show named --property=MainPID --value 2>/dev/null)
        if [[ -n "$pid" && "$pid" != "0" ]]; then
            echo "  PID: $pid"
        fi
        
        if check_service_enabled "named"; then
            echo "  Inicio automatico: HABILITADO"
        else
            echo "  Inicio automatico: DESHABILITADO"
        fi
    else
        aputs_error "Servicio: INACTIVO"
    fi
    
    draw_line
    
    # SECCIÓN 2: Configuración de red
    aputs_info "2. Configuracion de Red"
    echo ""
    
    local interface_found=""
    local server_ip=""

    while IFS= read -r iface; do
        local ip=$(get_interface_ip "$iface")
        if [[ "$ip" != "Sin IP" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            interface_found="$iface"
            server_ip="$ip"
            break
        fi
    done < <(get_network_interfaces)

    if [[ -n "$interface_found" ]]; then
        echo "  Interfaz DNS: $interface_found"
        echo "  IP Servidor: $server_ip"

        local netmask=$(ip -4 addr show "$interface_found" | grep -oP 'inet \K[^/]+/\d+' | cut -d'/' -f2)
        if [[ -n "$netmask" ]]; then
            echo "  Mascara: /$netmask"
        fi

        local gateway=$(ip route | grep "^default" | grep "$interface_found" | awk '{print $3}' 2>/dev/null)
        if [[ -n "$gateway" ]]; then
            echo "  Gateway: $gateway"
        fi
    else
        aputs_warning "No se encontro ninguna interfaz con IP asignada"
    fi
    
    draw_line
    
    # 3 --> Parámetros DNS de named.conf
    aputs_info "3. Parametros DNS (named.conf)"
    echo ""
    
    # IP en la que escucha
    local listen_ip=$(sudo grep "listen-on port 53" /etc/named.conf 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | grep -v "127.0.0.1" | head -n 1)
    if [[ -n "$listen_ip" ]]; then
        echo "  Escuchando en: 127.0.0.1, $listen_ip"
    else
        echo "  Escuchando en: 127.0.0.1"
    fi
    
    # Redes permitidas
    local allowed_query=$(sudo grep -A 5 "allow-query" /etc/named.conf 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+/\d+' | head -n 1)
    if [[ -n "$allowed_query" ]]; then
        echo "  Redes permitidas: localhost, $allowed_query"
    else
        echo "  Redes permitidas: No configurado"
    fi
    
    # Recursión
    local recursion=$(sudo grep "recursion" /etc/named.conf 2>/dev/null | grep -v "^[[:space:]]*#" | grep -oP 'yes|no' | head -n 1)
    if [[ -n "$recursion" ]]; then
        if [[ "$recursion" == "yes" ]]; then
            echo "  Recursion: HABILITADA"
            
            # Redes con recursión
            local rec_networks=$(sudo grep -A 5 "allow-recursion" /etc/named.conf 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+/\d+' | head -n 1)
            if [[ -n "$rec_networks" ]]; then
                echo "  Recursion permitida: localhost, $rec_networks"
            fi
        else
            echo "  Recursion: DESHABILITADA"
        fi
    fi
    
    # Forwarders
    local forwarders=$(sudo sed -n '/forwarders {/,/};/p' /etc/named.conf 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | tr '\n' ', ' | sed 's/,$//')
    if [[ -n "$forwarders" ]]; then
        echo "  DNS Forwarders: $forwarders"
    else
        echo "  DNS Forwarders: No configurados"
    fi
    
    draw_line

    # 4 --> Puertos
    aputs_info "4. Puertos en escucha"
    echo ""
    
    local puerto_tcp=$(sudo ss -tlnp 2>/dev/null | grep ":53 " | grep "named")
    local puerto_udp=$(sudo ss -ulnp 2>/dev/null | grep ":53 " | grep "named")
    
    if [[ -n "$puerto_tcp" ]]; then
        echo "  [OK] 53/TCP: Escuchando"
    else
        echo "  [--] 53/TCP: No escuchando"
    fi
    
    if [[ -n "$puerto_udp" ]]; then
        echo "  [OK] 53/UDP: Escuchando"
    else
        echo "  [--] 53/UDP: No escuchando"
    fi
    
    draw_line
    
    # 5 --> Firewall
    aputs_info "5. Firewall"
    echo ""
    
    if sudo systemctl is-active --quiet firewalld; then
        echo "  Firewalld: ACTIVO"
        
        if sudo firewall-cmd --list-services 2>/dev/null | grep -q "dns"; then
            echo "  Servicio DNS: PERMITIDO"
        else
            echo "  Servicio DNS: NO permitido"
        fi
    else
        echo "  Firewalld: INACTIVO"
    fi
    
    draw_line
    
    # 6 --> Zonas configuradas
    aputs_info "6. Zonas conriguradas"
    echo ""
    
    local zonas_directas=$(sudo find /var/named -maxdepth 1 -name "*.zone" -type f 2>/dev/null | wc -l)
    local zonas_inversas=$(sudo find /var/named -maxdepth 1 -name "*.rev" -type f 2>/dev/null | wc -l)
    
    echo "  Zonas directas: $zonas_directas"
    echo "  Zonas inversas: $zonas_inversas"
    echo "  Total: $((zonas_directas + zonas_inversas))"
    
    if [[ $zonas_directas -gt 0 ]]; then
        echo ""
        echo "  Dominios:"
        while IFS= read -r zona_file; do
            local dominio=$(basename "$zona_file" .zone)
            local ip=$(sudo grep "^@.*IN.*A" "$zona_file" 2>/dev/null | head -n 1 | awk '{print $NF}')
            local serial=$(sudo grep -m1 "Serial" "$zona_file" 2>/dev/null | grep -oP '\d{10}')
            
            echo "    - $dominio"
            echo "      IP: ${ip:-N/A}"
            echo "      Serial: ${serial:-N/A}"
        done < <(sudo find /var/named -maxdepth 1 -name "*.zone" -type f 2>/dev/null | sort)
    fi
    
    draw_line

    # 7 --> Archivos de configuracion
    aputs_info "7. Archivos de configuracion"
    echo ""
    
    echo "  Archivo principal:"
    echo "    /etc/named.conf"
    
    if [[ -f /etc/named.conf ]]; then
        local size=$(du -h /etc/named.conf 2>/dev/null | awk '{print $1}')
        local mod=$(stat -c %y /etc/named.conf 2>/dev/null | cut -d'.' -f1)
        echo "    Tamaño: $size"
        echo "    Modificado: $mod"
    fi
    
    echo ""
    echo "  Directorio de zonas:"
    echo "    /var/named/"
    
    if [[ -d /var/named ]]; then
        local archivos=$(sudo ls -1 /var/named/*.zone /var/named/*.rev 2>/dev/null | wc -l)
        echo "    Archivos de zona: $archivos"
    fi
    
    draw_line
    aputs_success "Configuracion mostrada completamente"
}

# Ejecutar si se llama directamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ver_config_actual
    pause
fi