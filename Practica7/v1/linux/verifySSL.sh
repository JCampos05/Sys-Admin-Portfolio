#!/bin/bash
# 
# ssl/ssl_verify.sh — Verificación general y reporte final de la Práctica 7
#
#
# Funciones públicas:
#   ssl_verify_certificado()   — verifica el cert (vigencia, CN, permisos)
#   ssl_verify_ftp()           — verifica vsftpd (servicio + TLS)
#   ssl_verify_repositorio()   — verifica estructura y RPMs del repo FTP
#   ssl_verify_http()          — verifica HTTP/HTTPS de los servicios
#   ssl_verify_todo()          — ejecuta todas las verificaciones + tabla
#   ssl_menu_verify()          — submenú interactivo
#
# Requiere:
#   utils.sh, ssl_utils.sh cargados previamente
# 

[[ -n "${_SSL_VERIFY_LOADED:-}" ]] && return 0
readonly _SSL_VERIFY_LOADED=1

# Colores para la tabla de resultados (complementan los de utils.sh)
readonly _V_OK="${GREEN}  OK  ${NC}"
readonly _V_FAIL="${RED}  FAIL${NC}"
readonly _V_WARN="${YELLOW}  WARN${NC}"
readonly _V_SKIP="${GRAY}  SKIP${NC}"

# -----------------------------------------------------------------------------
# _v_check  <descripcion>  <resultado: ok|fail|warn|skip>  [detalle]
# Helper interno para imprimir una fila de verificación con formato uniforme.
# -----------------------------------------------------------------------------
_v_check() {
    local desc="$1"
    local result="$2"
    local detalle="${3:-}"

    local icono
    case "$result" in
        ok)   icono="${_V_OK}"   ;;
        fail) icono="${_V_FAIL}" ;;
        warn) icono="${_V_WARN}" ;;
        skip) icono="${_V_SKIP}" ;;
    esac

    printf "  ${icono}  %-38s %s\n" "${desc}" "${detalle}"
}

# -----------------------------------------------------------------------------
# ssl_verify_certificado
# Verifica el estado del certificado: existencia, vigencia, CN, permisos.
# -----------------------------------------------------------------------------
ssl_verify_certificado() {
    echo ""
    aputs_info "── Certificado SSL/TLS ──"
    echo ""

    # ¿Existe?
    if [[ ! -f "${SSL_CERT}" ]]; then
        _v_check "Archivo ${SSL_CERT}" "fail" "(no existe)"
        return 1
    fi
    _v_check "Archivo ${SSL_CERT}" "ok"

    if [[ ! -f "${SSL_KEY}" ]]; then
        _v_check "Clave ${SSL_KEY}" "fail" "(no existe)"
        return 1
    fi
    _v_check "Clave ${SSL_KEY}" "ok"

    # ¿Vigente?
    if openssl x509 -in "${SSL_CERT}" -noout -checkend 0 &>/dev/null; then
        local end_date
        end_date=$(openssl x509 -in "${SSL_CERT}" -noout -enddate 2>/dev/null \
                   | sed 's/notAfter=//')
        _v_check "Certificado vigente" "ok" "expira: ${end_date}"
    else
        _v_check "Certificado vigente" "fail" "(EXPIRADO)"
    fi

    # ¿CN correcto?
    local cn
    cn=$(openssl x509 -in "${SSL_CERT}" -noout -subject 2>/dev/null \
         | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1)
    if [[ "${cn}" == "${SSL_DOMAIN}" ]]; then
        _v_check "CN = ${SSL_DOMAIN}" "ok"
    else
        _v_check "CN = ${SSL_DOMAIN}" "fail" "(encontrado: ${cn})"
    fi

    # ¿Permisos correctos?
    local perm_key
    perm_key=$(stat -c "%a" "${SSL_KEY}" 2>/dev/null)
    if [[ "${perm_key}" == "600" ]]; then
        _v_check "Permisos clave (600)" "ok"
    else
        _v_check "Permisos clave (600)" "warn" "(actual: ${perm_key})"
    fi

    echo ""
}

