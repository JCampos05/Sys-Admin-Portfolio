#
#
# Módulo: Gestión de usuarios y grupos FTP 
#
# Requiere:
#   utils.sh          
#

# ─────────────────────────────────────────────────────────────────────────────
#   MENÚ DE GESTIÓN (punto de entrada desde mainFTP.sh)
# ─────────────────────────────────────────────────────────────────────────────

# Submenú de usuarios y grupos — se llama desde main_menu opción 3
gestionar_usuarios_grupos() {
    while true; do
        clear
        draw_header "Gestion de Usuarios y Grupos FTP"
        echo ""
        aputs_info "  ── Usuarios ────────────────────────────"
        aputs_info "  1) Crear usuario(s) FTP"
        aputs_info "  2) Listar usuarios FTP"
        aputs_info "  3) Cambiar grupo de usuario FTP"
        aputs_info "  4) Eliminar usuario FTP"
        echo ""
        aputs_info "  ── Grupos ──────────────────────────────"
        aputs_info "  5) Crear grupo FTP"
        aputs_info "  6) Listar grupos FTP"
        aputs_info "  7) Eliminar grupo FTP"
        echo ""
        aputs_info "  8) Volver al menu principal"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1) _crear_usuarios_lote ;;
            2) _listar_usuarios_ftp; pause ;;
            3) _cambiar_grupo_usuario; pause ;;
            4) _eliminar_usuario_ftp; pause ;;
            5) _crear_grupo_ftp; pause ;;
            6) _listar_grupos_ftp; pause ;;
            7) _eliminar_grupo_ftp; pause ;;
            8) return 0 ;;
            *)
                aputs_error "Opcion invalida. Seleccione del 1 al 8"
                sleep 2
                ;;
        esac
    done
}

# Obtiene el grupo registrado de un usuario en el archivo .meta
# Uso: _meta_get_grupo "juan_perez"  → imprime "reprobados"
_meta_get_grupo() {
    grep -m1 "^${1}:" "$VSFTPD_USERS_META" 2>/dev/null | cut -d: -f2
}

# Agrega o actualiza la entrada de un usuario en el archivo .meta
# Uso: _meta_set "juan_perez" "reprobados"
_meta_set() {
    local u="$1" g="$2"
    if grep -q "^${u}:" "$VSFTPD_USERS_META" 2>/dev/null; then
        sed -i "s|^${u}:.*|${u}:${g}|" "$VSFTPD_USERS_META"
    else
        echo "${u}:${g}" >> "$VSFTPD_USERS_META"
    fi
}

# Elimina la entrada de un usuario del archivo .meta
# Uso: _meta_del "juan_perez"
_meta_del() {
    sed -i "/^${1}:/d" "$VSFTPD_USERS_META"
}

# Verifica si un usuario está registrado en el archivo .meta
# Retorna 0 si existe, 1 si no
_meta_existe() {
    grep -q "^${1}:" "$VSFTPD_USERS_META" 2>/dev/null
}

# Pide contraseña con confirmación y validación de seguridad
# Almacena el resultado en la variable cuyo nombre se pasa como $1
# Uso: _pedir_contrasena_confirmada mi_var
_pedir_contrasena_confirmada() {
    local __var="$1"
    local p1 p2

    while true; do
        # Leer sin eco para no mostrar la contraseña en pantalla
        echo -ne "${CYAN}[INPUT]${NC} Contrasena: "
        read -rs p1
        echo

        # Validar requisitos de seguridad
        if ! ftp_validar_contrasena "$p1"; then
            continue
        fi

        echo -ne "${CYAN}[INPUT]${NC} Confirma contrasena: "
        read -rs p2
        echo

        if [[ "$p1" != "$p2" ]]; then
            aputs_error "Las contrasenas no coinciden — intente de nuevo"
            continue
        fi

        # Asignar el valor a la variable del llamador
        printf -v "$__var" "%s" "$p1"
        return 0
    done
}

