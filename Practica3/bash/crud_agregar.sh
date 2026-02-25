#!/bin/bash
#
# crud_agregar.sh
# Submódulo para agregar dominios y registros DNS
#

# Cargar utilidades
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/validators_dns.sh"

# Función para incrementar serial
incrementar_serial() {
    local fecha_hoy=$(date +%Y%m%d)
    echo "${fecha_hoy}01"
}

# Función para agregar zona a named.conf
agregar_zona_a_named_conf() {
    local dominio="$1"
    local tipo_zona="${2:-forward}"  # forward o reverse
    local nombre_archivo="${3:-$1}"

    local zona_entry=""
    
    if [[ "$tipo_zona" == "forward" ]]; then
        zona_entry="
// Zona: $dominio
zone \"$dominio\" IN {
    type master;
    file \"${dominio}.zone\";
    allow-update { none; };
};"
    else
        # Zona inversa
        local red_inversa="$dominio"
        zona_entry="
// Zona inversa: $dominio
zone \"${red_inversa}.in-addr.arpa\" IN {
    type master;
    file \"${nombre_archivo}.rev\";
    allow-update { none; };
};"
    fi
    
    # Agregar al final de named.conf
    echo "$zona_entry" | sudo tee -a /etc/named.conf > /dev/null
    
    if [[ $? -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Función para crear archivo de zona directa
crear_zona_directa() {
    local dominio="$1"
    local ip_principal="$2"
    local crear_www="$3"
    local tipo_www="$4"
    local crear_ns="$5"
    local nombre_ns="$6"
    local ip_ns="$7"
    local crear_mx="$8"
    local nombre_mail="$9"
    local ip_mail="${10}"
    local prioridad_mx="${11}"
    local ttl="${12:-86400}"
    
    local serial=$(incrementar_serial)
    local zona_file="/var/named/${dominio}.zone"
    local temp_file="/tmp/${dominio}.zone.tmp"
    
    # Crear archivo de zona
    cat > "$temp_file" << EOF
\$TTL ${ttl}
@   IN  SOA ${nombre_ns}.${dominio}. root.${dominio}. (
            ${serial}    ; Serial (YYYYMMDD01)
            3600         ; Refresh (1 hora)
            1800         ; Retry (30 minutos)
            604800       ; Expire (1 semana)
            86400 )      ; Minimum TTL (1 dia)

; Servidores de nombres
@       IN  NS      ${nombre_ns}.${dominio}.

; Registro A para el servidor NS
${nombre_ns}    IN  A       ${ip_ns}

; Registro A para el dominio raiz
@       IN  A       ${ip_principal}

EOF

    # Agregar WWW si se solicita
    if [[ "$tipo_www" == "cname" ]]; then
        echo "; Registro CNAME para www" >> "$temp_file"
        echo "www     IN  CNAME   ${dominio}." >> "$temp_file"
    else
        echo "; Registro A para www" >> "$temp_file"
        echo "www     IN  A       ${ip_principal}" >> "$temp_file"
    fi
    
    # Agregar MX si se solicita
    if [[ "$crear_mx" == "s" || "$crear_mx" == "S" ]]; then
        cat >> "$temp_file" << EOF
; Registro MX (Mail Exchange)
@       IN  MX  ${prioridad_mx} ${nombre_mail}.${dominio}.
${nombre_mail}  IN  A       ${ip_mail}

EOF
    fi
    
    # Copiar al sistema y establecer permisos
    if sudo cp "$temp_file" "$zona_file"; then
        sudo chmod 640 "$zona_file"
        sudo chown root:named "$zona_file"
        rm -f "$temp_file"
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

# Función para crear zona inversa
crear_zona_inversa() {
    local dominio="$1"
    local ip_principal="$2"
    local nombre_ns="$3"
    local ip_ns="$4"
    local ttl="${5:-86400}"
    
    # Extraer octetos de la IP
    local octeto4=$(echo "$ip_principal" | cut -d. -f4)
    local octeto3=$(echo "$ip_principal" | cut -d. -f3)
    local octeto2=$(echo "$ip_principal" | cut -d. -f2)
    local octeto1=$(echo "$ip_principal" | cut -d. -f1)
    
    local red_inversa="${octeto1}.${octeto2}.${octeto3}"
    local serial=$(incrementar_serial)
    
    local rev_file="/var/named/${dominio}.rev"
    local temp_file="/tmp/${dominio}.rev.tmp"
    
    cat > "$temp_file" << EOF
\$TTL ${ttl}
@   IN  SOA ${nombre_ns}.${dominio}. root.${dominio}. (
            ${serial}    ; Serial
            3600         ; Refresh
            1800         ; Retry
            604800       ; Expire
            86400 )      ; Minimum TTL

; Servidor de nombres
@       IN  NS      ${nombre_ns}.${dominio}.

; Registros PTR
${octeto4}    IN  PTR     ${dominio}.
${octeto4}    IN  PTR     ${nombre_ns}.${dominio}.
EOF

    # Copiar y establecer permisos
    if sudo cp "$temp_file" "$rev_file"; then
        sudo chmod 640 "$rev_file"
        sudo chown root:named "$rev_file"
        rm -f "$temp_file"
        
        # Agregar zona inversa a named.conf
        agregar_zona_a_named_conf "$red_inversa" "reverse" "$dominio"
        
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

# Función principal para agregar dominio completo
agregar_dominio_completo() {
    clear
    draw_header "Agregar Nuevo Dominio"
    
    # Parámetros obligatorios
    local nombre_dominio
    read -rp "Nombre del dominio (ej: ejemplo.com): " nombre_dominio
    
    if [[ -z "$nombre_dominio" ]]; then
        aputs_error "El nombre del dominio no puede estar vacio"
        return 1
    fi
    
    # Verificar si ya existe
    if ! dns_validar_nombre_dominio "$nombre_dominio"; then
        aputs_error "El dominio '$nombre_dominio' ya existe"
        return 1
    fi

    if [[ -f "/var/named/${nombre_dominio}.zone" ]]; then
        aputs_error "El dominio '$nombre_dominio' ya existe"
        return 1
    fi
    
    local ip_principal
    read -rp "IP principal del dominio: " ip_principal
    
    if ! dns_validar_ip "$ip_principal"; then
        aputs_error "IP invalida"
        return 1
    fi
    
    echo ""
    draw_line
    echo ""
    
    # Parámetros opcionales
    aputs_info "Configuracion adicional (opcional):"
    echo ""
    
    # Preguntar por www
    local crear_www
    read -rp "¿Crear registro www? (s/n) [s]: " crear_www
    crear_www=${crear_www:-s}

    local tipo_www="a"

    if [[ "$crear_www" == "s" || "$crear_www" == "S" ]]; then
        echo ""
        aputs_info "Tipo de registro para www:"
        echo "  1) CNAME (alias a ${nombre_dominio})"
        echo "  2) A (misma IP que @: ${ip_principal})"
        read -rp "Opcion [1]: " tipo_www_opcion
        tipo_www_opcion=${tipo_www_opcion:-1}

        if [[ "$tipo_www_opcion" == "1" ]]; then
            tipo_www="cname"
        else
            tipo_www="a"
        fi
    fi
    
    # NS (siempre se crea)
    local nombre_ns
    local nombres_reservados=("www" "ftp" "mail" "smtp" "pop" "imap" "webmail")

    while true; do
        read -rp "Nombre del servidor NS [ns1]: " nombre_ns
        nombre_ns=${nombre_ns:-ns1}
    
        local invalido=false
        for reservado in "${nombres_reservados[@]}"; do
            if [[ "$nombre_ns" == "$reservado" ]]; then
                invalido=true
                break
            fi
        done
    
        if [[ "$invalido" == "true" ]]; then
            aputs_error "'$nombre_ns' no puede usarse como NS, genera conflicto"
            aputs_info "Use nombres como: ns1, ns2, dns1"
        else
            break
        fi
    done
    
    local ip_ns
    read -rp "IP del servidor NS [${ip_principal}]: " ip_ns
    ip_ns=${ip_ns:-$ip_principal}
    
    if ! dns_validar_ip "$ip_ns"; then
        aputs_error "IP del NS invalida"
        return 1
    fi
    
    # MX
    local crear_mx
    read -rp "¿Crear registro MX (correo)? (s/n) [n]: " crear_mx
    crear_mx=${crear_mx:-n}
    
    local nombre_mail="mail"
    local ip_mail=""
    local prioridad_mx="10"
    
    if [[ "$crear_mx" == "s" || "$crear_mx" == "S" ]]; then
        read -rp "  Nombre del servidor de correo [mail]: " nombre_mail
        nombre_mail=${nombre_mail:-mail}
        
        read -rp "  IP del servidor de correo: " ip_mail
    if ! dns_validar_ip "$ip_mail"; then
        aputs_error "IP del servidor de correo invalida"
        return 1
    fi
        
        read -rp "  Prioridad MX [10]: " prioridad_mx
        prioridad_mx=${prioridad_mx:-10}
        while ! dns_validar_prioridad_mx "$prioridad_mx"; do
            read -rp "  Prioridad MX [10]: " prioridad_mx
            prioridad_mx=${prioridad_mx:-10}
        done
    fi
    
    # TTL
    local ttl
    read -rp "TTL para la zona (segundos) [86400]: " ttl
    ttl=${ttl:-86400}
    while ! dns_validar_ttl "$ttl"; do
        read -rp "TTL para la zona (segundos) [86400]: " ttl
        ttl=${ttl:-86400}
    done
    
    # Zona inversa
    local crear_zona_inversa
    read -rp "¿Crear zona inversa? (s/n) [s]: " crear_zona_inversa
    crear_zona_inversa=${crear_zona_inversa:-s}
    
    echo ""
    draw_line
    echo ""
    
    # Resumen
    aputs_info "Resumen de Configuracion:"
    echo ""
    echo "  Dominio: $nombre_dominio"
    echo "  IP principal: $ip_principal"
    echo "  Crear www: $crear_www ($tipo_www)"
    echo "  Servidor NS: ${nombre_ns}.${nombre_dominio} ($ip_ns)"
    echo "  Crear MX: $crear_mx"
    if [[ "$crear_mx" == "s" || "$crear_mx" == "S" ]]; then
        echo "    Mail: ${nombre_mail}.${nombre_dominio} ($ip_mail, prioridad: $prioridad_mx)"
    fi
    echo "  TTL: $ttl"
    echo "  Zona inversa: $crear_zona_inversa"
    echo ""
    
    local confirmar
    read -rp "¿Confirmar creacion del dominio? (s/n): " confirmar
    
    if [[ "$confirmar" != "s" && "$confirmar" != "S" ]]; then
        aputs_info "Creacion cancelada"
        return 0
    fi
    
    echo ""
    draw_line
    echo ""
    
    # Crear zona directa
    aputs_info "Creando zona directa..."
    
    if crear_zona_directa "$nombre_dominio" "$ip_principal" "$crear_www" "$tipo_www" \
                          "s" "$nombre_ns" "$ip_ns" "$crear_mx" "$nombre_mail" \
                          "$ip_mail" "$prioridad_mx" "$ttl"; then
        aputs_success "Zona directa creada: /var/named/${nombre_dominio}.zone"
    else
        aputs_error "Error al crear zona directa"
        return 1
    fi
    
    # Validar zona
    if sudo named-checkzone "$nombre_dominio" "/var/named/${nombre_dominio}.zone" &>/dev/null; then
        aputs_success "Zona directa validada correctamente"
    else
        aputs_error "Error de sintaxis en la zona directa"
        sudo named-checkzone "$nombre_dominio" "/var/named/${nombre_dominio}.zone" 2>&1 | sed 's/^/  /'
        return 1
    fi
    
    echo ""
    
    # Crear zona inversa
    if [[ "$crear_zona_inversa" == "s" || "$crear_zona_inversa" == "S" ]]; then
        aputs_info "Creando zona inversa..."
        
        if crear_zona_inversa "$nombre_dominio" "$ip_principal" "$nombre_ns" "$ip_ns" "$ttl"; then
            aputs_success "Zona inversa creada: /var/named/${nombre_dominio}.rev"
        else
            aputs_warning "Error al crear zona inversa (opcional)"
        fi
    fi
    
    echo ""
    
    # Agregar zona a named.conf
    aputs_info "Agregando zona a named.conf..."
    
    if agregar_zona_a_named_conf "$nombre_dominio" "forward"; then
        aputs_success "Zona agregada a named.conf"
    else
        aputs_error "Error al agregar zona a named.conf"
        return 1
    fi
    
    # Validar named.conf
    if sudo named-checkconf; then
        aputs_success "Configuracion de named.conf validada"
    else
        aputs_error "Error en named.conf"
        sudo named-checkconf 2>&1 | sed 's/^/  /'
        return 1
    fi
    
    echo ""
    draw_line
    echo ""
    
    # Reiniciar servicio
    aputs_warning "Se requiere reiniciar el servicio para aplicar cambios"
    local reiniciar
    read -rp "¿Reiniciar servicio named ahora? (s/n): " reiniciar
    
    if [[ "$reiniciar" == "s" || "$reiniciar" == "S" ]]; then
        aputs_info "Reiniciando servicio..."
        
        if sudo systemctl restart named 2>/tmp/named_restart_error.log; then
            sleep 2
            if check_service_active "named"; then
                aputs_success "Servicio reiniciado correctamente"
            else
                aputs_error "El servicio no se inicio correctamente"
            fi
        else
            aputs_error "Error al reiniciar servicio"
            cat /tmp/named_restart_error.log | sed 's/^/  /'
            sudo journalctl -u named -n 5 --no-pager 2>/dev/null | sed 's/^/  /'
        fi
    else
        aputs_info "Recuerde reiniciar el servicio manualmente"
    fi
    
    echo ""
    draw_line
    echo ""
    
    aputs_success "Dominio creadi Exitosamente"
    echo ""
    aputs_info "Puede probar la resolucion con:"
    echo "  dig @localhost $nombre_dominio"
    echo "  dig @localhost www.$nombre_dominio"
    echo ""
}

# Función para agregar registro a dominio existente
agregar_registro_menu() {
    clear
    draw_header "Agregar registro a Dominio Existente"
    
    # Listar dominios disponibles
    aputs_info "Dominios disponibles:"
    echo ""
    
    local dominios=()
    while IFS= read -r zona_file; do
        local dominio=$(basename "$zona_file" .zone)
        dominios+=("$dominio")
        echo "  - $dominio"
    done < <(sudo find /var/named -maxdepth 1 -name "*.zone" -type f 2>/dev/null | sort)
    
    if [[ ${#dominios[@]} -eq 0 ]]; then
        echo ""
        aputs_warning "No hay dominios configurados"
        aputs_info "Cree un dominio primero con la opcion '2) Agregar nuevo dominio'"
        return
    fi
    
    echo ""
    
    local dominio_destino
    read -rp "Dominio destino: " dominio_destino
    
    if [[ -z "$dominio_destino" ]]; then
        aputs_error "Debe especificar un dominio"
        return 1
    fi
    
    local zona_file="/var/named/${dominio_destino}.zone"
    
    if [[ ! -f "$zona_file" ]]; then
        aputs_error "El dominio '$dominio_destino' no existe"
        return 1
    fi
    
    echo ""
    aputs_info "Tipos de registro disponibles:"
    echo ""
    aputs_info "1) A (IPv4)"
    aputs_info "2) AAAA (IPv6)"
    aputs_info "3) CNAME (Alias)"
    aputs_info "4) MX (Mail)"
    aputs_info "5) TXT (Texto)"
    aputs_info "6) NS (Name Server)"
    echo ""
    
    local tipo_registro
    read -rp "Tipo de registro: " tipo_registro
    
    case $tipo_registro in
    1)
        agregar_registro_a "$dominio_destino"
        ;;
    2)
        agregar_registro_aaaa "$dominio_destino"
        ;;
    3)
        agregar_registro_cname "$dominio_destino"
        ;;
    4)
        agregar_registro_mx "$dominio_destino"
        ;;
    5)
        agregar_registro_txt "$dominio_destino"
        ;;
    6)
        agregar_registro_ns "$dominio_destino"
        ;;
    *)
        aputs_error "Tipo de registro invalido"
        ;;
    esac
}

