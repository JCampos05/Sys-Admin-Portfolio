#
# Módulo: Acceso autenticado al servidor FTP con sesión persistente
#
# Requiere:
#   utils_cliente.sh   
#

# ─── Variables de sesión (en memoria, no persistentes) ───────────────────────
# Estas variables se pueblan al iniciar sesión y se limpian al cerrarla.
# Son globales dentro del proceso del script principal.
SESION_SERVIDOR=""    # "fedora" | "windows"
SESION_IP=""          # IP del servidor activo
SESION_USUARIO=""     # Nombre de usuario FTP
SESION_PASS=""        # Contraseña (en memoria, nunca en disco)
SESION_ACTIVA=false   # Bandera de sesión abierta

# ─── Función principal — submenú de acceso autenticado ───────────────────────

acceso_autenticado_ftp() {
    while true; do
        clear
        draw_header "Acceso Autenticado — Sesion FTP"
        echo ""

        # Mostrar estado actual de la sesión en el encabezado del submenú
        if $SESION_ACTIVA; then
            aputs_success "Sesion activa: ${SESION_USUARIO}@${SESION_IP} (${SESION_SERVIDOR})"
        else
            aputs_warning "Sin sesion activa — seleccione opcion 1 para iniciar"
        fi

        echo ""
        aputs_info "  ── Sesion ──────────────────────────────"
        aputs_info "  1) Iniciar sesion"
        aputs_info "  2) Cerrar sesion"
        echo ""
        aputs_info "  ── Operaciones ─────────────────────────"
        aputs_info "  3) Listar directorio remoto"
        aputs_info "  4) Subir archivo"
        aputs_info "  5) Descargar archivo"
        aputs_info "  6) Crear directorio remoto"
        aputs_info "  7) Eliminar archivo remoto"
        echo ""
        aputs_info "  8) Volver al menu principal"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1) _iniciar_sesion; pause ;;
            2) _cerrar_sesion;  pause ;;
            3) _sesion_listar;       pause ;;
            4) _sesion_subir;        pause ;;
            5) _sesion_descargar;    pause ;;
            6) _sesion_mkdir;        pause ;;
            7) _sesion_eliminar;     pause ;;
            8) return 0 ;;
            *)
                aputs_error "Opcion invalida. Seleccione del 1 al 8"
                sleep 2
                ;;
        esac
    done
}

# ─── Gestión de sesión ────────────────────────────────────────────────────────

# Inicia sesión: pide servidor, usuario, contraseña y verifica la conexión
_iniciar_sesion() {
    draw_header "Iniciar Sesion FTP"

    # Si ya hay sesión, preguntar si reemplazarla
    if $SESION_ACTIVA; then
        aputs_warning "Ya hay una sesion activa: ${SESION_USUARIO}@${SESION_IP}"
        local resp
        agets "Cerrar sesion actual e iniciar una nueva? [s/N]" resp
        if [[ ! "$resp" =~ ^[Ss]$ ]]; then
            aputs_info "Sesion actual conservada"
            return 0
        fi
        _cerrar_sesion
    fi

    # lftp instalado
    if ! check_lftp_instalado; then
        aputs_error "lftp no esta instalado — use la opcion 2 del menu principal"
        return 1
    fi

    # Elegir servidor
    echo ""
    aputs_info "Servidor de destino:"
    echo "    1) Fedora Server  ($(conf_get IP_FEDORA 2>/dev/null || echo 'no configurada'))"
    echo "    2) Windows Server ($(conf_get IP_WINDOWS 2>/dev/null || echo 'no configurada'))"
    echo ""
    local sel_srv
    agets "Seleccione servidor [1-2]" sel_srv

    local clave_ip etiqueta_srv
    case "$sel_srv" in
        1) clave_ip="IP_FEDORA";  etiqueta_srv="fedora"  ;;
        2) clave_ip="IP_WINDOWS"; etiqueta_srv="windows" ;;
        *)
            aputs_error "Seleccion invalida"
            return 1
            ;;
    esac

    local ip
    ip=$(conf_get "$clave_ip")
    if [[ -z "$ip" ]]; then
        aputs_error "IP del servidor no configurada"
        aputs_warning "Configure las IPs desde la opcion 0 del menu principal antes de conectar"
        return 1
    fi

    # Verificar que el puerto 21 responda antes de pedir credenciales
    aputs_info "Verificando accesibilidad de $ip:21..."
    if ! check_puerto_ftp "$ip"; then
        aputs_error "El servidor $ip no responde en el puerto 21"
        aputs_info  "Verifique que el servicio FTP este activo en el servidor"
        return 1
    fi
    aputs_success "Puerto 21 accesible en $ip"

    # Pedir credenciales
    echo ""
    local usuario
    agets "Usuario FTP" usuario
    if [[ -z "$usuario" ]]; then
        aputs_error "El usuario no puede estar vacio"
        return 1
    fi

    # Leer contraseña sin eco (no se muestra en pantalla)
    local pass
    echo -ne "${CYAN}[INPUT]${NC} Contrasena: "
    read -rs pass
    echo

    if [[ -z "$pass" ]]; then
        aputs_error "La contrasena no puede estar vacia"
        return 1
    fi

    # Verificar credenciales con un comando lftp de prueba (solo pwd)
    aputs_info "Verificando credenciales..."
    local script_prueba
    script_prueba=$(mktemp /tmp/ftp_test_XXXXXX)
    # El trap garantiza que el archivo temporal se elimine aunque el script falle
    trap "rm -f '$script_prueba'" RETURN

    cat > "$script_prueba" <<LFTP_EOF
