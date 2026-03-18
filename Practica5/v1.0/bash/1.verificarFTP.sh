#
# Módulo: Verificar instalación y estado del servicio FTP (vsftpd)
#
# Requiere:
#   utils.sh 
#
# Rutas y nombres definidos aquí para mantener consistencia con los otros módulos
readonly FTP_PACKAGE="vsftpd"
readonly FTP_SERVICE="vsftpd"
readonly FTP_CONFIG="/etc/vsftpd/vsftpd.conf"
readonly FTP_ROOT="/srv/ftp"
readonly FTP_GENERAL="${FTP_ROOT}/general"
readonly FTP_USER_PREFIX="ftp_"
readonly FTP_SSH_GROUP="ftp_users"
readonly FTP_GROUPS_BASE=("reprobados" "recursadores")
readonly VSFTPD_DIR="/etc/vsftpd"
readonly VSFTPD_USERS_META="${VSFTPD_DIR}/ftp_users.meta"
readonly VSFTPD_GROUPS_FILE="${VSFTPD_DIR}/ftp_groups.list"
readonly FTP_PORT_CONTROL=21
readonly FTP_PORT_DATA=20
readonly FTP_ZONE_INTERNA="internal"

# ─── Función principal ───────────────────────────────────────────────────────

# Muestra un diagnóstico completo del estado del servicio FTP
# Se llama desde main_menu opción 1
verificar_ftp() {
    draw_header "Verificacion del Servicio FTP"

    # ── 1. Paquete vsftpd ────────────────────────────────────────────────────
    echo ""
    aputs_info "[ 1/7 ] Paquete vsftpd"
    draw_line

    if check_package_installed "$FTP_PACKAGE"; then
        # Obtener versión exacta instalada
        local version
        version=$(rpm -q "$FTP_PACKAGE" 2>/dev/null)
        aputs_success "Instalado: $version"
    else
        aputs_error "vsftpd NO esta instalado"
        aputs_info "Vaya a la opcion 2 para instalarlo"
        echo ""
        pause
        return 1
    fi

    # ── 2. Estado del servicio (activo / inactivo) ───────────────────────────
    echo ""
    aputs_info "[ 2/7 ] Estado del servicio"
    draw_line

    if check_service_active "$FTP_SERVICE"; then
        aputs_success "Servicio ACTIVO (corriendo ahora mismo)"
        # Mostrar tiempo de actividad del servicio
        local uptime
        uptime=$(systemctl show "$FTP_SERVICE" --property=ActiveEnterTimestamp \
            --no-pager 2>/dev/null | cut -d= -f2)
        [[ -n "$uptime" ]] && aputs_info "Activo desde: $uptime"
    else
        aputs_error "Servicio INACTIVO"
        # Mostrar el motivo del fallo si existe
        local estado
        estado=$(systemctl is-failed "$FTP_SERVICE" 2>/dev/null)
        [[ "$estado" == "failed" ]] && aputs_warning "El servicio tiene estado 'failed' — revise los logs"
        aputs_info "Inicie con: sudo systemctl start vsftpd"
    fi

    # ── 3. Habilitado en boot ────────────────────────────────────────────────
    echo ""
    aputs_info "[ 3/7 ] Habilitado en arranque (boot)"
    draw_line

    if check_service_enabled "$FTP_SERVICE"; then
        aputs_success "Habilitado — el servicio arranca automaticamente con el sistema"
    else
        aputs_warning "NO habilitado — el servicio no arrancara tras un reinicio"
        aputs_info "Habilite con: sudo systemctl enable vsftpd"
    fi

    # ── 4. Puerto en escucha ─────────────────────────────────────────────────
    echo ""
    aputs_info "[ 4/7 ] Puerto FTP en escucha"
    draw_line

    if check_port_listening "$FTP_PORT_CONTROL"; then
        aputs_success "Puerto $FTP_PORT_CONTROL (control FTP) en escucha"
    else
        aputs_error "Puerto $FTP_PORT_CONTROL NO esta en escucha"
        aputs_info "Causas posibles:"
        aputs_info "  - El servicio vsftpd no esta corriendo"
        aputs_info "  - listen=NO en /etc/vsftpd/vsftpd.conf"
        aputs_info "  - Otro proceso ocupa el puerto"
    fi

    # Verificar también si hay rango PASV configurado y activo
    if [[ -f "$FTP_CONFIG" ]]; then
        local pasv_min pasv_max
        pasv_min=$(grep -m1 "^pasv_min_port=" "$FTP_CONFIG" 2>/dev/null | cut -d= -f2)
        pasv_max=$(grep -m1 "^pasv_max_port=" "$FTP_CONFIG" 2>/dev/null | cut -d= -f2)
        if [[ -n "$pasv_min" && -n "$pasv_max" ]]; then
            aputs_info "Rango PASV configurado: $pasv_min - $pasv_max"
        fi
    fi

    # ── 5. Firewall ──────────────────────────────────────────────────────────
    echo ""
    aputs_info "[ 5/7 ] Firewall (firewalld)"
    draw_line

    if ! command -v firewall-cmd &>/dev/null; then
        aputs_warning "firewalld no esta disponible en este sistema"
    else
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            aputs_success "firewalld activo"

            # Verificar servicio ftp en zona internal (Red_Sistemas)
            if firewall-cmd --zone="$FTP_ZONE_INTERNA" --query-service=ftp \
               --permanent &>/dev/null 2>&1; then
                aputs_success "Servicio 'ftp' permitido en zona: $FTP_ZONE_INTERNA"
            else
                aputs_error "Servicio 'ftp' NO permitido en zona: $FTP_ZONE_INTERNA"
                aputs_info "Agregue con: sudo firewall-cmd --zone=$FTP_ZONE_INTERNA --add-service=ftp --permanent"
            fi

            # Verificar rango PASV en el firewall
            if [[ -f "$FTP_CONFIG" ]]; then
                local pmin pmax
                pmin=$(grep -m1 "^pasv_min_port=" "$FTP_CONFIG" 2>/dev/null | cut -d= -f2)
                pmax=$(grep -m1 "^pasv_max_port=" "$FTP_CONFIG" 2>/dev/null | cut -d= -f2)
                if [[ -n "$pmin" && -n "$pmax" ]]; then
                    if firewall-cmd --zone="$FTP_ZONE_INTERNA" \
                        --query-port="${pmin}-${pmax}/tcp" --permanent &>/dev/null 2>&1; then
                        aputs_success "Rango PASV $pmin-$pmax permitido en zona: $FTP_ZONE_INTERNA"
                    else
                        aputs_warning "Rango PASV $pmin-$pmax NO abierto en firewall"
                        aputs_info "Sin esto, el modo pasivo fallara para los clientes"
                    fi
                fi
            fi
        else
            aputs_warning "firewalld esta inactivo — no hay filtrado de puertos"
        fi
    fi

    # ── 6. Interfaces de red ─────────────────────────────────────────────────
    echo ""
    aputs_info "[ 6/7 ] Interfaces de red del servidor"
    draw_line

    local interfaz
    while IFS= read -r interfaz; do
        local ip
        ip=$(get_interface_ip "$interfaz")
        printf "  %-12s %s\n" "$interfaz" "$ip"
    done < <(get_network_interfaces)
    aputs_info "El servicio FTP estara disponible en todas las IPs listadas"

    # ── 7. Grupos y usuarios FTP ─────────────────────────────────────────────
    echo ""
    aputs_info "[ 7/7 ] Grupos y usuarios FTP"
    draw_line

    # Verificar grupos base
    local g
    for g in "${FTP_GROUPS_BASE[@]}"; do
        if getent group "$g" &>/dev/null; then
            aputs_success "Grupo '$g' existe en el sistema"
        else
            aputs_warning "Grupo '$g' NO existe — se creara en la instalacion"
        fi
    done

    # Verificar grupos adicionales del archivo de lista
    if [[ -f "$VSFTPD_GROUPS_FILE" && -s "$VSFTPD_GROUPS_FILE" ]]; then
        local grupos_extra=0
        while IFS= read -r linea; do
            linea="${linea%%#*}"; linea="${linea//[[:space:]]/}"
            [[ -z "$linea" ]] && continue
            # Solo mostrar grupos que no son los base
            local es_base=false
            for b in "${FTP_GROUPS_BASE[@]}"; do [[ "$linea" == "$b" ]] && es_base=true; done
            if ! $es_base; then
                if getent group "$linea" &>/dev/null; then
                    aputs_success "Grupo adicional '$linea' existe"
                else
                    aputs_warning "Grupo adicional '$linea' en lista pero NO en sistema"
                fi
                grupos_extra=$(( grupos_extra + 1 ))
            fi
        done < "$VSFTPD_GROUPS_FILE"
        [[ $grupos_extra -gt 0 ]] && aputs_info "$grupos_extra grupo(s) adicional(es) encontrados"
    fi

    # Contar usuarios FTP registrados
    if [[ -f "$VSFTPD_USERS_META" && -s "$VSFTPD_USERS_META" ]]; then
        local total_usuarios
        total_usuarios=$(grep -c "^[^#]" "$VSFTPD_USERS_META" 2>/dev/null || echo "0")
        aputs_info "Usuarios FTP registrados: $total_usuarios"
    else
        aputs_info "No hay usuarios FTP registrados todavia"
    fi

    # ── Archivo de configuración ─────────────────────────────────────────────
    echo ""
    draw_line
    if [[ -f "$FTP_CONFIG" ]]; then
        aputs_success "Archivo de configuracion: $FTP_CONFIG"
        # Mostrar directivas clave configuradas
        aputs_info "Directivas activas relevantes:"
        grep -E "^(listen|anonymous_enable|local_enable|write_enable|chroot_local_user|pasv_enable|pasv_min_port|pasv_max_port|max_clients|max_per_ip)" \
            "$FTP_CONFIG" 2>/dev/null | while IFS= read -r linea; do
                echo "  $linea"
        done
    else
        aputs_warning "Archivo $FTP_CONFIG no encontrado"
        aputs_info "Vaya a la opcion 2 para instalar y configurar vsftpd"
    fi

    draw_line
    echo ""
}