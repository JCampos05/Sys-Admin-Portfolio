#!/bin/bash
#
# FunctionsFTP-C.sh
# Grupo C — Gestión de usuarios y grupos FTP
#
# Requiere: utils.sh, utilsFTP.sh, validatorsFTP.sh, FunctionsFTP-B.sh
# (necesita _ftp_crear_bind_mount, _ftp_eliminar_bind_mount)
#

# -----------------------------------------------------------------------------
# Helpers internos de directorios de usuario
# -----------------------------------------------------------------------------

_ftp_crear_dirs_usuario() {
    local usuario="$1" grupo="$2"
    local user_root="${FTP_ROOT}/${FTP_USER_PREFIX}${usuario}"

    if ! id "$usuario" &>/dev/null; then
        useradd \
            --shell /sbin/nologin \
            --home-dir "$user_root" \
            --no-create-home \
            --gid "$grupo" \
            --groups "$FTP_SSH_GROUP" \
            --password '!' \
            "$usuario"
        aputs_success "Usuario del sistema '$usuario' creado (grupo: $grupo)"
    fi
    usermod -g "$grupo"        "$usuario" 2>/dev/null
    usermod -aG "$FTP_SSH_GROUP" "$usuario" 2>/dev/null

    mkdir -p "$user_root"
    chown root:root "$user_root"; chmod 755 "$user_root"

    local privada="$user_root/$usuario"
    mkdir -p "$privada"
    chown "$usuario":"$grupo" "$privada"; chmod 700 "$privada"

    _ftp_crear_bind_mount "$FTP_GENERAL"       "$user_root/general"
    _ftp_crear_bind_mount "${FTP_ROOT}/$grupo"  "$user_root/$grupo"

    setfacl -m  "u:${usuario}:rwx" "$FTP_GENERAL"       2>/dev/null || true
    setfacl -m  "u:${usuario}:rwx" "${FTP_ROOT}/$grupo"  2>/dev/null || true
    setfacl -d -m "u:${usuario}:rwx" "${FTP_ROOT}/$grupo" 2>/dev/null || true

    _ftp_selinux_context "$user_root"
}

_ftp_eliminar_mounts_usuario() {
    local usuario="$1"
    local user_root="${FTP_ROOT}/${FTP_USER_PREFIX}${usuario}"
    _ftp_eliminar_bind_mount "$user_root/general"
    local g; for g in "${FTP_GROUPS[@]}"; do
        [[ -d "$user_root/$g" ]] && _ftp_eliminar_bind_mount "$user_root/$g"
    done
}

_ftp_actualizar_mounts_usuario() {
    local usuario="$1" nuevo_grupo="$2"
    local user_root="${FTP_ROOT}/${FTP_USER_PREFIX}${usuario}"
    local g; for g in "${FTP_GROUPS[@]}"; do
        [[ -d "$user_root/$g" ]] && _ftp_eliminar_bind_mount "$user_root/$g"
    done
    _ftp_crear_bind_mount "$FTP_GENERAL"              "$user_root/general"
    _ftp_crear_bind_mount "${FTP_ROOT}/$nuevo_grupo"  "$user_root/$nuevo_grupo"
}

_ftp_renombrar_dirs_usuario() {
    local viejo="$1" nuevo="$2" grupo="$3"
    local old_root="${FTP_ROOT}/${FTP_USER_PREFIX}${viejo}"
    local new_root="${FTP_ROOT}/${FTP_USER_PREFIX}${nuevo}"
    [[ ! -d "$old_root" ]] && return 0
    _ftp_eliminar_mounts_usuario "$viejo"
    mv "$old_root" "$new_root"
    if [[ -d "$new_root/$viejo" ]]; then
        mv "$new_root/$viejo" "$new_root/$nuevo"
        chown "$nuevo":"$grupo" "$new_root/$nuevo"
        chmod 700 "$new_root/$nuevo"
    fi
    _ftp_crear_bind_mount "$FTP_GENERAL"       "$new_root/general"
    _ftp_crear_bind_mount "${FTP_ROOT}/$grupo"  "$new_root/$grupo"
    _ftp_selinux_context "$new_root"
}

# -----------------------------------------------------------------------------
# CRUD Usuarios
# -----------------------------------------------------------------------------

