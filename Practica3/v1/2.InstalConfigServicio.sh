#!/bin/bash
#
# 
# Módulo para instalar y configurar el servicio DNS (BIND)
# 
#
# Cargar utilidades
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Variables globales del módulo
RED_SERVIDOR=""
IP_ESPERADA=""

# Función para verificar si BIND ya está instalado
verificar_bind_instalado() {
    if check_package_installed "bind"; then
        return 0
    else
        return 1
    fi
}

# Función para instalar BIND y utilidades
instalar_bind() {
    aputs_info "Iniciando instalacion de BIND9 y utilidades..."
    echo ""

    # Actualizar repositorios en silencio
    aputs_info "Actualizando repositorios del sistema..."
    sudo dnf check-update &>/dev/null

    # Instalar BIND en silencio
    aputs_info "Instalando paquetes: bind, bind-utils..."

    if sudo dnf install -y bind bind-utils &>/dev/null; then
        local version=$(rpm -q bind 2>/dev/null)
        aputs_success "BIND instalado correctamente"
        echo "  Version: $version"
        return 0
    else
        aputs_error "Error durante la instalacion de BIND"
        aputs_info "Verifique su conexion a internet y los repositorios del sistema"
        return 1
    fi
}

# Función para habilitar servicio named
habilitar_servicio() {
    aputs_info "Habilitando servicio named para inicio automatico..."
    
    if sudo systemctl enable named &>/dev/null; then
        aputs_success "Servicio named habilitado"
        return 0
    else
        aputs_error "No se pudo habilitar el servicio named"
        return 1
    fi
}

