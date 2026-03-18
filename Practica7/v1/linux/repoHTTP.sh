#!/bin/bash
#
# ssl/ssl_repo.sh — Construcción del repositorio FTP de paquetes
#

[[ -n "${_SSL_REPO_LOADED:-}" ]] && return 0
readonly _SSL_REPO_LOADED=1

# -----------------------------------------------------------------------------
# ssl_repo_crear_estructura
#
# Crea las carpetas del repositorio si no existen y aplica los permisos
# correctos para que el usuario anónimo FTP pueda leer (pero no escribir).
#
# ¿Por qué estos permisos?
#   - root:ftp  755  en la raíz del repo → cualquier usuario FTP puede listar
#   - Los RPM son archivos de solo lectura → 644
#   - vsftpd requiere que los directorios del chroot anónimo no sean escribibles
# -----------------------------------------------------------------------------
ssl_repo_crear_estructura() {
    ssl_mostrar_banner "Repositorio FTP — Crear Estructura"

    aputs_info "Creando estructura en: ${SSL_REPO_ROOT}"
    echo ""

    local dirs=(
        "$SSL_REPO_APACHE"
        "$SSL_REPO_NGINX"
        "$SSL_REPO_TOMCAT"
    )

    local dir
    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            aputs_info "Ya existe: ${dir}"
        else
            if mkdir -p "$dir"; then
                aputs_success "Creado: ${dir}"
            else
                aputs_error "No se pudo crear: ${dir}"
                return 1
            fi
        fi
    done

    echo ""
    aputs_info "Aplicando permisos..."

    # La raíz del repositorio: root:ftp para que el grupo ftp pueda leer
    chown -R root:ftp  "$SSL_REPO_ROOT"
    # 755 en directorios: owner=rwx, group=r-x, others=r-x
    # El usuario FTP anónimo necesita poder entrar (x) y listar (r)
    find "$SSL_REPO_ROOT" -type d -exec chmod 755 {} \;
    # 644 en archivos: legibles por todos, escribibles solo por root
    find "$SSL_REPO_ROOT" -type f -exec chmod 644 {} \;

    # Contexto SELinux: public_content_t permite a vsftpd leer los archivos
    if command -v restorecon &>/dev/null; then
        restorecon -R "$SSL_REPO_ROOT" &>/dev/null
        aputs_success "Contexto SELinux aplicado (public_content_t)"
    fi

    echo ""
    aputs_success "Estructura del repositorio lista"
    echo ""

    # Mostrar el árbol resultante para confirmar visualmente
    aputs_info "Árbol creado:"
    find "$SSL_REPO_ROOT" -type d | sed 's|[^/]*/|  |g;s|  \([^  ]\)|└─ \1|'
    echo ""
}

# -----------------------------------------------------------------------------
# _ssl_repo_nombre_dir  <servicio>
# Devuelve la ruta del directorio del repositorio para el servicio dado.
# Uso interno — mapea httpd→Apache, nginx→Nginx, tomcat→Tomcat
# -----------------------------------------------------------------------------
_ssl_repo_nombre_dir() {
    case "$1" in
        httpd)  echo "$SSL_REPO_APACHE" ;;
        nginx)  echo "$SSL_REPO_NGINX"  ;;
        tomcat) echo "$SSL_REPO_TOMCAT" ;;
        *)      aputs_error "Servicio desconocido: $1"; return 1 ;;
    esac
}

