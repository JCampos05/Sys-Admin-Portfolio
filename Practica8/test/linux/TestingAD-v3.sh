#!/bin/bash
#
# Testing-AD.sh — v3
# Fedora 43 Workstation
#
# Uso: sudo bash Testing-AD.sh
#
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/utilsAD.sh"

# 
# HELPERS DINAMICOS
# 

_get_grupos_con_miembros() {
    getent group 2>/dev/null | grep "@${DC_DOMAIN}" | \
        awk -F: '$4!="" {print $1}' | sort
}

_probar_kinit() {
    local sam="$1" password="$2"
    local resultado
    resultado=$(echo "$password" | kinit "${sam}@${DC_REALM}" 2>&1)
    local rc=$?
    kdestroy &>/dev/null 2>&1 || true
    if [[ $rc -eq 0 ]]; then
        return 0
    elif echo "$resultado" | grep -qi \
        "KDC_ERR_CLIENT_REVOKED\|revoked\|restricted\|hours\|logon"; then
        echo "$resultado"; return 1
    else
        echo "$resultado"; return 2
    fi
}

# 
# MENU PRINCIPAL
# 
show_menu() {
    clear
    draw_line
    echo "  Tarea 08 — Pruebas Cliente Linux v2"
    draw_line
    echo "  Dominio:  $DC_DOMAIN"
    echo "  DC:       $DC_IP"
    echo "  Hora:     $(date '+%H:%M:%S')"
    local grupos
    grupos=$(_get_grupos_con_miembros)
    if [[ -n "$grupos" ]]; then
        echo "  Grupos:"
        for g in $grupos; do
            local count
            count=$(getent group "$g" 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -c .)
            echo "    ${g%%@*} ($count usuarios)"
        done
    fi
    draw_line
    echo ""
    echo "  -- Estado del Dominio --"
    echo "  1) Estado de conexion al dominio"
    echo "  2) Grupos y usuarios de AD"
    echo "  3) LogonHours (acceso actual por grupo)"
    echo ""
    echo "  -- Pruebas de LogonHours --"
    echo "  4) Probar login de un usuario (interactivo)"
    echo "  5) Probar login de TODOS los usuarios"
    echo ""
    echo "  -- Pruebas de Sesion --"
    echo "  6) Iniciar sesion interactiva"
    echo "  7) Verificar home directory"
    echo "  8) Verificar permisos sudo"
    echo ""
    echo "  -- Verificacion General --"
    echo "  V) Verificacion completa"
    echo ""
    echo "  -- Cuotas FSRM via CIFS --"
    echo "  C) Prueba de cuotas y file screening"
    echo "  0) Salir"
    echo ""
}

# 
# 1) ESTADO
# 
test_estado_dominio() {
    draw_header "Estado de Conexion al Dominio"
    echo ""
    aputs_info "realm list:"
    realm list | while IFS= read -r l; do echo "    $l"; done
    echo ""
    aputs_info "sssd:"
    local st
    st=$(sudo sssctl domain-status "$DC_DOMAIN" 2>/dev/null)
    echo "$st" | grep -q "Online" && aputs_success "Online" || aputs_error "Offline"
    echo "$st" | while IFS= read -r l; do echo "    $l"; done
    echo ""
    ping -c 1 -W 2 "$DC_IP" &>/dev/null && \
        aputs_success "Ping DC ($DC_IP): OK" || aputs_error "Ping DC ($DC_IP): FALLO"
    host "$DC_DOMAIN" "$DC_IP" &>/dev/null 2>&1 && \
        aputs_success "DNS $DC_DOMAIN: OK" || aputs_error "DNS $DC_DOMAIN: FALLO"
}

