#!/bin/bash
#
# utils_http.sh
# Utilidades extendidas para la gestión de servicios HTTP
#
# Complementa utils.sh (práctica 4) con funciones específicas de HTTP.
# Requiere:
#   utils.sh debe estar cargado antes (aputs_*, draw_*, agets, pause)
#
# Uso en main_http.sh:
#   source "${SCRIPT_DIR}/utils.sh"
#   source "${SCRIPT_DIR}/utils_http.sh"
#


# Nombres internos de los servicios (como los conoce dnf/systemd en Fedora)
# Apache en Fedora se llama 'httpd', NO 'apache2' como en Ubuntu
readonly HTTP_SERVICIO_APACHE="httpd"
readonly HTTP_SERVICIO_NGINX="nginx"
readonly HTTP_SERVICIO_TOMCAT="tomcat"

# Directorio raíz web de cada servicio
# Es donde se coloca el index.html y el contenido público
readonly HTTP_WEBROOT_APACHE="/var/www/html"
readonly HTTP_WEBROOT_NGINX="/usr/share/nginx/html"
# Tomcat se define dinámico en tiempo de ejecución (depende de CATALINA_HOME)

# Archivos de configuración de puerto por servicio
# Son los archivos que el script edita con sed para cambiar el puerto
readonly HTTP_CONF_APACHE="/etc/httpd/conf/httpd.conf"
readonly HTTP_CONF_NGINX="/etc/nginx/nginx.conf"
# Tomcat: $CATALINA_HOME/conf/server.xml (variable, se construye en funciones)

# Archivo de configuración de seguridad de Apache
# Aquí se aplica ServerTokens Prod y ServerSignature Off
readonly HTTP_CONF_APACHE_SECURITY="/etc/httpd/conf.d/security.conf"

# Usuarios del sistema dedicados a cada servicio
# Son usuarios sin shell (-s /sbin/nologin) con permisos solo sobre su webroot
readonly HTTP_USUARIO_APACHE="apache"
readonly HTTP_USUARIO_NGINX="nginx"
readonly HTTP_USUARIO_TOMCAT="tomcat"

# Puertos reservados que el script nunca debe tocar
# Son puertos de otros servicios del sistema que no deben pisarse
readonly HTTP_PUERTOS_RESERVADOS=(22 25 53 3306 5432 6379 27017)

# Puerto por defecto de cada servicio 
readonly HTTP_PUERTO_DEFAULT_APACHE=80
readonly HTTP_PUERTO_DEFAULT_NGINX=80
readonly HTTP_PUERTO_DEFAULT_TOMCAT=8080

# Verifica que todas las herramientas necesarias estén disponibles
# Uso: http_verificar_dependencias
# Retorna 0 si todo OK, 1 si falta alguna herramienta crítica
http_verificar_dependencias() {
    local faltantes=0

    # Herramientas críticas — sin estas el script no puede funcionar
    local herramientas_criticas=("dnf" "systemctl" "firewall-cmd" "ss" "sed" "curl")

    aputs_info "Verificando herramientas necesarias..."
    echo ""

    local herramienta
    for herramienta in "${herramientas_criticas[@]}"; do
        if command -v "$herramienta" &>/dev/null; then
            printf "  ${GREEN}[OK]${NC}  %-15s encontrado en: %s\n" \
                   "$herramienta" "$(command -v "$herramienta")"
        else
            printf "  ${RED}[NO]${NC}  %-15s NO encontrado\n" "$herramienta"
            (( faltantes++ ))
        fi
    done

    echo ""

    # Java es necesario solo para Tomcat — advertencia, no error crítico
    if command -v java &>/dev/null; then
        local java_ver
        java_ver=$(java -version 2>&1 | head -1)
        printf "  ${GREEN}[OK]${NC}  %-15s %s\n" "java" "$java_ver"
    else
        printf "  ${YELLOW}[WARN]${NC} %-15s No instalado (requerido solo para Tomcat)\n" "java"
        aputs_info "  Instale con: sudo dnf install java-17-openjdk -y"
    fi

    echo ""

    if (( faltantes > 0 )); then
        aputs_error "$faltantes herramienta(s) critica(s) no encontrada(s)"
        return 1
    fi

    aputs_success "Todas las dependencias criticas disponibles"
    return 0
}

