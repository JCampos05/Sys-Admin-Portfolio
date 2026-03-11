#!/bin/bash
#
# http_functions_E.sh
# Grupo E — Monitoreo de servicios HTTP
#
# Propósito del grupo:
#   Observar el estado del sistema en tiempo real sin modificar nada.
#   Todas las funciones son de SOLO LECTURA.
#
#   E.1 — Estado del servicio
#         PID, memoria, CPU, tiempo activo, estado systemd,
#         habilitado en boot, socket en escucha.
#
#   E.2 — Monitoreo de puertos
#         Puertos en escucha de cada servicio HTTP instalado.
#         Puertos abiertos/cerrados en firewalld.
#         Puertos del sistema relevantes para detectar conflictos.
#
#   E.3 — Logs del servicio
#         journalctl filtrado por servicio con N líneas configurable.
#         Resumen de eventos críticos: errores, arranques, caídas.
#         Conteo de errores 4xx y 5xx de los últimos logs de acceso.
#
#   E.4 — Headers HTTP en vivo (curl -I)
#         Petición HEAD real al servicio.
#         Muestra todos los headers de respuesta.
#         Verifica presencia de security headers configurados en Grupo C.
#
#   E.5 — Configuración activa
#         Parámetros efectivos leídos del archivo de configuración.
#         Usuario del proceso, webroot, permisos.
#
#   E.6 — http_menu_monitoreo — punto de entrada desde main_menu opción 4
#
# Funciones públicas:
#   http_monitoreo_estado()      — Estado PID/memoria/tiempo de cada servicio
#   http_monitoreo_puertos()     — Puertos en escucha y estado firewall
#   http_monitoreo_logs()        — Logs con journalctl + resumen de errores
#   http_monitoreo_headers()     — curl -I contra el servicio activo
#   http_monitoreo_config()      — Configuración activa del servicio
#   http_menu_monitoreo()        — Submenú del Grupo E
#
# Funciones internas (prefijo _):
#   _http_mon_estado_servicio()  — Panel de estado de un servicio individual
#   _http_mon_firewall_puerto()  — Estado de un puerto en firewalld
#   _http_mon_verificar_headers_seguridad() — Audita headers del Grupo C
#
# Requiere:
#   utils.sh, utils_http.sh, validators_http.sh
#   http_functions_A.sh (_http_obtener_puerto_activo, http_verificar_respuesta)
#   http_functions_C.sh (_http_leer_puerto_config, _http_seleccionar_servicio_instalado)
#

