#!/bin/bash
#
# mainT07.sh — Orquestador principal de la practica
#
set -euo pipefail

# -----------------------------------------------------------------------------
# Rutas base — resueltas relativas a este archivo para portabilidad
# -----------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly P5_DIR="$(cd "${SCRIPT_DIR}/../p5" && pwd)"
readonly P6_DIR="$(cd "${SCRIPT_DIR}/../p6" && pwd)"
readonly SSL_DIR_LIB="${SCRIPT_DIR}"

# -----------------------------------------------------------------------------
# Verificar privilegios de root antes de cargar nada
# -----------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo ""
    echo "  [ERROR] Este script requiere privilegios de root."
    echo "  Ejecute: sudo bash ${BASH_SOURCE[0]}"
    echo ""
    exit 1
fi

# -----------------------------------------------------------------------------
# Verificar que las prácticas anteriores existen antes de cargar
# -----------------------------------------------------------------------------
_verificar_estructura() {
    local errores=0

    for dir in "${P5_DIR}" "${P6_DIR}" "${SSL_DIR_LIB}"; do
        if [[ ! -d "${dir}" ]]; then
            echo "  [ERROR] Directorio no encontrado: ${dir}"
            (( errores++ ))
        fi
    done

    local archivos_criticos=(
        "${P5_DIR}/utils.sh"
        "${P5_DIR}/utilsFTP.sh"
        "${P5_DIR}/validatorsFTP.sh"
        "${P5_DIR}/FunctionsFTP-A.sh"
        "${P5_DIR}/FunctionsFTP-B.sh"
        "${P5_DIR}/FunctionsFTP-C.sh"
        "${P5_DIR}/FunctionsFTP-D.sh"
        "${P6_DIR}/utilsHTTP.sh"
        "${P6_DIR}/validatorsHTTP.sh"
        "${P6_DIR}/FunctionsHTTP-A.sh"
        "${P6_DIR}/FunctionsHTTP-B.sh"
        "${P6_DIR}/FunctionsHTTP-C.sh"
        "${P6_DIR}/FunctionsHTTP-D.sh"
        "${P6_DIR}/FunctionsHTTP-E.sh"
        "${SSL_DIR_LIB}/utilsSSL.sh"
        "${SSL_DIR_LIB}/repoHTTP.sh"
        "${SSL_DIR_LIB}/certSSL.sh"
        "${SSL_DIR_LIB}/FTP-SSL.sh"
        "${SSL_DIR_LIB}/HTTP-SSL.sh"
        "${SSL_DIR_LIB}/verifySSL.sh"
    )

    for archivo in "${archivos_criticos[@]}"; do
        if [[ ! -f "${archivo}" ]]; then
            echo "  [ERROR] Archivo no encontrado: ${archivo}"
            (( errores++ ))
        fi
    done

    if (( errores > 0 )); then
        echo ""
        echo "  Verifique que las Prácticas 5, 6 y 7 están en:"
        echo "  /home/adminuser/scripts/{Practica5,Practica6,Practica7}"
        echo ""
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Cargar todos los módulos en orden de dependencia
# -----------------------------------------------------------------------------
_cargar_modulos() {
    # Práctica 5 — FTP
    # utils.sh es compartido entre prácticas; lo cargamos de P5
    source "${P5_DIR}/utils.sh"
    source "${P5_DIR}/utilsFTP.sh"
    source "${P5_DIR}/validatorsFTP.sh"
    source "${P5_DIR}/FunctionsFTP-A.sh"
    source "${P5_DIR}/FunctionsFTP-B.sh"
    source "${P5_DIR}/FunctionsFTP-C.sh"
    source "${P5_DIR}/FunctionsFTP-D.sh"

    # Práctica 6 — HTTP
    # utils.sh ya cargado; solo cargamos los módulos HTTP
    source "${P6_DIR}/utilsHTTP.sh"
    source "${P6_DIR}/validatorsHTTP.sh"
    source "${P6_DIR}/FunctionsHTTP-A.sh"
    source "${P6_DIR}/FunctionsHTTP-B.sh"
    source "${P6_DIR}/FunctionsHTTP-C.sh"
    source "${P6_DIR}/FunctionsHTTP-D.sh"
    source "${P6_DIR}/FunctionsHTTP-E.sh"

    # Práctica 7 — SSL/TLS (en orden de dependencia)
    source "${SSL_DIR_LIB}/utilsSSL.sh"   # constantes y helpers base
    source "${SSL_DIR_LIB}/repoHTTP.sh"    # repositorio FTP
    source "${SSL_DIR_LIB}/certSSL.sh"    # generación de certificado
    source "${SSL_DIR_LIB}/FTP-SSL.sh"     # FTPS en vsftpd
    source "${SSL_DIR_LIB}/HTTP-SSL.sh"    # HTTPS en Apache/Nginx/Tomcat
    source "${SSL_DIR_LIB}/verifySSL.sh"  # verificación y reporte

    # Inicializar grupos FTP si el servicio ya estaba instalado
    if declare -f _ftp_cargar_grupos &>/dev/null; then
        _ftp_cargar_grupos 2>/dev/null || true
    fi
}

#
# INDICADORES DE ESTADO
# Permiten mostrar en el menú si cada paso ya fue completado.
#

# Retorna el ícono de estado según si una condición es verdadera
_icono_estado() {
    local condicion="$1"  # "ok" o "no"
    if [[ "$condicion" == "ok" ]]; then
        echo -e "${GREEN}●${NC}"
    else
        echo -e "${RED}○${NC}"
    fi
}

# Evalúa el estado de cada paso para mostrarlo en el menú
_estado_ftp() {
    rpm -q vsftpd &>/dev/null && systemctl is-active --quiet vsftpd 2>/dev/null \
        && echo "ok" || echo "no"
}

_estado_ftps() {
    grep -q "^ssl_enable=YES" "${SSL_CONF_VSFTPD}" 2>/dev/null \
        && echo "ok" || echo "no"
}

_estado_repo() {
    local count
    count=$(find "${SSL_REPO_ROOT}" -name "*.rpm" 2>/dev/null | wc -l)
    (( count > 0 )) && echo "ok" || echo "no"
}

_estado_http() {
    ( ssl_servicio_instalado httpd || ssl_servicio_instalado nginx || \
      ssl_servicio_instalado tomcat ) && echo "ok" || echo "no"
}

_estado_ssl_http() {
    # Usar las mismas marcas que ssl_http_estado() para evitar falsos positivos.
    # nginx.conf base de Fedora ya contiene "ssl_certificate" en comentarios.
    # Solo consideramos SSL activo si está nuestra marca propia en cada archivo.
    local apache_ok=false nginx_ok=false tomcat_ok=false

    [[ -f "${SSL_CONF_APACHE_SSL}" ]] && apache_ok=true

    if grep -q "=== Practica7 SSL Nginx ===" "${SSL_CONF_NGINX}" 2>/dev/null; then
        nginx_ok=true
    fi

    local server_xml
    server_xml=$(SSL_CONF_TOMCAT 2>/dev/null)
    # Buscar la marca propia — el server.xml base de Tomcat puede tener
    # SSLEnabled="false" o comentarios con SSLEnabled que darían falso positivo
    if [[ -f "$server_xml" ]] && grep -q "Practica7 SSL" "$server_xml" 2>/dev/null; then
        tomcat_ok=true
    fi

    if $apache_ok || $nginx_ok || $tomcat_ok; then
        echo "ok"
    else
        echo "no"
    fi
}

_estado_cert() {
    ssl_cert_existe && echo "ok" || echo "no"
}

#
# PASOS DEL MENÚ
# Cada paso puede ejecutarse de forma independiente.
#

# -----------------------------------------------------------------------------
# Paso 1: Instalar y configurar FTP
# Llama directamente al menú de instalación de P5
# -----------------------------------------------------------------------------
_paso_1_ftp() {
    clear
    ssl_mostrar_banner "Paso 1 — Instalar y configurar FTP"

    aputs_info "Entrando al menú de instalación FTP (Práctica 5)..."
    echo ""
    pause

    # Llamar al submenú de instalación/servicio de P5
    if declare -f ftp_menu_instalacion &>/dev/null; then
        ftp_menu_instalacion
    else
        aputs_error "ftp_menu_instalacion no encontrada"
        aputs_info  "Verifique que FunctionsFTP-B.sh se cargó correctamente"
        pause
    fi
}

# -----------------------------------------------------------------------------
# Paso 2: Configurar FTPS/TLS (opcional)
# Genera el certificado (si no existe) y lo aplica a vsftpd
# -----------------------------------------------------------------------------
_paso_2_ftps() {
    clear
    ssl_mostrar_banner "Paso 2 — Configurar FTPS/TLS (opcional)"

    # Verificar que FTP está instalado primero
    if ! rpm -q vsftpd &>/dev/null; then
        aputs_error "vsftpd no está instalado"
        aputs_info  "Ejecute primero el Paso 1 — Instalar FTP"
        pause
        return
    fi

    echo ""
    echo -e "  ${CYAN}Este paso configurará:${NC}"
    echo "    • Certificado SSL autofirmado (si no existe)"
    echo "    • TLS explícito en vsftpd (puerto 21)"
    echo ""
    echo -ne "  ${YELLOW}[?]${NC} ¿Desea aplicar FTPS/TLS a vsftpd? [S/n]: "
    local resp
    read -r resp

    if [[ "$resp" =~ ^[nN]$ ]]; then
        aputs_info "FTPS omitido — puede configurarlo después desde el menú"
        pause
        return
    fi

    echo ""

    # Generar certificado si no existe
    if ! ssl_cert_existe; then
        aputs_info "El certificado no existe — generando..."
        echo ""
        ssl_cert_generar || { pause; return; }
        echo ""
    else
        aputs_info "Certificado ya existe — reutilizando"
        ssl_cert_mostrar_info
        echo ""
    fi

    # Aplicar TLS a vsftpd
    ssl_ftp_aplicar
    pause
}

# -----------------------------------------------------------------------------
# Paso 3: Crear repositorio FTP + usuario dedicado "repo"
# -----------------------------------------------------------------------------
_paso_3_repo_estructura() {
    clear
    ssl_mostrar_banner "Paso 3 — Repositorio FTP + usuario 'repo'"

    # Verificar que FTP está instalado
    if ! rpm -q vsftpd &>/dev/null; then
        aputs_error "vsftpd no está instalado"
        aputs_info  "Ejecute primero el Paso 1 — Instalar FTP"
        pause
        return
    fi

    # Crear estructura del repositorio
    aputs_info "Creando estructura del repositorio FTP..."
    echo ""
    ssl_repo_crear_estructura || { pause; return; }

    echo ""
    draw_line
    echo ""

    # Crear usuario dedicado "repo" como grupo especial FTP
    aputs_info "Configurando usuario dedicado 'repo'..."
    echo ""

    # El usuario se llama "repo" (sin prefijo).
    # vsftpd usa local_root=/srv/ftp/ftp_$USER → buscará /srv/ftp/ftp_repo.
    # Esa carpeta es la RAÍZ del chroot (root:root 755, no escribible).
    # El repositorio real queda montado dentro como subcarpeta "repositorio".
    local REPO_USER="repo"
    local REPO_CHROOT="${SSL_FTP_ROOT}/ftp_repo"          # raíz del chroot vsftpd
    local REPO_SUBDIR="${REPO_CHROOT}/repositorio"         # punto visible al conectar
    local REPO_REAL="${SSL_FTP_ROOT}/repositorio"          # datos reales

    # Corrección PAM 
    # /etc/pam.d/vsftpd tiene pam_shells.so que rechaza /sbin/nologin.
    # La solución más limpia es agregar /sbin/nologin a /etc/shells,
    # que indica al sistema que es una shell válida para usuarios de servicio.
    if ! grep -qx "/sbin/nologin" /etc/shells 2>/dev/null; then
        echo "/sbin/nologin" >> /etc/shells
        aputs_success "Agregado /sbin/nologin a /etc/shells (fix PAM vsftpd)"
    else
        aputs_info "/sbin/nologin ya está en /etc/shells"
    fi
    echo ""

    # Crear usuario del sistema 
    if id "${REPO_USER}" &>/dev/null; then
        aputs_info "El usuario '${REPO_USER}' ya existe"
    else
        aputs_info "Creando usuario '${REPO_USER}' (sin shell, chroot en ${REPO_CHROOT})..."

        # -r           : usuario del sistema (UID < 1000, sin directorio home creado)
        # -d CHROOT    : home = raíz del chroot que vsftpd espera
        # -s /sbin/nologin : sin shell interactiva (no puede hacer SSH)
        # -M           : NO crear el home automáticamente (lo creamos a mano)
        useradd -r -M -d "${REPO_CHROOT}" -s /sbin/nologin "${REPO_USER}" 2>/dev/null

        if id "${REPO_USER}" &>/dev/null; then
            aputs_success "Usuario '${REPO_USER}' creado"
        else
            aputs_error "No se pudo crear el usuario '${REPO_USER}'"
            pause
            return
        fi
    fi

    # Crear estructura de directorios del chroot 
    # REGLA CRÍTICA de vsftpd con chroot_local_user=YES:
    #   La raíz del chroot (REPO_CHROOT) debe ser propiedad de root
    #   y NO tener permisos de escritura para nadie más.
    #   Si el propietario puede escribir → vsftpd rechaza la conexión.
    aputs_info "Creando estructura de chroot en ${REPO_CHROOT}..."

    # Raíz del chroot: root:root 755 (obligatorio para vsftpd)
    mkdir -p "${REPO_CHROOT}"
    chown root:root "${REPO_CHROOT}"
    chmod 755 "${REPO_CHROOT}"
    aputs_success "Raíz del chroot: ${REPO_CHROOT} (root:root 755)"

    # Subcarpeta "repositorio" dentro del chroot donde el usuario puede leer
    # Usamos bind mount para que apunte a los datos reales
    mkdir -p "${REPO_SUBDIR}"
    chown root:ftp "${REPO_SUBDIR}"
    chmod 755 "${REPO_SUBDIR}"

    # Montar el repositorio real dentro del chroot (bind mount)
    if mountpoint -q "${REPO_SUBDIR}" 2>/dev/null; then
        aputs_info "Bind mount ya activo en ${REPO_SUBDIR}"
    else
        if mount --bind "${REPO_REAL}" "${REPO_SUBDIR}" 2>/dev/null; then
            aputs_success "Bind mount: ${REPO_REAL} → ${REPO_SUBDIR}"
        else
            aputs_warning "bind mount falló — enlace simbólico como alternativa"
            rmdir "${REPO_SUBDIR}" 2>/dev/null
            ln -sfn "${REPO_REAL}" "${REPO_SUBDIR}"
            aputs_success "Symlink creado: ${REPO_SUBDIR} → ${REPO_REAL}"
        fi
    fi

    # Hacer el bind mount persistente en /etc/fstab
    local FSTAB_ENTRY="${REPO_REAL}  ${REPO_SUBDIR}  none  bind  0 0"
    if ! grep -qF "${REPO_SUBDIR}" /etc/fstab 2>/dev/null; then
        echo "# Practica7 — repositorio FTP (bind mount)" >> /etc/fstab
        echo "${FSTAB_ENTRY}" >> /etc/fstab
        aputs_success "Bind mount agregado a /etc/fstab (persistente)"
    else
        aputs_info "Entrada en /etc/fstab ya existe"
    fi
    echo ""

    # Contexto SELinux 
    if command -v restorecon &>/dev/null; then
        restorecon -Rv "${REPO_CHROOT}" &>/dev/null
        aputs_success "Contexto SELinux aplicado a ${REPO_CHROOT}"
    fi

    # Asignar contraseña
    echo -ne "  ${CYAN}[INPUT]${NC} Contraseña para el usuario '${REPO_USER}': "
    local pass
    read -rs pass
    echo ""

    if [[ -z "${pass}" ]]; then
        pass="reprobados"
        aputs_warning "Contraseña vacía — usando default: reprobados"
    fi

    echo "${REPO_USER}:${pass}" | chpasswd 2>/dev/null \
        && aputs_success "Contraseña configurada" \
        || aputs_warning "No se pudo configurar contraseña (chpasswd)"

    echo ""
    draw_line
    echo ""
    aputs_success "Paso 3 completado"
    printf "  %-22s %s\n" "Usuario FTP:"    "${REPO_USER}"
    printf "  %-22s %s\n" "Raíz chroot:"    "${REPO_CHROOT}  (root:root 755)"
    printf "  %-22s %s\n" "Repositorio:"    "${REPO_SUBDIR}  (bind → ${REPO_REAL})"
    printf "  %-22s %s\n" "Acceso FTP:"     "ftp://192.168.100.10  usuario: ${REPO_USER}"
    printf "  %-22s %s\n" "Navegar a:"      "/repositorio/http/Linux/{Apache,Nginx,Tomcat}"
    echo ""

    pause
}

# -----------------------------------------------------------------------------
# Paso 4: Descargar RPMs al repositorio
# -----------------------------------------------------------------------------
_paso_4_descargar_rpms() {
    clear
    ssl_mostrar_banner "Paso 4 — Descargar RPMs al repositorio"

    if [[ ! -d "${SSL_REPO_ROOT}" ]]; then
        aputs_error "El repositorio no existe"
        aputs_info  "Ejecute primero el Paso 3 — Crear repositorio"
        pause
        return
    fi

    # Submenú de descarga
    while true; do
        clear
        ssl_mostrar_banner "Paso 4 — Descargar RPMs"
        ssl_repo_listar

        echo -e "  ${BLUE}1)${NC} Descargar todos (Apache + Nginx + Tomcat)"
        echo -e "  ${BLUE}2)${NC} Descargar solo Apache (httpd)"
        echo -e "  ${BLUE}3)${NC} Descargar solo Nginx"
        echo -e "  ${BLUE}4)${NC} Descargar solo Tomcat"
        echo -e "  ${BLUE}5)${NC} Verificar integridad (SHA256)"
        echo -e "  ${BLUE}0)${NC} Volver al menú principal"
        echo ""

        local op
        read -rp "  Opción: " op

        case "$op" in
            1) ssl_repo_descargar_todos;               pause ;;
            2) ssl_repo_descargar_paquete "httpd";     pause ;;
            3) ssl_repo_descargar_paquete "nginx";     pause ;;
            4) ssl_repo_descargar_paquete "tomcat";    pause ;;
            5) ssl_repo_verificar_integridad;          pause ;;
            0) return ;;
            *) aputs_error "Opción inválida"; sleep 1 ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Paso 5: Instalar y configurar HTTP
