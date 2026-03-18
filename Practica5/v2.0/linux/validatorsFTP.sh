#!/bin/bash
#
# validatorsFTP.sh
# Validaciones, helpers de entrada y gestión de metadatos de usuarios FTP
#
# Requiere:
#   utils.sh    cargado antes (aputs_error, aputs_*)
#   utilsFTP.sh cargado antes (constantes FTP_*, VSFTPD_USERS_META)
#

# Nombres de sistema que no pueden usarse como login FTP
readonly _FTP_USUARIOS_RESERVADOS=(root bin daemon adm lp sync shutdown halt
    mail operator games ftp nobody systemd-network dbus polkitd sshd chrony
    vsftpd nfsnobody www-data apache nginx ftp_users)

# -----------------------------------------------------------------------------
# ftp_validar_nombre_usuario <nombre>
# Retorna 0 si el nombre es válido, 1 en caso contrario.
# Reglas: minúsculas/números/_.- ; max 32 chars ; empieza con letra o _
# -----------------------------------------------------------------------------
ftp_validar_nombre_usuario() {
    local nombre="$1"

    if [[ ! "$nombre" =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]]; then
        aputs_error "Nombre inválido '$nombre': minúsculas/números/_.-; max 32; empieza con letra o _"
        return 1
    fi

    local r
    for r in "${_FTP_USUARIOS_RESERVADOS[@]}"; do
        [[ "$nombre" == "$r" ]] && aputs_error "Nombre reservado: '$nombre'" && return 1
    done

    return 0
}

# -----------------------------------------------------------------------------
# ftp_validar_nombre_grupo <nombre>
# Retorna 0 si el nombre de grupo es válido.
# -----------------------------------------------------------------------------
ftp_validar_nombre_grupo() {
    local nombre="$1"
    if [[ -z "$nombre" || ! "$nombre" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        aputs_error "Nombre de grupo inválido: solo minúsculas, números, _ y -"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# ftp_pedir_contrasena <__var>
# Solicita contraseña con confirmación. Escribe resultado en la variable
# cuyo nombre se pasa como argumento (nameref pattern).
# -----------------------------------------------------------------------------
ftp_pedir_contrasena() {
    local __var="$1"
    local p1 p2
    while true; do
        echo -ne "${CYAN}[INPUT]${NC} Contraseña (mín. 4 caracteres): "
        read -rs p1; echo
        [[ ${#p1} -lt 4 ]] && aputs_error "Mínimo 4 caracteres" && continue
        echo -ne "${CYAN}[INPUT]${NC} Confirma contraseña: "
        read -rs p2; echo
        [[ "$p1" != "$p2" ]] && aputs_error "Las contraseñas no coinciden" && continue
        printf -v "$__var" "%s" "$p1"
        return 0
    done
}

# -----------------------------------------------------------------------------
# ftp_pedir_grupo <__var>
# Muestra los grupos disponibles y solicita selección.
# Escribe el nombre del grupo elegido en la variable indicada.
# -----------------------------------------------------------------------------
ftp_pedir_grupo() {
    local __var="${1:-_grupo_sel}"
    local sel
    while true; do
        echo "  Grupos disponibles:"
        local i
        for i in "${!FTP_GROUPS[@]}"; do
            echo "    $((i+1))) ${FTP_GROUPS[$i]}"
        done
        echo -ne "${CYAN}[INPUT]${NC} Selecciona grupo [1-${#FTP_GROUPS[@]}]: "
        read -r sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && \
           (( sel >= 1 && sel <= ${#FTP_GROUPS[@]} )); then
            printf -v "$__var" "%s" "${FTP_GROUPS[$((sel-1))]}"
            return 0
        fi
        aputs_error "Selección inválida"
    done
}

# -----------------------------------------------------------------------------
# Gestión de metadatos de usuarios (archivo VSFTPD_USERS_META)
# Formato de cada línea: usuario:grupo
# -----------------------------------------------------------------------------
ftp_meta_get_grupo()  { grep -m1 "^${1}:" "$VSFTPD_USERS_META" 2>/dev/null | cut -d: -f2; }
ftp_meta_del()        { sed -i "/^${1}:/d" "$VSFTPD_USERS_META"; }
ftp_meta_existe()     { grep -q "^${1}:" "$VSFTPD_USERS_META" 2>/dev/null; }
ftp_meta_set() {
    local u="$1" g="$2"
    if grep -q "^${u}:" "$VSFTPD_USERS_META" 2>/dev/null; then
        sed -i "s|^${u}:.*|${u}:${g}|" "$VSFTPD_USERS_META"
    else
        echo "${u}:${g}" >> "$VSFTPD_USERS_META"
    fi
}

# -----------------------------------------------------------------------------
# ftp_usuario_existe <nombre>
# Retorna 0 si el usuario está registrado en los metadatos.
# -----------------------------------------------------------------------------
ftp_usuario_existe() { ftp_meta_existe "$1"; }

# -----------------------------------------------------------------------------
# _ftp_set_password <usuario> <password>
# Aplica la contraseña al usuario del sistema via chpasswd.
# -----------------------------------------------------------------------------
_ftp_set_password() {
    echo "${1}:${2}" | chpasswd
}

# -----------------------------------------------------------------------------
# _ftp_inicializar_meta
# Crea el archivo de metadatos si no existe.
# -----------------------------------------------------------------------------
_ftp_inicializar_meta() {
    mkdir -p "$VSFTPD_DIR"
    touch "$VSFTPD_USERS_META"
    chmod 640 "$VSFTPD_USERS_META"
    aputs_success "Archivo de metadatos inicializado"
}

export -f ftp_validar_nombre_usuario
export -f ftp_validar_nombre_grupo
export -f ftp_pedir_contrasena
export -f ftp_pedir_grupo
export -f ftp_meta_get_grupo
export -f ftp_meta_del
export -f ftp_meta_existe
export -f ftp_meta_set
export -f ftp_usuario_existe
export -f _ftp_set_password
export -f _ftp_inicializar_meta