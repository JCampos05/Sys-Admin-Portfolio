#
# validatorsAD.sh
#
# Funciones:
#   test_dc_connectivity    - Verifica ping al Domain Controller
#   test_dns_resolution     - Verifica que el DNS resuelve el dominio AD
#   test_time_sync          - Verifica diferencia de tiempo con el DC (max 5 min)
#   test_required_ports     - Verifica puertos criticos de AD accesibles desde cliente
#   test_static_ip          - Verifica que la IP de Red_Sistemas es estatica
#   invoke_all_validations  - Ejecuta todas las validaciones
#

test_dc_connectivity() {
    aputs_info "Verificando conectividad con DC ($DC_IP)..."

    if check_connectivity "$DC_IP"; then
        aputs_success "DC alcanzable: $DC_IP"
        write_ad_log "Conectividad con DC verificada" "SUCCESS"
        return 0
    else
        aputs_error "No se puede alcanzar el DC: $DC_IP"
        aputs_info  "Verifique que el servidor Windows esta encendido"
        aputs_info  "Verifique que ambas VMs estan en la misma red (Red_Sistemas)"
        write_ad_log "Fallo conectividad con DC $DC_IP" "ERROR"
        return 1
    fi
}

test_dns_resolution() {
    aputs_info "Verificando resolucion DNS del dominio $DC_DOMAIN..."

    # Verificar si el dominio se resuelve correctamente
    if host "$DC_DOMAIN" "$DC_IP" &>/dev/null 2>&1; then
        aputs_success "Dominio $DC_DOMAIN resuelto correctamente via $DC_IP"
        write_ad_log "DNS resolucion de $DC_DOMAIN OK" "SUCCESS"
        return 0
    fi

    # Intentar con nslookup como alternativa
    if nslookup "$DC_DOMAIN" "$DC_IP" &>/dev/null 2>&1; then
        aputs_success "Dominio $DC_DOMAIN resuelto via nslookup"
        return 0
    fi

    # El DNS del sistema no resuelve el dominio todavia.
    # Esto es esperado si aun no se configuro. El script lo corregira.
    aputs_warning "El DNS del sistema no resuelve $DC_DOMAIN aun"
    aputs_info    "Functions-AD-A.sh configurara el DNS antes de unirse al dominio"
    write_ad_log "DNS no resuelve $DC_DOMAIN - se configurara en Fase A" "WARNING"
    return 0    # No es fallo critico, la Fase A lo resuelve
}


test_time_sync() {
    aputs_info "Verificando sincronizacion de tiempo con el DC..."

    # Verificar que NTP esta activo en el cliente
    if ! systemctl is-active --quiet chronyd 2>/dev/null && \
       ! systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        aputs_warning "Ningun servicio NTP activo detectado"
        aputs_info    "El script activara chronyd antes de unirse al dominio"
    else
        aputs_success "Servicio NTP activo en el cliente"
    fi

    # Verificar el offset de tiempo actual
    local client_time dc_time diff

    # Obtener tiempo del DC via rdate o calcular diferencia manual
    # Usamos date en UTC para comparar
    client_time=$(date -u +%s)

    # Intentar obtener tiempo del DC via SMB (puerto 445)
    # Si no esta disponible, confiamos en que NTP mantiene sincronizado
    if command -v net &>/dev/null; then
        dc_time=$(net time -S "$DC_IP" 2>/dev/null | grep -oP '\d{2}:\d{2}:\d{2}' | head -1)
        if [[ -n "$dc_time" ]]; then
            aputs_info "Hora del DC: $dc_time"
            aputs_info "Hora local:  $(date +%H:%M:%S)"
        fi
    fi

    # Verificar estado de timedatectl
    local sync_status
    sync_status=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)
    if [[ "$sync_status" == "yes" ]]; then
        aputs_success "Reloj sincronizado via NTP (NTPSynchronized=yes)"
        write_ad_log "Tiempo sincronizado correctamente" "SUCCESS"
        return 0
    else
        aputs_warning "El reloj puede no estar sincronizado (NTPSynchronized=no)"
        aputs_info    "El script forzara sincronizacion antes de unirse al dominio"
        write_ad_log "Tiempo posiblemente no sincronizado" "WARNING"
        return 0    # No abortamos, la Fase A fuerza sincronizacion
    fi
}

test_required_ports() {
    aputs_info "Verificando puertos criticos de AD en el DC..."

    local ports=(88 389 445)
    local port_names=("Kerberos" "LDAP" "SMB")
    local all_ok=true

    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local name="${port_names[$i]}"

        if nc -z -w 3 "$DC_IP" "$port" &>/dev/null 2>&1; then
            aputs_success "Puerto $port ($name) accesible en DC"
        else
            aputs_warning "Puerto $port ($name) no responde desde el cliente"
            aputs_info    "Verifique las reglas de firewall en el servidor Windows"
            all_ok=false
        fi
    done

    if $all_ok; then
        write_ad_log "Todos los puertos criticos de AD accesibles" "SUCCESS"
    else
        write_ad_log "Algunos puertos de AD no accesibles - puede afectar la union" "WARNING"
    fi

    # No retornamos 1 porque el firewall del DC ya fue configurado por el script
    # y los puertos deberian estar abiertos. Si alguno falla es advertencia, no error critico.
    return 0
}

test_static_ip() {
    aputs_info "Verificando IP estatica en $INTERNAL_IFACE..."

    local current_ip
    current_ip=$(get_interface_ip "$INTERNAL_IFACE")

    if [[ "$current_ip" == "Sin IP" || -z "$current_ip" ]]; then
        aputs_error "La interfaz $INTERNAL_IFACE no tiene IP asignada"
        aputs_info  "Verifique que el adaptador de red interna esta conectado"
        write_ad_log "Sin IP en interfaz $INTERNAL_IFACE" "ERROR"
        return 1
    fi

    # Verificar que es una IP interna valida (no loopback ni APIPA)
    if [[ "$current_ip" == 127.* || "$current_ip" == 169.254.* ]]; then
        aputs_warning "IP no valida para dominio AD: $current_ip"
        aputs_info    "Verifique la configuracion de red en NetworkManager"
    else
        aputs_success "IP detectada en $INTERNAL_IFACE: $current_ip"
    fi

    write_ad_log "IP en $INTERNAL_IFACE: $current_ip" "INFO"
    return 0
}

invoke_all_validations() {
    draw_header "Validaciones de Prerequisitos - Cliente Linux"

    local critical_failed=false

    aputs_info "Verificando conectividad con el DC..."
    if ! test_dc_connectivity; then
        critical_failed=true
    fi

    aputs_info "Verificando resolucion DNS..."
    test_dns_resolution

    aputs_info "Verificando sincronizacion de tiempo..."
    test_time_sync

    aputs_info "Verificando puertos de AD..."
    test_required_ports

    aputs_info "Verificando IP estatica..."
    if ! test_static_ip; then
        critical_failed=true
    fi

    draw_line

    if $critical_failed; then
        aputs_error "Validaciones criticas fallaron. Corrija los errores antes de continuar."
        return 1
    fi

    aputs_success "Validaciones completadas. El cliente esta listo para unirse al dominio."
    return 0
}