# Llama directamente al menú de instalación de P6
# -----------------------------------------------------------------------------
_paso_5_http() {
    clear
    ssl_mostrar_banner "Paso 5 — Instalar y configurar HTTP"

    aputs_info "Entrando al menú de instalación HTTP (Práctica 6)..."
    echo ""

    # Mostrar los RPMs disponibles en el repositorio antes de instalar
    if [[ -d "${SSL_REPO_ROOT}" ]]; then
        aputs_info "RPMs disponibles en el repositorio FTP:"
        echo ""
        find "${SSL_REPO_ROOT}" -name "*.rpm" 2>/dev/null \
            | while read -r rpm; do
                printf "    %s\n" "$(basename "${rpm}")"
            done
        echo ""
        draw_line
        echo ""
    fi

    pause

    # Llamar al submenú de instalación HTTP de P6
    if declare -f http_menu_instalar &>/dev/null; then
        http_menu_instalar
    else
        aputs_error "http_menu_instalar no encontrada"
        aputs_info  "Verifique que FunctionsHTTP-B.sh se cargó correctamente"
        pause
    fi
}

# -----------------------------------------------------------------------------
# Paso 6: Configurar SSL/HTTPS (opcional)
# Genera el certificado (si no existe) y lo aplica a los servicios HTTP
# -----------------------------------------------------------------------------
_paso_6_ssl_http() {
    clear
    ssl_mostrar_banner "Paso 6 — Configurar SSL/HTTPS (opcional)"

    # Verificar que hay al menos un servicio HTTP instalado
    if ! ( ssl_servicio_instalado httpd || ssl_servicio_instalado nginx || \
           ssl_servicio_instalado tomcat ); then
        aputs_error "No hay servicios HTTP instalados"
        aputs_info  "Ejecute primero el Paso 5 — Instalar HTTP"
        pause
        return
    fi

    echo ""
    echo -e "  ${CYAN}Este paso configurará:${NC}"
    echo "    • Certificado SSL autofirmado (si no existe)"
    echo "    • HTTPS en los servicios HTTP instalados"
    echo "    • Redirect HTTP → HTTPS"
    echo ""
    echo -ne "  ${YELLOW}[?]${NC} ¿Desea aplicar SSL/HTTPS? [S/n]: "
    local resp
    read -r resp

    if [[ "$resp" =~ ^[nN]$ ]]; then
        aputs_info "SSL/HTTPS omitido — puede configurarlo después desde el menú"
        pause
        return
    fi

    echo ""

    # Generar certificado si no existe
    if ! ssl_cert_existe; then
        aputs_info "El certificado no existe — generando..."
        echo ""
        ssl_cert_generar || { pause; return; }
        echo ""
    else
        aputs_info "Certificado ya existe — reutilizando"
        ssl_cert_mostrar_info
        echo ""
    fi

    # Aplicar SSL a los servicios HTTP instalados
    ssl_http_aplicar_todos
    pause
}