ftp_crear_usuarios() {
    draw_line
    echo -ne "${CYAN}[INPUT]${NC} Número de usuarios a crear: "
    read -r n
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || { aputs_error "Número inválido"; return 1; }

    local total=$n creados=0
    while (( creados < total )); do
        draw_line
        aputs_info "Usuario $((creados+1)) de $total"

        local usuario=""
        while true; do
            echo -ne "${CYAN}[INPUT]${NC} Nombre de usuario FTP: "
            read -r usuario
            ftp_validar_nombre_usuario "$usuario" || continue
            ftp_usuario_existe "$usuario" && aputs_error "Ya existe '$usuario'" && continue
            id "$usuario" &>/dev/null && aputs_error "Usuario del sistema '$usuario' ya existe" && continue
            break
        done

        local pass=""
        ftp_pedir_contrasena pass
        stty echo 2>/dev/null

        local grupo=""
        ftp_pedir_grupo grupo

        _ftp_crear_dirs_usuario "$usuario" "$grupo"
        _ftp_set_password "$usuario" "$pass"
        ftp_meta_set "$usuario" "$grupo"

        aputs_success "Usuario '$usuario' creado en grupo '$grupo'"
        (( creados++ ))
    done

    systemctl restart vsftpd
    aputs_success "$total usuario(s) creado(s). vsftpd reiniciado."
}

ftp_actualizar_usuario() {
    draw_line
    echo -ne "${CYAN}[INPUT]${NC} Nombre del usuario FTP a actualizar: "
    read -r usuario
    ftp_usuario_existe "$usuario" || { aputs_error "El usuario '$usuario' no existe"; return 1; }

    local grupo_actual; grupo_actual=$(ftp_meta_get_grupo "$usuario")
    aputs_info "Usuario : $usuario  |  Grupo: $grupo_actual"
    aputs_info "(Enter = sin cambios)"
    draw_line

    # Nombre
    echo -ne "${CYAN}[INPUT]${NC} Nuevo nombre [$usuario]: "
    read -r nuevo_nombre
    if [[ -n "$nuevo_nombre" && "$nuevo_nombre" != "$usuario" ]]; then
        if ! ftp_validar_nombre_usuario "$nuevo_nombre"; then
            aputs_error "Nombre inválido — sin cambios"
        elif ftp_usuario_existe "$nuevo_nombre"; then
            aputs_error "'$nuevo_nombre' ya en uso"
        else
            id "$usuario" &>/dev/null && usermod -l "$nuevo_nombre" "$usuario" 2>/dev/null && \
                aputs_success "Login del sistema: '$usuario' → '$nuevo_nombre'"
            sed -i "s|^${usuario}:|${nuevo_nombre}:|" "$VSFTPD_USERS_META"
            _ftp_renombrar_dirs_usuario "$usuario" "$nuevo_nombre" "$grupo_actual"
            aputs_success "Usuario FTP renombrado: '$usuario' → '$nuevo_nombre'"
            usuario="$nuevo_nombre"
        fi
    fi

    # Carpeta privada
    local user_root="${FTP_ROOT}/${FTP_USER_PREFIX}${usuario}"
    local carpeta_actual=""
    if [[ -d "$user_root" ]]; then
        carpeta_actual=$(find "$user_root" -maxdepth 1 -mindepth 1 -type d \
            ! -name "general" $(printf -- "! -name %s " "${FTP_GROUPS[@]}") \
            | xargs -I{} basename {} 2>/dev/null | head -1)
    fi
    if [[ -n "$carpeta_actual" ]]; then
        echo -ne "${CYAN}[INPUT]${NC} Renombrar carpeta privada '$carpeta_actual' [Enter = dejar igual]: "
        read -r nuevo_carpeta
        if [[ -n "$nuevo_carpeta" && "$nuevo_carpeta" != "$carpeta_actual" ]]; then
            local ruta_vieja="$user_root/$carpeta_actual"
            local ruta_nueva="$user_root/$nuevo_carpeta"
            if [[ -e "$ruta_nueva" ]]; then
                aputs_error "Ya existe '$nuevo_carpeta' — sin cambios"
            else
                mv "$ruta_vieja" "$ruta_nueva"
                chown "$usuario":"$grupo_actual" "$ruta_nueva"; chmod 700 "$ruta_nueva"
                aputs_success "Carpeta privada: '$carpeta_actual' → '$nuevo_carpeta'"
            fi
        fi
    fi

    # Contraseña
    echo -ne "${CYAN}[INPUT]${NC} ¿Cambiar contraseña? [s/N]: "; read -r cp
    if [[ "$cp" =~ ^[Ss]$ ]]; then
        local nueva_pass=""
        ftp_pedir_contrasena nueva_pass
        stty echo 2>/dev/null
        _ftp_set_password "$usuario" "$nueva_pass"
        aputs_success "Contraseña actualizada"
    fi

    # Grupo
    aputs_info "Grupo actual: $grupo_actual"
    echo -ne "${CYAN}[INPUT]${NC} ¿Cambiar grupo? [s/N]: "; read -r cg
    if [[ "$cg" =~ ^[Ss]$ ]]; then
        local nuevo_grupo=""
        ftp_pedir_grupo nuevo_grupo
        if [[ "$nuevo_grupo" != "$grupo_actual" ]]; then
            usermod -g "$nuevo_grupo" "$usuario" 2>/dev/null
            setfacl -x "u:${usuario}" "${FTP_ROOT}/$grupo_actual" 2>/dev/null || true
            setfacl -m  "u:${usuario}:rwx" "${FTP_ROOT}/$nuevo_grupo" 2>/dev/null || true
            setfacl -d -m "u:${usuario}:rw"  "${FTP_ROOT}/$nuevo_grupo" 2>/dev/null || true
            ftp_meta_set "$usuario" "$nuevo_grupo"
            _ftp_actualizar_mounts_usuario "$usuario" "$nuevo_grupo"
            aputs_success "Grupo: '$grupo_actual' → '$nuevo_grupo'"
        else
            aputs_info "Mismo grupo — sin cambios"
        fi
    fi

    systemctl restart vsftpd
    aputs_success "Actualización de '$usuario' completada"
}

