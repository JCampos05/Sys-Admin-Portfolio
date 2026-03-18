#!/bin/bash
# =============================================================================
# ssl/ssl_ftp.sh — Configuración de FTPS (TLS explícito) en vsftpd
#
# Propósito:
#   Añadir las directivas SSL/TLS al vsftpd.conf existente para habilitar
#   FTPS en modo TLS explícito (puerto 21, el cliente negocia STARTTLS).
#
#   NO reinstala vsftpd — solo edita su configuración.
#   Requiere que el certificado ya esté generado (ssl_cert.sh).
#
# Funciones públicas:
#   ssl_ftp_verificar_prereqs() — verifica vsftpd instalado + cert existe
#   ssl_ftp_aplicar()           — escribe directivas SSL en vsftpd.conf
#   ssl_ftp_revertir()          — elimina directivas SSL (rollback)
#   ssl_ftp_estado()            — muestra estado actual de SSL en vsftpd
#   ssl_menu_ftp()              — submenú interactivo
#
# Requiere:
#   utils.sh, ssl_utils.sh, ssl_cert.sh cargados previamente
# =============================================================================

[[ -n "${_SSL_FTP_LOADED:-}" ]] && return 0
readonly _SSL_FTP_LOADED=1

# Marcador que identifica el bloque SSL en vsftpd.conf
# Se usa para detectar si ya fue aplicado y para revertirlo
readonly _SSL_FTP_MARCA="# === Practica7 SSL/TLS ==="

# -----------------------------------------------------------------------------
# ssl_ftp_verificar_prereqs
#
# Verifica que:
#   1. vsftpd está instalado (rpm -q)
#   2. El certificado ya fue generado (ssl_cert_existe)
#   3. El archivo vsftpd.conf existe
# -----------------------------------------------------------------------------
ssl_ftp_verificar_prereqs() {
    local ok=true

    aputs_info "Verificando prerequisitos para FTPS..."
    echo ""

    # vsftpd debe estar instalado
    if rpm -q vsftpd &>/dev/null; then
        printf "  ${GREEN}[OK]${NC}  vsftpd instalado\n"
    else
        printf "  ${RED}[NO]${NC}  vsftpd NO instalado\n"
        aputs_info "        Ejecute primero: Paso 1 — Instalar FTP"
        ok=false
    fi

    # El archivo de configuración debe existir
    if [[ -f "${SSL_CONF_VSFTPD}" ]]; then
        printf "  ${GREEN}[OK]${NC}  vsftpd.conf encontrado: ${SSL_CONF_VSFTPD}\n"
    else
        printf "  ${RED}[NO]${NC}  vsftpd.conf NO encontrado en ${SSL_CONF_VSFTPD}\n"
        ok=false
    fi

    # El certificado debe estar generado
    if ssl_cert_existe; then
        printf "  ${GREEN}[OK]${NC}  Certificado: ${SSL_CERT}\n"
        printf "  ${GREEN}[OK]${NC}  Clave:        ${SSL_KEY}\n"
    else
        printf "  ${RED}[NO]${NC}  Certificado NO generado en ${SSL_DIR}\n"
        aputs_info "        Ejecute primero: Paso 2a — Generar certificado"
        ok=false
    fi

    echo ""
    if $ok; then
        aputs_success "Prerequisitos OK — listo para configurar FTPS"
        return 0
    else
        aputs_error "Prerequisitos incompletos"
        return 1
    fi
}

