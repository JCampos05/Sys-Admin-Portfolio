#!/bin/bash
# 
# ssl/ssl_cert.sh — Generación del certificado autofirmado compartido
#
# Propósito:
#   Generar el par clave/certificado RSA autofirmado que comparten todos
#   los servicios (Apache, Nginx, Tomcat, vsftpd) de la Práctica 7.
#
#   El certificado se genera una sola vez y vive en /etc/ssl/reprobados/.
#   Los módulos ssl_ftp.sh y ssl_http.sh lo referencian directamente.
#
#   ssl_cert_generar()       — genera clave + certificado con openssl
#   ssl_cert_mostrar_info()  — muestra detalles del certificado existente
#   ssl_cert_agregar_hosts() — añade reprobados.com a /etc/hosts
#   ssl_menu_cert()          — submenú interactivo
#
# Requiere:
#   utils.sh, ssl_utils.sh cargados previamente
# 

[[ -n "${_SSL_CERT_LOADED:-}" ]] && return 0
readonly _SSL_CERT_LOADED=1

# -----------------------------------------------------------------------------
# ssl_cert_generar
#
# Genera el par clave privada + certificado X.509 autofirmado.
# Si ya existe el certificado pregunta si se quiere regenerar.
#
# Decisiones de diseño:
#   -x509        : certificado autofirmado (no CSR para CA externa)
#   -nodes       : sin passphrase en la clave (los servicios arrancan solos)
#   -days 365    : validez de 1 año (ajustable con SSL_DAYS)
#   -newkey rsa:2048 : genera clave RSA nueva en el mismo comando
#   -subj        : evita el prompt interactivo de openssl
# -----------------------------------------------------------------------------
ssl_cert_generar() {
    ssl_mostrar_banner "SSL — Generar Certificado"

    # Verificar que openssl está disponible
    if ! command -v openssl &>/dev/null; then
        aputs_error "openssl no encontrado"
        aputs_info  "Instalar con: dnf install openssl -y"
        return 1
    fi

    # Si ya existe el certificado, preguntar antes de sobrescribir
    if ssl_cert_existe; then
        aputs_warning "Ya existe un certificado en ${SSL_DIR}"
        echo ""
        ssl_cert_mostrar_info
        echo ""
        echo -ne "${YELLOW}[?]${NC} ¿Desea regenerarlo? Se perderá el actual [s/N]: "
        local resp
        read -r resp
        [[ ! "$resp" =~ ^[sS]$ ]] && return 0
        echo ""
    fi

    # Crear directorio con permisos restrictivos
    aputs_info "Preparando directorio ${SSL_DIR}..."
    if ! mkdir -p "${SSL_DIR}"; then
        aputs_error "No se pudo crear ${SSL_DIR}"
        return 1
    fi
    chmod 700 "${SSL_DIR}"
    aputs_success "Directorio listo"
    echo ""

    # Personalización del certificado 
    # Mostrar los valores por defecto y preguntar si el usuario quiere cambiarlos.
    # Si responde N o Enter, usa los valores de utilsSSL.sh sin modificación.
    echo ""
    aputs_info "Datos del certificado (valores por defecto de utilsSSL.sh):"
    echo ""
    printf "  ${CYAN}%-5s${NC} %-20s %s\n" "[CN]"  "Dominio:"      "${SSL_DOMAIN}"
    printf "  ${CYAN}%-5s${NC} %-20s %s\n" "[O]"   "Organización:" "Administracion de Sistemas"
    printf "  ${CYAN}%-5s${NC} %-20s %s\n" "[OU]"  "Unidad:"       "Practica7"
    printf "  ${CYAN}%-5s${NC} %-20s %s\n" "[C]"   "País:"         "MX"
    printf "  ${CYAN}%-5s${NC} %-20s %s\n" "[ST]"  "Estado:"       "Mexico"
    printf "  ${CYAN}%-5s${NC} %-20s %s\n" "[L]"   "Ciudad:"       "Mexico City"
    printf "  ${CYAN}%-5s${NC} %-20s %s\n" ""      "Validez:"      "${SSL_DAYS} días"
    printf "  ${CYAN}%-5s${NC} %-20s %s\n" ""      "Clave RSA:"    "${SSL_KEY_BITS} bits"
    echo ""

    echo -ne "  ${YELLOW}[?]${NC} ¿Personalizar los datos del certificado? [s/N]: "
    local personalizar
    read -r personalizar

    # Valores que se usarán — inicializados con los defaults de utilsSSL.sh
    local cert_cn="${SSL_DOMAIN}"
    local cert_o="Administracion de Sistemas"
    local cert_ou="Practica7"
    local cert_c="MX"
    local cert_st="Mexico"
    local cert_l="Mexico City"
    local cert_days="${SSL_DAYS}"

    if [[ "$personalizar" =~ ^[sS]$ ]]; then
        echo ""
        aputs_info "Ingresa el valor deseado o presiona Enter para conservar el default:"
        echo ""

        local _tmp
        echo -ne "  Dominio / CN   [${cert_cn}]: "
        read -r _tmp; [[ -n "$_tmp" ]] && cert_cn="$_tmp"

        echo -ne "  Organización   [${cert_o}]: "
        read -r _tmp; [[ -n "$_tmp" ]] && cert_o="$_tmp"

        echo -ne "  Unidad / OU    [${cert_ou}]: "
        read -r _tmp; [[ -n "$_tmp" ]] && cert_ou="$_tmp"

        echo -ne "  País (2 letras) [${cert_c}]: "
        read -r _tmp; [[ -n "$_tmp" ]] && cert_c="${_tmp:0:2}"

        echo -ne "  Estado         [${cert_st}]: "
        read -r _tmp; [[ -n "$_tmp" ]] && cert_st="$_tmp"

        echo -ne "  Ciudad         [${cert_l}]: "
        read -r _tmp; [[ -n "$_tmp" ]] && cert_l="$_tmp"

        echo -ne "  Validez (días) [${cert_days}]: "
        read -r _tmp
        if [[ -n "$_tmp" && "$_tmp" =~ ^[0-9]+$ ]]; then
            cert_days="$_tmp"
        fi

        echo ""
        draw_line
        aputs_info "Certificado que se generará:"
        echo ""
        printf "  %-20s %s\n" "Dominio (CN):"   "${cert_cn}"
        printf "  %-20s %s\n" "Organización:"   "${cert_o}"
        printf "  %-20s %s\n" "Unidad (OU):"    "${cert_ou}"
        printf "  %-20s %s\n" "País:"           "${cert_c}"
        printf "  %-20s %s\n" "Estado:"         "${cert_st}"
        printf "  %-20s %s\n" "Ciudad:"         "${cert_l}"
        printf "  %-20s %s\n" "Validez:"        "${cert_days} días"
        echo ""
        echo -ne "  ${YELLOW}[?]${NC} ¿Confirmar y generar? [S/n]: "
        local confirmar
        read -r confirmar
        [[ "$confirmar" =~ ^[nN]$ ]] && return 0
        draw_line
    fi

    # Construir el subject con los valores elegidos (default o personalizados)
    local subject_final="/C=${cert_c}/ST=${cert_st}/L=${cert_l}/O=${cert_o}/OU=${cert_ou}/CN=${cert_cn}"

    echo ""
    aputs_info "Generando certificado..."
    aputs_info "Subject: ${subject_final}"
    echo ""

    # Actualizar /etc/hosts con el CN elegido si es diferente al default
    if [[ "$cert_cn" != "${SSL_DOMAIN}" ]]; then
        aputs_info "CN personalizado detectado: ${cert_cn}"
        aputs_info "Se agregará entrada en /etc/hosts para: ${cert_cn}"
    fi

    # El comando central — genera clave y certificado en una sola llamada
    if openssl req -x509 \
        -nodes \
        -days    "${cert_days}" \
        -newkey  "rsa:${SSL_KEY_BITS}" \
        -keyout  "${SSL_KEY}" \
        -out     "${SSL_CERT}" \
        -subj    "${subject_final}" 2>&1 | sed 's/^/    /'; then
        echo ""
    else
        aputs_error "Error al ejecutar openssl req"
        return 1
    fi

    # Verificar que los archivos se crearon correctamente
    if [[ ! -f "${SSL_CERT}" || ! -f "${SSL_KEY}" ]]; then
        aputs_error "openssl no generó los archivos esperados"
        return 1
    fi

    # Permisos estrictos:
    #   .key -> 600: solo root puede leerla (nunca exponer la clave privada)
    #   .crt -> 644: legible por los servicios (httpd, nginx, vsftpd corren como root)
    chmod 600 "${SSL_KEY}"
    chmod 644 "${SSL_CERT}"
    chown root:root "${SSL_KEY}" "${SSL_CERT}"

    aputs_success "Certificado generado:"
    echo ""
    printf "  %-12s %s\n" "Certificado:" "${SSL_CERT}"
    printf "  %-12s %s\n" "Clave:"       "${SSL_KEY}"
    echo ""

    # Añadir entrada en /etc/hosts con el CN real del certificado generado
    # (puede ser el default SSL_DOMAIN o uno personalizado)
    local cn_real
    cn_real=$(openssl x509 -in "${SSL_CERT}" -noout -subject 2>/dev/null \
              | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1) || true
    [[ -z "$cn_real" ]] && cn_real="${SSL_DOMAIN}"
    ssl_cert_agregar_hosts "$cn_real"

    echo ""
    aputs_success "Certificado listo — puede aplicarse a FTP y HTTP"
    return 0
}