# Funciones para agregar registros específicos
agregar_registro_a() {
    local dominio="$1"
    local zona_file="/var/named/${dominio}.zone"
    
    echo ""
    aputs_info "Agregar registro A (IPv4)"
    echo ""
    
    local nombre_host
    read -rp "Nombre del host (ej: ftp, servidor1): " nombre_host
    
    if [[ -z "$nombre_host" ]]; then
        aputs_error "El nombre no puede estar vacio"
        return 1
    fi
    
    local ip_host
    read -rp "Direccion IPv4: " ip_host
    
    if ! validate_ip "$ip_host"; then
        aputs_error "IP invalida"
        return 1
    fi
    
    # Crear backup
    sudo cp "$zona_file" "${zona_file}.backup_$(date +%Y%m%d_%H%M%S)"
    
    # Agregar registro
    echo "${nombre_host}    IN  A       ${ip_host}" | sudo tee -a "$zona_file" > /dev/null
    
    # Incrementar serial
    local serial_actual=$(sudo grep -m1 "Serial" "$zona_file" | grep -oP '\d{10}')
    local serial_nuevo=$(incrementar_serial)
    sudo sed -i "s/${serial_actual}/${serial_nuevo}/g" "$zona_file"
    
    # Validar
    if sudo named-checkzone "$dominio" "$zona_file" &>/dev/null; then
        aputs_success "Registro A agregado correctamente"
    else
        aputs_error "Error de sintaxis"
        return 1
    fi
}