ssl_ftp_aplicar() {
    ssl_mostrar_banner "FTPS — Aplicar TLS a vsftpd"

    ssl_ftp_verificar_prereqs || return 1

    # Verificar si ya fue aplicado
    if grep -q "${_SSL_FTP_MARCA}" "${SSL_CONF_VSFTPD}" 2>/dev/null; then
        aputs_warning "FTPS ya está configurado en ${SSL_CONF_VSFTPD}"
        echo ""
        ssl_ftp_estado
        echo ""
        echo -ne "${YELLOW}[?]${NC} ¿Desea reaplicar la configuración? [s/N]: "
        local resp
        read -r resp
        [[ ! "$resp" =~ ^[sS]$ ]] && return 0

        # Eliminar bloque anterior antes de reaplicar
        _ssl_ftp_eliminar_bloque
    fi

    # ── Preguntar comportamiento para usuarios anónimos ─────────────────────
    echo ""
    aputs_info "Configuración de acceso anónimo con FTPS:"
    echo ""
    echo "  El repositorio FTP permite acceso anónimo para descargar RPMs."
    echo "  Puedes elegir cómo se comporta el TLS para esos usuarios:"
    echo ""
    echo -e "  ${BLUE}1)${NC} Anónimo sin TLS  — se conecta en texto plano (recomendado para"
    echo    "                     repositorios públicos, compatible con todos los clientes)"
    echo -e "  ${BLUE}2)${NC} Anónimo con TLS  — puede usar TLS si su cliente lo soporta"
    echo    "                     (más seguro, pero puede fallar con clientes básicos)"
    echo -e "  ${BLUE}3)${NC} Bloquear anónimo — solo usuarios autenticados pueden conectarse"
    echo    "                     (máxima seguridad, repositorio FTP deja de ser público)"
    echo ""

    local anon_opt
    while true; do
        echo -ne "  ${YELLOW}[?]${NC} Seleccione opción [1-3, Enter=1]: "
        read -r anon_opt
        [[ -z "$anon_opt" ]] && anon_opt="1"
        [[ "$anon_opt" =~ ^[123]$ ]] && break
        aputs_error "Opción inválida — ingrese 1, 2 o 3"
    done

    # Construir directivas según la opción elegida
    local anon_ssl_line=""
    local anon_upload_line=""
    local anon_desc=""

    case "$anon_opt" in
        1)
            anon_ssl_line="allow_anon_ssl=NO"
            anon_desc="Anónimo: texto plano (sin TLS requerido)"
            ;;
        2)
            anon_ssl_line="allow_anon_ssl=YES"
            anon_desc="Anónimo: TLS habilitado (opcional)"
            ;;
        3)
            anon_ssl_line="allow_anon_ssl=NO"
            anon_upload_line="anon_enable=NO"
            anon_desc="Anónimo: BLOQUEADO (solo usuarios autenticados)"
            ;;
    esac

    aputs_success "Configuración elegida: ${anon_desc}"
    echo ""

    # Backup antes de modificar
    ssl_hacer_backup "${SSL_CONF_VSFTPD}"
    echo ""

    aputs_info "Agregando directivas SSL a ${SSL_CONF_VSFTPD}..."
    echo ""

    # Escribir bloque SSL al final del archivo
    # La directiva anon_enable=NO se agrega solo si el usuario eligió opción 3
    {
        echo ""
        echo "${_SSL_FTP_MARCA}"
        echo "# Habilitado por mainT07.sh — Práctica 7"
        echo "# Modo anónimo: ${anon_desc}"
        echo "ssl_enable=YES"
        echo "rsa_cert_file=${SSL_CERT}"
        echo "rsa_private_key_file=${SSL_KEY}"
        echo "ssl_tlsv1=YES"
        echo "ssl_sslv2=NO"
        echo "ssl_sslv3=NO"
        echo "force_local_data_ssl=NO"
        echo "force_local_logins_ssl=NO"
        echo "${anon_ssl_line}"
        [[ -n "$anon_upload_line" ]] && echo "$anon_upload_line"
        echo "${_SSL_FTP_MARCA}"
    } >> "${SSL_CONF_VSFTPD}"

    if [[ $? -ne 0 ]]; then
        aputs_error "No se pudo escribir en ${SSL_CONF_VSFTPD}"
        return 1
    fi

    aputs_success "Directivas SSL escritas"
    echo ""

    # Mostrar las líneas añadidas para confirmación visual
    aputs_info "Bloque agregado:"
    echo ""
    grep -A 12 "${_SSL_FTP_MARCA}" "${SSL_CONF_VSFTPD}" | head -13 \
        | sed 's/^/    /'
    echo ""

    # Reiniciar vsftpd para que tome los cambios
    aputs_info "Reiniciando vsftpd..."
    if systemctl restart vsftpd 2>/dev/null; then
        aputs_success "vsftpd reiniciado correctamente"
    else
        aputs_error "Error al reiniciar vsftpd"
        aputs_info  "Verifique: journalctl -u vsftpd -n 20"
        return 1
    fi

    echo ""
    aputs_success "FTPS configurado — vsftpd acepta TLS en puerto 21"
    aputs_info    "Prueba: openssl s_client -connect 192.168.100.10:21 -starttls ftp"
    return 0
}

# -----------------------------------------------------------------------------
# _ssl_ftp_eliminar_bloque
# Elimina el bloque SSL de vsftpd.conf usando sed.
# Uso interno — llamado por ssl_ftp_revertir y al reaplicar.
# -----------------------------------------------------------------------------
_ssl_ftp_eliminar_bloque() {
    local marca_escapada
    marca_escapada=$(echo "${_SSL_FTP_MARCA}" | sed 's/[#=\/]/\\&/g')

    sed -i "/${marca_escapada}/,/${marca_escapada}/d" "${SSL_CONF_VSFTPD}" 2>/dev/null
}