_http_mon_estado_servicio() {
    local svc="$1"
    local nombre="$2"
    local paquete
    paquete=$(http_nombre_paquete "$svc")
    local nombre_systemd
    nombre_systemd=$(http_nombre_systemd "$svc")

    echo -e "  ${CYAN} ${nombre}${NC}"
    echo "  ────────────────────────────────────────────────────"

    # Verificar instalación primero
    if ! rpm -q "$paquete" &>/dev/null; then
        printf "  ${GRAY}[--]${NC}  No instalado\n"
        echo ""
        return 0
    fi

    local version
    version=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" "$paquete" 2>/dev/null)
    printf "  ${GREEN}[OK]${NC}  Version     : %s\n" "$version"

    # ── Estado systemd ────────────────────────────────────────────────────
    if check_service_active "$nombre_systemd"; then

        # PID del proceso principal
        local pid
        pid=$(sudo systemctl show "$nombre_systemd" \
              --property=MainPID --value 2>/dev/null)
        printf "  ${GREEN}[OK]${NC}  Estado      : ${GREEN}ACTIVO${NC} — PID: %s\n" "$pid"

        # Tiempo activo desde el último inicio
        local activo_desde
        activo_desde=$(sudo systemctl show "$nombre_systemd" \
                       --property=ActiveEnterTimestamp --value 2>/dev/null \
                       | cut -d' ' -f1-4)
        [[ -n "$activo_desde" ]] && \
            printf "        Activo desde: %s\n" "$activo_desde"

        # Memoria consumida por el servicio (en MB)
        local memoria_bytes
        memoria_bytes=$(sudo systemctl show "$nombre_systemd" \
                        --property=MemoryCurrent --value 2>/dev/null)
        if [[ -n "$memoria_bytes" && "$memoria_bytes" != "[not set]" \
              && "$memoria_bytes" -gt 0 ]] 2>/dev/null; then
            local memoria_mb=$(( memoria_bytes / 1024 / 1024 ))
            printf "        Memoria     : %s MB\n" "$memoria_mb"
        fi

        # CPU del proceso con ps -p PID -o %cpu
        if [[ -n "$pid" && "$pid" != "0" ]]; then
            local cpu
            cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
            [[ -n "$cpu" ]] && printf "        CPU         : %s%%\n" "$cpu"
        fi

    else
        local estado_detalle
        estado_detalle=$(sudo systemctl is-active "$nombre_systemd" 2>/dev/null)
        printf "  ${RED}[!!]${NC}  Estado      : ${RED}INACTIVO${NC} (%s)\n" "$estado_detalle"

        # Mostrar la última línea del log para dar pista del motivo
        local ultimo_log
        ultimo_log=$(sudo journalctl -u "$nombre_systemd" -n 1 \
                     --no-pager 2>/dev/null | tail -1)
        [[ -n "$ultimo_log" ]] && \
            printf "        Ultimo log  : %s\n" "${ultimo_log:0:70}..."
    fi

    # ── Habilitado en boot ────────────────────────────────────────────────
    if check_service_enabled "$nombre_systemd"; then
        printf "        Boot        : ${GREEN}habilitado${NC}\n"
    else
        printf "        Boot        : ${YELLOW}deshabilitado${NC}\n"
    fi

    # ── Puerto en escucha ─────────────────────────────────────────────────
    local puerto_activo
    puerto_activo=$(_http_obtener_puerto_activo "$nombre_systemd")

    if [[ -n "$puerto_activo" ]]; then
        printf "  ${GREEN}[OK]${NC}  Puerto      : %s/tcp en escucha\n" "$puerto_activo"
    else
        local puerto_conf
        puerto_conf=$(_http_leer_puerto_config "$svc")
        printf "  ${YELLOW}[--]${NC}  Puerto      : sin escucha (config: %s/tcp)\n" \
               "${puerto_conf:-?}"
    fi

    echo ""
}

http_monitoreo_estado() {
    clear
    draw_header "Estado de Servicios HTTP"

    echo ""
    printf "  %-20s %s\n" "Hora del informe:" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "  %-20s %s\n" "Servidor:" "$(hostname) ($(hostname -I | awk '{print $1}'))"
    echo ""
    draw_line
    echo ""

    local servicios=("httpd"  "nginx"  "tomcat")
    local nombres=("Apache (httpd)" "Nginx" "Tomcat")

    local i
    for i in "${!servicios[@]}"; do
        _http_mon_estado_servicio "${servicios[$i]}" "${nombres[$i]}"
    done

    draw_line

    # ── Resumen del sistema ───────────────────────────────────────────────
    echo ""
    aputs_info "Resumen del sistema:"
    echo ""

    local activos=0 instalados=0
    local svc
    for svc in httpd nginx tomcat; do
        if rpm -q "$(http_nombre_paquete "$svc")" &>/dev/null; then
            (( instalados++ ))
            check_service_active "$(http_nombre_systemd "$svc")" && (( activos++ ))
        fi
    done

    printf "  Servicios instalados : %s de 3\n" "$instalados"
    printf "  Servicios activos    : %s de %s instalados\n" "$activos" "$instalados"

    # Carga del sistema
    local load
    load=$(uptime | grep -oP 'load average: \K[0-9., ]+' | awk '{print $1}')
    [[ -n "$load" ]] && printf "  Carga del sistema    : %s\n" "$load"
}

