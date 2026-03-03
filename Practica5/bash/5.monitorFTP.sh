#
#
# Módulo: Monitor del servicio FTP (vsftpd)
#
# Requiere:
#   utils.sh    
#

# Submenú del monitor — se llama desde main_menu opción 5
monitor_ftp() {
    while true; do
        clear
        draw_header "Monitor FTP"
        echo ""
        aputs_info "  1) Estado del servicio vsftpd"
        aputs_info "  2) Conexiones FTP activas"
        aputs_info "  3) Log de transferencias (xferlog)"
        aputs_info "  4) Log de eventos vsftpd"
        aputs_info "  5) Estadisticas por usuario"
        aputs_info "  6) Seguimiento en tiempo real (tail -f)"
        aputs_info "  7) Volver al menu principal"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1) _estado_servicio_ftp; pause ;;
            2) _conexiones_activas_ftp; pause ;;
            3) _ver_log_transferencias; pause ;;
            4) _ver_log_eventos; pause ;;
            5) _estadisticas_usuarios; pause ;;
            6) _seguimiento_tiempo_real; pause ;;
            7) return 0 ;;
            *)
                aputs_error "Opcion invalida. Seleccione del 1 al 7"
                sleep 2
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#   ESTADO DEL SERVICIO
# ─────────────────────────────────────────────────────────────────────────────

