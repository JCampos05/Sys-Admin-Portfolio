#
#   Variables Globales
#
INTERFACES=()
INTERFAZ_SELECCIONADA=""
NOMBRE_SCOPE=""
RED=""
MASCARA=""
BITS_MASCARA=0
IP_INICIO=""
IP_FIN=""
GATEWAY=""
DNS=""
LEASE_TIME=0
#
#   Funciones de Validacion de IP
#
# Valida el formato basico de IPv4
validar_formato_ip(){
    local ip=$1

    # Verifica que tenga el patron correcto: numero.numero.numero.numero
    if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    # Verifica que cada octeto este en el rango 0-255
    local octeto
    for octeto in ${ip//./ }; do
        if ((octeto < 0 || octeto > 255)); then
            return 1
        fi
    done
    
    return 0
}

# Valida que la IP sea usable -> no reservada ej -> 127.0.0.0 -> 0.0.0.0
validar_ip_usable(){
    local ip=$1
    
    # Primero validar el formato
    if ! validar_formato_ip "$ip"; then
        echo "Error: Formato IPv4 incorrecto"
        return 1
    fi
    
    # Extrae los octetos de la IP
    IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$ip"
    
    # Valida IPs reservadas que NO son usables
    
    # 1. Red 0.0.0.0/8 
    if [ "$oct1" -eq 0 ]; then
        echo "Error: La red 0.0.0.0/8 es reservada -> No utilizable"
        return 1
    fi
    
    # Red 127.0.0.0/8 
    if [ "$oct1" -eq 127 ]; then
        echo "Error: La red 127.0.0.0/8 (localhost)"
        return 1
    fi
    
    # 3. IP de broadcast
    if [ "$oct1" -eq 255 ] && [ "$oct2" -eq 255 ] && [ "$oct3" -eq 255 ] && [ "$oct4" -eq 255 ]; then
        echo "Error: 255.255.255.255 es direccion de broadcast"
        return 1
    fi
    
    # 4. Redes multicast 224.0.0.0/4
    if [ "$oct1" -ge 224 ] && [ "$oct1" -le 239 ]; then
        echo "Error: Redes 224.0.0.0 a 239.255.255.255 son multicast"
        return 1
    fi
    
    # 5. Redes experimentales 240.0.0.0/4
    if [ "$oct1" -ge 240 ] && [ "$oct1" -le 255 ]; then
        echo "Error: Redes 240.0.0.0 a 255.255.255.255 son experimentales"
        return 1
    fi
    
    return 0
}

# Calcula -> mascara de subred 
calcular_mascara(){
    local ip=$1
    
    IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$ip"
    
    # Determinar la clase de red y asignar mascara por defecto
    # Clase A: 1.0.0.0 a 126.0.0.0 -> Mascara /8 (255.0.0.0)
    # Clase B: 128.0.0.0 a 191.255.0.0 -> Mascara /16 (255.255.0.0)
    # Clase C: 192.0.0.0 a 223.255.255.0 -> Mascara /24 (255.255.255.0)
    
    if [ "$oct1" -ge 1 ] && [ "$oct1" -le 126 ]; then
        # Clase A
        MASCARA="255.0.0.0"
        BITS_MASCARA=8
        echo "Clase A detectada - Mascara: $MASCARA (/8)"
        
    elif [ "$oct1" -ge 128 ] && [ "$oct1" -le 191 ]; then
        # Clase B
        MASCARA="255.255.0.0"
        BITS_MASCARA=16
        echo "Clase B detectada - Mascara: $MASCARA (/16)"
        
    elif [ "$oct1" -ge 192 ] && [ "$oct1" -le 223 ]; then
        # Clase C
        MASCARA="255.255.255.0"
        BITS_MASCARA=24
        echo "Clase C detectada - Mascara: $MASCARA (/24)"
        
    else
        echo "Error: No se pudo determinar clase de red"
        return 1
    fi
    
    # Calcula cantidad de IPs usables
    # Formula: 2^(32-bits_mascara) - 2
    # Resta 2 -> primera IP es la de red y la ultima es broadcast
    local hosts_bits=$((32 - BITS_MASCARA))
    local ips_totales=$((2 ** hosts_bits))
    local ips_usables=$((ips_totales - 2))
    
    echo "IPs totales: $ips_totales"
    echo "IPs usables: $ips_usables (excluyendo red y broadcast)"
    
    return 0
}

# Convierte la IP a numero entero (para comparaciones)
ip_a_numero(){
    local ip=$1
    IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$ip"
    echo $((oct1 * 256**3 + oct2 * 256**2 + oct3 * 256 + oct4))
}

# Obtiene la IP de red a partir de IP y mascara
obtener_ip_red(){
    local ip=$1
    local mascara=$2
    
    IFS='.' read -r ip1 ip2 ip3 ip4 <<< "$ip"
    IFS='.' read -r m1 m2 m3 m4 <<< "$mascara"
    
    # AND bit a bit entre IP y mascara
    local red1=$((ip1 & m1))
    local red2=$((ip2 & m2))
    local red3=$((ip3 & m3))
    local red4=$((ip4 & m4))
    
    echo "$red1.$red2.$red3.$red4"
}

# Valida que una IP pertenezca al mismo segmento
validar_mismo_segmento(){
    local ip_base=$1
    local ip_comparar=$2
    local mascara=$3
    
    # Obtene la red de ambas IPs
    local red_base=$(obtener_ip_red "$ip_base" "$mascara")
    local red_comparar=$(obtener_ip_red "$ip_comparar" "$mascara")
    
    # Compara si pertenecen a la misma red
    if [ "$red_base" != "$red_comparar" ]; then
        echo "Error: La IP $ip_comparar no pertenece al segmento $red_base"
        return 1
    fi
    
    return 0
}

#Valida que IP inicial sea menor que IP final
validar_rango_ips(){
    local ip_inicio=$1
    local ip_fin=$2
    
    # Convierte las IPs completas a numeros para comparar
    local num_inicio=$(ip_a_numero "$ip_inicio")
    local num_fin=$(ip_a_numero "$ip_fin")
    
    # Compara los valores numericos de las IPs 
    if [ "$num_inicio" -ge "$num_fin" ]; then
        echo "Error: La IP inicial debe ser menor que la IP final"
        echo "IP Inicial: $ip_inicio (valor: $num_inicio)"
        echo "IP Final: $ip_fin (valor: $num_fin)"
        return 1
    fi

    return 0
}

# Valida que las IPs no sean direccion de red ni broadcast
validar_ip_no_especial(){
    local ip=$1
    local red=$2
    local mascara=$3
    
    # Calcular IP de broadcast
    IFS='.' read -r r1 r2 r3 r4 <<< "$red"
    IFS='.' read -r m1 m2 m3 m4 <<< "$mascara"
    
    # Broadcast 
    local b1=$(((r1 & m1) | (255 - m1)))
    local b2=$(((r2 & m2) | (255 - m2)))
    local b3=$(((r3 & m3) | (255 - m3)))
    local b4=$(((r4 & m4) | (255 - m4)))
    
    local broadcast="$b1.$b2.$b3.$b4"
    
    # Verifica que no sea la IP de red
    if [ "$ip" = "$red" ]; then
        echo "Error: No puede usar la IP de red ($red)"
        return 1
    fi
    
    # Verifica que no sea la IP de broadcast
    if [ "$ip" = "$broadcast" ]; then
        echo "Error: No puede usar la IP de broadcast ($broadcast)"
        return 1
    fi
    
    return 0
}
#
#   Funciones de Deteccion y Configuracion
#
deteccion_interfaces_red(){
    mapfile -t INTERFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo")

    if [ "${#INTERFACES[@]}" -eq 0 ]; then
        echo ""
        echo "No se detectaron interfaces de red"
        exit 1
    fi

    echo ""
    echo "Interfaces de red detectadas:"
    
    for i in "${!INTERFACES[@]}"; do
        local iface="${INTERFACES[$i]}"
        local current_ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[^/]+' || echo "Sin IP")
        echo ""
        printf "  %d) %-10s (IP actual: %s)\n" $((i+1)) "$iface" "$current_ip"
    done
    echo ""

    while true; do
        read -rp "Seleccione el numero de la interfaz para DHCP [1-${#INTERFACES[@]}]: " selection
        
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
#   Funciones semi principales -> usadas por las principales
#
parametros_usuario(){
    echo ""
    echo "-------------------------------"
    echo " Configuracion de parametros"
    echo "--------------------------------"

    echo ""
    read -rp "Nombre del Scope: " NOMBRE_SCOPE
    NOMBRE_SCOPE=${NOMBRE_SCOPE:-RedInterna}

    # Solicita y valida segmento de red
    while true; do
        echo ""
        echo "Ingrese el segmento de red (ej: 192.168.100.0)"
        read -rp "Segmento de red: " RED
        
        echo ""
        # 1 -> Validar formato
        if ! validar_formato_ip "$RED"; then
            echo "Formato de IP invalido"
            continue
        fi
        
        # 2 -> Validar que sea usable
        if ! validar_ip_usable "$RED"; then
            continue
        fi
        
        # 3 -> Calcular mascara automatica
        if ! calcular_mascara "$RED"; then
            continue
        fi
        
        # 4 -> Obtener la IP de red real
        RED=$(obtener_ip_red "$RED" "$MASCARA")
        echo ""
        echo "Segmento de red aceptado: $RED"
        break
    done

    # Solicita y valida IP inicial del rango DHCP
    while true; do
        echo ""
        echo "Ingrese la IP donde INICIa el rango DHCP"
        echo "Debe pertenecer al segmento: $RED/$BITS_MASCARA"
        echo "Debe ser MAYOR que: $RED"
        read -rp "IP Inicial: " IP_INICIO
        
        echo ""
        # 1 -> Validar formato
        if ! validar_formato_ip "$IP_INICIO"; then
            echo "Formato invalido"
            continue
        fi
        
        # 2 -> Validar que pertenezca al mismo segmento
        if ! validar_mismo_segmento "$RED" "$IP_INICIO" "$MASCARA"; then
            continue
        fi
        
        # 3 -> Validar que no sea IP de red ni broadcast
        if ! validar_ip_no_especial "$IP_INICIO" "$RED" "$MASCARA"; then
            continue
        fi
        
        echo "IP Inicial aceptada: $IP_INICIO"
        break
    done

    # Solicita y valida IP final del rango DHCP
    while true; do
        echo ""
        echo "Ingrese la IP donde FINALIZa el rango DHCP"
        echo "Debe pertenecer al segmento: $RED/$BITS_MASCARA"
        echo "Debe ser MAYOR que: $IP_INICIO"
        read -rp "IP Final: " IP_FIN
        
        echo ""
        # 1 -> Validar formato
        if ! validar_formato_ip "$IP_FIN"; then
            echo "Formato invalido"
            continue
        fi
        
        # 2 -> Validar que pertenezca al mismo segmento
        if ! validar_mismo_segmento "$RED" "$IP_FIN" "$MASCARA"; then
            continue
        fi
        
        # 3 -> Validar que no sea IP de red ni broadcast
        if ! validar_ip_no_especial "$IP_FIN" "$RED" "$MASCARA"; then
            continue
        fi
        
        # 4 -> ✅ VALIDACION CORREGIDA - Compara IPs completas
        if ! validar_rango_ips "$IP_INICIO" "$IP_FIN"; then
            continue
        fi
        
        echo "IP Final aceptada: $IP_FIN"
        break
    done

    # Solicita y valida Gateway
    while true; do
        echo ""
        echo "Ingrese la IP del Gateway (puerta de enlace)"
        echo "Debe pertenecer al segmento: $RED/$BITS_MASCARA"
        read -rp "Gateway: " GATEWAY
        
        echo ""
        # 1 -> Validar formato
        if ! validar_formato_ip "$GATEWAY"; then
            echo "Formato invalido"
            continue
        fi
        
        # 2 -> Validar que pertenezca al mismo segmento
        if ! validar_mismo_segmento "$RED" "$GATEWAY" "$MASCARA"; then
            continue
        fi
        
        # 3 -> Validar que no sea IP de red ni broadcast
        if ! validar_ip_no_especial "$GATEWAY" "$RED" "$MASCARA"; then
            continue
        fi
        
        echo "Gateway aceptado: $GATEWAY"
        break
    done

    # Solicita y valida DNS
    while true; do
        echo ""
        echo "Ingrese la IP del servidor DNS"
        read -rp "DNS: " DNS
        
        echo ""
        # Solo validar formato, el DNS puede estar en cualquier red
        if ! validar_formato_ip "$DNS"; then
            echo "Formato invalido"
            continue
        fi
        
        echo "DNS aceptado: $DNS"
        break
    done

    # Solicita y valida tiempo de concesion
    while true; do
        echo ""
        echo "Ingrese el tiempo de concesion en segundos"
        echo "Ejemplos: 3600 (1 hora), 86400 (1 dia), 604800 (1 semana)"
        read -rp "Tiempo de concesion: " LEASE_TIME
        
        # Validar que sea un numero positivo
        if [[ "$LEASE_TIME" =~ ^[0-9]+$ ]] && [ "$LEASE_TIME" -gt 0 ]; then
            # Mostrar tiempo en formato legible
            local hours=$((LEASE_TIME / 3600))
            local days=$((hours / 24))
            
            if [ "$days" -gt 0 ]; then
                echo "Tiempo aceptado: $LEASE_TIME segundos ($days dias)"
            elif [ "$hours" -gt 0 ]; then
                echo "Tiempo aceptado: $LEASE_TIME segundos ($hours horas)"
            else
                echo "Tiempo aceptado: $LEASE_TIME segundos"
            fi
            break
        else
            echo "Error: Debe ingresar un numero positivo"
        fi
    done
}

configurar_interfaz_red(){
    echo ""
    echo "-------------------------------"
    echo " Configuracion de Interfaz de Red"
    echo "-------------------------------"
    echo ""
    
    # Calcula la IP del servidor (primera IP usable del segmento)
    IFS='.' read -r r1 r2 r3 r4 <<< "$RED"
    local server_ip="$r1.$r2.$r3.$((r4 + 1))"
    
    echo "Configurando interfaz $INTERFAZ_SELECCIONADA con IP: $server_ip/$BITS_MASCARA"
    
    # Crea archivo de configuracion de NetworkManager
    local nm_config="/etc/NetworkManager/system-connections/$INTERFAZ_SELECCIONADA.nmconnection"
    
    sudo tee "$nm_config" > /dev/null <<EOF
[connection]
id=$INTERFAZ_SELECCIONADA
uuid=$(uuidgen)
type=ethernet
interface-name=$INTERFAZ_SELECCIONADA

[ipv4]
method=manual
address1=$server_ip/$BITS_MASCARA
EOF

    # Establece permisos correctos
    sudo chmod 600 "$nm_config"
    
    # Reinicia NetworkManager y activa la interfaz
    echo ""
    echo "Aplicando configuracion de red..."
    sudo systemctl restart NetworkManager
    sleep 2
    
    sudo nmcli connection up "$INTERFAZ_SELECCIONADA" &> /dev/null
    
    # Verifica la configuracion
    local current_ip=$(ip -4 addr show "$INTERFAZ_SELECCIONADA" | grep -oP 'inet \K[^/]+')
    
    if [ "$current_ip" = "$server_ip" ]; then
        echo "Configuracion aplicada correctamente"
        echo "IP actual: $current_ip"
    else
        echo "Advertencia: La IP configurada no coincide"
        echo "Esperada: $server_ip"
        echo "Actual: $current_ip"
    fi
}

config_dhcp(){
    echo ""
    echo "-----------------------------------"
    echo " Configuracion del Servicio DHCP"
    echo "-----------------------------------"
    echo ""
    
    local dhcp_conf="/etc/dhcp/dhcpd.conf"
    
    # Hacer backup del archivo original si existe
    if [ -f "$dhcp_conf" ]; then
        echo "Creando backup de configuracion anterior..."
        sudo cp "$dhcp_conf" "${dhcp_conf}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Crear nueva configuracion
    echo "Generando archivo de configuracion..."
    sudo tee "$dhcp_conf" > /dev/null <<EOF
# Configuracion generada automaticamente
# Scope: $NOMBRE_SCOPE
# Fecha: $(date)

# Configuracion global
default-lease-time $LEASE_TIME;
max-lease-time $((LEASE_TIME * 2));
authoritative;

# Scope: $NOMBRE_SCOPE
subnet $RED netmask $MASCARA {
    range $IP_INICIO $IP_FIN;
    option routers $GATEWAY;
    option domain-name-servers $DNS;
    option subnet-mask $MASCARA;
}
EOF
    
    echo "Archivo de configuracion creado en: $dhcp_conf"
    echo ""
    echo "Resumen de la configuracion:"
    echo "  - Scope: $NOMBRE_SCOPE"
    echo "  - Red: $RED/$BITS_MASCARA"
    echo "  - Rango: $IP_INICIO - $IP_FIN"
    echo "  - Gateway: $GATEWAY"
    echo "  - DNS: $DNS"
    echo "  - Tiempo de concesion: $LEASE_TIME segundos"
}

iniciar_dhcp(){
    echo ""
    echo "-----------------------------------"
    echo " Iniciando Servicio DHCP"
    echo "-----------------------------------"
    echo ""
    
    # Habilita el servicio para inicio automatico
    echo "Habilitando servicio para inicio automatico..."
    sudo systemctl enable dhcpd &> /dev/null
    
    # Reinicia el servicio
    echo "Iniciando servicio DHCP..."
    sudo systemctl restart dhcpd
    
    sleep 2
    
    # Verifica el estado
    if sudo systemctl is-active dhcpd &> /dev/null; then
        echo ""
        echo "Servicio DHCP iniciado correctamente"
        echo ""
        sudo systemctl status dhcpd --no-pager -l
    else
        echo ""
        echo "Fallo el inicio del servicio. Logs:"
        sudo journalctl -u dhcpd -n 20 --no-pager
        exit 1
    fi
}
#
#   Monitor tiempo real
#
monitoreo_info(){
    echo ""
    echo " Informacion de Monitoreo DHCP"
    echo ""
    
    echo "Estado del servicio:"
    echo "--------------------"
    local service_status=$(sudo systemctl is-active dhcpd)
    if [ "$service_status" == "active" ]; then
        echo "Servicio: ACTIVO"
    else
        echo "Servicio: $service_status"
    fi
    echo ""
    
    echo ""
    echo "Configuracion de red:"
    echo "---------------------"
    echo "Interfaz: $INTERFAZ_SELECCIONADA"
    ip -4 addr show "$INTERFAZ_SELECCIONADA" 2>/dev/null | grep "inet " | awk '{print "IP: " $2}'
    echo ""
    
    echo ""
    echo "Concesiones activas:"
    echo "--------------------"
    if [ -f /var/lib/dhcpd/dhcpd.leases ]; then
        local unique_leases=$(sudo awk '/^lease/ {ip=$2} /binding state active/ {print ip}' /var/lib/dhcpd/dhcpd.leases | sort -u)
        
        if [ -n "$unique_leases" ]; then
            echo "$unique_leases" | while read ip; do
                echo "  - $ip"
            done
            
            local count=$(echo "$unique_leases" | wc -l)
            echo ""
            echo "Total de clientes conectados: $count"
        else
            echo "Sin concesiones activas"
        fi
    else
        echo "Sin concesiones activas"
    fi
    
    echo ""    
    echo "Presiona Ctrl+C para salir del monitoreo"
    echo ""
}
#
#   Funciones del Menu Principal
#
verificar_instalacion(){
    echo ""
    echo "Verificando instalacion del servicio DHCP..."
    echo ""
    
    if rpm -q dhcp-server &> /dev/null; then
        echo "Estado: INSTALADO"
        echo ""
        rpm -qi dhcp-server | grep -E "Name|Version|Release|Install Date"
        echo ""
        
        if systemctl is-enabled dhcpd &> /dev/null; then
            echo "Servicio: HABILITADO"
        else
            echo "Servicio: NO HABILITADO"
        fi
        
        if systemctl is-active dhcpd &> /dev/null; then
            echo "Estado: ACTIVO"
        else
            echo "Estado: INACTIVO"
        fi
    else
        echo "Estado: NO INSTALADO"
        echo ""
        read -rp "Desea instalar el servicio ahora? (s/n): " respuesta
        
        if [[ "$respuesta" =~ ^[Ss]$ ]]; then
            echo ""
            echo "Iniciando instalacion..."
            
            if sudo dnf install -y dhcp-server &> /dev/null; then
                echo "Instalacion finalizada correctamente"
            else
                echo "Error: Fallo la instalacion del servicio"
                echo "Verifique su conexion a internet y repositorios"
            fi
        else
            echo "Instalacion cancelada"
        fi
    fi
}

instalar_servicio(){
    echo ""
    echo "-----------------------------------"
    echo "  Proceso de Instalacion Completo"
    echo "-----------------------------------"
    echo ""
    echo "Este proceso instalara y configurara el servidor DHCP"
    echo ""
    
    # Verifica si ya esta instalado
    if rpm -q dhcp-server &> /dev/null; then
        echo "El servicio ya esta instalado"
        echo ""
        read -rp "Desea reconfigurar el servicio? (s/n): " reconfig
        
        if [[ ! "$reconfig" =~ ^[Ss]$ ]]; then
            echo "Operacion cancelada"
            return 0
        fi
    else
        # Servicio NO instalado, confirmar instalacion
        read -rp "Desea instalar el servicio DHCP? (s/n): " respuesta
        
        if [[ ! "$respuesta" =~ ^[Ss]$ ]]; then
            echo "Instalacion cancelada"
            return 0
        fi
        
        echo ""
        echo "Iniciando instalacion..."
        
        # Instalacion SILENCIOSA
        if sudo dnf install -y dhcp-server &> /dev/null; then
            echo "Instalacion finalizada correctamente"
            echo ""
        else
            echo "Error: Fallo la instalacion del servicio"
            echo "Verifique su conexion a internet y repositorios"
            return 1
        fi
    fi
    
    # Configuracion completa ->
    echo "Procediendo con la configuracion..."
    echo ""
    
    deteccion_interfaces_red
    parametros_usuario
    configurar_interfaz_red
    config_dhcp
    iniciar_dhcp
    
    echo ""
    echo "--------------------------------"
    echo "Instalacion y configuracion completadas"
    echo "El servicio DHCP esta activo y funcionando"
    echo "--------------------------------"
}

nueva_configuracion(){
    echo ""
    echo "--------------------------------"
    echo "  NUEVA CONFIGURACION DHCP"
    echo "--------------------------------"
    echo ""
    echo "Esta opcion permite reconfigurar un servidor DHCP ya instalado."
    echo "Si existe una configuracion previa, sera reemplazada."
    echo ""
    echo "Nota: Si el servicio no esta instalado, use la opcion 2"
    echo ""
    read -rp "Desea continuar? (s/n): " respuesta
    
    if [[ ! "$respuesta" =~ ^[Ss]$ ]]; then
        echo "Configuracion cancelada"
        return 0
    fi
    
    echo ""
    echo "Verificando instalacion del servicio..."
    
    if ! rpm -q dhcp-server &> /dev/null; then
        echo ""
        echo "Error: El servicio DHCP no esta instalado"
        echo ""
        echo "Por favor, use la opcion 2 del menu para instalar y configurar"
        echo "el servicio por primera vez."
        return 0
    fi
    
    echo ""
    echo "Iniciando reconfiguracion..."
    
    deteccion_interfaces_red
    parametros_usuario
    configurar_interfaz_red
    config_dhcp
    iniciar_dhcp
    
    echo ""
    echo "------------------------------------------"

    echo "Reconfiguracion completada exitosamente"
    echo "------------------------------------------"
}

reiniciar_servicio(){
    echo "--------------------------------"
    echo "Reiniciando servicio DHCP..."
    echo "--------------------------------"

    
    if ! rpm -q dhcp-server &> /dev/null; then
        echo "Error: El servicio no esta instalado"
        return 1
    fi
    
    if sudo systemctl restart dhcpd; then
        echo "Servicio reiniciado correctamente"
        echo ""
        sudo systemctl status dhcpd --no-pager -l
    else
        echo "Error al reiniciar el servicio"
        echo ""
        sudo journalctl -u dhcpd -n 30 --no-pager
    fi
}

ver_configuracion_actual(){
    echo ""
    echo "------------------------------------"
    echo " Configuracion Actual del Servidor"
    echo "------------------------------------"
    echo ""
    
    # Verificar si el servicio esta instalado
    if ! rpm -q dhcp-server &> /dev/null; then
        echo "El servicio DHCP no esta instalado"
        return 1
    fi
    
    echo "1. Estado del Servicio:"
    echo "----------------------"
    if systemctl is-active dhcpd &> /dev/null; then
        echo "Estado: ACTIVO"
    else
        echo "Estado: INACTIVO"
    fi
    
    if systemctl is-enabled dhcpd &> /dev/null; then
        echo "Inicio automatico: HABILITADO"
    else
        echo "Inicio automatico: DESHABILITADO"
    fi
    echo ""
    
    # Leer configuracion del archivo dhcpd.conf
    echo "2. Configuracion DHCP:"
    echo "---------------------"
    if [ -f /etc/dhcp/dhcpd.conf ]; then
        # Extraer subnet
        local subnet=$(sudo grep -oP 'subnet \K[0-9.]+' /etc/dhcp/dhcpd.conf | head -1)
        echo "Segmento de red: $subnet"
        
        # Extraer netmask
        local netmask=$(sudo grep -oP 'netmask \K[0-9.]+' /etc/dhcp/dhcpd.conf | head -1)
        echo "Mascara: $netmask"
        
        # Extraer range
        local range=$(sudo grep -oP 'range \K[0-9. ]+' /etc/dhcp/dhcpd.conf | head -1)
        echo "Rango: $range"
        
        # Extraer gateway (routers)
        local gateway=$(sudo grep -oP 'option routers \K[0-9.]+' /etc/dhcp/dhcpd.conf | head -1)
        echo "Gateway: $gateway"
        
        # Extraer DNS
        local dns=$(sudo grep -oP 'option domain-name-servers \K[0-9.]+' /etc/dhcp/dhcpd.conf | head -1)
        echo "DNS: $dns"
        
        # Extraer lease time
        local lease=$(sudo grep -oP 'default-lease-time \K[0-9]+' /etc/dhcp/dhcpd.conf | head -1)
        echo "Lease Time: $lease segundos"
    else
        echo "Archivo de configuracion no encontrado"
    fi
    echo ""
    
    # Interfaz configurada
    echo "3. Interfaz de Red:"
    echo "------------------"
    if [ -f /etc/sysconfig/dhcpd ]; then
        local iface=$(sudo grep -oP 'DHCPDARGS="\K[^"]+' /etc/sysconfig/dhcpd)
        echo "Interfaz: $iface"
        
        if [ -n "$iface" ]; then
            local ip_actual=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[^/]+' | head -1)
            echo "IP del servidor: $ip_actual"
        fi
    else
        echo "No configurado"
    fi
    echo ""
    
    # Estadisticas de concesiones
    echo "4. Estadisticas:"
    echo "---------------"
    if [ -f /var/lib/dhcpd/dhcpd.leases ]; then
        local total_leases=$(sudo grep -c "^lease" /var/lib/dhcpd/dhcpd.leases 2>/dev/null || echo "0")
        local active_leases=$(sudo awk '/^lease/ {ip=$2} /binding state active/ {print ip}' /var/lib/dhcpd/dhcpd.leases | sort -u | wc -l)
        
        echo "Concesiones totales registradas: $total_leases"
        echo "Concesiones activas: $active_leases"
    else
        echo "Sin concesiones registradas"
    fi
    echo ""
}

modo_monitor(){
    echo ""
    echo "Iniciando modo monitor..."
    echo "Presiona Ctrl+C para salir"
    echo ""
    sleep 2
    
    while true; do
        clear
        monitoreo_info
        sleep 5
    done
}

#
#   Menu Principal
#

main_menu() {
    while true; do
        clear
        echo ""
        echo "--------------------------------"
        echo "  Gestor de Servicio DHCP"
        echo "--------------------------------"
        echo ""
        echo "Seleccione una opcion:"
        echo ""
        echo "1) Verificar instalacion"
        echo "2) Instalar servicio"
        echo "3) Nueva configuracion"
        echo "4) Reiniciar servicio"
        echo "5) Monitor de concesiones"
        echo "6) Configuracion actual"
        echo "7) Salir"
        echo ""
        read -rp "Opcion: " OP

        case $OP in
        1)
            verificar_instalacion
            ;;
        2)
            instalar_servicio
            ;;
        3)
            nueva_configuracion
            ;;
        4)
            reiniciar_servicio
            ;;
        5) 
            modo_monitor
            ;;
        6)
            ver_configuracion_actual
            ;;
        7)
            echo ""
            echo "Saliendo del programa..."
            exit 0
            ;;
        *)
            echo ""
            echo "Error: Opcion invalida"
            ;;
        esac
        echo ""
        read -rp "Presiona Enter para continuar..."
    done
}
#
#   Punto de Entrada Principal
#
main_menu