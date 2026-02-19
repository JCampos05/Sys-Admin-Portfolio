#!/bin/bash
#
#   Gestor de Servicio DHCP
#
#   Requiere:
#       utils.sh      -> funciones de salida formateada y utilidades comunes
#       validators.sh -> validaciones de IP, mascara y calculo de subred con ipcalc
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/validators.sh"
#
#   Variables Globales
#
INTERFACES=()
INTERFAZ_SELECCIONADA=""
NOMBRE_SCOPE=""
RED=""
MASCARA=""
BITS_MASCARA=0
IP_SERVIDOR=""        # IP que se asignara al servidor (estatica)
IP_INICIO=""          # Primera IP del rango de clientes
IP_FIN=""             # Ultima IP del rango de clientes
GATEWAY=""            # Gateway (Opcional)
DNS_PRIMARIO=""       # DNS Primario (Opcional)
DNS_SECUNDARIO=""     # DNS Secundario (Opcional)
LEASE_TIME=0
#
#   Funciones de Deteccion y Configuracion
#
deteccion_interfaces_red(){
    mapfile -t INTERFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo")

    if [ "${#INTERFACES[@]}" -eq 0 ]; then
        echo ""
        aputs_error "No se detectaron interfaces de red"
        exit 1
    fi

    echo ""
    aputs_info "Interfaces de red detectadas:"

    for i in "${!INTERFACES[@]}"; do
        local iface="${INTERFACES[$i]}"
        local current_ip
        current_ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[^/]+' || echo "Sin IP")
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
            aputs_error "Seleccion invalida. Ingrese un numero entre 1 y ${#INTERFACES[@]}"
        fi
    done

    echo ""
    aputs_success "Interfaz seleccionada: $INTERFAZ_SELECCIONADA"
}
#
#   Funciones semi principales -> usadas por las principales
#
parametros_usuario(){
    echo ""
    draw_header "Configuracion de parametros"

    echo ""
    read -rp "Nombre del Scope: " NOMBRE_SCOPE
    NOMBRE_SCOPE=${NOMBRE_SCOPE:-RedInterna}

    # Solicita el segmento de red y el prefijo CIDR
    # Con ambos datos, validators.sh calcula mascara, broadcast e IPs usables
    while true; do
        echo ""
        aputs_info "Ingrese el segmento de red (sin prefijo, solo la IP base)"
        read -rp "Segmento de red: " RED

        echo ""
        if ! validar_formato_ip "$RED"; then
            aputs_error "Formato de IP invalido"
            continue
        fi

        if ! validar_ip_usable "$RED"; then
            continue
        fi

        # Solicita el prefijo CIDR
        # calcular_subred_cidr actualiza RED, MASCARA y BITS_MASCARA
        while true; do
            echo ""
            aputs_info "Ingrese el prefijo CIDR (ej: 24 para /24 -> 255.255.255.0)"
            read -rp "Prefijo CIDR: " BITS_MASCARA

            if ! validar_cidr "$BITS_MASCARA"; then
                continue
            fi

            if ! calcular_subred_cidr "$RED" "$BITS_MASCARA"; then
                continue
            fi

            break
        done

        aputs_success "Segmento de red aceptado: $RED/$BITS_MASCARA"
        break
    done


    # IP del servidor -> primera IP estatica, clientes comienzan desde la siguiente
    while true; do
        echo ""
        draw_header "IP Inicial"
        aputs_info "Esta IP sera asignada ESTATICAMENTE al servidor"
        aputs_info "Los clientes recibiran IPs DESPUES de esta"
        echo ""
        read -rp "Ingrese la IP donde INICIA el rango DHCP: " IP_SERVIDOR

        echo ""
        if ! validar_formato_ip "$IP_SERVIDOR"; then
            aputs_error "Formato invalido"
            continue
        fi

        if ! validar_mismo_segmento "$RED" "$IP_SERVIDOR" "$MASCARA"; then
            continue
        fi

        if ! validar_ip_no_especial "$IP_SERVIDOR" "$RED" "$MASCARA"; then
            continue
        fi

        aputs_success "IP del servidor aceptada: $IP_SERVIDOR"
        break
    done


    # La primera IP de clientes es IP_SERVIDOR + 1
    IFS='.' read -r o1 o2 o3 o4 <<< "$IP_SERVIDOR"
    local nuevo_o4=$((o4 + 1))

    if [ "$nuevo_o4" -gt 255 ]; then
        nuevo_o4=0
        o3=$((o3 + 1))
        if [ "$o3" -gt 255 ]; then
            o3=0
            o2=$((o2 + 1))
            if [ "$o2" -gt 255 ]; then
                o2=0
                o1=$((o1 + 1))
            fi
        fi
    fi

    IP_INICIO="$o1.$o2.$o3.$nuevo_o4"

    echo ""
    draw_header "Rango para Clientes"
    aputs_info "Primera IP disponible para clientes: $IP_INICIO"
    aputs_info "(Esta IP fue calculada automaticamente)"
    echo ""

    # Solicita y valida IP final del rango DHCP
    while true; do
        aputs_info "Ingrese la IP donde FINALIZA el rango DHCP"
        aputs_info "Debe ser MAYOR que: $IP_INICIO"
        read -rp "IP Final: " IP_FIN

        echo ""
        if ! validar_formato_ip "$IP_FIN"; then
            aputs_error "Formato invalido"
            continue
        fi

        if ! validar_mismo_segmento "$RED" "$IP_FIN" "$MASCARA"; then
            continue
        fi

        if ! validar_ip_no_especial "$IP_FIN" "$RED" "$MASCARA"; then
            continue
        fi

        if ! validar_rango_ips "$IP_INICIO" "$IP_FIN"; then
            continue
        fi

        aputs_success "IP Final aceptada: $IP_FIN"
        break
    done

    # Gateway Opcional
    while true; do
        echo ""
        draw_header "Gateway (Opcional)"
        aputs_info "Presione ENTER para omitir"
        echo ""
        read -rp "Gateway: " GATEWAY

        if [ -z "$GATEWAY" ]; then
            echo ""
            aputs_info "Gateway: NO configurado"
            break
        fi

        echo ""
        if ! validar_formato_ip "$GATEWAY"; then
            aputs_error "Formato invalido. Intente de nuevo o presione ENTER para omitir"
            continue
        fi

        if ! validar_mismo_segmento "$RED" "$GATEWAY" "$MASCARA"; then
            aputs_info "Intente de nuevo o presione ENTER para omitir"
            continue
        fi

        if ! validar_ip_no_especial "$GATEWAY" "$RED" "$MASCARA"; then
            aputs_info "Intente de nuevo o presione ENTER para omitir"
            continue
        fi

        aputs_success "Gateway aceptado: $GATEWAY"
        break
    done


    # DNS Opcional (Primario y Secundario)
    echo ""
    draw_header "DNS (Opcional)"
    echo ""

    while true; do
        read -rp "Desea configurar DNS? (s/n o ENTER para NO): " respuesta_dns

        if [ -z "$respuesta_dns" ] || [[ "$respuesta_dns" =~ ^[Nn]$ ]]; then
            echo ""
            aputs_info "DNS: NO configurado"
            DNS_PRIMARIO=""
            DNS_SECUNDARIO=""
            break
        fi

        if [[ "$respuesta_dns" =~ ^[Ss]$ ]]; then
            echo ""
            echo "----- DNS Primario -----"

            while true; do
                read -rp "DNS Primario (o ENTER para omitir): " DNS_PRIMARIO

                if [ -z "$DNS_PRIMARIO" ]; then
                    echo ""
                    aputs_info "DNS: NO configurado"
                    DNS_SECUNDARIO=""
                    break 2
                fi

                echo ""
                if ! validar_formato_ip "$DNS_PRIMARIO"; then
                    aputs_error "Formato invalido. Intente de nuevo o presione ENTER para omitir"
                    continue
                fi

                aputs_success "DNS Primario aceptado: $DNS_PRIMARIO"
                break
            done

            if [ -n "$DNS_PRIMARIO" ]; then
                echo ""
                echo "----- DNS Secundario (Opcional) -----"

                while true; do
                    read -rp "DNS Secundario (o ENTER para omitir): " DNS_SECUNDARIO

                    if [ -z "$DNS_SECUNDARIO" ]; then
                        echo ""
                        aputs_info "DNS Secundario: NO configurado"
                        break
                    fi

                    echo ""
                    if ! validar_formato_ip "$DNS_SECUNDARIO"; then
                        aputs_error "Formato invalido. Intente de nuevo o presione ENTER para omitir"
                        continue
                    fi

                    aputs_success "DNS Secundario aceptado: $DNS_SECUNDARIO"
                    break
                done
            fi

            break
        fi

        aputs_warning "Por favor ingrese 's' para SI, 'n' para NO, o ENTER para NO"
    done

    # Solicita y valida tiempo de concesion
    while true; do
        echo ""
        aputs_info "Ingrese el tiempo de concesion en segundos"
        aputs_info "Ejemplos: 3600 (1 hora), 86400 (1 dia), 604800 (1 semana)"
        read -rp "Tiempo de concesion: " LEASE_TIME

        if [[ "$LEASE_TIME" =~ ^[0-9]+$ ]] && [ "$LEASE_TIME" -gt 0 ]; then
            local hours=$((LEASE_TIME / 3600))
            local days=$((hours / 24))

            if [ "$days" -gt 0 ]; then
                aputs_success "Tiempo aceptado: $LEASE_TIME segundos ($days dias)"
            elif [ "$hours" -gt 0 ]; then
                aputs_success "Tiempo aceptado: $LEASE_TIME segundos ($hours horas)"
            else
                aputs_success "Tiempo aceptado: $LEASE_TIME segundos"
            fi
            break
        else
            aputs_error "Debe ingresar un numero positivo"
        fi
    done


    echo ""
    draw_header "RESUMEN DE CONFIGURACION"
    echo "  Red          : $RED/$BITS_MASCARA"
    echo "  Mascara      : $MASCARA"
    echo "  IP Servidor  : $IP_SERVIDOR"
    echo "  Rango        : $IP_INICIO - $IP_FIN"
    if [ -n "$GATEWAY" ]; then
        echo "  Gateway      : $GATEWAY"
    else
        echo "  Gateway      : NO configurado"
    fi
    if [ -n "$DNS_PRIMARIO" ]; then
        echo "  DNS Primario : $DNS_PRIMARIO"
        if [ -n "$DNS_SECUNDARIO" ]; then
            echo "  DNS Secundario: $DNS_SECUNDARIO"
        fi
    else
        echo "  DNS          : NO configurado"
    fi
    echo "  Lease Time   : $LEASE_TIME segundos"
    draw_line
    echo ""
}

