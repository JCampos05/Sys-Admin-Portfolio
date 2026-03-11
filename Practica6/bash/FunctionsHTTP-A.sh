#!/bin/bash
#
# Grupo A — Verificación de estado de servicios HTTP
#
# Propósito del grupo:
#   Consultar el estado actual del sistema sin modificar nada.
#   Todas las funciones aquí son de SOLO LECTURA.
#   Los otros grupos (B, C, D, E) llaman a estas funciones antes de actuar.
#
# Funciones:
#   http_verificar_estado()           — Estado de los tres servicios (panel general)
#   http_verificar_puerto_disponible() — Consulta si un puerto está libre
#   http_verificar_usuario_servicio()  — Valida usuario dedicado y sus permisos
#   http_menu_verificar()             — Submenú interactivo del grupo A
#
# Requiere:
#   utils.sh, utils_http.sh, validators_http.sh cargados previamente
#

http_verificar_estado() {
    clear
    draw_header "Verificacion de Servicios HTTP"

    local servicios=("httpd" "nginx" "tomcat")
    local nombres=("Apache (httpd)" "Nginx" "Tomcat")
    local puertos_default=(80 80 8080)

    local i
    for i in "${!servicios[@]}"; do
        local servicio="${servicios[$i]}"
        local nombre="${nombres[$i]}"
        local puerto_default="${puertos_default[$i]}"

        echo ""
        echo -e "  ${CYAN} ${nombre}${NC}"
        echo "  ──"

        # rpm -q devuelve el nombre completo con versión si está instalado,
        # o un mensaje de error si no lo está
        local paquete
        paquete=$(http_nombre_paquete "$servicio")

        if rpm -q "$paquete" &>/dev/null; then
            local version_rpm
            version_rpm=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" "$paquete" 2>/dev/null)
            printf "  ${GREEN}[OK]${NC}  Instalado    : %s\n" "$version_rpm"
        else
            printf "  ${GRAY}[--]${NC}  Instalado    : No instalado\n"
            echo ""
            continue
        fi

        # is-active retorna 0 (activo) o 1 (inactivo/fallido)
        local nombre_systemd
        nombre_systemd=$(http_nombre_systemd "$servicio")

        if check_service_active "$nombre_systemd"; then
            local pid
            pid=$(sudo systemctl show "$nombre_systemd" \
                  --property=MainPID --value 2>/dev/null)
            printf "  ${GREEN}[OK]${NC}  Servicio     : ACTIVO (PID: %s)\n" "$pid"
        else
            local estado_detalle
            estado_detalle=$(sudo systemctl is-active "$nombre_systemd" 2>/dev/null)
            printf "  ${RED}[!!]${NC}  Servicio     : INACTIVO (%s)\n" "$estado_detalle"
        fi

        # Habilitado en boot 
        if check_service_enabled "$nombre_systemd"; then
            printf "  ${GREEN}[OK]${NC}  Inicio boot  : Habilitado\n"
        else
            printf "  ${YELLOW}[!!]${NC}  Inicio boot  : Deshabilitado\n"
        fi

        # Buscamos en ss -tlnp el proceso correspondiente al servicio
        # para extraer el puerto real que está usando en este momento
        local puerto_activo
        puerto_activo=$(_http_obtener_puerto_activo "$nombre_systemd")

        if [[ -n "$puerto_activo" ]]; then
            printf "  ${GREEN}[OK]${NC}  Puerto       : %s/tcp en escucha\n" "$puerto_activo"
        else
            printf "  ${YELLOW}[--]${NC}  Puerto       : Sin puerto en escucha\n"
        fi

        local webroot
        webroot=$(http_get_webroot "$servicio")

        if [[ -d "$webroot" ]]; then
            local archivos
            archivos=$(find "$webroot" -maxdepth 1 -type f 2>/dev/null | wc -l)
            printf "  ${GREEN}[OK]${NC}  Webroot      : %s (%s archivo(s))\n" \
                   "$webroot" "$archivos"
        else
            printf "  ${GRAY}[--]${NC}  Webroot      : %s (no existe)\n" "$webroot"
        fi

        echo ""
    done

    draw_line
    aputs_info "Para instalar un servicio: opcion 2) del menu principal"
    aputs_info "Para iniciar un servicio:  sudo systemctl start <servicio>"
}


_http_obtener_puerto_activo() {
    local nombre_systemd="$1"

    local puerto
    puerto=$(sudo ss -tlnp 2>/dev/null \
             | grep "\"${nombre_systemd}\"" \
             | awk '{print $4}' \
             | grep -oP ':\K[0-9]+' \
             | head -1)

    echo "$puerto"
}


