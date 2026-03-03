#
# Módulo: Acceso anónimo al servidor FTP
#
# Requiere:
#   utils_cliente.sh 
#

# ─── Función principal ────────────────────────────────────────────────────────

acceso_anonimo_ftp() {
    while true; do
        clear
        draw_header "Acceso Anonimo al Servidor FTP"
        echo ""
        aputs_info "  1) Listar directorio raiz (Fedora)"
        aputs_info "  2) Listar directorio raiz (Windows)"
        aputs_info "  3) Descargar archivo (Fedora)"
        aputs_info "  4) Descargar archivo (Windows)"
        aputs_info "  5) Volver al menu principal"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1) _anonimo_listar "fedora";  pause ;;
            2) _anonimo_listar "windows"; pause ;;
            3) _anonimo_descargar "fedora";  pause ;;
            4) _anonimo_descargar "windows"; pause ;;
            5) return 0 ;;
            *)
                aputs_error "Opcion invalida. Seleccione del 1 al 5"
                sleep 2
                ;;
        esac
    done
}

# ─── Helpers internos ─────────────────────────────────────────────────────────

# Valida prerrequisitos comunes: lftp instalado + IP configurada + servidor accesible
# $1 = "fedora" | "windows"
# Almacena la IP en la variable cuyo nombre se pasa como $2
# Retorna 0 si todo OK, 1 si hay algún problema
_anonimo_precheck() {
    local servidor="$1"
    local __ip_var="$2"

    # lftp instalado
    if ! check_lftp_instalado; then
        aputs_error "lftp no esta instalado — use la opcion 2 del menu principal"
        return 1
    fi

    # IP configurada
    local clave ip
    [[ "$servidor" == "fedora" ]] && clave="IP_FEDORA" || clave="IP_WINDOWS"
    ip=$(conf_get "$clave")

    if [[ -z "$ip" ]]; then
        aputs_error "IP del servidor $(echo "$servidor" | tr '[:lower:]' '[:upper:]') no configurada"
        aputs_warning "Configure las IPs desde la opcion 0 del menu principal antes de conectar"
        return 1
    fi

    # Servidor accesible
    aputs_info "Verificando acceso a $ip..."
    if ! check_puerto_ftp "$ip"; then
        aputs_error "El servidor $ip no responde en el puerto 21"
        aputs_info  "Verifique que el servicio FTP este activo en el servidor"
        return 1
    fi

    # Exportar IP al llamador
    printf -v "$__ip_var" "%s" "$ip"
    return 0
}

# Lista el directorio raíz del servidor con acceso anónimo
# $1 = "fedora" | "windows"
_anonimo_listar() {
    local servidor="$1"
    draw_header "Listar Raiz — Servidor $(echo "$servidor" | tr '[:lower:]' '[:upper:]') (Anonimo)"

    local ip
    _anonimo_precheck "$servidor" ip || return 1

    echo ""
    aputs_info "Conectando a $ip como anonymous..."
    draw_line

    # Conectar como anonymous, listar y salir
    # La contraseña para anonymous es por convención el email del usuario,
    # pero cualquier cadena es aceptada.
    lftp -c "
        open -u 'anonymous','guest@ftp' ${ip}
        set ftp:passive-mode true
        set net:timeout 10
        ls -la
        bye
    " 2>&1

    local rc=$?
    draw_line
    if [[ $rc -eq 0 ]]; then
        aputs_success "Listado completado"
    else
        aputs_error   "Error al conectar o listar (codigo: $rc)"
        aputs_info    "El servidor puede tener el acceso anonimo deshabilitado"
        aputs_info    "En vsftpd: verifique anonymous_enable=YES en /etc/vsftpd/vsftpd.conf"
    fi
}

# Descarga un archivo del servidor con acceso anónimo
# $1 = "fedora" | "windows"
_anonimo_descargar() {
    local servidor="$1"
    draw_header "Descargar Archivo — Servidor $(echo "$servidor" | tr '[:lower:]' '[:upper:]') (Anonimo)"

    local ip
    _anonimo_precheck "$servidor" ip || return 1

    echo ""
    # Pedir ruta remota
    local ruta_remota
    agets "Ruta del archivo en el servidor (ej: /pub/archivo.txt)" ruta_remota
    if [[ -z "$ruta_remota" ]]; then
        aputs_error "La ruta no puede estar vacia"
        return 1
    fi

    # Directorio destino local
    local destino="${HOME}/Descargas"
    mkdir -p "$destino"

    aputs_info "Descargando desde $ip:$ruta_remota → $destino/"
    draw_line

    lftp -c "
        open -u 'anonymous','guest@ftp' ${ip}
        set ftp:passive-mode true
        set net:timeout 10
        get '${ruta_remota}' -o '${destino}/'
        bye
    " 2>&1

    local rc=$?
    draw_line
    if [[ $rc -eq 0 ]]; then
        local nombre_archivo
        nombre_archivo=$(basename "$ruta_remota")
        aputs_success "Archivo descargado: ${destino}/${nombre_archivo}"
    else
        aputs_error "Error en la descarga (codigo: $rc)"
    fi
}