# Función para verificar configuración de red
verificar_configuracion_red() {
    draw_header "Verificaciones de Red"
    
    aputs_info "Detectando interfaz de red activa con IP asignada..."
    echo ""
    
    local interface_encontrada=""
    local ip_actual=""
    
    # Buscar CUALQUIER interfaz con IP (excepto loopback)
    while IFS= read -r iface; do
        local ip=$(get_interface_ip "$iface")
        # Verificar que tenga IP válida (no "Sin IP")
        if [[ "$ip" != "Sin IP" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            interface_encontrada="$iface"
            ip_actual="$ip"
            break
        fi
    done < <(get_network_interfaces)
    
    if [[ -z "$interface_encontrada" ]]; then
        aputs_error "No se encontro ninguna interfaz con IP asignada"
        echo ""
        
        # Mostrar interfaces disponibles
        aputs_info "Interfaces de red disponibles:"
        echo ""
        while IFS= read -r iface; do
            local ip=$(get_interface_ip "$iface")
            echo "  - $iface: $ip"
        done < <(get_network_interfaces)
        
        echo ""
        aputs_info "Configure una IP en alguna interfaz antes de continuar"
        
        return 1
    fi
    
    # Calcular red automáticamente
    local red_calculada
    red_calculada=$(echo "$ip_actual" | cut -d. -f1-3)
    RED_SERVIDOR="${red_calculada}.0/24"
    
    aputs_success "Interfaz encontrada: $interface_encontrada"
    echo "  IP actual: $ip_actual"
    echo "  Red detectada: $RED_SERVIDOR"
    echo ""
    
    # Preguntar si desea continuar con esta configuración
    local respuesta
    read -rp "¿Desea usar esta interfaz para el servidor DNS? (s/n) [s]: " respuesta
    respuesta=${respuesta:-s}
    
    if [[ "$respuesta" == "s" || "$respuesta" == "S" ]]; then
        aputs_success "Configuracion aceptada"
        
        # Exportar variables globales
        export INTERFAZ_DNS="$interface_encontrada"
        export IP_SERVIDOR="$ip_actual"
        export RED_SERVIDOR
        
        return 0
    else
        aputs_info "Configuracion cancelada"
        echo ""
        aputs_info "Seleccione manualmente la interfaz a usar"
        
        # Permitir selección manual
        echo ""
        aputs_info "Interfaces disponibles:"
        echo ""
        
        local interfaces=()
        while IFS= read -r iface; do
            local ip=$(get_interface_ip "$iface")
            if [[ "$ip" != "Sin IP" ]]; then
                interfaces+=("$iface")
                echo "  ${#interfaces[@]}) $iface - $ip"
            fi
        done < <(get_network_interfaces)
        
        if [[ ${#interfaces[@]} -eq 0 ]]; then
            aputs_error "No hay interfaces con IP disponibles"
            return 1
        fi
        
        echo ""
        local seleccion
        read -rp "Seleccione el numero de interfaz [1-${#interfaces[@]}]: " seleccion
        
        if [[ $seleccion -ge 1 && $seleccion -le ${#interfaces[@]} ]]; then
            local iface_seleccionada="${interfaces[$((seleccion-1))]}"
            local ip_seleccionada=$(get_interface_ip "$iface_seleccionada")
            
            # Calcular red
            red_calculada=$(echo "$ip_seleccionada" | cut -d. -f1-3)
            RED_SERVIDOR="${red_calculada}.0/24"
            
            aputs_success "Interfaz seleccionada: $iface_seleccionada ($ip_seleccionada)"
            
            export INTERFAZ_DNS="$iface_seleccionada"
            export IP_SERVIDOR="$ip_seleccionada"
            export RED_SERVIDOR
            
            return 0
        else
            aputs_error "Seleccion invalida"
            return 1
        fi
    fi
}

# Función para solicitar parámetros de configuración DNS
solicitar_parametros_dns() {
    draw_header "Configuracion de parametros DNS"
    
    aputs_info "Se configurara el servidor DNS con los siguientes parametros"
    echo ""
    
    # Red permitida para consultas
    local red_default="${IP_SERVIDOR}/32"

    aputs_info "Red permitida para consultas DNS:"
    aputs_info "IP actual del servidor: $IP_SERVIDOR"
    read -rp "  [Default: any]: " RED_PERMITIDA
    RED_PERMITIDA=${RED_PERMITIDA:-any}
    
    echo ""
    
    # Recursión
    aputs_info "¿Permitir recursion? (permite que el servidor busque respuestas en otros DNS)"
    read -rp "  [s/n, Default: s]: " permitir_rec
    permitir_rec=${permitir_rec:-s}
    
    if [[ "$permitir_rec" == "s" || "$permitir_rec" == "S" ]]; then
        PERMITIR_RECURSION="yes"
        echo "  Recursion: HABILITADA"
    else
        PERMITIR_RECURSION="no"
        echo "  Recursion: DESHABILITADA"
    fi
    
    echo ""
    
    # Forwarders (solo si la recursión está habilitada)
    if [[ "$PERMITIR_RECURSION" == "yes" ]]; then
        aputs_info "DNS Forwarders (servidores DNS externos para consultas)"
        
        read -rp "  Forwarder primario [Default: 8.8.8.8]: " DNS_FORWARDER_1
        DNS_FORWARDER_1=${DNS_FORWARDER_1:-8.8.8.8}
        
        read -rp "  Forwarder secundario [Default: 8.8.4.4]: " DNS_FORWARDER_2
        DNS_FORWARDER_2=${DNS_FORWARDER_2:-8.8.4.4}
        
        # Validar IPs de forwarders
        if ! validate_ip "$DNS_FORWARDER_1"; then
            aputs_warning "IP de forwarder primario invalida, usando 8.8.8.8"
            DNS_FORWARDER_1="8.8.8.8"
        fi
        
        if ! validate_ip "$DNS_FORWARDER_2"; then
            aputs_warning "IP de forwarder secundario invalida, usando 8.8.4.4"
            DNS_FORWARDER_2="8.8.4.4"
        fi
    else
        DNS_FORWARDER_1=""
        DNS_FORWARDER_2=""
    fi
    
    draw_line

    # Mostrar resumen
    aputs_info "Resumen de Configuracion:"
    echo ""
    echo "  IP del Servidor DNS: $IP_SERVIDOR"
    echo "  Interfaz: $INTERFAZ_DNS"
    echo "  Red permitida: $RED_PERMITIDA"
    echo "  Recursion: $PERMITIR_RECURSION"
    
    if [[ "$PERMITIR_RECURSION" == "yes" ]]; then
        echo "  Forwarder primario: $DNS_FORWARDER_1"
        echo "  Forwarder secundario: $DNS_FORWARDER_2"
    fi
    
    echo ""
    
    local confirmar
    read -rp "¿Es correcta esta configuracion? (s/n): " confirmar
    
    if [[ "$confirmar" != "s" && "$confirmar" != "S" ]]; then
        aputs_info "Reingresando parametros..."
        echo ""
        solicitar_parametros_dns
    fi
    
    # Exportar variables
    export RED_PERMITIDA
    export PERMITIR_RECURSION
    export DNS_FORWARDER_1
    export DNS_FORWARDER_2
}

# Función para hacer backup de configuraciones existentes
backup_configuraciones() {
    local backup_dir="/home/$(whoami)/dns_backup_$(date +%Y%m%d_%H%M%S)"
    
    aputs_info "Creando backup de configuraciones existentes..."
    
    mkdir -p "$backup_dir"
    
    if [[ -f /etc/named.conf ]]; then
        sudo cp /etc/named.conf "$backup_dir/" 2>/dev/null
        aputs_success "Backup de named.conf creado"
    fi
    
    if [[ -d /var/named ]]; then
        sudo cp -r /var/named "$backup_dir/" 2>/dev/null
        aputs_success "Backup de directorio /var/named creado"
    fi
    
    aputs_success "Backup guardado en: $backup_dir"
}

# Función para configurar named.conf
configurar_named_conf() {
    draw_header "Configuracion de named.conf"
    
    aputs_info "Generando archivo /etc/named.conf..."
    
    # Crear archivo temporal
    local temp_file="/tmp/named.conf.tmp"
    
cat > "$temp_file" << 'EOF'
options {
    // Escuchar en localhost y en la IP del servidor DNS
    listen-on port 53 { any; };
    listen-on-v6 port 53 { none; };

    directory "/var/named";
    dump-file "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    secroots-file "/var/named/data/named.secroots";
    recursing-file "/var/named/data/named.recursing";
    
    // Permitir consultas desde localhost y la red configurada
    allow-query { any; };
    
    // Configuracion de recursion
    recursion RECURSION_PLACEHOLDER;
    allow-recursion { localhost; RED_PERMITIDA_PLACEHOLDER; };
    
    // DNS externos para resolver consultas que no conocemos
    forwarders {
        FORWARDER1_PLACEHOLDER;
        FORWARDER2_PLACEHOLDER;
    };
    
    // Validacion DNSSEC
    dnssec-validation yes;
    
    // Directorios adicionales
    managed-keys-directory "/var/named/dynamic";
    geoip-directory "/usr/share/GeoIP";
    
    // Archivos del sistema
    pid-file "/run/named/named.pid";
    session-keyfile "/run/named/session.key";
    
    // Politicas de criptografia
    include "/etc/crypto-policies/back-ends/bind.config";
};
EOF
    # Reemplazar placeholders con valores reales
    sed -i "s|IP_SERVIDOR_PLACEHOLDER|${IP_SERVIDOR}|g" "$temp_file"
    sed -i "s|RED_PERMITIDA_PLACEHOLDER|${RED_PERMITIDA}|g" "$temp_file"
    sed -i "s|RECURSION_PLACEHOLDER|${PERMITIR_RECURSION}|g" "$temp_file"
    
    # Manejar forwarders según si están configurados
    if [[ -n "$DNS_FORWARDER_1" && -n "$DNS_FORWARDER_2" ]]; then
        sed -i "s|FORWARDER1_PLACEHOLDER|${DNS_FORWARDER_1}|g" "$temp_file"
        sed -i "s|FORWARDER2_PLACEHOLDER|${DNS_FORWARDER_2}|g" "$temp_file"
    else
        # Si no hay forwarders, eliminar la sección completa
        sed -i '/forwarders {/,/};/d' "$temp_file"
    fi
    
    # Copiar al sistema con sudo
    if sudo cp "$temp_file" /etc/named.conf; then
        aputs_success "Archivo /etc/named.conf creado"
        
        # Establecer permisos correctos
        sudo chmod 640 /etc/named.conf
        sudo chown root:named /etc/named.conf
        
        aputs_success "Permisos configurados correctamente"
    else
        aputs_error "Error al crear /etc/named.conf"
        rm -f "$temp_file"
        return 1
    fi
    
    # Limpiar archivo temporal
    rm -f "$temp_file"
    
    echo ""
    
    # Validar sintaxis
    aputs_info "Validando sintaxis de named.conf..."
    
    if sudo named-checkconf /etc/named.conf; then
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

# Función para configurar firewall
configurar_firewall() {
    draw_header "Configuracion de Firewall"
    
    aputs_info "Verificando estado de firewalld..."
    
    if ! sudo systemctl is-active --quiet firewalld; then
        aputs_warning "Firewalld no esta activo"
        echo ""
        
        local respuesta
        read -rp "¿Desea iniciar firewalld? (s/n): " respuesta
        
        if [[ "$respuesta" == "s" || "$respuesta" == "S" ]]; then
            aputs_info "Iniciando firewalld..."
            
            if sudo systemctl start firewalld && sudo systemctl enable firewalld; then
                aputs_success "Firewalld iniciado y habilitado"
            else
                aputs_error "No se pudo iniciar firewalld"
                return 1
            fi
        else
            aputs_warning "Firewall no configurado - el servicio DNS puede no ser accesible"
            return 0
        fi
    else
        aputs_success "Firewalld esta activo"
    fi
    
    echo ""
    
    # Agregar servicio DNS al firewall
    aputs_info "Agregando servicio DNS al firewall..."
    
    if sudo firewall-cmd --permanent --add-service=dns &>/dev/null; then
        aputs_success "Servicio DNS agregado a firewall (permanente)"
    else
        aputs_warning "El servicio DNS ya estaba en el firewall"
    fi
    
    # Recargar firewall
    if sudo firewall-cmd --reload &>/dev/null; then
        aputs_success "Firewall recargado"
    fi
    
    echo ""
    
    # Verificar configuración
    aputs_info "Verificando configuracion de firewall..."
    
    if sudo firewall-cmd --list-services | grep -q "dns"; then
        aputs_success "Servicio DNS: PERMITIDO en firewall"
    else
        aputs_error "Servicio DNS: NO permitido en firewall"
        return 1
    fi
    #
    #
    #
    echo ""
    
    # Sumamente Critico: Verificar y configurar zona 'internal' si existe ens192 <-----------------------------------
    aputs_info "Configurando zonas de firewall para interfaces..."
    
    # Usar la interfaz DNS detectada dinámicamente
    if [[ -n "$INTERFAZ_DNS" ]] && ip link show "$INTERFAZ_DNS" &>/dev/null; then
        aputs_info "Interfaz $INTERFAZ_DNS detectada, configurando zona internal..."
    
        # Asignar interfaz DNS a zona internal
        sudo firewall-cmd --permanent --zone=internal --change-interface="$INTERFAZ_DNS" &>/dev/null
        
        # Agregar servicios CRÍTICOS a zona internal
        sudo firewall-cmd --permanent --zone=internal --add-service=dns &>/dev/null
        sudo firewall-cmd --permanent --zone=internal --add-service=ssh &>/dev/null
        sudo firewall-cmd --permanent --zone=internal --add-protocol=icmp &>/dev/null
        
        aputs_success "Zona internal configurada correctamente"
    fi
    
    # Recargar firewall para aplicar cambios de zonas
    sudo firewall-cmd --reload &>/dev/null
    
    echo ""
    
    # Verificación final de zonas
    aputs_info "Verificando zonas activas:"
    sudo firewall-cmd --get-active-zones | sed 's/^/  /'
    
    return 0
}

# Función para liberar puerto 53
liberar_puerto_53() {
    draw_header "Verificar puerto 53"
    
    aputs_info "Verificando conflicto con systemd-resolved..."
    echo ""
    
    if sudo systemctl is-active --quiet systemd-resolved; then
        aputs_warning "systemd-resolved esta usando el puerto 53"
        echo ""
        aputs_info "Para que BIND funcione, systemd-resolved debe detenerse"
        echo ""
        
        local respuesta
        read -rp "¿Desea detener systemd-resolved? (s/n) [s]: " respuesta
        respuesta=${respuesta:-s}
        
        if [[ "$respuesta" == "s" || "$respuesta" == "S" ]]; then
            aputs_info "Deteniendo systemd-resolved..."
            
            sudo systemctl stop systemd-resolved
            sudo systemctl disable systemd-resolved
            
            aputs_success "systemd-resolved detenido y deshabilitado"
            echo ""
            
            # Configurar resolv.conf
            aputs_info "Configurando /etc/resolv.conf..."
            
            sudo rm -f /etc/resolv.conf
            echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf > /dev/null
            echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf > /dev/null
            sudo chattr +i /etc/resolv.conf
            
            aputs_success "Puerto 53 liberado correctamente"
            echo ""
            
            return 0
        else
            aputs_error "No se puede continuar sin liberar el puerto 53"
            echo ""
            aputs_info "BIND no puede iniciar mientras systemd-resolved use el puerto 53"
            return 1
        fi
    else
        aputs_success "systemd-resolved no esta activo - puerto 53 disponible"
        echo ""
        return 0
    fi
}

# Función para iniciar servicio DNS
iniciar_servicio_dns() {
    draw_header "Inicio del servicio DNS"
    
    aputs_info "Iniciando servicio named..."
    
    if sudo systemctl start named; then
        aputs_success "Servicio named iniciado"
        
        # Esperar a que se estabilice
        sleep 2
        
        # Verificar que está activo
        if check_service_active "named"; then
            aputs_success "Servicio named: ACTIVO"
            
            # Mostrar información del servicio
            local pid=$(sudo systemctl show named --property=MainPID --value 2>/dev/null)
            if [[ -n "$pid" && "$pid" != "0" ]]; then
                echo "  PID: $pid"
            fi
            
            return 0
        else
            aputs_error "Servicio named no se inicio correctamente"
            return 1
        fi
    else
        aputs_error "Error al iniciar servicio named"
        echo ""
        aputs_error "Logs de error:"
        sudo journalctl -u named -n 10 --no-pager 2>&1 | sed 's/^/  /'
        return 1
    fi
}

# Función para verificar puertos
verificar_puertos() {
    aputs_info "Verificando puertos en escucha..."
    echo ""
    
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
}

# Función principal de instalación
instalar_config_servicio() {
    clear
    draw_header "Instalar y Configurar Servicio DNS"
    
    # Verificar privilegios
    if ! check_privileges; then
        return 1
    fi
    
    echo ""
    
    # 1 --> Verificar si BIND ya está instalado
    aputs_info "PASO 1: Verificando instalacion existente..."
    echo ""
    
    if verificar_bind_instalado; then
        aputs_warning "BIND ya esta instalado"
        
        local version=$(rpm -q bind 2>/dev/null)
        echo "  Version: $version"
        echo ""
        
        local respuesta
        read -rp "¿Desea continuar con la configuracion? (s/n): " respuesta
        
        if [[ "$respuesta" != "s" && "$respuesta" != "S" ]]; then
            aputs_info "Instalacion cancelada"
            return 0
        fi
        
        # Hacer backup si ya existe configuración
        if [[ -f /etc/named.conf ]]; then
            echo ""
            backup_configuraciones
        fi
    else
        aputs_info "BIND no esta instalado - se procedera con la instalacion"
        echo ""
        
        draw_line
        echo ""
        
        # Instalar BIND
        if ! instalar_bind; then
            return 1
        fi
        
        echo ""
        
        # Habilitar servicio
        habilitar_servicio
    fi
    
    draw_line
    
    # 2 --> Verificar configuración de red
    aputs_info "PASO 2: Verificando configuracion de red..."
    
    if ! verificar_configuracion_red; then
        return 1
    fi
    
    pause
    clear
    
    # 3 --> Solicitar parámetros DNS
    aputs_info "PASO 3: Configuracion de parametros DNS..."
    
    solicitar_parametros_dns
    
    echo ""
    pause
    clear
    
    # 4 --> Configurar named.conf
    aputs_info "PASO 4: Generando configuracion del servidor DNS..."
    echo ""
    
    if ! configurar_named_conf; then
        aputs_error "Error al configurar named.conf"
        return 1
    fi
    
    echo ""
    draw_line
    
    # 5 --> Configurar firewall
    aputs_info "PASO 5: Configurando firewall..."
    
    configurar_firewall
    
    draw_line
    
    # 6 --> Iniciar servicio
    aputs_info "PASO 6: Iniciando servicio DNS..."

    if ! liberar_puerto_53; then
        return 1
    fi
    
    if ! iniciar_servicio_dns; then
        aputs_error "Error al iniciar el servicio"
        return 1
    fi
    
    echo ""
    verificar_puertos
    
    draw_line
    echo ""
    
    aputs_success "Instalacion y Configuracion Completa"
    echo ""
    aputs_info "El servidor DNS esta operativo"
    aputs_info "Puede agregar dominios usando la opcion '6) CRUD Dominios'"
    echo ""
}

# Ejecutar si se llama directamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    instalar_config_servicio
    pause
fi