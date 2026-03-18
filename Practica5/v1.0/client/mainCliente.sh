#
# mainCliente.sh
#
# Script principal — Gestor del Cliente FTP en Fedora Workstation
# Punto único de entrada. Carga módulos con 'source' y llama a sus funciones.
#


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Carga de módulos ─────────────────────────────────────────────────────────
source "${SCRIPT_DIR}/utilsCliente.sh"
source "${SCRIPT_DIR}/1.verificar_cliente.sh"
source "${SCRIPT_DIR}/2.instalar_cliente.sh"
source "${SCRIPT_DIR}/3.acceso_anonimo.sh"
source "${SCRIPT_DIR}/4.acceso_autenticado.sh"
source "${SCRIPT_DIR}/5.verificar_conexion.sh"

# ─── Gestión de configuración de servidores ───────────────────────────────────

# Lee un valor del archivo de configuración de servidores
# Uso: conf_get "IP_FEDORA"   →  imprime "192.168.100.10"
conf_get() {
    local clave="$1"
    if [[ ! -f "$CLIENT_CONFIG_FILE" ]]; then
        echo ""
        return 1
    fi
    grep -m1 "^${clave}=" "$CLIENT_CONFIG_FILE" 2>/dev/null \
        | cut -d= -f2- \
        | tr -d '[:space:]'
}

# Escribe o actualiza un valor en el archivo de configuración
conf_set() {
    local clave="$1"
    local valor="$2"

    # Asegurar que el directorio y archivo existen
    mkdir -p "$CLIENT_CONFIG_DIR"
    touch "$CLIENT_CONFIG_FILE"

    if grep -q "^${clave}=" "$CLIENT_CONFIG_FILE" 2>/dev/null; then
        # Actualizar línea existente
        sed -i "s|^${clave}=.*|${clave}=${valor}|" "$CLIENT_CONFIG_FILE"
    else
        # Agregar nueva línea
        echo "${clave}=${valor}" >> "$CLIENT_CONFIG_FILE"
    fi
}

# Submenú de configuración de IPs de servidores
# Se accede desde la opción 0 del menú principal
_configurar_servidores() {
    draw_header "Configurar IPs de Servidores"

    local ip_fedora ip_windows
    ip_fedora=$(conf_get "IP_FEDORA")
    ip_windows=$(conf_get "IP_WINDOWS")

    echo ""
    aputs_info "Configuracion actual:"
    if [[ -n "$ip_fedora" ]]; then
        aputs_success "  Servidor Fedora  : $ip_fedora"
    else
        aputs_warning "  Servidor Fedora  : (no configurada)"
    fi
    if [[ -n "$ip_windows" ]]; then
        aputs_success "  Servidor Windows : $ip_windows"
    else
        aputs_warning "  Servidor Windows : (no configurada)"
    fi
    echo ""
    aputs_info "(Presione Enter para mantener el valor actual)"
    draw_line

    # ── IP Fedora Server ──────────────────────────────────────────────────────
    local nueva_ip_fedora
    agets "IP Servidor Fedora  [${ip_fedora:-vacio}]" nueva_ip_fedora

    if [[ -n "$nueva_ip_fedora" ]]; then
        if check_ip_valida "$nueva_ip_fedora"; then
            conf_set "IP_FEDORA" "$nueva_ip_fedora"
            aputs_success "IP Fedora guardada: $nueva_ip_fedora"
        else
            aputs_error "Formato de IP invalido: '$nueva_ip_fedora'"
            aputs_info  "Formato esperado: X.X.X.X  (ej: 192.168.100.10)"
            aputs_warning "IP de Fedora no actualizada"
        fi
    else
        aputs_info "IP Fedora sin cambios: ${ip_fedora:-(vacio)}"
    fi

    # ── IP Windows Server ─────────────────────────────────────────────────────
    local nueva_ip_windows
    agets "IP Servidor Windows [${ip_windows:-vacio}]" nueva_ip_windows

    if [[ -n "$nueva_ip_windows" ]]; then
        if check_ip_valida "$nueva_ip_windows"; then
            conf_set "IP_WINDOWS" "$nueva_ip_windows"
            aputs_success "IP Windows guardada: $nueva_ip_windows"
        else
            aputs_error "Formato de IP invalido: '$nueva_ip_windows'"
            aputs_info  "Formato esperado: X.X.X.X  (ej: 192.168.100.20)"
            aputs_warning "IP de Windows no actualizada"
        fi
    else
        aputs_info "IP Windows sin cambios: ${ip_windows:-(vacio)}"
    fi

    # Mostrar configuración final
    echo ""
    draw_line
    aputs_info "Configuracion guardada en: $CLIENT_CONFIG_FILE"
    ip_fedora=$(conf_get "IP_FEDORA")
    ip_windows=$(conf_get "IP_WINDOWS")
    [[ -n "$ip_fedora"  ]] && aputs_success "  Servidor Fedora  : $ip_fedora"
    [[ -n "$ip_windows" ]] && aputs_success "  Servidor Windows : $ip_windows"
}