ssl_repo_descargar_paquete() {
    local servicio="$1"
    local num_versiones="${2:-3}"
    local destdir
    destdir=$(_ssl_repo_nombre_dir "$servicio") || return 1

    echo ""
    draw_line
    aputs_info "Descargando: ${servicio} (hasta ${num_versiones} versiones)"
    draw_line
    echo ""

    if [[ ! -d "$destdir" ]]; then
        mkdir -p "$destdir" || { aputs_error "No se pudo crear ${destdir}"; return 1; }
    fi

    # Determinar arquitectura según el servicio
    local arch_flag
    case "$servicio" in
        tomcat) arch_flag="--arch noarch" ;;
        *)      arch_flag="--arch x86_64" ;;
    esac

    # Para httpd: resolver dinámicamente el paquete que provee system-logos(httpd-logo-ng)
    # En Fedora 41+ se llama "fedora-logos-httpd"; en RHEL/CentOS "centos-logos-httpd", etc.
    # dnf provides lo resuelve sin importar el nombre exacto de la distro.
    local paquetes_extra=""
    if [[ "$servicio" == "httpd" ]]; then
        local logos_pkg
        logos_pkg=$(dnf repoquery --arch x86_64,noarch                         --queryformat "%{name}\n"                         --whatprovides "system-logos(httpd-logo-ng)"                         2>/dev/null                     | grep -v "^$" | sort -u | head -1) || true
        if [[ -n "$logos_pkg" ]]; then
            paquetes_extra="$logos_pkg"
            aputs_info "Paquete de logos detectado: ${logos_pkg}"
        else
            aputs_info "No se encontró proveedor de system-logos(httpd-logo-ng) — omitiendo"
        fi
    fi

    local paquete
    paquete=$(http_nombre_paquete "$servicio" 2>/dev/null || echo "$servicio")

    aputs_info "Consultando versiones disponibles en repositorios dnf..."
    local versiones_raw
    versiones_raw=$(dnf repoquery                         $arch_flag                         --showduplicates                         --queryformat "%{version}-%{release}"                         "$paquete" 2>/dev/null                     | grep -v "^$" | sort -Vr | uniq) || true

    if [[ -z "$versiones_raw" ]]; then
        aputs_warning "dnf repoquery no devolvió versiones para '${paquete}'"
        aputs_info    "Intentando con dnf list como alternativa..."
        versiones_raw=$(dnf list --showduplicates "$paquete" 2>/dev/null                         | grep "^${paquete}"                         | awk '{print $2}'                         | sed 's/^[0-9]*://'                         | sort -Vr | uniq) || true
    fi

    if [[ -z "$versiones_raw" ]]; then
        aputs_error "No se encontraron versiones para '${paquete}' en ningún repositorio"
        aputs_info  "Verifique: dnf repolist  |  dnf search ${paquete}"
        return 1
    fi

    local num_disponibles
    num_disponibles=$(echo "$versiones_raw" | wc -l)

    if (( num_disponibles < num_versiones )); then
        aputs_warning "Solo hay ${num_disponibles} versión(es) disponible(s) en los repos"
        aputs_info    "Los repos de Fedora base normalmente no guardan versiones anteriores"
        aputs_info    "Se descargarán las ${num_disponibles} versión(es) disponibles"
        num_versiones=$num_disponibles
    fi

    # Tomar las N versiones más recientes
    local versiones_a_descargar=()
    mapfile -t versiones_a_descargar < <(echo "$versiones_raw" | head -"$num_versiones")

    aputs_success "Versiones a descargar (${#versiones_a_descargar[@]}):"
    local v
    for v in "${versiones_a_descargar[@]}"; do
        printf "    %s\n" "$v"
    done
    echo ""

    local ok=0 fail=0

    for v in "${versiones_a_descargar[@]}"; do
        local ver_dir="${destdir}/${v}"

        draw_line
        aputs_info "Descargando versión: ${v}"
        aputs_info "Destino: ${ver_dir}"
        draw_line
        echo ""

        # Crear subcarpeta para esta versión
        mkdir -p "$ver_dir" || { aputs_error "No se pudo crear ${ver_dir}"; fail=$(( fail + 1 )); continue; }

        # Construir la especificación de versión para dnf download
        # Formato: paquete-version (ej: httpd-2.4.66-1.fc43)
        local paquete_ver="${paquete}-${v}"

        # Descargar el paquete principal + dependencias.
        # Si paquetes_extra está definido intentamos agregarlo; si falla ese paquete
        # específico, reintentamos sin él (--skip-unavailable como red de seguridad).
        aputs_info "Ejecutando: dnf download ${arch_flag} --resolve ${paquete_ver}${paquetes_extra:+ $paquetes_extra}"
        echo ""

        # Intentar descarga. dnf download retorna != 0 si un paquete extra no existe.
        # Usamos una función interna para aislar del set -e del padre.
        _intentar_descarga() {
            dnf download $arch_flag --resolve                 --destdir "$ver_dir"                 "$@" 2>&1 | sed 's/^/    /'
            return ${PIPESTATUS[0]}
        }

        local descarga_ok=0
        if [[ -n "$paquetes_extra" ]]; then
            _intentar_descarga "$paquete_ver" $paquetes_extra && descarga_ok=1 || {
                aputs_info "Reintentando sin paquetes extra..."
                _intentar_descarga "$paquete_ver" && descarga_ok=1 || descarga_ok=0
            }
        else
            _intentar_descarga "$paquete_ver" && descarga_ok=1 || descarga_ok=0
        fi
        unset -f _intentar_descarga

        if (( descarga_ok == 0 )); then
            aputs_error "Fallo al descargar ${paquete_ver}"
            fail=$(( fail + 1 )) || true
            continue
        fi
        echo ""

        # Verificar que se descargó el RPM principal
        local rpm_principal
        rpm_principal=$(find "$ver_dir" -name "${paquete}-${v}*.rpm" 2>/dev/null | head -1)

        if [[ -z "$rpm_principal" ]]; then
            # dnf a veces ajusta el nombre del release — buscar por version base
            local ver_base
            ver_base=$(echo "$v" | cut -d- -f1)
            rpm_principal=$(find "$ver_dir" -name "${paquete}-${ver_base}*.rpm" 2>/dev/null | head -1)
        fi

        if [[ -z "$rpm_principal" ]]; then
            aputs_error "No se encontró el RPM principal de ${paquete} en ${ver_dir}"
            fail=$(( fail + 1 ))
            continue
        fi

        aputs_success "RPM(s) descargados en ${ver_dir}:"
        find "$ver_dir" -name "*.rpm" | while IFS= read -r r; do
            printf "    %-52s %s\n" "$(basename "$r")" "$(du -h "$r" | cut -f1)"
        done
        echo ""

        # Generar .sha256 para el RPM principal únicamente
        local nombre_rpm
        nombre_rpm=$(basename "$rpm_principal")
        local sha_file="${rpm_principal}.sha256"
        local hash
        hash=$(sha256sum "$rpm_principal" | awk '{print $1}')
        echo "${hash}  ${nombre_rpm}" > "$sha_file"
        aputs_success "SHA256: ${nombre_rpm} → ${hash:0:16}..."

        # Permisos y SELinux
        chown -R root:ftp "$ver_dir" 2>/dev/null
        find "$ver_dir" -type d -exec chmod 755 {} \;
        find "$ver_dir" -type f -exec chmod 644 {} \;
        command -v restorecon &>/dev/null && restorecon -R "$ver_dir" &>/dev/null

        ok=$(( ok + 1 ))
        echo ""
    done

    draw_line
    printf "  Versiones descargadas: ${GREEN}%d OK${NC}  ${RED}%d FAIL${NC}\n" "$ok" "$fail"
    draw_line
    echo ""

    [[ $ok -gt 0 ]] && return 0 || return 1
}