# -----------------------------------------------------------------------------
# ssl_verify_ftp
# Verifica vsftpd: instalado, activo, puerto 21, TLS configurado.
# -----------------------------------------------------------------------------
ssl_verify_ftp() {
    echo ""
    aputs_info "── FTP (vsftpd) ──"
    echo ""

    # ¿Instalado?
    if ! rpm -q vsftpd &>/dev/null; then
        _v_check "vsftpd instalado" "fail"
        echo ""
        return 0
    fi
    _v_check "vsftpd instalado" "ok"

    # ¿Activo?
    if systemctl is-active --quiet vsftpd 2>/dev/null; then
        _v_check "vsftpd activo" "ok"
    else
        _v_check "vsftpd activo" "fail" "(inactivo)"
    fi

    # ¿Puerto 21 escuchando?
    if ss -tlnp 2>/dev/null | grep -q ":21 "; then
        _v_check "Puerto 21 escuchando" "ok"
    else
        _v_check "Puerto 21 escuchando" "warn" "(no detectado con ss)"
    fi

    # Estado TLS — verificación por configuración únicamente (sin intentar conexión)
    # El script NO requiere que FTPS esté configurado para continuar —
    # es un paso opcional (Paso 2). Se informa el estado sin abortar.
    local ssl_activo=false
    local cert_correcto=false

    if grep -q "^ssl_enable=YES" "${SSL_CONF_VSFTPD}" 2>/dev/null; then
        ssl_activo=true
    fi
    if grep -q "^rsa_cert_file=${SSL_CERT}" "${SSL_CONF_VSFTPD}" 2>/dev/null; then
        cert_correcto=true
    fi

    if $ssl_activo && $cert_correcto; then
        local anon_modo=""
        if grep -q "^anon_enable=NO" "${SSL_CONF_VSFTPD}" 2>/dev/null; then
            anon_modo="anónimo: BLOQUEADO"
        elif grep -q "^allow_anon_ssl=YES" "${SSL_CONF_VSFTPD}" 2>/dev/null; then
            anon_modo="anónimo: TLS habilitado"
        else
            anon_modo="anónimo: texto plano"
        fi
        _v_check "FTPS/TLS en vsftpd" "ok" "(ssl_enable=YES — ${anon_modo})"
    elif $ssl_activo; then
        local cert_actual=""
        cert_actual=$(grep "^rsa_cert_file=" "${SSL_CONF_VSFTPD}" 2>/dev/null                       | cut -d= -f2) || true
        _v_check "FTPS/TLS en vsftpd" "warn" "(ssl_enable=YES, cert: ${cert_actual:-no configurado})"
    else
        _v_check "FTPS/TLS en vsftpd" "warn" "(no configurado — Paso 2 opcional)"
    fi

    echo ""
}

