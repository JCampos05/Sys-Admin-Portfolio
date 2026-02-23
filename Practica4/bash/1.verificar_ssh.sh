#
# Verifica el estado de instalación del servicio OpenSSH
#
# Depende de: utils.sh
#
verificar_ssh() {
    clear
    draw_header "Verificacion de Instalacion SSH"

    local errores=0
    local advertencias=0

    # ─── 1. Paquete openssh-server ────────────────────────────────────────
    aputs_info "1. Verificando paquete openssh-server..."
    echo ""

    if check_package_installed "openssh-server"; then
        # rpm -q da el nombre completo con versión
        local version
        version=$(rpm -q openssh-server 2>/dev/null)
        aputs_success "Paquete instalado: $version"
    else
        aputs_error "El paquete openssh-server NO esta instalado"
        aputs_info "Vaya a la opcion 2) Instalar/Configurar SSH para instalarlo"
        (( errores++ ))
    fi

    draw_line

    # ─── 2. Estado del servicio sshd ─────────────────────────────────────
    aputs_info "2. Estado del servicio sshd..."
    echo ""

    if check_service_active "sshd"; then
        aputs_success "Servicio sshd: ACTIVO (corriendo)"

        local pid
        pid=$(sudo systemctl show sshd --property=MainPID --value 2>/dev/null)
        if [[ -n "$pid" && "$pid" != "0" ]]; then
            echo "    PID: $pid"
        fi

        # Mostrar desde cuándo está activo
        local desde
        desde=$(sudo systemctl show sshd --property=ActiveEnterTimestamp --value 2>/dev/null)
        if [[ -n "$desde" ]]; then
            echo "    Activo desde: $desde"
        fi
    else
        aputs_error "Servicio sshd: INACTIVO"
        (( errores++ ))
    fi

    # Inicio automático con el sistema
    if check_service_enabled "sshd"; then
        aputs_success "Inicio automatico en boot: HABILITADO"
    else
        aputs_warning "Inicio automatico en boot: DESHABILITADO"
        aputs_info "El servicio no arrancara al reiniciar el servidor"
        (( advertencias++ ))
    fi

    draw_line

    # ─── 3. Puerto en escucha ─────────────────────────────────────────────
    # Leemos el puerto configurado en sshd_config (puede no ser 22)
    aputs_info "3. Verificando puerto en escucha..."
    echo ""

    local puerto_config=22
    if [[ -f /etc/ssh/sshd_config ]]; then
        local puerto_leido
        puerto_leido=$(sudo grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
        if [[ -n "$puerto_leido" ]]; then
            puerto_config="$puerto_leido"
        fi
    fi

    aputs_info "Puerto configurado en sshd_config: $puerto_config"
    echo ""

    local tcp_listen
    tcp_listen=$(sudo ss -tlnp 2>/dev/null | grep ":${puerto_config} ")

    if [[ -n "$tcp_listen" ]]; then
        aputs_success "Puerto ${puerto_config}/TCP: ESCUCHANDO"
        echo "$tcp_listen" | awk '{print "    " $1 "  " $4}'
    else
        aputs_error "Puerto ${puerto_config}/TCP: NO escuchando"
        aputs_info "El servicio puede estar caido o el puerto configurado difiere"
        (( errores++ ))
    fi

    draw_line

    # ─── 4. Archivo de configuración ─────────────────────────────────────
    aputs_info "4. Archivo de configuracion..."
    echo ""

    if [[ -f /etc/ssh/sshd_config ]]; then
        aputs_success "Archivo /etc/ssh/sshd_config: ENCONTRADO"

        # Tamaño y fecha de última modificación
        local size mod
        size=$(du -h /etc/ssh/sshd_config | awk '{print $1}')
        mod=$(stat -c '%y' /etc/ssh/sshd_config | cut -d'.' -f1)
        echo "    Tamaño: $size"
        echo "    Ultima modificacion: $mod"

        # Verificar sintaxis con sshd -t (test mode)
        echo ""
        if sudo sshd -t 2>/dev/null; then
            aputs_success "Sintaxis de sshd_config: VALIDA"
        else
            aputs_error "Sintaxis de sshd_config: INVALIDA"
            sudo sshd -t 2>&1 | sed 's/^/    /'
            (( errores++ ))
        fi
    else
        aputs_error "Archivo /etc/ssh/sshd_config: NO encontrado"
        (( errores++ ))
    fi

    draw_line

    # ─── 5. Firewall ─────────────────────────────────────────────────────
    aputs_info "5. Verificando firewall (firewalld)..."
    echo ""

    if sudo systemctl is-active --quiet firewalld 2>/dev/null; then
        aputs_success "Firewalld: ACTIVO"

        if sudo firewall-cmd --list-services 2>/dev/null | grep -qw "ssh"; then
            aputs_success "Servicio SSH: PERMITIDO en firewall"
        else
            # Verificar si está abierto el puerto directamente
            if sudo firewall-cmd --list-ports 2>/dev/null | grep -q "${puerto_config}/tcp"; then
                aputs_success "Puerto ${puerto_config}/TCP: PERMITIDO en firewall"
            else
                aputs_warning "SSH no parece estar permitido en el firewall"
                aputs_info "Vaya a la opcion 6) Firewall para configurarlo"
                (( advertencias++ ))
            fi
        fi
    else
        aputs_warning "Firewalld: INACTIVO"
        aputs_info "Sin firewall activo — el puerto puede estar expuesto sin restricciones"
        (( advertencias++ ))
    fi

    draw_line

    # ─── 6. Resumen final ─────────────────────────────────────────────────
    aputs_info "Resumen de verificacion:"
    echo ""

    if [[ $errores -eq 0 && $advertencias -eq 0 ]]; then
        aputs_success "SSH completamente operativo y configurado"
    elif [[ $errores -eq 0 ]]; then
        aputs_warning "SSH operativo con $advertencias advertencia(s)"
    else
        aputs_error "SSH con $errores error(es) critico(s) y $advertencias advertencia(s)"
    fi

    echo ""
    echo "  Errores criticos : $errores"
    echo "  Advertencias     : $advertencias"
}

# Ejecución directa (sin main.sh)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/utils.sh"
    verificar_ssh
    pause
fi