# -----------------------------------------------------------------------------
# Paso 7: Testing general
# -----------------------------------------------------------------------------
_paso_7_testing() {
    ssl_verify_todo
    pause
}

#
# MENÚ PRINCIPAL
#

_dibujar_menu() {
    clear

    # Estados de cada paso
    local s1=$(_icono_estado "$(_estado_ftp)")
    local s2=$(_icono_estado "$(_estado_ftps)")
    local s3=$(_icono_estado "$(
        [[ -d "${SSL_REPO_ROOT}" ]] && echo "ok" || echo "no"
    )")
    local s4=$(_icono_estado "$(_estado_repo)")
    local s5=$(_icono_estado "$(_estado_http)")
    local s6=$(_icono_estado "$(_estado_ssl_http)")
    local s_cert=$(_icono_estado "$(_estado_cert)")

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}   Tarea 07 — Infraestructura Segura FTP/HTTP     ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""

    # Indicador de certificado global
    echo -e "  Certificado SSL: ${s_cert}"
    echo ""

    echo -e "  ${GRAY}── Fase FTP ─────────────────────────────────────${NC}"
    echo -e "  ${BLUE}1)${NC} ${s1} Instalar y configurar FTP"
    echo -e "  ${BLUE}2)${NC} ${s2} Configurar FTPS/TLS         ${GRAY}(requiere paso 1)${NC}"
    echo ""

    echo -e "  ${GRAY}── Fase Repositorio ─────────────────────────────${NC}"
    echo -e "  ${BLUE}3)${NC} ${s3} Crear repositorio + usuario 'repo' ${GRAY}(req. paso 1)${NC}"
    echo -e "  ${BLUE}4)${NC} ${s4} Descargar RPMs al repositorio ${GRAY}(req. paso 3)${NC}"
    echo ""

    echo -e "  ${GRAY}── Fase HTTP ────────────────────────────────────${NC}"
    echo -e "  ${BLUE}5)${NC} ${s5} Instalar y configurar HTTP"
    echo -e "  ${BLUE}6)${NC} ${s6} Configurar SSL/HTTPS         ${GRAY}(requiere paso 5)${NC}"
    echo ""

    echo -e "  ${GRAY}── Extras ───────────────────────────────────────${NC}"
    echo -e "  ${BLUE}7)${NC}    Testing general completo"
    echo -e "  ${BLUE}f)${NC}    Menú completo FTP           ${GRAY}(Práctica 5)${NC}"
    echo -e "  ${BLUE}h)${NC}    Menú completo HTTP          ${GRAY}(Práctica 6)${NC}"
    echo -e "  ${BLUE}c)${NC}    Gestionar certificado SSL"
    echo -e "  ${BLUE}r)${NC}    Menú repositorio FTP"
    echo ""
    echo -e "  ${BLUE}0)${NC}    Salir"
    echo ""
}