# -----------------------------------------------------------------------------
# ssl_ftp_revertir
#
# Elimina las directivas SSL de vsftpd.conf y reinicia el servicio.
# Útil si algo falla o se quiere dejar vsftpd en modo plain FTP.
# -----------------------------------------------------------------------------
ssl_ftp_revertir() {
    ssl_mostrar_banner "FTPS — Revertir configuración SSL"

    if ! grep -q "${_SSL_FTP_MARCA}" "${SSL_CONF_VSFTPD}" 2>/dev/null; then
        aputs_info "No hay configuración SSL que revertir en ${SSL_CONF_VSFTPD}"
        return 0
    fi

    echo -ne "${YELLOW}[?]${NC} ¿Confirma eliminar las directivas SSL de vsftpd? [s/N]: "
    local resp
    read -r resp
    [[ ! "$resp" =~ ^[sS]$ ]] && return 0

    ssl_hacer_backup "${SSL_CONF_VSFTPD}"

    _ssl_ftp_eliminar_bloque

    aputs_success "Directivas SSL eliminadas de ${SSL_CONF_VSFTPD}"

    aputs_info "Reiniciando vsftpd..."
    if systemctl restart vsftpd 2>/dev/null; then
        aputs_success "vsftpd reiniciado en modo plain FTP"
    else
        aputs_error "Error al reiniciar vsftpd"
    fi
}

# -----------------------------------------------------------------------------
# ssl_ftp_estado
#
# Muestra el estado actual de SSL en vsftpd: si está activo, qué certificado
# usa, si el servicio está corriendo.
# Función de solo lectura — no modifica nada.
# -----------------------------------------------------------------------------
ssl_ftp_estado() {
    aputs_info "Estado FTPS en vsftpd:"
    echo ""

    # ¿Está el bloque SSL en vsftpd.conf?
    if grep -q "${_SSL_FTP_MARCA}" "${SSL_CONF_VSFTPD}" 2>/dev/null; then
        printf "  ${GREEN}[●]${NC}  SSL configurado en vsftpd.conf\n"
    else
        printf "  ${YELLOW}[○]${NC}  SSL NO configurado en vsftpd.conf\n"
    fi

    # ¿El servicio está activo?
    if systemctl is-active --quiet vsftpd 2>/dev/null; then
        local pid
        pid=$(systemctl show vsftpd -p MainPID --value 2>/dev/null)
        printf "  ${GREEN}[●]${NC}  vsftpd activo (PID: %s)\n" "${pid}"
    else
        printf "  ${RED}[○]${NC}  vsftpd NO está activo\n"
    fi

    # ¿ssl_enable=YES está presente?
    if grep -q "^ssl_enable=YES" "${SSL_CONF_VSFTPD}" 2>/dev/null; then
        printf "  ${GREEN}[●]${NC}  ssl_enable=YES\n"
    else
        printf "  ${YELLOW}[○]${NC}  ssl_enable no activo\n"
    fi

    # ¿Qué certificado está configurado?
    local cert_conf
    cert_conf=$(grep "^rsa_cert_file=" "${SSL_CONF_VSFTPD}" 2>/dev/null | cut -d= -f2)
    if [[ -n "$cert_conf" ]]; then
        printf "  ${CYAN}[i]${NC}  Certificado: %s\n" "${cert_conf}"
    fi

    # Modo anónimo
    if grep -q "^anon_enable=NO" "${SSL_CONF_VSFTPD}" 2>/dev/null; then
        printf "  ${RED}[●]${NC}  Anónimo: BLOQUEADO\n"
    elif grep -q "^allow_anon_ssl=YES" "${SSL_CONF_VSFTPD}" 2>/dev/null; then
        printf "  ${GREEN}[●]${NC}  Anónimo: TLS habilitado\n"
    else
        printf "  ${CYAN}[●]${NC}  Anónimo: texto plano (sin TLS)\n"
    fi

    echo ""
}

# -----------------------------------------------------------------------------
# ssl_menu_ftp — submenú interactivo del módulo FTPS
# -----------------------------------------------------------------------------
ssl_menu_ftp() {
    while true; do
        clear
        ssl_mostrar_banner "Tarea 07 — FTPS (TLS en vsftpd)"

        ssl_ftp_estado

        echo -e "  ${BLUE}1)${NC} Aplicar TLS a vsftpd"
        echo -e "  ${BLUE}2)${NC} Ver estado detallado"
        echo -e "  ${BLUE}3)${NC} Revertir configuración SSL"
        echo -e "  ${BLUE}0)${NC} Volver"
        echo ""

        local op
        read -rp "  Opción: " op

        case "$op" in
            1) ssl_ftp_aplicar;             pause ;;
            2) ssl_ftp_verificar_prereqs;   pause ;;
            3) ssl_ftp_revertir;            pause ;;
            0) return 0 ;;
            *) aputs_error "Opción inválida"; sleep 1 ;;
        esac
    done
}

export -f ssl_ftp_verificar_prereqs
export -f ssl_ftp_aplicar
export -f ssl_ftp_revertir
export -f ssl_ftp_estado
export -f ssl_menu_ftp
export -f _ssl_ftp_eliminar_bloque