# -----------------------------------------------------------------------------
# ssl_verify_repositorio
# Verifica la estructura del repositorio FTP y la integridad de los RPMs.
# -----------------------------------------------------------------------------
ssl_verify_repositorio() {
    echo ""
    aputs_info "── Repositorio FTP ──"
    echo ""

    # ¿Existe la raíz del repositorio?
    if [[ ! -d "${SSL_REPO_ROOT}" ]]; then
        _v_check "Directorio repositorio" "fail" "(${SSL_REPO_ROOT} no existe)"
        return 1
    fi
    _v_check "Directorio repositorio" "ok" "${SSL_REPO_ROOT}"

    # Verificar cada subdirectorio y sus RPMs
    local dirs_servicios=(
        "Apache:${SSL_REPO_APACHE}"
        "Nginx:${SSL_REPO_NGINX}"
        "Tomcat:${SSL_REPO_TOMCAT}"
    )

    for entrada in "${dirs_servicios[@]}"; do
        local nombre="${entrada%%:*}"
        local dir="${entrada##*:}"

        if [[ ! -d "${dir}" ]]; then
            _v_check "Directorio ${nombre}" "fail" "(no existe)"
            continue
        fi

        local count_rpm
        count_rpm=$(find "${dir}" -name "*.rpm" 2>/dev/null | wc -l)
        local count_sha
        count_sha=$(find "${dir}" -name "*.sha256" 2>/dev/null | wc -l)

        if [[ $count_rpm -gt 0 ]]; then
            _v_check "RPMs en ${nombre}" "ok" "${count_rpm} rpm(s), ${count_sha} sha256(s)"
        else
            _v_check "RPMs en ${nombre}" "warn" "(directorio vacío)"
        fi

        # Verificar integridad de los checksums
        if [[ $count_sha -gt 0 ]]; then
            local sha_fail=0
            while IFS= read -r sha_file; do
                local rpm_file="${sha_file%.sha256}"
                if [[ -f "$rpm_file" ]]; then
                    local h_esp h_act
                    h_esp=$(awk '{print $1}' "$sha_file" 2>/dev/null)
                    h_act=$(sha256sum "$rpm_file" 2>/dev/null | awk '{print $1}')
                    if [[ "$h_act" != "$h_esp" ]]; then
                        sha_fail=$(( sha_fail + 1 ))
                    fi
                fi
            done < <(find "${dir}" -name "*.sha256" 2>/dev/null)

            if [[ $sha_fail -eq 0 ]]; then
                _v_check "Checksums SHA256 ${nombre}" "ok"
            else
                _v_check "Checksums SHA256 ${nombre}" "fail" "${sha_fail} checksum(s) inválido(s)"
            fi
        fi
    done

    # Verificar permisos del repositorio para acceso FTP anónimo
    local perm_repo
    perm_repo=$(stat -c "%a" "${SSL_REPO_ROOT}" 2>/dev/null)
    if [[ "${perm_repo}" == "755" ]]; then
        _v_check "Permisos repositorio (755)" "ok"
    else
        _v_check "Permisos repositorio (755)" "warn" "(actual: ${perm_repo})"
    fi

    echo ""
}

