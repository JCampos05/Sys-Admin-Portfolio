#!/bin/bash
#
# reiniciar_servicio.sh
# 
# Cargar utilidades
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Función para validar sintaxis de named.conf
validar_named_conf() {
    aputs_info "Validando sintaxis de /etc/named.conf..."
    
    if sudo named-checkconf /etc/named.conf 2>/dev/null; then
        aputs_success "Sintaxis de named.conf: VALIDA"
        return 0
    else
        aputs_error "Sintaxis de named.conf: INVALIDA"
        echo ""
        aputs_error "Detalles del error:"
        sudo named-checkconf /etc/named.conf 2>&1 | sed 's/^/  /'
        return 1
    fi
}

# Función para validar sintaxis de todas las zonas
validar_zonas() {
    aputs_info "Validando sintaxis de archivos de zona..."
    
    local errores=0
    local zonas_validadas=0
    
    # Buscar archivos de zona en /var/named
    if [[ -d /var/named ]]; then
        while IFS= read -r zona_file; do
            local zona_name=$(basename "$zona_file" .zone)
            
            # Intentar validar la zona
            if sudo named-checkzone "$zona_name" "$zona_file" &>/dev/null; then
                aputs_success "Zona $zona_name: VALIDA"
                ((zonas_validadas++))
            else
                aputs_error "Zona $zona_name: INVALIDA"
                echo ""
                aputs_error "Detalles del error:"
                sudo named-checkzone "$zona_name" "$zona_file" 2>&1 | head -n 5 | sed 's/^/  /'
                ((errores++))
            fi
        done < <(sudo find /var/named -maxdepth 1 -name "*.zone" -type f 2>/dev/null)
        
        # Buscar archivos de zona inversa
        while IFS= read -r zona_file; do
            local zona_name=$(basename "$zona_file" .rev)
            
            # Construir nombre de zona inversa desde el archivo
            local rev_zone=$(grep -m1 "^@.*IN.*SOA" "$zona_file" 2>/dev/null | awk '{print $1}')
            if [[ -z "$rev_zone" ]]; then
                rev_zone="$zona_name.in-addr.arpa"
            fi
            
            if sudo named-checkzone "$rev_zone" "$zona_file" &>/dev/null; then
                aputs_success "Zona inversa $zona_name: VALIDA"
                ((zonas_validadas++))
            else
                aputs_error "Zona inversa $zona_name: INVALIDA"
                echo ""
                aputs_error "Detalles del error:"
                sudo named-checkzone "$rev_zone" "$zona_file" 2>&1 | head -n 5 | sed 's/^/  /'
                ((errores++))
            fi
        done < <(sudo find /var/named -maxdepth 1 -name "*.rev" -type f 2>/dev/null)
    fi
    
    if [[ $zonas_validadas -eq 0 ]]; then
        aputs_info "No se encontraron zonas personalizadas para validar"
    else
        aputs_info "Total de zonas validadas: $zonas_validadas"
    fi
    
    if [[ $errores -gt 0 ]]; then
        return 1
    fi
    
    return 0
}

