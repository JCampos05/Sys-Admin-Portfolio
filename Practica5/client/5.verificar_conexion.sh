#
# Módulo: Verificar conexión al servidor FTP (diagnóstico completo)
#
# Requiere:
#   utils_cliente.sh    
#

# ─── Función principal ────────────────────────────────────────────────────────

verificar_conexion_ftp() {
    draw_header "Verificar Conexion al Servidor FTP"

    echo ""
    aputs_info "Servidor a verificar:"
    echo "    1) Fedora Server  ($(conf_get IP_FEDORA 2>/dev/null || echo 'no configurada'))"
    echo "    2) Windows Server ($(conf_get IP_WINDOWS 2>/dev/null || echo 'no configurada'))"
    echo "    3) Ambos"
    echo ""

    local sel
    agets "Seleccione [1-3]" sel

    case "$sel" in
        1) _diagnostico_servidor "fedora"  ;;
        2) _diagnostico_servidor "windows" ;;
        3)
            _diagnostico_servidor "fedora"
            echo ""
            _diagnostico_servidor "windows"
            ;;
        *)
            aputs_error "Seleccion invalida"
            return 1
            ;;
    esac
}

# Ejecuta el diagnóstico completo sobre un servidor
# $1 = "fedora" | "windows"
_diagnostico_servidor() {
    local servidor="$1"
    local etiqueta
    [[ "$servidor" == "fedora" ]] && etiqueta="Fedora Server" || etiqueta="Windows Server"

    local clave_ip
    [[ "$servidor" == "fedora" ]] && clave_ip="IP_FEDORA" || clave_ip="IP_WINDOWS"

    local ip
    ip=$(conf_get "$clave_ip")

    draw_line
    echo "  Diagnostico: $etiqueta"
    draw_line

    if [[ -z "$ip" ]]; then
        aputs_warning "IP no configurada — configure desde la opcion 0 del menu principal"
        return 1
    fi

    aputs_info "Objetivo: $ip"
    echo ""

    # ── 1. Ping ───────────────────────────────────────────────────────────────
    aputs_info "[ 1/4 ] Conectividad ICMP (ping)"
    if check_ping "$ip"; then
        # Obtener el tiempo de ping para diagnóstico
        local tiempo_ping
        tiempo_ping=$(ping -c 1 -W 2 "$ip" 2>/dev/null \
            | grep "time=" | grep -oP "time=\K[0-9.]+" || echo "?")
        aputs_success "Respuesta ICMP recibida (tiempo: ${tiempo_ping} ms)"
    else
        aputs_error "Sin respuesta a ping desde $ip"
        aputs_info  "El servidor puede estar apagado o el firewall bloquea ICMP"
        aputs_info  "Continuando con las demas pruebas..."
    fi

    # ── 2. Puerto 21 ──────────────────────────────────────────────────────────
    echo ""
    aputs_info "[ 2/4 ] Puerto FTP 21 (TCP connect)"
    if check_puerto_ftp "$ip"; then
        aputs_success "Puerto 21 responde — el daemon FTP esta activo"
    else
        aputs_error "Puerto 21 no responde en $ip"
        aputs_info  "El servicio FTP puede estar detenido o el firewall bloquea el puerto"
        aputs_info  "En Fedora: sudo systemctl start vsftpd"
        aputs_info  "En Windows: revisar IIS Manager → sitio FTP → iniciar"
        return 1
    fi

    # ── 3. Banner FTP ─────────────────────────────────────────────────────────
    echo ""
    aputs_info "[ 3/4 ] Banner FTP del servidor"

    if ! check_lftp_instalado; then
        aputs_warning "lftp no disponible — omitiendo prueba de banner"
    else
        # Conectar con anonymous solo para leer el banner y desconectar
        # lftp imprime el banner en el proceso de conexión
        local banner
        banner=$(timeout 8 lftp -c "
            open ${ip}
            set ftp:passive-mode true
            set net:timeout 6
            bye
        " 2>&1 | head -5)

        if [[ -n "$banner" ]]; then
            aputs_success "Banner recibido del servidor:"
            echo "$banner" | while IFS= read -r linea; do
                echo "  ${GRAY}${linea}${NC}"
            done
        else
            aputs_warning "No se recibio banner (el servidor puede requerir autenticacion previa)"
        fi
    fi

    # ── 4. Tiempo de respuesta TCP ────────────────────────────────────────────
    echo ""
    aputs_info "[ 4/4 ] Tiempo de respuesta TCP (puerto 21)"

    # Medir el tiempo que tarda en establecer la conexión TCP
    local t_inicio t_fin ms
    t_inicio=$(date +%s%N 2>/dev/null || echo 0)

    if timeout 5 bash -c "echo > /dev/tcp/${ip}/21" 2>/dev/null; then
        t_fin=$(date +%s%N 2>/dev/null || echo 0)
        # Calcular diferencia en milisegundos
        ms=$(( (t_fin - t_inicio) / 1000000 ))
        if   (( ms < 50 ));   then
            aputs_success "Tiempo de conexion TCP: ${ms} ms (excelente)"
        elif (( ms < 200 ));  then
            aputs_success "Tiempo de conexion TCP: ${ms} ms (normal)"
        elif (( ms < 1000 )); then
            aputs_warning "Tiempo de conexion TCP: ${ms} ms (lento — posible sobrecarga)"
        else
            aputs_error   "Tiempo de conexion TCP: ${ms} ms (muy lento)"
        fi
    else
        aputs_error "No se pudo establecer conexion TCP al puerto 21"
    fi

    echo ""
    draw_line
    aputs_success "Diagnostico de $etiqueta completado"
}