# -----------------------------------------------------------------------------
# ssl_cert_mostrar_info
#
# Muestra los campos principales del certificado existente usando openssl.
# Función de solo lectura — no modifica nada.
# -----------------------------------------------------------------------------
ssl_cert_mostrar_info() {
    if ! ssl_cert_existe; then
        aputs_warning "No existe certificado en ${SSL_DIR}"
        aputs_info    "Ejecute la opción 1 para generarlo"
        return 1
    fi

    aputs_info "Información del certificado:"
    echo ""

    # Extraer campos individuales con openssl x509
    local subject issuer not_before not_after cn

    subject=$(openssl x509 -in "${SSL_CERT}" -noout -subject    2>/dev/null | sed 's/subject=//')
    issuer=$(openssl x509  -in "${SSL_CERT}" -noout -issuer     2>/dev/null | sed 's/issuer=//')
    not_before=$(openssl x509 -in "${SSL_CERT}" -noout -startdate 2>/dev/null | sed 's/notBefore=//')
    not_after=$(openssl x509  -in "${SSL_CERT}" -noout -enddate   2>/dev/null | sed 's/notAfter=//')
    cn=$(openssl x509 -in "${SSL_CERT}" -noout -subject 2>/dev/null \
         | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1)

    printf "  ${CYAN}%-16s${NC} %s\n" "CN:"         "${cn}"
    printf "  ${CYAN}%-16s${NC} %s\n" "Subject:"    "${subject}"
    printf "  ${CYAN}%-16s${NC} %s\n" "Issuer:"     "${issuer}"
    printf "  ${CYAN}%-16s${NC} %s\n" "Válido desde:" "${not_before}"
    printf "  ${CYAN}%-16s${NC} %s\n" "Válido hasta:" "${not_after}"
    echo ""

    # Verificar si el certificado está expirado
    if openssl x509 -in "${SSL_CERT}" -noout -checkend 0 &>/dev/null; then
        aputs_success "Certificado VIGENTE"
    else
        aputs_error   "Certificado EXPIRADO — regenere con opción 1"
    fi

    # Mostrar fingerprint para referencia
    local fp
    fp=$(openssl x509 -in "${SSL_CERT}" -noout -fingerprint -sha256 2>/dev/null \
         | sed 's/sha256 Fingerprint=//')
    echo ""
    printf "  ${CYAN}%-16s${NC} %s\n" "SHA256 FP:" "${fp}"
}