# Función principal para reiniciar servicio
reiniciar_servicio() {
    clear
    draw_header "Reiniciar Servicio DNS"
    
    # Verificar privilegios
    if ! check_privileges; then
        return 1
    fi
    
    # 1. Verificar que el servicio existe
    aputs_info "Verificando existencia del servicio named..."
    if ! sudo systemctl status named &>/dev/null; then
        aputs_error "El servicio named no esta instalado o no existe"
        return 1
    fi
    aputs_success "Servicio named encontrado"
    echo ""
    draw_line
    
    # 2. Validar configuración antes de reiniciar
    aputs_info "PASO 1: Validando configuracion antes de reiniciar"
    echo ""
    
    local config_valida=true
    
    if ! validar_named_conf; then
        config_valida=false
    fi
    
    echo ""
    
    if ! validar_zonas; then
        config_valida=false
    fi
    
    echo ""
    draw_line
    
    # Si hay errores de configuración, preguntar si desea continuar
    if [[ "$config_valida" == "false" ]]; then
        aputs_error "Se encontraron errores en la configuracion"
        echo ""
        aputs_warning "NO se recomienda reiniciar el servicio con errores de sintaxis"
        echo ""
        
        local respuesta
        read -rp "¿Desea continuar con el reinicio de todas formas? (s/n): " respuesta
        
        if [[ "$respuesta" != "s" && "$respuesta" != "S" ]]; then
            aputs_info "Reinicio cancelado por el usuario"
            return 1
        fi
        
        echo ""
        draw_line
        echo ""
    else
        aputs_success "Todas las validaciones pasaron correctamente"
        draw_line
    fi
    
    # 3. Mostrar estado actual del servicio
    aputs_info "PASO 2: Estado actual del servicio"
    echo ""
    
    if check_service_active "named"; then
        aputs_info "El servicio named esta ACTIVO"
        
        # Mostrar información básica
        local pid=$(sudo systemctl show named --property=MainPID --value 2>/dev/null)
        local memory=$(sudo systemctl show named --property=MemoryCurrent --value 2>/dev/null)
        
        if [[ -n "$pid" && "$pid" != "0" ]]; then
            echo "  PID: $pid"
        fi
        
        if [[ -n "$memory" && "$memory" != "[not set]" ]]; then
            local memory_mb=$((memory / 1024 / 1024))
            echo "  Memoria: ${memory_mb} MB"
        fi
    else
        aputs_info "El servicio named esta INACTIVO"
    fi
    
    draw_line
    
    # 4. Confirmar reinicio
    aputs_warning "El servicio DNS se reiniciara"
    echo ""
    aputs_info "Esto puede causar una breve interrupcion en las consultas DNS"
    echo ""
    
    local confirmar
    read -rp "¿Confirma que desea reiniciar el servicio? (s/n): " confirmar
    
    if [[ "$confirmar" != "s" && "$confirmar" != "S" ]]; then
        aputs_info "Reinicio cancelado por el usuario"
        return 0
    fi
    
    echo ""
    draw_line
    
    # 5. Reiniciar servicio
    aputs_info "PASO 3: Reiniciando servicio named..."
    echo ""
    
    if sudo systemctl restart named 2>/dev/null; then
        aputs_success "Comando de reinicio ejecutado"
    else
        aputs_error "Error al ejecutar comando de reinicio"
        echo ""
        aputs_error "Detalles del error:"
        sudo journalctl -u named -n 10 --no-pager 2>&1 | sed 's/^/  /'
        return 1
    fi
    
    # Esperar a que el servicio se estabilice
    sleep 2
    
    echo ""
    draw_line
    
    # 6. Verificar que el servicio levantó correctamente
    aputs_info "PASO 4: Verificando estado post-reinicio"
    echo ""
    
    if check_service_active "named"; then
        aputs_success "Servicio named: ACTIVO"
        
        # Mostrar información actualizada
        local new_pid=$(sudo systemctl show named --property=MainPID --value 2>/dev/null)
        if [[ -n "$new_pid" && "$new_pid" != "0" ]]; then
            echo "  Nuevo PID: $new_pid"
        fi
        
        # Verificar puertos
        sleep 1
        local puerto_tcp=$(sudo ss -tlnp 2>/dev/null | grep ":53 " | grep "named")
        local puerto_udp=$(sudo ss -ulnp 2>/dev/null | grep ":53 " | grep "named")
        
        if [[ -n "$puerto_tcp" ]]; then
            aputs_success "Puerto 53/TCP: ESCUCHANDO"
        else
            aputs_warning "Puerto 53/TCP: NO escuchando"
        fi
        
        if [[ -n "$puerto_udp" ]]; then
            aputs_success "Puerto 53/UDP: ESCUCHANDO"
        else
            aputs_warning "Puerto 53/UDP: NO escuchando"
        fi
        
        echo ""
        draw_line
        
        aputs_success "REINICIO COMPLETADO EXITOSAMENTE"
        
    else
        aputs_error "Servicio named: NO se inicio correctamente"
        echo ""
        aputs_error "Logs de error:"
        sudo journalctl -u named -n 10 --no-pager 2>&1 | sed 's/^/  /'
        return 1
    fi
    
    echo ""
    
    # 7. Mostrar logs recientes (resumido)
    aputs_info "Logs recientes del servicio (ultimas 5 lineas):"
    echo ""
    sudo journalctl -u named -n 5 --no-pager 2>/dev/null | tail -n 5
    
    return 0
}

# Ejecutar si se llama directamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    reiniciar_servicio
    pause
fi