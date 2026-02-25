#
# Ejecuta comandos o scripts en el servidor remoto via SSH
#
# Depende de: utilsCliSSH.sh, validatorsCliSSH.sh
#

ejecutar_remoto() {
    clear
    draw_header "Ejecutar Script o Comando Remoto"

    # ─── Elegir servidor ─────────────────────────────────────────
    if ! elegir_servidor; then
        return 1
    fi

    echo ""
    draw_line

    # ─── Verificar conectividad ──────────────────────────────────
    aputs_info "Verificando accesibilidad del servidor..."

    if ! check_puerto_ssh "$SVR_IP" "$SVR_PUERTO"; then
        aputs_error "No se puede alcanzar ${SVR_IP}:${SVR_PUERTO}"
        return 1
    fi
    aputs_success "Puerto ${SVR_PUERTO}/TCP accesible"
    echo ""
    draw_line

    # ─── Tipo de ejecucion ───────────────────────────────────────
    aputs_info "Que desea ejecutar?"
    echo ""
    echo "  1) Script predefinido de administracion"
    echo "  2) Script local (copiar y ejecutar)"
    echo "  3) Comando personalizado"
    echo ""

    local tipo
    agets "Opcion [1/2/3]" tipo

    echo ""
    draw_line
    echo ""

    case "$tipo" in
        1) _ejecutar_predefinido ;;
        2) _ejecutar_script_local ;;
        3) _ejecutar_comando_custom ;;
        *)
            aputs_error "Opcion no valida"
            return 1
            ;;
    esac
}

# ─── Scripts predefinidos de administracion ──────────────────────────────────
_ejecutar_predefinido() {
    aputs_info "Scripts disponibles en ${SVR_NOMBRE}:"
    echo ""

    local cmd_ejecutar=""

    if [[ "$SVR_IP" == "$SVR_LINUX_IP" ]]; then
        # ─ Opciones para Fedora Server ───────────────────────────
        echo "  1) Menu principal SSH          (bash ~/ssh_linux/main.sh)"
        echo "  2) Verificar servicio SSH      (modulo 1)"
        echo "  3) Monitor SSH                 (modulo 5)"
        echo "  4) Estado del sistema          (top, df, free)"
        echo ""

        local op
        agets "Seleccione [1-4]" op

        case "$op" in
            1) cmd_ejecutar="bash ~/ssh_linux/main.sh" ;;
            2) cmd_ejecutar="bash ~/ssh_linux/main.sh <<< '1'" ;;
            3) cmd_ejecutar="bash ~/ssh_linux/main.sh <<< '5'" ;;
            4) cmd_ejecutar="echo '=== CPU/MEM ==='; free -h; echo ''; echo '=== DISCO ==='; df -h; echo ''; echo '=== UPTIME ==='; uptime" ;;
            *) aputs_error "Opcion no valida"; return 1 ;;
        esac

    else
        # ─ Opciones para Windows Server ──────────────────────────
        # En Windows conectamos a cmd por defecto, por eso se
        # necesita llamar a powershell explicitamente
        local ps_path="C:/Users/Administrador/Documents/Scripts/P4"

        echo "  1) Menu principal SSH Windows  (mainSSH.ps1)"
        echo "  2) Verificar servicio SSH      (modulo 1)"
        echo "  3) Monitor SSH                 (modulo 5)"
        echo "  4) Estado del sistema          (memoria, disco, uptime)"
        echo ""

        local op
        agets "Seleccione [1-4]" op

        case "$op" in
            1) cmd_ejecutar="powershell -ExecutionPolicy Bypass -File ${ps_path}/mainSSH.ps1" ;;
            2) cmd_ejecutar="powershell -ExecutionPolicy Bypass -Command \"cd '${ps_path}'; . './utils.ps1'; . './validators_ssh.ps1'; . './1_verificar_ssh.ps1'; Invoke-VerificarSSH\"" ;;
            3) cmd_ejecutar="powershell -ExecutionPolicy Bypass -Command \"cd '${ps_path}'; . './utils.ps1'; . './validators_ssh.ps1'; . './5_monitor_ssh.ps1'; Invoke-MonitorSSH\"" ;;
            4) cmd_ejecutar="powershell -ExecutionPolicy Bypass -Command \"Write-Host '=== MEMORIA ==='; Get-CimInstance Win32_OperatingSystem | Select-Object FreePhysicalMemory,TotalVisibleMemorySize | Format-List; Write-Host '=== DISCO ==='; Get-PSDrive C | Select-Object Used,Free\"" ;;
            *) aputs_error "Opcion no valida"; return 1 ;;
        esac
    fi

    _lanzar_comando "$cmd_ejecutar"
}