# 
# 2) GRUPOS Y USUARIOS — dinamico
# 
test_grupos_usuarios() {
    draw_header "Grupos y Usuarios de Active Directory"
    local grupos
    grupos=$(_get_grupos_con_miembros)
    if [[ -z "$grupos" ]]; then
        aputs_warning "No se encontraron grupos via getent. sssd Online?"
        return 1
    fi
    for grupo in $grupos; do
        echo ""
        aputs_info "Grupo: $grupo"
        local miembros
        miembros=$(getent group "$grupo" 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -v '^$')
        [[ -z "$miembros" ]] && aputs_warning "  Sin miembros" && continue
        printf "  %-30s %-15s\n" "Usuario" "Estado"
        echo "  ──────────────────────────────────────────"
        while IFS= read -r u; do
            local sam="${u%%@*}"
            [[ -z "$sam" ]] && continue
            id "$u" &>/dev/null 2>&1 && \
                printf "  %-30s %-15s\n" "$u" "OK" || \
                printf "  %-30s %-15s\n" "$u" "NO RESUELTO"
        done <<< "$miembros"
    done
}

# 
# 3) LOGONHOURS — dinamico via kinit
# 
test_logonhours_estado() {
    draw_header "Estado de LogonHours — Acceso Actual"
    echo ""
    aputs_info "Hora: $(date '+%H:%M %Z')"
    echo ""
    echo -ne "${CYAN}[INPUT]${NC} Password de dominio para verificacion: "
    read -rs pass_check
    echo ""
    echo ""
    local grupos
    grupos=$(_get_grupos_con_miembros)
    [[ -z "$grupos" ]] && aputs_warning "No se encontraron grupos." && return 1
    for grupo in $grupos; do
        local nombre_corto="${grupo%%@*}"
        local primer_usuario
        primer_usuario=$(getent group "$grupo" 2>/dev/null | \
            cut -d: -f4 | cut -d, -f1 | cut -d@ -f1)
        [[ -z "$primer_usuario" ]] && \
            aputs_warning "$nombre_corto: sin usuarios" && continue
        local msg
        msg=$(_probar_kinit "$primer_usuario" "$pass_check")
        local rc=$?
        if [[ $rc -eq 0 ]]; then
            aputs_success "$nombre_corto ($primer_usuario): DENTRO de horario ✓"
        elif [[ $rc -eq 1 ]]; then
            aputs_warning "$nombre_corto ($primer_usuario): FUERA de horario"
            aputs_info    "  $(echo "$msg" | head -1)"
        else
            aputs_error "$nombre_corto ($primer_usuario): ERROR"
        fi
    done
    echo ""
    aputs_info "Los LogonHours se aplican en UTC en el DC."
}

# 
# 4) LOGIN INTERACTIVO — un usuario
# 
test_login_usuario() {
    draw_header "Prueba de Login — Usuario Interactivo"
    echo ""
    aputs_info "Usuarios del dominio:"
    local grupos
    grupos=$(_get_grupos_con_miembros)
    for g in $grupos; do
        local lista
        lista=$(getent group "$g" 2>/dev/null | cut -d: -f4 | \
            tr ',' ' ' | sed "s/@${DC_DOMAIN}//g" | xargs)
        aputs_info "  ${g%%@*}: $lista"
    done
    echo ""
    echo -ne "${CYAN}[INPUT]${NC} Usuario a probar: "
    read -r sam
    [[ -z "$sam" ]] && { aputs_error "Usuario vacio."; return 1; }
    echo -ne "${CYAN}[INPUT]${NC} Password de $sam: "
    read -rs password
    echo ""
    echo ""
    aputs_info "Autenticando: $sam@$DC_DOMAIN"
    echo ""
    local msg
    msg=$(_probar_kinit "$sam" "$password")
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        aputs_success "LOGIN EXITOSO: $sam dentro de horario"
    elif [[ $rc -eq 1 ]]; then
        aputs_success "BLOQUEADO por LogonHours (correcto si esta fuera de horario)"
        aputs_info    "Mensaje DC: $msg"
    else
        aputs_error "FALLO: $msg"
    fi
}

