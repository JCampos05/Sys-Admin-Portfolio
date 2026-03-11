#!/bin/bash
#
# validators_http.sh
# Validaciones específicas para la gestión de servicios HTTP
#
# Requiere:
#   utils.sh     debe estar cargado antes (aputs_error / aputs_info)
#   utils_http.sh debe estar cargado antes (constantes HTTP_*)
#

http_validar_puerto() {
    local puerto="$1"

    # ── Verificación 1: Formato — debe ser un número entero positivo ──────────
    # La regex ^[0-9]+$ rechaza letras, espacios, signos negativos y decimales
    if [[ ! "$puerto" =~ ^[0-9]+$ ]]; then
        aputs_error "El puerto debe ser un numero entero positivo"
        aputs_info "Ejemplos validos: 80, 8080, 8888"
        return 1
    fi

    # ── Verificación 2: El puerto 0 está reservado por el kernel ─────────────
    if (( puerto == 0 )); then
        aputs_error "El puerto 0 esta reservado por el sistema operativo"
        return 1
    fi

    # ── Verificación 3: Rango TCP válido ──────────────────────────────────────
    # El protocolo TCP define puertos de 16 bits: 1 a 65535
    if (( puerto < 1 || puerto > 65535 )); then
        aputs_error "Puerto fuera de rango. Debe estar entre 1 y 65535"
        return 1
    fi

    # ── Verificación 4: Puertos bien conocidos (1-1023) ───────────────────────
    # Requieren ejecución como root; advertimos pero no bloqueamos
    if (( puerto < 1024 )); then
        aputs_warning "El puerto $puerto es un puerto privilegiado (requiere root)"
        aputs_info "Se recomienda usar puertos >= 1024 para servicios de prueba"
    fi

    # ── Verificación 5: Puertos reservados para otros servicios ───────────────
    # Comparamos contra la lista HTTP_PUERTOS_RESERVADOS de utils_http.sh
    # Ejemplo: puerto 22 es SSH — no debe pisarse
    local reservado
    for reservado in "${HTTP_PUERTOS_RESERVADOS[@]}"; do
        if (( puerto == reservado )); then
            aputs_error "El puerto $puerto esta reservado para otro servicio del sistema"
            aputs_info "Puertos reservados: ${HTTP_PUERTOS_RESERVADOS[*]}"
            aputs_info "Elija un puerto diferente"
            return 1
        fi
    done

    # ── Verificación 6: Puerto actualmente en uso ──────────────────────────────
    # Usamos la función http_puerto_en_uso de utils_http.sh
    if http_puerto_en_uso "$puerto"; then
        local proceso_ocupante
        proceso_ocupante=$(http_quien_usa_puerto "$puerto")
        # dnf arranca el servicio automáticamente al instalar el paquete.
        # Si el puerto lo ocupa el propio httpd/nginx/tomcat no es un conflicto —
        # la instalación sobreescribirá la configuración.
        # ss puede devolver el nombre corto ("httpd") o la ruta completa ("/usr/sbin/httpd")
        if echo "$proceso_ocupante" | grep -qE "(^|/)(httpd|nginx|tomcat)$"; then
            aputs_warning "Puerto $puerto en uso por '${proceso_ocupante}' (servicio HTTP)"
            aputs_info "Se aceptara — el instalador sobreescribira la configuracion"
            aputs_success "Puerto $puerto aceptado"
            return 0
        fi
        aputs_error "El puerto $puerto ya esta en uso por: ${proceso_ocupante}"
        aputs_info "Use 'ss -tlnp' para ver todos los puertos activos"
        aputs_info "Elija un puerto diferente"
        return 1
    fi

    # Puerto válido y disponible
    aputs_success "Puerto $puerto disponible"
    return 0
}