configurar_interfaz_red(){
    echo ""
    draw_header "Configuracion de Interfaz de Red"
    echo ""

    aputs_info "Configurando interfaz $INTERFAZ_SELECCIONADA con IP: $IP_SERVIDOR/$BITS_MASCARA"

    local nm_config="/etc/NetworkManager/system-connections/$INTERFAZ_SELECCIONADA.nmconnection"

    sudo tee "$nm_config" > /dev/null <<EOF
[connection]
id=$INTERFAZ_SELECCIONADA
uuid=$(uuidgen)
type=ethernet
interface-name=$INTERFAZ_SELECCIONADA

[ipv4]
method=manual
address1=$IP_SERVIDOR/$BITS_MASCARA
EOF

    if [ -n "$GATEWAY" ]; then
        echo "gateway=$GATEWAY" | sudo tee -a "$nm_config" > /dev/null
    fi

    if [ -n "$DNS_PRIMARIO" ]; then
        if [ -n "$DNS_SECUNDARIO" ]; then
            echo "dns=$DNS_PRIMARIO;$DNS_SECUNDARIO;" | sudo tee -a "$nm_config" > /dev/null
        else
            echo "dns=$DNS_PRIMARIO;" | sudo tee -a "$nm_config" > /dev/null
        fi
    fi

    sudo chmod 600 "$nm_config"

    echo ""
    aputs_info "Aplicando configuracion de red..."
    sudo systemctl restart NetworkManager
    sleep 2

    sudo nmcli connection up "$INTERFAZ_SELECCIONADA" &> /dev/null

    local current_ip
    current_ip=$(ip -4 addr show "$INTERFAZ_SELECCIONADA" | grep -oP 'inet \K[^/]+')

    if [ "$current_ip" = "$IP_SERVIDOR" ]; then
        aputs_success "Configuracion aplicada correctamente"
        aputs_info "IP actual: $current_ip"
    else
        aputs_warning "La IP configurada no coincide"
        aputs_info "Esperada : $IP_SERVIDOR"
        aputs_info "Actual   : $current_ip"
    fi
}

