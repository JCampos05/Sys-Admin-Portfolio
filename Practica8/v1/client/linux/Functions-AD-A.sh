#
# Functions-AD-A.sh
# 
# Funciones:
#   install_ad_packages     - Instala realmd, sssd, adcli y dependencias
#   configure_hostname      - Configura FQDN del cliente antes del join
#   configure_dns           - Configura DNS del adaptador interno
#   register_dns_client     - Registra el cliente en el DNS del DC
#   sync_time               - Fuerza sincronizacion NTP antes de Kerberos
#   discover_domain         - Verifica que realm puede ver el dominio
#   join_domain             - Une el equipo al dominio AD
#   configure_sssd          - Escribe sssd.conf con la configuracion requerida
#   configure_homedir       - Activa creacion automatica de home al primer login
#   configure_sudo          - Agrega administradores de AD al archivo sudoers
#   verify_ad_integration   - Verifica que un usuario de AD es resolvible
#   invoke_phase_a          - Funcion principal que orquesta toda la fase
#

install_ad_packages() {
    draw_header "Paso 1/10: Instalando paquetes para union a AD"
    write_ad_log "Iniciando instalacion de paquetes AD" "INFO"

    local packages=(realmd sssd sssd-ad sssd-tools adcli oddjob
                    oddjob-mkhomedir samba-common-tools krb5-workstation
                    authselect bind-utils)

    aputs_info "Actualizando cache de repositorios..."
    sudo dnf makecache -q 2>/dev/null

    aputs_info "Instalando paquetes: ${packages[*]}"
    if sudo dnf install -y "${packages[@]}" &>/dev/null; then
        aputs_success "Todos los paquetes instalados correctamente"
        write_ad_log "Paquetes instalados OK" "SUCCESS"
        return 0
    fi

    local failed=()
    for pkg in "${packages[@]}"; do
        sudo dnf install -y "$pkg" &>/dev/null || failed+=("$pkg")
    done

    for critical in realmd sssd adcli; do
        if [[ " ${failed[*]} " =~ " ${critical} " ]]; then
            aputs_error "Paquete critico '$critical' no instalado. Abortando."
            return 1
        fi
    done
    [[ ${#failed[@]} -gt 0 ]] && aputs_warning "Paquetes opcionales fallidos: ${failed[*]}"
    return 0
}

configure_hostname() {
    draw_header "Paso 2/10: Configurando FQDN del cliente"
    write_ad_log "Configurando hostname FQDN" "INFO"

    local short_name fqdn client_ip
    short_name=$(hostname -s 2>/dev/null || hostname)
    fqdn="${short_name}.${DC_DOMAIN}"
    client_ip=$(get_interface_ip "$INTERNAL_IFACE")

    aputs_info "Nombre corto: $short_name"
    aputs_info "FQDN objetivo: $fqdn"
    aputs_info "IP cliente: $client_ip"

    sudo hostnamectl set-hostname "$fqdn" 2>/dev/null || \
        echo "$fqdn" | sudo tee /etc/hostname > /dev/null

    if ! grep -q "$fqdn" /etc/hosts 2>/dev/null; then
        backup_file "/etc/hosts"
        echo "$client_ip    $fqdn    $short_name" | sudo tee -a /etc/hosts > /dev/null
        aputs_success "Entrada agregada en /etc/hosts: $client_ip $fqdn"
    else
        aputs_info "Entrada FQDN ya existe en /etc/hosts"
    fi

    local result_fqdn
    result_fqdn=$(hostname -f 2>/dev/null)
    if [[ "$result_fqdn" == "$fqdn" ]]; then
        aputs_success "FQDN configurado: $result_fqdn"
        write_ad_log "FQDN OK: $result_fqdn" "SUCCESS"
    else
        aputs_warning "hostname -f: $result_fqdn (esperado: $fqdn)"
        write_ad_log "FQDN parcial: $result_fqdn" "WARNING"
    fi
    return 0
}

# -------------------------------------------------------------------------
# configure_dns
# Configura el DNS de ens192 para que apunte al DC via NetworkManager.
# -------------------------------------------------------------------------
configure_dns() {
    draw_header "Paso 3/10: Configurando DNS para resolver el dominio AD"
    write_ad_log "Configurando DNS $INTERNAL_IFACE -> $DC_IP" "INFO"

    local conn_name
    conn_name=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | \
                grep "$INTERNAL_IFACE" | cut -d: -f1 | head -1)
    [[ -z "$conn_name" ]] && conn_name="$INTERNAL_IFACE"

    aputs_info "Conexion NetworkManager: $conn_name"

    if sudo nmcli con modify "$conn_name" \
        ipv4.dns "$DC_IP" \
        ipv4.dns-search "$DC_DOMAIN" \
        ipv4.ignore-auto-dns yes 2>/dev/null; then
        aputs_success "DNS configurado via NetworkManager: $DC_IP"
        write_ad_log "DNS $DC_IP en $conn_name OK" "SUCCESS"
    else
        aputs_warning "nmcli fallo. Configurando via systemd-resolved..."
        sudo mkdir -p /etc/systemd/resolved.conf.d
        sudo tee /etc/systemd/resolved.conf.d/ad-dns.conf > /dev/null << EOF
[Resolve]
DNS=$DC_IP
Domains=$DC_DOMAIN
EOF
        write_ad_log "DNS via resolved.conf.d" "SUCCESS"
    fi

    sudo nmcli con up "$conn_name" &>/dev/null || true
    sudo systemctl restart systemd-resolved &>/dev/null || true
    sleep 3

    if host "$DC_DOMAIN" "$DC_IP" &>/dev/null 2>&1; then
        aputs_success "Dominio $DC_DOMAIN resuelto via $DC_IP"
    else
        aputs_warning "Resolucion DNS puede tardar unos segundos. Continuando..."
    fi
    return 0
}

register_dns_client() {
    local admin_password="$1"

    draw_header "Paso 4/10: Registrando cliente en DNS del DC"
    write_ad_log "Registrando cliente en DNS de $DC_IP" "INFO"

    local client_ip short_name fqdn
    client_ip=$(get_interface_ip "$INTERNAL_IFACE")
    short_name=$(hostname -s 2>/dev/null || hostname)
    fqdn="${short_name}.${DC_DOMAIN}"

    aputs_info "Registrando: $fqdn -> $client_ip en DNS $DC_IP"

    # Metodo 1: net ads dns register via samba-common-tools con Kerberos
    if command -v net &>/dev/null; then
        aputs_info "Intentando registro via net ads dns register..."
        if echo "$admin_password" | kinit "${ADMIN_USER}@${DC_REALM}" &>/dev/null 2>&1; then
            if sudo net ads dns register "$fqdn" "$client_ip" -k &>/dev/null 2>&1; then
                aputs_success "Registrado en DNS via net ads: $fqdn -> $client_ip"
                write_ad_log "DNS via net ads OK: $fqdn -> $client_ip" "SUCCESS"
                kdestroy &>/dev/null 2>&1 || true
                return 0
            fi
            kdestroy &>/dev/null 2>&1 || true
        fi
    fi

    # Metodo 2: nsupdate con autenticacion GSS-TSIG
    if command -v nsupdate &>/dev/null; then
        aputs_info "Intentando registro via nsupdate..."
        echo "$admin_password" | kinit "${ADMIN_USER}@${DC_REALM}" &>/dev/null 2>&1
        if printf "server %s\nzone %s\nupdate delete %s A\nupdate add %s 3600 A %s\nsend\n" \
            "$DC_IP" "$DC_DOMAIN" "$fqdn" "$fqdn" "$client_ip" | \
            sudo nsupdate -g &>/dev/null 2>&1; then
            aputs_success "Registrado en DNS via nsupdate: $fqdn -> $client_ip"
            write_ad_log "DNS via nsupdate OK: $fqdn -> $client_ip" "SUCCESS"
            kdestroy &>/dev/null 2>&1 || true
            return 0
        fi
        kdestroy &>/dev/null 2>&1 || true
    fi

    # Metodo 3: Verificar si ya esta registrado (lo hizo Windows previamente)
    aputs_info "Verificando si el DNS ya fue registrado desde el servidor Windows..."
    if host "$fqdn" "$DC_IP" &>/dev/null 2>&1; then
        aputs_success "DNS ya registrado correctamente: $fqdn -> $client_ip"
        write_ad_log "DNS ya existia en DC: $fqdn" "SUCCESS"
        return 0
    fi

    draw_line
    aputs_error "ATENCION: El DNS del cliente NO esta registrado en el DC."
    aputs_error "El join fallara con error GSSAPI si continua sin registrarlo."
    echo ""
    aputs_info "Ejecute el siguiente comando en el servidor Windows AHORA:"
    echo ""
    echo "  powershell -ExecutionPolicy Bypass -File "C:\Users\Administrador\Documents\Scripts\P8\Register-ClientDNS.ps1""
    echo ""
    echo "  O manualmente:"
    echo "  Add-DnsServerResourceRecordA \"
    echo "      -ZoneName '$DC_DOMAIN' \"
    echo "      -Name '$short_name' \"
    echo "      -IPv4Address '$client_ip' \"
    echo "      -TimeToLive 01:00:00"
    echo ""
    draw_line

    # Esperar confirmacion del usuario
    local max_wait=10
    local attempt=0
    while [[ $attempt -lt $max_wait ]]; do
        echo -ne "${CYAN}[INPUT]${NC} Presione Enter cuando haya registrado el DNS en Windows (intento $((attempt+1))/$max_wait)..."
        read -r
        attempt=$((attempt+1))

        # Verificar si ya se registro
        if host "$fqdn" "$DC_IP" &>/dev/null 2>&1; then
            aputs_success "DNS verificado: $fqdn ya resuelve correctamente"
            write_ad_log "DNS registrado por usuario: $fqdn" "SUCCESS"
            return 0
        else
            aputs_warning "DNS aun no resuelve $fqdn. Verificando..."
            sleep 3
            if host "$fqdn" "$DC_IP" &>/dev/null 2>&1; then
                aputs_success "DNS registrado: $fqdn -> $client_ip"
                write_ad_log "DNS OK: $fqdn" "SUCCESS"
                return 0
            fi
            if [[ $attempt -lt $max_wait ]]; then
                aputs_warning "Aun no resuelve. Registrelo en Windows y presione Enter de nuevo."
            fi
        fi
    done

    aputs_error "DNS no registrado despues de $max_wait intentos."
    aputs_error "El join continuara pero sssd puede quedar Offline."
    aputs_error "Despues del join ejecute: sudo realm leave && sudo bash main.sh"
    write_ad_log "DNS no registrado - continuando con advertencia" "WARNING"
    return 1
}

# -------------------------------------------------------------------------
# sync_time
# Fuerza sincronizacion NTP. Kerberos rechaza con diferencia > 5 minutos.
# -------------------------------------------------------------------------
sync_time() {
    draw_header "Paso 5/10: Sincronizando tiempo con el DC"
    write_ad_log "Forzando sincronizacion NTP" "INFO"

    systemctl is-active --quiet chronyd || sudo systemctl enable --now chronyd &>/dev/null
    sudo chronyc makestep &>/dev/null || true
    sleep 2

    local sync_status
    sync_status=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)
    if [[ "$sync_status" == "yes" ]]; then
        aputs_success "Tiempo sincronizado: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        write_ad_log "Tiempo sincronizado OK" "SUCCESS"
    else
        aputs_warning "NTPSynchronized=no. Hora: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    fi
    return 0
}

# -------------------------------------------------------------------------
# discover_domain
# Verifica que realm puede descubrir el dominio antes del join.
# -------------------------------------------------------------------------
discover_domain() {
    draw_header "Paso 6/10: Descubriendo el dominio $DC_DOMAIN"
    write_ad_log "realm discover $DC_DOMAIN" "INFO"

    local output
    output=$(sudo realm discover "$DC_IP" 2>&1)
    if ! echo "$output" | grep -q "domain-name:"; then
        output=$(sudo realm discover "$DC_DOMAIN" 2>&1)
    fi

    if echo "$output" | grep -q "domain-name:"; then
        aputs_success "Dominio $DC_DOMAIN descubierto"
        echo "$output" | while IFS= read -r line; do aputs_info "  $line"; done
        write_ad_log "realm discover OK" "SUCCESS"
        return 0
    else
        aputs_error "No se pudo descubrir $DC_DOMAIN"
        aputs_error "Salida: $output"
        write_ad_log "realm discover fallo: $output" "ERROR"
        return 1
    fi
}

# -------------------------------------------------------------------------
# join_domain
# Une el equipo al dominio. Idempotente: si ya esta unido, retorna 0.
# -------------------------------------------------------------------------
join_domain() {
    local admin_password="$1"

    draw_header "Paso 7/10: Uniendo el equipo al dominio $DC_DOMAIN"
    write_ad_log "Iniciando join a $DC_DOMAIN" "INFO"

    if check_realm_joined; then
        local current_domain
        current_domain=$(realm list 2>/dev/null | grep "domain-name" | awk '{print $2}')
        aputs_info "Ya unido al dominio: $current_domain"
        write_ad_log "Ya unido a $current_domain" "INFO"
        return 0
    fi

    if [[ -f /etc/krb5.keytab ]]; then
        local kvno_fqdn
        kvno_fqdn=$(sudo klist -k /etc/krb5.keytab 2>/dev/null | grep -i "reprobados.local@" | grep -v "$" | head -1)
        if [[ -z "$kvno_fqdn" ]]; then
            aputs_warning "Keytab existente sin FQDN detectado. Limpiando para regenerar..."
            sudo realm leave "$DC_DOMAIN" &>/dev/null || true
            aputs_info "Keytab anterior eliminado. Procediendo con join limpio."
        fi
    fi

    aputs_info "Ejecutando realm join para $DC_DOMAIN..."
    aputs_warning "Este proceso puede tardar 30-60 segundos..."


    local output
    output=$(echo "$admin_password" | sudo realm join \
        --user="$ADMIN_USER" \
        "$DC_DOMAIN" 2>&1)

    if [[ $? -eq 0 ]]; then
        aputs_success "Union a $DC_DOMAIN completada"
        write_ad_log "Join exitoso a $DC_DOMAIN" "SUCCESS"
        realm list | while IFS= read -r line; do aputs_info "  $line"; done
        return 0
    else
        aputs_error "Join fallo: $output"
        aputs_info  "Si la cuenta del equipo ya existe: sudo realm leave && vuelva a ejecutar"
        write_ad_log "Join fallo: $output" "ERROR"
        return 1
    fi
}

# -------------------------------------------------------------------------
# configure_sssd
# Escribe /etc/sssd/sssd.conf con fallback_homedir=/home/%u@%d (requerido).
# -------------------------------------------------------------------------
configure_sssd() {
    draw_header "Paso 8/10: Configurando sssd.conf"
    write_ad_log "Configurando /etc/sssd/sssd.conf" "INFO"

    backup_file "/etc/sssd/sssd.conf"

    # ad_hostname con el FQDN para que Kerberos encuentre el equipo
    local client_fqdn
    client_fqdn="$(hostname -s 2>/dev/null || hostname).${DC_DOMAIN}"

    sudo tee /etc/sssd/sssd.conf > /dev/null << EOF
#
# sssd.conf - Configurado por Functions-AD-A.sh - Tarea 08
#
[sssd]
domains = $DC_DOMAIN
services = nss, pam

[domain/$DC_DOMAIN]
id_provider = ad
auth_provider = ad
access_provider = ad
chpass_provider = ad

ad_domain = $DC_DOMAIN
krb5_realm = $DC_REALM
# ad_server debe ser el FQDN del DC, NO su IP.
# Kerberos verifica el SPN ldap/nombre.dominio y con IP falla.
ad_server = $DC_FQDN

# Requerido por la practica
fallback_homedir = /home/%u@%d
default_shell = /bin/bash

use_fully_qualified_names = True
cache_credentials = True
krb5_store_password_if_offline = True
enumerate = True

# FQDN del cliente para Kerberos
ad_hostname = $client_fqdn
EOF

    sudo chmod 600 /etc/sssd/sssd.conf
    sudo chown root:root /etc/sssd/sssd.conf
    aputs_success "sssd.conf escrito (permisos 600)"

    sudo systemctl enable sssd &>/dev/null
    sudo systemctl restart sssd
    sleep 5

    if check_service_active "sssd"; then
        aputs_success "Servicio sssd activo"
        write_ad_log "sssd activo OK" "SUCCESS"
        return 0
    else
        aputs_error "sssd no arranco:"
        sudo journalctl -u sssd --no-pager -n 10 2>/dev/null | tail -8
        write_ad_log "sssd no arranco" "ERROR"
        return 1
    fi
}

# -------------------------------------------------------------------------
# configure_homedir
# Activa creacion automatica del directorio home al primer login.
# -------------------------------------------------------------------------
configure_homedir() {
    draw_header "Paso 9/10: Configurando creacion automatica de home"
    write_ad_log "Configurando mkhomedir" "INFO"

    if sudo authselect select sssd with-mkhomedir --force &>/dev/null; then
        aputs_success "authselect: sssd with-mkhomedir aplicado"
    else
        aputs_warning "authselect fallo. Configurando pam_mkhomedir manualmente..."
        grep -q "pam_mkhomedir" /etc/pam.d/system-auth 2>/dev/null || \
            sudo sed -i '/^session.*pam_unix/a session     optional      pam_mkhomedir.so skel=/etc/skel umask=077' \
            /etc/pam.d/system-auth 2>/dev/null
    fi

    sudo systemctl enable --now oddjobd &>/dev/null
    check_service_active "oddjobd" && \
        aputs_success "oddjobd activo (mkhomedir habilitado)" || \
        aputs_warning "oddjobd no arranco"

    write_ad_log "mkhomedir configurado" "SUCCESS"
    return 0
}

# -------------------------------------------------------------------------
# configure_sudo
# Configura sudo para administradores de AD.
# Formato correcto en Fedora: %domain\ admins (backslash escapa el espacio)
# -------------------------------------------------------------------------
configure_sudo() {
    draw_header "Paso 10/10: Configurando sudo para administradores de AD"
    write_ad_log "Configurando /etc/sudoers.d/ad-admins" "INFO"

    backup_file "/etc/sudoers.d/ad-admins"

    sudo tee /etc/sudoers.d/ad-admins > /dev/null << 'SUDOERS_EOF'
#
# ad-admins - Tarea 08
# Permisos sudo para administradores del dominio Active Directory
# El espacio en "Domain Admins" se escapa con backslash (\)
#
%domain\ admins@reprobados.local ALL=(ALL) NOPASSWD:ALL
Administrador@reprobados.local ALL=(ALL) NOPASSWD:ALL
SUDOERS_EOF

    sudo chmod 440 /etc/sudoers.d/ad-admins
    sudo chown root:root /etc/sudoers.d/ad-admins

    if sudo visudo -c -f /etc/sudoers.d/ad-admins &>/dev/null; then
        aputs_success "/etc/sudoers.d/ad-admins OK"
        write_ad_log "sudoers ad-admins OK" "SUCCESS"
        return 0
    else
        aputs_error "Error de sintaxis en sudoers. Eliminando archivo..."
        sudo rm -f /etc/sudoers.d/ad-admins
        write_ad_log "Error sintaxis sudoers" "ERROR"
        return 1
    fi
}

# -------------------------------------------------------------------------
# verify_ad_integration
# Verifica resolucion de usuarios AD. Si hay error Kerberos, muestra el
# comando exacto para registrar el cliente en el DNS del DC.
# -------------------------------------------------------------------------
verify_ad_integration() {
    draw_header "Verificando integracion con Active Directory"
    write_ad_log "Verificando integracion AD" "INFO"

    aputs_info "Esperando sincronizacion de sssd con el DC (20 segundos)..."
    sleep 20
    sudo sss_cache -E &>/dev/null || true
    sleep 3

    local test_user="user01@${DC_DOMAIN}"
    aputs_info "Resolviendo: $test_user"

    local user_info
    user_info=$(id "$test_user" 2>&1)

    if echo "$user_info" | grep -q "uid="; then
        aputs_success "Integracion verificada: $user_info"
        write_ad_log "Integracion AD OK: $user_info" "SUCCESS"
    else
        aputs_warning "Usuario no resuelto aun."

        local sssd_error
        sssd_error=$(sudo journalctl -u sssd --no-pager -n 10 2>/dev/null | \
                     grep -i "GSSAPI\|Server not found\|Kerberos\|error" | tail -3)

        if [[ -n "$sssd_error" ]]; then
            aputs_error "Error detectado en sssd:"
            echo "$sssd_error" | while IFS= read -r line; do aputs_info "  $line"; done
        fi

        local short_name client_ip
        short_name=$(hostname -s 2>/dev/null || hostname)
        client_ip=$(get_interface_ip "$INTERNAL_IFACE")

        echo ""
        aputs_warning "Si el error es GSSAPI / Server not found, ejecute en el servidor Windows:"
        echo ""
        echo "  Add-DnsServerResourceRecordA \\"
        echo "      -ZoneName '$DC_DOMAIN' \\"
        echo "      -Name '$short_name' \\"
        echo "      -IPv4Address '$client_ip' \\"
        echo "      -TimeToLive 01:00:00"
        echo ""
        aputs_info "Luego en este cliente:"
        echo "  sudo systemctl restart sssd && sleep 15 && id user01@$DC_DOMAIN"
        echo ""
        write_ad_log "Verificacion: usuario no resuelto - $user_info" "WARNING"
    fi

    aputs_info "Estado realm:"
    realm list | while IFS= read -r line; do aputs_info "  $line"; done
    return 0
}

# -------------------------------------------------------------------------
# invoke_phase_a
# Orquestador de los 10 pasos en orden.
# -------------------------------------------------------------------------
invoke_phase_a() {
    draw_header "Fase A: Union del Cliente Linux al Dominio AD"
    write_ad_log "=== INICIO FASE A ===" "INFO"

    draw_line
    aputs_info "Dominio: $DC_DOMAIN | DC: $DC_IP | Usuario: $ADMIN_USER"
    draw_line
    echo -ne "${CYAN}[INPUT]${NC} Contrasena de $ADMIN_USER@$DC_DOMAIN: "
    read -rs admin_password
    echo ""

    [[ -z "$admin_password" ]] && { aputs_error "Contrasena vacia. Abortando."; return 1; }

    install_ad_packages || return 1
    configure_hostname
    configure_dns
    # register_dns_client puede retornar 1 si el DNS no se pudo registrar
    # pero el usuario confirmo continuar. No abortamos en ese caso.
    register_dns_client "$admin_password" || true
    sync_time
    discover_domain || return 1
    join_domain "$admin_password" || { admin_password=""; return 1; }
    admin_password=""
    configure_sssd || return 1
    configure_homedir
    configure_sudo
    verify_ad_integration

    write_ad_log "=== FIN FASE A ===" "SUCCESS"
    aputs_success "Fase A completada: cliente Linux unido al dominio $DC_DOMAIN"
    return 0
}