agregar_registro_aaaa() {
    local dominio="$1"
    aputs_info "Registro AAAA (IPv6) - Funcionalidad en desarrollo"
}

agregar_registro_cname() {
    local dominio="$1"
    local zona_file="/var/named/${dominio}.zone"
    
    echo ""
    aputs_info "Agregar registro CNAME (Alias)"
    echo ""
    
    local nombre_alias
    read -rp "Nombre del alias (ej: blog, tienda): " nombre_alias
    
    if [[ -z "$nombre_alias" ]]; then
        aputs_error "El nombre no puede estar vacio"
        return 1
    fi
    
    local destino_alias
    read -rp "Destino (a que apunta, ej: www): " destino_alias
    
    if [[ -z "$destino_alias" ]]; then
        aputs_error "El destino no puede estar vacio"
        return 1
    fi
    
    # Crear backup
    sudo cp "$zona_file" "${zona_file}.backup_$(date +%Y%m%d_%H%M%S)"
    
    # Agregar registro
    echo "${nombre_alias}    IN  CNAME   ${destino_alias}.${dominio}." | sudo tee -a "$zona_file" > /dev/null
    
    # Incrementar serial
    local serial_actual=$(sudo grep -m1 "Serial" "$zona_file" | grep -oP '\d{10}')
    local serial_nuevo=$(incrementar_serial)
    sudo sed -i "s/${serial_actual}/${serial_nuevo}/g" "$zona_file"
    
    # Validar
    if sudo named-checkzone "$dominio" "$zona_file" &>/dev/null; then
        aputs_success "Registro CNAME agregado correctamente"
    else
        aputs_error "Error de sintaxis"
        return 1
    fi
}