# -----------------------------------------------------------------------------
# ssl_repo_descargar_todos
#
# Descarga los tres servicios con múltiples versiones cada uno.
# Informa cuántas versiones se descargaron por servicio.
# -----------------------------------------------------------------------------
ssl_repo_descargar_todos() {
    ssl_mostrar_banner "Repositorio FTP — Descargar Paquetes"

    aputs_info "Verificando conectividad..."
    if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        aputs_error "Sin conectividad a internet — las descargas fallarán"
        aputs_info  "Verifique la interfaz NAT (192.168.70.0/24) del servidor"
        return 1
    fi
    aputs_success "Conectividad OK"
    echo ""

    if [[ ! -d "$SSL_REPO_LINUX" ]]; then
        ssl_repo_crear_estructura || return 1
    fi

    # Preguntar cuántas versiones descargar por servicio
    local num_versiones
    echo -ne "  ¿Cuántas versiones descargar por servicio? [3]: "
    read -r num_versiones
    [[ -z "$num_versiones" || ! "$num_versiones" =~ ^[0-9]+$ ]] && num_versiones=3
    (( num_versiones < 1 )) && num_versiones=1
    echo ""
    aputs_info "Se descargarán hasta ${num_versiones} versión(es) por servicio"
    echo ""

    local servicios=("httpd" "nginx" "tomcat")
    local nombres=("Apache (httpd)" "Nginx" "Tomcat")
    local resultado=()

    local i
    for i in "${!servicios[@]}"; do
        local svc="${servicios[$i]}"
        local nombre="${nombres[$i]}"

        aputs_info "━━━ ${nombre} ━━━"
        echo ""

        if ssl_repo_descargar_paquete "$svc" "$num_versiones"; then
            resultado+=("${GREEN}OK${NC}")
        else
            resultado+=("${RED}FAIL${NC}")
            aputs_warning "Fallo en ${nombre} — continuando con el siguiente..."
        fi

        echo ""
        sleep 1
    done

    echo ""
    draw_line
    aputs_info "Resumen de descargas:"
    echo ""
    for i in "${!servicios[@]}"; do
        local dir
        dir=$(_ssl_repo_nombre_dir "${servicios[$i]}" 2>/dev/null)
        local num_vers
        num_vers=$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        printf "  %-20s " "${nombres[$i]}"
        echo -e "${resultado[$i]}  (${num_vers} versión/es)"
    done
    echo ""
    draw_line

    return 0
}

# -----------------------------------------------------------------------------
# ssl_repo_listar
#
# Muestra el contenido del repositorio organizado por servicio → versión.
# -----------------------------------------------------------------------------
ssl_repo_listar() {
    ssl_mostrar_banner "Repositorio FTP — Contenido Actual"

    if [[ ! -d "$SSL_REPO_ROOT" ]]; then
        aputs_alert "El repositorio no existe aún"
        aputs_info  "Ejecute primero: Opción 1 → Crear estructura"
        return 1
    fi

    local servicios=("Apache" "Nginx" "Tomcat")
    local dirs=("$SSL_REPO_APACHE" "$SSL_REPO_NGINX" "$SSL_REPO_TOMCAT")

    local i
    for i in "${!servicios[@]}"; do
        local nombre="${servicios[$i]}"
        local dir="${dirs[$i]}"

        echo ""
        printf "  ${CYAN}[%s]${NC}  %s\n" "$nombre" "$dir"
        echo "  ──"

        if [[ ! -d "$dir" ]]; then
            printf "  ${GRAY}(directorio no existe)${NC}\n"
            continue
        fi

        # Iterar versiones (subdirectorios)
        local hay_versiones=false
        while IFS= read -r ver_dir; do
            hay_versiones=true
            local ver_nombre
            ver_nombre=$(basename "$ver_dir")

            # Buscar RPM principal en la subcarpeta
            local paquete_nombre
            case "$nombre" in
                Apache) paquete_nombre="httpd" ;;
                Nginx)  paquete_nombre="nginx" ;;
                Tomcat) paquete_nombre="tomcat" ;;
            esac

            local rpm_principal
            rpm_principal=$(find "$ver_dir" -name "${paquete_nombre}-[0-9]*.rpm" \
                            2>/dev/null | head -1)
            local sha_ok=""
            if [[ -n "$rpm_principal" && -f "${rpm_principal}.sha256" ]]; then
                local h_esp h_act
                h_esp=$(awk '{print $1}' "${rpm_principal}.sha256" 2>/dev/null)
                h_act=$(sha256sum "$rpm_principal" 2>/dev/null | awk '{print $1}')
                [[ "$h_act" == "$h_esp" ]] && sha_ok="${GREEN}[OK]${NC}" || sha_ok="${RED}[ERROR]${NC}"
            else
                sha_ok="${YELLOW}[?]${NC}"
            fi

            local num_rpms
            num_rpms=$(find "$ver_dir" -name "*.rpm" 2>/dev/null | wc -l)
            local size_total
            size_total=$(du -sh "$ver_dir" 2>/dev/null | cut -f1)

            printf "  %b  v%-30s  %2d RPM(s)  %s\n" \
                "$sha_ok" "$ver_nombre" "$num_rpms" "$size_total"
        done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -Vr)

        if ! $hay_versiones; then
            printf "  ${GRAY}(vacío — ejecute la descarga)${NC}\n"
        fi
    done

    echo ""
    draw_line
    aputs_info "Ruta FTP: ftp://192.168.100.10/repositorio/http/Linux/"
    echo ""
}

