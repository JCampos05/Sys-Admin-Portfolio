#!/bin/bash
#
# FunctionsFTP-D.sh
# Grupo D — Configuración, firewall y mantenimiento/reparación
#
# Requiere: utils.sh, utilsFTP.sh, validatorsFTP.sh, FunctionsFTP-B.sh
#

# -----------------------------------------------------------------------------
# Configuración de vsftpd.conf
# -----------------------------------------------------------------------------

ftp_ver_configuracion() {
    draw_line
    aputs_info "Configuración activa: $VSFTPD_CONF"
    draw_line
    if [[ -f "$VSFTPD_CONF" ]]; then
        grep -v '^\s*#' "$VSFTPD_CONF" | grep -v '^\s*$'
    else
        aputs_warning "$VSFTPD_CONF no existe — instala vsftpd primero"
    fi
}

ftp_editar_configuracion() {
    [[ ! -f "$VSFTPD_CONF" ]] && aputs_warning "Instala vsftpd primero" && return
    ftp_crear_backup "$VSFTPD_CONF"
    aputs_info "Backup guardado. Enter = sin cambios."
    draw_line

    # Banner
    local banner_actual
    banner_actual=$(grep -E "^ftpd_banner=" "$VSFTPD_CONF" | cut -d= -f2-)
    echo -ne "${CYAN}[INPUT]${NC} Banner [$banner_actual]: "; read -r nuevo_banner
    [[ -n "$nuevo_banner" ]] && _ftp_set_param "ftpd_banner" "${nuevo_banner//=/-}"

    # Puertos pasivos
    local pmin pmax
    pmin=$(grep -E "^pasv_min_port=" "$VSFTPD_CONF" | cut -d= -f2)
    pmax=$(grep -E "^pasv_max_port=" "$VSFTPD_CONF" | cut -d= -f2)
    echo -ne "${CYAN}[INPUT]${NC} Puerto pasivo mínimo [$pmin]: "; read -r nmin
    echo -ne "${CYAN}[INPUT]${NC} Puerto pasivo máximo [$pmax]: "; read -r nmax
    local fmin="${nmin:-$pmin}" fmax="${nmax:-$pmax}"
    if [[ -n "$nmin" || -n "$nmax" ]]; then
        if [[ "$fmin" =~ ^[0-9]+$ && "$fmax" =~ ^[0-9]+$ ]] && \
           (( fmin >= 1024 && fmax <= 65535 && fmin < fmax )); then
            [[ -n "$nmin" ]] && _ftp_set_param "pasv_min_port" "$nmin"
            [[ -n "$nmax" ]] && _ftp_set_param "pasv_max_port" "$nmax"
        else
            aputs_error "Rango inválido o mínimo >= máximo — sin cambios"
        fi
    fi

    # Acceso anónimo
    local anon_actual
    anon_actual=$(grep -E "^anonymous_enable=" "$VSFTPD_CONF" | cut -d= -f2)
    echo -ne "${CYAN}[INPUT]${NC} Acceso anónimo YES/NO [$anon_actual]: "; read -r nuevo_anon
    if [[ -n "$nuevo_anon" ]]; then
        case "${nuevo_anon^^}" in
            YES|Y) _ftp_set_param "anonymous_enable" "YES" ;;
            NO|N)  _ftp_set_param "anonymous_enable" "NO"  ;;
            *)     aputs_error "Usa YES o NO" ;;
        esac
    fi

    echo -ne "${CYAN}[INPUT]${NC} ¿Reiniciar vsftpd? [S/n]: "; read -r r
    [[ ! "$r" =~ ^[Nn]$ ]] && ftp_reiniciar
}

# -----------------------------------------------------------------------------
# Firewall
# -----------------------------------------------------------------------------

