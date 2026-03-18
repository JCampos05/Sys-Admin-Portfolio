#
# Módulo: Verificar instalación del cliente FTP (lftp) y conectividad
#
# Requiere:
#   utils_cliente.sh 
#

# ─── Constantes del módulo ────────────────────────────────────────────────────
readonly CLIENT_CONFIG_DIR="${HOME}/.config/ftp_cliente"
readonly CLIENT_CONFIG_FILE="${CLIENT_CONFIG_DIR}/servidores.conf"
readonly LFTP_PACKAGE="lftp"

# ─── Función principal ────────────────────────────────────────────────────────

verificar_cliente_ftp() {
    draw_header "Verificacion del Cliente FTP"

    # ── 1. Paquete lftp ───────────────────────────────────────────────────────
    echo ""
    aputs_info "[ 1/4 ] Paquete lftp"
    draw_line

    if check_lftp_instalado; then
        local version
        version=$(lftp --version 2>/dev/null | head -1)
        aputs_success "lftp instalado: $version"
    else
        aputs_error "lftp NO esta instalado"
        aputs_info "Vaya a la opcion 2 para instalarlo"
        echo ""
        pause
        return 1
    fi

    # ── 2. Configuración de servidores ────────────────────────────────────────
    echo ""
    aputs_info "[ 2/4 ] Configuracion de servidores"
    draw_line

    local ip_fedora ip_windows
    ip_fedora=$(conf_get "IP_FEDORA")
    ip_windows=$(conf_get "IP_WINDOWS")

    if [[ -n "$ip_fedora" ]]; then
        aputs_success "Servidor Fedora  configurado: $ip_fedora"
    else
        aputs_warning "Servidor Fedora  NO configurado"
    fi

    if [[ -n "$ip_windows" ]]; then
        aputs_success "Servidor Windows configurado: $ip_windows"
    else
        aputs_warning "Servidor Windows NO configurado"
    fi

    if [[ -z "$ip_fedora" && -z "$ip_windows" ]]; then
        aputs_info "Use la opcion 0 del menu principal para configurar las IPs"
    fi

    # ── 3. Conectividad ICMP ──────────────────────────────────────────────────
    echo ""
    aputs_info "[ 3/4 ] Conectividad (ping)"
    draw_line

    _verificar_conectividad_servidor "Fedora"  "$ip_fedora"
    _verificar_conectividad_servidor "Windows" "$ip_windows"

    # ── 4. Puerto FTP (21) ────────────────────────────────────────────────────
    echo ""
    aputs_info "[ 4/4 ] Puerto FTP (21) accesible"
    draw_line

    _verificar_puerto_servidor "Fedora"  "$ip_fedora"
    _verificar_puerto_servidor "Windows" "$ip_windows"

    draw_line
    echo ""
}

# Verifica ping a un servidor dado su etiqueta e IP
# $1 = etiqueta ("Fedora" | "Windows")
# $2 = IP (puede estar vacía si no se configuró)
_verificar_conectividad_servidor() {
    local label="$1"
    local ip="$2"

    if [[ -z "$ip" ]]; then
        aputs_warning "Servidor $label: IP no configurada — omitido"
        return
    fi

    if check_ping "$ip"; then
        aputs_success "Servidor $label ($ip): accesible vía ICMP"
    else
        aputs_error   "Servidor $label ($ip): sin respuesta a ping"
        aputs_info    "  Posibles causas: red incorrecta, VM apagada, firewall bloquea ICMP"
    fi
}

# Verifica que el puerto 21 responde en un servidor
# $1 = etiqueta   $2 = IP
_verificar_puerto_servidor() {
    local label="$1"
    local ip="$2"

    if [[ -z "$ip" ]]; then
        aputs_warning "Servidor $label: IP no configurada — omitido"
        return
    fi

    if check_puerto_ftp "$ip"; then
        aputs_success "Servidor $label ($ip): puerto 21 responde"
    else
        aputs_error   "Servidor $label ($ip): puerto 21 NO responde"
        aputs_info    "  Posibles causas: vsftpd/IIS FTP detenido, firewall bloquea el puerto"
    fi
}