# -----------------------------------------------------------------------------
# ssl_verify_http
# Verifica HTTP y HTTPS de Apache, Nginx y Tomcat.
# Para cada servicio instalado: prueba el puerto HTTP y el HTTPS con curl.
# -----------------------------------------------------------------------------
ssl_verify_http() {
    echo ""
    aputs_info "── Servicios HTTP/HTTPS ──"
    echo ""

    local servicios=("httpd:Apache" "nginx:Nginx" "tomcat:Tomcat")

    for entrada in "${servicios[@]}"; do
        local pkg="${entrada%%:*}"
        local nombre="${entrada##*:}"

        if ! ssl_servicio_instalado "${pkg}"; then
            _v_check "${nombre}" "skip" "(no instalado)"
            continue
        fi

        # ¿Activo?
        if systemctl is-active --quiet "${pkg}" 2>/dev/null; then
            _v_check "${nombre} activo" "ok"
        else
            _v_check "${nombre} activo" "fail" "(inactivo)"
            continue
        fi

        # Detectar puertos
        local http_port
        http_port=$(ssl_leer_puerto_http "${pkg}")
        local https_port
        https_port=$(ssl_leer_puerto_https "${pkg}")

        # Prueba HTTP
        # ── Prueba HTTP ───────────────────────────────────────────────────────
        local http_code=""
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                    --connect-timeout 3 \
                    "http://127.0.0.1:${http_port}" 2>/dev/null) || true

        case "${http_code}" in
            2*)
                _v_check "${nombre} HTTP :${http_port}" "ok" "HTTP ${http_code}" ;;
            301|302|307|308)
                _v_check "${nombre} HTTP :${http_port}" "ok" "Redirect ${http_code} → HTTPS" ;;
            000|"")
                _v_check "${nombre} HTTP :${http_port}" "fail" "(sin respuesta)" ;;
            *)
                _v_check "${nombre} HTTP :${http_port}" "warn" "HTTP ${http_code}" ;;
        esac

        # ── Prueba HTTPS + TLS handshake ─────────────────────────────────────
        # Obtener código HTTP y datos del certificado en una sola pasada con curl
        local https_code=""
        local https_cert_cn=""
        local https_tls_ver=""

        # curl -w con múltiples variables — más eficiente que llamadas separadas
        local curl_https_out=""
        curl_https_out=$(curl -sk --max-time 5 \
            --connect-timeout 3 \
            -o /dev/null \
            -w "%{http_code}|%{ssl_verify_result}" \
            "https://127.0.0.1:${https_port}" 2>/dev/null) || true

        local https_ssl_verify=""
        https_code=$(echo "${curl_https_out}"    | cut -d'|' -f1) || true
        https_ssl_verify=$(echo "${curl_https_out}" | cut -d'|' -f2) || true

        # Evaluar código HTTP del HTTPS
        case "${https_code}" in
            2*)
                _v_check "${nombre} HTTPS :${https_port}" "ok" "HTTP ${https_code}" ;;
            301|302|307|308)
                _v_check "${nombre} HTTPS :${https_port}" "ok" "HTTP ${https_code} (redirect)" ;;
            000|"")
                _v_check "${nombre} HTTPS :${https_port}" "warn" "(sin respuesta — SSL posiblemente no configurado)" ;;
            *)
                _v_check "${nombre} HTTPS :${https_port}" "warn" "HTTP ${https_code}" ;;
        esac

        # ── TLS handshake: openssl con fallback a curl ────────────────────────
        local ssl_output=""
        ssl_output=$(echo "Q" | timeout 5 openssl s_client \
            -connect "127.0.0.1:${https_port}" \
            -CAfile "${SSL_CERT}" \
            2>/dev/null) || true

        local ssl_proto=""
        local ssl_cn=""
        ssl_proto=$(echo "${ssl_output}" | grep "Protocol" | tail -1 | awk '{print $NF}') || true
        # Extraer CN del subject — openssl moderno usa "CN = valor" con espacios
        ssl_cn=$(echo "${ssl_output}" | grep -i "subject"                  | grep -oP "CN\s*=\s*\K[^,/]+" | head -1 | tr -d ' ') || true

        if [[ -n "${ssl_proto}" ]]; then
            # openssl obtuvo el protocolo — resultado más completo
            _v_check "${nombre} TLS handshake" "ok" "${ssl_proto} — CN: ${ssl_cn:-?}"
        elif [[ "${https_ssl_verify}" == "0" && "${https_code}" != "000" && -n "${https_code}" ]]; then
            # curl confirmó TLS (ssl_verify_result=0 significa handshake exitoso con -k)
            _v_check "${nombre} TLS handshake" "ok" "(TLS activo — protocolo no detectado por openssl)"
        elif [[ "${https_code}" != "000" && -n "${https_code}" ]]; then
            # Hay respuesta HTTPS aunque no pudimos verificar el protocolo exacto
            _v_check "${nombre} TLS handshake" "warn" "(respuesta HTTPS recibida, no se pudo leer protocolo)"
        else
            _v_check "${nombre} TLS handshake" "warn" "(sin respuesta en puerto ${https_port})"
        fi

        echo ""
    done
}