# Verifica si un puerto está actualmente en uso por algún proceso
# Uso: http_puerto_en_uso 8080
# Retorna 0 si está en uso, 1 si está libre
http_puerto_en_uso() {
    local puerto="$1"

    # ss -tlnp: muestra puertos TCP en escucha con el proceso que los ocupa
    # Buscamos el patrón ":PUERTO " en la columna de dirección local
    if sudo ss -tlnp 2>/dev/null | grep -q ":${puerto} "; then
        return 0  # Puerto en uso
    else
        return 1  # Puerto libre
    fi
}

# Obtiene el nombre del proceso que ocupa un puerto
# Uso: http_quien_usa_puerto 80
# Imprime el nombre del proceso o "desconocido"
http_quien_usa_puerto() {
    local puerto="$1"

    # ss -tlnp extrae también el nombre del proceso entre comillas en el campo users
    local proceso
    proceso=$(sudo ss -tlnp 2>/dev/null \
              | grep ":${puerto} " \
              | grep -oP 'users:\(\("\K[^"]+' \
              | head -1)

    echo "${proceso:-desconocido}"
}

# Lista todos los puertos HTTP actualmente en escucha en el sistema
# Uso: http_listar_puertos_activos
# Imprime una tabla con puerto, estado y proceso
http_listar_puertos_activos() {
    aputs_info "Puertos HTTP activos en el sistema:"
    echo ""

    # Buscamos puertos comunes de servicios web
    local puertos_web=(80 443 8080 8443 8888 3000 4000 8000 9090)

    printf "  %-10s %-12s %-20s\n" "PUERTO" "ESTADO" "PROCESO"
    echo "  ──────────────────────────────────────────"

    local puerto
    for puerto in "${puertos_web[@]}"; do
        if http_puerto_en_uso "$puerto"; then
            local proceso
            proceso=$(http_quien_usa_puerto "$puerto")
            printf "  ${GREEN}%-10s${NC} %-12s %-20s\n" \
                   "${puerto}/tcp" "EN USO" "$proceso"
        else
            printf "  ${GRAY}%-10s${NC} %-12s\n" \
                   "${puerto}/tcp" "libre"
        fi
    done
}

# Obtiene el nombre del paquete dnf a partir del nombre interno del servicio
# Necesario porque el servicio systemd y el paquete dnf pueden llamarse diferente
# Uso: http_nombre_paquete "httpd"  -> devuelve "httpd"
#      http_nombre_paquete "tomcat" -> devuelve "tomcat" (o indica instalación manual)
http_nombre_paquete() {
    local servicio="$1"
    case "$servicio" in
        httpd|apache)  echo "httpd"  ;;
        nginx)         echo "nginx"  ;;
        tomcat)        echo "tomcat" ;;
        *)             echo "$servicio" ;;
    esac
}

# Obtiene el nombre del servicio systemd a partir del nombre del servicio HTTP
# Uso: http_nombre_systemd "httpd"  -> "httpd"
#      http_nombre_systemd "tomcat" -> "tomcat" (puede variar si es instalación manual)
http_nombre_systemd() {
    local servicio="$1"
    case "$servicio" in
        httpd|apache)  echo "httpd"  ;;
        nginx)         echo "nginx"  ;;
        tomcat)        echo "tomcat" ;;
        *)             echo "$servicio" ;;
    esac
}

# Obtiene el directorio webroot del servicio indicado
# Uso: http_get_webroot "httpd"
http_get_webroot() {
    local servicio="$1"
    case "$servicio" in
        httpd|apache)  echo "$HTTP_WEBROOT_APACHE" ;;
        nginx)         echo "$HTTP_WEBROOT_NGINX"  ;;
        tomcat)
            # Tomcat usa CATALINA_HOME si está definido, o la ruta por defecto de dnf
            local catalina="${CATALINA_HOME:-/usr/share/tomcat}"
            echo "${catalina}/webapps/ROOT"
            ;;
        *)  echo "/var/www/html" ;;
    esac
}

