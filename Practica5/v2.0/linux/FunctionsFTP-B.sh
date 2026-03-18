#!/bin/bash
#
# FunctionsFTP-B.sh
# Grupo B — Instalación, desinstalación y control del servicio vsftpd
#
# Requiere: utils.sh, utilsFTP.sh, validatorsFTP.sh
#

# -----------------------------------------------------------------------------
# _ftp_pedir_grupos_iniciales
# Solicita los grupos FTP en el primer arranque. Si ya existen en disco
# los carga y retorna sin pedir nada.
# -----------------------------------------------------------------------------
_ftp_pedir_grupos_iniciales() {
    if [[ -s "$VSFTPD_GROUPS_FILE" ]]; then
        _ftp_cargar_grupos
        aputs_info "Grupos existentes: ${FTP_GROUPS[*]}"
        return 0
    fi

    draw_line
    aputs_info "Define los grupos FTP (al menos uno). Línea vacía para terminar."
    draw_line

    FTP_GROUPS=()
    while true; do
        echo -ne "${CYAN}[INPUT]${NC} Nombre del grupo (Enter para terminar): "
        read -r grupo
        if [[ -z "$grupo" ]]; then
            [[ ${#FTP_GROUPS[@]} -eq 0 ]] && aputs_error "Al menos un grupo requerido" && continue
            break
        fi
        if ! ftp_validar_nombre_grupo "$grupo"; then continue; fi
        local dup=false
        local g
        for g in "${FTP_GROUPS[@]}"; do [[ "$g" == "$grupo" ]] && dup=true && break; done
        $dup && aputs_warning "'$grupo' ya está en la lista" && continue
        FTP_GROUPS+=("$grupo")
        aputs_success "Grupo '$grupo' agregado"
    done

    _ftp_guardar_grupos
    aputs_success "Grupos guardados: ${FTP_GROUPS[*]}"
}

# -----------------------------------------------------------------------------
# _ftp_crear_grupos_sistema
# Crea en el sistema los grupos de FTP_GROUPS que no existan aún.
# -----------------------------------------------------------------------------
_ftp_crear_grupos_sistema() {
    local grupo
    for grupo in "${FTP_GROUPS[@]}"; do
        if ! getent group "$grupo" &>/dev/null; then
            groupadd --system "$grupo"
            aputs_success "Grupo del sistema '$grupo' creado"
        else
            aputs_info "Grupo '$grupo' ya existe"
        fi
    done
}

# -----------------------------------------------------------------------------
# _ftp_crear_grupo_ssh
# Crea el grupo FTP_SSH_GROUP usado para bloquear acceso SSH a usuarios FTP.
# -----------------------------------------------------------------------------
_ftp_crear_grupo_ssh() {
    if ! getent group "$FTP_SSH_GROUP" &>/dev/null; then
        groupadd --system "$FTP_SSH_GROUP"
        aputs_success "Grupo SSH '$FTP_SSH_GROUP' creado"
    else
        aputs_info "Grupo SSH '$FTP_SSH_GROUP' ya existe"
    fi
}

# -----------------------------------------------------------------------------
# _ftp_bloquear_ssh
# Agrega DenyGroups FTP_SSH_GROUP a sshd_config (una sola vez).
# -----------------------------------------------------------------------------
_ftp_bloquear_ssh() {
    local sshd_conf="/etc/ssh/sshd_config"
    [[ ! -f "$sshd_conf" ]] && return 0
    local patron="DenyGroups ${FTP_SSH_GROUP}"
    if ! grep -qF "$patron" "$sshd_conf"; then
        { echo ""; echo "# Usuarios FTP — bloqueados en SSH"; echo "$patron"; } >> "$sshd_conf"
        systemctl reload sshd 2>/dev/null || true
        aputs_success "SSH: DenyGroups ${FTP_SSH_GROUP} agregado"
    else
        aputs_info "SSH: DenyGroups ${FTP_SSH_GROUP} ya configurado"
    fi
}

# -----------------------------------------------------------------------------
# _ftp_escribir_vsftpd_conf
# Genera vsftpd.conf completo desde cero (hace backup si ya existe).
# -----------------------------------------------------------------------------
_ftp_escribir_vsftpd_conf() {
    aputs_info "Escribiendo $VSFTPD_CONF..."
    [[ -f "$VSFTPD_CONF" ]] && ftp_crear_backup "$VSFTPD_CONF"

    cat > "$VSFTPD_CONF" <<CONF
# vsftpd.conf — generado por mainFTP.sh

listen=YES
listen_ipv6=NO

# --- Anónimo: chroot en ${FTP_ROOT}/ftp_anonymous (root:root 755)
anonymous_enable=YES
anon_root=${FTP_ROOT}/ftp_anonymous
no_anon_password=YES
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO

# --- Usuarios locales del sistema ---
local_enable=YES
write_enable=YES
local_umask=007

# --- Chroot por usuario ---
chroot_local_user=YES
allow_writeable_chroot=NO
user_sub_token=\$USER
local_root=${FTP_ROOT}/${FTP_USER_PREFIX}\$USER

# --- Banner y log ---
ftpd_banner=${FTP_BANNER}
xferlog_enable=YES
xferlog_std_format=YES
log_ftp_protocol=NO

# --- Modo pasivo ---
pasv_enable=YES
pasv_min_port=${FTP_PASV_MIN}
pasv_max_port=${FTP_PASV_MAX}

# --- Rendimiento ---
reverse_lookup_enable=NO

# --- PAM ---
pam_service_name=vsftpd
tcp_wrappers=NO
userlist_enable=NO
CONF
    aputs_success "vsftpd.conf escrito"
}

# -----------------------------------------------------------------------------
# _ftp_escribir_pam
# Configura PAM para autenticar vía /etc/shadow.
# -----------------------------------------------------------------------------
_ftp_escribir_pam() {
    aputs_info "Configurando PAM..."
    [[ -f "$PAM_FILE" ]] && ftp_crear_backup "$PAM_FILE"
    cat > "$PAM_FILE" <<PAM
#%PAM-1.0
auth     include  password-auth
account  include  password-auth
PAM
    aputs_success "PAM: autenticación vía /etc/shadow"
}

# -----------------------------------------------------------------------------
# _ftp_configurar_selinux
# Aplica contexto public_content_rw_t y booleano ftpd_full_access.
# -----------------------------------------------------------------------------
_ftp_configurar_selinux() {
    if ! command -v semanage &>/dev/null; then
        aputs_warning "semanage no disponible — omitiendo configuración SELinux"
        return 0
    fi
    aputs_info "Configurando SELinux para FTP..."
    semanage fcontext -a -t public_content_rw_t "${FTP_ROOT}(/.*)?" 2>/dev/null || \
    semanage fcontext -m -t public_content_rw_t "${FTP_ROOT}(/.*)?" 2>/dev/null
    restorecon -Rv "$FTP_ROOT" &>/dev/null
    setsebool -P ftpd_full_access on &>/dev/null
    aputs_success "SELinux configurado (public_content_rw_t + ftpd_full_access)"
}

# -----------------------------------------------------------------------------
# _ftp_abrir_firewall
# Abre puerto 21 y rango pasivo en firewalld.
# -----------------------------------------------------------------------------
_ftp_abrir_firewall() {
    command -v firewall-cmd &>/dev/null || return 0
    aputs_info "Configurando firewall..."
    firewall-cmd --permanent --add-service=ftp &>/dev/null
    firewall-cmd --permanent --add-port="${FTP_PASV_MIN}-${FTP_PASV_MAX}/tcp" &>/dev/null
    firewall-cmd --reload &>/dev/null
    aputs_success "Firewall configurado"
}

# -----------------------------------------------------------------------------
# _ftp_crear_estructura_dirs
# Crea árbol de directorios base: FTP_ROOT, general, grupos, anónimo.
# -----------------------------------------------------------------------------
_ftp_crear_estructura_dirs() {
    aputs_info "Creando estructura base en $FTP_ROOT..."

    mkdir -p "$FTP_GENERAL"
    local grupo
    for grupo in "${FTP_GROUPS[@]}"; do mkdir -p "${FTP_ROOT}/${grupo}"; done

    chown root:root "$FTP_ROOT"; chmod 755 "$FTP_ROOT"
    chown root:ftp  "$FTP_GENERAL"; chmod 775 "$FTP_GENERAL"; chmod +t "$FTP_GENERAL"

    setfacl -m  other::rwx "$FTP_GENERAL" 2>/dev/null || true
    setfacl -m  group::rwx "$FTP_GENERAL" 2>/dev/null || true
    setfacl -d -m other::rwx "$FTP_GENERAL" 2>/dev/null || true
    setfacl -d -m group::rwx "$FTP_GENERAL" 2>/dev/null || true

    for grupo in "${FTP_GROUPS[@]}"; do
        local dir="${FTP_ROOT}/${grupo}"
        chown root:"$grupo" "$dir"; chmod 2770 "$dir"; chmod +t "$dir"
    done

    local anon_root="${FTP_ROOT}/ftp_anonymous"
    mkdir -p "$anon_root"
    chown root:root "$anon_root"; chmod 755 "$anon_root"
    _ftp_crear_bind_mount "$FTP_GENERAL" "$anon_root/general"

    _ftp_selinux_context "$FTP_ROOT"
    aputs_success "Estructura base creada"
}

# -----------------------------------------------------------------------------
# _ftp_crear_bind_mount <origen> <destino>
# Crea y activa un bind mount persistente vía unidad systemd .mount
# -----------------------------------------------------------------------------
_ftp_crear_bind_mount() {
    local origen="$1" destino="$2"
    local unit_name; unit_name=$(_ftp_path_to_unit "$destino")
    local unit_file="/etc/systemd/system/${unit_name}"

    mkdir -p "$destino"
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
    systemctl daemon-reload
    systemctl enable --now "$unit_name" &>/dev/null \
        && aputs_success "Bind mount: $destino" \
        || aputs_error   "Error al montar: $destino"
}

# -----------------------------------------------------------------------------
# _ftp_eliminar_bind_mount <destino>
# Desmonta y elimina la unidad systemd del bind mount.
# -----------------------------------------------------------------------------
_ftp_eliminar_bind_mount() {
    local destino="$1"
    local unit_name; unit_name=$(_ftp_path_to_unit "$destino")
    systemctl disable --now "$unit_name" &>/dev/null || true
    umount "$destino" 2>/dev/null || true
    rm -f "/etc/systemd/system/${unit_name}"
    systemctl daemon-reload
    rmdir "$destino" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# ftp_instalar
# Flujo completo de instalación de vsftpd.
# -----------------------------------------------------------------------------
ftp_instalar() {
    draw_line
    aputs_info "Verificando paquetes necesarios..."

    local pkgs=()
    rpm -q vsftpd  &>/dev/null || pkgs+=("vsftpd")
    command -v openssl &>/dev/null || pkgs+=("openssl")

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        aputs_info "Instalando: ${pkgs[*]}..."
        dnf install -y "${pkgs[@]}" &>/dev/null || {
            aputs_error "No se pudieron instalar los paquetes requeridos"
            return 1
        }
        aputs_success "Paquetes instalados"
    else
        aputs_info "Dependencias ya presentes"
    fi

    _ftp_pedir_grupos_iniciales
    _ftp_crear_grupos_sistema
    _ftp_crear_grupo_ssh
    _ftp_crear_estructura_dirs
    _ftp_inicializar_meta
    _ftp_bloquear_ssh
    _ftp_escribir_vsftpd_conf
    _ftp_escribir_pam
    _ftp_configurar_selinux
    _ftp_abrir_firewall

    systemctl enable --now vsftpd &>/dev/null
    systemctl restart vsftpd

    if systemctl is-active --quiet vsftpd; then
        aputs_success "vsftpd activo y en ejecución"
    else
        aputs_error "vsftpd no inició — revisa: journalctl -u vsftpd -n 30"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# ftp_desinstalar
# Elimina vsftpd, bind mounts, usuarios y datos (con confirmaciones).
# -----------------------------------------------------------------------------
ftp_desinstalar() {
    echo -ne "${CYAN}[INPUT]${NC} Confirma desinstalación de vsftpd [s/N]: "
    read -r r
    [[ "$r" =~ ^[Ss]$ ]] || return

    systemctl stop vsftpd &>/dev/null
    systemctl disable vsftpd &>/dev/null
    dnf remove -y vsftpd &>/dev/null
    aputs_success "vsftpd desinstalado"

    aputs_info "Eliminando bind mounts..."
    while IFS=: read -r u _; do
        [[ -z "$u" ]] && continue
        local user_root="${FTP_ROOT}/${FTP_USER_PREFIX}${u}"
        _ftp_eliminar_bind_mount "$user_root/general"
        local g; for g in "${FTP_GROUPS[@]}"; do
            [[ -d "$user_root/$g" ]] && _ftp_eliminar_bind_mount "$user_root/$g"
        done
    done < "$VSFTPD_USERS_META" 2>/dev/null
    _ftp_eliminar_bind_mount "${FTP_ROOT}/ftp_anonymous/general" 2>/dev/null || true
    find /etc/systemd/system/ -name "srv-ftp-*.mount" -delete 2>/dev/null
    systemctl daemon-reload
    aputs_success "Bind mounts eliminados"

    echo -ne "${CYAN}[INPUT]${NC} ¿Eliminar usuarios FTP del sistema? [s/N]: "
    read -r ru
    if [[ "$ru" =~ ^[Ss]$ ]]; then
        while IFS=: read -r u _; do
            [[ -z "$u" ]] && continue
            id "$u" &>/dev/null && userdel "$u" && aputs_success "Usuario '$u' eliminado"
        done < "$VSFTPD_USERS_META" 2>/dev/null
    fi

    echo -ne "${CYAN}[INPUT]${NC} ¿Eliminar datos ($FTP_ROOT y configuración)? [s/N]: "
    read -r rd
    if [[ "$rd" =~ ^[Ss]$ ]]; then
        rm -rf "$FTP_ROOT" "$VSFTPD_USERS_META" "$VSFTPD_GROUPS_FILE"
        aputs_success "Datos eliminados"
    fi

    local sshd_conf="/etc/ssh/sshd_config"
    if [[ -f "$sshd_conf" ]]; then
        sed -i "/# Usuarios FTP/d;/DenyGroups ${FTP_SSH_GROUP}/d" "$sshd_conf"
        systemctl reload sshd 2>/dev/null || true
        aputs_success "SSH: DenyGroups removido"
    fi

    if command -v semanage &>/dev/null; then
        semanage fcontext -d "${FTP_ROOT}(/.*)?" 2>/dev/null || true
        setsebool -P ftpd_full_access off &>/dev/null || true
        aputs_success "SELinux: contexto FTP revertido"
    fi

    local pam_bak; pam_bak=$(ls -t "${PAM_FILE}.bak_"* 2>/dev/null | head -1)
    [[ -n "$pam_bak" ]] && cp "$pam_bak" "$PAM_FILE" && aputs_success "PAM restaurado"
}

# -----------------------------------------------------------------------------
# Control del servicio
# -----------------------------------------------------------------------------
ftp_iniciar()   { aputs_info "Iniciando vsftpd...";    systemctl start   vsftpd && aputs_success "vsftpd iniciado"   || aputs_error "No se pudo iniciar"; }
ftp_detener()   {
    echo -ne "${CYAN}[INPUT]${NC} Confirma detener vsftpd [s/N]: "; read -r r
    [[ "$r" =~ ^[Ss]$ ]] || return
    systemctl stop  vsftpd && aputs_success "vsftpd detenido"   || aputs_error "No se pudo detener"
}
ftp_reiniciar() { aputs_info "Reiniciando vsftpd..."; systemctl restart vsftpd && aputs_success "vsftpd reiniciado" || aputs_error "No se pudo reiniciar"; }
ftp_toggle_boot() {
    if systemctl is-enabled --quiet vsftpd; then
        systemctl disable vsftpd && aputs_success "Arranque automático deshabilitado"
    else
        systemctl enable  vsftpd && aputs_success "Arranque automático habilitado"
    fi
}

# -----------------------------------------------------------------------------
# ftp_menu_instalacion
# Menú del Grupo B.
# -----------------------------------------------------------------------------
ftp_menu_instalacion() {
    while true; do
        clear
        ftp_draw_header "Grupo B — Instalación y Control del Servicio"
        echo -e "  ${BLUE}1)${NC} Instalar vsftpd"
        echo -e "  ${BLUE}2)${NC} Iniciar servicio"
        echo -e "  ${BLUE}3)${NC} Detener servicio"
        echo -e "  ${BLUE}4)${NC} Reiniciar servicio"
        echo -e "  ${BLUE}5)${NC} Toggle arranque automático (enable/disable)"
        echo -e "  ${BLUE}6)${NC} Desinstalar vsftpd"
        echo -e "  ${BLUE}0)${NC} Volver al menú principal"
        echo ""

        local op
        read -rp "  Opción: " op
        case "$op" in
            1) ftp_instalar      ; pause ;;
            2) ftp_iniciar       ; pause ;;
            3) ftp_detener       ; pause ;;
            4) ftp_reiniciar     ; pause ;;
            5) ftp_toggle_boot   ; pause ;;
            6) ftp_desinstalar   ; pause ;;
            0) return 0 ;;
            *) aputs_error "Opción inválida"; sleep 1 ;;
        esac
    done
}

export -f _ftp_pedir_grupos_iniciales
export -f _ftp_crear_grupos_sistema
export -f _ftp_crear_grupo_ssh
export -f _ftp_bloquear_ssh
export -f _ftp_escribir_vsftpd_conf
export -f _ftp_escribir_pam
export -f _ftp_configurar_selinux
export -f _ftp_abrir_firewall
export -f _ftp_crear_estructura_dirs
export -f _ftp_crear_bind_mount
export -f _ftp_eliminar_bind_mount
export -f ftp_instalar
export -f ftp_desinstalar
export -f ftp_iniciar
export -f ftp_detener
export -f ftp_reiniciar
export -f ftp_toggle_boot
export -f ftp_menu_instalacion