#!/bin/bash
#
# FunctionsFTP-A.sh
# Grupo A — Monitoreo general del servidor FTP
#
# Funciones de solo lectura: estado del servicio, puertos, conexiones,
# logs, listado de usuarios y grupos activos.
#
# Requiere: utils.sh, utilsFTP.sh, validatorsFTP.sh
#

# -----------------------------------------------------------------------------
# ftp_estado_servicio
# Muestra estado systemd, puertos en escucha, conexiones activas y log reciente.
# -----------------------------------------------------------------------------
ftp_estado_servicio() {
    draw_line
    aputs_info "Estado de vsftpd:"
    systemctl status vsftpd --no-pager -l | head -20

    draw_line
    aputs_info "Puertos en escucha:"
    ss -tlnp 2>/dev/null | grep -E ":(21|20|${FTP_PASV_MIN})\b" || \
        aputs_warning "No se detectaron puertos FTP en escucha"

    draw_line
    aputs_info "Conexiones activas:"
    ss -tnp 2>/dev/null | grep ':21' || aputs_info "Sin conexiones activas"

    draw_line
    aputs_info "Log reciente:"
    if [[ -f /var/log/vsftpd.log ]]; then
        tail -20 /var/log/vsftpd.log
    else
        journalctl -u vsftpd --no-pager -n 20 2>/dev/null
    fi
}

# -----------------------------------------------------------------------------
# ftp_listar_usuarios
# Tabla con todos los usuarios FTP registrados y su directorio/grupo.
# -----------------------------------------------------------------------------
ftp_listar_usuarios() {
    draw_line
    aputs_info "Usuarios FTP registrados:"

    if [[ ! -s "$VSFTPD_USERS_META" ]]; then
        aputs_warning "No hay usuarios registrados"
        return
    fi

    echo ""
    printf "  %-20s %-15s %-25s %-15s\n" "USUARIO" "GRUPO" "CHROOT" "CARPETA PRIVADA"
    printf "  %-20s %-15s %-25s %-15s\n" "-------" "-----" "------" "---------------"

    while IFS=: read -r u g; do
        [[ -z "$u" ]] && continue
        local user_root="${FTP_ROOT}/${FTP_USER_PREFIX}${u}"
        local privada=""
        if [[ -d "$user_root" ]]; then
            privada=$(find "$user_root" -maxdepth 1 -mindepth 1 -type d \
                ! -name "general" $(printf -- "! -name %s " "${FTP_GROUPS[@]}") \
                | xargs -I{} basename {} 2>/dev/null | head -1)
        fi
        printf "  %-20s %-15s %-25s %-15s\n" \
            "$u" "$g" "${FTP_USER_PREFIX}${u}" "${privada:-(sin carpeta)}"
    done < "$VSFTPD_USERS_META"
}

# -----------------------------------------------------------------------------
# ftp_listar_grupos
# Muestra cada grupo con su directorio, permisos y miembros activos.
# -----------------------------------------------------------------------------
ftp_listar_grupos() {
    draw_line
    aputs_info "Grupos FTP configurados:"

    if [[ ${#FTP_GROUPS[@]} -eq 0 ]]; then
        aputs_warning "No hay grupos configurados"
        return
    fi

    local grupo
    for grupo in "${FTP_GROUPS[@]}"; do
        local dir="${FTP_ROOT}/${grupo}"
        echo ""
        echo "  Grupo     : $grupo"
        echo "  Directorio: $dir"
        if [[ -d "$dir" ]]; then
            echo "  Permisos  : $(stat -c '%A  %U:%G' "$dir")"
        else
            echo "  Directorio: (no existe)"
        fi
        local miembros
        miembros=$(grep ":${grupo}$" "$VSFTPD_USERS_META" 2>/dev/null \
                   | cut -d: -f1 | tr '\n' ' ')
        echo "  Miembros  : ${miembros:-(sin miembros)}"
    done

    echo ""
    draw_line
    aputs_info "Directorio general: $FTP_GENERAL"
    if [[ -d "$FTP_GENERAL" ]]; then
        echo "  Permisos: $(stat -c '%A  %U:%G' "$FTP_GENERAL")"
    else
        aputs_warning "$FTP_GENERAL no existe aún"
    fi
}

# -----------------------------------------------------------------------------
# ftp_listar_puertos
# Muestra el estado de los puertos FTP relevantes.
# -----------------------------------------------------------------------------
ftp_listar_puertos() {
    aputs_info "Puertos FTP:"
    echo ""
    printf "  %-12s %-12s %-20s\n" "PUERTO" "ESTADO" "PROCESO"
    echo "  ────────────────────────────────────────"

    local puertos=(21 20 "$FTP_PASV_MIN")
    local p
    for p in "${puertos[@]}"; do
        if ftp_puerto_en_uso "$p"; then
            local proc
            proc=$(ss -tlnp 2>/dev/null | grep ":${p} " \
                   | grep -oP 'users:\(\("\K[^"]+' | head -1)
            printf "  ${GREEN}%-12s${NC} %-12s %-20s\n" "${p}/tcp" "EN USO" "${proc:-vsftpd}"
        else
            printf "  ${GRAY}%-12s${NC} %-12s\n" "${p}/tcp" "libre"
        fi
    done
    printf "  ${GRAY}%-12s${NC} %-12s\n" "${FTP_PASV_MIN}-${FTP_PASV_MAX}/tcp" "pasivo"
}

# -----------------------------------------------------------------------------
# ftp_menu_monitoreo
# Menú del Grupo A.
# -----------------------------------------------------------------------------
ftp_menu_monitoreo() {
    while true; do
        clear
        ftp_draw_header "Grupo A — Monitoreo del Servidor FTP"
        echo -e "  ${BLUE}1)${NC} Estado del servicio vsftpd"
        echo -e "  ${BLUE}2)${NC} Listar usuarios registrados"
        echo -e "  ${BLUE}3)${NC} Listar grupos configurados"
        echo -e "  ${BLUE}4)${NC} Puertos FTP activos"
        echo -e "  ${BLUE}0)${NC} Volver al menú principal"
        echo ""

        local op
        read -rp "  Opción: " op
        case "$op" in
            1) ftp_estado_servicio ; pause ;;
            2) ftp_listar_usuarios ; pause ;;
            3) ftp_listar_grupos   ; pause ;;
            4) ftp_listar_puertos  ; pause ;;
            0) return 0 ;;
            *) aputs_error "Opción inválida"; sleep 1 ;;
        esac
    done
}

export -f ftp_estado_servicio
export -f ftp_listar_usuarios
export -f ftp_listar_grupos
export -f ftp_listar_puertos
export -f ftp_menu_monitoreo