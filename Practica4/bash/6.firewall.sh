#
# Gestión de reglas de firewalld para el servicio SSH
#
# Depende de: utils.sh, validators_ssh.sh
#

# ─── Verificar que firewalld está disponible ──────────────────────────────────
_verificar_firewalld() {
    if ! command -v firewall-cmd &>/dev/null; then
        aputs_error "firewalld no esta instalado"
        aputs_info "Instale con: sudo dnf install firewalld"
        return 1
    fi

    if ! sudo systemctl is-active --quiet firewalld 2>/dev/null; then
        aputs_warning "firewalld esta inactivo. Iniciando..."
        if sudo systemctl start firewalld 2>/dev/null; then
            aputs_success "firewalld iniciado"
        else
            aputs_error "No se pudo iniciar firewalld"
            return 1
        fi
    fi

    return 0
}

# ─── 1. Ver estado actual del firewall ───────────────────────────────────────
_ver_estado_firewall() {
    clear
    draw_header "Estado del Firewall"

    if ! _verificar_firewalld; then
        return 1
    fi

    echo ""

    # Estado general del firewall
    if sudo systemctl is-active --quiet firewalld; then
        aputs_success "firewalld: ACTIVO"
    else
        aputs_error "firewalld: INACTIVO"
    fi

    if sudo systemctl is-enabled --quiet firewalld; then
        echo "  Inicio en boot: HABILITADO"
    else
        echo "  Inicio en boot: DESHABILITADO"
    fi

    echo ""
    draw_line

    # Zona activa
    # En firewalld las reglas se agrupan en "zonas" con diferentes niveles de confianza
    local zona_activa
    zona_activa=$(sudo firewall-cmd --get-active-zones 2>/dev/null | head -n 1)
    aputs_info "Zona activa: $zona_activa"
    echo ""

    # Servicios permitidos (por nombre)
    aputs_info "Servicios permitidos:"
    sudo firewall-cmd --list-services 2>/dev/null | tr ' ' '\n' | \
        while read -r svc; do echo "  - $svc"; done

    echo ""

    # Puertos abiertos explícitamente
    aputs_info "Puertos abiertos:"
    local puertos
    puertos=$(sudo firewall-cmd --list-ports 2>/dev/null)

    if [[ -n "$puertos" ]]; then
        echo "$puertos" | tr ' ' '\n' | while read -r p; do
            echo "  - $p"
        done
    else
        echo "  (ninguno adicional)"
    fi

    draw_line

    # Verificación específica de SSH
    aputs_info "Estado especifico de SSH:"
    echo ""

    if sudo firewall-cmd --list-services 2>/dev/null | grep -qw "ssh"; then
        aputs_success "Servicio SSH: PERMITIDO (por nombre de servicio)"
    elif sudo firewall-cmd --list-ports 2>/dev/null | grep -q "22/tcp"; then
        aputs_success "Puerto 22/TCP: PERMITIDO (por puerto)"
    else
        aputs_warning "SSH no esta explicitamente permitido en el firewall"
    fi
}

# ─── 2. Permitir SSH estándar (puerto 22) ────────────────────────────────────
_permitir_ssh_estandar() {
    clear
    draw_header "Permitir SSH en el Firewall"

    if ! _verificar_firewalld; then
        return 1
    fi

    echo ""
    aputs_info "Se abrira el puerto 22/TCP para el servicio SSH"
    echo ""

    # Verificar si ya está permitido
    if sudo firewall-cmd --list-services 2>/dev/null | grep -qw "ssh"; then
        aputs_success "El servicio SSH ya esta permitido en el firewall"
        return 0
    fi

    local confirmar
    read -rp "  ¿Confirma agregar el servicio SSH al firewall? (s/n): " confirmar
    if [[ "$confirmar" != "s" && "$confirmar" != "S" ]]; then
        aputs_info "Operacion cancelada"
        return 0
    fi

    echo ""

    # --permanent: la regla persiste tras reiniciar
    # --add-service=ssh: usar el nombre predefinido de firewalld para SSH
    if sudo firewall-cmd --permanent --add-service=ssh 2>/dev/null; then
        aputs_success "Regla SSH agregada (permanente)"
    else
        aputs_error "Error al agregar regla SSH"
        return 1
    fi

    # Recargar para que la regla permanente se vuelva efectiva ahora mismo
    if sudo firewall-cmd --reload 2>/dev/null; then
        aputs_success "Firewall recargado — regla activa"
    else
        aputs_error "Error al recargar firewalld"
        return 1
    fi

    echo ""
    aputs_success "Puerto 22/TCP habilitado para conexiones SSH"
}