# 
# 5) LOGIN TODOS — dinamico
# 
test_login_todos() {
    draw_header "Prueba de Login — Todos los Usuarios"
    echo ""
    echo -ne "${CYAN}[INPUT]${NC} Password de dominio: "
    read -rs password
    echo ""
    echo ""
    local grupos
    grupos=$(_get_grupos_con_miembros)
    [[ -z "$grupos" ]] && aputs_warning "No se encontraron grupos." && return 1
    printf "  %-30s %-20s %s\n" "Usuario" "Grupo" "Resultado"
    echo "  ──────────────────────────────────────────────────────────────"
    for grupo in $grupos; do
        local nombre_corto="${grupo%%@*}"
        local miembros
        miembros=$(getent group "$grupo" 2>/dev/null | \
            cut -d: -f4 | tr ',' '\n' | grep -v '^$')
        [[ -z "$miembros" ]] && continue
        while IFS= read -r u; do
            local sam="${u%%@*}"
            [[ -z "$sam" ]] && continue
            local msg
            msg=$(_probar_kinit "$sam" "$password")
            local rc=$?
            local st
            if   [[ $rc -eq 0 ]]; then st="${GREEN}LOGIN OK ✓${NC}"
            elif [[ $rc -eq 1 ]]; then st="${YELLOW}BLOQUEADO (LogonHours)${NC}"
            else                       st="${RED}ERROR: $(echo "$msg" | head -1 | cut -c1-40)${NC}"
            fi
            printf "  %-30s %-20s " "$sam@$DC_DOMAIN" "$nombre_corto"
            echo -e "$st"
        done <<< "$miembros"
    done
    echo ""
    aputs_info "Hora: $(date '+%H:%M:%S %Z')"
}

# 
# 6) SESION INTERACTIVA
# 
test_sesion_interactiva() {
    draw_header "Sesion Interactiva"
    echo ""
    aputs_info "Usuarios del dominio:"
    local grupos
    grupos=$(_get_grupos_con_miembros)
    for g in $grupos; do
        local lista
        lista=$(getent group "$g" 2>/dev/null | cut -d: -f4 | \
            tr ',' ' ' | sed "s/@${DC_DOMAIN}//g" | xargs)
        aputs_info "  ${g%%@*}: $lista"
    done
    echo ""
    agets "Usuario" sam
    echo ""
    aputs_info "Sesion como: $sam@$DC_DOMAIN"
    aputs_info "Escribe 'exit' para terminar"
    echo ""
    su - "$sam@$DC_DOMAIN"
    local rc=$?
    echo ""
    [[ $rc -eq 0 ]] && aputs_success "Sesion terminada OK" || \
        aputs_warning "Sesion rechazada (posiblemente fuera de LogonHours)"
}

# 
# 7) HOME DIRECTORY
# 
test_home_directory() {
    draw_header "Verificacion de Home Directory"
    echo ""
    agets "Usuario (ej: user01)" sam
    local home="/home/${sam}@${DC_DOMAIN}"
    if [[ -d "$home" ]]; then
        aputs_success "Home existe: $home"
        ls -la "$home" | head -8
    else
        aputs_warning "Home no existe: $home"
        aputs_info    "Se crea al primer login (mkhomedir)"
    fi
}

# 
# 8) SUDO
# 
test_sudo() {
    draw_header "Verificacion Sudo"
    echo ""
    if [[ -f /etc/sudoers.d/ad-admins ]]; then
        aputs_success "/etc/sudoers.d/ad-admins existe"
        cat /etc/sudoers.d/ad-admins
        echo ""
        sudo visudo -c -f /etc/sudoers.d/ad-admins &>/dev/null && \
            aputs_success "Sintaxis valida" || aputs_error "Error de sintaxis"
    else
        aputs_error "/etc/sudoers.d/ad-admins NO encontrado"
    fi
}

# 
# C) CUOTAS FSRM via CIFS — dinamico
# 

