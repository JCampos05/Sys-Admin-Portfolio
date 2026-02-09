#
#
#   Funciones Auxiliares
#
validar_ip(){
    local ip=$1

    if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1  # formato incorrecto
    fi

    for i in ${ip//./ }; do
        # si algún octeto es mayor a 255 o menor a 0, la IP es incorrecta
        if ((i < 0 || i > 255)); then
            return 1
        fi
    done
    
    return 0  # IP correcta
}


deteccion_interfaces_red(){
    mapfile -t INTERFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo")

    # Validacion de haber encontrado o no interfaces
    if [ "${#INTERFACES[@]}" -eq 0 ]; then
        echo ""
        echo "No se detectaron interfaces de red"
        exit 1
    fi

    echo ""
    echo "Interfaces de red detectadas:"
    
    # Mostrar interfaces con numero
    for i in "${!INTERFACES[@]}"; do
        local iface="${INTERFACES[$i]}"
        local current_ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[^/]+' || echo "Sin IP")
        echo ""
        printf "  %d) %-10s (IP actual: %s)\n" $((i+1)) "$iface" "$current_ip"
    done
    echo ""

    # Solicitar seleccion de interfaz
    while true; do
        read -rp "Seleccione el numero de la interfaz para DHCP [1-${#INTERFACES[@]}]: " selection
        
        # Validar que sea un numero en el rango correcto
        if [[ "$selection" =~ ^[0-9]+$ ]] && 
           [ "$selection" -ge 1 ] && 
           [ "$selection" -le "${#INTERFACES[@]}" ]; then
            INTERFAZ_SELECCIONADA="${INTERFACES[$((selection-1))]}"
            break
        else
            echo "Seleccion invalida. Ingrese un numero entre 1 y ${#INTERFACES[@]}"
        fi
    done
    
    echo ""
    echo "Interfaz de red seleccionada: $INTERFAZ_SELECCIONADA"
}
#
#   funciones principales del menu
#
config_intercaz_red(){
    deteccion_interfaces_red

    local connection_name="dhcp-client-${INTERFAZ_SELECCIONADA}"

    # Eliminar conexión anterior si existe
    if nmcli con show "$connection_name" &> /dev/null; then
        echo ""
        echo "Eliminando configuración anterior..."
        sudo nmcli con delete "$connection_name" &> /dev/null
    fi

    # Crear conexión DHCP
    # ipv4.method auto = obtener IP automáticamente por DHCP
    if sudo nmcli con add \
        type ethernet \
        con-name "$connection_name" \
        ifname "$INTERFAZ_SELECCIONADA" \
        ipv4.method auto \
        &> /dev/null; then
        
        echo ""
        echo "Perfil DHCP creado"
    else
        echo ""
        echo "Fallo la creación del perfil"
        return
    fi

    # actibvar la nueva conexion
    if sudo nmcli con up "$connection_name" &> /dev/null; then
        echo ""
        echo "Conexion activada"
        sleep 3
    else
        echo ""
        echo "Error al iniciar la conexion"
    fi
}

renovar_release() {
    echo ""
    echo "Sistema de renovacion de concesión DHCP"

    deteccion_interfaces_red
    
    local connection_name="dhcp-client-${INTERFAZ_SELECCIONADA}"
    
    echo ""
    echo "Liberando IP actual..."
    
    # Usar NetworkManager en lugar de dhclient
    # Desactivar la conexión (release)
    sudo nmcli con down "$connection_name" 2>/dev/null || true
    sleep 2

    echo ""
    echo "Solicitando nueva IP..."
    
    # Reactivar la conexión (renew)
    if sudo nmcli con up "$connection_name" 2>/dev/null; then
        sleep 3
        
        # Verificar nueva IP (VARIABLE CORREGIDA)
        local new_ip=$(ip -4 addr show "$INTERFAZ_SELECCIONADA" | grep -oP 'inet \K[^/]+')
        
        if [ -n "$new_ip" ]; then
            echo ""
            echo "Nueva IP obtenida: $new_ip"
            echo ""
            echo "Detalles de la interfaz:"
            ip -4 addr show "$INTERFAZ_SELECCIONADA"
        else
            echo ""
            echo "No se pudo renovar la concesión"
        fi
    else
        echo ""
        echo "Error: No se pudo renovar la conexión"
        echo "Asegúrese de haber configurado primero la interfaz (Opción 1)"
    fi
}

estatus_red(){
    echo ""
    echo "Estatus de la red"
    
    echo "interfaces de red y direcciones IP:"
    echo ""
    ip -4 -br addr show | grep -v "lo"
    
    echo ""
    echo "Ruta por defecto (Gateway):"
    ip route show | grep "default" || echo "No hay gateway configurado"
    
    echo ""
    echo "Servidores DNS configurados:"
    cat /etc/resolv.conf | grep "nameserver" || echo "No hay DNS configurados"
    
    echo ""
}


conectividad(){
    echo ""
    
    while true;do
        echo ""
        read -rp "Ingrese la IP del servidor DHCP [192.168.100.1]: " SERVER_IP
        validar_ip "$SERVER_IP" && break
    done
    
    echo ""
    print_info "Realizando ping a $SERVER_IP (4 paquetes)..."
    echo ""
    
    if ping -c 4 "$SERVER_IP"; then
        echo ""
        print_success "Conexión exitosa con el servidor $SERVER_IP"
    else
        echo ""
        print_error "No se pudo conectar con $SERVER_IP"
        print_warning "Verifica que ambos equipos estén en la misma red"
    fi
}


main_menu(){
    while true; do
        clear
        echo ""
        echo "Bienvenido..."
        echo "Sistema de pruebas y config DHCP"
        echo ""

        echo "Seleccione una opcion: "
        echo ""
        echo "  1) Configurar interfaz para recibir IP por DHCP"
        echo "  2) Renovar concesión DHCP (release + renew)"
        echo "  3) Ver estado actual de la red"
        echo "  4) Probar conectividad con el servidor"
        echo "  5) Salir"
        echo ""
        read -rp "Opcion: " OP

        case $OP in
        1)
            config_intercaz_red
            ;;
        2)
            renovar_release
            ;;
        3)
            estatus_red
            ;;
        4)
            conectividad
            ;;
        5)
            exit 0
            ;;
        *)
            echo "Error. Seleccione una opcion valida."
            ;;
        esac
        echo ""
        read -rp "Presiona Enter para continuar..."
    done
}

main_menu