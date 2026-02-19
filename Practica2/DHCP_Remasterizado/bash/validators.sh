#!/bin/bash
#
#   Modulo de Validacion de Redes
#
#   Todas las validaciones de direcciones IPv4, mascaras,
#   rangos y calculos de subred se realizan aqui.
#   Depende de ipcalc para los calculos de red.
#
#   Variables globales que este modulo modifica:
#       MASCARA       -> mascara en formato decimal punteado
#       BITS_MASCARA  -> prefijo CIDR numerico
#       RED           -> direccion de red calculada
#
#   Uso:
#       source validators.sh
#
#   Requiere:
#       ipcalc (dnf install ipcalc)
#

#
#   Funciones de Soporte Interno
#

# Verifica que ipcalc este disponible en el sistema
verificar_ipcalc(){
    if ! command -v ipcalc &> /dev/null; then
        aputs_error "ipcalc no esta instalado"
        aputs_info "Ejecute: sudo dnf install ipcalc"
        return 1
    fi
    return 0
}

# Convierte la IP a numero entero (para comparaciones numericas)
ip_a_numero(){
    local ip=$1
    IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$ip"
    echo $((oct1 * 256**3 + oct2 * 256**2 + oct3 * 256 + oct4))
}

#
#   Funciones de Validacion de Formato
#

