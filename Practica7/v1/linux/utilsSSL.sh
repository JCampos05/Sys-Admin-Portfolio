#!/bin/bash
#
# ssl/ssl_utils.sh — Constantes globales y helpers compartidos para SSL/TLS
#

# -----------------------------------------------------------------------------
# Guardia de doble carga
# Evita redefinir constantes si otro módulo ya hizo source de este archivo
# -----------------------------------------------------------------------------
[[ -n "${_SSL_UTILS_LOADED:-}" ]] && return 0
readonly _SSL_UTILS_LOADED=1

# -----------------------------------------------------------------------------
# Constantes de certificado
# -----------------------------------------------------------------------------

# Directorio donde viven el certificado y la llave privada.
# Todos los servicios (Apache, Nginx, Tomcat, vsftpd) apuntan aquí.
readonly SSL_DIR="/etc/ssl/reprobados"

# Ruta completa del certificado público (se puede compartir)
readonly SSL_CERT="${SSL_DIR}/reprobados.crt"

# Ruta completa de la llave privada (permisos 600, solo root la lee)
readonly SSL_KEY="${SSL_DIR}/reprobados.key"

# Nombre de dominio que irá en el campo CN del certificado.
# Debe coincidir con lo que verifica la rúbrica: reprobados.com
readonly SSL_DOMAIN="reprobados.com"

# Días de validez del certificado autofirmado
readonly SSL_DAYS=365

# Tamaño de la clave RSA en bits (2048 es el mínimo aceptable hoy)
readonly SSL_KEY_BITS=2048

# Datos del sujeto del certificado (subject DN).
# openssl los usa en el campo -subj para no mostrar el prompt interactivo.
readonly SSL_SUBJECT="/C=MX/ST=Mexico/L=Mexico City/O=Administracion de Sistemas/OU=Practica7/CN=${SSL_DOMAIN}"

# -----------------------------------------------------------------------------
# Constantes del repositorio FTP
# -----------------------------------------------------------------------------

# Raíz del servidor FTP (definida en ftp.sh — la redeclaramos aquí como
# referencia local para no depender del orden de carga de ftp.sh)
readonly SSL_FTP_ROOT="/srv/ftp"

# Ruta donde vivirán los paquetes del repositorio
readonly SSL_REPO_ROOT="${SSL_FTP_ROOT}/repositorio"

# Subdirectorio para paquetes Linux dentro del repositorio
readonly SSL_REPO_LINUX="${SSL_REPO_ROOT}/http/Linux"

# Subcarpetas por servicio dentro de Linux/
# El script crea estas carpetas si no existen
readonly SSL_REPO_APACHE="${SSL_REPO_LINUX}/Apache"
readonly SSL_REPO_NGINX="${SSL_REPO_LINUX}/Nginx"
readonly SSL_REPO_TOMCAT="${SSL_REPO_LINUX}/Tomcat"

# -----------------------------------------------------------------------------
# Constantes de puertos SSL
# Los servicios HTTP ya tienen su puerto HTTP (elegido en práctica 6).
# El puerto HTTPS se deriva sumando 363 al puerto base, con excepciones:
#   - Si el puerto base es 80  -> HTTPS en 443  (estándar)
#   - Si el puerto base es 8080 -> HTTPS en 8443 (convención Tomcat/Nginx)
#   - Cualquier otro -> puerto_base + 363
# ssl_puerto_https() implementa esta lógica.
# -----------------------------------------------------------------------------

# Puerto HTTPS estándar para Apache cuando usa puerto 80
readonly SSL_PUERTO_HTTPS_APACHE=443

# Puerto HTTPS convencional para Nginx y Tomcat
readonly SSL_PUERTO_HTTPS_ALT=8443

# Puerto HTTPS de Tomcat cuando Nginx ya ocupa 8443
readonly SSL_PUERTO_HTTPS_TOMCAT=8444

# -----------------------------------------------------------------------------
# Constantes de configuración de servicios
# (rutas que ya conocen los módulos HTTP de práctica 6,
#  replicadas aquí para que ssl_http.sh no dependa del orden de carga)
# -----------------------------------------------------------------------------

readonly SSL_CONF_APACHE="/etc/httpd/conf/httpd.conf"
readonly SSL_CONF_APACHE_SSL="/etc/httpd/conf.d/ssl_reprobados.conf"
readonly SSL_CONF_NGINX="/etc/nginx/nginx.conf"
readonly SSL_CONF_VSFTPD="/etc/vsftpd/vsftpd.conf"

