#
# Monitoreo del servicio SSH: estado, conexiones activas y logs
#
# Depende de: utils.sh, validators_ssh.sh
#

# ─── Estado del servicio ──────────────────────────────────────────────────────
_mostrar_estado_servicio() {
    draw_header "Estado del Servicio SSH"

    if check_service_active "sshd"; then
        aputs_success "Estado: ACTIVO"
        echo ""

        # PID: identificador del proceso en el sistema operativo
        local pid
        pid=$(sudo systemctl show sshd --property=MainPID --value 2>/dev/null)
        if [[ -n "$pid" && "$pid" != "0" ]]; then
            echo "  PID del proceso : $pid"

            # Uso de CPU del proceso (ps -p pid -o %cpu)
            if command -v ps &>/dev/null; then
                local cpu
                cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
                [[ -n "$cpu" ]] && echo "  CPU actual      : ${cpu}%"
            fi
        fi

        # Memoria consumida por el servicio
        local memory
        memory=$(sudo systemctl show sshd --property=MemoryCurrent --value 2>/dev/null)
        if [[ -n "$memory" && "$memory" != "[not set]" && "$memory" -gt 0 ]]; then
            local memory_mb=$(( memory / 1024 / 1024 ))
            echo "  Memoria         : ${memory_mb} MB"
        fi

        # Timestamp desde que está activo
        local desde
        desde=$(sudo systemctl show sshd --property=ActiveEnterTimestamp --value 2>/dev/null)
        [[ -n "$desde" ]] && echo "  Activo desde    : $desde"

        # Inicio automático
        if check_service_enabled "sshd"; then
            echo "  Inicio en boot  : HABILITADO"
        else
            echo "  Inicio en boot  : DESHABILITADO"
            aputs_warning "El servicio no arrancara al reiniciar"
        fi

    else
        aputs_error "Estado: INACTIVO"
        echo ""
        aputs_info "Inicie el servicio con: sudo systemctl start sshd"
    fi

    echo ""

    # Puerto en escucha
    aputs_info "Puerto en escucha:"
    echo ""

    local puerto=22
    if [[ -f /etc/ssh/sshd_config ]]; then
        local p
        p=$(sudo grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}')
        [[ -n "$p" ]] && puerto="$p"
    fi

    local tcp_info
    tcp_info=$(sudo ss -tlnp 2>/dev/null | grep ":${puerto} ")

    if [[ -n "$tcp_info" ]]; then
        aputs_success "  Puerto ${puerto}/TCP — Escuchando"
        echo "$tcp_info" | awk '{print "       Direccion: " $4}'
    else
        echo "  [--] Puerto ${puerto}/TCP — No escuchando"
        (( errores++ ))
    fi
}

# ─── Conexiones activas ───────────────────────────────────────────────────────
_mostrar_conexiones_activas() {
    draw_header "Conexiones SSH Activas"

    # Las sesiones SSH aparecen con pts/ (pseudo-terminal)
    local sesiones
    sesiones=$(who 2>/dev/null | grep "pts/")

    if [[ -n "$sesiones" ]]; then
        local total
        total=$(echo "$sesiones" | wc -l)
        aputs_info "Sesiones activas: $total"
        echo ""

        # Encabezado de tabla
        printf "  %-15s %-10s %-20s %-20s\n" "USUARIO" "TERMINAL" "DESDE" "IP ORIGEN"
        echo "────────────────────────────────────────────────────────────────────────────────"

        while IFS= read -r sesion; do
            local usuario terminal fecha ip
            usuario=$(echo "$sesion" | awk '{print $1}')
            terminal=$(echo "$sesion" | awk '{print $2}')
            fecha=$(echo "$sesion" | awk '{print $3, $4}')
            ip=$(echo "$sesion" | grep -oP '\(\K[^)]+')

            printf "  %-15s %-10s %-20s %-20s\n" \
                   "$usuario" "$terminal" "$fecha" "${ip:-local}"
        done <<< "$sesiones"

    else
        aputs_info "No hay sesiones SSH activas en este momento"
    fi

    echo ""

    # ss (socket statistics) para ver conexiones TCP en puerto SSH
    aputs_info "Conexiones TCP en puerto $puerto (ss):"
    echo ""

    local conexiones_tcp
    conexiones_tcp=$(sudo ss -tnp 2>/dev/null | grep ":${puerto:-22}")

    if [[ -n "$conexiones_tcp" ]]; then
        printf "  %-12s %-25s %-25s\n" "ESTADO" "LOCAL" "REMOTO"
        draw_line
        echo "$conexiones_tcp" | while read -r linea; do
            local estado local_addr remote_addr
            estado=$(echo "$linea" | awk '{print $1}')
            local_addr=$(echo "$linea" | awk '{print $4}')
            remote_addr=$(echo "$linea" | awk '{print $5}')
            printf "  %-12s %-25s %-25s\n" "$estado" "$local_addr" "$remote_addr"
        done
    else
        aputs_info "Sin conexiones TCP establecidas en este momento"
    fi
}