_prueba_escritura_cifs() {
    local ruta="$1" tamano_mb="$2" debe_fallar="$3" desc="$4"
    local esperado_str
    [[ "$debe_fallar" == "true" ]] && esperado_str="FALLA" || esperado_str="EXITO"
    local fallo=false

    if [[ "$tamano_mb" -eq 0 ]]; then
        dd if=/dev/zero of="$ruta" bs=1K count=1 2>/tmp/dd_err
        [[ $? -ne 0 ]] && fallo=true
    else
        dd if=/dev/zero of="$ruta" bs=1M count="$tamano_mb" 2>/tmp/dd_err
        local rc=$? dd_err
        dd_err=$(cat /tmp/dd_err 2>/dev/null)
        if [[ $rc -ne 0 ]] || echo "$dd_err" | grep -qi "No queda espacio\|No space"; then
            fallo=true
        else
            local real=0
            [[ -f "$ruta" ]] && real=$(stat -c%s "$ruta" 2>/dev/null || echo 0)
            [[ $real -lt $(( tamano_mb * 1024 * 1024 )) ]] && fallo=true
        fi
    fi

    local paso=false
    { [[ "$debe_fallar" == "true"  && "$fallo" == "true"  ]] || \
      [[ "$debe_fallar" == "false" && "$fallo" == "false" ]]; } && paso=true

    if [[ "$paso" == "true" ]]; then
        echo -e "  ${GREEN}  PASS  ${NC}  $(printf '%-45s' "$desc") Esperado: ${GREEN}$esperado_str${NC}"
    else
        echo -e "  ${RED}  FAIL  ${NC}  $(printf '%-45s' "$desc") Esperado: ${YELLOW}$esperado_str${NC}"
        [[ "$debe_fallar" == "true"  && "$fallo" == "false" ]] && \
            aputs_warning "  Se escribio cuando debia ser bloqueado. Verifique cuota HARD."
        [[ "$debe_fallar" == "false" && "$fallo" == "true"  ]] && \
            aputs_warning "  Bloqueado cuando debia pasar. $(cat /tmp/dd_err 2>/dev/null | tail -1)"
    fi

    [[ -f "$ruta" ]] && sudo rm -f "$ruta" 2>/dev/null
    rm -f /tmp/dd_err 2>/dev/null
    [[ "$paso" == "true" ]] && return 0 || return 1
}