# -----------------------------------------------------------------------------
# ssl_repo_verificar_integridad
# Verifica el SHA256 del RPM principal de cada versión de cada servicio.
# -----------------------------------------------------------------------------
ssl_repo_verificar_integridad() {
    ssl_mostrar_banner "Repositorio FTP — Verificación de Integridad"

    if [[ ! -d "$SSL_REPO_ROOT" ]]; then
        aputs_error "El repositorio no existe"
        return 1
    fi

    local total=0 ok=0 fail=0 sin_sha=0

    aputs_info "Verificando checksums SHA256 (RPM principal por versión)..."
    echo ""

    local dirs=("$SSL_REPO_APACHE" "$SSL_REPO_NGINX" "$SSL_REPO_TOMCAT")
    local nombres=("Apache" "Nginx" "Tomcat")
    local paquetes=("httpd" "nginx" "tomcat")

    local i
    for i in "${!dirs[@]}"; do
        local dir="${dirs[$i]}"
        local nombre="${nombres[$i]}"
        local paquete="${paquetes[$i]}"

        [[ ! -d "$dir" ]] && continue

        printf "\n  ${CYAN}[%s]${NC}\n" "$nombre"

        while IFS= read -r ver_dir; do
            local ver
            ver=$(basename "$ver_dir")
            local rpm_principal
            rpm_principal=$(find "$ver_dir" -name "${paquete}-[0-9]*.rpm" \
                            2>/dev/null | head -1)

            (( total++ ))

            if [[ -z "$rpm_principal" ]]; then
                printf "  ${YELLOW}[SIN RPM]${NC}  v%s\n" "$ver"
                (( sin_sha++ ))
                continue
            fi

            local sha_file="${rpm_principal}.sha256"
            if [[ ! -f "$sha_file" ]]; then
                printf "  ${YELLOW}[SIN SHA]${NC}  v%s\n" "$ver"
                (( sin_sha++ ))
                continue
            fi

            local h_esp h_act
            h_esp=$(awk '{print $1}' "$sha_file" 2>/dev/null)
            h_act=$(sha256sum "$rpm_principal" 2>/dev/null | awk '{print $1}')

            if [[ "$h_act" == "$h_esp" ]]; then
                printf "  ${GREEN}[OK]${NC}   v%s\n" "$ver"
                ok=$(( ok + 1 ))
            else
                printf "  ${RED}[FAIL]${NC} v%s — hash no coincide\n" "$ver"
                fail=$(( fail + 1 ))
            fi
        done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -Vr)
    done

    echo ""
    draw_line
    printf "  Total verificados : %d\n"             "$total"
    printf "  ${GREEN}Correctos${NC}         : %d\n" "$ok"
    printf "  ${YELLOW}Sin .sha256${NC}       : %d\n" "$sin_sha"
    printf "  ${RED}Fallidos${NC}          : %d\n"   "$fail"
    draw_line
    echo ""

    (( fail > 0 )) && { aputs_error "${fail} archivo(s) corruptos detectados"; return 1; }
    (( total == 0 )) && { aputs_alert "No se encontraron versiones en el repositorio"; return 1; }

    aputs_success "Integridad verificada — todos los archivos correctos"
    return 0
}

# -----------------------------------------------------------------------------
# ssl_menu_repo
# -----------------------------------------------------------------------------
ssl_menu_repo() {
    while true; do
        clear
        ssl_mostrar_banner "Tarea 07 — Repositorio FTP"

        echo -e "  ${BLUE}1)${NC} Crear estructura de carpetas"
        echo -e "  ${BLUE}2)${NC} Descargar paquetes (3 versiones por servicio)"
        echo -e "  ${BLUE}3)${NC} Descargar servicio individual"
        echo -e "  ${BLUE}4)${NC} Ver contenido del repositorio"
        echo -e "  ${BLUE}5)${NC} Verificar integridad (SHA256)"
        echo -e "  ${BLUE}0)${NC} Volver al menú principal"
        echo ""

        local op
        read -rp "  Opción: " op

        case "$op" in
            1)
                ssl_repo_crear_estructura
                pause
                ;;
            2)
                ssl_repo_descargar_todos
                pause
                ;;
            3)
                clear
                ssl_mostrar_banner "Descargar Servicio Individual"
                echo ""
                echo -e "  ${BLUE}1)${NC} Apache (httpd)"
                echo -e "  ${BLUE}2)${NC} Nginx"
                echo -e "  ${BLUE}3)${NC} Tomcat"
                echo ""
                local srv_op
                read -rp "  Servicio [1-3]: " srv_op
                echo ""
                local num_ver
                read -rp "  ¿Cuántas versiones descargar? [3]: " num_ver
                [[ -z "$num_ver" || ! "$num_ver" =~ ^[0-9]+$ ]] && num_ver=3
                (( num_ver < 1 )) && num_ver=1
                echo ""
                case "$srv_op" in
                    1) ssl_repo_descargar_paquete "httpd"  "$num_ver" ;;
                    2) ssl_repo_descargar_paquete "nginx"  "$num_ver" ;;
                    3) ssl_repo_descargar_paquete "tomcat" "$num_ver" ;;
                    *) aputs_error "Opción inválida" ;;
                esac
                pause
                ;;
            4)
                ssl_repo_listar
                pause
                ;;
            5)
                ssl_repo_verificar_integridad
                pause
                ;;
            0) return 0 ;;
            *)
                aputs_error "Opción inválida"
                sleep 1
                ;;
        esac
    done
}

export -f ssl_repo_descargar_paquete
export -f ssl_repo_descargar_todos
export -f ssl_repo_listar
export -f ssl_repo_verificar_integridad
export -f ssl_menu_repo
export -f _ssl_repo_nombre_dir


