#!/bin/bash
#
# http_functions_B.sh
# Grupo B — Instalación de servicios HTTP
#
# Propósito del grupo:
#   Implementar el flujo encadenado completo de instalación:
#     Selección de servicio -> Consulta dinámica de versiones ->
#     Selección de versión -> Selección de puerto ->
#     Instalación silenciosa -> Configuración inicial automática
#
# Funciones públicas:
#   http_seleccionar_servicio()    — Menú de selección de servicio
#   http_consultar_versiones()     — Consulta dinámica desde dnf (sin hardcodear)
#   http_seleccionar_version()     — Muestra versiones y captura la elección
#   http_seleccionar_puerto()      — Captura y valida el puerto de escucha
#   http_instalar_apache()         — Instalación silenciosa de httpd
#   http_instalar_nginx()          — Instalación silenciosa de nginx
#   http_instalar_tomcat()         — Instalación + usuario + systemd unit
#   http_crear_usuario_dedicado()  — Usuario de sistema sin shell, permisos webroot
#   http_crear_index()             — index.html personalizado por servicio
#   http_menu_instalar()           — Orquestador del flujo completo
#
# Funciones internas (prefijo _):
#   _http_instalar_paquete()       — Wrapper dnf con manejo de errores
#   _http_configurar_puerto_inicial() — Aplica puerto al archivo de config
#   _http_habilitar_servicio()     — enable + start + verificación
#   _http_configurar_firewall_inicial() — Abre puerto nuevo, cierra default
#   _http_setup_apache()           — Post-instalación específica de Apache
#   _http_setup_nginx()            — Post-instalación específica de Nginx
#   _http_setup_tomcat()           — Post-instalación específica de Tomcat
#
# Requiere:
#   utils.sh, utils_http.sh, validators_http.sh, http_functions_A.sh
#

http_seleccionar_servicio() {
    local _var_destino="$1"

    clear
    http_draw_servicio_header "Selector de Servicio" "Paso 1 de 4"

    aputs_info "Servicios HTTP disponibles en Fedora Server:"
    echo ""
    echo -e "  ${BLUE}1)${NC} Apache (httpd)"
    echo "      Servidor web clasico. Modular, ampliamente documentado."
    echo "      Paquete dnf: httpd  |  Usuario: apache  |  Puerto default: 80"
    echo ""
    echo -e "  ${BLUE}2)${NC} Nginx"
    echo "      Servidor web / proxy inverso de alto rendimiento."
    echo "      Paquete dnf: nginx  |  Usuario: nginx   |  Puerto default: 80"
    echo ""
    echo -e "  ${BLUE}3)${NC} Tomcat"
    echo "      Servidor de aplicaciones Java (Jakarta EE / Servlets)."
    echo "      Requiere JDK instalado. Puerto default: 8080"
    echo ""

    local opcion
    while true; do
        agets "Seleccione el servicio [1-3]" opcion

        if ! http_validar_opcion_menu "$opcion" "3"; then
            echo ""
            continue
        fi

        # Verificar si ya está instalado — edge case: reinstalación
        local nombre_servicio
        case "$opcion" in
            1) nombre_servicio="httpd"  ;;
            2) nombre_servicio="nginx"  ;;
            3) nombre_servicio="tomcat" ;;
        esac

        local paquete
        paquete=$(http_nombre_paquete "$nombre_servicio")

        if rpm -q "$paquete" &>/dev/null; then
            local version_actual
            version_actual=$(rpm -q --queryformat "%{VERSION}" "$paquete" 2>/dev/null)
            echo ""
            aputs_warning "El servicio '$nombre_servicio' ya esta instalado (v${version_actual})"
            echo ""
            echo "  Opciones:"
            echo "    1) Reinstalar (desinstala primero y vuelve a instalar)"
            echo "    2) Solo reconfigurar (omite instalacion, va directo a config)"
            echo "    3) Cancelar"
            echo ""

            local op_reinstalar
            agets "Seleccione [1-3]" op_reinstalar

            case "$op_reinstalar" in
                1)
                    printf -v "$_var_destino" "reinstalar:${nombre_servicio}"
                    return 0
                    ;;
                2)
                    printf -v "$_var_destino" "reconfigurar:${nombre_servicio}"
                    return 0
                    ;;
                3|*)
                    printf -v "$_var_destino" "cancelar"
                    return 0
                    ;;
            esac
        fi

        printf -v "$_var_destino" "$nombre_servicio"
        return 0
    done
}