test_cuotas_linux() {
    draw_header "Pruebas de Cuotas FSRM desde Linux v2"

    # cifs-utils requerido
    if ! rpm -qa | grep -q "^cifs-utils-"; then
        aputs_warning "Instalando cifs-utils..."
        sudo dnf install -y cifs-utils &>/dev/null || {
            aputs_error "sudo dnf install -y cifs-utils"
            return 1
        }
    fi

    echo ""
    # Mostrar usuarios disponibles
    aputs_info "Usuarios del dominio:"
    local grupos
    grupos=$(_get_grupos_con_miembros)
    for g in $grupos; do
        local lista
        lista=$(getent group "$g" 2>/dev/null | cut -d: -f4 | \
            tr ',' ' ' | sed "s/@${DC_DOMAIN}//g" | xargs)
        aputs_info "  ${g%%@*}: $lista"
    done

    echo ""
    echo -ne "${CYAN}[INPUT]${NC} Usuario a probar: "
    read -r test_user
    test_user="${test_user// /}"
    [[ -z "$test_user" ]] && { aputs_error "Usuario vacio."; return 1; }

    # Detectar grupo del usuario desde AD
    local test_group=""
    for g in $grupos; do
        local miembros
        miembros=$(getent group "$g" 2>/dev/null | cut -d: -f4 | tr ',' '\n')
        if echo "$miembros" | grep -qE "^${test_user}(@|$)"; then
            test_group="${g%%@*}"
            break
        fi
    done

    [[ -n "$test_group" ]] && aputs_info "Grupo detectado: $test_group" || \
        aputs_warning "Grupo no detectado automaticamente."

    # Cuota — preguntar siempre para que sea explicito
    echo -ne "${CYAN}[INPUT]${NC} Cuota en MB del usuario (ej: 5 o 10): "
    read -r quota_mb
    if ! [[ "$quota_mb" =~ ^[0-9]+$ ]] || [[ $quota_mb -eq 0 ]]; then
        aputs_error "Cuota invalida."; return 1
    fi

    echo -ne "${CYAN}[INPUT]${NC} Password de $test_user: "
    read -rs test_password
    echo ""

    # Montar subcarpeta directa del usuario
    local mount_point="/tmp/cuota_${test_user}_$$"
    mkdir -p "$mount_point"

    aputs_info "Montando //$DC_IP/Perfiles\$/$test_user..."
    if ! sudo mount -t cifs "//${DC_IP}/Perfiles$/${test_user}" "$mount_point" \
        -o "username=${test_user},password=${test_password},domain=${NETBIOS_NAME},vers=3.0,uid=$(id -u),gid=$(id -g)" \
        2>/tmp/mount_err; then
        aputs_error "No se pudo montar: $(cat /tmp/mount_err 2>/dev/null)"
        aputs_info  "sudo mount -t cifs //$DC_IP/Perfiles\$/$test_user /mnt \\"
        aputs_info  "  -o username=$test_user,domain=$NETBIOS_NAME,vers=3.0"
        rmdir "$mount_point" 2>/dev/null; rm -f /tmp/mount_err; return 1
    fi
    aputs_success "Montado en: $mount_point"
    rm -f /tmp/mount_err

    # Limpiar residuos
    sudo find "$mount_point" -maxdepth 1 -name "prueba_*" -delete 2>/dev/null

    # Calcular espacio disponible
    local uso_bytes=0
    uso_bytes=$(sudo find "$mount_point" -maxdepth 1 -type f \
        -exec stat -c%s {} \; 2>/dev/null | awk '{s+=$1} END {print s+0}')
    local quota_bytes=$(( quota_mb * 1024 * 1024 ))
    local disponible_mb=$(( (quota_bytes - uso_bytes) / 1024 / 1024 ))
    local uso_kb=$(( uso_bytes / 1024 ))

    echo ""
    draw_line
    echo "  Usuario:    $test_user | Grupo: $test_group"
    echo "  Cuota:      ${quota_mb} MB | Uso: ${uso_kb} KB | Disponible: ${disponible_mb} MB"
    draw_line

    if [[ $uso_bytes -gt 0 ]]; then
        echo ""
        aputs_warning "Archivos preexistentes (${uso_kb} KB usados):"
        sudo find "$mount_point" -maxdepth 1 -type f | while read -r f; do
            sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
            aputs_info "  $(basename "$f") ($(( sz / 1024 )) KB)"
        done
    fi

    if [[ $disponible_mb -le 1 ]]; then
        aputs_error "Espacio insuficiente ($disponible_mb MB). Elimine archivos."
        sudo umount "$mount_point" 2>/dev/null; rmdir "$mount_point" 2>/dev/null
        return 1
    fi

    local dentro_mb=$(( disponible_mb - 1 ))
    [[ $dentro_mb -lt 1 ]] && dentro_mb=1
    local fuera_mb=$(( quota_mb + 1 ))

    echo ""
    local total=0 pasaron=0

    _prueba_escritura_cifs \
        "$mount_point/prueba_sobre_cuota.bin" "$fuera_mb" "true" \
        "Archivo ${fuera_mb}MB (supera cuota ${quota_mb}MB)"
    local p1=$?; (( total++ )); [[ $p1 -eq 0 ]] && (( pasaron++ ))

    _prueba_escritura_cifs \
        "$mount_point/prueba_dentro_cuota.bin" "$dentro_mb" "false" \
        "Archivo ${dentro_mb}MB (dentro de cuota ${quota_mb}MB)"
    local p2=$?; (( total++ )); [[ $p2 -eq 0 ]] && (( pasaron++ ))

    _prueba_escritura_cifs \
        "$mount_point/prueba_bloqueado.exe" 0 "true" \
        "Archivo .exe (file screening)"
    local p3=$?; (( total++ )); [[ $p3 -eq 0 ]] && (( pasaron++ ))

    _prueba_escritura_cifs \
        "$mount_point/prueba_bloqueado.mp3" 0 "true" \
        "Archivo .mp3 (file screening)"
    local p4=$?; (( total++ )); [[ $p4 -eq 0 ]] && (( pasaron++ ))

    _prueba_escritura_cifs \
        "$mount_point/prueba_bloqueado.msi" 0 "true" \
        "Archivo .msi (file screening)"
    local p5=$?; (( total++ )); [[ $p5 -eq 0 ]] && (( pasaron++ ))

    echo ""
    draw_line
    local c
    [[ $pasaron -eq $total ]] && c="${GREEN}" || c="${YELLOW}"
    echo -e "  ${c}Resultado: $pasaron / $total pruebas correctas${NC}"
    draw_line
    echo ""
    aputs_success "Share montado en: $mount_point  (NO desmontado para evidencia)"
    aputs_info    "Ver archivos: ls -la $mount_point"
    aputs_info    "Desmontar:    sudo umount $mount_point"
    echo ""

    echo -ne "${CYAN}[INPUT]${NC} Probar otro usuario? (S/N): "
    read -r otra
    if [[ "${otra^^}" == "S" ]]; then
        sudo umount "$mount_point" 2>/dev/null
        rmdir "$mount_point" 2>/dev/null
        test_cuotas_linux
    fi
}