agregar_registro_mx() {
    local dominio="$1"
    local zona_file="/var/named/${dominio}.zone"
    
    echo ""
    aputs_info "Agregar registro MX (Mail Exchange)"
    echo ""
    
    local servidor_mail
    read -rp "Nombre del servidor de correo (ej: mail2): " servidor_mail
    
    if [[ -z "$servidor_mail" ]]; then
        aputs_error "El nombre no puede estar vacio"
        return 1
    fi
    
    local prioridad
    read -rp "Prioridad [20]: " prioridad
    prioridad=${prioridad:-20}
    
    local ip_mail
    read -rp "IP del servidor de correo: " ip_mail
    
    if ! validate_ip "$ip_mail"; then
        aputs_error "IP invalida"
        return 1
    fi
    
    # Crear backup
    sudo cp "$zona_file" "${zona_file}.backup_$(date +%Y%m%d_%H%M%S)"
    
    # Agregar registros
    echo "@       IN  MX  ${prioridad} ${servidor_mail}.${dominio}." | sudo tee -a "$zona_file" > /dev/null
    echo "${servidor_mail}  IN  A       ${ip_mail}" | sudo tee -a "$zona_file" > /dev/null
    
    # Incrementar serial
    local serial_actual=$(sudo grep -m1 "Serial" "$zona_file" | grep -oP '\d{10}')
    local serial_nuevo=$(incrementar_serial)
    sudo sed -i "s/${serial_actual}/${serial_nuevo}/g" "$zona_file"
    
    # Validar
    if sudo named-checkzone "$dominio" "$zona_file" &>/dev/null; then
        aputs_success "Registro MX agregado correctamente"
    else
        aputs_error "Error de sintaxis"
        return 1
    fi
}