http_consultar_versiones() {
    local servicio="$1"
    local _array_destino="$2"

    local paquete
    paquete=$(http_nombre_paquete "$servicio")

    aputs_info "Consultando versiones disponibles de '${paquete}' en repositorios..."
    echo ""

    local versiones_raw
    versiones_raw=$(dnf repoquery \
                        --arch "$(uname -m)" \
                        --showduplicates \
                        --queryformat "%{version}-%{release}" \
                        "$paquete" 2>/dev/null \
                    | grep -v "^$" \
                    | sort -Vr \
                    | uniq)

    if [[ -z "$versiones_raw" ]]; then
        versiones_raw=$(dnf list --showduplicates "$paquete" 2>/dev/null \
                        | grep "^${paquete}" \
                        | awk '{print $2}' \
                        | sort -Vr \
                        | uniq)
    fi

    if rpm -q "$paquete" &>/dev/null; then
        local version_instalada
        version_instalada=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" \
                            "$paquete" 2>/dev/null)
        if [[ -n "$version_instalada" ]] && \
           ! echo "$versiones_raw" | grep -qF "$version_instalada"; then
            versiones_raw="${version_instalada}"$'\n'"${versiones_raw}"
            versiones_raw=$(echo "$versiones_raw" | grep -v "^$" | sort -Vr | uniq)
        fi
    fi

    if [[ -z "$versiones_raw" ]]; then
        aputs_warning "No se encontraron versiones para '${paquete}' en los repositorios"
        aputs_info "Verifique la conexion a internet y los repositorios habilitados:"
        aputs_info "  sudo dnf repolist"
        return 1
    fi

    local versiones_array=()
    while IFS= read -r linea; do
        [[ -n "$linea" ]] && versiones_array+=("$linea")
    done <<< "$versiones_raw"

    local -n _ref_array="$_array_destino"
    _ref_array=("${versiones_array[@]}")

    aputs_success "Se encontraron ${#versiones_array[@]} version(es) disponible(s)"
    return 0
}

http_seleccionar_version() {
    local servicio="$1"
    local _nombre_array="$2"
    local _var_version="$3"

    local -n _versiones_ref="$_nombre_array"
    local total="${#_versiones_ref[@]}"

    clear
    http_draw_servicio_header "Selector de Version — ${servicio}" "Paso 2 de 4"

    aputs_info "Versiones disponibles en repositorios (orden: mas reciente primero):"
    echo ""
    printf "  %-5s %-35s %-12s\n" "NUM" "VERSION" "ETIQUETA"
    echo "  ─"

    local i
    for i in "${!_versiones_ref[@]}"; do
        local num=$(( i + 1 ))
        local ver="${_versiones_ref[$i]}"
        local etiqueta=""

        if (( total == 1 )); then
            etiqueta="${GREEN}Latest${NC} / ${BLUE}Stable${NC}"
        elif (( i == 0 )); then
            etiqueta="${GREEN}Latest${NC}   — mas reciente, desarrollo activo"
        elif (( i == 1 && total >= 3 )); then
            etiqueta="${CYAN}Reciente${NC}  — un ciclo anterior, probada"
        elif (( i == total - 1 )); then
            etiqueta="${BLUE}Stable${NC}   — mayor tiempo en produccion"
        else
            local ciclos_atras=$(( i ))
            etiqueta="${GRAY}Anterior${NC}  — ${ciclos_atras} version(es) atras"
        fi

        printf "  %-5s %-38s " "$num)" "$ver"
        echo -e "$etiqueta"
    done

    echo ""
    aputs_info "Latest  = version mas reciente disponible en repositorios"
    aputs_info "Reciente= un ciclo de release atras, ampliamente probada"
    aputs_info "Stable  = version mas antigua disponible, maxima estabilidad"
    aputs_info "Anterior= versiones intermedias disponibles en el repo"
    echo ""

    local indice_elegido
    while true; do
        agets "Seleccione el numero de version [1-${total}]" indice_elegido

        if http_validar_indice_version "$indice_elegido" "$total"; then
            break
        fi
        echo ""
    done

    local idx=$(( indice_elegido - 1 ))
    local version_final="${_versiones_ref[$idx]}"

    printf -v "$_var_version" "%s" "$version_final"

    echo ""
    aputs_success "Version seleccionada: ${version_final}"
    return 0
}

http_seleccionar_puerto() {
    local servicio="$1"
    local _var_puerto="$2"

    clear
    http_draw_servicio_header "Selector de Puerto — ${servicio}" "Paso 3 de 4"

    local puerto_default
    case "$servicio" in
        httpd|apache) puerto_default="$HTTP_PUERTO_DEFAULT_APACHE" ;;
        nginx)        puerto_default="$HTTP_PUERTO_DEFAULT_NGINX"  ;;
        tomcat)       puerto_default="$HTTP_PUERTO_DEFAULT_TOMCAT" ;;
        *)            puerto_default="80" ;;
    esac

    aputs_info "Puertos comunes para servicios HTTP:"
    echo "    80   — HTTP estandar (requiere root)"
    echo "    8080 — Alternativa HTTP (Tomcat default)"
    echo "    8888 — Puerto de pruebas comun"
    echo "    443  — HTTPS (requiere certificado SSL)"
    echo ""
    aputs_info "Puerto por defecto para ${servicio}: ${puerto_default}"
    echo ""

    # Mostrar puertos actualmente ocupados para ayudar al usuario a elegir
    http_listar_puertos_activos
    echo ""

    local _puerto_sel="$puerto_default"
    while true; do
        agets "Puerto de escucha [Enter = ${puerto_default}]" _puerto_sel

        [[ -z "$_puerto_sel" ]] && _puerto_sel="$puerto_default"

        if http_validar_puerto "$_puerto_sel"; then
            break
        fi
        _puerto_sel="$puerto_default"
        echo ""
    done

    printf -v "$_var_puerto" "%s" "$_puerto_sel"

    echo ""
    aputs_success "Puerto seleccionado: ${_puerto_sel}/tcp"
    return 0
}

