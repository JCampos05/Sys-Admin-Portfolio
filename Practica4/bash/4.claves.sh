#
# Generación y despliegue de par de claves SSH (pública/privada)
#
# Depende de: utils.sh, validators_ssh.sh
#

# ─── 1. Generar par de claves ─────────────────────────────────────────────────
# ssh-keygen crea DOS archivos:
#   ~/.ssh/id_tipo -> clave PRIVADA (nunca se comparte)
#   ~/.ssh/id_tipo.pub -> clave PÚBLICA (se copia al servidor)
_generar_claves() {
    clear
    draw_header "Generar Par de Claves SSH"

    echo ""
    aputs_info "Se generara un par de claves criptograficas:"
    aputs_info "  - Clave PRIVADA: permanece en este equipo (cliente)"
    aputs_info "  - Clave PUBLICA: se copia al servidor para autenticarse"

    # Verificar que ~/.ssh existe, si no crearlo con permisos correctos
    # Los permisos 700 en ~/.ssh son obligatorios — SSH rechaza permisos más abiertos
    if [[ ! -d "$HOME/.ssh" ]]; then
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        aputs_success "Directorio ~/.ssh creado"
    fi

    draw_line

    # ─ Tipo de clave ─────────────────────────────────────────────────────
    aputs_info "Tipo de clave criptografica:"
    echo ""
    echo "    1) ed25519  (recomendado -> rapido y seguro)"
    echo "    2) rsa      (compatible con sistemas mas antiguos)"
    echo "    3) ecdsa    (alta seguridad -> curvas elipticas)"
    echo ""

    local tipo_clave
    while true; do
        agets "Tipo de clave [1]" tipo_clave
        tipo_clave="${tipo_clave:-1}"

        case "$tipo_clave" in
            1) tipo_clave="ed25519" ;;
            2) tipo_clave="rsa"     ;;
            3) tipo_clave="ecdsa"   ;;
        esac

        if ssh_validar_tipo_clave "$tipo_clave"; then
            break
        fi
        echo ""
    done

    echo ""

    # ─ Bits (solo para RSA) ───────────────────────────────────────────────
    local bits_arg=""
    if [[ "$tipo_clave" == "rsa" ]]; then
        aputs_info "Numero de bits para RSA:"
        echo "    1) 2048  (minimo aceptable)"
        echo "    2) 3072  (recomendado)"
        echo "    3) 4096  (maxima seguridad)"
        echo ""

        local bits_opcion bits_valor
        while true; do
            agets "Seleccione opcion [2]" bits_opcion
            bits_opcion="${bits_opcion:-2}"

            case "$bits_opcion" in
                1) bits_valor="2048" ;;
                2) bits_valor="3072" ;;
                3) bits_valor="4096" ;;
                *) bits_valor="$bits_opcion" ;;
            esac

            if ssh_validar_bits_rsa "$bits_valor"; then
                bits_arg="-b $bits_valor"
                break
            fi
            echo ""
        done
        echo ""
    fi

    # ─ Nombre del archivo de clave ────────────────────────────────────────
    local nombre_defecto="$HOME/.ssh/id_${tipo_clave}"
    aputs_info "Ruta y nombre del archivo de clave:"
    aputs_info "Predeterminado: $nombre_defecto"
    echo ""

    local ruta_clave
    agets "Ruta del archivo [Enter = predeterminado]" ruta_clave
    ruta_clave="${ruta_clave:-$nombre_defecto}"

    echo ""

    # ─ Passphrase (contraseña de la clave privada) ────────────────────────
    # La passphrase cifra la clave privada. Si alguien roba el archivo,
    aputs_info "Passphrase de la clave privada (contrasena adicional):"
    aputs_info "Dejar vacia = sin proteccion adicional (menos seguro)"
    echo ""

    # Advertir si ya existe una clave en esa ruta
    if [[ -f "$ruta_clave" ]]; then
        aputs_warning "Ya existe una clave en: $ruta_clave"
        local sobrescribir
        read -rp "  ¿Sobrescribir? (s/n): " sobrescribir
        if [[ "$sobrescribir" != "s" && "$sobrescribir" != "S" ]]; then
            aputs_info "Operacion cancelada"
            return 0
        fi
    fi

    echo ""

    # Generar la clave con ssh-keygen
    # -t: tipo de clave
    # -f: archivo de salida
    # -C: comentario (identificador de la clave)
    # ${bits_arg}: bits solo si es RSA (vacío para ed25519/ecdsa)
    if ssh-keygen -t "$tipo_clave" $bits_arg \
                    -f "$ruta_clave" \
                    -C "${USER}@$(hostname)_$(date +%Y%m%d)"; then
        echo ""
        aputs_success "Par de claves generado correctamente"
        echo ""
        echo "  Clave privada : $ruta_clave"
        echo "  Clave publica : ${ruta_clave}.pub"
        echo ""

        # Mostrar la clave pública para que el usuario la conozca
        aputs_info "Clave publica generada:"
        cat "${ruta_clave}.pub"
        echo ""
        aputs_info "Copie esta clave publica al servidor con la opcion 2)"
    else
        aputs_error "Error durante la generacion de claves"
        return 1
    fi
}