_http_mon_firewall_puerto() {
    local puerto="$1"

    local abierto=false

    # Verificar por número de puerto directo
    if sudo firewall-cmd --list-ports 2>/dev/null \
       | grep -q "${puerto}/tcp"; then
        abierto=true
    fi

    # Verificar por nombre de servicio (http=80, https=443)
    if (( puerto == 80 )) && \
       sudo firewall-cmd --list-services 2>/dev/null | grep -qw "http"; then
        abierto=true
    fi
    if (( puerto == 443 )) && \
       sudo firewall-cmd --list-services 2>/dev/null | grep -qw "https"; then
        abierto=true
    fi

    if $abierto; then
        printf "  ${GREEN}[ABIERTO]${NC}  %s/tcp\n" "$puerto"
    else
        printf "  ${YELLOW}[CERRADO]${NC}  %s/tcp\n" "$puerto"
    fi
}

http_monitoreo_puertos() {
    clear
    draw_header "Monitoreo de Puertos HTTP"

    echo ""

    # ── Capa 1: Puertos de servicios HTTP instalados ──────────────────────
    aputs_info "Puertos de servicios HTTP instalados:"
    echo ""
    printf "  %-20s %-15s %-15s %-10s\n" "SERVICIO" "PUERTO CONFIG" "PUERTO ACTIVO" "ESTADO"
    echo "  ─────────────────────────────────────────────────────────────"

    local svc
    for svc in httpd nginx tomcat; do
        if ! rpm -q "$(http_nombre_paquete "$svc")" &>/dev/null; then
            continue
        fi

        local nombre_systemd
        nombre_systemd=$(http_nombre_systemd "$svc")
        local puerto_conf puerto_activo estado_str

        puerto_conf=$(_http_leer_puerto_config "$svc")
        puerto_activo=$(_http_obtener_puerto_activo "$nombre_systemd")

        if check_service_active "$nombre_systemd"; then
            estado_str="${GREEN}activo${NC}"
        else
            estado_str="${YELLOW}inactivo${NC}"
        fi

        printf "  %-20s %-15s %-15s " \
               "$svc" \
               "${puerto_conf:-?}/tcp" \
               "${puerto_activo:--}/tcp"
        echo -e "$estado_str"
    done

    echo ""
    draw_line

    # ── Capa 2: Estado de puertos relevantes en firewalld ─────────────────
    echo ""
    aputs_info "Estado en firewalld:"
    echo ""

    if sudo systemctl is-active --quiet firewalld 2>/dev/null; then
        aputs_success "firewalld: ACTIVO"
        echo ""

        # Verificar los puertos de todos los servicios instalados
        local puertos_a_verificar=()
        for svc in httpd nginx tomcat; do
            if rpm -q "$(http_nombre_paquete "$svc")" &>/dev/null; then
                local p
                p=$(_http_leer_puerto_config "$svc")
                [[ -n "$p" ]] && puertos_a_verificar+=("$p")
            fi
        done

        # Siempre verificar los puertos default aunque no estén configurados
        puertos_a_verificar+=(80 443 8080 8443)

        # Eliminar duplicados preservando orden
        local puertos_unicos=()
        local seen=()
        local p
        for p in "${puertos_a_verificar[@]}"; do
            local ya_visto=false
            local v
            for v in "${seen[@]}"; do
                [[ "$v" == "$p" ]] && ya_visto=true && break
            done
            if ! $ya_visto; then
                puertos_unicos+=("$p")
                seen+=("$p")
            fi
        done

        for p in "${puertos_unicos[@]}"; do
            _http_mon_firewall_puerto "$p"
        done

        echo ""

        # Servicios por nombre habilitados
        aputs_info "Servicios habilitados por nombre en firewalld:"
        local servicios_fw
        servicios_fw=$(sudo firewall-cmd --list-services 2>/dev/null)
        if [[ -n "$servicios_fw" ]]; then
            echo "    $servicios_fw" | tr ' ' '\n' | \
                while read -r s; do
                    [[ -n "$s" ]] && printf "    - %s\n" "$s"
                done
        else
            echo "    (ninguno)"
        fi

    else
        aputs_warning "firewalld: INACTIVO"
        aputs_info "Sin reglas de firewall activas — todos los puertos expuestos"
    fi

    echo ""
    draw_line

    # ── Capa 3: Todos los puertos TCP en escucha del sistema ──────────────
    echo ""
    aputs_info "Todos los puertos TCP en escucha del sistema:"
    echo ""
    printf "  %-12s %-25s %-20s\n" "ESTADO" "DIRECCIÓN LOCAL" "PROCESO"
    echo "  ─────────────────────────────────────────────────────────"

    sudo ss -tlnp 2>/dev/null \
        | tail -n +2 \
        | while IFS= read -r linea; do
            local estado dir_local proceso
            estado=$(echo "$linea" | awk '{print $1}')
            dir_local=$(echo "$linea" | awk '{print $4}')
            proceso=$(echo "$linea" | grep -oP 'users:\(\("\K[^"]+' | head -1)
            proceso="${proceso:-sistema}"
            printf "  %-12s %-25s %-20s\n" "$estado" "$dir_local" "$proceso"
        done
}