# Obtiene el usuario dedicado del servicio
# Uso: http_get_usuario_servicio "nginx"
http_get_usuario_servicio() {
    local servicio="$1"
    case "$servicio" in
        httpd|apache)  echo "$HTTP_USUARIO_APACHE" ;;
        nginx)         echo "$HTTP_USUARIO_NGINX"  ;;
        tomcat)        echo "$HTTP_USUARIO_TOMCAT" ;;
        *)             echo "nobody" ;;
    esac
}

# Obtiene el archivo de configuración principal del servicio
# Uso: http_get_conf_archivo "httpd"
http_get_conf_archivo() {
    local servicio="$1"
    case "$servicio" in
        httpd|apache)  echo "$HTTP_CONF_APACHE" ;;
        nginx)         echo "$HTTP_CONF_NGINX"  ;;
        tomcat)
            local catalina="${CATALINA_HOME:-/usr/share/tomcat}"
            echo "${catalina}/conf/server.xml"
            ;;
        *)  echo "" ;;
    esac
}

# Crea un backup de un archivo de configuración con timestamp
# Uso: http_crear_backup "/etc/httpd/conf/httpd.conf"
# Retorna 0 y muestra ruta del backup, o 1 si falló
http_crear_backup() {
    local archivo="$1"

    if [[ ! -f "$archivo" ]]; then
        aputs_warning "Archivo no encontrado para backup: $archivo"
        return 1
    fi

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)

    # Guardamos el backup en el mismo directorio con sufijo .bak_TIMESTAMP
    local backup="${archivo}.bak_${timestamp}"

    if sudo cp "$archivo" "$backup" 2>/dev/null; then
        aputs_success "Backup creado: $backup"
        return 0
    else
        aputs_error "No se pudo crear backup de: $archivo"
        return 1
    fi
}

# Restaura el backup más reciente de un archivo de configuración
# Uso: http_restaurar_backup "/etc/httpd/conf/httpd.conf"
http_restaurar_backup() {
    local archivo="$1"
    local directorio
    directorio=$(dirname "$archivo")
    local nombre
    nombre=$(basename "$archivo")

    # Buscar el backup más reciente (último en orden alfabético = más reciente por timestamp)
    local backup_reciente
    backup_reciente=$(sudo find "$directorio" -name "${nombre}.bak_*" 2>/dev/null \
                      | sort | tail -1)

    if [[ -z "$backup_reciente" ]]; then
        aputs_error "No se encontro ningun backup para: $archivo"
        return 1
    fi

    aputs_info "Restaurando desde: $backup_reciente"

    if sudo cp "$backup_reciente" "$archivo" 2>/dev/null; then
        aputs_success "Archivo restaurado correctamente"
        return 0
    else
        aputs_error "Error al restaurar el backup"
        return 1
    fi
}

# Imprime un encabezado de sección con el nombre del servicio resaltado
# Uso: http_draw_servicio_header "Apache (httpd)" "Instalacion"
http_draw_servicio_header() {
    local servicio="$1"
    local accion="$2"
    echo ""
    echo "════════════════════════════════════════════════"
    echo -e "  ${CYAN}[HTTP]${NC} ${servicio} — ${accion}"
    echo "════════════════════════════════════════════════"
    echo ""
}

# Imprime un resumen de la operación completada
# Uso: http_draw_resumen "Apache" "80" "2.4.58"
http_draw_resumen() {
    local servicio="$1"
    local puerto="$2"
    local version="$3"

    echo ""
    echo "  ╔══════════════════════════════════════════╗"
    echo -e "  ║  ${GREEN}Despliegue completado exitosamente${NC}        ║"
    echo "  ╠══════════════════════════════════════════╣"
    printf "  ║  %-10s %-30s ║\n" "Servicio:"  "$servicio"
    printf "  ║  %-10s %-30s ║\n" "Version:"   "$version"
    printf "  ║  %-10s %-30s ║\n" "Puerto:"    "$puerto/tcp"
    echo "  ╚══════════════════════════════════════════╝"
    echo ""
    aputs_info "Verificacion rapida:"
    echo "    curl -I http://localhost:${puerto}"
    echo ""
}