# ─── 2. Copiar clave pública al servidor ──────────────────────────────────────
# ssh-copy-id copia nuestra clave pública al archivo authorized_keys del servidor
# Después de esto se puede conectar sin contraseña
_copiar_clave() {
    clear
    draw_header "Copiar Clave Publica al Servidor"

    aputs_info "ssh-copy-id instala su clave publica en el servidor remoto."
    aputs_info "Necesitara la contrasena del servidor UNA ultima vez."
    draw_line

    # ─ IP del servidor destino ────────────────────────────────────────────
    local ip_servidor
    while true; do
        agets "IP del servidor destino " ip_servidor
        if ssh_validar_ip "$ip_servidor"; then
            break
        fi
        echo ""
    done

    echo ""

    # ─ Usuario en el servidor ─────────────────────────────────────────────
    local usuario_remoto
    while true; do
        agets "Usuario en el servidor remoto (ej: adminuser)" usuario_remoto
        if ssh_validar_nombre_usuario "$usuario_remoto"; then
            break
        fi
        echo ""
    done

    echo ""

    # ─ Puerto del servidor ────────────────────────────────────────────────
    local puerto_remoto
    while true; do
        agets "Puerto SSH del servidor [22]" puerto_remoto
        puerto_remoto="${puerto_remoto:-22}"
        if ssh_validar_puerto "$puerto_remoto"; then
            break
        fi
        echo ""
    done

    echo ""

    # ─ Clave pública a copiar ─────────────────────────────────────────────
    aputs_info "Claves publicas disponibles en ~/.ssh/:"
    echo ""

    local claves=()
    while IFS= read -r pub; do
        claves+=("$pub")
        echo "    - $pub"
    done < <(find "$HOME/.ssh" -name "*.pub" -type f 2>/dev/null)

    if [[ ${#claves[@]} -eq 0 ]]; then
        aputs_warning "No se encontraron claves publicas en ~/.ssh/"
        aputs_info "Genere una clave con la opcion 1) primero"
        return 1
    fi

    echo ""
    local clave_pub
    agets "Ruta de la clave publica [${claves[0]}]" clave_pub
    clave_pub="${clave_pub:-${claves[0]}}"

    if [[ ! -f "$clave_pub" ]]; then
        aputs_error "No se encontro el archivo: $clave_pub"
        return 1
    fi

    echo ""
    draw_line

    # Verificar conectividad antes de intentar copiar
    aputs_info "Verificando conectividad con $ip_servidor..."
    if ! check_connectivity "$ip_servidor"; then
        aputs_error "No hay conectividad con $ip_servidor"
        aputs_info "Verifique que el servidor esta encendido y accesible"
        return 1
    fi
    aputs_success "Servidor accesible"
    echo ""

    # ssh-copy-id copia la clave al archivo ~/.ssh/authorized_keys del servidor
    aputs_info "Copiando clave publica a ${usuario_remoto}@${ip_servidor}..."
    echo ""

    if ssh-copy-id -i "$clave_pub" -p "$puerto_remoto" \
                    "${usuario_remoto}@${ip_servidor}"; then
        echo ""
        aputs_success "Clave publica copiada exitosamente"
        echo ""
        aputs_info "Ahora puede conectarse sin contrasena:"
        echo "    ssh -p ${puerto_remoto} ${usuario_remoto}@${ip_servidor}"
    else
        aputs_error "Error al copiar la clave publica"
        aputs_info "Asegurese de que el servidor SSH esta activo y acepta contraseñas temporalmente"
        return 1
    fi
}

# ─── 3. Ver claves autorizadas en este servidor ───────────────────────────────
_ver_autorizadas() {
    clear
    draw_header "Claves Autorizadas en este Servidor"

    echo ""
    aputs_info "Usuario del sistema a consultar:"
    echo ""

    # Listar usuarios reales (UID >= 1000)
    awk -F: '$3 >= 1000 && $3 < 65534 {print "  - " $1 " (home: " $6 ")"}' /etc/passwd
    echo ""

    local usuario
    while true; do
        agets "Usuario a consultar" usuario
        if ssh_validar_usuario_existe "$usuario"; then
            break
        fi
        echo ""
    done

    echo ""
    draw_line

    local home_usuario
    home_usuario=$(eval echo "~${usuario}")
    local auth_keys="${home_usuario}/.ssh/authorized_keys"

    if [[ -f "$auth_keys" ]]; then
        local total
        total=$(wc -l < "$auth_keys")
        aputs_success "Archivo encontrado: $auth_keys ($total clave(s))"
        echo ""
        aputs_info "Claves autorizadas:"
        echo ""

        local i=1
        while IFS= read -r linea; do
            if [[ -n "$linea" && ! "$linea" =~ ^# ]]; then
                # Extraer el comentario de la clave (último campo)
                local tipo comentario
                tipo=$(echo "$linea" | awk '{print $1}')
                comentario=$(echo "$linea" | awk '{print $NF}')
                echo "  $i) Tipo: $tipo"
                echo "     ID:   $comentario"
                (( i++ ))
            fi
        done < "$auth_keys"
    else
        aputs_warning "No existe archivo authorized_keys para el usuario '$usuario'"
        aputs_info "Ruta esperada: $auth_keys"
        aputs_info "Copie una clave publica con la opcion 2)"
    fi
}

# ─── 4. Agregar clave pública manualmente ────────────────────────────────────
# Útil cuando se tiene la clave pública del cliente como texto
_agregar_clave() {
    clear
    draw_header "Agregar Clave Publica Manualmente"

    echo ""
    aputs_info "Use esta opcion si tiene el contenido de una clave .pub"
    aputs_info "que desea autorizar en este servidor."
    echo ""

    # Usuario cuyo authorized_keys se modificará
    local usuario
    while true; do
        agets "Usuario del servidor donde agregar la clave" usuario
        if ssh_validar_usuario_existe "$usuario"; then
            break
        fi
        echo ""
    done

    echo ""

    # Solicitar el contenido de la clave pública
    aputs_info "Pegue el contenido completo de la clave publica (.pub):"
    aputs_info "Formato: ssh-ed25519 AAAA... usuario@equipo"
    echo ""

    local clave_publica
    agets "Clave publica" clave_publica

    if [[ -z "$clave_publica" ]]; then
        aputs_error "No se ingreso ninguna clave"
        return 1
    fi

    # Validar que tenga formato de clave SSH (comienza con ssh- o ecdsa-)
    if [[ ! "$clave_publica" =~ ^(ssh-|ecdsa-) ]]; then
        aputs_error "El formato no parece ser una clave SSH valida"
        aputs_info "La clave debe comenzar con: ssh-rsa, ssh-ed25519 o ecdsa-sha2-nistp256"
        return 1
    fi

    echo ""
    draw_line

    local home_usuario
    home_usuario=$(eval echo "~${usuario}")
    local ssh_dir="${home_usuario}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"

    # Crear directorio .ssh si no existe (con permisos correctos)
    if [[ ! -d "$ssh_dir" ]]; then
        sudo mkdir -p "$ssh_dir"
        sudo chmod 700 "$ssh_dir"
        sudo chown "${usuario}:${usuario}" "$ssh_dir"
        aputs_success "Directorio .ssh creado"
    fi

    # Verificar que la clave no esté duplicada
    if [[ -f "$auth_keys" ]] && grep -qF "$clave_publica" "$auth_keys" 2>/dev/null; then
        aputs_warning "Esta clave ya existe en authorized_keys"
        return 0
    fi

    # Añadir la clave al archivo authorized_keys
    echo "$clave_publica" | sudo tee -a "$auth_keys" > /dev/null
    sudo chmod 600 "$auth_keys"
    sudo chown "${usuario}:${usuario}" "$auth_keys"

    aputs_success "Clave publica agregada correctamente"
    echo ""
    aputs_info "El usuario puede conectarse con su clave privada correspondiente"
}

# ─── Submenú de claves ────────────────────────────────────────────────────────
claves_ssh_menu() {
    while true; do
        clear
        draw_header "Gestion de Claves SSH"
        echo ""
        aputs_info "1) Generar nuevo par de claves (privada + publica)"
        aputs_info "2) Copiar clave publica al servidor remoto"
        aputs_info "3) Ver claves autorizadas en este servidor"
        aputs_info "4) Agregar clave publica manualmente"
        aputs_info "5) Volver al menu principal"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1) _generar_claves    ;;
            2) _copiar_clave      ;;
            3) _ver_autorizadas   ;;
            4) _agregar_clave     ;;
            5) return 0           ;;
            *) aputs_error "Opcion invalida" ; sleep 1 ;;
        esac

        echo ""
        pause
    done
}
# ─── Punto de entrada del módulo ─────────────────────────────────────────────
gestionar_claves_ssh() {
    if ! check_privileges; then
        return 1
    fi
    claves_ssh_menu
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/utils.sh"
    source "${SCRIPT_DIR}/validators_ssh.sh"
    gestionar_claves_ssh
fi