main_menu() {
    while true; do
        _dibujar_menu

        local op
        read -rp "  Opción: " op

        case "$op" in
            1) _paso_1_ftp              ;;
            2) _paso_2_ftps             ;;
            3) _paso_3_repo_estructura  ;;
            4) _paso_4_descargar_rpms   ;;
            5) _paso_5_http             ;;
            6) _paso_6_ssl_http         ;;
            7) _paso_7_testing          ;;

            # Acceso a los menús completos de prácticas anteriores
            f|F)
                if declare -f main_menu_ftp &>/dev/null; then
                    main_menu_ftp
                else
                    # Llamar al menú principal de mainFTP.sh directamente
                    bash "${P5_DIR}/mainFTP.sh" 2>/dev/null \
                        || { aputs_error "No se pudo abrir mainFTP.sh"; pause; }
                fi
                ;;
            h|H)
                if declare -f main_menu_http &>/dev/null; then
                    main_menu_http
                else
                    bash "${P6_DIR}/mainHTTP.sh" 2>/dev/null \
                        || { aputs_error "No se pudo abrir mainHTTP.sh"; pause; }
                fi
                ;;
            c|C) ssl_menu_cert          ;;
            r|R) ssl_menu_repo          ;;

            0)
                echo ""
                aputs_info "Saliendo de la Práctica 7..."
                echo ""
                exit 0
                ;;
            *)
                aputs_error "Opción inválida"
                sleep 1
                ;;
        esac
    done
}

#
# Punto de entrada
#

_verificar_estructura
_cargar_modulos
main_menu