# Estado completo del servicio vsftpd con toda la información de systemd
_estado_servicio_ftp() {
    draw_header "Estado del Servicio vsftpd"
    echo ""

    # ── Estado systemd ────────────────────────────────────────────────────────
    aputs_info "[ systemctl status vsftpd ]"
    draw_line

    # Mostrar estado con colores de systemd (--no-pager para no pausar)
    systemctl status "$FTP_SERVICE" --no-pager --lines=10 2>/dev/null
    local exit_status=$?

    echo ""
    draw_line

    # ── Actividad en arranque ─────────────────────────────────────────────────
    if check_service_enabled "$FTP_SERVICE"; then
        aputs_success "Habilitado en arranque (systemctl enable)"
    else
        aputs_warning "NO habilitado en arranque — se perdera tras reinicio"
    fi

    # ── Puerto en escucha ─────────────────────────────────────────────────────
    echo ""
    aputs_info "[ Puertos en escucha ]"
    draw_line

    # Mostrar sockets TCP de vsftpd
    local sockets
    sockets=$(ss -tlnp 2>/dev/null | grep "vsftpd\|:21\|:20" || true)
    if [[ -n "$sockets" ]]; then
        echo "$sockets" | while IFS= read -r linea; do
            echo "  $linea"
        done
    else
        aputs_warning "No se detectan sockets vsftpd en escucha"
    fi

    # ── Proceso vsftpd ────────────────────────────────────────────────────────
    echo ""
    aputs_info "[ Proceso vsftpd ]"
    draw_line

    local procs
    procs=$(ps aux 2>/dev/null | grep "[v]sftpd" || true)
    if [[ -n "$procs" ]]; then
        # Cabecera
        printf "  %-8s %-6s %-6s %s\n" "USER" "PID" "%CPU" "COMMAND"
        echo "$procs" | awk '{printf "  %-8s %-6s %-6s %s\n", $1, $2, $3, $11}' | head -10
    else
        aputs_warning "No hay procesos vsftpd en ejecucion"
    fi

    # ── Versión instalada ─────────────────────────────────────────────────────
    echo ""
    aputs_info "[ Version vsftpd ]"
    draw_line

    local version
    version=$(rpm -q vsftpd 2>/dev/null || echo "No instalado")
    aputs_info "Paquete: $version"

    # Mostrar la versión binaria de vsftpd si está disponible
    if command -v vsftpd &>/dev/null; then
        aputs_info "Binario: $(vsftpd -v 2>&1 | head -1)"
    fi

    # ── Configuración activa ──────────────────────────────────────────────────
    echo ""
    aputs_info "[ Configuracion activa (vsftpd.conf) ]"
    draw_line

    if [[ -f "$FTP_CONFIG" ]]; then
        # Mostrar solo directivas activas (sin comentarios ni líneas vacías)
        grep -v "^#\|^$" "$FTP_CONFIG" 2>/dev/null | while IFS= read -r linea; do
            echo "  $linea"
        done
    else
        aputs_warning "$FTP_CONFIG no encontrado"
    fi

    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
#   CONEXIONES ACTIVAS
# ─────────────────────────────────────────────────────────────────────────────

# Muestra las conexiones TCP activas en los puertos FTP
# ss (socket statistics) es la herramienta moderna que reemplaza netstat en Fedora
_conexiones_activas_ftp() {
    draw_header "Conexiones FTP Activas"
    echo ""

    # ── Canal de control (puerto 21) ──────────────────────────────────────────
    aputs_info "[ Canal de control — Puerto $FTP_PORT_CONTROL ]"
    draw_line

    # ss -t: sockets TCP
    # -n: sin resolución de nombres (más rápido)
    # -p: mostrar proceso dueño del socket
    # state ESTABLISHED: solo conexiones activas (no las en escucha)
    local ctrl
    ctrl=$(ss -tnp state established 2>/dev/null | grep ":${FTP_PORT_CONTROL}" || true)

    if [[ -n "$ctrl" ]]; then
        printf "  %-22s %-22s %-22s %s\n" "LOCAL" "REMOTO" "ESTADO" "PROCESO"
        echo "$ctrl" | awk '{printf "  %-22s %-22s %-22s %s\n", $4, $5, $1, $6}' | head -20
        local n_ctrl
        n_ctrl=$(echo "$ctrl" | wc -l)
        aputs_info "Total conexiones de control: $n_ctrl"
    else
        aputs_info "No hay conexiones de control activas en el puerto $FTP_PORT_CONTROL"
    fi

    # ── Canal de datos PASV ───────────────────────────────────────────────────
    echo ""
    aputs_info "[ Canal de datos PASV ]"
    draw_line

    # Leer rango PASV del archivo de configuración
    local pmin pmax
    pmin=$(grep -m1 "^pasv_min_port=" "$FTP_CONFIG" 2>/dev/null | cut -d= -f2)
    pmax=$(grep -m1 "^pasv_max_port=" "$FTP_CONFIG" 2>/dev/null | cut -d= -f2)

    if [[ -n "$pmin" && -n "$pmax" ]]; then
        aputs_info "Rango PASV configurado: $pmin - $pmax"

        # Buscar conexiones en el rango PASV
        local datos
        datos=$(ss -tnp state established 2>/dev/null \
            | awk -v pmin="$pmin" -v pmax="$pmax" '{
                # Extraer el puerto local del campo Local Address:Port
                n = split($4, a, ":");
                port = a[n];
                if (port+0 >= pmin+0 && port+0 <= pmax+0) print
            }' || true)

        if [[ -n "$datos" ]]; then
            printf "  %-22s %-22s %s\n" "LOCAL (PASV)" "REMOTO" "PROCESO"
            echo "$datos" | awk '{printf "  %-22s %-22s %s\n", $4, $5, $6}' | head -20
            local n_datos
            n_datos=$(echo "$datos" | wc -l)
            aputs_info "Total conexiones de datos PASV activas: $n_datos"
        else
            aputs_info "No hay transferencias de datos PASV activas"
        fi
    else
        aputs_warning "Rango PASV no encontrado en $FTP_CONFIG"
        aputs_info "Ejecute la instalacion (opcion 2) para configurar vsftpd"
    fi

    # ── Resumen de todos los sockets vsftpd ───────────────────────────────────
    echo ""
    aputs_info "[ Todos los sockets vsftpd ]"
    draw_line

    ss -tnp 2>/dev/null | grep "vsftpd" | while IFS= read -r linea; do
        echo "  $linea"
    done || aputs_info "No hay sockets vsftpd activos"

    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
#   LOGS
# ─────────────────────────────────────────────────────────────────────────────
#
# Muestra el log de transferencias de archivos (/var/log/xferlog)
# Formato de cada línea xferlog (formato wu-ftpd estándar):
#

_ver_log_transferencias() {
    draw_header "Log de Transferencias — /var/log/xferlog"

    local log_file="/var/log/xferlog"

    if [[ ! -f "$log_file" ]]; then
        aputs_warning "Archivo de log no encontrado: $log_file"
        aputs_info "Se crea automáticamente cuando ocurre la primera transferencia"
        aputs_info "Verifique que xferlog_enable=YES en $FTP_CONFIG"
        return 0
    fi

    local lineas
    while true; do
        agets "Cuantas lineas mostrar [50]" lineas
        lineas="${lineas:-50}"
        ftp_validar_lineas_log "$lineas" && break
    done

    echo ""
    aputs_info "Ultimas $lineas transferencias:"
    draw_line

    # Mostrar las últimas N líneas del xferlog con parseo legible
    if [[ -s "$log_file" ]]; then
        tail -n "$lineas" "$log_file" 2>/dev/null | while IFS= read -r linea; do
            # Parsear campos del formato xferlog
            # Campo 7: duración(s), 9: bytes, 10: ruta, 12: dirección, 14: usuario
            local duracion bytes ruta direccion usuario fecha
            read -r _ _ fecha hora _ duracion _ bytes ruta _ _ direccion _ _ usuario _ <<< "$linea"

            # Traducir dirección a texto legible
            local dir_txt
            case "$direccion" in
                i) dir_txt="${GREEN}SUBIDA   ${NC}" ;;
                o) dir_txt="${BLUE}BAJADA   ${NC}" ;;
                *) dir_txt="${GRAY}desconocido${NC}" ;;
            esac

            # Convertir bytes a formato legible
            local size_txt
            if [[ "$bytes" =~ ^[0-9]+$ ]]; then
                if (( bytes >= 1048576 )); then
                    size_txt=$(( bytes / 1048576 ))MB
                elif (( bytes >= 1024 )); then
                    size_txt=$(( bytes / 1024 ))KB
                else
                    size_txt="${bytes}B"
                fi
            else
                size_txt="?"
            fi

            echo -e "  ${GRAY}$fecha $hora${NC}  $dir_txt  ${CYAN}${usuario:-?}${NC}  ${size_txt}  ${ruta:-?}"
        done
    else
        aputs_info "El log de transferencias esta vacio — aun no se han realizado transferencias"
    fi

    echo ""
    local total_lineas
    total_lineas=$(wc -l < "$log_file" 2>/dev/null || echo 0)
    aputs_info "Total de entradas en xferlog: $total_lineas"
}

