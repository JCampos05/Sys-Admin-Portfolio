#
# utilsAD.sh
#
# Funciones:
#   write_ad_log          - Escribe entradas en el log de la practica
#   get_ad_domain         - Retorna el dominio en minusculas (ej: reprobados.local)
#   get_dc_ip             - Retorna la IP del Domain Controller
#   get_internal_iface    - Detecta la interfaz conectada a Red_Sistemas (192.168.100.x)
#   check_realm_joined    - Verifica si el equipo ya esta unido a un dominio
#   backup_file           - Hace backup de un archivo de configuracion antes de editarlo
#

# Rutas de trabajo
TAREA08_LOG="/var/log/tarea08-ad.log"
ADMIN_USER="Administrador"        # Cuenta de administrador del dominio

# -------------------------------------------------------------------------
# Detectar configuracion del entorno dinamicamente
# Sin hardcodear IPs, dominios ni interfaces de red
# -------------------------------------------------------------------------


INTERNAL_IFACE=$(ip -4 addr show | grep "192.168\." |     grep -v "192.168.70\.\|192.168.75\." |     awk '{print $NF}' | head -1)
[[ -z "$INTERNAL_IFACE" ]] && INTERNAL_IFACE=$(ip -o link show |     awk -F": " '{print $2}' | grep -v "^lo$" | head -1)

# Obtener IP del cliente en la red interna
CLIENT_IP=$(ip -4 addr show "$INTERNAL_IFACE" 2>/dev/null |     grep -oP "inet \K[^/]+" | head -1)

detect_dc_ip() {
    local subnet
    subnet=$(echo "$CLIENT_IP" | cut -d. -f1-3)
    for last_octet in 20 1 10 2; do
        local candidate="${subnet}.${last_octet}"
        if ping -c 1 -W 1 "$candidate" &>/dev/null 2>&1; then
            # Verificar que es un DC comprobando puerto Kerberos (88)
            if nc -z -w 2 "$candidate" 88 &>/dev/null 2>&1; then
                echo "$candidate"
                return 0
            fi
        fi
    done
    return 1
}

# Detectar dominio preguntando al DNS si aun no esta configurado
detect_domain() {
    # Intentar desde realm si ya esta unido
    local domain
    domain=$(realm list 2>/dev/null | grep "domain-name" | awk "{print \$2}" | head -1)
    [[ -n "$domain" ]] && echo "$domain" && return 0

    # Intentar desde el hostname FQDN
    local fqdn
    fqdn=$(hostname -f 2>/dev/null)
    if [[ "$fqdn" == *.*.* ]]; then
        echo "${fqdn#*.}"
        return 0
    fi

    return 1
}

# Inicializar variables de conexion
if [[ -z "${DC_IP:-}" ]]; then
    DC_IP=$(detect_dc_ip 2>/dev/null)
    if [[ -z "$DC_IP" ]]; then
        # Si no se puede detectar, pedir al usuario
        echo -ne "[0;36m[INPUT][0m IP del servidor DC: "
        read -r DC_IP
    fi
fi

if [[ -z "${DC_DOMAIN:-}" ]]; then
    DC_DOMAIN=$(detect_domain 2>/dev/null)
    if [[ -z "$DC_DOMAIN" ]]; then
        echo -ne "[0;36m[INPUT][0m Nombre del dominio (ej: reprobados.local): "
        read -r DC_DOMAIN
    fi
fi

DC_REALM="${DC_DOMAIN^^}"                              # reprobados.local -> REPROBADOS.LOCAL
DC_REALM="${DC_REALM//.LOCAL/.LOCAL}"                  # ya esta en mayusculas
NETBIOS_NAME=$(echo "$DC_DOMAIN" | cut -d. -f1 | tr "[:lower:]" "[:upper:]")

# FQDN del DC: obtener via registro SRV de LDAP del dominio
# Este metodo es mas confiable que PTR porque el registro SRV siempre existe en AD
DC_FQDN=$(host -t SRV "_ldap._tcp.dc._msdcs.${DC_DOMAIN}" "$DC_IP" 2>/dev/null |     awk "/has SRV record/{print \$NF}" | sed "s/\.$//" | head -1)

# Fallback: buscar via registro A del DC en la zona del dominio
if [[ -z "$DC_FQDN" ]]; then
    DC_FQDN=$(host -t A "${DC_DOMAIN}" "$DC_IP" 2>/dev/null |         awk "/has address $DC_IP/{print \$1}" | sed "s/\.$//" | head -1)
fi

# Fallback: obtener hostname del DC via LDAP (siempre disponible si el DC responde)
if [[ -z "$DC_FQDN" ]] && command -v ldapsearch &>/dev/null; then
    DC_FQDN=$(ldapsearch -x -H "ldap://${DC_IP}" -b "" -s base dnsHostName 2>/dev/null |         awk "/^dnsHostName:/{print \$2}" | head -1)
fi

# Fallback final: buscar todos los registros A del dominio y encontrar el que coincide con DC_IP
if [[ -z "$DC_FQDN" ]]; then
    DC_FQDN=$(host "${DC_DOMAIN}" "$DC_IP" 2>/dev/null |         grep "has address" | head -1 | awk "{print \$1}" | sed "s/\.${DC_DOMAIN}\.//")
    [[ -n "$DC_FQDN" ]] && DC_FQDN="${DC_FQDN}.${DC_DOMAIN}"
fi

# Si nada funciono, intentar resolver el hostname del DC via nmblookup
if [[ -z "$DC_FQDN" ]] && command -v nmblookup &>/dev/null; then
    local nb_name
    nb_name=$(nmblookup -A "$DC_IP" 2>/dev/null | awk "/<00>.*<UNIQUE>/{print \$1}" | head -1)
    [[ -n "$nb_name" ]] && DC_FQDN="${nb_name,,}.${DC_DOMAIN}"
fi

[[ -z "$DC_FQDN" ]] && DC_FQDN="${NETBIOS_NAME,,}-dc.${DC_DOMAIN}"
write_ad_log "DC_FQDN detectado: $DC_FQDN" "INFO" 2>/dev/null || true

write_ad_log() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp][$level] $message" | sudo tee -a "$TAREA08_LOG" > /dev/null
}

get_internal_iface() {
    ip -4 addr show | grep "192.168.100\." | awk '{print $NF}' | head -1
}

check_realm_joined() {
    if realm list 2>/dev/null | grep -q "domain-name"; then
        return 0
    fi
    return 1
}

backup_file() {
    local file="$1"
    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    local backup="${file}.bak-${timestamp}"

    if [[ -f "$file" ]]; then
        sudo cp "$file" "$backup"
        aputs_info "Backup creado: $backup"
        write_ad_log "Backup de $file -> $backup" "INFO"
    fi
}

export -f write_ad_log
export -f get_internal_iface
export -f check_realm_joined
export -f backup_file