http_validar_puerto_cambio() {
    local puerto_nuevo="$1"
    local puerto_actual="$2"

    # Formato y rango (igual que la función base)
    if [[ ! "$puerto_nuevo" =~ ^[0-9]+$ ]]; then
        aputs_error "El puerto debe ser un numero entero positivo"
        return 1
    fi

    if (( puerto_nuevo == 0 )); then
        aputs_error "El puerto 0 esta reservado por el sistema operativo"
        return 1
    fi

    if (( puerto_nuevo < 1 || puerto_nuevo > 65535 )); then
        aputs_error "Puerto fuera de rango. Debe estar entre 1 y 65535"
        return 1
    fi

    # No tiene sentido "cambiar" al mismo puerto
    if [[ "$puerto_nuevo" == "$puerto_actual" ]]; then
        aputs_warning "El puerto nuevo ($puerto_nuevo) es igual al actual"
        aputs_info "Seleccione un puerto diferente al actual ($puerto_actual)"
        return 1
    fi

    # Puertos reservados del sistema
    local reservado
    for reservado in "${HTTP_PUERTOS_RESERVADOS[@]}"; do
        if (( puerto_nuevo == reservado )); then
            aputs_error "El puerto $puerto_nuevo esta reservado para otro servicio"
            return 1
        fi
    done

    # Verificar si está en uso (pero ignorar el puerto actual del propio servicio)
    if http_puerto_en_uso "$puerto_nuevo"; then
        local proceso_ocupante
        proceso_ocupante=$(http_quien_usa_puerto "$puerto_nuevo")
        aputs_error "El puerto $puerto_nuevo ya esta en uso por: ${proceso_ocupante}"
        return 1
    fi

    aputs_success "Puerto $puerto_nuevo disponible para el cambio"
    return 0
}

http_validar_servicio() {
    local entrada="$1"

    if [[ -z "$entrada" ]]; then
        aputs_error "Debe seleccionar un servicio"
        aputs_info "Opciones: 1) Apache (httpd)  2) Nginx  3) Tomcat"
        return 1
    fi

    # Aceptamos número de menú o nombre textual (case-insensitive)
    local entrada_lower="${entrada,,}"

    case "$entrada_lower" in
        1|apache|httpd)
            # Válido
            ;;
        2|nginx)
            # Válido
            ;;
        3|tomcat)
            # Válido
            ;;
        iis|"apache win"|"nginx win")
            aputs_error "El servicio '$entrada' es exclusivo de Windows"
            aputs_info "En Fedora Linux los servicios disponibles son: Apache, Nginx, Tomcat"
            return 1
            ;;
        *)
            aputs_error "Servicio no reconocido: '$entrada'"
            aputs_info "Servicios disponibles en Linux:"
            echo "    1) Apache (httpd) — servidor web clasico"
            echo "    2) Nginx          — servidor web / proxy inverso"
            echo "    3) Tomcat         — servidor de aplicaciones Java"
            return 1
            ;;
    esac

    return 0
}

http_validar_version() {
    local version_elegida="$1"
    # El resto de los argumentos es el array de versiones disponibles
    shift
    local versiones_disponibles=("$@")

    if [[ -z "$version_elegida" ]]; then
        aputs_error "Debe especificar una version"
        return 1
    fi

    # Verificar que la versión exista en la lista
    local version
    for version in "${versiones_disponibles[@]}"; do
        if [[ "$version" == "$version_elegida" ]]; then
            return 0  # Encontrada
        fi
    done

    # No encontrada en la lista
    aputs_error "La version '$version_elegida' no esta disponible"
    aputs_info "Versiones disponibles:"
    for version in "${versiones_disponibles[@]}"; do
        echo "    - $version"
    done
    return 1
}

http_validar_opcion_menu() {
    local opcion="$1"
    local max_opciones="$2"

    # Debe ser un número entero positivo
    if [[ ! "$opcion" =~ ^[0-9]+$ ]]; then
        aputs_error "Opcion invalida: '$opcion'"
        aputs_info "Ingrese un numero entre 1 y $max_opciones"
        return 1
    fi

    # Debe estar en rango 1..max_opciones
    if (( opcion < 1 || opcion > max_opciones )); then
        aputs_error "Opcion fuera de rango: $opcion"
        aputs_info "Rango valido: 1 a $max_opciones"
        return 1
    fi

    return 0
}

