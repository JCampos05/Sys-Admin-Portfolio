#
#
# Módulo: Estructura de directorios FTP, bind mounts y visualización
#
# Requiere:
#   utils.sh       
#


# Submenú de directorios — se llama desde main_menu opción 4
gestionar_directorios() {
    while true; do
        clear
        draw_header "Estructura de Directorios FTP"
        echo ""
        aputs_info "  1) Ver arbol de directorios (solo carpetas)"
        aputs_info "  2) Ver arbol de directorios y ficheros"
        aputs_info "  3) Ver permisos y propietarios"
        aputs_info "  4) Reparar permisos"
        aputs_info "  5) Verificar bind mounts"
        aputs_info "  6) Volver al menu principal"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1) _ver_arbol_directorios; pause ;;
            2) _ver_arbol_completo; pause ;;
            3) _ver_permisos; pause ;;
            4) _reparar_permisos; pause ;;
            5) _verificar_bind_mounts; pause ;;
            6) return 0 ;;
            *)
                aputs_error "Opcion invalida. Seleccione del 1 al 6"
                sleep 2
                ;;
        esac
    done
}

# 
# ─── Helper visual compartido ────────────────────────────────────────────────
#
_imprimir_linea_arbol() {
    local prefijo="$1"
    local conector="$2"
    local ruta="$3"
    local mostrar_archivos="${4:-no}"
    local nota="${5:-}"

    local nombre perms owner
    nombre=$(basename "$ruta")
    perms=$(stat -c '%A' "$ruta" 2>/dev/null || echo "?????????")
    owner=$(stat -c '%U:%G' "$ruta" 2>/dev/null || echo "?:?")

    if [[ -d "$ruta" ]]; then
        # Directorios: azul y negrita
        # Distinguimos bind mounts con color cian y etiqueta
        if mountpoint -q "$ruta" 2>/dev/null; then
            printf "%s%s ${CYAN}%-24s${NC}  ${GRAY}%-11s  %-18s${NC}  %s\n" \
                "$prefijo" "$conector" "${nombre}/" "$perms" "$owner" \
                "${nota:-${CYAN}[bind mount]${NC}}"
        else
            printf "%s%s ${BLUE}%-24s${NC}  ${GRAY}%-11s  %-18s${NC}  %s\n" \
                "$prefijo" "$conector" "${nombre}/" "$perms" "$owner" \
                "${nota:-}"
        fi
    else
        # Ficheros: blanco, con tamaño si se pidió
        local size_str=""
        if [[ "$mostrar_archivos" == "si" ]]; then
            local bytes
            bytes=$(stat -c '%s' "$ruta" 2>/dev/null || echo 0)
            if   (( bytes >= 1048576 )); then
                size_str=$(awk "BEGIN{printf \"%.1fM\", $bytes/1048576}")
            elif (( bytes >= 1024 )); then
                size_str=$(awk "BEGIN{printf \"%.1fK\", $bytes/1024}")
            else
                size_str="${bytes}B"
            fi
            size_str="  ${YELLOW}[${size_str}]${NC}"
        fi
        printf "%s%s %-24s  ${GRAY}%-11s  %-18s${NC}%b\n" \
            "$prefijo" "$conector" "$nombre" "$perms" "$owner" "$size_str"
    fi
}