# server.xml de Tomcat — depende de CATALINA_HOME
# Se evalúa en tiempo de ejecución, no como readonly
SSL_CONF_TOMCAT() {
    local catalina="${CATALINA_HOME:-/usr/share/tomcat}"
    echo "${catalina}/conf/server.xml"
}

# Keystore de Java para Tomcat HTTPS
SSL_KEYSTORE_TOMCAT() {
    local catalina="${CATALINA_HOME:-/usr/share/tomcat}"
    echo "${catalina}/conf/reprobados.p12"
}

# -----------------------------------------------------------------------------
# Helpers de estado — funciones pequeñas de consulta (sin efectos secundarios)
# -----------------------------------------------------------------------------

# ssl_cert_existe
# Retorna 0 si el par clave+certificado ya fue generado, 1 si falta alguno.
# Uso: ssl_cert_existe && aputs_info "Cert OK" || aputs_error "Falta cert"
ssl_cert_existe() {
    [[ -f "${SSL_CERT}" && -f "${SSL_KEY}" ]]
}

# ssl_servicio_instalado  <nombre_systemd>
# Retorna 0 si el paquete RPM está instalado en el sistema.
# Uso: ssl_servicio_instalado httpd && echo "Apache presente"
ssl_servicio_instalado() {
    local paquete="$1"
    rpm -q "$paquete" &>/dev/null
}

# ssl_servicio_activo  <nombre_systemd>
# Retorna 0 si el servicio está corriendo en este momento.
ssl_servicio_activo() {
    local svc="$1"
    systemctl is-active --quiet "$svc" 2>/dev/null
}

# ssl_puerto_https  <puerto_http>
# Dado el puerto HTTP actual de un servicio, devuelve el puerto HTTPS
# que el script debe configurar, siguiendo la convención:
#   80   -> 443
#   8080 -> 8443
#   otro -> puerto + 363  (ej: 8081 -> 8444)
#
# Por qué 363: es el delta estándar entre 80↔443. Mantiene la relación
# semántica HTTP/HTTPS sin pisar puertos ya usados en este entorno.
#
# Uso: https_port=$(ssl_puerto_https 8080)  -> "8443"
ssl_puerto_https() {
    local http_port="$1"
    case "$http_port" in
        80)   echo "443"  ;;
        8080) echo "8443" ;;
        *)    echo $(( http_port + 363 )) ;;
    esac
}

# ssl_leer_puerto_http  <servicio>
# Lee el puerto HTTP activo de un servicio desde su archivo de configuración.
# Devuelve el número de puerto o el default si no lo encuentra.
#
# Delega en la función _http_leer_puerto_config de FunctionsHTTP-C.sh
# si está disponible; si no, usa grep directo como fallback.
ssl_leer_puerto_http() {
    local servicio="$1"

    # Intentar con la función de práctica 6 si está cargada
    if declare -f _http_leer_puerto_config &>/dev/null; then
        _http_leer_puerto_config "$servicio"
        return
    fi

    # Fallback: leer directamente del archivo de configuración
    case "$servicio" in
        httpd)
            grep -E "^Listen\s+[0-9]+" "${SSL_CONF_APACHE}" 2>/dev/null \
                | awk '{print $2}' | head -1 || echo "80"
            ;;
        nginx)
            grep -E "^\s+listen\s+[0-9]+" "${SSL_CONF_NGINX}" 2>/dev/null \
                | grep -v ' ssl' \
                | grep -oP '\d+' | head -1 || echo "80"
            ;;
        tomcat)
            grep 'protocol="HTTP/1.1"' "$(SSL_CONF_TOMCAT)" 2>/dev/null \
                | grep -oP 'port="\K[0-9]+' | head -1 || echo "8080"
            ;;
        *)
            echo "80"
            ;;
    esac
}