_http_instalar_paquete() {
    local paquete="$1"
    local version="$2"

    local _version_inst="$version"
    if [[ "$version" != *".fc"* && "$version" != *".el"* ]]; then
        local _dist_tag
        _dist_tag=$(rpm --eval "%{dist}" 2>/dev/null | tr -d '\n')
        [[ -n "$_dist_tag" ]] && _version_inst="${version}${_dist_tag}"
    fi
    local paquete_version="${paquete}-${_version_inst}"

    aputs_info "Instalando: ${paquete_version}"
    aputs_info "Comando: sudo dnf install -y ${paquete_version}"
    echo ""

    if sudo dnf install -y --best "${paquete_version}" &>/dev/null \
       | while IFS= read -r linea; do echo "    $linea"; done; then

        # Verificar que el paquete realmente quedó instalado
        if rpm -q "$paquete" &>/dev/null; then
            local version_instalada
            version_instalada=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" "$paquete")
            aputs_success "Instalado correctamente: ${paquete} v${version_instalada}"
            return 0
        else
            aputs_error "dnf reporto exito pero el paquete no aparece instalado"
            return 1
        fi
    else
        aputs_error "Error durante la instalacion de ${paquete_version}"
        aputs_info "Verifique: sudo dnf install -y ${paquete_version}"
        return 1
    fi
}

http_crear_usuario_dedicado() {
    local usuario="$1"
    local webroot="$2"

    aputs_info "Configurando usuario dedicado: ${usuario}"
    echo ""

    if id "$usuario" &>/dev/null; then
        aputs_success "Usuario '${usuario}' ya existe (creado por el paquete)"

        local shell_actual
        shell_actual=$(getent passwd "$usuario" | cut -d: -f7)

        if [[ "$shell_actual" != "/sbin/nologin" && "$shell_actual" != "/bin/false" ]]; then
            aputs_warning "Shell interactiva detectada en '${usuario}' — corrigiendo..."
            sudo usermod -s /sbin/nologin "$usuario"
            aputs_success "Shell cambiada a /sbin/nologin"
        else
            aputs_success "Sin shell interactiva — correcto"
        fi

    else
        aputs_info "Creando usuario del sistema '${usuario}'..."

        # -r: usuario del sistema 
        # -s /sbin/nologin: sin shell — nadie puede hacer 'su tomcat'
        # -d /dev/null: home apunta a /dev/null como medida adicional
        # -c: comentario descriptivo
        if sudo useradd -r -s /sbin/nologin -d /dev/null \
                        -c "Usuario del servicio ${usuario}" "$usuario" 2>/dev/null; then
            aputs_success "Usuario '${usuario}' creado correctamente"
        else
            aputs_error "No se pudo crear el usuario '${usuario}'"
            return 1
        fi
    fi

    echo ""

    # Crear webroot si no existe 
    if [[ ! -d "$webroot" ]]; then
        aputs_info "Creando directorio webroot: ${webroot}"
        sudo mkdir -p "$webroot"
    fi

    # Aplicar permisos sobre el webroot 
    sudo chown root:root "$webroot"
    sudo chmod 755 "$webroot"

    # El usuario del servicio necesita poder leer los archivos dentro del webroot
    sudo find "$webroot" -type f -exec sudo chmod 644 {} \; 2>/dev/null
    sudo find "$webroot" -type d -exec sudo chmod 755 {} \; 2>/dev/null

    aputs_success "Permisos aplicados en webroot: ${webroot}"
    printf "    Directorio : root:root  755\n"
    printf "    Archivos   : 644 (legibles por ${usuario})\n"

    return 0
}

http_crear_index() {
    local servicio="$1"
    local version="$2"
    local puerto="$3"

    local webroot
    webroot=$(http_get_webroot "$servicio")

    # Nombres amigables para mostrar en el HTML
    local nombre_display
    case "$servicio" in
        httpd)  nombre_display="Apache HTTP Server" ;;
        nginx)  nombre_display="Nginx"              ;;
        tomcat) nombre_display="Apache Tomcat"      ;;
        *)      nombre_display="$servicio"          ;;
    esac

    aputs_info "Generando index.html en ${webroot}..."

    # Crear el HTML con la información de la instalación
