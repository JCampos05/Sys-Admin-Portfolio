#
# Aplica parámetros de seguridad (hardening) al servidor SSH
#
# Depende de: utils.sh, validators_ssh.sh
#
hardening_ssh() {
    clear
    draw_header "Hardening de Seguridad SSH"

    if ! check_privileges; then
        return 1
    fi

    # Verificar que sshd_config existe antes de modificarlo
    if [[ ! -f /etc/ssh/sshd_config ]]; then
        aputs_error "No se encontro /etc/ssh/sshd_config"
        aputs_info "Ejecute primero la opcion 2) Instalar/Configurar SSH"
        return 1
    fi

    aputs_info "Este modulo refuerza la seguridad del servidor SSH."
    aputs_info "Cada parametro se explicara antes de solicitarlo."
    echo ""

    # Backup antes de cualquier cambio
    local backup="/etc/ssh/sshd_config.hardening_$(date +%Y%m%d_%H%M%S)"
    sudo cp /etc/ssh/sshd_config "$backup"
    aputs_success "Backup creado: $backup"
    draw_line

    # Función interna reutilizable para modificar directivas
    _set_sshd_param() {
        local directiva="$1"
        local valor="$2"
        if sudo grep -qE "^#?${directiva}\b" /etc/ssh/sshd_config 2>/dev/null; then
            sudo sed -i "s/^#*${directiva}.*/${directiva} ${valor}/" /etc/ssh/sshd_config
        else
            echo "${directiva} ${valor}" | sudo tee -a /etc/ssh/sshd_config > /dev/null
        fi
    }

    # ─── MaxAuthTries ────────────────────────────────────────
    # Cuántos intentos de contraseña se permiten antes de cerrar la conexión.
    aputs_info "MaxAuthTries: Numero maximo de intentos de autenticacion"
    aputs_info "Recomendado: 3  |  Rango valido: 1-10"
    echo ""

    local max_auth
    while true; do
        agets "MaxAuthTries [3]" max_auth
        max_auth="${max_auth:-3}"    
        if ssh_validar_max_auth_tries "$max_auth"; then
            break
        fi
        echo ""
    done

    _set_sshd_param "MaxAuthTries" "$max_auth"
    aputs_success "MaxAuthTries configurado: $max_auth"
    draw_line
    # ─── PARÁMETRO 2: LoginGraceTime ──────────────────────────────────────
    # Tiempo en segundos que tiene el cliente para completar el login.
    # Si en ese tiempo no se autentica, el servidor cierra la conexión.
    aputs_info "LoginGraceTime: Segundos disponibles para completar el login"
    aputs_info "Recomendado: 30  |  Rango valido: 10-300 segundos"
    echo ""

    local grace_time
    while true; do
        agets "LoginGraceTime en segundos [30]" grace_time
        grace_time="${grace_time:-30}"
        if ssh_validar_login_grace_time "$grace_time"; then
            break
        fi
        echo ""
    done

    _set_sshd_param "LoginGraceTime" "${grace_time}s"
    aputs_success "LoginGraceTime configurado: ${grace_time}s"
    draw_line

    # ─── PARÁMETRO 3: MaxSessions ─────────────────────────────────────────
    # Número máximo de sesiones abiertas simultáneamente por conexión.
    aputs_info "MaxSessions: Sesiones SSH simultaneas maximas por conexion"
    aputs_info "Recomendado: 3  |  Rango valido: 1-20"
    echo ""

    local max_sessions
    while true; do
        agets "MaxSessions [3]" max_sessions
        max_sessions="${max_sessions:-3}"
        if ssh_validar_max_sessions "$max_sessions"; then
            break
        fi
        echo ""
    done

    _set_sshd_param "MaxSessions" "$max_sessions"
    aputs_success "MaxSessions configurado: $max_sessions"
    draw_line

    # ─── PARÁMETRO 4: PermitRootLogin ────────────────────────────────────
    # Controla si el usuario root puede conectarse directamente por SSH.
    aputs_info "PermitRootLogin: Permitir login directo como root"
    aputs_info "Recomendado: no (obliga a usar usuario normal + sudo)"
    echo ""
    aputs_info "Opciones:"
    echo "    1) no (recomendado: root no puede conectarse)"
    echo "    2) prohibit-password (root solo con clave, nunca contraseña)"
    echo "    3) yes (no recomendado: cualquier metodo)"
    echo ""

    local opcion_root
    local valor_root
    while true; do
        agets "Seleccione opcion [1]" opcion_root
        opcion_root="${opcion_root:-1}"
        case "$opcion_root" in
            1) valor_root="no"; break ;;
            2) valor_root="prohibit-password"; break ;;
            3) valor_root="yes"
                aputs_warning "Permitir root es un riesgo de seguridad importante"
                break ;;
            *) aputs_error "Opcion invalida. Seleccione 1, 2 o 3" ;;
        esac
        echo ""
    done

    _set_sshd_param "PermitRootLogin" "$valor_root"
    aputs_success "PermitRootLogin configurado: $valor_root"
    draw_line

    # ─── PARÁMETRO 5: PasswordAuthentication ─────────────────────────────
    # Si está en 'no', SOLO se puede entrar con clave pública.
    # Esto elimina completamente los ataques de fuerza bruta de contraseñas.
    # Solo desactivar si ya se tiene claves configuradas (módulo 4).
    aputs_info "PasswordAuthentication: Permitir autenticacion con contrasena"
    aputs_warning "Desactivar SOLO si ya tiene claves publicas configuradas (opcion 4)"
    echo ""
    aputs_info "Opciones:"
    echo "    1) yes   (contraseña permitida — más compatible)"
    echo "    2) no    (solo claves públicas — más seguro)"
    echo ""

    local opcion_pass
    local valor_pass
    while true; do
        agets "Seleccione opcion [1]" opcion_pass
        opcion_pass="${opcion_pass:-1}"
        case "$opcion_pass" in
            1) valor_pass="yes";  break ;;
            2) valor_pass="no"
                aputs_warning "Asegurese de tener claves publicas configuradas antes de reconectar"
                break ;;
            *) aputs_error "Opcion invalida. Seleccione 1 o 2" ;;
        esac
        echo ""
    done

    _set_sshd_param "PasswordAuthentication" "$valor_pass"
    aputs_success "PasswordAuthentication configurado: $valor_pass"
    draw_line

    # ─── PARÁMETRO 6: Banner ─────────────────────────────────────────────
    # El banner aparece ANTES de que el usuario introduzca sus credenciales.
    # Tiene uso legal: avisa que el sistema es privado y que el acceso
    # no autorizado tiene consecuencias. Requerido en entornos corporativos.
    aputs_info "Banner: Mensaje legal que se muestra antes del login"
    echo ""
    aputs_info "Opciones:"
    echo "    1) Usar banner predeterminado (aviso legal generico)"
    echo "    2) Escribir banner personalizado"
    echo "    3) Sin banner"
    echo ""

    local opcion_banner
    agets "Seleccione opcion [1]" opcion_banner
    opcion_banner="${opcion_banner:-1}"

    case "$opcion_banner" in
        1)
            # Banner predeterminado con aviso legal genérico
            sudo tee /etc/ssh/banner_ssh > /dev/null << 'EOF'