config_dhcp(){
    echo ""
    draw_header "Configuracion del Servicio DHCP"
    echo ""

    local dhcp_conf="/etc/dhcp/dhcpd.conf"

    if [ -f "$dhcp_conf" ]; then
        aputs_info "Creando backup de configuracion anterior..."
        sudo cp "$dhcp_conf" "${dhcp_conf}.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    aputs_info "Generando archivo de configuracion..."
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
    option subnet-mask $MASCARA;
EOF

    if [ -n "$GATEWAY" ]; then
        echo "    option routers $GATEWAY;" | sudo tee -a "$dhcp_conf" > /dev/null
    fi

    if [ -n "$DNS_PRIMARIO" ]; then
        if [ -n "$DNS_SECUNDARIO" ]; then
            echo "    option domain-name-servers $DNS_PRIMARIO, $DNS_SECUNDARIO;" | sudo tee -a "$dhcp_conf" > /dev/null
        else
            echo "    option domain-name-servers $DNS_PRIMARIO;" | sudo tee -a "$dhcp_conf" > /dev/null
        fi
    fi

    echo "}" | sudo tee -a "$dhcp_conf" > /dev/null

    aputs_success "Archivo de configuracion creado en: $dhcp_conf"
    echo ""
    draw_header "Resumen de la configuracion"
    echo "  Scope        : $NOMBRE_SCOPE"
    echo "  Red          : $RED/$BITS_MASCARA"
    echo "  IP Servidor  : $IP_SERVIDOR"
    echo "  Rango        : $IP_INICIO - $IP_FIN"
    if [ -n "$GATEWAY" ]; then
        echo "  Gateway      : $GATEWAY"
    else
        echo "  Gateway      : NO configurado"
    fi
    if [ -n "$DNS_PRIMARIO" ]; then
        echo "  DNS Primario : $DNS_PRIMARIO"
        if [ -n "$DNS_SECUNDARIO" ]; then
            echo "  DNS Secundario: $DNS_SECUNDARIO"
        fi
    else
        echo "  DNS          : NO configurado"
    fi
    echo "  Lease Time   : $LEASE_TIME segundos"
    draw_line
    echo ""
}