ftp_gestionar_firewall() {
    command -v firewall-cmd &>/dev/null || { aputs_warning "firewalld no disponible"; return; }

    local pmin pmax
    pmin=$(grep -E "^pasv_min_port=" "$VSFTPD_CONF" 2>/dev/null | cut -d= -f2); pmin="${pmin:-$FTP_PASV_MIN}"
    pmax=$(grep -E "^pasv_max_port=" "$VSFTPD_CONF" 2>/dev/null | cut -d= -f2); pmax="${pmax:-$FTP_PASV_MAX}"

    draw_line
    aputs_info "Firewall — Puertos FTP"
    aputs_info "Puertos abiertos actualmente:"
    firewall-cmd --list-ports   2>/dev/null
    firewall-cmd --list-services 2>/dev/null

    draw_line
    echo "  1) Abrir puertos FTP (21 + ${pmin}-${pmax})"
    echo "  2) Cerrar puertos FTP"
    echo "  3) Ver reglas completas"
    echo "  0) Volver"
    draw_line
    echo -ne "${CYAN}[INPUT]${NC} Opción: "; read -r op

    case "$op" in
        1) firewall-cmd --permanent --add-service=ftp &>/dev/null
           firewall-cmd --permanent --add-port="${pmin}-${pmax}/tcp" &>/dev/null
           firewall-cmd --reload &>/dev/null && aputs_success "Puertos abiertos" ;;
        2) firewall-cmd --permanent --remove-service=ftp &>/dev/null
           firewall-cmd --permanent --remove-port="${pmin}-${pmax}/tcp" &>/dev/null
           firewall-cmd --reload &>/dev/null && aputs_success "Puertos cerrados" ;;
        3) firewall-cmd --list-all ;;
        0) return ;;
        *) aputs_warning "Opción inválida" ;;
    esac
}

# -----------------------------------------------------------------------------
# Mantenimiento y reparación
# -----------------------------------------------------------------------------

ftp_reparar_permisos() {
    draw_line
    aputs_info "Reparando permisos..."

    chown root:root "$FTP_ROOT"; chmod 755 "$FTP_ROOT"

    if [[ -d "$FTP_GENERAL" ]]; then
        chown root:ftp "$FTP_GENERAL"; chmod 775 "$FTP_GENERAL"; chmod +t "$FTP_GENERAL"
        aputs_success "$FTP_GENERAL reparado"
        while IFS=: read -r u _; do
            [[ -z "$u" ]] && continue
            id "$u" &>/dev/null && setfacl -m "u:${u}:rwx" "$FTP_GENERAL" 2>/dev/null || true
        done < "$VSFTPD_USERS_META" 2>/dev/null
    fi

    local grupo
    for grupo in "${FTP_GROUPS[@]}"; do
        local d="${FTP_ROOT}/$grupo"
        if [[ -d "$d" ]]; then
            chown root:"$grupo" "$d"; chmod 2770 "$d"; chmod +t "$d"
            aputs_success "$d reparado"
        fi
    done

    while IFS=: read -r u g; do
        [[ -z "$u" ]] && continue
        local user_root="${FTP_ROOT}/${FTP_USER_PREFIX}${u}"
        local privada="$user_root/$u"

        [[ -d "$user_root" ]] && { chown root:root "$user_root"; chmod 755 "$user_root"; }
        if [[ -d "$privada" ]]; then
            chown "$u":"$g" "$privada"; chmod 700 "$privada"
            aputs_success "$privada reparada"
        fi

        id "$u" &>/dev/null && usermod -aG "$FTP_SSH_GROUP" "$u" 2>/dev/null || true

        local unit_gen unit_grp
        unit_gen=$(_ftp_path_to_unit "$user_root/general")
        unit_grp=$(_ftp_path_to_unit "$user_root/$g")
        systemctl is-active --quiet "$unit_gen" || \
            systemctl start "$unit_gen" &>/dev/null || \
            _ftp_crear_bind_mount "$FTP_GENERAL"     "$user_root/general"
        systemctl is-active --quiet "$unit_grp" || \
            systemctl start "$unit_grp" &>/dev/null || \
            _ftp_crear_bind_mount "${FTP_ROOT}/$g"   "$user_root/$g"

    done < "$VSFTPD_USERS_META" 2>/dev/null

    aputs_info "Propagando ACLs en carpetas de grupo..."
    while IFS=: read -r u g; do
        [[ -z "$u" ]] && continue
        local grupo_dir="${FTP_ROOT}/$g"
        [[ ! -d "$grupo_dir" ]] && continue
        while IFS=: read -r u2 g2; do
            [[ -z "$u2" || "$g2" != "$g" ]] && continue
            find "$grupo_dir" -type d | while read -r dir; do
                setfacl -m  "u:${u2}:rwx" "$dir" 2>/dev/null || true
                setfacl -d -m "u:${u2}:rwx" "$dir" 2>/dev/null || true
            done
        done < "$VSFTPD_USERS_META" 2>/dev/null
    done < "$VSFTPD_USERS_META" 2>/dev/null
    aputs_success "ACLs de grupos propagadas"

    aputs_info "Propagando ACLs en $FTP_GENERAL..."
    find "$FTP_GENERAL" -type d | while read -r dir; do
        setfacl -m  other::rwx "$dir" 2>/dev/null || true
        setfacl -d -m other::rwx "$dir" 2>/dev/null || true
    done
    find "$FTP_GENERAL" -type f | while read -r file; do
        setfacl -m other::rwx "$file" 2>/dev/null || true
    done
    aputs_success "ACLs propagadas en $FTP_GENERAL"

    if command -v restorecon &>/dev/null; then
        aputs_info "Reparando contexto SELinux..."
        restorecon -Rv "$FTP_ROOT" &>/dev/null
        aputs_success "Contexto SELinux reparado"
    fi

    aputs_success "Reparación completada"
}