# ssl_mostrar_banner  <titulo>
# Imprime un encabezado visual uniforme para los submenús SSL.
# Reutiliza los colores definidos en utils.sh (CYAN, NC).
ssl_mostrar_banner() {
    local titulo="${1:-SSL/TLS}"
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    printf   "${CYAN}║${NC}  %-44s${CYAN}║${NC}\n" "$titulo"
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

# ssl_verificar_prereqs
# Comprueba que las herramientas necesarias para SSL están disponibles.
# Retorna 0 si todo está OK, 1 si falta algo crítico.
# Se llama al inicio de ssl_cert.sh, ssl_http.sh y ssl_ftp.sh.
ssl_verificar_prereqs() {
    local faltantes=0

    aputs_info "Verificando herramientas SSL..."
    echo ""

    # openssl es imprescindible para generar el certificado
    if command -v openssl &>/dev/null; then
        local ver
        ver=$(openssl version 2>/dev/null | head -1)
        printf "  ${GREEN}[OK]${NC}  openssl    — %s\n" "$ver"
    else
        printf "  ${RED}[NO]${NC}  openssl    — NO encontrado\n"
        aputs_info "        Instalar con: sudo dnf install openssl -y"
        (( faltantes++ ))
    fi

    # mod_ssl necesario para Apache HTTPS
    if rpm -q mod_ssl &>/dev/null; then
        printf "  ${GREEN}[OK]${NC}  mod_ssl    — instalado\n"
    else
        printf "  ${YELLOW}[--]${NC}  mod_ssl    — no instalado (necesario para Apache SSL)\n"
        aputs_info "        Se instalará automáticamente al aplicar SSL a Apache"
    fi

    # keytool necesario para Tomcat HTTPS (viene con el JDK)
    if command -v keytool &>/dev/null; then
        printf "  ${GREEN}[OK]${NC}  keytool    — disponible (JDK presente)\n"
    else
        printf "  ${YELLOW}[--]${NC}  keytool    — no encontrado (necesario para Tomcat SSL)\n"
        aputs_info "        Se instalará con: sudo dnf install java-17-openjdk -y"
    fi

    # curl para las verificaciones finales
    if command -v curl &>/dev/null; then
        printf "  ${GREEN}[OK]${NC}  curl       — disponible\n"
    else
        printf "  ${RED}[NO]${NC}  curl       — NO encontrado\n"
        (( faltantes++ ))
    fi

    echo ""

    if (( faltantes > 0 )); then
        aputs_error "${faltantes} herramienta(s) critica(s) faltante(s)"
        return 1
    fi

    aputs_success "Herramientas SSL verificadas"
    return 0
}

# ssl_abrir_puerto_firewall  <puerto>
# Abre un puerto TCP en firewalld de forma permanente y recarga las reglas.
# Es un wrapper pequeño que los módulos ssl_http y ssl_ftp usan para no
# duplicar la lógica de firewall-cmd.
ssl_abrir_puerto_firewall() {
    local puerto="$1"
    
    # Firewalld
    firewall-cmd --permanent --add-port="${puerto}/tcp" &>/dev/null
    firewall-cmd --reload &>/dev/null
    aputs_success "Puerto ${puerto}/tcp abierto en firewall (permanente)"
    
    # SELinux — agregar el puerto como http_port_t si no está ya
    if command -v semanage &>/dev/null; then
        if ! semanage port -l | grep -q "^http_port_t.*tcp.*\b${puerto}\b"; then
            semanage port -a -t http_port_t -p tcp "${puerto}" &>/dev/null \
                || semanage port -m -t http_port_t -p tcp "${puerto}" &>/dev/null
            aputs_success "Puerto ${puerto}/tcp registrado en SELinux (http_port_t)"
        fi
    fi
}

# ssl_hacer_backup  <archivo>
# Crea una copia de seguridad con timestamp antes de modificar un archivo.
# Delega en http_crear_backup si está disponible; si no, lo hace directamente.
ssl_hacer_backup() {
    local archivo="$1"

    [[ ! -f "$archivo" ]] && return 0   # Si no existe, no hay nada que respaldar

    if declare -f http_crear_backup &>/dev/null; then
        http_crear_backup "$archivo"
        return
    fi

    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local backup="${archivo}.bak_ssl_${ts}"

    if cp "$archivo" "$backup" 2>/dev/null; then
        aputs_success "Backup: ${backup}"
    else
        aputs_error "No se pudo crear backup de: ${archivo}"
        return 1
    fi
}


# ssl_leer_puerto_https  <servicio>
# Lee el puerto HTTPS REAL desde los archivos de configuración.
# Si no hay SSL configurado, calcula el sugerido desde el puerto HTTP.
#
# Lee de:
#   Apache  -> ssl_reprobados.conf (Listen <puerto>)
#   Nginx   -> nginx.conf (listen <puerto> ssl)
#   Tomcat  -> server.xml (Connector SSLEnabled="true" port="<puerto>")
#   vsftpd  -> no aplica (usa puerto 21 con STARTTLS)
ssl_leer_puerto_https() {
    local servicio="$1"
    local puerto=""

    case "$servicio" in
        httpd)
            # Leer el Listen del VirtualHost SSL en ssl_reprobados.conf
            if [[ -f "${SSL_CONF_APACHE_SSL}" ]]; then
                puerto=$(grep -E "^Listen\s+[0-9]+" "${SSL_CONF_APACHE_SSL}" 2>/dev/null                          | awk '{print $2}' | head -1) || true
            fi
            ;;
        nginx)
            # Leer el listen con ssl en nginx.conf (excluir el sin ssl)
            if [[ -f "${SSL_CONF_NGINX}" ]]; then
                puerto=$(grep -E "^\s+listen\s+[0-9]+\s+ssl" "${SSL_CONF_NGINX}" 2>/dev/null                          | grep -oP '\d+' | head -1) || true
            fi
            ;;
        tomcat)
            # Leer el puerto del Connector SSL en server.xml
            # El Connector nuevo tiene port= y SSLEnabled= en líneas separadas,
            # así que usamos python3 para parsear el XML correctamente
            local server_xml
            server_xml=$(SSL_CONF_TOMCAT 2>/dev/null)
            if [[ -f "$server_xml" ]]; then
                puerto=$(python3 - "$server_xml" << 'PYEOF_TOMCAT'
import sys, re

server_xml = sys.argv[1]
try:
    with open(server_xml) as f:
        content = f.read()

    # Estrategia: buscar el comentario "Practica7 SSL" que siempre precede
    # nuestro Connector — luego extraer el primer port= en los 500 chars siguientes
    idx = content.find("Practica7 SSL")
    if idx >= 0:
        snippet = content[idx:idx+500]
        m = re.search(r'port="(\d+)"', snippet)
        if m:
            print(m.group(1))
            sys.exit(0)

    # Fallback: buscar cualquier Connector con SSLEnabled="true"
    # Buscar "SSLEnabled" y retroceder para encontrar el port= del mismo bloque
    idx = content.find('SSLEnabled="true"')
    while idx >= 0:
        # Buscar el <Connector que abre este bloque (retroceder hasta <Connector)
        start = content.rfind('<Connector', 0, idx)
        if start >= 0:
            snippet = content[start:idx+200]
            m = re.search(r'port="(\d+)"', snippet)
            if m:
                print(m.group(1))
                sys.exit(0)
        idx = content.find('SSLEnabled="true"', idx+1)
except Exception:
    pass
PYEOF_TOMCAT
) || true
            fi
            ;;
    esac

    # Si no se encontró puerto real, calcular el sugerido
    if [[ -z "$puerto" ]]; then
        local http_port
        http_port=$(ssl_leer_puerto_http "$servicio")
        puerto=$(ssl_puerto_https "$http_port")
    fi

    echo "$puerto"
}