┌─────────────────────────────────────────────────────────────────┐
|   Sistema de Acceso Restringido                                 |
|   Solo personal autorizado puede acceder a este sistema.        |
|   Todos los accesos son monitoreados y registrados.             |
|   El acceso no autorizado esta prohibido y sera reportado.      |
└─────────────────────────────────────────────────────────────────┘
EOF
            _set_sshd_param "Banner" "/etc/ssh/banner_ssh"
            aputs_success "Banner predeterminado creado en /etc/ssh/banner_ssh"
            ;;
        2)
            # Banner personalizado
            local texto_banner
            while true; do
                echo ""
                aputs_info "Escriba el texto del banner (una sola linea):"
                agets "Banner" texto_banner
                if ssh_validar_banner "$texto_banner"; then
                    break
                fi
                echo ""
            done

            echo "$texto_banner" | sudo tee /etc/ssh/banner_ssh > /dev/null
            _set_sshd_param "Banner" "/etc/ssh/banner_ssh"
            aputs_success "Banner personalizado guardado"
            ;;
        3)
            _set_sshd_param "Banner" "none"
            aputs_info "Sin banner configurado"
            ;;
        *)
            aputs_warning "Opcion no reconocida. Se usara banner predeterminado"
            ;;
    esac

    draw_line

    # ─── Validación final de sintaxis ─────────────────────────────────────
    aputs_info "Validando sintaxis de sshd_config..."
    echo ""

    if sudo sshd -t 2>/dev/null; then
        aputs_success "Sintaxis valida"
    else
        aputs_error "Error de sintaxis detectado:"
        sudo sshd -t 2>&1 | sed 's/^/    /'
        echo ""
        aputs_warning "Restaurando backup previo..."
        sudo cp "$backup" /etc/ssh/sshd_config
        aputs_info "Backup restaurado. Revise la configuracion."
        return 1
    fi

    echo ""

    # ─── Reinicio del servicio ────────────────────────────────────────────
    aputs_warning "Se reiniciara el servicio sshd para aplicar el hardening"
    local confirmar
    read -rp "  ¿Confirma el reinicio? (s/n): " confirmar

    if [[ "$confirmar" == "s" || "$confirmar" == "S" ]]; then
        if sudo systemctl restart sshd 2>/dev/null; then
            sleep 2
            if check_service_active "sshd"; then
                aputs_success "sshd reiniciado correctamente con hardening aplicado"
            else
                aputs_error "sshd no arranco tras el reinicio"
                sudo journalctl -u sshd -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
                return 1
            fi
        else
            aputs_error "Error al reiniciar sshd"
            return 1
        fi
    else
        aputs_info "Reinicio pospuesto. Recuerde reiniciar manualmente:"
        echo "    sudo systemctl restart sshd"
    fi

    draw_line
    echo ""
    aputs_success "Hardeninf aplicado correctamente"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/utils.sh"
    source "${SCRIPT_DIR}/validators_ssh.sh"
    hardening_ssh
    pause
fi