# ─── 3. Permitir puerto personalizado ────────────────────────────────────────
_permitir_puerto_custom() {
    clear
    draw_header "Permitir Puerto Personalizado"

    if ! _verificar_firewalld; then
        return 1
    fi

    echo ""
    aputs_info "Ingrese el puerto que desea abrir para SSH"
    echo ""

    local puerto
    while true; do
        agets "Numero de puerto" puerto
        if ssh_validar_puerto "$puerto"; then
            break
        fi
        echo ""
    done

    echo ""

    # Verificar si ya está abierto
    if sudo firewall-cmd --list-ports 2>/dev/null | grep -q "${puerto}/tcp"; then
        aputs_success "El puerto $puerto/TCP ya esta abierto"
        return 0
    fi

    local confirmar
    read -rp "  ¿Abrir puerto ${puerto}/TCP? (s/n): " confirmar
    if [[ "$confirmar" != "s" && "$confirmar" != "S" ]]; then
        aputs_info "Operacion cancelada"
        return 0
    fi

    echo ""

    # --add-port: abrir un puerto específico en lugar de un servicio por nombre
    if sudo firewall-cmd --permanent --add-port="${puerto}/tcp" 2>/dev/null; then
        aputs_success "Puerto ${puerto}/TCP agregado (permanente)"
    else
        aputs_error "Error al agregar el puerto $puerto"
        return 1
    fi

    if sudo firewall-cmd --reload 2>/dev/null; then
        aputs_success "Firewall recargado — puerto ${puerto}/TCP activo"
    else
        aputs_error "Error al recargar el firewall"
        return 1
    fi
}

# ─── 4. Bloquear puerto SSH ───────────────────────────────────────────────────
_bloquear_puerto_ssh() {
    clear
    draw_header "Bloquear Puerto SSH"

    if ! _verificar_firewalld; then
        return 1
    fi

    echo ""
    aputs_warning "ATENCION: Bloquear SSH cortara las conexiones remotas activas"
    aputs_warning "Solo haga esto si tiene acceso fisico/consola al servidor"
    echo ""

    local puerto
    while true; do
        agets "Puerto SSH a bloquear [22]" puerto
        puerto="${puerto:-22}"
        if ssh_validar_puerto "$puerto"; then
            break
        fi
        echo ""
    done

    echo ""

    local confirmar
    read -rp "  Escriba 'CONFIRMAR' para bloquear el puerto $puerto: " confirmar
    if [[ "$confirmar" != "CONFIRMAR" ]]; then
        aputs_info "Operacion cancelada"
        return 0
    fi

    echo ""

    local cambios=0

    # Quitar el servicio SSH por nombre (si está)
    if sudo firewall-cmd --list-services 2>/dev/null | grep -qw "ssh"; then
        sudo firewall-cmd --permanent --remove-service=ssh 2>/dev/null
        aputs_success "Servicio SSH eliminado del firewall"
        (( cambios++ ))
    fi

    # Quitar el puerto directamente (si está)
    if sudo firewall-cmd --list-ports 2>/dev/null | grep -q "${puerto}/tcp"; then
        sudo firewall-cmd --permanent --remove-port="${puerto}/tcp" 2>/dev/null
        aputs_success "Puerto ${puerto}/TCP eliminado del firewall"
        (( cambios++ ))
    fi

    if (( cambios == 0 )); then
        aputs_info "No habia reglas SSH que eliminar"
        return 0
    fi

    if sudo firewall-cmd --reload 2>/dev/null; then
        aputs_success "Firewall recargado — SSH bloqueado"
    else
        aputs_error "Error al recargar el firewall"
        return 1
    fi
}

# ─── Submenú de firewall ──────────────────────────────────────────────────────
firewall_ssh_menu() {
    while true; do
        clear
        draw_header "Configuracion Firewall SSH"

        echo ""
        aputs_info "1) Ver estado actual del firewall"
        aputs_info "2) Permitir SSH en el firewall (puerto 22)"
        aputs_info "3) Permitir puerto personalizado"
        aputs_info "4) Bloquear puerto SSH"
        aputs_info "5) Volver al menu principal"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1) _ver_estado_firewall    ;;
            2) _permitir_ssh_estandar  ;;
            3) _permitir_puerto_custom ;;
            4) _bloquear_puerto_ssh    ;;
            5) return 0                ;;
            *) aputs_error "Opcion invalida" ; sleep 1 ;;
        esac

        echo ""
        pause
    done
}
# ─── Punto de entrada ─────────────────────────────────────────────────────────
gestionar_firewall_ssh() {
    if ! check_privileges; then
        return 1
    fi
    firewall_ssh_menu
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/utils.sh"
    source "${SCRIPT_DIR}/validators_ssh.sh"
    gestionar_firewall_ssh
fi