# ─── Comprobación de IPs antes de opciones que conectan ──────────────────────
# Verifica que al menos una IP esté configurada.
# Si ninguna lo está, muestra advertencia y retorna 1.
_ips_configuradas() {
    local ip_f ip_w
    ip_f=$(conf_get "IP_FEDORA")
    ip_w=$(conf_get "IP_WINDOWS")

    if [[ -z "$ip_f" && -z "$ip_w" ]]; then
        echo ""
        aputs_warning "┌─────────────────────────────────────────────────┐"
        aputs_warning "│  ATENCION: No hay IPs de servidores configuradas │"
        aputs_warning "│  Use la opcion 0 del menu para configurarlas     │"
        aputs_warning "└─────────────────────────────────────────────────┘"
        echo ""
        aputs_info "Sin las IPs configuradas no es posible conectarse a ningun servidor."
        return 1
    fi
    return 0
}

# ─── Menú principal ───────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        echo ""
        aputs_info "+--------------------------------------+"
        aputs_info "|---|   Gestor del Cliente FTP     |---|"
        aputs_info "|---|   Fedora Workstation         |---|"
        aputs_info "+--------------------------------------+"
        echo ""

        # Indicador de IPs configuradas debajo del encabezado
        local ip_f ip_w
        ip_f=$(conf_get "IP_FEDORA")
        ip_w=$(conf_get "IP_WINDOWS")

        if [[ -n "$ip_f" || -n "$ip_w" ]]; then
            [[ -n "$ip_f" ]] && aputs_success "  Fedora  : $ip_f"
            [[ -n "$ip_w" ]] && aputs_success "  Windows : $ip_w"
        else
            aputs_warning "  Servidores no configurados — use opcion 0"
        fi

        # Indicador de sesión autenticada activa
        if $SESION_ACTIVA 2>/dev/null; then
            aputs_success "  Sesion FTP activa: ${SESION_USUARIO}@${SESION_IP}"
        fi

        echo ""
        aputs_info "Seleccione una opcion:"
        echo ""
        aputs_info "  0) Configurar IPs de servidores"
        aputs_info "  1) Verificar instalacion"
        aputs_info "  2) Instalar y configurar cliente FTP"
        aputs_info "  3) Acceso anonimo al servidor"
        aputs_info "  4) Acceso con usuario autenticado"
        aputs_info "  5) Verificar conexion al servidor"
        aputs_info "  6) Salir"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            0)
                _configurar_servidores
                pause
                ;;
            1)
                verificar_cliente_ftp
                pause
                ;;
            2)
                instalar_cliente_ftp
                pause
                ;;
            3)
                if _ips_configuradas; then
                    acceso_anonimo_ftp
                else
                    pause
                fi
                ;;
            4)
                if _ips_configuradas; then
                    acceso_autenticado_ftp
                else
                    pause
                fi
                ;;
            5)
                if _ips_configuradas; then
                    verificar_conexion_ftp
                    pause
                else
                    pause
                fi
                ;;
            6)
                # Cerrar sesión activa antes de salir para limpiar credenciales
                if ${SESION_ACTIVA:-false}; then
                    aputs_info "Cerrando sesion FTP activa..."
                    _cerrar_sesion
                fi
                clear
                echo ""
                aputs_info "Saliendo del Gestor del Cliente FTP..."
                echo ""
                exit 0
                ;;
            *)
                aputs_error "Opcion invalida. Seleccione una opcion del 0 al 6"
                sleep 2
                ;;
        esac
    done
}

# ─── Punto de entrada ─────────────────────────────────────────────────────────
if [[ -z "${CLIENT_CONFIG_DIR:-}" ]]; then
    CLIENT_CONFIG_DIR="${HOME}/.config/ftp_cliente"
    CLIENT_CONFIG_FILE="${CLIENT_CONFIG_DIR}/servidores.conf"
fi

main_menu