http_monitoreo_logs() {
    clear
    draw_header "Logs de Servicio HTTP"

    local servicio
    if ! _http_seleccionar_servicio_instalado servicio; then
        return 1
    fi

    local nombre_systemd
    nombre_systemd=$(http_nombre_systemd "$servicio")

    http_draw_servicio_header "$servicio" "Logs del Servicio"

    # Número de líneas a mostrar
    local n_lineas
    while true; do
        agets "Numero de lineas a mostrar [50]" n_lineas
        n_lineas="${n_lineas:-50}"
        if http_validar_lineas_log "$n_lineas"; then
            break
        fi
        echo ""
    done

    echo ""
    draw_line
    aputs_info "Ultimas ${n_lineas} lineas — journalctl -u ${nombre_systemd}"
    draw_line
    echo ""

    # journalctl:
    #   -u  : filtrar por unidad systemd
    #   -n  : número de líneas
    #   --no-pager : no paginar, mostrar todo de golpe
    #   -o short-precise : formato con timestamp preciso
    sudo journalctl -u "$nombre_systemd" \
                    -n "$n_lineas" \
                    --no-pager \
                    -o short-precise \
                    2>/dev/null

    echo ""
    draw_line
    echo ""

    # ── Resumen automático de eventos críticos ────────────────────────────
    aputs_info "Resumen de eventos — ultimas 24 horas:"
    echo ""

    # Errores y fallos
    local n_errores
    n_errores=$(sudo journalctl -u "$nombre_systemd" \
                --since "24 hours ago" --no-pager 2>/dev/null \
                | grep -ciE "error|fail|crit|emerg|alert" 2>/dev/null \
                || echo "0")

    # Reinicios del servicio
    local n_reinicios
    n_reinicios=$(sudo journalctl -u "$nombre_systemd" \
                  --since "24 hours ago" --no-pager 2>/dev/null \
                  | grep -ci "Started\|Restarted\|start request" 2>/dev/null \
                  || echo "0")

    # Advertencias
    local n_warnings
    n_warnings=$(sudo journalctl -u "$nombre_systemd" \
                 --since "24 hours ago" --no-pager 2>/dev/null \
                 | grep -ci "warn\|notice" 2>/dev/null \
                 || echo "0")

    printf "  %-25s %s\n" "Errores/fallos (24h):"   "$n_errores"
    printf "  %-25s %s\n" "Reinicios (24h):"        "$n_reinicios"
    printf "  %-25s %s\n" "Advertencias (24h):"     "$n_warnings"

    echo ""

    # Alerta si hay errores relevantes
    if (( n_errores > 5 )); then
        aputs_warning "Alto numero de errores detectados (${n_errores})"
        echo ""
        aputs_info "Ultimos 5 errores:"
        sudo journalctl -u "$nombre_systemd" \
                        --since "24 hours ago" --no-pager 2>/dev/null \
            | grep -iE "error|fail|crit" \
            | tail -5 \
            | sed 's/^/    /'
    fi

    # ── Logs de acceso del servicio (si existen) ──────────────────────────
    echo ""
    local log_acceso=""
    case "$servicio" in
        httpd)  log_acceso="/var/log/httpd/access_log"  ;;
        nginx)  log_acceso="/var/log/nginx/access.log"  ;;
        tomcat)
            local catalina="${CATALINA_HOME:-/usr/share/tomcat}"
            log_acceso="${catalina}/logs/localhost_access_log.$(date +%Y-%m-%d).txt"
            ;;
    esac

    if [[ -n "$log_acceso" ]] && sudo test -f "$log_acceso" 2>/dev/null; then
        aputs_info "Resumen de log de acceso HTTP: ${log_acceso}"
        echo ""

        # Conteo de respuestas 4xx (errores de cliente)
        local n_4xx
        n_4xx=$(sudo grep -cE '" [4][0-9]{2} ' "$log_acceso" 2>/dev/null \
                || echo "0")

        # Conteo de respuestas 5xx (errores de servidor)
        local n_5xx
        n_5xx=$(sudo grep -cE '" [5][0-9]{2} ' "$log_acceso" 2>/dev/null \
                || echo "0")

        # Total de peticiones
        local n_total
        n_total=$(sudo wc -l < "$log_acceso" 2>/dev/null || echo "0")

        printf "  %-25s %s\n" "Total peticiones:"    "$n_total"
        printf "  %-25s %s\n" "Errores cliente 4xx:" "$n_4xx"
        printf "  %-25s %s\n" "Errores servidor 5xx:" "$n_5xx"

        (( n_5xx > 0 )) && {
            echo ""
            aputs_warning "${n_5xx} errores de servidor detectados en access_log"
            aputs_info "Ultimos 3 errores 5xx:"
            sudo grep -E '" [5][0-9]{2} ' "$log_acceso" 2>/dev/null \
                | tail -3 | sed 's/^/    /'
        }
    fi
}