# -----------------------------------------------------------------------------
# Exportar todo para que los subshells y módulos cargados con source
# hereden estas funciones y constantes
# -----------------------------------------------------------------------------
export SSL_DIR SSL_CERT SSL_KEY SSL_DOMAIN SSL_DAYS SSL_KEY_BITS SSL_SUBJECT
export SSL_FTP_ROOT SSL_REPO_ROOT SSL_REPO_LINUX
export SSL_REPO_APACHE SSL_REPO_NGINX SSL_REPO_TOMCAT
export SSL_PUERTO_HTTPS_APACHE SSL_PUERTO_HTTPS_ALT SSL_PUERTO_HTTPS_TOMCAT
export SSL_CONF_APACHE SSL_CONF_APACHE_SSL SSL_CONF_NGINX SSL_CONF_VSFTPD

export -f SSL_CONF_TOMCAT
export -f SSL_KEYSTORE_TOMCAT
export -f ssl_cert_existe
export -f ssl_servicio_instalado
export -f ssl_servicio_activo
export -f ssl_puerto_https
export -f ssl_leer_puerto_http
export -f ssl_leer_puerto_https
export -f ssl_mostrar_banner
export -f ssl_verificar_prereqs
export -f ssl_abrir_puerto_firewall
export -f ssl_hacer_backup