sudo tee "${webroot}/index.html" > /dev/null << EOF
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>${nombre_display}</title>
    <style>
        body { font-family: sans-serif; max-width: 500px; margin: 60px auto; color: #222; }
        h1   { border-bottom: 2px solid #222; padding-bottom: 8px; }
        td   { padding: 6px 16px 6px 0; }
        td:first-child { font-weight: bold; color: #555; }
    </style>
</head>
<body>
    <h1>${nombre_display}</h1>
    <p>Despliegue exitoso</p>
    <table>
        <tr><td>Version</td> <td>${version}</td></tr>
        <tr><td>Puerto</td>  <td>${puerto}/tcp</td></tr>
        <tr><td>Webroot</td> <td>${webroot}</td></tr>
        <tr><td>Usuario</td> <td>$(http_get_usuario_servicio "$servicio")</td></tr>
        <tr><td>Fecha</td>   <td>$(date '+%Y-%m-%d %H:%M')</td></tr>
    </table>
</body>
</html>
EOF

    if [[ $? -eq 0 ]]; then
        aputs_success "index.html generado correctamente"
        aputs_info "Verificar con: curl http://localhost:${puerto}"
        return 0
    else
        aputs_error "No se pudo escribir el index.html en ${webroot}"
        return 1
    fi
}

_http_registrar_puerto_selinux() {
    local puerto="$1"

    # Si SELinux no esta activo, no hace falta nada
    if ! command -v getenforce &>/dev/null; then
        return 0
    fi
    local modo_selinux
    modo_selinux=$(getenforce 2>/dev/null)
    if [[ "$modo_selinux" == "Disabled" ]]; then
        return 0
    fi

    aputs_info "SELinux activo (${modo_selinux}) — verificando registro del puerto ${puerto}..."

    # Verificar si el puerto ya esta registrado como http_port_t
    if sudo semanage port -l 2>/dev/null | grep -E "^http_port_t\s" | grep -qw "$puerto"; then
        aputs_info "Puerto ${puerto} ya registrado en SELinux como http_port_t"
        return 0
    fi

    # semanage viene del paquete policycoreutils-python-utils
    if ! command -v semanage &>/dev/null; then
        aputs_warning "semanage no disponible — instalando policycoreutils-python-utils..."
        if ! sudo dnf install -y policycoreutils-python-utils 2>/dev/null; then
            aputs_error "No se pudo instalar semanage — el servicio fallara en puertos no estandar"
            aputs_info "Instale manualmente: sudo dnf install policycoreutils-python-utils"
            aputs_info "Luego ejecute: sudo semanage port -a -t http_port_t -p tcp ${puerto}"
            return 1
        fi
    fi

    aputs_info "Registrando puerto ${puerto}/tcp en SELinux como http_port_t..."
    if sudo semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null; then
        aputs_success "Puerto ${puerto}/tcp registrado en SELinux (http_port_t)"
        return 0
    else
        if sudo semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null; then
            aputs_success "Puerto ${puerto}/tcp reasignado a http_port_t en SELinux"
            return 0
        else
            aputs_error "No se pudo registrar el puerto ${puerto} en SELinux"
            aputs_info "Intente manualmente: sudo semanage port -a -t http_port_t -p tcp ${puerto}"
            return 1
        fi
    fi
}

_http_configurar_puerto_inicial() {
    local servicio="$1"
    local puerto="$2"

    local archivo_conf
    archivo_conf=$(http_get_conf_archivo "$servicio")

    aputs_info "Configurando puerto ${puerto} en: ${archivo_conf}"

    # Backup obligatorio antes de cualquier edición
    if ! http_crear_backup "$archivo_conf"; then
        aputs_warning "Continuando sin backup (archivo puede ser nuevo)"
    fi

    echo ""

    case "$servicio" in

        # Apache (httpd) 
        httpd)
            # Guardia: si puerto llegó vacío, abortar antes de corromper el archivo
            if [[ -z "$puerto" ]]; then
                aputs_error "Puerto vacio — no se modificara httpd.conf"
                return 1
            fi
            if sudo grep -qE "^Listen\s" "$archivo_conf" 2>/dev/null; then
                # Reemplaza TODAS las directivas Listen (IPv4, IPv6, con y sin IP)
                # Primero: "Listen 80" o "Listen 80 " (sin IP)
                sudo sed -i -E "s/^Listen\s+[0-9]+\s*$/Listen ${puerto}/" \
                            "$archivo_conf"
                # Segundo: "Listen 0.0.0.0:80" (con IP explícita)
                sudo sed -i -E "s/^Listen\s+[0-9.]+:[0-9]+\s*$/Listen ${puerto}/" \
                            "$archivo_conf"
                # Tercero: "Listen [::]:80" (IPv6) — comentar para evitar conflicto
                sudo sed -i -E "s/^(Listen\s+\[::\]:[0-9]+)$/#\1 # desactivado por gestor HTTP/" \
                            "$archivo_conf"
                aputs_success "Puerto Apache actualizado: Listen ${puerto}"
            else
                echo "Listen ${puerto}" | sudo tee -a "$archivo_conf" > /dev/null
                aputs_success "Directiva Listen ${puerto} agregada a httpd.conf"
            fi
            ;;

        # Nginx 
        nginx)
            if sudo grep -qE "^\s+listen\s+[0-9]+" "$archivo_conf" 2>/dev/null; then
                sudo sed -i -E "s/(^\s+listen\s+)[0-9]+(;)/\1${puerto}\2/" \
                            "$archivo_conf"
                aputs_success "Puerto Nginx actualizado: listen ${puerto};"
            else
                aputs_warning "Directiva 'listen' no encontrada en nginx.conf"
                aputs_info "Verifique manualmente: ${archivo_conf}"
            fi
            ;;

        # Tomcat ─
        tomcat)
            if sudo grep -q 'protocol="HTTP/1.1"' "$archivo_conf" 2>/dev/null; then
                sudo sed -i -E \
                    "s/(Connector port=\")[0-9]+(\" protocol=\"HTTP\/1\.1\")/\1${puerto}\2/" \
                    "$archivo_conf"
                aputs_success "Puerto Tomcat actualizado: Connector port=\"${puerto}\""
            else
                aputs_warning "Conector HTTP/1.1 no encontrado en server.xml"
                aputs_info "Verifique manualmente: ${archivo_conf}"
            fi
            ;;
    esac

    # Registrar en SELinux ANTES del restart — sin esto el bind falla con Permission denied
    echo ""
    _http_registrar_puerto_selinux "$puerto"

    return 0
}