_recorrer_arbol() {
    local raiz="$1"
    local prefijo="$2"
    local modo="${3:-no}"   # "no" = solo dirs | "si" = dirs + ficheros

    # Recoger entradas (dirs primero, luego ficheros si aplica)
    local entradas=()
    while IFS= read -r e; do
        entradas+=("$e")
    done < <(
        # Directorios primero, ordenados
        find "$raiz" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort
        # Ficheros después, solo si el modo los incluye
        if [[ "$modo" == "si" ]]; then
            find "$raiz" -maxdepth 1 -mindepth 1 -type f 2>/dev/null | sort
        fi
    )

    local total="${#entradas[@]}"
    local i
    for i in "${!entradas[@]}"; do
        local ruta="${entradas[$i]}"
        local conector nuevo_prefijo

        if (( i == total - 1 )); then
            conector="└──"
            nuevo_prefijo="${prefijo}    "
        else
            conector="├──"
            nuevo_prefijo="${prefijo}│   "
        fi

        _imprimir_linea_arbol "$prefijo" "$conector" "$ruta" "$modo"

        # Entrar en subdirectorios (no en bind mounts para evitar bucles)
        if [[ -d "$ruta" ]] && ! mountpoint -q "$ruta" 2>/dev/null; then
            _recorrer_arbol "$ruta" "$nuevo_prefijo" "$modo"
        fi
    done
}

# ── Cabecera de columnas ──────────────────────────────────────────────────────
_cabecera_arbol() {
    printf "  ${GRAY}%-6s %-24s  %-11s  %-18s  %s${NC}\n" \
        "" "NOMBRE" "PERMISOS" "PROPIETARIO:GRUPO" "NOTA"
    echo "  ──────────────────────────────────────────────────────────────────"
}

# ─────────────────────────────────────────────────────────────────────────────

# Muestra el árbol de SOLO directorios bajo /srv/ftp/
# Vista rápida de la estructura sin ruido de ficheros
_ver_arbol_directorios() {
    draw_header "Arbol de Directorios — $FTP_ROOT"

    if [[ ! -d "$FTP_ROOT" ]]; then
        aputs_error "$FTP_ROOT no existe — ejecute la instalacion (opcion 2)"
        return 1
    fi

    echo ""
    _cabecera_arbol

    # Raíz
    local perms_root owner_root
    perms_root=$(stat -c '%A' "$FTP_ROOT" 2>/dev/null)
    owner_root=$(stat -c '%U:%G' "$FTP_ROOT" 2>/dev/null)
    printf "  ${BLUE}%-30s${NC}  ${GRAY}%-11s  %-18s${NC}\n" \
        "${FTP_ROOT}/" "$perms_root" "$owner_root"

    # Árbol recursivo de solo directorios
    _recorrer_arbol "$FTP_ROOT" "  " "no"

    echo ""
    draw_line

    # Resumen
    local total_dirs total_usuarios
    total_dirs=$(find "$FTP_ROOT" -type d 2>/dev/null | wc -l)
    total_usuarios=$(grep -c "^[^#]" "$VSFTPD_USERS_META" 2>/dev/null || echo 0)
    aputs_info "Total directorios: $total_dirs  |  Usuarios FTP registrados: $total_usuarios"

    # Leyenda de colores
    echo ""
    printf "  ${BLUE}■${NC} Directorio normal    ${CYAN}■${NC} Bind mount (directorio compartido montado)\n"
}

# Muestra el árbol completo (directorios + ficheros) bajo /srv/ftp/
# Vista de auditoría: qué archivos existen, quién los subió y cuánto ocupan
_ver_arbol_completo() {
    draw_header "Arbol Completo — $FTP_ROOT"

    if [[ ! -d "$FTP_ROOT" ]]; then
        aputs_error "$FTP_ROOT no existe — ejecute la instalacion (opcion 2)"
        return 1
    fi

    echo ""
    _cabecera_arbol

    # Raíz
    local perms_root owner_root
    perms_root=$(stat -c '%A' "$FTP_ROOT" 2>/dev/null)
    owner_root=$(stat -c '%U:%G' "$FTP_ROOT" 2>/dev/null)
    printf "  ${BLUE}%-30s${NC}  ${GRAY}%-11s  %-18s${NC}\n" \
        "${FTP_ROOT}/" "$perms_root" "$owner_root"

    # Árbol recursivo con ficheros incluidos
    _recorrer_arbol "$FTP_ROOT" "  " "si"

    echo ""
    draw_line

    # Resumen de estadísticas
    local total_dirs total_files total_size
    total_dirs=$(find "$FTP_ROOT" -type d 2>/dev/null | wc -l)
    total_files=$(find "$FTP_ROOT" -type f 2>/dev/null | wc -l)
    total_size=$(du -sh "$FTP_ROOT" 2>/dev/null | cut -f1)
    aputs_info "Directorios: $total_dirs  |  Ficheros: $total_files  |  Tamaño total: ${total_size:-N/A}"

    # Leyenda de colores
    echo ""
    printf "  ${BLUE}■${NC} Directorio    ${CYAN}■${NC} Bind mount    ${YELLOW}■${NC} Tamaño fichero\n"
}