open -u '${usuario}','${pass}' ${ip}
set ftp:passive-mode true
set net:timeout 10
pwd
bye
LFTP_EOF

    local salida
    salida=$(lftp -f "$script_prueba" 2>&1)
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        aputs_error "No se pudo autenticar en $ip"
        # Mostrar el mensaje de error de lftp para diagnóstico
        echo "$salida" | grep -i "error\|fail\|denied\|530" | head -3 \
            | while IFS= read -r linea; do aputs_info "  lftp: $linea"; done
        aputs_info "Verifique usuario, contrasena y que el servidor FTP este activo"
        return 1
    fi

    # Credenciales correctas: guardar en memoria
    SESION_SERVIDOR="$etiqueta_srv"
    SESION_IP="$ip"
    SESION_USUARIO="$usuario"
    SESION_PASS="$pass"
    SESION_ACTIVA=true

    aputs_success "Sesion iniciada correctamente"
    aputs_success "  Servidor : $etiqueta_srv ($ip)"
    aputs_success "  Usuario  : $usuario"
    aputs_info    "Las credenciales se mantienen en memoria durante esta sesion"
}

# Cierra la sesión limpiando las variables de memoria
_cerrar_sesion() {
    if ! $SESION_ACTIVA; then
        aputs_info "No hay sesion activa"
        return 0
    fi

    aputs_info "Cerrando sesion de ${SESION_USUARIO}@${SESION_IP}..."

    # Limpiar todas las variables de sesión
    SESION_SERVIDOR=""
    SESION_IP=""
    SESION_USUARIO=""
    SESION_PASS=""
    SESION_ACTIVA=false

    aputs_success "Sesion cerrada — credenciales eliminadas de memoria"
}

# ─── Guarda de sesión ─────────────────────────────────────────────────────────
# Verifica que haya sesión activa antes de cada operación.
# Si no hay sesión, muestra el aviso y retorna 1 para que el llamador salga.
_requiere_sesion() {
    if ! $SESION_ACTIVA; then
        aputs_error "No hay sesion activa"
        aputs_info  "Seleccione la opcion 1 para iniciar sesion primero"
        return 1
    fi
    return 0
}

# ─── Ejecutor de comandos lftp con sesión activa ──────────────────────────────
# Construye y ejecuta un script lftp usando las credenciales en memoria.
# El script temporal se crea con mktemp (permisos 600) y se elimina al terminar.
#
# $1 = bloque de comandos lftp a ejecutar (sin el open ni el bye)
# Retorna el código de salida de lftp
_ejecutar_con_sesion() {
    local comandos="$1"

    local tmp
    tmp=$(mktemp /tmp/ftp_sesion_XXXXXX)
    # trap garantiza eliminación del temporal incluso si hay error
    trap "rm -f '$tmp'" RETURN

    cat > "$tmp" <<LFTP_EOF
open -u '${SESION_USUARIO}','${SESION_PASS}' ${SESION_IP}
set ftp:passive-mode true
set net:timeout 15
${comandos}
bye
LFTP_EOF

    lftp -f "$tmp" 2>&1
    return $?
}

# ─── Operaciones con sesión ───────────────────────────────────────────────────

# Lista el contenido de un directorio remoto
_sesion_listar() {
    draw_header "Listar Directorio Remoto"
    _requiere_sesion || return 1

    echo ""
    local directorio
    agets "Directorio remoto a listar (Enter para raiz)" directorio
    [[ -z "$directorio" ]] && directorio="/"

    aputs_info "Listando: ${SESION_IP}:${directorio}"
    draw_line

    _ejecutar_con_sesion "cd '${directorio}'; ls -la"

    local rc=$?
    draw_line
    [[ $rc -eq 0 ]] \
        && aputs_success "Listado completado" \
        || aputs_error   "Error al listar (codigo: $rc)"
}

