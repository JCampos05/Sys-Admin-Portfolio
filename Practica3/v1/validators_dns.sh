# Requiere:
#       ipcalc (dnf install ipcalc)
#       utils.sh debe estar cargado antes
#

#
#   Funciones de Soporte Interno
#

# Verifica que ipcalc este disponible en el sistema
dns_verificar_ipcalc() {
    if ! command -v ipcalc &>/dev/null; then
        aputs_error "ipcalc no esta instalado"
        aputs_info "Ejecute: sudo dnf install ipcalc"
        return 1
    fi
    return 0
}

#
#   Validaciones de Formato
#

# Valida el formato basico de una direccion IPv4
# Comprueba patron X.X.X.X y que cada octeto sea 0-255
dns_validar_formato_ip() {
    local ip="$1"

    if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    local octeto
    for octeto in ${ip//./ }; do
        if (( octeto < 0 || octeto > 255 )); then
            return 1
        fi
    done

    return 0
}

# Valida que la IP no pertenezca a rangos reservados o no usables
# Reservados: 0.0.0.0/8, 127.0.0.0/8, multicast 224-239, experimentales 240-255
dns_validar_ip_usable() {
    local ip="$1"

    if ! dns_validar_formato_ip "$ip"; then
        aputs_error "Formato IPv4 incorrecto: $ip"
        return 1
    fi

    IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$ip"

    if [[ "$oct1" -eq 0 ]]; then
        aputs_error "La red 0.0.0.0/8 es reservada y no es utilizable"
        return 1
    fi

    if [[ "$oct1" -eq 127 ]]; then
        aputs_error "La red 127.0.0.0/8 es de loopback y no es utilizable"
        return 1
    fi

    if [[ "$oct1" -eq 255 && "$oct2" -eq 255 && "$oct3" -eq 255 && "$oct4" -eq 255 ]]; then
        aputs_error "255.255.255.255 es la direccion de broadcast limitado"
        return 1
    fi

    if [[ "$oct1" -ge 224 && "$oct1" -le 239 ]]; then
        aputs_error "El rango 224.0.0.0 - 239.255.255.255 es multicast"
        return 1
    fi

    if [[ "$oct1" -ge 240 && "$oct1" -le 255 ]]; then
        aputs_error "El rango 240.0.0.0 - 255.255.255.255 es experimental"
        return 1
    fi

    return 0
}

# Valida una IP completa: formato + usable
# Uso: dns_validar_ip "192.168.1.1"
dns_validar_ip() {
    local ip="$1"

    if ! dns_validar_formato_ip "$ip"; then
        aputs_error "Formato de IP invalido: $ip"
        aputs_info "El formato debe ser X.X.X.X donde cada X es 0-255"
        return 1
    fi

    if ! dns_validar_ip_usable "$ip"; then
        return 1
    fi

    return 0
}

#
#   Validaciones de Nombres
#

# Valida el formato de un nombre de dominio
# Acepta: letras, numeros, guiones y puntos
# No acepta: espacios, caracteres especiales, dominio vacio
# Ejemplos validos: ejemplo.com, sub.ejemplo.com, mi-sitio.org
dns_validar_nombre_dominio() {
    local dominio="$1"

    if [[ -z "$dominio" ]]; then
        aputs_error "El nombre del dominio no puede estar vacio"
        return 1
    fi

    # Debe tener al menos un punto (TLD obligatorio)
    if [[ "$dominio" != *.* ]]; then
        aputs_error "El dominio debe tener al menos un punto (ej: ejemplo.com)"
        return 1
    fi

    # Solo letras, numeros, guiones y puntos
    if [[ ! "$dominio" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)+$ ]]; then
        aputs_error "Nombre de dominio invalido: $dominio"
        aputs_info "Solo se permiten letras, numeros, guiones y puntos"
        aputs_info "No puede comenzar ni terminar con guion o punto"
        return 1
    fi

    # Longitud maxima de etiqueta DNS es 63 caracteres
    local etiqueta
    for etiqueta in ${dominio//./ }; do
        if [[ ${#etiqueta} -gt 63 ]]; then
            aputs_error "Cada parte del dominio no puede superar 63 caracteres"
            return 1
        fi
    done

    # Longitud total maxima de un FQDN es 253 caracteres
    if [[ ${#dominio} -gt 253 ]]; then
        aputs_error "El nombre del dominio no puede superar 253 caracteres"
        return 1
    fi

    return 0
}

# Valida el nombre de un host o subdominio (sin puntos)
# Ejemplos validos: www, mail, ns1, ftp, servidor-1
dns_validar_nombre_host() {
    local host="$1"

    if [[ -z "$host" ]]; then
        aputs_error "El nombre del host no puede estar vacio"
        return 1
    fi

    if [[ ! "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?$ ]]; then
        aputs_error "Nombre de host invalido: $host"
        aputs_info "Solo letras, numeros y guiones. No puede comenzar ni terminar con guion"
        return 1
    fi

    if [[ ${#host} -gt 63 ]]; then
        aputs_error "El nombre del host no puede superar 63 caracteres"
        return 1
    fi

    return 0
}

#
#   Validaciones de Parametros DNS
#

# Valida que el TTL sea un numero entero positivo
# Rango razonable: 60 segundos (1 minuto) a 604800 (1 semana)
dns_validar_ttl() {
    local ttl="$1"

    if [[ ! "$ttl" =~ ^[0-9]+$ ]]; then
        aputs_error "El TTL debe ser un numero entero positivo"
        return 1
    fi

    if [[ "$ttl" -lt 60 ]]; then
        aputs_error "El TTL minimo es 60 segundos"
        aputs_info "Un TTL muy bajo genera trafico excesivo en el DNS"
        return 1
    fi

    if [[ "$ttl" -gt 604800 ]]; then
        aputs_error "El TTL maximo recomendado es 604800 (1 semana)"
        return 1
    fi

    return 0
}

# Valida que la prioridad MX sea un entero entre 0 y 65535
dns_validar_prioridad_mx() {
    local prioridad="$1"

    if [[ ! "$prioridad" =~ ^[0-9]+$ ]]; then
        aputs_error "La prioridad MX debe ser un numero entero"
        return 1
    fi

    if [[ "$prioridad" -lt 0 || "$prioridad" -gt 65535 ]]; then
        aputs_error "La prioridad MX debe estar entre 0 y 65535"
        return 1
    fi

    return 0
}

#
#   Calculos de Red con ipcalc
#

# Calcula y muestra informacion de subred dado una IP y prefijo CIDR
# Solo para referencia informativa en el DNS, no modifica variables globales
# Uso: dns_info_subred "192.168.1.10" "24"
dns_info_subred() {
    local ip="$1"
    local cidr="$2"

    if ! dns_verificar_ipcalc; then
        return 1
    fi

    local resultado
    resultado=$(ipcalc -n -m -b "${ip}/${cidr}" 2>/dev/null)

    if [[ $? -ne 0 || -z "$resultado" ]]; then
        aputs_error "ipcalc no pudo procesar la direccion ${ip}/${cidr}"
        return 1
    fi

    local red
    local mascara
    local broadcast

    red=$(echo "$resultado" | grep "^NETWORK=" | cut -d'=' -f2)
    mascara=$(echo "$resultado" | grep "^NETMASK=" | cut -d'=' -f2)
    broadcast=$(echo "$resultado" | grep "^BROADCAST=" | cut -d'=' -f2)

    local hosts_bits=$(( 32 - cidr ))
    local ips_usables=$(( (2 ** hosts_bits) - 2 ))

    echo ""
    draw_line
    echo "  Informacion de subred /${cidr}"
    draw_line
    echo "  Direccion de red    : $red"
    echo "  Mascara             : $mascara"
    echo "  Broadcast           : $broadcast"
    echo "  IPs usables         : $ips_usables"
    draw_line
    echo ""

    return 0
}

# Verifica que una IP pertenezca al mismo segmento que el servidor DNS
# Usa la IP activa del servidor como referencia
# Uso: dns_validar_ip_en_segmento_servidor "192.168.1.50" "24"
dns_validar_ip_en_segmento_servidor() {
    local ip_comparar="$1"
    local cidr="${2:-24}"

    if ! dns_verificar_ipcalc; then
        return 1
    fi

    # Obtener IP activa del servidor (excluyendo loopback)
    local ip_servidor
    ip_servidor=$(ip -4 addr show \
        | grep -oP 'inet \K[^/]+' \
        | grep -v "^127\." \
        | head -1)

    if [[ -z "$ip_servidor" ]]; then
        aputs_error "No se pudo determinar la IP activa del servidor"
        return 1
    fi

    # Calcular red del servidor
    local red_servidor
    red_servidor=$(ipcalc -n "${ip_servidor}/${cidr}" 2>/dev/null \
        | grep "^NETWORK=" | cut -d'=' -f2)

    # Calcular red de la IP a comparar
    local red_comparar
    red_comparar=$(ipcalc -n "${ip_comparar}/${cidr}" 2>/dev/null \
        | grep "^NETWORK=" | cut -d'=' -f2)

    if [[ "$red_servidor" != "$red_comparar" ]]; then
        aputs_error "La IP $ip_comparar no pertenece al segmento del servidor ($red_servidor/$cidr)"
        return 1
    fi

    return 0
}

#
#   Exportar funciones del modulo
#
export -f dns_verificar_ipcalc
export -f dns_validar_formato_ip
export -f dns_validar_ip_usable
export -f dns_validar_ip
export -f dns_validar_nombre_dominio
export -f dns_validar_nombre_host
export -f dns_validar_ttl
export -f dns_validar_prioridad_mx
export -f dns_info_subred
export -f dns_validar_ip_en_segmento_servidor