# Muestra permisos y propietarios de cada directorio relevante
# con el significado de cada permiso explicado
_ver_permisos() {
    draw_header "Permisos y Propietarios — $FTP_ROOT"

    if [[ ! -d "$FTP_ROOT" ]]; then
        aputs_error "$FTP_ROOT no existe"
        return 1
    fi

    echo ""
    # Cabecera de tabla
    printf "  %-42s %-12s %-14s %s\n" "DIRECTORIO" "PERMISOS" "PROPIETARIO" "NOTA"
    draw_line
    printf "  %-42s %-12s %-14s %s\n" "──────────" "────────" "───────────" "────"

    # Función local de impresión de línea de permisos
    _fila_permisos() {
        local ruta="$1" nota="$2"
        [[ ! -e "$ruta" ]] && printf "  %-42s %-12s %-14s %s\n" "$ruta" "---" "no existe" "$nota" && return
        local perms owner
        perms=$(stat -c '%A' "$ruta" 2>/dev/null)
        owner=$(stat -c '%U:%G' "$ruta" 2>/dev/null)
        printf "  %-42s %-12s %-14s %s\n" "$ruta" "$perms" "$owner" "$nota"
    }

    # Raíz del servidor FTP
    _fila_permisos "$FTP_ROOT" "raiz FTP (755 obligatorio)"

    # Directorio general
    _fila_permisos "$FTP_GENERAL" "compartido todos (1775)"

    # Directorios de grupos
    if [[ -f "$VSFTPD_GROUPS_FILE" ]]; then
        while IFS= read -r g; do
            g="${g%%#*}"; g="${g//[[:space:]]/}"
            [[ -z "$g" ]] && continue
            _fila_permisos "${FTP_ROOT}/${g}" "grupo $g (3770)"
        done < "$VSFTPD_GROUPS_FILE"
    fi

    echo ""
    draw_line
    aputs_info "Chroots de usuarios:"
    draw_line

    # Chroots individuales de cada usuario
    if [[ -s "$VSFTPD_USERS_META" ]]; then
        while IFS=: read -r u g; do
            [[ -z "$u" ]] && continue
            local user_root="${FTP_ROOT}/${FTP_USER_PREFIX}${u}"
            _fila_permisos "$user_root"          "chroot raiz $u (755 obligatorio)"
            _fila_permisos "${user_root}/${u}"   "carpeta privada (700)"
            _fila_permisos "${user_root}/general" "bind mount -> general"
            _fila_permisos "${user_root}/${g}"   "bind mount -> $g"
            echo ""
        done < "$VSFTPD_USERS_META"
    else
        aputs_info "No hay usuarios FTP registrados"
    fi

    # Leyenda de permisos especiales
    echo ""
    draw_line
    aputs_info "Leyenda de bits especiales:"
    echo "  1xxx  = sticky bit (+t): solo el propietario puede borrar sus archivos"
    echo "  2xxx  = setgid  (+s): archivos nuevos heredan el grupo del directorio"
    echo "  3xxx  = sticky + setgid combinados"
    echo "  755   = rwxr-xr-x  (raiz chroot — vsftpd exige no escribible por usuario)"
    echo "  700   = rwx------  (carpeta privada — solo el usuario)"
    echo ""
}