# -----------------------------------------------------------------------------
# ssl_verify_todo
#
# Ejecuta todas las verificaciones en secuencia y muestra un resumen final
# con la tabla de estado de todos los servicios.
# -----------------------------------------------------------------------------
ssl_verify_todo() {
    clear
    ssl_mostrar_banner "Tarea 07 — Verificación General"

    aputs_info "Servidor: 192.168.100.10 (Fedora Server)"
    aputs_info "Fecha:    $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    draw_line

    ssl_verify_certificado
    draw_line

    ssl_verify_ftp
    draw_line

    ssl_verify_repositorio
    draw_line

    ssl_verify_http
    draw_line

    # Tabla resumen de puertos y SSL
    echo ""
    aputs_info "Resumen de servicios:"
    echo ""

    printf "  ${CYAN}%-12s %-10s %-10s %-8s %-10s${NC}\n" \
           "Servicio" "Puerto HTTP" "Puerto HTTPS" "SSL" "Estado"
    echo "  ──────────────────────────────────────────────────────"

    local servicios_info=(
        "vsftpd:21:-:FTP"
        "httpd:auto:auto:HTTP"
        "nginx:auto:auto:HTTP"
        "tomcat:auto:auto:HTTP"
    )

    for entrada in "${servicios_info[@]}"; do
        IFS=: read -r pkg p_http p_https tipo <<< "${entrada}"
        local nombre="${pkg}"

        if ! rpm -q "${pkg}" &>/dev/null 2>&1; then
            printf "  %-12s ${GRAY}%-10s %-10s %-8s %-10s${NC}\n" \
                   "${nombre}" "-" "-" "-" "no instalado"
            continue
        fi

        # Leer puertos reales
        if [[ "${p_http}" == "auto" ]]; then
            p_http=$(ssl_leer_puerto_http "${pkg}")
            p_https=$(ssl_leer_puerto_https "${pkg}")
        fi

        # Estado SSL — usar if/else en lugar de && || para evitar problemas con set -e
        local ssl_status="-"
        if [[ "${pkg}" == "vsftpd" ]]; then
            if grep -q "^ssl_enable=YES" "${SSL_CONF_VSFTPD}" 2>/dev/null; then
                ssl_status="${GREEN}YES${NC}"
            else
                ssl_status="${YELLOW}NO${NC}"
            fi
        elif [[ "${pkg}" == "httpd" ]]; then
            if [[ -f "${SSL_CONF_APACHE_SSL}" ]]; then
                ssl_status="${GREEN}YES${NC}"
            else
                ssl_status="${YELLOW}NO${NC}"
            fi
        elif [[ "${pkg}" == "nginx" ]]; then
            if grep -q "=== Practica7 SSL Nginx ===" "${SSL_CONF_NGINX}" 2>/dev/null; then
                ssl_status="${GREEN}YES${NC}"
            else
                ssl_status="${YELLOW}NO${NC}"
            fi
        elif [[ "${pkg}" == "tomcat" ]]; then
            if grep -q "Practica7 SSL" "$(SSL_CONF_TOMCAT)" 2>/dev/null; then
                ssl_status="${GREEN}YES${NC}"
            else
                ssl_status="${YELLOW}NO${NC}"
            fi
        fi

        # Estado del servicio
        local svc_status="${RED}inactivo${NC}"
        if systemctl is-active --quiet "${pkg}" 2>/dev/null; then
            svc_status="${GREEN}activo${NC}"
        fi

        printf "  %-12s %-10s %-10s " "${nombre}" "${p_http}" "${p_https}"
        echo -ne "${ssl_status}"
        printf "    "
        echo -e "${svc_status}"
    done

    echo ""
    draw_line
    echo ""
    aputs_success "Verificación completada"
    echo ""
}

# -----------------------------------------------------------------------------
# ssl_menu_verify — submenú interactivo del módulo de verificación
# -----------------------------------------------------------------------------
ssl_menu_verify() {
    while true; do
        clear
        ssl_mostrar_banner "Tarea 07 — Verificación y Testing"

        echo -e "  ${BLUE}1)${NC} Verificación general completa (recomendado)"
        echo -e "  ${BLUE}2)${NC} Verificar solo certificado SSL"
        echo -e "  ${BLUE}3)${NC} Verificar solo FTP (vsftpd + TLS)"
        echo -e "  ${BLUE}4)${NC} Verificar solo repositorio FTP"
        echo -e "  ${BLUE}5)${NC} Verificar solo servicios HTTP/HTTPS"
        echo -e "  ${BLUE}0)${NC} Volver"
        echo ""

        local op
        read -rp "  Opción: " op

        case "$op" in
            1) ssl_verify_todo;         pause ;;
            2) ssl_verify_certificado;  pause ;;
            3) ssl_verify_ftp;          pause ;;
            4) ssl_verify_repositorio;  pause ;;
            5) ssl_verify_http;         pause ;;
            0) return 0 ;;
            *) aputs_error "Opción inválida"; sleep 1 ;;
        esac
    done
}

export -f ssl_verify_certificado
export -f ssl_verify_ftp
export -f ssl_verify_repositorio
export -f ssl_verify_http
export -f ssl_verify_todo
export -f ssl_menu_verify
export -f _v_check