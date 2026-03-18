#!/bin/bash
#
# utilsFTP.sh
# Utilidades extendidas para la gestión del servidor FTP (vsftpd)
#
# Complementa utils.sh con constantes y helpers específicos de FTP.
# Requiere:
#   utils.sh debe estar cargado antes (aputs_*, draw_*, agets, pause)
#
# Uso en mainFTP.sh:
#   source "${SCRIPT_DIR}/utils.sh"
#   source "${SCRIPT_DIR}/utilsFTP.sh"
#

# -----------------------------------------------------------------------------
# Constantes — rutas y valores por defecto
# -----------------------------------------------------------------------------
readonly FTP_ROOT="/srv/ftp"
readonly FTP_GENERAL="${FTP_ROOT}/general"
readonly FTP_USER_PREFIX="ftp_"
readonly FTP_BANNER="Servidor FTP"
readonly FTP_SSH_GROUP="ftp_users"

readonly VSFTPD_CONF="/etc/vsftpd/vsftpd.conf"
readonly VSFTPD_DIR="/etc/vsftpd"
readonly VSFTPD_GROUPS_FILE="${VSFTPD_DIR}/groups"
readonly VSFTPD_USERS_META="${VSFTPD_DIR}/virtual_users_meta"
readonly PAM_FILE="/etc/pam.d/vsftpd"

readonly FTP_PASV_MIN=30000
readonly FTP_PASV_MAX=31000

# Puertos reservados que el script nunca debe tocar
readonly FTP_PUERTOS_RESERVADOS=(22 25 53 80 443 3306 5432 8080)

# FTP_GROUPS es mutable — se carga desde disco en _ftp_cargar_grupos
FTP_GROUPS=()

# -----------------------------------------------------------------------------
# ftp_verificar_dependencias
# Verifica que vsftpd, openssl, setfacl y semanage estén disponibles.
# Retorna 0 si todo OK, 1 si falta alguna herramienta crítica.
# -----------------------------------------------------------------------------
ftp_verificar_dependencias() {
    local faltantes=0

    local criticas=("dnf" "systemctl" "firewall-cmd" "ss" "openssl" "setfacl")

    aputs_info "Verificando herramientas necesarias..."
    echo ""

    local h
    for h in "${criticas[@]}"; do
        if command -v "$h" &>/dev/null; then
            printf "  ${GREEN}[OK]${NC}  %-15s %s\n" "$h" "$(command -v "$h")"
        else
            printf "  ${RED}[NO]${NC}  %-15s NO encontrado\n" "$h"
            (( faltantes++ ))
        fi
    done

    echo ""

    # semanage es opcional — advertencia, no error crítico
    if command -v semanage &>/dev/null; then
        printf "  ${GREEN}[OK]${NC}  %-15s %s\n" "semanage" "$(command -v semanage)"
    else
        printf "  ${YELLOW}[WARN]${NC} %-15s No instalado (SELinux no se configurará)\n" "semanage"
        aputs_info "  Instale con: dnf install policycoreutils-python-utils"
    fi

    echo ""

    if (( faltantes > 0 )); then
        aputs_error "$faltantes herramienta(s) crítica(s) no encontrada(s)"
        return 1
    fi

    aputs_success "Todas las dependencias críticas disponibles"
    return 0
}

# -----------------------------------------------------------------------------
# ftp_puerto_en_uso <puerto>
# Retorna 0 si el puerto está en uso, 1 si está libre.
# -----------------------------------------------------------------------------
ftp_puerto_en_uso() {
    ss -tlnp 2>/dev/null | grep -q ":${1} "
}

# -----------------------------------------------------------------------------
# ftp_crear_backup <archivo>
# Crea copia con timestamp en el mismo directorio.
# -----------------------------------------------------------------------------
ftp_crear_backup() {
    local archivo="$1"
    [[ ! -f "$archivo" ]] && aputs_warning "No existe para backup: $archivo" && return 1
    local bak="${archivo}.bak_$(date +%Y%m%d_%H%M%S)"
    cp "$archivo" "$bak" && aputs_success "Backup: $bak" || {
        aputs_error "No se pudo crear backup de $archivo"; return 1
    }
}

# -----------------------------------------------------------------------------
# _ftp_set_param <param> <valor>
# Escribe o actualiza un parámetro en vsftpd.conf (sin espacios alrededor de =)
# -----------------------------------------------------------------------------
_ftp_set_param() {
    local param="$1" value="$2"
    local ve; ve=$(printf '%s' "$value" | sed 's/[@&\\]/\\&/g')
    if grep -qE "^#?${param}=" "$VSFTPD_CONF" 2>/dev/null; then
        sed -i "s@^#\?${param}=.*@${param}=${ve}@" "$VSFTPD_CONF"
    else
        echo "${param}=${value}" >> "$VSFTPD_CONF"
    fi
}

# -----------------------------------------------------------------------------
# _ftp_cargar_grupos
# Lee VSFTPD_GROUPS_FILE y puebla el array FTP_GROUPS.
# -----------------------------------------------------------------------------
_ftp_cargar_grupos() {
    FTP_GROUPS=()
    [[ ! -f "$VSFTPD_GROUPS_FILE" ]] && return 0
    while IFS= read -r linea; do
        linea="${linea%%#*}"
        linea="${linea//[[:space:]]/}"
        [[ -z "$linea" ]] && continue
        FTP_GROUPS+=("$linea")
    done < "$VSFTPD_GROUPS_FILE"
}

# -----------------------------------------------------------------------------
# _ftp_guardar_grupos
# Persiste FTP_GROUPS en VSFTPD_GROUPS_FILE.
# -----------------------------------------------------------------------------
_ftp_guardar_grupos() {
    mkdir -p "$VSFTPD_DIR"
    printf '%s\n' "${FTP_GROUPS[@]}" > "$VSFTPD_GROUPS_FILE"
}

# -----------------------------------------------------------------------------
# _ftp_selinux_context <path>
# Aplica contexto SELinux al path indicado (silencioso si no hay restorecon).
# -----------------------------------------------------------------------------
_ftp_selinux_context() {
    command -v restorecon &>/dev/null && restorecon -R "$1" &>/dev/null || true
}

# -----------------------------------------------------------------------------
# _ftp_path_to_unit <ruta_absoluta>
# Convierte una ruta en nombre de unidad systemd .mount
# Ej: /srv/ftp/ftp_ana/general → srv-ftp-ftp_ana-general.mount
# -----------------------------------------------------------------------------
_ftp_path_to_unit() {
    local path="${1#/}"
    echo "${path//\//-}.mount"
}

# -----------------------------------------------------------------------------
# ftp_draw_header <titulo>
# Encabezado visual uniforme para todos los submenús FTP.
# -----------------------------------------------------------------------------
ftp_draw_header() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  $1"
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

# -----------------------------------------------------------------------------
# Exportar variables y funciones para subshells
# -----------------------------------------------------------------------------
export FTP_ROOT FTP_GENERAL FTP_USER_PREFIX FTP_BANNER FTP_SSH_GROUP
export VSFTPD_CONF VSFTPD_DIR VSFTPD_GROUPS_FILE VSFTPD_USERS_META PAM_FILE
export FTP_PASV_MIN FTP_PASV_MAX FTP_PUERTOS_RESERVADOS

export -f ftp_verificar_dependencias
export -f ftp_puerto_en_uso
export -f ftp_crear_backup
export -f _ftp_set_param
export -f _ftp_cargar_grupos
export -f _ftp_guardar_grupos
export -f _ftp_selinux_context
export -f _ftp_path_to_unit
export -f ftp_draw_header