# Repara permisos incorrectos en toda la estructura FTP
# Útil tras migraciones, backups o modificaciones manuales accidentales
_reparar_permisos() {
    draw_header "Reparar Permisos"

    if [[ ! -d "$FTP_ROOT" ]]; then
        aputs_error "$FTP_ROOT no existe — ejecute la instalacion (opcion 2)"
        return 1
    fi

    # Raíz FTP
    chown root:root "$FTP_ROOT"; chmod 755 "$FTP_ROOT"
    aputs_success "$FTP_ROOT → root:root 755"

    # Directorio general
    if [[ -d "$FTP_GENERAL" ]]; then
        chown root:ftp "$FTP_GENERAL"
        chmod 775 "$FTP_GENERAL"
        chmod +t "$FTP_GENERAL"
        aputs_success "$FTP_GENERAL → root:ftp 1775"

        # Restaurar ACLs en general para todos los usuarios registrados
        if [[ -s "$VSFTPD_USERS_META" ]]; then
            while IFS=: read -r u _; do
                [[ -z "$u" ]] && continue
                id "$u" &>/dev/null && setfacl -m "u:${u}:rwx" "$FTP_GENERAL" 2>/dev/null || true
            done < "$VSFTPD_USERS_META"
            aputs_success "ACLs de usuarios restauradas en $FTP_GENERAL"
        fi
    fi

    # Directorios de grupos
    if [[ -f "$VSFTPD_GROUPS_FILE" ]]; then
        while IFS= read -r g; do
            g="${g%%#*}"; g="${g//[[:space:]]/}"
            [[ -z "$g" ]] && continue
            local dir="${FTP_ROOT}/${g}"
            if [[ -d "$dir" ]]; then
                chown root:"$g" "$dir"; chmod 2770 "$dir"; chmod +t "$dir"
                aputs_success "$dir → root:$g 3770"
            fi
        done < "$VSFTPD_GROUPS_FILE"
    fi

    # Chroots de usuarios
    if [[ -s "$VSFTPD_USERS_META" ]]; then
        while IFS=: read -r u g; do
            [[ -z "$u" ]] && continue
            local user_root="${FTP_ROOT}/${FTP_USER_PREFIX}${u}"
            local privada="${user_root}/${u}"

            # Chroot raíz: root:root 755
            if [[ -d "$user_root" ]]; then
                chown root:root "$user_root"; chmod 755 "$user_root"
                aputs_success "$user_root → root:root 755"
            fi

            # Carpeta privada: usuario:grupo 700
            if [[ -d "$privada" ]]; then
                chown "${u}:${g}" "$privada"; chmod 700 "$privada"
                aputs_success "$privada → ${u}:${g} 700"
            fi

            # Garantizar bloqueo SSH
            id "$u" &>/dev/null && usermod -aG "$FTP_SSH_GROUP" "$u" 2>/dev/null || true

            # Reactivar bind mounts si no están montados
            local unit_gen unit_grp
            unit_gen=$(_path_to_unit "${user_root}/general")
            unit_grp=$(_path_to_unit "${user_root}/${g}")

            if ! systemctl is-active --quiet "$unit_gen" 2>/dev/null; then
                systemctl start "$unit_gen" &>/dev/null \
                    || _crear_bind_mount "$FTP_GENERAL" "${user_root}/general"
            fi

            if ! systemctl is-active --quiet "$unit_grp" 2>/dev/null; then
                systemctl start "$unit_grp" &>/dev/null \
                    || _crear_bind_mount "${FTP_ROOT}/${g}" "${user_root}/${g}"
            fi

        done < "$VSFTPD_USERS_META"
    fi

    # SELinux: restaurar contextos
    if command -v restorecon &>/dev/null; then
        restorecon -Rv "$FTP_ROOT" &>/dev/null
        aputs_success "Contexto SELinux restaurado en $FTP_ROOT"
    fi

    aputs_success "Reparacion de permisos completada"
}