# 
# V) VERIFICACION COMPLETA
# 
test_verificacion_completa() {
    draw_header "Verificacion Completa — Tarea 08"
    test_estado_dominio; echo ""; pause
    test_grupos_usuarios; echo ""; pause
    echo -ne "${CYAN}[INPUT]${NC} Password para pruebas de LogonHours: "
    read -rs password; echo ""; echo ""
    draw_header "LogonHours via Kerberos"
    local grupos
    grupos=$(_get_grupos_con_miembros)
    [[ -z "$grupos" ]] && aputs_warning "Sin grupos." && return
    printf "  %-30s %-20s %s\n" "Usuario" "Grupo" "Resultado"
    echo "  ──────────────────────────────────────────────────────────────"
    for grupo in $grupos; do
        local nombre_corto="${grupo%%@*}"
        local miembros
        miembros=$(getent group "$grupo" 2>/dev/null | \
            cut -d: -f4 | tr ',' '\n' | grep -v '^$')
        [[ -z "$miembros" ]] && continue
        while IFS= read -r u; do
            local sam="${u%%@*}"
            [[ -z "$sam" ]] && continue
            local msg
            msg=$(_probar_kinit "$sam" "$password")
            local rc=$?
            local st
            if   [[ $rc -eq 0 ]]; then st="${GREEN}LOGIN OK ✓${NC}"
            elif [[ $rc -eq 1 ]]; then st="${YELLOW}BLOQUEADO${NC}"
            else                       st="${RED}ERROR${NC}"
            fi
            printf "  %-30s %-20s " "$sam@$DC_DOMAIN" "$nombre_corto"
            echo -e "$st"
        done <<< "$miembros"
    done
    echo ""
    aputs_success "Verificacion: $(date '+%H:%M:%S %Z')"
}

# 
# PUNTO DE ENTRADA
# 
if ! check_privileges; then
    aputs_error "Ejecute con sudo: sudo bash Testing-AD.sh"
    exit 1
fi

while true; do
    show_menu
    read -rp "  Opcion: " op
    echo ""
    case "${op^^}" in
        1) test_estado_dominio;        pause ;;
        2) test_grupos_usuarios;       pause ;;
        3) test_logonhours_estado;     pause ;;
        4) test_login_usuario;         pause ;;
        5) test_login_todos;           pause ;;
        6) test_sesion_interactiva          ;;
        7) test_home_directory;        pause ;;
        8) test_sudo;                  pause ;;
        V) test_verificacion_completa; pause ;;
        C) test_cuotas_linux;          pause ;;
        0) aputs_info "Saliendo..."; exit 0  ;;
        *) aputs_error "Opcion invalida"     ;;
    esac
done