_http_habilitar_servicio() {
    local servicio="$1"
    local nombre_systemd
    nombre_systemd=$(http_nombre_systemd "$servicio")

    aputs_info "Habilitando ${nombre_systemd} en el boot..."
    if sudo systemctl enable "$nombre_systemd" 2>/dev/null; then
        aputs_success "Inicio automatico habilitado"
    else
        aputs_error "No se pudo habilitar ${nombre_systemd} en el boot"
        return 1
    fi

    echo ""
    aputs_info "Iniciando servicio ${nombre_systemd}..."

    if sudo systemctl restart "$nombre_systemd" 2>/dev/null; then
        sleep 2

        if check_service_active "$nombre_systemd"; then
            local pid
            pid=$(sudo systemctl show "$nombre_systemd" \
                  --property=MainPID --value 2>/dev/null)
            aputs_success "${nombre_systemd} activo — PID: ${pid}"
            return 0
        else
            aputs_error "${nombre_systemd} no levanto correctamente"
            aputs_info "Revise: sudo journalctl -u ${nombre_systemd} -n 20"
            return 1
        fi
    else
        aputs_error "Error al iniciar ${nombre_systemd}"
        sudo journalctl -u "$nombre_systemd" -n 10 --no-pager 2>/dev/null \
            | sed 's/^/    /'
        return 1
    fi
}

_http_configurar_firewall_inicial() {
    local servicio="$1"
    local puerto_nuevo="$2"

    aputs_info "Configurando firewall para puerto ${puerto_nuevo}/tcp..."
    echo ""

    # Verificar que firewalld está activo
    if ! sudo systemctl is-active --quiet firewalld 2>/dev/null; then
        aputs_warning "firewalld inactivo — iniciando..."
        sudo systemctl start firewalld 2>/dev/null
        sudo systemctl enable firewalld 2>/dev/null
    fi

    # Abrir el puerto nuevo 
    # --permanent: la regla persiste tras reinicios
    if ! sudo firewall-cmd --list-ports 2>/dev/null | grep -q "${puerto_nuevo}/tcp"; then
        if sudo firewall-cmd --permanent --add-port="${puerto_nuevo}/tcp" 2>/dev/null; then
            aputs_success "Puerto ${puerto_nuevo}/tcp abierto en firewall (permanente)"
        else
            aputs_error "No se pudo abrir el puerto ${puerto_nuevo}/tcp"
            return 1
        fi
    else
        aputs_info "Puerto ${puerto_nuevo}/tcp ya estaba abierto en firewall"
    fi

    # Cerrar el puerto default si se eligió uno diferente 
    local puerto_default
    case "$servicio" in
        httpd|nginx) puerto_default=80   ;;
        tomcat)      puerto_default=8080 ;;
    esac

    if (( puerto_nuevo != puerto_default )); then
        # Solo cerrar el puerto default si ningún otro proceso lo está usando
        if ! http_puerto_en_uso "$puerto_default"; then
            if (( puerto_default == 80 )); then
                sudo firewall-cmd --permanent --remove-service=http \
                     2>/dev/null && \
                aputs_success "Servicio 'http' (puerto 80) eliminado del firewall"
            fi
            # Quitar la regla de puerto directo si existe
            if sudo firewall-cmd --list-ports 2>/dev/null \
               | grep -q "${puerto_default}/tcp"; then
                sudo firewall-cmd --permanent \
                     --remove-port="${puerto_default}/tcp" 2>/dev/null && \
                aputs_success "Puerto ${puerto_default}/tcp cerrado en firewall"
            fi
        else
            aputs_info "Puerto default ${puerto_default} en uso por otro servicio — no se cierra"
        fi
    fi

    # Recargar para que las reglas permanentes sean efectivas ahora 
    sudo firewall-cmd --reload 2>/dev/null
    aputs_success "Firewall recargado — reglas activas"

    return 0
}