agregar_registro_txt() {
    local dominio="$1"
    local zona_file="/var/named/${dominio}.zone"
    
    echo ""
    aputs_info "Agregar registro TXT"
    echo ""
    
    local nombre_txt
    read -rp "Nombre (@ para raiz): " nombre_txt
    
    if [[ -z "$nombre_txt" ]]; then
        nombre_txt="@"
    fi
    
    local contenido_txt
    read -rp "Contenido del registro TXT: " contenido_txt
    
    if [[ -z "$contenido_txt" ]]; then
        aputs_error "El contenido no puede estar vacio"
        return 1
    fi
    
    # Crear backup
    sudo cp "$zona_file" "${zona_file}.backup_$(date +%Y%m%d_%H%M%S)"
    
    # Agregar registro
    echo "${nombre_txt}    IN  TXT     \"${contenido_txt}\"" | sudo tee -a "$zona_file" > /dev/null
    
    # Incrementar serial
    local serial_actual=$(sudo grep -m1 "Serial" "$zona_file" | grep -oP '\d{10}')
    local serial_nuevo=$(incrementar_serial)
    sudo sed -i "s/${serial_actual}/${serial_nuevo}/g" "$zona_file"
    
    # Validar
    if sudo named-checkzone "$dominio" "$zona_file" &>/dev/null; then
        aputs_success "Registro TXT agregado correctamente"
    else
        aputs_error "Error de sintaxis"
        return 1
    fi
}

agregar_registro_ns() {
    local dominio="$1"
    aputs_info "Registro NS (Name Server) - Funcionalidad en desarrollo"
}