# Sube un archivo local al servidor
_sesion_subir() {
    draw_header "Subir Archivo al Servidor"
    _requiere_sesion || return 1

    echo ""
    # Ruta del archivo local
    local archivo_local
    agets "Ruta del archivo local a subir" archivo_local

    if [[ ! -f "$archivo_local" ]]; then
        aputs_error "El archivo no existe: $archivo_local"
        aputs_info  "Use rutas absolutas (ej: /home/usuario/Documentos/tarea.pdf)"
        return 1
    fi

    # Directorio remoto destino
    local directorio_remoto
    agets "Directorio remoto destino (Enter para raiz)" directorio_remoto
    [[ -z "$directorio_remoto" ]] && directorio_remoto="/"

    local nombre_archivo
    nombre_archivo=$(basename "$archivo_local")

    aputs_info "Subiendo: $archivo_local → ${SESION_IP}:${directorio_remoto}/${nombre_archivo}"
    draw_line

    _ejecutar_con_sesion "cd '${directorio_remoto}'; put '${archivo_local}'"

    local rc=$?
    draw_line
    if [[ $rc -eq 0 ]]; then
        aputs_success "Archivo subido: ${directorio_remoto}/${nombre_archivo}"
    else
        aputs_error "Error al subir el archivo (codigo: $rc)"
        aputs_info  "Verifique que tiene permisos de escritura en el directorio remoto"
    fi
}

# Descarga un archivo del servidor al equipo local
_sesion_descargar() {
    draw_header "Descargar Archivo del Servidor"
    _requiere_sesion || return 1

    echo ""
    local archivo_remoto
    agets "Ruta del archivo remoto a descargar (ej: /general/informe.pdf)" archivo_remoto

    if [[ -z "$archivo_remoto" ]]; then
        aputs_error "La ruta no puede estar vacia"
        return 1
    fi

    # Directorio local destino
    local directorio_local="${HOME}/Descargas"
    mkdir -p "$directorio_local"
    aputs_info "Destino local por defecto: $directorio_local"

    local cambiar_dest
    agets "Usar otro directorio local? [s/N]" cambiar_dest
    if [[ "$cambiar_dest" =~ ^[Ss]$ ]]; then
        agets "Directorio local destino" directorio_local
        if [[ ! -d "$directorio_local" ]]; then
            aputs_info "El directorio no existe. Creando: $directorio_local"
            mkdir -p "$directorio_local" || {
                aputs_error "No se pudo crear el directorio: $directorio_local"
                return 1
            }
        fi
    fi

    local nombre_archivo
    nombre_archivo=$(basename "$archivo_remoto")

    aputs_info "Descargando: ${SESION_IP}:${archivo_remoto} → ${directorio_local}/"
    draw_line

    _ejecutar_con_sesion "get '${archivo_remoto}' -o '${directorio_local}/'"

    local rc=$?
    draw_line
    if [[ $rc -eq 0 ]]; then
        aputs_success "Archivo descargado: ${directorio_local}/${nombre_archivo}"
    else
        aputs_error "Error al descargar (codigo: $rc)"
        aputs_info  "Verifique que el archivo existe en el servidor y tiene permisos de lectura"
    fi
}

# Crea un directorio en el servidor remoto
_sesion_mkdir() {
    draw_header "Crear Directorio Remoto"
    _requiere_sesion || return 1

    echo ""
    local directorio_nuevo
    agets "Ruta del nuevo directorio remoto (ej: /user1/proyectos)" directorio_nuevo

    if [[ -z "$directorio_nuevo" ]]; then
        aputs_error "La ruta no puede estar vacia"
        return 1
    fi

    aputs_info "Creando directorio: ${SESION_IP}:${directorio_nuevo}"
    draw_line

    _ejecutar_con_sesion "mkdir -p '${directorio_nuevo}'"

    local rc=$?
    draw_line
    [[ $rc -eq 0 ]] \
        && aputs_success "Directorio creado: ${directorio_nuevo}" \
        || aputs_error   "Error al crear directorio (codigo: $rc)"
}

# Elimina un archivo del servidor remoto
_sesion_eliminar() {
    draw_header "Eliminar Archivo Remoto"
    _requiere_sesion || return 1

    echo ""
    local archivo_remoto
    agets "Ruta del archivo remoto a eliminar" archivo_remoto

    if [[ -z "$archivo_remoto" ]]; then
        aputs_error "La ruta no puede estar vacia"
        return 1
    fi

    # Confirmación antes de borrar
    aputs_warning "Va a eliminar: ${SESION_IP}:${archivo_remoto}"
    local confirm
    agets "Confirmar eliminacion? [s/N]" confirm
    if [[ ! "$confirm" =~ ^[Ss]$ ]]; then
        aputs_info "Operacion cancelada"
        return 0
    fi

    draw_line
    _ejecutar_con_sesion "rm '${archivo_remoto}'"

    local rc=$?
    draw_line
    [[ $rc -eq 0 ]] \
        && aputs_success "Archivo eliminado: ${archivo_remoto}" \
        || aputs_error   "Error al eliminar (codigo: $rc)"
}