_http_setup_apache() {
    local puerto="$1"

    aputs_info "Aplicando configuracion post-instalacion de Apache..."
    echo ""

    # Asegurar que el webroot existe
    if [[ ! -d "$HTTP_WEBROOT_APACHE" ]]; then
        sudo mkdir -p "$HTTP_WEBROOT_APACHE"
        sudo chown root:root "$HTTP_WEBROOT_APACHE"
        sudo chmod 755 "$HTTP_WEBROOT_APACHE"
        aputs_success "Directorio /var/www/html creado"
    fi

    # Crear o actualizar security.conf con configuración mínima de seguridad
    sudo tee "$HTTP_CONF_APACHE_SECURITY" > /dev/null << 'EOF'
# security.conf — Configuracion de seguridad HTTP
# Generado por FunctionsHTTP-B.sh (instalacion inicial)
# FunctionsHTTP-C.sh aplica la configuracion avanzada de headers y metodos

# Ocultar version exacta del servidor en headers HTTP
ServerTokens Prod

# No mostrar informacion del servidor en paginas de error
ServerSignature Off
EOF

    aputs_success "security.conf aplicado: ServerTokens Prod, ServerSignature Off"
    return 0
}

_http_setup_nginx() {
    local puerto="$1"

    aputs_info "Aplicando configuracion post-instalacion de Nginx..."
    echo ""

    # server_tokens off: oculta la versión de Nginx en el header Server
    if sudo grep -q "server_tokens" "$HTTP_CONF_NGINX" 2>/dev/null; then
        sudo sed -i "s/server_tokens.*/server_tokens off;/" "$HTTP_CONF_NGINX"
    else
        # Insertar después de la línea que contiene "http {"
        sudo sed -i "/^http {/a\\    server_tokens off;" "$HTTP_CONF_NGINX"
    fi

    aputs_success "server_tokens off aplicado en nginx.conf"

    # Verificar sintaxis de nginx.conf antes de continuar
    if sudo nginx -t 2>/dev/null; then
        aputs_success "Sintaxis de nginx.conf: valida"
    else
        aputs_warning "Problema de sintaxis en nginx.conf — verificar manualmente"
        sudo nginx -t 2>&1 | sed 's/^/    /'
    fi

    return 0
}

_http_setup_tomcat() {
    local puerto="$1"

    aputs_info "Aplicando configuracion post-instalacion de Tomcat..."
    echo ""

    # Verificar Java 
    if ! command -v java &>/dev/null; then
        aputs_warning "Java no esta instalado — instalando java-17-openjdk..."
        if sudo dnf install -y java-17-openjdk 2>/dev/null; then
            aputs_success "java-17-openjdk instalado"
        else
            aputs_error "No se pudo instalar Java — Tomcat no funcionara sin JDK"
            return 1
        fi
    else
        local java_ver
        java_ver=$(java -version 2>&1 | head -1)
        aputs_success "Java encontrado: ${java_ver}"
    fi

    # Determinar rutas de instalación 
    # Si Tomcat fue instalado con dnf, el paquete lo deja en /usr/share/tomcat
    # CATALINA_HOME es la variable de entorno que Tomcat usa para encontrarse a sí mismo
    local catalina_home="${CATALINA_HOME:-/usr/share/tomcat}"
    local java_home
    java_home=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")

    aputs_info "CATALINA_HOME : ${catalina_home}"
    aputs_info "JAVA_HOME     : ${java_home}"
    echo ""

    # Crear unit file de systemd si no existe 
    local unit_file="/etc/systemd/system/tomcat.service"

    if [[ ! -f "$unit_file" ]] && [[ ! -f "/usr/lib/systemd/system/tomcat.service" ]]; then
        aputs_info "Creando unit file de systemd para Tomcat..."

        sudo tee "$unit_file" > /dev/null << EOF
[Unit]
Description=Apache Tomcat Web Application Container
After=network.target

[Service]
Type=forking
User=${HTTP_USUARIO_TOMCAT}
Group=${HTTP_USUARIO_TOMCAT}
Environment="JAVA_HOME=${java_home}"
Environment="CATALINA_HOME=${catalina_home}"
Environment="CATALINA_BASE=${catalina_home}"
Environment="CATALINA_PID=${catalina_home}/temp/tomcat.pid"
ExecStart=${catalina_home}/bin/startup.sh
ExecStop=${catalina_home}/bin/shutdown.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

        sudo systemctl daemon-reload
        aputs_success "Unit file creado: ${unit_file}"
    else
        aputs_success "Unit file de Tomcat ya existe"
    fi

    # Configurar permisos de directorios de Tomcat 
    # El usuario tomcat necesita escribir en logs, work y temp
    local dirs_tomcat=("logs" "work" "temp")
    local dir
    for dir in "${dirs_tomcat[@]}"; do
        local ruta_dir="${catalina_home}/${dir}"
        if [[ -d "$ruta_dir" ]]; then
            sudo chown -R "${HTTP_USUARIO_TOMCAT}:${HTTP_USUARIO_TOMCAT}" "$ruta_dir"
            aputs_success "Permisos aplicados: ${ruta_dir} -> ${HTTP_USUARIO_TOMCAT}"
        fi
    done

    return 0
}