# ─── Subir un script local y ejecutarlo ──────────────────────────────────────
_ejecutar_script_local() {
    aputs_info "Subir script local y ejecutarlo en ${SVR_NOMBRE}"
    echo ""

    # Pedir ruta del script local
    local ruta_script
    while true; do
        agets "Ruta del script local" ruta_script
        if validar_archivo_local "$ruta_script"; then
            break
        fi
        echo ""
    done

    # Nombre del archivo
    local nombre_script
    nombre_script=$(basename "$ruta_script")

    # Ruta remota temporal donde depositarlo
    local ruta_tmp_remota
    if [[ "$SVR_IP" == "$SVR_LINUX_IP" ]]; then
        ruta_tmp_remota="~/${nombre_script}"
    else
        ruta_tmp_remota="C:/Users/${SVR_WIN_USER}/${nombre_script}"
    fi

    echo ""
    aputs_info "El script se copiara a: ${SVR_USER}@${SVR_IP}:${ruta_tmp_remota}"
    echo ""

    # Copiar el script al servidor
    aputs_info "Copiando script..."
    scp -P "$SVR_PUERTO" \
        -o StrictHostKeyChecking=accept-new \
        "$ruta_script" \
        "${SVR_USER}@${SVR_IP}:${ruta_tmp_remota}" 2>&1

    if [[ $? -ne 0 ]]; then
        aputs_error "No se pudo copiar el script al servidor"
        return 1
    fi
    aputs_success "Script copiado correctamente"
    echo ""

    # Armar el comando de ejecucion segun el servidor
    local cmd_ejecutar
    if [[ "$SVR_IP" == "$SVR_LINUX_IP" ]]; then
        # En Linux: dar permisos y ejecutar con bash
        cmd_ejecutar="chmod +x ~/${nombre_script} && bash ~/${nombre_script}"
    else
        # En Windows: ejecutar con PowerShell
        cmd_ejecutar="powershell -ExecutionPolicy Bypass -File C:/Users/${SVR_WIN_USER}/${nombre_script}"
    fi

    _lanzar_comando "$cmd_ejecutar"
}

# ─── Comando personalizado ────────────────────────────────────────────────────
_ejecutar_comando_custom() {
    aputs_info "Escriba el comando a ejecutar en ${SVR_NOMBRE}"
    echo ""

    # Mostrar ejemplos segun servidor
    if [[ "$SVR_IP" == "$SVR_LINUX_IP" ]]; then
        aputs_info "Ejemplos Linux:"
        echo "  systemctl status sshd"
        echo "  cat /etc/ssh/sshd_config | grep Port"
        echo "  who"
    else
        aputs_info "Ejemplos Windows (via powershell):"
        echo "  powershell Get-Service sshd"
        echo "  powershell Get-NetTCPConnection -LocalPort 22"
    fi
    echo ""

    local comando
    while true; do
        agets "Comando a ejecutar" comando
        if validar_comando "$comando"; then
            break
        fi
        echo ""
    done

    _lanzar_comando "$comando"
}

# ─── Lanzar el comando con SSH ────────────────────────────────────────────────
# Funcion interna compartida por las tres opciones anteriores
_lanzar_comando() {
    local cmd="$1"

    echo ""
    draw_line
    aputs_info "Servidor : ${SVR_NOMBRE} (${SVR_USER}@${SVR_IP})"
    aputs_info "Comando  : $cmd"
    draw_line
    echo ""

    # -t: asigna TTY remota, necesario para scripts interactivos
    #     sin -t los menus con read no funcionan correctamente
    # -o StrictHostKeyChecking=accept-new: acepta claves nuevas
    ssh \
        -p "$SVR_PUERTO" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=8 \
        -t "${SVR_USER}@${SVR_IP}" \
        "$cmd"
    local codigo=$?

    echo ""
    draw_line
    if [[ $codigo -eq 0 ]]; then
        aputs_success "Ejecucion completada correctamente"
    else
        aputs_warning "Ejecucion finalizo con codigo: $codigo"
    fi
}