# Muestra el log de eventos de vsftpd (/var/log/vsftpd.log)
# Registra: conexiones, autenticaciones, comandos FTP, errores, desconexiones
_ver_log_eventos() {
    draw_header "Log de Eventos vsftpd — /var/log/vsftpd.log"

    local log_file="/var/log/vsftpd.log"

    if [[ ! -f "$log_file" ]]; then
        aputs_warning "Archivo de log no encontrado: $log_file"
        aputs_info "Verifique que vsftpd_log_file=/var/log/vsftpd.log en $FTP_CONFIG"
        aputs_info "Alternativa: sudo journalctl -u vsftpd --no-pager"
        return 0
    fi

    local lineas
    while true; do
        agets "Cuantas lineas mostrar [50]" lineas
        lineas="${lineas:-50}"
        ftp_validar_lineas_log "$lineas" && break
    done

    echo ""
    aputs_info "Ultimas $lineas entradas del log de eventos:"
    draw_line

    if [[ -s "$log_file" ]]; then
        # Colorizar líneas según tipo de evento
        tail -n "$lineas" "$log_file" 2>/dev/null | while IFS= read -r linea; do
            if echo "$linea" | grep -qi "error\|fail\|denied\|invalid\|refused"; then
                echo -e "  ${RED}$linea${NC}"
            elif echo "$linea" | grep -qi "ok\|connect\|login\|close"; then
                echo -e "  ${GREEN}$linea${NC}"
            elif echo "$linea" | grep -qi "warn"; then
                echo -e "  ${YELLOW}$linea${NC}"
            else
                echo "  $linea"
            fi
        done
    else
        aputs_info "El log de eventos esta vacio"
    fi

    echo ""
    aputs_info "Para ver el log de systemd use: sudo journalctl -u vsftpd -n $lineas"
}