_http_mon_verificar_headers_seguridad() {
    local respuesta="$1"

    echo ""
    aputs_info "Auditoria de security headers (configurados en Grupo C):"
    echo ""

    # Headers que deben estar presentes tras aplicar http_configurar_seguridad
    local headers_esperados=(
        "X-Frame-Options"
        "X-Content-Type-Options"
        "X-XSS-Protection"
        "Referrer-Policy"
    )

    local h
    for h in "${headers_esperados[@]}"; do
        local valor
        valor=$(echo "$respuesta" | grep -i "^${h}:" | cut -d: -f2- | tr -d '\r' | xargs)

        if [[ -n "$valor" ]]; then
            printf "  ${GREEN}[OK]${NC}    %-30s %s\n" "${h}:" "$valor"
        else
            printf "  ${YELLOW}[--]${NC}    %-30s AUSENTE\n" "${h}:"
        fi
    done

    # Verificar el header Server — no debe revelar versión
    echo ""
    local header_server
    header_server=$(echo "$respuesta" \
                    | grep -i "^Server:" | cut -d: -f2- | tr -d '\r' | xargs)

    if [[ -n "$header_server" ]]; then
        # Si contiene números de versión es una fuga de información
        if echo "$header_server" | grep -qE "[0-9]+\.[0-9]+"; then
            printf "  ${YELLOW}[!!]${NC}    %-30s %s\n" \
                   "Server:" "$header_server"
            aputs_warning "  El header Server revela version — aplique Grupo C opcion 2"
        else
            printf "  ${GREEN}[OK]${NC}    %-30s %s\n" \
                   "Server:" "$header_server"
        fi
    fi
}