# Recarga la configuración de un servicio sin detenerlo (reload, no restart)
# Uso: http_recargar_servicio "httpd"
# reload aplica cambios de config sin matar conexiones activas
http_recargar_servicio() {
    local servicio="$1"
    local nombre_systemd
    nombre_systemd=$(http_nombre_systemd "$servicio")

    aputs_info "Recargando configuracion de ${nombre_systemd}..."

    if sudo systemctl reload "$nombre_systemd" 2>/dev/null; then
        sleep 1
        if check_service_active "$nombre_systemd"; then
            aputs_success "${nombre_systemd} recargado y activo"
            return 0
        else
            aputs_error "${nombre_systemd} no esta activo tras el reload"
            return 1
        fi
    else
        # Algunos servicios no soportan reload — intentamos restart como fallback
        aputs_warning "reload no disponible — intentando restart..."
        http_reiniciar_servicio "$servicio"
        return $?
    fi
}

# Reinicia completamente un servicio (restart)
# Uso: http_reiniciar_servicio "nginx"
# Usar solo cuando reload no es suficiente (cambio de puerto, versión, etc.)
http_reiniciar_servicio() {
    local servicio="$1"
    local nombre_systemd
    nombre_systemd=$(http_nombre_systemd "$servicio")

    aputs_info "Reiniciando ${nombre_systemd}..."

    if sudo systemctl restart "$nombre_systemd" 2>/dev/null; then
        sleep 2
        if check_service_active "$nombre_systemd"; then
            local pid
            pid=$(sudo systemctl show "$nombre_systemd" \
                  --property=MainPID --value 2>/dev/null)
            aputs_success "${nombre_systemd} reiniciado — PID: ${pid}"
            return 0
        else
            aputs_error "${nombre_systemd} no levanto tras el reinicio"
            aputs_info "Revise los logs: sudo journalctl -u ${nombre_systemd} -n 20"
            return 1
        fi
    else
        aputs_error "Error al ejecutar restart de ${nombre_systemd}"
        return 1
    fi
}

# Verifica que el servicio responde en el puerto indicado con curl
# Uso: http_verificar_respuesta "httpd" 80
# Muestra los headers HTTP reales de la respuesta
http_verificar_respuesta() {
    local servicio="$1"
    local puerto="$2"

    aputs_info "Verificando respuesta HTTP en localhost:${puerto}..."
    echo ""

    # curl -I: solo pide los headers (HEAD request) — rápido y sin descargar cuerpo
    # --max-time 5: no esperar más de 5 segundos
    # --silent: sin barra de progreso
    # --show-error: pero sí mostrar errores
    local respuesta
    respuesta=$(curl -I --max-time 5 --silent --show-error \
                "http://localhost:${puerto}" 2>&1)

    local exit_code=$?

    if (( exit_code == 0 )); then
        aputs_success "Servicio respondiendo en puerto ${puerto}"
        echo ""
        echo "$respuesta" | sed 's/^/    /'
        return 0
    else
        aputs_error "El servicio NO responde en puerto ${puerto}"
        aputs_info "Posibles causas:"
        echo "    - El servicio no esta activo (systemctl status ${servicio})"
        echo "    - El puerto configurado no coincide con el real"
        echo "    - El firewall esta bloqueando la conexion"
        return 1
    fi
}

export HTTP_SERVICIO_APACHE HTTP_SERVICIO_NGINX HTTP_SERVICIO_TOMCAT
export HTTP_WEBROOT_APACHE HTTP_WEBROOT_NGINX
export HTTP_CONF_APACHE HTTP_CONF_NGINX HTTP_CONF_APACHE_SECURITY
export HTTP_USUARIO_APACHE HTTP_USUARIO_NGINX HTTP_USUARIO_TOMCAT
export HTTP_PUERTOS_RESERVADOS
export HTTP_PUERTO_DEFAULT_APACHE HTTP_PUERTO_DEFAULT_NGINX HTTP_PUERTO_DEFAULT_TOMCAT

export -f http_verificar_dependencias
export -f http_puerto_en_uso
export -f http_quien_usa_puerto
export -f http_listar_puertos_activos
export -f http_nombre_paquete
export -f http_nombre_systemd
export -f http_get_webroot
export -f http_get_usuario_servicio
export -f http_get_conf_archivo
export -f http_crear_backup
export -f http_restaurar_backup
export -f http_draw_servicio_header
export -f http_draw_resumen
export -f http_recargar_servicio
export -f http_reiniciar_servicio
export -f http_verificar_respuesta