# Genera estadísticas de uso por usuario a partir del xferlog
# Muestra: total subidas, total bajadas, bytes transferidos por usuario
_estadisticas_usuarios() {
    draw_header "Estadisticas de Transferencias por Usuario"

    local log_file="/var/log/xferlog"

    if [[ ! -f "$log_file" ]] || [[ ! -s "$log_file" ]]; then
        aputs_info "No hay datos de transferencias todavia"
        aputs_info "Las estadisticas se generan desde: $log_file"
        return 0
    fi

    echo ""
    printf "  %-20s %8s %8s %12s %12s\n" \
        "USUARIO" "SUBIDAS" "BAJADAS" "BYTES SUBIDOS" "BYTES BAJADOS"
    draw_line
    printf "  %-20s %8s %8s %12s %12s\n" \
        "───────" "───────" "───────" "─────────────" "─────────────"

    # Parsear xferlog con awk
    # Campo 10: ruta del archivo
    # Campo 12: dirección (i=subida, o=bajada)
    # Campo 9:  bytes
    # Campo 14: usuario (campo 14, 0-indexed desde el inicio de línea)
    awk '
    {
        # En xferlog, los campos son posicionales
        # el usuario está en el campo NF-1 (penúltimo) cuando hay 15+ campos
        if (NF >= 14) {
            usuario = $(NF-1)
            bytes   = $8
            dir     = $11

            if (dir == "i") {
                subidas[usuario]++
                bytes_subidos[usuario] += bytes
            } else if (dir == "o") {
                bajadas[usuario]++
                bytes_bajados[usuario] += bytes
            }
        }
    }
    END {
        for (u in subidas) {
            if (!(u in bajadas)) bajadas[u] = 0
            if (!(u in bytes_bajados)) bytes_bajados[u] = 0
            printf "  %-20s %8d %8d %12d %12d\n",
                u, subidas[u], bajadas[u], bytes_subidos[u], bytes_bajados[u]
        }
        for (u in bajadas) {
            if (!(u in subidas)) {
                printf "  %-20s %8d %8d %12d %12d\n",
                    u, 0, bajadas[u], 0, bytes_bajados[u]
            }
        }
    }
    ' "$log_file" 2>/dev/null | sort -k2 -rn

    echo ""

    # Totales globales
    local total_subidas total_bajadas total_bytes
    total_subidas=$(awk '{if (NF>=14 && $11=="i") count++} END {print count+0}' "$log_file")
    total_bajadas=$(awk '{if (NF>=14 && $11=="o") count++} END {print count+0}' "$log_file")
    total_bytes=$(awk '{if (NF>=14) sum+=$8} END {print sum+0}' "$log_file")

    draw_line
    aputs_info "Totales — Subidas: $total_subidas  |  Bajadas: $total_bajadas  |  Bytes: $total_bytes"

    # Período cubierto por el log
    local primera_fecha ultima_fecha
    primera_fecha=$(head -1 "$log_file" 2>/dev/null | awk '{print $1,$2,$3,$5}')
    ultima_fecha=$(tail -1 "$log_file" 2>/dev/null | awk '{print $1,$2,$3,$5}')
    [[ -n "$primera_fecha" ]] && aputs_info "Desde: $primera_fecha  |  Hasta: $ultima_fecha"
}

# ─────────────────────────────────────────────────────────────────────────────
#   TIEMPO REAL
# ─────────────────────────────────────────────────────────────────────────────

# Sigue el log de vsftpd en tiempo real (como tail -f)
# Permite al administrador ver eventos de conexión y transferencia al momento
_seguimiento_tiempo_real() {
    draw_header "Seguimiento en Tiempo Real"

    echo ""
    aputs_info "Seleccione el log a seguir:"
    aputs_info "  1) Log de eventos vsftpd (/var/log/vsftpd.log)"
    aputs_info "  2) Log de transferencias (/var/log/xferlog)"
    aputs_info "  3) Journal del sistema (journalctl -u vsftpd -f)"
    echo ""

    local sel
    read -rp "  Opcion: " sel

    echo ""
    aputs_info "Presione Ctrl+C para detener el seguimiento..."
    draw_line
    echo ""

    case "$sel" in
        1)
            if [[ -f "/var/log/vsftpd.log" ]]; then
                tail -f "/var/log/vsftpd.log"
            else
                aputs_warning "/var/log/vsftpd.log no existe todavia"
                aputs_info "Se crea al primer evento FTP — mostrando journal en su lugar"
                journalctl -u vsftpd -f --no-pager 2>/dev/null
            fi
            ;;
        2)
            if [[ -f "/var/log/xferlog" ]]; then
                tail -f "/var/log/xferlog"
            else
                aputs_warning "/var/log/xferlog no existe todavia"
                aputs_info "Se crea cuando ocurra la primera transferencia"
            fi
            ;;
        3)
            journalctl -u vsftpd -f --no-pager 2>/dev/null
            ;;
        *)
            aputs_error "Opcion invalida"
            ;;
    esac
}