# ─── Configuración activa ─────────────────────────────────────────────────────
_mostrar_config_activa() {
    draw_header "Configuracion Activa de sshd_config"

    if [[ ! -f /etc/ssh/sshd_config ]]; then
        aputs_error "No se encontro /etc/ssh/sshd_config"
        return
    fi

    # Extraer los parámetros más relevantes para seguridad
    echo ""
    aputs_info "Parametros de seguridad relevantes:"
    echo ""

    local parametros=(
        "Port"
        "PermitRootLogin"
        "PasswordAuthentication"
        "PubkeyAuthentication"
        "MaxAuthTries"
        "LoginGraceTime"
        "MaxSessions"
        "X11Forwarding"
        "AllowUsers"
        "Banner"
    )

    for param in "${parametros[@]}"; do
        # Buscar el parámetro activo (sin # al inicio)
        local valor
        valor=$(sudo grep -E "^${param}\b" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')

        if [[ -n "$valor" ]]; then
            printf "  %-28s -> %s\n" "$param" "$valor"
        else
            printf "  %-28s -> (predeterminado del sistema)\n" "$param"
        fi
    done
}

# ─── Logs del servicio ────────────────────────────────────────────────────────
_mostrar_logs() {
    clear
    draw_header "Logs del Servicio SSH"

    echo ""
    aputs_info "Cuantas lineas de log desea ver?"
    aputs_info "Rango valido: 10 a 500 lineas"
    echo ""

    local lineas
    while true; do
        agets "Numero de lineas [50]" lineas
        lineas="${lineas:-50}"
        if ssh_validar_lineas_log "$lineas"; then
            break
        fi
        echo ""
    done

    echo ""
    draw_line
    aputs_info "Ultimas $lineas lineas de log de sshd:"
    draw_line
    echo ""

    # journalctl lee los logs del sistema de journald
    # -u sshd: filtrar solo el servicio sshd
    # -n: número de líneas
    # --no-pager: no paginar (mostrar todo de golpe)
    sudo journalctl -u sshd -n "$lineas" --no-pager 2>/dev/null

    echo ""
    draw_line

    # Resumen de eventos de seguridad relevantes
    aputs_info "Resumen de eventos de seguridad (ultimas 24h):"
    echo ""

    local intentos_fallidos
    intentos_fallidos=$(sudo journalctl -u sshd --since "24 hours ago" --no-pager 2>/dev/null \
        | grep -c "Failed password\|Invalid user" 2>/dev/null || echo "0")

    local logins_exitosos
    logins_exitosos=$(sudo journalctl -u sshd --since "24 hours ago" --no-pager 2>/dev/null \
        | grep -c "Accepted" 2>/dev/null || echo "0")

    echo "  Intentos fallidos   : $intentos_fallidos"
    echo "  Logins exitosos     : $logins_exitosos"

    if (( intentos_fallidos > 10 )); then
        echo ""
        aputs_warning "Alto numero de intentos fallidos. Considere instalar fail2ban"
    fi
}

# ─── Función principal del monitor ───────────────────────────────────────────
monitor_ssh() {
    clear

    if ! check_privileges; then
        return 1
    fi

    if ! check_package_installed "openssh-server"; then
        draw_header "Monitor SSH"
        aputs_error "OpenSSH no esta instalado"
        aputs_info "Ejecute la opcion 2) Instalar/Configurar SSH primero"
        return 1
    fi

    # Detectar puerto configurado para pasarlo a las subfunciones
    local puerto=22
    if [[ -f /etc/ssh/sshd_config ]]; then
        local p
        p=$(sudo grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}')
        [[ -n "$p" ]] && puerto="$p"
    fi

    # Mostrar todas las secciones del monitor
    _mostrar_estado_servicio
    _mostrar_conexiones_activas
    echo ""
    _mostrar_config_activa

    echo ""
    draw_line

    aputs_info "Ver logs detallados del servicio?"
    local ver_logs
    read -rp "  (s/n): " ver_logs
    if [[ "$ver_logs" == "s" || "$ver_logs" == "S" ]]; then
        _mostrar_logs
    fi

    echo ""
    draw_line
    aputs_info "Monitor actualizado: $(date '+%Y-%m-%d %H:%M:%S')"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/utils.sh"
    source "${SCRIPT_DIR}/validators_ssh.sh"
    monitor_ssh
    pause
fi