# Valida el formato basico de una direccion IPv4
# Comprueba patron X.X.X.X y que cada octeto sea 0-255
validar_formato_ip(){
    local ip=$1

    if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    local octeto
    for octeto in ${ip//./ }; do
        if ((octeto < 0 || octeto > 255)); then
            return 1
        fi
    done

    return 0
}

# Valida que el prefijo CIDR sea un numero entero entre 1 y 30
# Se excluye /31 y /32 por no ser utiles para rangos DHCP
validar_cidr(){
    local cidr=$1

    if [[ ! $cidr =~ ^[0-9]+$ ]]; then
        aputs_error "El prefijo CIDR debe ser un numero entero"
        return 1
    fi

    if [ "$cidr" -lt 1 ] || [ "$cidr" -gt 30 ]; then
        aputs_error "El prefijo CIDR debe estar entre /1 y /30"
        aputs_info "  /31 y /32 no permiten rangos DHCP validos"
        return 1
    fi

    return 0
}

#
#   Funciones de Validacion de Rango y Segmento
#

# Valida que la IP sea usable -> no pertenece a rangos reservados
# Reservados: 0.0.0.0/8, 127.0.0.0/8, multicast 224-239, experimentales 240-255
validar_ip_usable(){
    local ip=$1

    if ! validar_formato_ip "$ip"; then
        aputs_error "Formato IPv4 incorrecto"
        return 1
    fi

    IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$ip"

    if [ "$oct1" -eq 0 ]; then
        aputs_error "La red 0.0.0.0/8 es reservada y no es utilizable"
        return 1
    fi

    if [ "$oct1" -eq 127 ]; then
        aputs_error "La red 127.0.0.0/8 es de loopback y no es utilizable"
        return 1
    fi

    if [ "$oct1" -eq 255 ] && [ "$oct2" -eq 255 ] && [ "$oct3" -eq 255 ] && [ "$oct4" -eq 255 ]; then
        aputs_error "255.255.255.255 es la direccion de broadcast limitado"
        return 1
    fi

    if [ "$oct1" -ge 224 ] && [ "$oct1" -le 239 ]; then
        aputs_error "El rango 224.0.0.0 - 239.255.255.255 es multicast"
        return 1
    fi

    if [ "$oct1" -ge 240 ] && [ "$oct1" -le 255 ]; then
        aputs_error "El rango 240.0.0.0 - 255.255.255.255 es experimental"
        return 1
    fi

    return 0
}

# Valida que una IP no sea la direccion de red ni la de broadcast
# de la subred definida por RED y MASCARA globales
validar_ip_no_especial(){
    local ip=$1
    local red=$2
    local mascara=$3

    IFS='.' read -r r1 r2 r3 r4 <<< "$red"
    IFS='.' read -r m1 m2 m3 m4 <<< "$mascara"

    local b1=$(( (r1 & m1) | (255 - m1) ))
    local b2=$(( (r2 & m2) | (255 - m2) ))
    local b3=$(( (r3 & m3) | (255 - m3) ))
    local b4=$(( (r4 & m4) | (255 - m4) ))

    local broadcast="$b1.$b2.$b3.$b4"

    if [ "$ip" = "$red" ]; then
        aputs_error "No puede usar la direccion de red ($red)"
        return 1
    fi

    if [ "$ip" = "$broadcast" ]; then
        aputs_error "No puede usar la direccion de broadcast ($broadcast)"
        return 1
    fi

    return 0
}

# Valida que dos IPs pertenezcan al mismo segmento de red
validar_mismo_segmento(){
    local ip_base=$1
    local ip_comparar=$2
    local mascara=$3

    local red_base=$(obtener_ip_red "$ip_base" "$mascara")
    local red_comparar=$(obtener_ip_red "$ip_comparar" "$mascara")

    if [ "$red_base" != "$red_comparar" ]; then
        aputs_error "La IP $ip_comparar no pertenece al segmento $red_base"
        return 1
    fi

    return 0
}

# Valida que la IP inicial del rango sea estrictamente menor que la IP final
validar_rango_ips(){
    local ip_inicio=$1
    local ip_fin=$2

    local num_inicio=$(ip_a_numero "$ip_inicio")
    local num_fin=$(ip_a_numero "$ip_fin")

    if [ "$num_inicio" -ge "$num_fin" ]; then
        aputs_error "La IP inicial debe ser menor que la IP final"
        aputs_info "  IP Inicial : $ip_inicio  (valor: $num_inicio)"
        aputs_info "  IP Final   : $ip_fin  (valor: $num_fin)"
        return 1
    fi

    return 0
}

#
#   Funciones de Calculo de Red con ipcalc
#

# Obtiene la direccion de red realizando AND bit a bit entre IP y mascara
obtener_ip_red(){
    local ip=$1
    local mascara=$2

    IFS='.' read -r ip1 ip2 ip3 ip4 <<< "$ip"
    IFS='.' read -r m1 m2 m3 m4 <<< "$mascara"

    local red1=$((ip1 & m1))
    local red2=$((ip2 & m2))
    local red3=$((ip3 & m3))
    local red4=$((ip4 & m4))

    echo "$red1.$red2.$red3.$red4"
}

# Calcula todos los parametros de subred a partir de IP y prefijo CIDR
# Usa ipcalc para obtener mascara, broadcast, IPs usables y rango
# Modifica las variables globales MASCARA y BITS_MASCARA
# Muestra un resumen de la subred al usuario
calcular_subred_cidr(){
    local ip=$1
    local cidr=$2

    if ! verificar_ipcalc; then
        return 1
    fi

    # ipcalc calcula todos los parametros de la subred
    local resultado
    resultado=$(ipcalc -n -m -b "${ip}/${cidr}" 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$resultado" ]; then
        aputs_error "ipcalc no pudo procesar la direccion ${ip}/${cidr}"
        return 1
    fi

    # Extraer cada campo del resultado de ipcalc
    local mascara_calculada
    local broadcast_calculado
    local red_calculada

    mascara_calculada=$(echo "$resultado" | grep "^NETMASK=" | cut -d'=' -f2)
    broadcast_calculado=$(echo "$resultado" | grep "^BROADCAST=" | cut -d'=' -f2)
    red_calculada=$(echo "$resultado" | grep "^NETWORK=" | cut -d'=' -f2)

    if [ -z "$mascara_calculada" ] || [ -z "$red_calculada" ]; then
        aputs_error "No se pudieron extraer los parametros de la subred"
        return 1
    fi

    # Actualizar variables globales
    MASCARA="$mascara_calculada"
    BITS_MASCARA="$cidr"
    RED="$red_calculada"

    # Calcular IPs usables: 2^(32-cidr) - 2
    local hosts_bits=$((32 - cidr))
    local ips_totales=$((2 ** hosts_bits))
    local ips_usables=$((ips_totales - 2))

    # Mostrar resumen de la subred
    echo ""
    draw_line
    echo "  Informacion de subred /${cidr}"
    draw_line
    echo "  Direccion de red    : $RED"
    echo "  Mascara             : $MASCARA"
    echo "  Broadcast           : $broadcast_calculado"
    echo "  IPs totales         : $ips_totales"
    echo "  IPs usables         : $ips_usables"
    draw_line
    echo ""

    return 0
}

#
#   Exportar funciones del modulo
#
export -f verificar_ipcalc
export -f ip_a_numero
export -f validar_formato_ip
export -f validar_cidr
export -f validar_ip_usable
export -f validar_ip_no_especial
export -f validar_mismo_segmento
export -f validar_rango_ips
export -f obtener_ip_red
export -f calcular_subred_cidr