http_verificar_puerto_disponible() {
    clear
    draw_header "Verificar Disponibilidad de Puerto"

    echo ""

    # Solicitar el puerto a verificar con validación de formato básico
    local puerto
    while true; do
        agets "Puerto a verificar (ej: 8080)" puerto

        if [[ ! "$puerto" =~ ^[0-9]+$ ]]; then
            aputs_error "Ingrese un numero de puerto valido"
            echo ""
            continue
        fi

        if (( puerto < 1 || puerto > 65535 )); then
            aputs_error "Puerto fuera de rango (1-65535)"
            echo ""
            continue
        fi

        break
    done

    echo ""
    draw_line
    aputs_info "Diagnostico del puerto ${puerto}/tcp:"
    echo ""

    # 1. Estado de uso 
    if http_puerto_en_uso "$puerto"; then
        local proceso
        proceso=$(http_quien_usa_puerto "$puerto")
        printf "  ${RED}[OCUPADO]${NC}  Puerto %s esta en uso por: %s\n" \
               "$puerto" "$proceso"

        # Mostrar detalles completos del socket
        echo ""
        aputs_info "Detalle del socket:"
        sudo ss -tlnp 2>/dev/null \
            | grep ":${puerto} " \
            | awk '{printf "    Estado: %s  |  Direccion: %s\n", $1, $4}'
    else
        printf "  ${GREEN}[LIBRE]${NC}    Puerto %s esta disponible\n" "$puerto"
    fi

    echo ""

    # Se verifica si firewalld tiene una regla que permita este puerto
    aputs_info "Estado en firewalld:"
    echo ""

    if sudo systemctl is-active --quiet firewalld 2>/dev/null; then
        # Verificar por número de puerto directo
        if sudo firewall-cmd --list-ports 2>/dev/null | grep -q "${puerto}/tcp"; then
            printf "  ${GREEN}[ABIERTO]${NC}  Puerto %s/tcp permitido en firewall\n" "$puerto"

        # HTTP/HTTPS en puerto 80/443 pueden estar permitidos por nombre de servicio
        elif (( puerto == 80 )) && \
             sudo firewall-cmd --list-services 2>/dev/null | grep -qw "http"; then
            printf "  ${GREEN}[ABIERTO]${NC}  Servicio 'http' permitido (puerto 80)\n"

        elif (( puerto == 443 )) && \
             sudo firewall-cmd --list-services 2>/dev/null | grep -qw "https"; then
            printf "  ${GREEN}[ABIERTO]${NC}  Servicio 'https' permitido (puerto 443)\n"

        else
            printf "  ${YELLOW}[CERRADO]${NC} Puerto %s/tcp NO tiene regla en firewall\n" "$puerto"
            aputs_info "  Para abrirlo: sudo firewall-cmd --permanent --add-port=${puerto}/tcp"
        fi
    else
        printf "  ${YELLOW}[INFO]${NC}    firewalld esta inactivo — sin restricciones de puerto\n"
    fi

    echo ""

    aputs_info "Clasificacion:"
    echo ""

    # Tipo de puerto 
    if (( puerto < 1024 )); then
        printf "  Tipo     : Puerto privilegiado (sistema) — requiere root\n"
    elif (( puerto >= 1024 && puerto <= 49151 )); then
        printf "  Tipo     : Puerto registrado (aplicaciones)\n"
    else
        printf "  Tipo     : Puerto dinamico/efimero\n"
    fi

    # Verificar si es un puerto reservado 
    local es_reservado=false
    local p
    for p in "${HTTP_PUERTOS_RESERVADOS[@]}"; do
        if (( puerto == p )); then
            es_reservado=true
            break
        fi
    done

    if $es_reservado; then
        printf "  ${RED}Reservado${NC} : Si — usado por otro servicio del sistema\n"
    else
        printf "  Reservado : No — disponible para servicios HTTP\n"
    fi
}