ftp_eliminar_usuario() {
    draw_line
    echo -ne "${CYAN}[INPUT]${NC} Nombre del usuario FTP a eliminar: "
    read -r usuario
    ftp_usuario_existe "$usuario" || { aputs_error "El usuario '$usuario' no existe"; return 1; }

    local grupo; grupo=$(ftp_meta_get_grupo "$usuario")
    local user_dir="${FTP_ROOT}/${FTP_USER_PREFIX}${usuario}"
    aputs_info "Usuario: $usuario  |  Grupo: $grupo  |  Dir: $user_dir"

    echo -ne "${CYAN}[INPUT]${NC} Confirma eliminar '$usuario' [s/N]: "; read -r confirm
    [[ "$confirm" =~ ^[Ss]$ ]] || { aputs_info "Cancelado"; return 0; }

    echo -ne "${CYAN}[INPUT]${NC} ¿Eliminar directorio del usuario? [s/N]: "; read -r del_dir

    setfacl -x "u:${usuario}" "$FTP_GENERAL"          2>/dev/null || true
    setfacl -x "u:${usuario}" "${FTP_ROOT}/$grupo"    2>/dev/null || true
    _ftp_eliminar_mounts_usuario "$usuario"
    id "$usuario" &>/dev/null && userdel "$usuario" && \
        aputs_success "Usuario del sistema '$usuario' eliminado"
    ftp_meta_del "$usuario"
    [[ "$del_dir" =~ ^[Ss]$ ]] && rm -rf "$user_dir" && aputs_success "Directorio eliminado"

    systemctl restart vsftpd
    aputs_success "Usuario '$usuario' eliminado"
}

# -----------------------------------------------------------------------------
# CRUD Grupos
# -----------------------------------------------------------------------------

ftp_crear_grupo() {
    draw_line
    echo -ne "${CYAN}[INPUT]${NC} Nombre del nuevo grupo: "
    read -r nuevo_grupo
    ftp_validar_nombre_grupo "$nuevo_grupo" || return 1

    local g; for g in "${FTP_GROUPS[@]}"; do
        [[ "$g" == "$nuevo_grupo" ]] && aputs_warning "El grupo '$nuevo_grupo' ya existe" && return 1
    done

    getent group "$nuevo_grupo" &>/dev/null || groupadd "$nuevo_grupo" || {
        aputs_error "groupadd falló"; return 1
    }

    local dir="${FTP_ROOT}/$nuevo_grupo"
    mkdir -p "$dir"
    chown root:"$nuevo_grupo" "$dir"; chmod 770 "$dir"

    FTP_GROUPS+=("$nuevo_grupo")
    _ftp_guardar_grupos
    aputs_success "Grupo '$nuevo_grupo' creado"
}