_http_instalar_paquete() {
    local paquete="$1"
    local version="$2"   # versión elegida por el usuario — ej: "2.4.66-1.fc43"

    # Mapear nombre de paquete a directorio del repositorio
    local repo_dir
    repo_dir=$(_ssl_repo_nombre_dir "$paquete" 2>/dev/null)
    if [[ $? -ne 0 || -z "$repo_dir" ]]; then
        aputs_error "No se pudo determinar directorio del repositorio para: ${paquete}"
        return 1
    fi

    aputs_info "Instalando desde repositorio FTP local"
    aputs_info "Repositorio : ${repo_dir}"
    aputs_info "Versión     : ${version}"
    echo ""

    # ── Paso 1: Localizar la subcarpeta de la versión elegida ────────────────
    # La nueva estructura almacena cada versión en su propia subcarpeta:
    #   /srv/ftp/repositorio/http/Linux/Apache/2.4.66-1.fc43/
    local ver_dir="${repo_dir}/${version}"

    if [[ ! -d "$ver_dir" ]]; then
        # Intentar coincidencia parcial (ej: el usuario tiene "2.4.66-1.fc43"
        # pero el directorio es "2.4.66-1.fc43.x86_64")
        ver_dir=$(find "$repo_dir" -mindepth 1 -maxdepth 1 -type d                   -name "${version}*" 2>/dev/null | head -1)
    fi

    if [[ -z "$ver_dir" || ! -d "$ver_dir" ]]; then
        aputs_warning "No se encontró la versión '${version}' en el repositorio"
        aputs_info    "Versiones disponibles:"
        find "$repo_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null             | sort -Vr | while IFS= read -r d; do printf "    %s
" "$(basename "$d")"; done
        echo ""
        echo -ne "  ${YELLOW}[?]${NC} ¿Descargar la versión ${version} ahora? [S/n]: "
        local resp; read -r resp
        if [[ ! "$resp" =~ ^[nN]$ ]]; then
            ssl_repo_descargar_paquete "$paquete" 1 || return 1
            ver_dir="${repo_dir}/${version}"
            [[ ! -d "$ver_dir" ]] && ver_dir=$(find "$repo_dir" -mindepth 1 -maxdepth 1                                                -type d -name "${version}*" 2>/dev/null | head -1)
        fi
        [[ -z "$ver_dir" || ! -d "$ver_dir" ]] && return 1
    fi

    # ── Paso 2: Localizar el RPM principal en la subcarpeta ──────────────────
    local rpm_principal
    rpm_principal=$(find "$ver_dir" -name "${paquete}-[0-9]*.rpm" 2>/dev/null | head -1)

    if [[ -z "$rpm_principal" ]]; then
        aputs_error "No se encontró el RPM principal de '${paquete}' en ${ver_dir}"
        return 1
    fi

    local nombre_rpm size
    nombre_rpm=$(basename "$rpm_principal")
    size=$(du -h "$rpm_principal" | cut -f1)
    aputs_info "RPM principal:"
    printf "    %-50s %s
" "$nombre_rpm" "$size"
    echo ""

    # ── Paso 3: Verificar integridad SHA256 ───────────────────────────────────
    local sha_file="${rpm_principal}.sha256"
    if [[ -f "$sha_file" ]]; then
        aputs_info "Verificando integridad SHA256..."
        local hash_esperado hash_actual
        hash_esperado=$(awk '{print $1}' "$sha_file" 2>/dev/null)
        hash_actual=$(sha256sum "$rpm_principal" 2>/dev/null | awk '{print $1}')
        if [[ -n "$hash_esperado" && "$hash_actual" == "$hash_esperado" ]]; then
            aputs_success "SHA256 verificado — archivo íntegro"
        else
            aputs_error "SHA256 NO coincide — el RPM puede estar corrupto"
            aputs_info  "  Esperado: ${hash_esperado}"
            aputs_info  "  Actual:   ${hash_actual}"
            echo -ne "  ${YELLOW}[?]${NC} ¿Continuar de todas formas? [s/N]: "
            local resp_sha; read -r resp_sha
            [[ ! "$resp_sha" =~ ^[sS]$ ]] && return 1
        fi
    else
        aputs_warning "Sin archivo .sha256 — omitiendo verificación de integridad"
    fi
    echo ""

    # ── Paso 4: Detectar y resolver conflictos de versión con paquetes instalados ──
    aputs_info "Verificando conflictos de versión con paquetes instalados..."
    local conflictos=()

    # Obtener el nombre del SRPM base del paquete principal
    local srpm_base
    srpm_base=$(rpm -qp "$rpm_principal" --queryformat "%{SOURCERPM}" 2>/dev/null                 | sed 's/-[^-]*-[^-]*\.[^.]*\.rpm$//' | sed 's/-[0-9].*//' ) || true

    if [[ -n "$srpm_base" ]]; then
        # Buscar todos los paquetes instalados que vienen del mismo SRPM
        while IFS= read -r pkg_instalado; do
            [[ -z "$pkg_instalado" ]] && continue
            local ver_instalada
            ver_instalada=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" "$pkg_instalado" 2>/dev/null) || true
            # Si la versión instalada es diferente a la que vamos a instalar
            if [[ -n "$ver_instalada" && "$ver_instalada" != "$version" ]]; then
                conflictos+=("$pkg_instalado")
            fi
        done < <(rpm -qa --queryformat "%{NAME}
" 2>/dev/null                  | grep -E "^(${srpm_base}|mod_ssl|mod_http2|mod_lua)" 2>/dev/null                  | sort -u) || true
    fi

    if [[ ${#conflictos[@]} -gt 0 ]]; then
        aputs_warning "Paquetes con versión diferente detectados — se eliminarán antes de instalar:"
        local c
        local habia_mod_ssl=false
        local habia_ssl_conf=false

        for c in "${conflictos[@]}"; do
            local ver_c
            ver_c=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" "$c" 2>/dev/null) || true
            printf "    %-35s v%s
" "$c" "$ver_c"
            [[ "$c" == "mod_ssl" ]] && habia_mod_ssl=true
        done
        echo ""

        # Si ssl_reprobados.conf existe, deshabilitarlo temporalmente antes de
        # eliminar mod_ssl para que Apache no falle al arrancar sin el módulo
        if $habia_mod_ssl && [[ -f "${SSL_CONF_APACHE_SSL:-/etc/httpd/conf.d/ssl_reprobados.conf}" ]]; then
            habia_ssl_conf=true
            mv "${SSL_CONF_APACHE_SSL:-/etc/httpd/conf.d/ssl_reprobados.conf}"                "${SSL_CONF_APACHE_SSL:-/etc/httpd/conf.d/ssl_reprobados.conf}.disabled" 2>/dev/null || true
            aputs_info "ssl_reprobados.conf deshabilitado temporalmente (mod_ssl ausente)"
        fi

        rpm -e --nodeps "${conflictos[@]}" 2>&1 | sed 's/^/    /' || true
        aputs_success "Paquetes conflictivos eliminados"

        # Marcar para reinstalar mod_ssl después de instalar la nueva versión de httpd
        # Se guarda en variable local — se procesa después del rpm -Uvh principal
        if $habia_mod_ssl; then
            aputs_info "mod_ssl será reinstalado tras instalar httpd ${version}"
        fi
        # Exportar flags para usarlos después del bloque de instalación
        # (variables locales — dentro de la misma función)
        local _reinstalar_mod_ssl=$habia_mod_ssl
        local _restaurar_ssl_conf=$habia_ssl_conf
    else
        aputs_info "Sin conflictos de versión detectados"
        local _reinstalar_mod_ssl=false
        local _restaurar_ssl_conf=false
    fi
    echo ""

    # ── Paso 5: Instalar todos los RPMs de la subcarpeta en una sola pasada ───
    local todos_los_rpms=()
    mapfile -t todos_los_rpms < <(find "$ver_dir" -name "*.rpm" 2>/dev/null | sort)

    local count_total="${#todos_los_rpms[@]}"
    aputs_info "Instalando ${count_total} paquete(s) de v${version} en una sola pasada..."
    echo ""

    local rpm_f
    for rpm_f in "${todos_los_rpms[@]}"; do
        printf "    %s
" "$(basename "$rpm_f")"
    done
    echo ""

    rpm -Uvh --replacepkgs --replacefiles "${todos_los_rpms[@]}" 2>&1         | sed 's/^/    /'

    local exit_rpm=$?
    echo ""

    # ── Paso 6: Verificar que quedó instalado ────────────────────────────────
    if ! rpm -q "$paquete" &>/dev/null; then
        aputs_error "rpm reportó código ${exit_rpm} — el paquete no quedó instalado"
        aputs_info  "Verifique: rpm -ivh --test ${rpm_principal}"
        # El conf queda deshabilitado — mod_ssl fue eliminado y no se reinstalará
        # Apache puede arrancar sin SSL. El usuario deberá reaplicar SSL manualmente.
        if ${_restaurar_ssl_conf:-false}; then
            aputs_warning "ssl_reprobados.conf queda deshabilitado (mod_ssl no instalado)"
            aputs_info    "Reaplicar SSL desde Paso 6 tras resolver el error"
        fi
        return 1
    fi

    local version_instalada
    version_instalada=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" "$paquete" 2>/dev/null)
    aputs_success "Instalado correctamente: ${paquete} v${version_instalada}"
    aputs_info    "Origen: ${ver_dir}"

    # ── Paso 7: Reinstalar mod_ssl compatible con la nueva versión ────────────
    if ${_reinstalar_mod_ssl:-false}; then
        echo ""
        aputs_info "Reinstalando mod_ssl compatible con ${paquete} ${version_instalada}..."

        # Buscar mod_ssl en el repositorio FTP (mismo directorio que httpd)
        local mod_ssl_rpm
        mod_ssl_rpm=$(find "$repo_dir" -path "*/${version}/mod_ssl*.rpm" 2>/dev/null | head -1) || true

        if [[ -n "$mod_ssl_rpm" ]]; then
            aputs_info "Instalando desde repositorio: $(basename "$mod_ssl_rpm")"
            rpm -Uvh --replacepkgs "$mod_ssl_rpm" 2>&1 | sed 's/^/    /' || true
        else
            # No está en el repo — instalar con dnf desde internet
            aputs_info "mod_ssl no está en el repositorio — instalando desde dnf..."
            local ver_base
            ver_base=$(echo "$version_instalada" | cut -d- -f1)
            dnf install -y "mod_ssl-${version_instalada}" 2>&1 | tail -3 | sed 's/^/    /'                 || dnf install -y mod_ssl 2>&1 | tail -3 | sed 's/^/    /' || true
        fi

        if rpm -q mod_ssl &>/dev/null; then
            local mod_ssl_ver
            mod_ssl_ver=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" mod_ssl 2>/dev/null)
            aputs_success "mod_ssl reinstalado: v${mod_ssl_ver}"
        else
            aputs_warning "mod_ssl no se pudo reinstalar — SSL/HTTPS no estará disponible"
            aputs_info    "Instale manualmente: dnf install mod_ssl"
        fi

        # Restaurar ssl_reprobados.conf ahora que mod_ssl está instalado
        if ${_restaurar_ssl_conf:-false}; then
            local conf_disabled="${SSL_CONF_APACHE_SSL:-/etc/httpd/conf.d/ssl_reprobados.conf}.disabled"
            if [[ -f "$conf_disabled" ]]; then
                mv "$conf_disabled"                    "${SSL_CONF_APACHE_SSL:-/etc/httpd/conf.d/ssl_reprobados.conf}" 2>/dev/null || true
                aputs_success "ssl_reprobados.conf restaurado"
            fi
        fi
    fi

    return 0
}
export -f _http_instalar_paquete

http_consultar_versiones() {
    local servicio="$1"
    local _array_destino="$2"

    local paquete
    paquete=$(http_nombre_paquete "$servicio" 2>/dev/null || echo "$servicio")

    local repo_dir
    repo_dir=$(_ssl_repo_nombre_dir "$paquete" 2>/dev/null)

    # ── Leer versiones desde subcarpetas del repositorio FTP ─────────────────
    # La nueva estructura almacena cada versión en un subdirectorio:
    #   /srv/ftp/repositorio/http/Linux/Apache/2.4.66-1.fc43/
    # Cada subdirectorio = una versión disponible para instalar.
    if [[ -n "$repo_dir" && -d "$repo_dir" ]]; then
        local ver_dirs=()
        mapfile -t ver_dirs < <(find "$repo_dir" -mindepth 1 -maxdepth 1                                  -type d 2>/dev/null | sort -Vr)

        if [[ ${#ver_dirs[@]} -gt 0 ]]; then
            aputs_info "Leyendo versiones disponibles desde el repositorio FTP..."
            echo ""

            local versiones_array=()
            local vd
            for vd in "${ver_dirs[@]}"; do
                # El nombre del directorio ES la versión (ej: 2.4.66-1.fc43)
                local ver_nombre
                ver_nombre=$(basename "$vd")

                # Verificar que el directorio tiene al menos el RPM principal
                local rpm_check
                rpm_check=$(find "$vd" -name "${paquete}-[0-9]*.rpm" 2>/dev/null | head -1)
                if [[ -n "$rpm_check" ]]; then
                    versiones_array+=("$ver_nombre")
                fi
            done

            if [[ ${#versiones_array[@]} -gt 0 ]]; then
                local -n _ref_array="$_array_destino"
                _ref_array=("${versiones_array[@]}")
                aputs_success "${#versiones_array[@]} versión(es) disponible(s) en el repositorio FTP"
                aputs_info    "Origen: ${repo_dir}"
                return 0
            fi
        fi

        # Directorio existe pero sin subcarpetas de versión — ofrecer descarga
        aputs_warning "El repositorio FTP no tiene versiones descargadas para '${paquete}'"
        echo ""
        echo -ne "  ${YELLOW}[?]${NC} ¿Descargar 3 versiones al repositorio ahora? [S/n]: "
        local resp; read -r resp
        if [[ ! "$resp" =~ ^[nN]$ ]]; then
            echo ""
            ssl_repo_descargar_paquete "$paquete" 3 || return 1
            echo ""
            http_consultar_versiones "$servicio" "$_array_destino"
            return $?
        fi
    fi

    # ── Fallback: dnf repoquery ───────────────────────────────────────────────
    aputs_warning "Usando repositorios dnf como fallback (no recomendado en P7)"
    echo ""

    local versiones_raw
    versiones_raw=$(dnf repoquery                         --arch "$(uname -m)"                         --showduplicates                         --queryformat "%{version}-%{release}"                         "$paquete" 2>/dev/null                     | grep -v "^$" | sort -Vr | uniq)

    if [[ -z "$versiones_raw" ]]; then
        aputs_error "No se encontraron versiones para '${paquete}'"
        aputs_info  "Ejecute el Paso 4 para descargar los paquetes al repositorio"
        return 1
    fi

    local versiones_array=()
    while IFS= read -r linea; do
        [[ -n "$linea" ]] && versiones_array+=("$linea")
    done <<< "$versiones_raw"

    local -n _ref_array="$_array_destino"
    _ref_array=("${versiones_array[@]}")
    aputs_success "${#versiones_array[@]} versión(es) encontrada(s) (fuente: dnf)"
    return 0
}
export -f http_consultar_versiones

_http_habilitar_servicio() {
    local servicio="$1"
    local nombre_systemd
    nombre_systemd=$(http_nombre_systemd "$servicio")

    # Para httpd: verificar que si hay ssl_reprobados.conf, mod_ssl esté presente
    if [[ "$servicio" == "httpd" ]]; then
        local ssl_conf="${SSL_CONF_APACHE_SSL:-/etc/httpd/conf.d/ssl_reprobados.conf}"
        if [[ -f "$ssl_conf" ]] && ! rpm -q mod_ssl &>/dev/null; then
            aputs_warning "ssl_reprobados.conf existe pero mod_ssl NO está instalado"
            aputs_info    "Deshabilitando ssl_reprobados.conf para permitir arranque de httpd..."
            mv "$ssl_conf" "${ssl_conf}.disabled" 2>/dev/null || true
            aputs_success "Conf SSL deshabilitado temporalmente — httpd arrancará sin SSL"
            aputs_info    "Reaplicar SSL desde Paso 6 una vez resuelto mod_ssl"
        fi
        # Si hay un conf .disabled y mod_ssl SÍ está, restaurarlo
        if [[ -f "${ssl_conf}.disabled" ]] && rpm -q mod_ssl &>/dev/null; then
            mv "${ssl_conf}.disabled" "$ssl_conf" 2>/dev/null || true
            aputs_success "ssl_reprobados.conf restaurado — mod_ssl disponible"
        fi
    fi

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
            pid=$(sudo systemctl show "$nombre_systemd"                   --property=MainPID --value 2>/dev/null)
            aputs_success "${nombre_systemd} activo — PID: ${pid}"
            return 0
        else
            aputs_error "${nombre_systemd} no levanto correctamente"
            aputs_info "Revise: sudo journalctl -u ${nombre_systemd} -n 20"
            return 1
        fi
    else
        aputs_error "Error al iniciar ${nombre_systemd}"
        sudo journalctl -u "$nombre_systemd" -n 10 --no-pager 2>/dev/null             | sed 's/^/    /'
        return 1
    fi
}
export -f _http_habilitar_servicio


http_menu_instalar() {

    # ── Paso 1: Selección de servicio ─────────────────────────────────────────
    local seleccion_servicio
    http_seleccionar_servicio seleccion_servicio

    case "$seleccion_servicio" in
        cancelar)
            aputs_info "Instalacion cancelada"
            sleep 2
            return 0
            ;;
        reinstalar:*)
            local servicio="${seleccion_servicio#reinstalar:}"
            aputs_warning "Desinstalando version actual de ${servicio}..."
            dnf remove -y "$(http_nombre_paquete "$servicio")" 2>/dev/null || true
            aputs_success "Desinstalado. Continuando con instalacion limpia..."
            sleep 2
            ;;
        reconfigurar:*)
            local servicio="${seleccion_servicio#reconfigurar:}"
            aputs_info "Modo reconfiguracion — omitiendo instalacion del paquete"
            local version_actual
            version_actual=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}" \
                             "$(http_nombre_paquete "$servicio")" 2>/dev/null) || true

            local puerto_reconfig
            http_seleccionar_puerto "$servicio" puerto_reconfig
            _http_configurar_puerto_inicial "$servicio" "$puerto_reconfig"
            echo ""

            if ! http_reiniciar_servicio "$servicio"; then
                aputs_error "El servicio no levanto con el nuevo puerto"
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

    # ── Paso 2: Consultar versiones ───────────────────────────────────────────
    local versiones_disponibles=()
    if ! http_consultar_versiones "$servicio" versiones_disponibles; then
        aputs_error "No se pudieron obtener versiones."
        echo ""
        pause
        return 1
    fi

    echo ""
    pause

    # ── Paso 3: Selección de versión ──────────────────────────────────────────
    local version_elegida
    http_seleccionar_version "$servicio" versiones_disponibles version_elegida
    echo ""
    pause

    # ── Paso 4: Selección de puerto ───────────────────────────────────────────
    local puerto_elegido
    http_seleccionar_puerto "$servicio" puerto_elegido
    echo ""

    # ── Paso 4b: Preguntar si se desea certificar con SSL ─────────────────────
    draw_line
    echo -e "  ${CYAN}[SSL]${NC} ¿Desea configurar SSL/HTTPS para este servicio?"
    echo ""
    echo -ne "  ${YELLOW}[?]${NC} Certificar ${servicio} con SSL después de instalar [s/N]: "
    local resp_ssl
    read -r resp_ssl
    local aplicar_ssl=false
    [[ "$resp_ssl" =~ ^[sS]$ ]] && aplicar_ssl=true
    echo ""

    # ── Confirmación final ────────────────────────────────────────────────────
    draw_line
    aputs_info "Resumen de la instalacion a realizar:"
    echo ""
    printf "    Servicio : %s\n"    "$servicio"
    printf "    Version  : %s\n"    "$version_elegida"
    printf "    Puerto   : %s/tcp\n" "$puerto_elegido"
    if $aplicar_ssl; then
        printf "    SSL/HTTPS: %s\n" "SI — se configurará tras la instalación"
    else
        printf "    SSL/HTTPS: %s\n" "NO"
    fi
    echo ""

    local confirmacion
    while true; do
        agets "Confirmar instalacion? [s/n]" confirmacion
        local resultado
        http_validar_confirmacion "$confirmacion"
        resultado=$?
        if (( resultado == 0 )); then
            break
        elif (( resultado == 1 )); then
            aputs_info "Instalacion cancelada"
            sleep 2
            return 0
        fi
        echo ""
    done

    draw_line
    echo ""

    # ── Paso 5: Instalar el servicio ──────────────────────────────────────────
    local instalacion_ok=true
    case "$servicio" in
        httpd)  http_instalar_apache "$version_elegida" "$puerto_elegido" || instalacion_ok=false ;;
        nginx)  http_instalar_nginx  "$version_elegida" "$puerto_elegido" || instalacion_ok=false ;;
        tomcat) http_instalar_tomcat "$version_elegida" "$puerto_elegido" || instalacion_ok=false ;;
    esac

    # ── Paso 6: Aplicar SSL si se solicitó y la instalación fue exitosa ───────
    if $aplicar_ssl && $instalacion_ok; then
        echo ""
        draw_line
        aputs_info "Procediendo con la configuración SSL/HTTPS..."
        draw_line
        echo ""

        # Verificar si existe el certificado — si no, generarlo primero
        if ! ssl_cert_existe; then
            aputs_warning "No existe un certificado SSL — generando uno ahora..."
            echo ""
            if ! ssl_cert_generar; then
                aputs_error "No se pudo generar el certificado — SSL omitido"
                aputs_info  "Puede aplicarlo después desde: Paso 6 → SSL/HTTPS"
                echo ""
                pause
                return 0
            fi
            echo ""
        else
            aputs_info "Certificado SSL existente detectado:"
            ssl_cert_mostrar_info
            echo ""
        fi

        # Aplicar SSL al servicio recién instalado
        local ssl_result=0
        case "$servicio" in
            httpd)  ssl_http_aplicar_apache  || ssl_result=1 ;;
            nginx)  ssl_http_aplicar_nginx   || ssl_result=1 ;;
            tomcat) ssl_http_aplicar_tomcat  || ssl_result=1 ;;
        esac

        if [[ $ssl_result -eq 0 ]]; then
            echo ""
            aputs_success "Servicio ${servicio} instalado y certificado correctamente"
        else
            echo ""
            aputs_warning "La instalación fue exitosa pero hubo un problema al aplicar SSL"
            aputs_info    "Puede reintentarlo desde: Paso 6 → SSL/HTTPS"
        fi

    elif $aplicar_ssl && ! $instalacion_ok; then
        echo ""
        aputs_warning "La instalación falló — SSL no se puede aplicar"
        aputs_info    "Resuelva el error de instalación primero"
    fi

    echo ""
    pause
}