# -----------------------------------------------------------------------------
# ssl_cert_agregar_hosts
#
# Añade "127.0.0.1  reprobados.com" a /etc/hosts si no existe ya.
# Esto permite que curl y los navegadores resuelvan el dominio localmente
# sin depender de DNS externo.
# -----------------------------------------------------------------------------
ssl_cert_agregar_hosts() {
    # Acepta un CN opcional — si no se pasa usa SSL_DOMAIN
    local dominio="${1:-${SSL_DOMAIN}}"
    local entrada="127.0.0.1  ${dominio}"

    if grep -q "${dominio}" /etc/hosts 2>/dev/null; then
        aputs_info "/etc/hosts ya contiene entrada para ${dominio}"
        return 0
    fi

    echo "" >> /etc/hosts
    echo "# Practica7 — SSL/TLS" >> /etc/hosts
    echo "${entrada}" >> /etc/hosts

    aputs_success "Añadido a /etc/hosts: ${entrada}"
}

# -----------------------------------------------------------------------------
# ssl_menu_cert — submenú interactivo del módulo certificado
# -----------------------------------------------------------------------------
ssl_menu_cert() {
    while true; do
        clear
        ssl_mostrar_banner "Tarea 07 — Certificado SSL/TLS"

        # Indicador de estado
        if ssl_cert_existe; then
            echo -e "  Estado: ${GREEN}[● Certificado generado]${NC}"
        else
            echo -e "  Estado: ${RED}[○ Sin certificado]${NC}"
        fi
        echo ""

        echo -e "  ${BLUE}1)${NC} Generar certificado autofirmado"
        echo -e "  ${BLUE}2)${NC} Ver información del certificado"
        echo -e "  ${BLUE}3)${NC} Verificar entrada en /etc/hosts"
        echo -e "  ${BLUE}0)${NC} Volver"
        echo ""

        local op
        read -rp "  Opción: " op

        case "$op" in
            1) ssl_cert_generar;        pause ;;
            2) ssl_cert_mostrar_info;   pause ;;
            3)
                echo ""
                aputs_info "Entradas de ${SSL_DOMAIN} en /etc/hosts:"
                echo ""
                grep "${SSL_DOMAIN}" /etc/hosts || echo "  (no encontrado)"
                pause
                ;;
            0) return 0 ;;
            *) aputs_error "Opción inválida"; sleep 1 ;;
        esac
    done
}

export -f ssl_cert_generar
export -f ssl_cert_mostrar_info
export -f ssl_cert_agregar_hosts
export -f ssl_menu_cert