ftp_eliminar_grupo() {
    draw_line
    ftp_listar_grupos

    echo -ne "${CYAN}[INPUT]${NC} Nombre del grupo a eliminar: "
    read -r grupo_eliminar

    local encontrado=false
    local g; for g in "${FTP_GROUPS[@]}"; do
        [[ "$g" == "$grupo_eliminar" ]] && encontrado=true && break
    done
    $encontrado || { aputs_error "Grupo no encontrado"; return 1; }
    (( ${#FTP_GROUPS[@]} <= 1 )) && { aputs_error "Debe quedar al menos un grupo"; return 1; }

    local miembros
    miembros=$(grep ":${grupo_eliminar}$" "$VSFTPD_USERS_META" 2>/dev/null | cut -d: -f1)
    if [[ -n "$miembros" ]]; then
        aputs_info "Usuarios a reasignar: $(echo "$miembros" | tr '\n' ' ')"
        local grupo_destino=""
        ftp_pedir_grupo grupo_destino
        while IFS= read -r u; do
            [[ -z "$u" ]] && continue
            ftp_meta_set "$u" "$grupo_destino"
            _ftp_actualizar_mounts_usuario "$u" "$grupo_destino"
            aputs_success "'$u' reasignado a '$grupo_destino'"
        done <<< "$miembros"
    fi

    local dir="${FTP_ROOT}/$grupo_eliminar"
    if [[ -d "$dir" ]]; then
        echo -ne "${CYAN}[INPUT]${NC} ¿Eliminar directorio $dir? [s/N]: "
        read -r resp
        [[ "$resp" =~ ^[Ss]$ ]] && rm -rf "$dir" && aputs_success "Directorio eliminado"
    fi

    getent group "$grupo_eliminar" &>/dev/null && groupdel "$grupo_eliminar" 2>/dev/null

    local nuevos=()
    for g in "${FTP_GROUPS[@]}"; do
        [[ "$g" != "$grupo_eliminar" ]] && nuevos+=("$g")
    done
    FTP_GROUPS=("${nuevos[@]}")
    _ftp_guardar_grupos
    aputs_success "Grupo '$grupo_eliminar' eliminado"
}

# -----------------------------------------------------------------------------
# ftp_menu_gestion
# Menú del Grupo C.
# -----------------------------------------------------------------------------
ftp_menu_gestion() {
    while true; do
        clear
        ftp_draw_header "Grupo C — Gestión de Usuarios y Grupos"

        if [[ ${#FTP_GROUPS[@]} -gt 0 ]]; then
            echo -e "  ${GRAY}Grupos activos: ${FTP_GROUPS[*]}${NC}"
            echo ""
        fi

        echo -e "  ${CYAN}— Usuarios —${NC}"
        echo -e "  ${BLUE}1)${NC} Crear usuario(s)"
        echo -e "  ${BLUE}2)${NC} Actualizar usuario"
        echo -e "  ${BLUE}3)${NC} Eliminar usuario"
        echo ""
        echo -e "  ${CYAN}— Grupos —${NC}"
        echo -e "  ${BLUE}4)${NC} Crear grupo"
        echo -e "  ${BLUE}5)${NC} Eliminar grupo"
        echo -e "  ${BLUE}0)${NC} Volver al menú principal"
        echo ""

        local op
        read -rp "  Opción: " op
        case "$op" in
            1) ftp_crear_usuarios   ; pause ;;
            2) ftp_actualizar_usuario; pause ;;
            3) ftp_eliminar_usuario  ; pause ;;
            4) ftp_crear_grupo       ; pause ;;
            5) ftp_eliminar_grupo    ; pause ;;
            0) return 0 ;;
            *) aputs_error "Opción inválida"; sleep 1 ;;
        esac
    done
}

export -f _ftp_crear_dirs_usuario
export -f _ftp_eliminar_mounts_usuario
export -f _ftp_actualizar_mounts_usuario
export -f _ftp_renombrar_dirs_usuario
export -f ftp_crear_usuarios
export -f ftp_actualizar_usuario
export -f ftp_eliminar_usuario
export -f ftp_crear_grupo
export -f ftp_eliminar_grupo
export -f ftp_menu_gestion