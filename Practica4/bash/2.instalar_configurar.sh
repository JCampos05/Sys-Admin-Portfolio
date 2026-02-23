#
# Instala el servicio OpenSSH y realiza la configuración base
#
# Depende de: utils.sh, validators_ssh.sh
#
instalar_configurar_ssh() {
    clear
    draw_header "Instalar y Configurar OpenSSH"

    # Verificar privilegios antes de cualquier acción
    if ! check_privileges; then
        return 1
    fi

    # ─── 1. Verificar si ya está instalado ───────────────────────────────
    aputs_info "1. Verificando instalacion previa..."
    echo ""

    if check_package_installed "openssh-server"; then
        local version
        version=$(rpm -q openssh-server 2>/dev/null)
        aputs_warning "OpenSSH ya esta instalado: $version"
        echo ""
        local reinstalar
        read -rp "  ¿Desea continuar igualmente con la configuracion? (s/n): " reinstalar
        if [[ "$reinstalar" != "s" && "$reinstalar" != "S" ]]; then
            aputs_info "Operacion cancelada"
            return 0
        fi
    else
        aputs_info "OpenSSH no esta instalado. Procediendo con la instalacion..."
        echo ""

        # Instalar openssh-server desde los repositorios de Fedora
        if sudo dnf install -y openssh-server 2>/dev/null; then
            aputs_success "openssh-server instalado correctamente"
        else
            aputs_error "Error durante la instalacion de openssh-server"
            aputs_info "Verifique su conexion a internet y los repositorios configurados"
            return 1
        fi
    fi

    draw_line

    # ─── 2. Habilitar e iniciar el servicio ──────────────────────────────
    aputs_info "2. Configurando el servicio sshd..."
    echo ""

    # enable -> hace que el servicio arranque automáticamente en cada boot
    # Es el equivalente a systemctl enable sshd
    aputs_info "Habilitando inicio automatico (enable)..."
    if sudo systemctl enable sshd 2>/dev/null; then
        aputs_success "sshd habilitado en el boot"
    else
        aputs_error "No se pudo habilitar sshd en el boot"
        return 1
    fi

    echo ""

    # 'start' levanta el servicio ahora mismo en esta sesión
    aputs_info "Iniciando el servicio ahora (start)..."
    if sudo systemctl start sshd 2>/dev/null; then
        aputs_success "sshd iniciado correctamente"
    else
        aputs_error "No se pudo iniciar el servicio sshd"
        aputs_info "Revise los logs: sudo journalctl -u sshd -n 20"
        return 1
    fi

    draw_line
    # ─── 3. Configuración base de sshd_config ────────────────────────────
    # sshd_config es el archivo principal de configuración del servidor SSH
    aputs_info "3. Aplicando configuracion base en /etc/ssh/sshd_config..."
    echo ""

    # Crear backup antes de modificar — buena práctica antes de editar configs
    local backup="/etc/ssh/sshd_config.backup_$(date +%Y%m%d_%H%M%S)"
    if sudo cp /etc/ssh/sshd_config "$backup" 2>/dev/null; then
        aputs_success "Backup creado: $backup"
    else
        aputs_warning "No se pudo crear backup del sshd_config"
    fi

    echo ""

    # Solicitar el usuario que podrá conectarse vía SSH
    # Usamos el validator para asegurarnos de que el usuario existe
    local usuario_ssh
    while true; do
        agets "Usuario que podra conectarse via SSH (ej: adminuser)" usuario_ssh
        if ssh_validar_usuario_existe "$usuario_ssh"; then
            break
        fi
        echo ""
    done

    echo ""

    # ─── Aplicar los parámetros base en sshd_config ──────────────────────
    # Usamos sed para modificar las directivas existentes o agregarlas si no existen

    aputs_info "Escribiendo parametros en sshd_config..."
    echo ""

    # Establece o agrega una directiva en sshd_config
    # Uso: _set_sshd_param "Port" "22"
    _set_sshd_param() {
        local directiva="$1"
        local valor="$2"

        # Si la directiva ya existe se reemplaza
        if sudo grep -qE "^#?${directiva}\b" /etc/ssh/sshd_config 2>/dev/null; then
            sudo sed -i "s/^#*${directiva}.*/${directiva} ${valor}/" /etc/ssh/sshd_config
        else
            # Se agrega al final 
            echo "${directiva} ${valor}" | sudo tee -a /etc/ssh/sshd_config > /dev/null
        fi
    }

    # Puerto SSH 
    _set_sshd_param "Port" "22"
    echo "    Port                  -> 22"

    # Desactivar login directo como root
    _set_sshd_param "PermitRootLogin" "no"
    echo "    PermitRootLogin       -> no"

    # Habilitar autenticación por clave pública
    _set_sshd_param "PubkeyAuthentication" "yes"
    echo "    PubkeyAuthentication  -> yes"

    # Donde buscar las claves públicas autorizadas del usuario
    _set_sshd_param "AuthorizedKeysFile" ".ssh/authorized_keys"
    echo "    AuthorizedKeysFile    -> .ssh/authorized_keys"

    # Mantener contraseña activa 
    _set_sshd_param "PasswordAuthentication" "yes"
    echo "    PasswordAuthentication -> yes"

    # No reenviar sesiones gráficas 
    _set_sshd_param "X11Forwarding" "no"
    echo "    X11Forwarding         -> no"

    # Mostrar la última vez que se conectó el usuario 
    _set_sshd_param "PrintLastLog" "yes"
    echo "    PrintLastLog          -> yes"

    # Añadir el usuario a la lista de permitidos
    # AllowUsers limita explícitamente quién puede conectarse
    _set_sshd_param "AllowUsers" "$usuario_ssh"
    echo "    AllowUsers            -> $usuario_ssh"

    draw_line

    # ─── 4. Validar sintaxis antes de recargar ────────────────────────────
    # sshd -t prueba la configuración sin afectar el servicio activo
    aputs_info "4. Validando sintaxis de sshd_config..."
    echo ""

    if sudo sshd -t 2>/dev/null; then
        aputs_success "Sintaxis valida — sin errores"
    else
        aputs_error "Error de sintaxis en sshd_config:"
        sudo sshd -t 2>&1 | sed 's/^/    /'
        echo ""
        aputs_warning "Restaurando backup..."
        sudo cp "$backup" /etc/ssh/sshd_config
        aputs_info "Backup restaurado. Corrija los errores e intente de nuevo."
        return 1
    fi

    draw_line

    # ─── 5. Reiniciar servicio para aplicar cambios ───────────────────────
    aputs_info "5. Reiniciando sshd para aplicar cambios..."
    echo ""

    if sudo systemctl restart sshd 2>/dev/null; then
        sleep 2
        if check_service_active "sshd"; then
            aputs_success "sshd reiniciado y activo correctamente"

            local pid
            pid=$(sudo systemctl show sshd --property=MainPID --value 2>/dev/null)
            echo "    Nuevo PID: $pid"
        else
            aputs_error "sshd no levanto correctamente tras el reinicio"
            sudo journalctl -u sshd -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
            return 1
        fi
    else
        aputs_error "Error al reiniciar sshd"
        return 1
    fi

    draw_line
    echo ""
    aputs_success "Instalacion y configuracion completada exitosamente"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/utils.sh"
    source "${SCRIPT_DIR}/validators_ssh.sh"
    instalar_configurar_ssh
    pause
fi