http_validar_indice_version() {
    local indice="$1"
    local total_versiones="$2"

    if [[ ! "$indice" =~ ^[0-9]+$ ]]; then
        aputs_error "Debe ingresar el numero de la version deseada"
        return 1
    fi

    if (( indice < 1 || indice > total_versiones )); then
        aputs_error "Seleccion fuera de rango: $indice"
        aputs_info "Seleccione un numero entre 1 y $total_versiones"
        return 1
    fi

    return 0
}

http_validar_directorio_web() {
    local directorio="$1"
    local usuario_servicio="$2"

    # El directorio debe existir
    if [[ ! -d "$directorio" ]]; then
        aputs_error "El directorio web no existe: $directorio"
        aputs_info "Se creara automaticamente durante la instalacion"
        return 1
    fi

    # Verificar que el usuario del servicio existe en el sistema
    if ! id "$usuario_servicio" &>/dev/null; then
        aputs_warning "El usuario del servicio '$usuario_servicio' no existe aun"
        aputs_info "Se creara durante la instalacion"
        return 0  # No es error crítico en este punto
    fi

    # Verificar propietario del directorio
    local propietario_actual
    propietario_actual=$(stat -c '%U' "$directorio" 2>/dev/null)

    if [[ "$propietario_actual" != "$usuario_servicio" && \
          "$propietario_actual" != "root" ]]; then
        aputs_warning "El directorio $directorio es propiedad de: $propietario_actual"
        aputs_info "Deberia ser propiedad de: $usuario_servicio o root"
    fi

    return 0
}

http_validar_metodo_http() {
    local metodo="$1"

    if [[ -z "$metodo" ]]; then
        aputs_error "Debe especificar un metodo HTTP"
        aputs_info "Metodos disponibles para restringir: TRACE, TRACK, DELETE, PUT, OPTIONS"
        return 1
    fi

    # Convertimos a mayúsculas para comparación uniforme
    local metodo_upper="${metodo^^}"

    case "$metodo_upper" in
        GET|POST)
            # GET y POST son esenciales — no deben restringirse
            aputs_error "El metodo $metodo_upper es esencial y no debe restringirse"
            aputs_info "Restriccion tipica: TRACE, TRACK, DELETE, PUT no necesarios"
            return 1
            ;;
        TRACE|TRACK|DELETE|PUT|OPTIONS|PATCH|CONNECT|HEAD)
            # Estos son métodos válidos para gestionar
            ;;
        *)
            aputs_error "Metodo HTTP no reconocido: '$metodo'"
            aputs_info "Metodos HTTP estandar: GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, TRACE, CONNECT"
            return 1
            ;;
    esac

    return 0
}

http_validar_lineas_log() {
    local lineas="$1"

    if [[ ! "$lineas" =~ ^[0-9]+$ ]]; then
        aputs_error "El numero de lineas debe ser un entero positivo"
        return 1
    fi

    if (( lineas < 10 )); then
        aputs_error "Minimo 10 lineas de log"
        return 1
    fi

    if (( lineas > 500 )); then
        aputs_error "Maximo recomendado: 500 lineas (valor: $lineas)"
        aputs_info "Para analisis extenso use: sudo journalctl -u httpd --no-pager"
        return 1
    fi

    return 0
}

http_validar_confirmacion() {
    local respuesta="$1"
    local respuesta_lower="${respuesta,,}"

    case "$respuesta_lower" in
        s|si|yes|y)
            return 0  # Confirmado
            ;;
        n|no)
            return 1  # Negado — no es un error, es una decisión
            ;;
        "")
            aputs_error "Debe responder s (si) o n (no)"
            return 2  # Entrada vacía — inválida
            ;;
        *)
            aputs_error "Respuesta no reconocida: '$respuesta'"
            aputs_info "Responda: s (si) o n (no)"
            return 2  # Entrada inválida
            ;;
    esac
}

export -f http_validar_puerto
export -f http_validar_puerto_cambio
export -f http_validar_servicio
export -f http_validar_version
export -f http_validar_opcion_menu
export -f http_validar_indice_version
export -f http_validar_directorio_web
export -f http_validar_metodo_http
export -f http_validar_lineas_log
export -f http_validar_confirmacion