export -f http_menu_instalar

_http_setup_nginx() {
    local puerto="$1"

    # Eliminar welcome.conf si existe — pisa nuestro index.html
    local welcome_conf="/etc/nginx/default.d/welcome.conf"
    if [[ -f "$welcome_conf" ]]; then
        mv "$welcome_conf" "${welcome_conf}.disabled" 2>/dev/null || true
        aputs_success "welcome.conf de Fedora deshabilitado (usará nuestro index.html)"
    fi

    # server_tokens off: oculta la versión de Nginx
    if grep -q "server_tokens" "${HTTP_CONF_NGINX:-/etc/nginx/nginx.conf}" 2>/dev/null; then
        sed -i "s/server_tokens.*/server_tokens off;/" \
            "${HTTP_CONF_NGINX:-/etc/nginx/nginx.conf}"
    else
        sed -i "/^http {/a\\    server_tokens off;" \
            "${HTTP_CONF_NGINX:-/etc/nginx/nginx.conf}"
    fi
    aputs_success "server_tokens off aplicado en nginx.conf"

    # Verificar sintaxis
    if nginx -t 2>/dev/null; then
        aputs_success "Sintaxis de nginx.conf: válida"
    else
        aputs_warning "Problema de sintaxis en nginx.conf — verificar manualmente"
        nginx -t 2>&1 | sed 's/^/    /'
    fi
}
export -f _http_setup_nginx