# Verifica el estado de todos los bind mounts systemd
_verificar_bind_mounts() {
    draw_header "Estado de Bind Mounts"

    if [[ ! -s "$VSFTPD_USERS_META" ]]; then
        aputs_info "No hay usuarios registrados — no hay bind mounts"
        return 0
    fi

    echo ""
    printf "  %-50s %s\n" "UNIDAD SYSTEMD (.mount)" "ESTADO"
    draw_line

    while IFS=: read -r u g; do
        [[ -z "$u" ]] && continue
        local user_root="${FTP_ROOT}/${FTP_USER_PREFIX}${u}"

        # Verificar mount de general
        local unit_gen
        unit_gen=$(_path_to_unit "${user_root}/general")
        local estado_gen
        estado_gen=$(systemctl is-active "$unit_gen" 2>/dev/null || echo "inactivo")
        printf "  %-50s " "$unit_gen"
        if [[ "$estado_gen" == "active" ]]; then
            echo -e "${GREEN}activo${NC}"
        else
            echo -e "${RED}$estado_gen${NC}"
        fi

        # Verificar mount del grupo
        local unit_grp
        unit_grp=$(_path_to_unit "${user_root}/${g}")
        local estado_grp
        estado_grp=$(systemctl is-active "$unit_grp" 2>/dev/null || echo "inactivo")
        printf "  %-50s " "$unit_grp"
        if [[ "$estado_grp" == "active" ]]; then
            echo -e "${GREEN}activo${NC}"
        else
            echo -e "${RED}$estado_grp${NC}"
        fi

    done < "$VSFTPD_USERS_META"

    echo ""
    aputs_info "Use 'Reparar permisos' (opcion 4) para reactivar mounts caidos"
}

# Convierte una ruta absoluta en nombre de unidad systemd .mount
# El nombre debe coincidir exactamente con la ruta — systemd lo exige
# Ej: /srv/ftp/ftp_juan/general  →  srv-ftp-ftp_juan-general.mount
# Uso: _path_to_unit "/srv/ftp/ftp_juan/general"
_path_to_unit() {
    local path="${1#/}"            # quitar la / inicial
    echo "${path//\//-}.mount"     # sustituir cada / por -
}

# Crea y activa un bind mount persistente via systemd
# $1 = origen  (ej: /srv/ftp/general)
# $2 = destino (ej: /srv/ftp/ftp_juan/general)
_crear_bind_mount() {
    local origen="$1"
    local destino="$2"

    local unit_name
    unit_name=$(_path_to_unit "$destino")
    local unit_file="/etc/systemd/system/${unit_name}"

    # Crear punto de montaje si no existe
    mkdir -p "$destino"

    # Escribir la unidad systemd .mount
    # Type=none + Options=bind es la forma correcta de bind mount en systemd
    cat > "$unit_file" <<UNIT
[Unit]
Description=FTP bind mount ${origen} -> ${destino}
After=local-fs.target

[Mount]
What=${origen}
Where=${destino}
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
UNIT

    # Recargar daemon y activar la unidad
    systemctl daemon-reload
    systemctl enable --now "$unit_name" &>/dev/null \
        && aputs_success "Bind mount activo: $destino" \
        || aputs_error "Error al activar bind mount: $destino"
}

# Desmonta y elimina la unidad systemd de un bind mount
# $1 = destino del bind mount (ej: /srv/ftp/ftp_juan/general)
_eliminar_bind_mount() {
    local destino="$1"

    local unit_name
    unit_name=$(_path_to_unit "$destino")
    local unit_file="/etc/systemd/system/${unit_name}"

    # Desactivar y parar la unidad
    systemctl disable --now "$unit_name" &>/dev/null || true

    # Desmontar forzosamente si aún está montado
    umount "$destino" 2>/dev/null || true

    # Eliminar archivo de unidad
    rm -f "$unit_file"

    # Recargar daemon para que systemd olvide la unidad
    systemctl daemon-reload

    # Eliminar el punto de montaje vacío
    rmdir "$destino" 2>/dev/null || true

    aputs_success "Bind mount eliminado: $destino"
}