http_verificar_usuario_servicio() {
    clear
    draw_header "Verificar Usuario Dedicado de Servicio"

    echo ""
    aputs_info "Servicios disponibles:"
    echo "    1) Apache (httpd)"
    echo "    2) Nginx"
    echo "    3) Tomcat"
    echo ""

    # Selección del servicio a verificar
    local opcion
    while true; do
        agets "Servicio a verificar [1-3]" opcion
        if http_validar_opcion_menu "$opcion" "3"; then
            break
        fi
        echo ""
    done

    # Resolver nombre del servicio y usuario a partir de la opción
    local servicio usuario webroot
    case "$opcion" in
        1) servicio="httpd";  usuario="$HTTP_USUARIO_APACHE"; webroot="$HTTP_WEBROOT_APACHE" ;;
        2) servicio="nginx";  usuario="$HTTP_USUARIO_NGINX";  webroot="$HTTP_WEBROOT_NGINX"  ;;
        3) servicio="tomcat"; usuario="$HTTP_USUARIO_TOMCAT";
           webroot=$(http_get_webroot "tomcat") ;;
    esac

    echo ""
    draw_line
    echo -e "  ${CYAN}Verificando usuario '${usuario}' para ${servicio}${NC}"
    draw_line
    echo ""

    if id "$usuario" &>/dev/null; then
        local uid gid shell home
        uid=$(id -u "$usuario" 2>/dev/null)
        gid=$(id -g "$usuario" 2>/dev/null)
        shell=$(getent passwd "$usuario" | cut -d: -f7)
        home=$(getent passwd "$usuario" | cut -d: -f6)

        printf "  ${GREEN}[OK]${NC}  Usuario existe\n"
        printf "        UID   : %s\n" "$uid"
        printf "        GID   : %s\n" "$gid"
        printf "        Shell : %s\n" "$shell"
        printf "        Home  : %s\n" "$home"
        echo ""

        # Sin shell interactiva 
        # Los usuarios de servicio deben tener /sbin/nologin o /bin/false
        if [[ "$shell" == "/sbin/nologin" || "$shell" == "/bin/false" ]]; then
            printf "  ${GREEN}[OK]${NC}  Sin shell interactiva — acceso directo bloqueado\n"
        else
            printf "  ${YELLOW}[!!]${NC}  Shell interactiva activa: %s\n" "$shell"
            aputs_info "  Recomendacion: sudo usermod -s /sbin/nologin $usuario"
        fi

        # ── 3. Propiedad del webroot 
        if [[ -d "$webroot" ]]; then
            local propietario
            propietario=$(stat -c '%U' "$webroot" 2>/dev/null)
            local permisos
            permisos=$(stat -c '%a' "$webroot" 2>/dev/null)

            if [[ "$propietario" == "$usuario" || "$propietario" == "root" ]]; then
                printf "  ${GREEN}[OK]${NC}  Webroot %-30s propietario: %s (permisos: %s)\n" \
                       "$webroot" "$propietario" "$permisos"
            else
                printf "  ${YELLOW}[!!]${NC}  Webroot %-30s propietario: %s (esperado: %s)\n" \
                       "$webroot" "$propietario" "$usuario"
            fi
        else
            printf "  ${YELLOW}[--]${NC}  Webroot no existe: %s\n" "$webroot"
        fi

        # El usuario del servicio NO debe poder leer /etc/shadow, /root, etc.
        echo ""
        aputs_info "Verificacion de acceso a directorios sensibles:"
        echo ""

        local dirs_sensibles=("/root" "/home" "/etc/shadow" "/etc/sudoers")
        local dir
        for dir in "${dirs_sensibles[@]}"; do
            if [[ -e "$dir" ]]; then
                # Usamos sudo -u para intentar listar/leer como el usuario del servicio
                if sudo -u "$usuario" test -r "$dir" 2>/dev/null; then
                    printf "  ${YELLOW}[!!]${NC}  %-20s accesible (revisar permisos)\n" "$dir"
                else
                    printf "  ${GREEN}[OK]${NC}  %-20s bloqueado correctamente\n" "$dir"
                fi
            fi
        done

    else
        printf "  ${YELLOW}[--]${NC}  Usuario '%s' no existe en el sistema\n" "$usuario"
        aputs_info "  Se creara automaticamente al instalar el servicio (opcion 2)"
    fi

    echo ""
    draw_line
}

http_menu_verificar() {
    while true; do
        clear
        draw_header "Verificacion de Servicios HTTP"
        echo ""
        echo -e "  ${BLUE}1)${NC} Panel general de servicios"
        echo -e "  ${BLUE}2)${NC} Verificar disponibilidad de puerto"
        echo -e "  ${BLUE}3)${NC} Verificar usuario dedicado de servicio"
        echo -e "  ${BLUE}4)${NC} Volver al menu principal"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1)
                http_verificar_estado
                echo ""
                pause
                ;;
            2)
                http_verificar_puerto_disponible
                echo ""
                pause
                ;;
            3)
                http_verificar_usuario_servicio
                echo ""
                pause
                ;;
            4)
                return 0
                ;;
            *)
                aputs_error "Opcion invalida. Seleccione entre 1 y 4"
                sleep 2
                ;;
        esac
    done
}

# ───────────────────────────
#   EXPORTAR FUNCIONES DEL GRUPO A
# ───────────────────────────

export -f http_verificar_estado
export -f _http_obtener_puerto_activo
export -f http_verificar_puerto_disponible
export -f http_verificar_usuario_servicio
export -f http_menu_verificar