# 
# http_instalar_apache
# http_instalar_nginx
# http_instalar_tomcat
#
# Funciones públicas de instalación por servicio.
# Cada una orquesta los pasos específicos de su servicio en el orden correcto:
#   1. Crear usuario dedicado (si aplica antes del paquete)
#   2. Instalar paquete con dnf
#   3. Setup post-instalación específico
#   4. Configurar puerto en archivo de configuración
#   5. Habilitar e iniciar el servicio
#   6. Configurar firewall
#   7. Crear index.html personalizado
#
# Uso: http_instalar_apache "2.4.62-1.fc41" "8080"
# 
http_instalar_apache() {
    local version="$1"
    local puerto="$2"

    http_draw_servicio_header "Apache (httpd)" "Paso 4 de 4 — Instalacion"

    # Paso 1: Instalar paquete
    draw_line
    aputs_info "PASO 1/5 — Instalacion del paquete"
    draw_line
    if ! _http_instalar_paquete "httpd" "$version"; then
        return 1
    fi

    echo ""
    # Paso 2: Usuario dedicado (httpd lo crea el paquete, pero verificamos)
    draw_line
    aputs_info "PASO 2/5 — Usuario dedicado"
    draw_line
    http_crear_usuario_dedicado "$HTTP_USUARIO_APACHE" "$HTTP_WEBROOT_APACHE"

    echo ""
    # Paso 3: Setup específico de Apache
    draw_line
    aputs_info "PASO 3/5 — Configuracion post-instalacion"
    draw_line
    _http_setup_apache "$puerto"

    echo ""
    # Paso 4: Configurar puerto
    draw_line
    aputs_info "PASO 4/5 — Configuracion de puerto"
    draw_line
    _http_configurar_puerto_inicial "httpd" "$puerto"

    echo ""
    # Paso 5: Habilitar servicio + firewall + index
    draw_line
    aputs_info "PASO 5/5 — Activacion del servicio"
    draw_line
    if ! _http_habilitar_servicio "httpd"; then
        return 1
    fi
    echo ""
    _http_configurar_firewall_inicial "httpd" "$puerto"
    echo ""
    http_crear_index "httpd" "$version" "$puerto"

    echo ""
    http_draw_resumen "Apache (httpd)" "$puerto" "$version"
    return 0
}

http_instalar_nginx() {
    local version="$1"
    local puerto="$2"

    http_draw_servicio_header "Nginx" "Paso 4 de 4 — Instalacion"

    draw_line
    aputs_info "PASO 1/5 — Instalacion del paquete"
    draw_line
    if ! _http_instalar_paquete "nginx" "$version"; then
        return 1
    fi

    echo ""
    draw_line
    aputs_info "PASO 2/5 — Usuario dedicado"
    draw_line
    http_crear_usuario_dedicado "$HTTP_USUARIO_NGINX" "$HTTP_WEBROOT_NGINX"

    echo ""
    draw_line
    aputs_info "PASO 3/5 — Configuracion post-instalacion"
    draw_line
    _http_setup_nginx "$puerto"

    echo ""
    draw_line
    aputs_info "PASO 4/5 — Configuracion de puerto"
    draw_line
    _http_configurar_puerto_inicial "nginx" "$puerto"

    echo ""
    draw_line
    aputs_info "PASO 5/5 — Activacion del servicio"
    draw_line
    if ! _http_habilitar_servicio "nginx"; then
        return 1
    fi
    echo ""
    _http_configurar_firewall_inicial "nginx" "$puerto"
    echo ""
    http_crear_index "nginx" "$version" "$puerto"

    echo ""
    http_draw_resumen "Nginx" "$puerto" "$version"
    return 0
}

http_instalar_tomcat() {
    local version="$1"
    local puerto="$2"

    http_draw_servicio_header "Tomcat" "Paso 4 de 4 — Instalacion"

    draw_line
    aputs_info "PASO 1/5 — Instalacion del paquete"
    draw_line
    if ! _http_instalar_paquete "tomcat" "$version"; then
        return 1
    fi

    echo ""
    draw_line
    aputs_info "PASO 2/5 — Usuario dedicado"
    draw_line
    http_crear_usuario_dedicado "$HTTP_USUARIO_TOMCAT" "$(http_get_webroot tomcat)"

    echo ""
    draw_line
    aputs_info "PASO 3/5 — Configuracion post-instalacion (Java + systemd)"
    draw_line
    if ! _http_setup_tomcat "$puerto"; then
        return 1
    fi

    echo ""
    draw_line
    aputs_info "PASO 4/5 — Configuracion de puerto"
    draw_line
    _http_configurar_puerto_inicial "tomcat" "$puerto"

    echo ""
    draw_line
    aputs_info "PASO 5/5 — Activacion del servicio"
    draw_line
    if ! _http_habilitar_servicio "tomcat"; then
        return 1
    fi
    echo ""
    _http_configurar_firewall_inicial "tomcat" "$puerto"
    echo ""
    http_crear_index "tomcat" "$version" "$puerto"

    echo ""
    http_draw_resumen "Tomcat" "$puerto" "$version"
    return 0
}