iniciar_dhcp(){
    echo ""
    draw_header "Iniciando Servicio DHCP"
    echo ""

    aputs_info "Habilitando servicio para inicio automatico..."
    sudo systemctl enable dhcpd &> /dev/null

    aputs_info "Iniciando servicio DHCP..."
    sudo systemctl restart dhcpd

    sleep 2

    if sudo systemctl is-active dhcpd &> /dev/null; then
        echo ""
        aputs_success "Servicio DHCP iniciado correctamente"
        echo ""
        sudo systemctl status dhcpd --no-pager -l
    else
        echo ""
        aputs_error "Fallo el inicio del servicio. Logs:"
        sudo journalctl -u dhcpd -n 20 --no-pager
        exit 1
    fi
}
#
#   Monitor tiempo real
#
monitoreo_info(){
    draw_header "Monitor de Servicio DHCP"
    echo ""
    aputs_info "Actualizacion: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    if [ ! -f /etc/dhcp/dhcpd.conf ]; then
        aputs_warning "No hay configuracion DHCP disponible"
        echo ""
        return
    fi

    local subnet
    local range
    subnet=$(sudo grep -oP 'subnet \K[0-9.]+' /etc/dhcp/dhcpd.conf | head -1)
    range=$(sudo grep -oP 'range \K[0-9. ]+' /etc/dhcp/dhcpd.conf | head -1)

    if [ -n "$subnet" ]; then
        echo "  Scope  : $NOMBRE_SCOPE"
        echo "  Red    : $subnet"
        echo "  Rango  : $range"
        echo ""

        if [ -n "$INTERFAZ_SELECCIONADA" ]; then
            local server_ip
            server_ip=$(ip -4 addr show "$INTERFAZ_SELECCIONADA" 2>/dev/null | grep -oP 'inet \K[^/]+' | head -1)
            if [ -n "$server_ip" ]; then
                echo "  IP del servidor DHCP: $server_ip"
                echo ""
            fi
        fi
    fi

    if [ -f /var/lib/dhcpd/dhcpd.leases ]; then
        local leases_info
        leases_info=$(sudo awk '
        /^lease/ {
            ip = $2
            delete data
        }
        /binding state active/ {
            data["state"] = "active"
        }
        /hardware ethernet/ {
            data["mac"] = $3
            gsub(/;/, "", data["mac"])
        }
        /client-hostname/ {
            data["hostname"] = $2
            gsub(/[";]/, "", data["hostname"])
        }
        /ends/ {
            data["ends"] = $3 " " $4
            gsub(/;/, "", data["ends"])
        }
        /}/ {
            if (data["state"] == "active") {
                printf "%s|%s|%s|%s\n", ip, (data["hostname"] ? data["hostname"] : "Sin nombre"), (data["mac"] ? data["mac"] : "N/A"), (data["ends"] ? data["ends"] : "N/A")
            }
        }
        ' /var/lib/dhcpd/dhcpd.leases | sort -u -t'|' -k1,1)

        if [ -n "$leases_info" ]; then
            local count
            count=$(echo "$leases_info" | wc -l)
            aputs_info "Concesiones activas: $count"
            echo ""

            echo "$leases_info" | while IFS='|' read -r ip hostname mac expires; do
                echo "  IP     : $ip"
                echo "    Host   : $hostname"
                echo "    MAC    : $mac"
                echo "    Estado : ACTIVO"
                echo "    Expira : $expires"
                echo ""
            done
        else
            aputs_info "Sin concesiones activas"
            echo ""
        fi
    else
        aputs_info "Sin concesiones activas"
        echo ""
    fi
}
#
#   Funciones del Menu Principal
#
verificar_instalacion(){
    echo ""
    aputs_info "Verificando instalacion del servicio DHCP..."
    echo ""

    if rpm -q dhcp-server &> /dev/null; then
        aputs_success "Estado: INSTALADO"
        echo ""
        rpm -qi dhcp-server | grep -E "Name|Version|Release|Install Date"
        echo ""

        if systemctl is-enabled dhcpd &> /dev/null; then
            aputs_success "Servicio: HABILITADO"
        else
            aputs_warning "Servicio: NO HABILITADO"
        fi

        if systemctl is-active dhcpd &> /dev/null; then
            aputs_success "Estado: ACTIVO"
        else
            aputs_warning "Estado: INACTIVO"
        fi
    else
        aputs_warning "Estado: NO INSTALADO"
        echo ""
        read -rp "Desea instalar el servicio ahora? (s/n): " respuesta

        if [[ "$respuesta" =~ ^[Ss]$ ]]; then
            echo ""
            aputs_info "Iniciando instalacion..."

            if sudo dnf install -y dhcp-server &> /dev/null; then
                aputs_success "Instalacion finalizada correctamente"
            else
                aputs_error "Fallo la instalacion del servicio"
                aputs_info "Verifique su conexion a internet y repositorios"
            fi
        else
            aputs_info "Instalacion cancelada"
        fi
    fi
}

instalar_servicio(){
    echo ""
    draw_header "Proceso de Instalacion Completo"
    echo ""
    aputs_info "Este proceso instalara y configurara el servidor DHCP"
    echo ""

    if rpm -q dhcp-server &> /dev/null; then
        aputs_info "El servicio ya esta instalado"
        echo ""
        read -rp "Desea reconfigurar el servicio? (s/n): " reconfig

        if [[ ! "$reconfig" =~ ^[Ss]$ ]]; then
            aputs_info "Operacion cancelada"
            return 0
        fi
    else
        read -rp "Desea instalar el servicio DHCP? (s/n): " respuesta

        if [[ ! "$respuesta" =~ ^[Ss]$ ]]; then
            aputs_info "Instalacion cancelada"
            return 0
        fi

        echo ""
        aputs_info "Iniciando instalacion..."

        if sudo dnf install -y dhcp-server &> /dev/null; then
            aputs_success "Instalacion finalizada correctamente"
            echo ""
        else
            aputs_error "Fallo la instalacion del servicio"
            aputs_info "Verifique su conexion a internet y repositorios"
            return 1
        fi
    fi

    aputs_info "Procediendo con la configuracion..."
    echo ""

    deteccion_interfaces_red
    parametros_usuario
    configurar_interfaz_red
    config_dhcp
    iniciar_dhcp

    echo ""
    draw_line
    aputs_success "Instalacion y configuracion completadas"
    aputs_success "El servicio DHCP esta activo y funcionando"
    draw_line
}

nueva_configuracion(){
    echo ""
    draw_header "Nueva configuracion DHCP"
    echo ""
    aputs_info "Esta opcion permite reconfigurar un servidor DHCP ya instalado."
    aputs_info "Si existe una configuracion previa, sera reemplazada."
    echo ""
    aputs_warning "Si el servicio no esta instalado, use la opcion 2"
    echo ""
    read -rp "Desea continuar? (s/n): " respuesta

    if [[ ! "$respuesta" =~ ^[Ss]$ ]]; then
        aputs_info "Configuracion cancelada"
        return 0
    fi

    echo ""
    aputs_info "Verificando instalacion del servicio..."

    if ! rpm -q dhcp-server &> /dev/null; then
        echo ""
        aputs_error "El servicio DHCP no esta instalado"
        echo ""
        aputs_info "Por favor, use la opcion 2 del menu para instalar y configurar"
        aputs_info "el servicio por primera vez."
        return 0
    fi

    echo ""
    aputs_info "Iniciando reconfiguracion..."

    deteccion_interfaces_red
    parametros_usuario
    configurar_interfaz_red
    config_dhcp
    iniciar_dhcp

    echo ""
    draw_line
    aputs_success "Reconfiguracion completada exitosamente"
    draw_line
}

reiniciar_servicio(){
    draw_header "Reiniciando servicio DHCP"

    if ! rpm -q dhcp-server &> /dev/null; then
        aputs_error "El servicio no esta instalado"
        return 1
    fi

    if sudo systemctl restart dhcpd; then
        aputs_success "Servicio reiniciado correctamente"
        echo ""
        sudo systemctl status dhcpd --no-pager -l
    else
        aputs_error "Error al reiniciar el servicio"
        echo ""
        sudo journalctl -u dhcpd -n 30 --no-pager
    fi
}

ver_configuracion_actual(){
    echo ""
    draw_header "Configuracion Actual del Servidor"
    echo ""

    if ! rpm -q dhcp-server &> /dev/null; then
        aputs_warning "El servicio DHCP no esta instalado"
        return 1
    fi

    echo "1. Estado del Servicio:"
    draw_line
    if systemctl is-active dhcpd &> /dev/null; then
        aputs_success "Estado: ACTIVO"
    else
        aputs_warning "Estado: INACTIVO"
    fi

    if systemctl is-enabled dhcpd &> /dev/null; then
        aputs_success "Inicio automatico: HABILITADO"
    else
        aputs_warning "Inicio automatico: DESHABILITADO"
    fi
    echo ""

    echo "2. Configuracion DHCP:"
    draw_line
    if [ -f /etc/dhcp/dhcpd.conf ]; then
        local subnet
        local netmask
        local range
        local gateway
        local dns
        local lease
        subnet=$(sudo grep -oP 'subnet \K[0-9.]+' /etc/dhcp/dhcpd.conf | head -1)
        netmask=$(sudo grep -oP 'netmask \K[0-9.]+' /etc/dhcp/dhcpd.conf | head -1)
        range=$(sudo grep -oP 'range \K[0-9. ]+' /etc/dhcp/dhcpd.conf | head -1)
        gateway=$(sudo grep -oP 'option routers \K[0-9.]+' /etc/dhcp/dhcpd.conf | head -1)
        dns=$(sudo grep -oP 'option domain-name-servers \K[0-9.]+' /etc/dhcp/dhcpd.conf | head -1)
        lease=$(sudo grep -oP 'default-lease-time \K[0-9]+' /etc/dhcp/dhcpd.conf | head -1)

        echo "  Segmento de red : $subnet"
        echo "  Mascara         : $netmask"
        echo "  Rango           : $range"
        echo "  Gateway         : $gateway"
        echo "  DNS             : $dns"
        echo "  Lease Time      : $lease segundos"
    else
        aputs_warning "Archivo de configuracion no encontrado"
    fi
    echo ""

    echo "3. Interfaz de Red:"
    draw_line
    if [ -f /etc/sysconfig/dhcpd ]; then
        local iface
        iface=$(sudo grep -oP 'DHCPDARGS="\K[^"]+' /etc/sysconfig/dhcpd)
        echo "  Interfaz : $iface"

        if [ -n "$iface" ]; then
            local ip_actual
            ip_actual=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[^/]+' | head -1)
            echo "  IP del servidor: $ip_actual"
        fi
    else
        aputs_warning "No configurado"
    fi
    echo ""

    echo "4. Estadisticas:"
    draw_line
    if [ -f /var/lib/dhcpd/dhcpd.leases ]; then
        local total_leases
        local active_leases
        total_leases=$(sudo grep -c "^lease" /var/lib/dhcpd/dhcpd.leases 2>/dev/null || echo "0")
        active_leases=$(sudo awk '/^lease/ {ip=$2} /binding state active/ {print ip}' /var/lib/dhcpd/dhcpd.leases | sort -u | wc -l)

        echo "  Concesiones totales registradas : $total_leases"
        echo "  Concesiones activas             : $active_leases"
    else
        aputs_info "Sin concesiones registradas"
    fi
    echo ""
}

modo_monitor(){
    echo ""
    aputs_info "Iniciando modo monitor..."
    aputs_info "Presiona Ctrl+C para salir"
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
        draw_header "Gestor de Servicio DHCP"
        echo ""
        echo "Seleccione una opcion:"
        echo ""
        echo "  1) Verificar instalacion"
        echo "  2) Instalar servicio"
        echo "  3) Nueva configuracion"
        echo "  4) Reiniciar servicio"
        echo "  5) Monitor de concesiones"
        echo "  6) Configuracion actual"
        echo "  7) Salir"
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
            aputs_info "Saliendo del programa..."
            exit 0
            ;;
        *)
            echo ""
            aputs_error "Opcion invalida"
            ;;
        esac
        echo ""
        pause
    done
}
#
#   Punto de Entrada Principal
#
main_menu