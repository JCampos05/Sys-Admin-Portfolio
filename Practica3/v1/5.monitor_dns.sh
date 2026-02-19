#!/bin/bash
#
# monitor_dns.sh
#
# Cargar utilidades
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Función para mostrar estado del servicio
mostrar_estado_servicio() {
    draw_header "Estado del servicio"
    
    if check_service_active "named"; then
        aputs_success "Estado: ACTIVO"
        
        # Obtener información del servicio
        local pid=$(sudo systemctl show named --property=MainPID --value 2>/dev/null)
        local uptime=$(sudo systemctl show named --property=ActiveEnterTimestamp --value 2>/dev/null)
        local memory=$(sudo systemctl show named --property=MemoryCurrent --value 2>/dev/null)
        
        echo ""
        
        if [[ -n "$pid" && "$pid" != "0" ]]; then
            echo "  PID: $pid"
            
            # Obtener CPU usage si es posible
            if command -v ps &>/dev/null; then
                local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
                if [[ -n "$cpu" ]]; then
                    echo "  CPU: ${cpu}%"
                fi
            fi
        fi
        
        if [[ -n "$memory" && "$memory" != "[not set]" ]]; then
            local memory_mb=$((memory / 1024 / 1024))
            echo "  Memoria: ${memory_mb} MB"
        fi
        
        if [[ -n "$uptime" ]]; then
            echo "  Activo desde: $uptime"
        fi
        
        # Verificar si está habilitado
        if check_service_enabled "named"; then
            echo "  Inicio automatico: HABILITADO"
        else
            echo "  Inicio automatico: DESHABILITADO"
        fi
        
    else
        aputs_error "Estado: INACTIVO"
    fi
    
    echo ""
    
    # Verificar puertos
    aputs_info "Puertos en escucha:"
    echo ""
    
    local puerto_tcp=$(sudo ss -tlnp 2>/dev/null | grep ":53 " | grep "named")
    local puerto_udp=$(sudo ss -ulnp 2>/dev/null | grep ":53 " | grep "named")
    
    if [[ -n "$puerto_tcp" ]]; then
        echo "  [OK] 53/TCP - Escuchando"
    else
        echo "  [--] 53/TCP - No escuchando"
    fi
    
    if [[ -n "$puerto_udp" ]]; then
        echo "  [OK] 53/UDP - Escuchando"
    else
        echo "  [--] 53/UDP - No escuchando"
    fi
}