# Muestra el menú de grupos disponibles y espera selección
# Almacena el grupo elegido en la variable cuyo nombre se pasa como $1
# Uso: _pedir_grupo mi_var
_pedir_grupo() {
    local __var="${1:-_grupo_sel}"

    # Cargar grupos actuales del archivo de lista
    local grupos=()
    if [[ -f "$VSFTPD_GROUPS_FILE" ]]; then
        while IFS= read -r linea; do
            linea="${linea%%#*}"; linea="${linea//[[:space:]]/}"
            [[ -z "$linea" ]] && continue
            grupos+=("$linea")
        done < "$VSFTPD_GROUPS_FILE"
    fi

    if [[ ${#grupos[@]} -eq 0 ]]; then
        aputs_error "No hay grupos FTP definidos"
        aputs_info "Cree al menos un grupo desde la opcion 5 del submenu"
        return 1
    fi

    while true; do
        echo ""
        aputs_info "Grupos disponibles:"
        local i
        for i in "${!grupos[@]}"; do
            echo "    $((i+1))) ${grupos[$i]}"
        done

        local sel
        agets "Selecciona grupo [1-${#grupos[@]}]" sel

        if [[ "$sel" =~ ^[0-9]+$ ]] \
           && (( sel >= 1 && sel <= ${#grupos[@]} )); then
            printf -v "$__var" "%s" "${grupos[$((sel-1))]}"
            return 0
        fi
        aputs_error "Seleccion invalida — ingrese un numero del 1 al ${#grupos[@]}"
    done
}

# C — Crear uno o más usuarios FTP en lote
_crear_usuarios_lote() {
    draw_header "Crear Usuarios FTP"

    local n
    agets "Numero de usuarios a crear" n
    if [[ ! "$n" =~ ^[1-9][0-9]*$ ]]; then
        aputs_error "Ingrese un numero valido (entero >= 1)"
        return 1
    fi

    local total="$n"
    local creados=0

    while (( creados < total )); do
        echo ""
        draw_line
        aputs_info "Usuario $((creados+1)) de $total"
        draw_line

        # ── Nombre ──────────────────────────────────────────────────────────
        local usuario=""
        while true; do
            agets "Nombre de usuario FTP" usuario

            # Validar formato
            ftp_validar_nombre_usuario "$usuario" || continue

            # No debe estar ya registrado en .meta
            if _meta_existe "$usuario"; then
                aputs_error "El usuario '$usuario' ya esta registrado como FTP"
                continue
            fi

            # No debe existir ya en el sistema (evita colisión con cuentas locales)
            if id "$usuario" &>/dev/null; then
                aputs_error "El usuario del sistema '$usuario' ya existe"
                aputs_info "Use un nombre distinto o actualice el usuario existente (opcion 3)"
                continue
            fi

            break
        done

        # ── Contraseña ───────────────────────────────────────────────────────
        local pass=""
        _pedir_contrasena_confirmada pass
        stty echo 2>/dev/null

        # ── Grupo ────────────────────────────────────────────────────────────
        local grupo=""
        _pedir_grupo grupo || { creados=$(( creados + 1 )); continue; }

        # ── Crear usuario del sistema + directorios + ACLs ───────────────────
        _crear_usuario_sistema "$usuario" "$grupo"
        echo "${usuario}:${pass}" | chpasswd
        _meta_set "$usuario" "$grupo"

        aputs_success "Usuario '$usuario' creado en grupo '$grupo'"
        creados=$(( creados + 1 ))
    done

    # Reiniciar vsftpd para que lea la nueva lista de usuarios
    systemctl restart vsftpd 2>/dev/null \
        && aputs_success "vsftpd reiniciado — $total usuario(s) procesado(s)" \
        || aputs_warning "vsftpd no pudo reiniciarse — haga restart manualmente"
}

# R — Listar usuarios FTP registrados
_listar_usuarios_ftp() {
    draw_header "Usuarios FTP Registrados"

    if [[ ! -s "$VSFTPD_USERS_META" ]]; then
        aputs_info "No hay usuarios FTP registrados todavia"
        return 0
    fi

    echo ""
    printf "  %-22s %-16s %-28s %-16s\n" \
        "USUARIO FTP" "GRUPO" "DIRECTORIO CHROOT" "CARPETA PRIVADA"
    draw_line
    printf "  %-22s %-16s %-28s %-16s\n" \
        "───────────" "─────" "─────────────────" "───────────────"

    while IFS=: read -r u g; do
        [[ -z "$u" ]] && continue

        local user_root="${FTP_ROOT}/${FTP_USER_PREFIX}${u}"

        # Buscar carpeta privada dentro del chroot (excluye general y carpetas de grupo)
        local privada="(sin carpeta)"
        if [[ -d "$user_root" ]]; then
            local excluir=("general")
            # Agregar grupos de la lista como exclusiones
            if [[ -f "$VSFTPD_GROUPS_FILE" ]]; then
                while IFS= read -r gl; do
                    gl="${gl%%#*}"; gl="${gl//[[:space:]]/}"
                    [[ -n "$gl" ]] && excluir+=("$gl")
                done < "$VSFTPD_GROUPS_FILE"
            fi

            # Construir argumento ! -name para cada exclusión
            local find_args=()
            local ex
            for ex in "${excluir[@]}"; do
                find_args+=("!" "-name" "$ex")
            done

            local carpeta
            carpeta=$(find "$user_root" -maxdepth 1 -mindepth 1 -type d \
                "${find_args[@]}" 2>/dev/null | xargs -I{} basename {} | head -1)
            [[ -n "$carpeta" ]] && privada="$carpeta"
        fi

        printf "  %-22s %-16s %-28s %-16s\n" \
            "$u" "$g" "${FTP_USER_PREFIX}${u}" "$privada"
    done < "$VSFTPD_USERS_META"

    echo ""
    local total
    total=$(grep -c "^[^#]" "$VSFTPD_USERS_META" 2>/dev/null || echo 0)
    aputs_info "Total de usuarios registrados: $total"
}

# Cambiar el grupo FTP de un usuario existente
# Actualiza: grupo primario del sistema, ACLs, propietario carpeta privada,
# bind mounts y registro en .meta
_cambiar_grupo_usuario() {
    draw_header "Cambiar Grupo de Usuario FTP"

    # Mostrar usuarios disponibles para que el administrador pueda elegir
    _listar_usuarios_ftp

    local usuario
    agets "Nombre del usuario FTP" usuario

    if ! _meta_existe "$usuario"; then
        aputs_error "El usuario '$usuario' no esta registrado"
        return 1
    fi

    local grupo_actual
    grupo_actual=$(_meta_get_grupo "$usuario")

    draw_line
    aputs_info "Usuario FTP : $usuario"
    aputs_info "Grupo actual: $grupo_actual"
    draw_line

    # Pedir el nuevo grupo usando el selector interactivo
    local nuevo_grupo=""
    _pedir_grupo nuevo_grupo || return 1

    # Verificar que sea un grupo distinto al actual
    if [[ "$nuevo_grupo" == "$grupo_actual" ]]; then
        aputs_info "El grupo seleccionado es el mismo que el actual — sin cambios"
        return 0
    fi

    # ── Cambiar grupo primario en el sistema ──────────────────────────────────
    # usermod -g cambia el GID primario del usuario en /etc/passwd
    usermod -g "$nuevo_grupo" "$usuario" 2>/dev/null \
        && aputs_success "Grupo primario del sistema actualizado: '$grupo_actual' -> '$nuevo_grupo'" \
        || aputs_warning "No se pudo cambiar el grupo primario del sistema"

    # ── Ajustar ACLs ──────────────────────────────────────────────────────────
    # Quitar acceso ACL explícito del directorio del grupo anterior
    setfacl -x "u:${usuario}" "${FTP_ROOT}/${grupo_actual}" 2>/dev/null || true
    # Dar acceso ACL al directorio del nuevo grupo (rwx + default para nuevos archivos)
    setfacl -m  "u:${usuario}:rwx" "${FTP_ROOT}/${nuevo_grupo}" 2>/dev/null || true
    setfacl -d -m "u:${usuario}:rwx" "${FTP_ROOT}/${nuevo_grupo}" 2>/dev/null || true

    # ── Actualizar propietario de carpeta privada ─────────────────────────────
    # La carpeta privada del usuario vive dentro de su chroot: /srv/ftp/ftp_<usr>/<usr>
    # Su grupo debe coincidir con el nuevo grupo primario
    local privada="${FTP_ROOT}/${FTP_USER_PREFIX}${usuario}/${usuario}"
    if [[ -d "$privada" ]]; then
        chown "${usuario}:${nuevo_grupo}" "$privada" \
            && aputs_success "Propietario carpeta privada actualizado: ${usuario}:${nuevo_grupo}"
    fi

    # ── Actualizar .meta y remapear bind mounts ───────────────────────────────
    # .meta es la fuente de verdad del gestor: guarda la relación usuario:grupo
    _meta_set "$usuario" "$nuevo_grupo"
    # Los bind mounts exponen al usuario las carpetas de grupo dentro de su chroot.
    # Al cambiar de grupo hay que desmontar el antiguo y montar el nuevo.
    _actualizar_mounts_usuario "$usuario" "$nuevo_grupo"

    aputs_success "Grupo de '$usuario' cambiado: '$grupo_actual' -> '$nuevo_grupo'"

    # Reiniciar vsftpd para que aplique los cambios de permisos
    systemctl restart vsftpd 2>/dev/null \
        && aputs_success "vsftpd reiniciado — cambio de grupo completado" \
        || aputs_warning "vsftpd no pudo reiniciarse — haga restart manualmente"
}

# D — Eliminar usuario FTP
_eliminar_usuario_ftp() {
    draw_header "Eliminar Usuario FTP"

    local usuario
    agets "Nombre del usuario FTP a eliminar" usuario

    if ! _meta_existe "$usuario"; then
        aputs_error "El usuario '$usuario' no esta registrado"
        return 1
    fi

    local grupo
    grupo=$(_meta_get_grupo "$usuario")
    local user_dir="${FTP_ROOT}/${FTP_USER_PREFIX}${usuario}"

    draw_line
    aputs_info "Usuario FTP: $usuario"
    aputs_info "Grupo      : $grupo"
    aputs_info "Directorio : $user_dir"
    draw_line

    local confirmar
    agets "Confirma eliminar '$usuario'? [s/N]" confirmar
    if [[ ! "$confirmar" =~ ^[Ss]$ ]]; then
        aputs_info "Operacion cancelada"
        return 0
    fi

    local del_dir
    agets "Eliminar directorio del usuario ($user_dir)? [s/N]" del_dir

    # Quitar ACLs del usuario en los directorios compartidos
    setfacl -x "u:${usuario}" "$FTP_GENERAL"          2>/dev/null || true
    setfacl -x "u:${usuario}" "${FTP_ROOT}/${grupo}"  2>/dev/null || true

    # Desmontar y eliminar bind mounts antes de borrar el usuario del sistema
    _eliminar_mounts_usuario "$usuario"

    # Eliminar usuario del sistema Linux
    if id "$usuario" &>/dev/null; then
        userdel "$usuario" 2>/dev/null \
            && aputs_success "Usuario del sistema '$usuario' eliminado" \
            || aputs_warning "No se pudo eliminar el usuario del sistema"
    fi

    # Quitar del archivo .meta
    _meta_del "$usuario"

    # Eliminar directorio si el administrador lo confirma
    if [[ "$del_dir" =~ ^[Ss]$ ]]; then
        rm -rf "$user_dir"
        aputs_success "Directorio eliminado: $user_dir"
    else
        aputs_info "Directorio conservado: $user_dir"
    fi

    systemctl restart vsftpd 2>/dev/null \
        && aputs_success "vsftpd reiniciado — usuario '$usuario' eliminado" \
        || aputs_warning "vsftpd no pudo reiniciarse — haga restart manualmente"
}

# ─────────────────────────────────────────────────────────────────────────────
#   GRUPOS — CRUD
# ─────────────────────────────────────────────────────────────────────────────

# C — Crear un nuevo grupo FTP
_crear_grupo_ftp() {
    draw_header "Crear Grupo FTP"

    local nuevo_grupo
    agets "Nombre del nuevo grupo" nuevo_grupo

    # Validar formato
    if ! ftp_validar_nombre_grupo "$nuevo_grupo"; then
        return 1
    fi

    # No debe estar ya en la lista de grupos FTP
    if [[ -f "$VSFTPD_GROUPS_FILE" ]] && grep -qx "$nuevo_grupo" "$VSFTPD_GROUPS_FILE" 2>/dev/null; then
        aputs_warning "El grupo '$nuevo_grupo' ya existe en la lista FTP"
        return 1
    fi

    # Crear grupo en el sistema si no existe
    if ! getent group "$nuevo_grupo" &>/dev/null; then
        groupadd "$nuevo_grupo" \
            && aputs_success "Grupo del sistema creado: $nuevo_grupo" \
            || { aputs_error "groupadd fallo para '$nuevo_grupo'"; return 1; }
    else
        aputs_info "El grupo del sistema '$nuevo_grupo' ya existia"
    fi

    # Crear directorio del grupo en /srv/ftp/
    local dir="${FTP_ROOT}/${nuevo_grupo}"
    mkdir -p "$dir"
    chown root:"$nuevo_grupo" "$dir"
    chmod 2770 "$dir"
    chmod +t "$dir"
    aputs_success "Directorio creado: $dir (root:$nuevo_grupo 3770)"

    # Aplicar contexto SELinux al nuevo directorio
    if command -v restorecon &>/dev/null; then
        restorecon -R "$dir" &>/dev/null
    fi

    # Agregar a la lista de grupos FTP
    mkdir -p "$VSFTPD_DIR"
    echo "$nuevo_grupo" >> "$VSFTPD_GROUPS_FILE"
    aputs_success "Grupo '$nuevo_grupo' agregado a la lista FTP"
}

# R — Listar grupos FTP con sus miembros y permisos
_listar_grupos_ftp() {
    draw_header "Grupos FTP"

    if [[ ! -f "$VSFTPD_GROUPS_FILE" ]] || [[ ! -s "$VSFTPD_GROUPS_FILE" ]]; then
        aputs_info "No hay grupos FTP definidos"
        return 0
    fi

    while IFS= read -r grupo; do
        grupo="${grupo%%#*}"; grupo="${grupo//[[:space:]]/}"
        [[ -z "$grupo" ]] && continue

        local dir="${FTP_ROOT}/${grupo}"
        echo ""
        aputs_info "Grupo     : $grupo"

        if [[ -d "$dir" ]]; then
            aputs_info "Directorio: $dir"
            echo "  Permisos: $(stat -c '%A  %U:%G' "$dir" 2>/dev/null)"
        else
            aputs_warning "Directorio '$dir' no existe en disco"
        fi

        # Listar miembros del grupo desde .meta
        local miembros
        miembros=$(grep ":${grupo}$" "$VSFTPD_USERS_META" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
        echo "  Miembros: ${miembros:-(sin miembros)}"

        draw_line
    done < "$VSFTPD_GROUPS_FILE"

    # Mostrar también directorio general
    echo ""
    aputs_info "Directorio general: $FTP_GENERAL"
    if [[ -d "$FTP_GENERAL" ]]; then
        echo "  Permisos: $(stat -c '%A  %U:%G' "$FTP_GENERAL" 2>/dev/null)"
    else
        aputs_warning "$FTP_GENERAL no existe — ejecute la instalacion (opcion 2)"
    fi
    echo ""
}

# D — Eliminar un grupo FTP
#     Si tiene miembros, los reasigna a otro grupo antes de eliminar
_eliminar_grupo_ftp() {
    draw_header "Eliminar Grupo FTP"

    # Mostrar grupos disponibles antes de pedir nombre
    _listar_grupos_ftp

    local grupo_eliminar
    agets "Nombre del grupo a eliminar" grupo_eliminar

    # Validar que esté en la lista FTP
    if ! grep -qx "$grupo_eliminar" "$VSFTPD_GROUPS_FILE" 2>/dev/null; then
        aputs_error "El grupo '$grupo_eliminar' no esta en la lista FTP"
        return 1
    fi

    # Contar grupos restantes: debe quedar al menos uno
    local total_grupos
    total_grupos=$(grep -c "^[^#]" "$VSFTPD_GROUPS_FILE" 2>/dev/null || echo 0)
    if (( total_grupos <= 1 )); then
        aputs_error "No se puede eliminar el unico grupo FTP"
        aputs_info "Cree otro grupo antes de eliminar este"
        return 1
    fi

    # Verificar si hay usuarios en el grupo
    local miembros
    miembros=$(grep ":${grupo_eliminar}$" "$VSFTPD_USERS_META" 2>/dev/null | cut -d: -f1)

    if [[ -n "$miembros" ]]; then
        aputs_warning "El grupo '$grupo_eliminar' tiene miembros:"
        echo "$miembros" | while IFS= read -r u; do echo "  - $u"; done
        aputs_info "Deben reasignarse a otro grupo antes de eliminar"

        local grupo_destino=""
        _pedir_grupo grupo_destino

        # Reasignar cada miembro al grupo destino
        while IFS= read -r u; do
            [[ -z "$u" ]] && continue
            _meta_set "$u" "$grupo_destino"
            usermod -g "$grupo_destino" "$u" 2>/dev/null

            # Actualizar bind mounts del usuario
            _actualizar_mounts_usuario "$u" "$grupo_destino"

            # Actualizar ACLs
            setfacl -x "u:${u}" "${FTP_ROOT}/${grupo_eliminar}" 2>/dev/null || true
            setfacl -m "u:${u}:rwx" "${FTP_ROOT}/${grupo_destino}" 2>/dev/null || true
            setfacl -d -m "u:${u}:rwx" "${FTP_ROOT}/${grupo_destino}" 2>/dev/null || true

            aputs_success "'$u' reasignado a '$grupo_destino'"
        done <<< "$miembros"
    fi

    # Preguntar si eliminar el directorio del grupo
    local dir="${FTP_ROOT}/${grupo_eliminar}"
    if [[ -d "$dir" ]]; then
        local del_dir
        agets "Eliminar directorio $dir? [s/N]" del_dir
        if [[ "$del_dir" =~ ^[Ss]$ ]]; then
            rm -rf "$dir"
            aputs_success "Directorio eliminado: $dir"
        else
            aputs_info "Directorio conservado: $dir"
        fi
    fi

    # Eliminar grupo del sistema
    if getent group "$grupo_eliminar" &>/dev/null; then
        groupdel "$grupo_eliminar" 2>/dev/null \
            && aputs_success "Grupo del sistema '$grupo_eliminar' eliminado" \
            || aputs_warning "No se pudo eliminar el grupo del sistema"
    fi

    # Quitar de la lista de grupos FTP
    sed -i "/^${grupo_eliminar}$/d" "$VSFTPD_GROUPS_FILE"
    aputs_success "Grupo '$grupo_eliminar' eliminado de la lista FTP"
}

# Crea el usuario del sistema, su chroot, carpeta privada y bind mounts
# $1 = nombre de usuario
# $2 = grupo FTP primario
_crear_usuario_sistema() {
    local usuario="$1"
    local grupo="$2"
    local user_root="${FTP_ROOT}/${FTP_USER_PREFIX}${usuario}"

    # Crear usuario del sistema si no existe
    # shell=/sbin/nologin — no puede iniciar sesion interactiva
    # home=$user_root      — chroot raiz vsftpd
    # gid=$grupo           — grupo primario FTP
    # groups=$FTP_SSH_GROUP — bloqueo SSH via DenyGroups
    # password='!'          — bloqueado hasta que se asigne via chpasswd
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

    # Asegurar membresía correcta de grupos
    usermod -g "$grupo" "$usuario" 2>/dev/null
    usermod -aG "$FTP_SSH_GROUP" "$usuario" 2>/dev/null

    # Chroot raíz: root:root 755
    # vsftpd rechaza un chroot escribible por el usuario (política de seguridad)
    mkdir -p "$user_root"
    chown root:root "$user_root"
    chmod 755 "$user_root"

    # Carpeta privada del usuario: solo él puede acceder
    local privada="${user_root}/${usuario}"
    mkdir -p "$privada"
    chown "${usuario}:${grupo}" "$privada"
    chmod 700 "$privada"
    aputs_success "Carpeta privada: $privada (${usuario}:${grupo} 700)"

    # Bind mounts: en lugar de symlinks (vsftpd no sigue symlinks fuera del chroot)
    _crear_bind_mount "$FTP_GENERAL"         "${user_root}/general"
    _crear_bind_mount "${FTP_ROOT}/${grupo}" "${user_root}/${grupo}"

    # ACLs: dar acceso explícito al usuario en los directorios compartidos
    setfacl -m  "u:${usuario}:rwx" "$FTP_GENERAL"          2>/dev/null || true
    setfacl -m  "u:${usuario}:rwx" "${FTP_ROOT}/${grupo}"  2>/dev/null || true
    setfacl -d -m "u:${usuario}:rwx" "${FTP_ROOT}/${grupo}" 2>/dev/null || true

    # SELinux
    if command -v restorecon &>/dev/null; then
        restorecon -R "$user_root" &>/dev/null
    fi
}

# Renombra directorios cuando cambia el nombre de login de un usuario
# $1 = nombre viejo
# $2 = nombre nuevo
# $3 = grupo FTP del usuario
_renombrar_directorios_usuario() {
    local viejo="$1" nuevo="$2" grupo="$3"
    local old_root="${FTP_ROOT}/${FTP_USER_PREFIX}${viejo}"
    local new_root="${FTP_ROOT}/${FTP_USER_PREFIX}${nuevo}"

    [[ ! -d "$old_root" ]] && return 0

    # Desmontar bind mounts antes de mover el directorio
    _eliminar_mounts_usuario "$viejo"

    # Mover directorio raíz del chroot
    mv "$old_root" "$new_root"

    # Renombrar carpeta privada interna si coincide con el nombre viejo
    if [[ -d "${new_root}/${viejo}" ]]; then
        mv "${new_root}/${viejo}" "${new_root}/${nuevo}"
        chown "${nuevo}:${grupo}" "${new_root}/${nuevo}"
        chmod 700 "${new_root}/${nuevo}"
    fi

    # Recrear bind mounts con las rutas nuevas
    _crear_bind_mount "$FTP_GENERAL"        "${new_root}/general"
    _crear_bind_mount "${FTP_ROOT}/${grupo}" "${new_root}/${grupo}"

    if command -v restorecon &>/dev/null; then
        restorecon -R "$new_root" &>/dev/null
    fi
}

# Actualiza bind mounts cuando cambia el grupo de un usuario
# $1 = nombre de usuario
# $2 = nuevo grupo
_actualizar_mounts_usuario() {
    local usuario="$1"
    local nuevo_grupo="$2"
    local user_root="${FTP_ROOT}/${FTP_USER_PREFIX}${usuario}"

    # Desmontar bind mounts de grupos anteriores
    if [[ -f "$VSFTPD_GROUPS_FILE" ]]; then
        while IFS= read -r g; do
            g="${g%%#*}"; g="${g//[[:space:]]/}"
            [[ -z "$g" ]] && continue
            [[ -d "${user_root}/${g}" ]] && _eliminar_bind_mount "${user_root}/${g}"
        done < "$VSFTPD_GROUPS_FILE"
    fi

    # Montar general y el nuevo grupo
    _crear_bind_mount "$FTP_GENERAL"              "${user_root}/general"
    _crear_bind_mount "${FTP_ROOT}/${nuevo_grupo}" "${user_root}/${nuevo_grupo}"
}

# Desmonta y elimina todos los bind mounts de un usuario
# $1 = nombre de usuario
_eliminar_mounts_usuario() {
    local usuario="$1"
    local user_root="${FTP_ROOT}/${FTP_USER_PREFIX}${usuario}"

    # Desmontar general
    [[ -d "${user_root}/general" ]] && _eliminar_bind_mount "${user_root}/general"

    # Desmontar todos los directorios de grupo
    if [[ -f "$VSFTPD_GROUPS_FILE" ]]; then
        while IFS= read -r g; do
            g="${g%%#*}"; g="${g//[[:space:]]/}"
            [[ -z "$g" ]] && continue
            [[ -d "${user_root}/${g}" ]] && _eliminar_bind_mount "${user_root}/${g}"
        done < "$VSFTPD_GROUPS_FILE"
    fi
}