http_monitoreo_headers() {
    clear
    draw_header "Headers HTTP en Vivo"

    local servicio
    if ! _http_seleccionar_servicio_instalado servicio; then
        return 1
    fi

    local nombre_systemd
    nombre_systemd=$(http_nombre_systemd "$servicio")

    http_draw_servicio_header "$servicio" "curl -I"

    # Detectar el puerto activo del servicio
    local puerto
    puerto=$(_http_obtener_puerto_activo "$nombre_systemd")

    if [[ -z "$puerto" ]]; then
        # Servicio inactivo — leer del archivo de config
        puerto=$(_http_leer_puerto_config "$servicio")
    fi

    if [[ -z "$puerto" ]]; then
        aputs_error "No se pudo detectar el puerto del servicio"
        aputs_info "Verifique que el servicio esta activo: systemctl status ${nombre_systemd}"
        return 1
    fi

    aputs_info "Realizando peticion HEAD a http://localhost:${puerto} ..."
    echo ""

    # curl -I : petición HEAD — solo headers, sin cuerpo
    # --max-time 5 : timeout de 5 segundos
    # --silent : sin barra de progreso
    # --show-error : pero sí mostrar errores de conexión
    # --include : incluir headers de respuesta en stdout
    local respuesta
    respuesta=$(curl -I \
                     --max-time 5 \
                     --silent \
                     --show-error \
                     "http://localhost:${puerto}" 2>&1)
    local curl_exit=$?

    if (( curl_exit != 0 )); then
        aputs_error "curl fallo con codigo ${curl_exit}"
        echo ""
        aputs_info "Detalle del error:"
        echo "    $respuesta"
        echo ""
        aputs_info "Causas posibles:"
        echo "    - El servicio esta inactivo"
        echo "    - El puerto ${puerto} no coincide con el configurado"
        echo "    - El firewall esta bloqueando la conexion local"
        return 1
    fi

    draw_line
    aputs_info "Respuesta completa de http://localhost:${puerto} :"
    draw_line
    echo ""

    # Mostrar todos los headers con sangría
    echo "$respuesta" | sed 's/^/    /'

    echo ""

    # ── Auditoría de security headers ────────────────────────────────────
    _http_mon_verificar_headers_seguridad "$respuesta"

    echo ""
    draw_line
    aputs_info "Comando equivalente: curl -I http://localhost:${puerto}"
    aputs_info "Desde red interna:   curl -I http://192.168.100.10:${puerto}"
}

