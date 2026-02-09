
validar_ip(){
    local ip=$1

    if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo ""
        echo "Formato IPv4 Incorrecto. Verifique nuevamente"
        return 1  # formato incorrecto
    fi

    for i in ${ip//./ }; do
        # si algun octeto es mayor a 255 o menor a 0, la IP es incorrecta
        if ((i < 0 || i > 255)); then
            echo ""
            echo "Formato IPv4 Incorrecto. Verifique nuevamente"
            return 1
        fi
    done
    
    echo ""
    echo "Formato IPv4 correcto"
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

instalar_dhcp(){
    echo ""
    echo "Verificando paquete dhcp-server..."
    # dhcp-server es el nombre del paquete en Fedora
    if ! rpm -q dhcp-server &> /dev/null; then
        sudo dnf install -y dhcp-server &> /dev/null
        echo ""
        echo "dhcp-server instalado correctamente"
        return 0
    fi
    echo ""
    echo "dhcp-server ya esta instalado"
    return 0
}

parametros_usuario(){
    echo ""
    echo "Ingrese los siguientes parametros:"

    echo ""
    read -rp "Nombre del Scope: " NOMBRE_SCOPE #
    NOMBRE_SCOPE=${NOMBRE_SCOPE:-RedInterna} #En dado caso de dejar vacio este campo

    while true;do
        echo ""
        read -rp "Segmento de red: " RED
        validar_ip "$RED" && break
    done

    while true;do
        echo ""
        read -rp "Mascara de Red: " MASCARA
        validar_ip "$MASCARA" && break
    done

    while true;do
        echo ""
        read -rp "IP donde inicia el rango del DHCP: " IP_INICIO
        validar_ip "$IP_INICIO" && break
    done

    while true;do
        echo ""
        read -rp "IP donde finaliza el rango del DHCP: " IP_FIN
        validar_ip "$IP_FIN" && break
    done

    while true;do
        echo ""
        read -rp "IP del servidor gateway: " GATEWAY
        validar_ip "$GATEWAY" && break
    done

    while true;do
        echo ""
        read -rp "IP del servidor DNS: " DNS
        validar_ip "$DNS" && break
    done

    # LEASE TIME (Tiempo de concesion)
    while true; do   
    echo ""     
        read -rp "Lease Time -> tiempo en segundos" LEASE_TIME
        # Verificamos que sea un numero positivo
        if [[ "$LEASE_TIME" =~ ^[0-9]+$ ]] && [ "$LEASE_TIME" -gt 0 ]; then
            break
        else
            echo "Debe ser un numero entero positivo"
        fi
    done
}

configurar_interfaz_red(){ # vaina que rectifica que la interfaz de red este correcta (AntiTonotos)
    echo ""
    echo "Configurando interfaz de red con IP estatica..."
    
    # Nombre de la conexión
    local connection_name="dhcp-server-${INTERFAZ_SELECCIONADA}"
    
    # Eliminar conexión anterior si existe
    if nmcli con show "$connection_name" &> /dev/null; then
        echo "Eliminando configuracion anterior..."
        sudo nmcli con delete "$connection_name" &> /dev/null
    fi
    
    # Crear nueva conexión con IP estática
    echo "Creando perfil de red con IP: $RED..."
    
    if sudo nmcli con add \
        type ethernet \
        con-name "$connection_name" \
        ifname "$INTERFAZ_SELECCIONADA" \
        ipv4.method manual \
        ipv4.addresses "${RED}/24" &> /dev/null; then
        
        echo "Perfil de red creado"
    else
        echo "Error al crear perfil de red"
        exit 1
    fi
    
    # Activar conexión
    echo "Activando conexion..."
    if sudo nmcli con up "$connection_name" &> /dev/null; then
        echo "Interfaz configurada con IP: $RED"
    else
        echo "Error al activar interfaz"
        exit 1
    fi
    
    # Esperar a que se aplique la configuración
    sleep 2
    
    # Verificar que la IP se configuró
    echo ""
    echo "Verificando configuracion de red..."
    ip -4 addr show "$INTERFAZ_SELECCIONADA"
}

config_dhcp(){
    echo ""
    echo "Configuracion del servidor DHCP"

    # Este archivo le dice al servicio dhcpd en qué interfaz debe escuchar
    echo ""
    echo "DHCPDARGS=\"$INTERFAZ_SELECCIONADA\"" | sudo tee /etc/sysconfig/dhcpd > /dev/null

    echo ""
    echo "Generando /etc/dhcp/dhcpd.conf "
    
    # Backup del archivo original (si existe y no es un backup anterior)
    #if [ -f /etc/dhcp/dhcpd.conf ] && [ ! -f /etc/dhcp/dhcpd.conf.backup ]; then
        #sudo cp /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf.backup
        #echo ""
        #echo "Backup creado: /etc/dhcp/dhcpd.conf.backup"
    #fi

    # EOF significa "End Of File" (fin de archivo)
    sudo tee /etc/dhcp/dhcpd.conf > /dev/null <<EOF
        authoritative;
        default-lease-time $LEASE_TIME;
        max-lease-time $((LEASE_TIME * 2));

        subnet $RED netmask $MASCARA {
            range $IP_INICIO $IP_FIN;
            option routers $GATEWAY;
            option domain-name-servers $DNS;
            option subnet-mask $MASCARA;
        }
EOF
    echo ""
    echo "Archivo creado exitosamente"

    # Agregar y permitir el servicio DHCP en la zona internal
    if sudo firewall-cmd --permanent --zone=internal --add-service=dhcp &> /dev/null; then
        echo ""
        echo "Servicio DHCP permitido en firewall"
    fi
    
    # Recargar el firewall para aplicar los cambios
    if sudo firewall-cmd --reload &> /dev/null; then
        echo ""
        echo "Firewall reconfigurado correctamente"
    fi
}


iniciar_dhcp(){
    echo ""
    echo "Iniciando servicio DHCP"

    #validacion del archivo de configuracion
    if sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf &> /tmp/dhcpd-test.log; then
        echo ""
        echo "Configuracion valida "
    else
        echo ""
        echo "Error en el archivo de configuracion"
        echo "Detalles del error:"
        cat /tmp/dhcpd-test.log
        exit 1
    fi

    #habilita el servicio 
    echo ""
    echo "Habilitando servicio..."
    sudo systemctl enable dhcpd &> /dev/null

    #inicia o reinicia el servicio
    echo ""
    echo "Iniciando servicio..."

    if sudo systemctl restart dhcpd; then
        echo ""
        echo "Servicio DHCP iniciado correctamente"
    else
        echo ""
        echo "Fallo el inicio del servicio"
        echo "Revisando logs..."
        sudo journalctl -u dhcpd -n 20 --no-pager
        exit 1
    fi
}

monitoreo_info(){
    echo ""
    echo "============================" 
    echo "Informacion de Monitoreo:"
    echo "============================" 
    echo ""
    echo "Estado del servicio:"
    sudo systemctl status dhcpd --no-pager | head -n 15
    echo ""
    echo "Configuracion de red actual:"
    ip -4 addr show "$INTERFAZ_SELECCIONADA" | grep -E "inet |$INTERFAZ_SELECCIONADA"
    echo ""
    echo "-------------------------"
    echo ""
    echo "Concesiones (leases) activas:"
    if [ -f /var/lib/dhcpd/dhcpd.leases ]; then
        # se muestra solo las líneas que contienen "lease" (las IPs asignadas)
        sudo grep "^lease" /var/lib/dhcpd/dhcpd.leases | tail -n 10
        
        local lease_count=$(sudo grep -c "^lease" /var/lib/dhcpd/dhcpd.leases 2>/dev/null || echo "0")
        echo ""
        echo "Total de concesiones registradas: $lease_count"
    else
        echo "Aún no hay concesiones activas (el archivo dhcpd.leases aún no existe)"
    fi
    echo ""
}

main(){
    instalar_dhcp
    deteccion_interfaces_red
    parametros_usuario
    configurar_interfaz_red
    config_dhcp
    iniciar_dhcp
    monitoreo_info
}

main