# Función para mostrar configuración actual
mostrar_configuracion_actual() {
    echo ""
    draw_header "Configuracion Actual"
    
    # Detectar interfaz y IP del servidor en la red 192.168.100.0/24
    aputs_info "Configuracion de Red:"
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
        echo "  Interfaz: $interface_found"
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
    
    echo ""
    
    # Leer configuración de named.conf
    if [[ -f /etc/named.conf ]]; then
        aputs_info "Configuracion DNS (named.conf):"
        echo ""
        
        # Extraer redes permitidas
        local allowed_query=$(sudo grep -A 5 "allow-query" /etc/named.conf 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+/\d+' | head -n 1)
        if [[ -n "$allowed_query" ]]; then
            echo "  Redes permitidas: $allowed_query"
        else
            echo "  Redes permitidas: No configurado"
        fi
        
        # Extraer forwarders
        local forwarders=$(sudo grep -A 5 "forwarders" /etc/named.conf 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | tr '\n' ', ' | sed 's/,$//')
        if [[ -n "$forwarders" ]]; then
            echo "  Forwarders: $forwarders"
        else
            echo "  Forwarders: No configurado"
        fi
        
        # Verificar recursión
        local recursion=$(sudo grep "recursion" /etc/named.conf 2>/dev/null | grep -v "^[[:space:]]*#" | grep -oP 'yes|no' | head -n 1)
        if [[ -n "$recursion" ]]; then
            if [[ "$recursion" == "yes" ]]; then
                echo "  Recursion: HABILITADA"
            else
                echo "  Recursion: DESHABILITADA"
            fi
        fi
        
    else
        aputs_warning "Archivo /etc/named.conf no encontrado"
    fi
}

# Función para mostrar resumen de zonas
mostrar_resumen_zonas() {
    draw_header "Resumen de las zonas"
    
    if [[ ! -d /var/named ]]; then
        aputs_warning "Directorio /var/named no encontrado"
        return
    fi
    
    # Contar zonas
    local zonas_directas=$(sudo find /var/named -maxdepth 1 -name "*.zone" -type f 2>/dev/null | wc -l)
    local zonas_inversas=$(sudo find /var/named -maxdepth 1 -name "*.rev" -type f 2>/dev/null | wc -l)
    local total_zonas=$((zonas_directas + zonas_inversas))
    
    aputs_info "Total de zonas configuradas: $total_zonas"
    echo "  Zonas directas: $zonas_directas"
    echo "  Zonas inversas: $zonas_inversas"
    echo ""
    
    if [[ $total_zonas -eq 0 ]]; then
        aputs_info "No hay zonas personalizadas configuradas"
        return
    fi
    
    # Listar zonas directas
    if [[ $zonas_directas -gt 0 ]]; then
        aputs_info "Zonas Directas:"
        echo ""
        
        while IFS= read -r zona_file; do
            local zona_name=$(basename "$zona_file" .zone)
            
            # Obtener información de la zona
            local serial=$(sudo grep -m1 "Serial" "$zona_file" 2>/dev/null | grep -oP '\d{10}')
            local registros=$(sudo grep -c "^[^;].*IN.*[A-Z]" "$zona_file" 2>/dev/null || echo "0")
            
            echo "  - $zona_name"
            if [[ -n "$serial" ]]; then
                echo "    Serial: $serial"
            fi
            echo "    Registros: $registros"
            
            # Validar zona
            if sudo named-checkzone "$zona_name" "$zona_file" &>/dev/null; then
                echo "    Estado: Success"
            else
                echo "    Estado: Error"
            fi
            echo ""
        done < <(sudo find /var/named -maxdepth 1 -name "*.zone" -type f 2>/dev/null)
    fi
    
    # Listar zonas inversas
    if [[ $zonas_inversas -gt 0 ]]; then
        aputs_info "Zonas Inversas:"
        echo ""
        
        while IFS= read -r zona_file; do
            local zona_name=$(basename "$zona_file" .rev)
            
            # Obtener información de la zona
            local serial=$(sudo grep -m1 "Serial" "$zona_file" 2>/dev/null | grep -oP '\d{10}')
            local registros=$(sudo grep -c "^[^;].*IN.*PTR" "$zona_file" 2>/dev/null || echo "0")
            
            echo "  - $zona_name (inversa)"
            if [[ -n "$serial" ]]; then
                echo "    Serial: $serial"
            fi
            echo "    Registros PTR: $registros"
            
            # Intentar validar zona inversa
            local rev_zone="${zona_name}.in-addr.arpa"
            if sudo named-checkzone "$rev_zone" "$zona_file" &>/dev/null; then
                echo "    Estado: OK"
            else
                echo "    Estado: ERROR"
            fi
            echo ""
        done < <(sudo find /var/named -maxdepth 1 -name "*.rev" -type f 2>/dev/null)
    fi
}

# Función principal de monitoreo
monitor_dns() {
    clear
    
    # Verificar privilegios
    if ! check_privileges; then
        return 1
    fi
    
    # Verificar que BIND esté instalado
    if ! check_package_installed "bind"; then
        aputs_error "BIND no esta instalado"
        echo ""
        aputs_info "Ejecute la opcion 'Instalar/config servicio DNS' primero"
        return 1
    fi
    
    # Mostrar todas las secciones del monitor
    mostrar_estado_servicio
    mostrar_configuracion_actual
    mostrar_resumen_zonas
    
    draw_line
    aputs_info "Monitor actualizado: $(date '+%Y-%m-%d %H:%M:%S')"
}

# Ejecutar si se llama directamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    monitor_dns
    pause
fi