http_monitoreo_config() {
    clear
    draw_header "Configuracion Activa del Servicio"

    local servicio
    if ! _http_seleccionar_servicio_instalado servicio; then
        return 1
    fi

    http_draw_servicio_header "$servicio" "Configuracion Activa"

    local archivo_conf
    archivo_conf=$(http_get_conf_archivo "$servicio")

    # ── Parámetros del archivo de configuración ───────────────────────────
    aputs_info "Archivo de configuracion: ${archivo_conf}"
    echo ""

    if [[ ! -f "$archivo_conf" ]] && ! sudo test -f "$archivo_conf" 2>/dev/null; then
        aputs_error "Archivo no encontrado: ${archivo_conf}"
        return 1
    fi

    aputs_info "Directivas activas (sin comentarios ni lineas vacias):"
    echo ""

    # grep -v: excluye comentarios (#) y líneas vacías
    # head -40: limitar a 40 líneas para no saturar la pantalla
    sudo grep -vE "^\s*#|^\s*$" "$archivo_conf" 2>/dev/null \
        | head -40 \
        | sed 's/^/    /'

    echo ""
    draw_line

    # ── Puerto configurado ────────────────────────────────────────────────
    echo ""
    local puerto_conf
    puerto_conf=$(_http_leer_puerto_config "$servicio")
    printf "  Puerto en config  : %s/tcp\n" "${puerto_conf:-no detectado}"

    local puerto_activo
    puerto_activo=$(_http_obtener_puerto_activo "$(http_nombre_systemd "$servicio")")
    printf "  Puerto en escucha : %s\n" "${puerto_activo:+${puerto_activo}/tcp (activo)}"
    [[ -z "$puerto_activo" ]] && printf "  Puerto en escucha : %s\n" "sin escucha"

    echo ""
    draw_line

    # ── Webroot ───────────────────────────────────────────────────────────
    echo ""
    local webroot
    webroot=$(http_get_webroot "$servicio")
    aputs_info "Directorio web (webroot): ${webroot}"
    echo ""

    if [[ -d "$webroot" ]] || sudo test -d "$webroot" 2>/dev/null; then

        # Propietario y permisos del directorio
        local propietario permisos
        propietario=$(stat -c '%U:%G' "$webroot" 2>/dev/null)
        permisos=$(stat -c '%a' "$webroot" 2>/dev/null)
        printf "  Propietario : %s\n" "$propietario"
        printf "  Permisos    : %s\n" "$permisos"

        # Contenido del webroot
        echo ""
        aputs_info "Contenido de ${webroot}:"
        sudo ls -lh "$webroot" 2>/dev/null | sed 's/^/    /'
    else
        aputs_warning "Webroot no existe: ${webroot}"
    fi

    echo ""
    draw_line

    # ── Usuario del proceso ───────────────────────────────────────────────
    echo ""
    local usuario_svc
    usuario_svc=$(http_get_usuario_servicio "$servicio")
    aputs_info "Usuario del servicio: ${usuario_svc}"
    echo ""

    if id "$usuario_svc" &>/dev/null; then
        local uid gid shell
        uid=$(id -u "$usuario_svc")
        gid=$(id -g "$usuario_svc")
        shell=$(getent passwd "$usuario_svc" | cut -d: -f7)
        printf "  UID   : %s\n" "$uid"
        printf "  GID   : %s\n" "$gid"
        printf "  Shell : %s\n" "$shell"

        if [[ "$shell" == "/sbin/nologin" || "$shell" == "/bin/false" ]]; then
            printf "  ${GREEN}[OK]${NC}  Sin shell interactiva — seguro\n"
        else
            printf "  ${YELLOW}[!!]${NC}  Shell interactiva activa: %s\n" "$shell"
        fi
    else
        aputs_warning "Usuario '${usuario_svc}' no existe en el sistema"
    fi

    # ── Security conf de Apache (si aplica) ──────────────────────────────
    if [[ "$servicio" == "httpd" ]] && \
       sudo test -f "$HTTP_CONF_APACHE_SECURITY" 2>/dev/null; then
        echo ""
        draw_line
        echo ""
        aputs_info "security.conf (${HTTP_CONF_APACHE_SECURITY}):"
        echo ""
        sudo grep -vE "^\s*#|^\s*$" "$HTTP_CONF_APACHE_SECURITY" 2>/dev/null \
            | sed 's/^/    /'
    fi
}

http_menu_monitoreo() {
    while true; do
        clear
        draw_header "Monitoreo de Servicios HTTP"
        echo ""
        echo -e "  ${BLUE}1)${NC} Estado del servicio   (PID, memoria, CPU, uptime)"
        echo -e "  ${BLUE}2)${NC} Monitoreo de puertos  (escucha + firewall)"
        echo -e "  ${BLUE}3)${NC} Logs del servicio     (journalctl + resumen errores)"
        echo -e "  ${BLUE}4)${NC} Headers HTTP en vivo  (curl -I + auditoria seguridad)"
        echo -e "  ${BLUE}5)${NC} Configuracion activa  (directivas + webroot + usuario)"
        echo -e "  ${BLUE}6)${NC} Volver al menu principal"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1) http_monitoreo_estado;  echo ""; pause ;;
            2) http_monitoreo_puertos; echo ""; pause ;;
            3) http_monitoreo_logs;    echo ""; pause ;;
            4) http_monitoreo_headers; echo ""; pause ;;
            5) http_monitoreo_config;  echo ""; pause ;;
            6) return 0 ;;
            *) aputs_error "Opcion invalida. Seleccione entre 1 y 6"; sleep 2 ;;
        esac
    done
}

export -f http_monitoreo_estado
export -f http_monitoreo_puertos
export -f http_monitoreo_logs
export -f http_monitoreo_headers
export -f http_monitoreo_config
export -f http_menu_monitoreo
export -f _http_mon_estado_servicio
export -f _http_mon_firewall_puerto
export -f _http_mon_verificar_headers_seguridad