http_menu_instalar() {
    # Paso 1: Selección de servicio 
    local seleccion_servicio
    http_seleccionar_servicio seleccion_servicio

    # Gestionar edge cases de la selección
    case "$seleccion_servicio" in
        cancelar)
            aputs_info "Instalacion cancelada"
            sleep 2
            return 0
            ;;
        reinstalar:*)
            # Extraer el nombre del servicio después de "reinstalar:"
            local servicio="${seleccion_servicio#reinstalar:}"
            aputs_warning "Desinstalando version actual de ${servicio}..."
            sudo dnf remove -y "$(http_nombre_paquete "$servicio")" 2>/dev/null
            aputs_success "Desinstalado. Continuando con instalacion limpia..."
            sleep 2
            ;;
        reconfigurar:*)
            # El usuario solo quiere reconfigurar — saltar la instalación
            local servicio="${seleccion_servicio#reconfigurar:}"
            aputs_info "Modo reconfiguracion — omitiendo instalacion del paquete"
            local version_actual
            version_actual=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" \
                             "$(http_nombre_paquete "$servicio")" 2>/dev/null)

            local puerto_reconfig
            http_seleccionar_puerto "$servicio" puerto_reconfig

            # 1. Editar config   2. Restart (valida que el puerto funciona)
            # 3. Firewall        4. Index
            # El restart debe ir ANTES del firewall para detectar fallos
            # (ej: puerto privilegiado) antes de tocar las reglas de red.
            _http_configurar_puerto_inicial "$servicio" "$puerto_reconfig"
            echo ""

            if ! http_reiniciar_servicio "$servicio"; then
                aputs_error "El servicio no levanto con el nuevo puerto — revise:"
                sudo journalctl -u "$(http_nombre_systemd "$servicio")" \
                     -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
                echo ""
                aputs_info "Posibles causas:"
                echo "    - Puerto privilegiado (<1024) sin permisos: usar puerto >= 1024"
                echo "    - Puerto ya ocupado por otro proceso: use 'ss -tlnp'"
                echo "    - Error de sintaxis en el archivo de config"
                pause
                return 1
            fi
            echo ""

            _http_configurar_firewall_inicial "$servicio" "$puerto_reconfig"
            echo ""
            http_crear_index "$servicio" "$version_actual" "$puerto_reconfig"

            echo ""
            http_draw_resumen "$servicio" "$puerto_reconfig" "$version_actual"
            echo ""
            pause
            return 0
            ;;
        *)
            local servicio="$seleccion_servicio"
            ;;
    esac

    echo ""
    pause

    # Paso 2: Consultar versiones desde dnf 
    local versiones_disponibles=()
    if ! http_consultar_versiones "$servicio" versiones_disponibles; then
        aputs_error "No se pudieron obtener versiones. Verifique la conexion."
        echo ""
        pause
        return 1
    fi

    echo ""
    pause

    # Paso 3: Selección de versión 
    local version_elegida
    http_seleccionar_version "$servicio" versiones_disponibles version_elegida

    echo ""
    pause

    # Paso 4: Selección de puerto ─
    local puerto_elegido
    http_seleccionar_puerto "$servicio" puerto_elegido

    echo ""

    # Confirmación final antes de instalar 
    draw_line
    aputs_info "Resumen de la instalacion a realizar:"
    echo ""
    printf "    Servicio : %s\n" "$servicio"
    printf "    Version  : %s\n" "$version_elegida"
    printf "    Puerto   : %s/tcp\n" "$puerto_elegido"
    echo ""

    local confirmacion
    while true; do
        agets "Confirmar instalacion? [s/n]" confirmacion
        local resultado
        http_validar_confirmacion "$confirmacion"
        resultado=$?

        if (( resultado == 0 )); then
            break              # Confirmado -> continuar
        elif (( resultado == 1 )); then
            aputs_info "Instalacion cancelada"
            sleep 2
            # Negado -> salir limpiamente
            return 0  
        fi
        # resultado == 2 -> entrada inválida, repetir
        echo ""    
    done

    draw_line
    echo ""

    # Paso 5: Ejecutar la instalación según el servicio 
    case "$servicio" in
        httpd)  http_instalar_apache "$version_elegida" "$puerto_elegido" ;;
        nginx)  http_instalar_nginx  "$version_elegida" "$puerto_elegido" ;;
        tomcat) http_instalar_tomcat "$version_elegida" "$puerto_elegido" ;;
    esac

    echo ""
    pause
}

export -f http_seleccionar_servicio
export -f http_consultar_versiones
export -f http_seleccionar_version
export -f http_seleccionar_puerto
export -f http_crear_usuario_dedicado
export -f http_crear_index
export -f http_instalar_apache
export -f http_instalar_nginx
export -f http_instalar_tomcat
export -f http_menu_instalar
export -f _http_instalar_paquete
export -f _http_registrar_puerto_selinux
export -f _http_configurar_puerto_inicial
export -f _http_habilitar_servicio
export -f _http_configurar_firewall_inicial
export -f _http_setup_apache
export -f _http_setup_nginx
export -f _http_setup_tomcat