ftp_reparar_grupos_usuarios() {
    draw_line
    aputs_info "Verificando grupos primarios de usuarios FTP..."
    while IFS=: read -r u g; do
        [[ -z "$u" ]] && continue
        if id "$u" &>/dev/null; then
            local gid_actual; gid_actual=$(id -gn "$u")
            if [[ "$gid_actual" != "$g" ]]; then
                usermod -g "$g" "$u" && aputs_success "$u: grupo corregido ($gid_actual → $g)"
            else
                aputs_info "$u: grupo OK ($g)"
            fi
            usermod -aG "$FTP_SSH_GROUP" "$u" 2>/dev/null || true
        else
            aputs_warning "Usuario del sistema '$u' no existe"
        fi
    done < "$VSFTPD_USERS_META" 2>/dev/null
    aputs_success "Revisión completada"
}

ftp_gestionar_permisos_dirs() {
    draw_line
    aputs_info "Permisos actuales:"
    echo ""
    local path
    for path in "$FTP_ROOT" "$FTP_GENERAL"; do
        [[ -d "$path" ]] && printf "  %-45s %s\n" "$path" "$(stat -c '%A %U:%G' "$path")"
    done
    local g
    for g in "${FTP_GROUPS[@]}"; do
        local d="${FTP_ROOT}/$g"
        [[ -d "$d" ]] \
            && printf "  %-45s %s\n" "$d" "$(stat -c '%A %U:%G' "$d")" \
            || printf "  %-45s %s\n" "$d" "(no existe)"
    done
    draw_line
    ftp_reparar_permisos
}

# -----------------------------------------------------------------------------
# ftp_menu_extras
# Menú del Grupo D.
# -----------------------------------------------------------------------------
ftp_menu_extras() {
    while true; do
        clear
        ftp_draw_header "Grupo D — Configuración y Mantenimiento"
        echo -e "  ${CYAN}— Configuración —${NC}"
        echo -e "  ${BLUE}1)${NC} Ver configuración activa (vsftpd.conf)"
        echo -e "  ${BLUE}2)${NC} Editar configuración (banner / puertos pasivos / anónimo)"
        echo -e "  ${BLUE}3)${NC} Gestionar firewall"
        echo ""
        echo -e "  ${CYAN}— Mantenimiento —${NC}"
        echo -e "  ${BLUE}4)${NC} Reparar permisos de toda la estructura FTP"
        echo -e "  ${BLUE}5)${NC} Reparar grupos primarios de usuarios"
        echo -e "  ${BLUE}6)${NC} Ver y reparar permisos de directorios"
        echo -e "  ${BLUE}0)${NC} Volver al menú principal"
        echo ""

        local op
        read -rp "  Opción: " op
        case "$op" in
            1) ftp_ver_configuracion        ; pause ;;
            2) ftp_editar_configuracion     ; pause ;;
            3) ftp_gestionar_firewall       ; pause ;;
            4) ftp_reparar_permisos         ; pause ;;
            5) ftp_reparar_grupos_usuarios  ; pause ;;
            6) ftp_gestionar_permisos_dirs  ; pause ;;
            0) return 0 ;;
            *) aputs_error "Opción inválida"; sleep 1 ;;
        esac
    done
}

export -f ftp_ver_configuracion
export -f ftp_editar_configuracion
export -f ftp_gestionar_firewall
export -f ftp_reparar_permisos
export -f ftp_reparar_grupos_usuarios
export -f ftp_gestionar_permisos_dirs
export -f ftp_menu_extras