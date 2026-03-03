#
#
# Módulo: Instalar, configurar e iniciar el servicio FTP (vsftpd)
#
# Requiere:
#   utils.sh 
#

# ─── Función principal ───────────────────────────────────────────────────────

# Instala, configura e inicia vsftpd de forma interactiva
# Se llama desde main_menu opción 2
instalar_configurar_ftp() {
    draw_header "Instalar y Configurar FTP (vsftpd)"

    # ── Paso 1: Instalar vsftpd ──────────────────────────────────────────────
    echo ""
    aputs_info "[ Paso 1/9 ] Instalacion del paquete vsftpd"
    draw_line

    if check_package_installed "vsftpd"; then
        local version
        version=$(rpm -q vsftpd 2>/dev/null)
        aputs_success "vsftpd ya esta instalado: $version"
    else
        aputs_info "Instalando vsftpd con dnf..."
        if dnf install -y vsftpd 2>/dev/null; then
            aputs_success "vsftpd instalado correctamente"
        else
            aputs_error "Error al instalar vsftpd — verifique conectividad y repositorios"
            return 1
        fi
    fi

    # ── Paso 2: Corregir PAM y /etc/shells ──────────────────────────────────
    #
    # Este es el paso más importante para que el login FTP funcione.
    # Sin él, TODOS los usuarios con shell=/sbin/nologin son rechazados por PAM.
    #
    echo ""
    aputs_info "[ Paso 2/9 ] Correccion PAM y /etc/shells"
    draw_line

    _corregir_pam_vsftpd

    # ── Paso 3: Crear grupos base y grupo de bloqueo SSH ─────────────────────
    echo ""
    aputs_info "[ Paso 3/9 ] Creacion de grupos FTP base"
    draw_line

    # Grupo ftp_users: todos los usuarios FTP pertenecen a este grupo.
    # En sshd_config se configura DenyGroups ftp_users para bloquear SSH
    # a estos usuarios — FTP y SSH son canales separados.
    if ! getent group "$FTP_SSH_GROUP" &>/dev/null; then
        groupadd "$FTP_SSH_GROUP"
        aputs_success "Grupo de bloqueo SSH creado: $FTP_SSH_GROUP"
    else
        aputs_info "Grupo '$FTP_SSH_GROUP' ya existe"
    fi

    # Grupos académicos base
    local g
    for g in "${FTP_GROUPS_BASE[@]}"; do
        if ! getent group "$g" &>/dev/null; then
            groupadd "$g"
            aputs_success "Grupo creado: $g"
        else
            aputs_info "Grupo '$g' ya existe"
        fi
    done

    # Guardar grupos en archivo de lista para uso de otros módulos
    mkdir -p "$VSFTPD_DIR"
    if [[ ! -f "$VSFTPD_GROUPS_FILE" ]]; then
        printf '%s\n' "${FTP_GROUPS_BASE[@]}" > "$VSFTPD_GROUPS_FILE"
        aputs_success "Lista de grupos guardada: $VSFTPD_GROUPS_FILE"
    fi

    # Inicializar archivo de metadatos de usuarios
    touch "$VSFTPD_USERS_META"
    chmod 640 "$VSFTPD_USERS_META"

    # ── Paso 4: Estructura de directorios base ───────────────────────────────
    echo ""
    aputs_info "[ Paso 4/9 ] Estructura de directorios en $FTP_ROOT"
    draw_line

    _crear_estructura_base

    # ── Paso 5: Parámetros de configuración vsftpd.conf ──────────────────────
    echo ""
    aputs_info "[ Paso 5/9 ] Configuracion de vsftpd.conf"
    draw_line
    aputs_info "Se pediran los parametros clave. Presione Enter para usar el valor por defecto."
    echo ""

    # IP de escucha (normalmente la de Red_Sistemas)
    local ip_servidor
    agets "IP del servidor FTP [192.168.100.10]" ip_servidor
    ip_servidor="${ip_servidor:-192.168.100.10}"

    # Puerto de control FTP
    local puerto_control
    while true; do
        agets "Puerto de control FTP [21]" puerto_control
        puerto_control="${puerto_control:-21}"
        ftp_validar_puerto_control "$puerto_control" && break
    done

    # Rango de puertos pasivos (PASV)
    # Se usan para el canal de datos en modo pasivo.
    # Deben estar abiertos en el firewall del servidor.
    local pasv_min pasv_max
    while true; do
        agets "Puerto PASV minimo [50000]" pasv_min
        pasv_min="${pasv_min:-50000}"
        agets "Puerto PASV maximo [51000]" pasv_max
        pasv_max="${pasv_max:-51000}"
        ftp_validar_rango_pasv "$pasv_min" "$pasv_max" && break
    done

    # Máximo de clientes simultáneos
    local max_clientes
    while true; do
        agets "Maximo de clientes simultaneos [50]" max_clientes
        max_clientes="${max_clientes:-50}"
        ftp_validar_max_clientes "$max_clientes" && break
    done

    # Máximo de conexiones por IP
    local max_por_ip
    while true; do
        agets "Maximo de conexiones por IP [3]" max_por_ip
        max_por_ip="${max_por_ip:-3}"
        ftp_validar_max_por_ip "$max_por_ip" && break
    done

    # Timeout de sesión inactiva
    local timeout_sesion
    while true; do
        agets "Timeout sesion inactiva en segundos [300]" timeout_sesion
        timeout_sesion="${timeout_sesion:-300}"
        ftp_validar_timeout_sesion "$timeout_sesion" && break
    done

    # Timeout de transferencia de datos
    local timeout_datos
    while true; do
        agets "Timeout de transferencia de datos en segundos [120]" timeout_datos
        timeout_datos="${timeout_datos:-120}"
        ftp_validar_timeout_datos "$timeout_datos" && break
    done

    # Banner de bienvenida
    local banner
    while true; do
        agets "Mensaje de bienvenida FTP [Servidor FTP Institucional - Solo acceso autorizado]" banner
        banner="${banner:-Servidor FTP Institucional - Solo acceso autorizado}"
        ftp_validar_banner "$banner" && break
    done

    # Hacer copia de seguridad de vsftpd.conf original
    if [[ -f "$FTP_CONFIG" ]]; then
        local backup="${FTP_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$FTP_CONFIG" "$backup"
        aputs_info "Backup de configuracion anterior: $backup"
    fi

    # Escribir vsftpd.conf
    _escribir_vsftpd_conf \
        "$ip_servidor" "$puerto_control" \
        "$pasv_min" "$pasv_max" \
        "$max_clientes" "$max_por_ip" \
        "$timeout_sesion" "$timeout_datos" \
        "$banner"

    # ── Paso 6: SELinux ──────────────────────────────────────────────────────
    echo ""
    aputs_info "[ Paso 6/9 ] Configuracion SELinux para FTP"
    draw_line

    _configurar_selinux "$pasv_min" "$pasv_max"

    # ── Paso 7: Firewalld ────────────────────────────────────────────────────
    echo ""
    aputs_info "[ Paso 7/9 ] Configuracion firewalld"
    draw_line

    _configurar_firewall "$pasv_min" "$pasv_max"

    # ── Paso 8: Habilitar e iniciar servicio ─────────────────────────────────
    echo ""
    aputs_info "[ Paso 8/9 ] Habilitando e iniciando vsftpd"
    draw_line

    systemctl enable "$FTP_SERVICE" 2>/dev/null \
        && aputs_success "vsftpd habilitado en arranque" \
        || aputs_warning "No se pudo habilitar vsftpd en arranque"

    # Reiniciar si ya estaba corriendo, iniciar si no
    if check_service_active "$FTP_SERVICE"; then
        systemctl restart "$FTP_SERVICE" 2>/dev/null \
            && aputs_success "vsftpd reiniciado con nueva configuracion" \
            || aputs_error "Error al reiniciar vsftpd — revise: journalctl -u vsftpd -n 20"
    else
        systemctl start "$FTP_SERVICE" 2>/dev/null \
            && aputs_success "vsftpd iniciado" \
            || aputs_error "Error al iniciar vsftpd — revise: journalctl -u vsftpd -n 20"
    fi

    # ── Paso 9: Verificar puerto en escucha ──────────────────────────────────
    echo ""
    aputs_info "[ Paso 9/9 ] Verificando puerto $puerto_control en escucha"
    draw_line

    # Dar 2 segundos al servicio para abrir el socket
    sleep 2

    if check_port_listening "$puerto_control"; then
        aputs_success "Puerto $puerto_control en escucha — vsftpd listo"
    else
        aputs_error "Puerto $puerto_control NO esta en escucha"
        aputs_info "Revise el log: journalctl -u vsftpd -n 30"
    fi

    echo ""
    draw_line
    aputs_success "Instalacion y configuracion de FTP completada"
    draw_line
    echo ""
}

# ─── Función auxiliar: corregir PAM y /etc/shells ────────────────────────────
#
# PROBLEMA QUE RESUELVE:
#   PAM ejecuta una cadena de módulos de autenticación para cada login FTP.
#   El módulo pam_shells.so comprueba que la shell del usuario esté listada
#   en /etc/shells. Si no está → falla con:
#     "pam_shells(vsftpd:auth): User has an invalid shell '/sbin/nologin'"
#
#   /sbin/nologin es la shell que asignamos a usuarios FTP precisamente para
#   que NO puedan hacer login interactivo (SSH/consola). Es la práctica
#   correcta de seguridad. El problema es que /etc/shells no la incluye
#   en la instalación limpia de Fedora.
#
# SOLUCIÓN IMPLEMENTADA (doble):
#
#   A) /etc/shells — agregar /sbin/nologin y /usr/sbin/nologin
#      /etc/shells es la lista blanca de shells válidas para el sistema.
#      En Fedora, /sbin es un symlink a /usr/sbin pero ambas rutas pueden
#      aparecer en /etc/passwd, por eso registramos ambas.
#
#   B) /etc/pam.d/vsftpd — reescribir sin pam_shells
#      El archivo PAM de vsftpd por defecto en Fedora incluye:
#        auth required pam_shells.so
#      Esta línea es el origen del rechazo. La eliminamos y dejamos solo
#      autenticación via pam_unix (contraseña en /etc/shadow).
#
#      Stack PAM resultante:
#        auth    — pam_listfile: userlist_deny + pam_unix: contraseña
#        account — pam_unix: cuenta válida + pam_nologin: no en modo nologin
#        session — pam_loginuid + pam_keyinit + pam_limits
#
_corregir_pam_vsftpd() {
    local pam_file="/etc/pam.d/vsftpd"
    local shells_file="/etc/shells"

    # ── A) Registrar /sbin/nologin en /etc/shells ────────────────────────────
    #
    # grep -qxF busca la línea EXACTA (no como regex, -x = línea completa)
    # Si no existe, la agrega con >>
    #
    local shell
    for shell in /sbin/nologin /usr/sbin/nologin; do
        if ! grep -qxF "$shell" "$shells_file" 2>/dev/null; then
            echo "$shell" >> "$shells_file"
            aputs_success "$shell registrado en $shells_file"
        else
            aputs_info "$shell ya estaba en $shells_file"
        fi
    done

    # ── B) Reescribir /etc/pam.d/vsftpd sin pam_shells ──────────────────────
    #
    # Primero hacemos backup del archivo original para poder restaurarlo
    # si algo sale mal. El backup lleva timestamp para no sobrescribir
    # backups anteriores.
    #
    if [[ -f "$pam_file" ]]; then
        local backup="${pam_file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$pam_file" "$backup"
        aputs_info "Backup de PAM anterior: $backup"
    fi

    # Escribir el nuevo /etc/pam.d/vsftpd
    # Cada línea tiene el formato: tipo  control  módulo  [argumentos]
    #
    #   tipo:    auth (autenticar), account (validar cuenta),
    #            session (setup de sesión), password (cambiar pass)
    #   control: required   = debe pasar (fallo bloquea PERO sigue cadena)
    #            requisite  = debe pasar (fallo detiene la cadena inmediatamente)
    #            sufficient = si pasa, termina cadena (éxito anticipado)
    #            optional   = fallo no es fatal
    #
    cat > "$pam_file" <<PAM_VSFTPD
#
# /etc/pam.d/vsftpd
#
# Configuracion PAM para vsftpd en Fedora Server
# Generado por el Gestor FTP — $(date '+%Y-%m-%d %H:%M:%S')
#
# NOTA: pam_shells.so ha sido ELIMINADO intencionalmente.
#   Los usuarios FTP usan shell=/sbin/nologin para bloquear login interactivo.
#   pam_shells rechazaria esos usuarios aunque sean validos para FTP.
#   /sbin/nologin fue agregado a /etc/shells como solucion alternativa.
#
# ─── AUTENTICACION ────────────────────────────────────────────────────────────
#
# pam_listfile: permite implementar una lista blanca o negra de usuarios.
#   item=user sense=deny file=/etc/vsftpd/ftpusers: rechaza usuarios listados
#   en /etc/vsftpd/ftpusers (root, bin, daemon, etc. — usuarios del sistema).
#   onerr=succeed: si el archivo no existe, permite el paso (no bloquea todo).
#
auth       required     pam_listfile.so item=user sense=deny file=/etc/vsftpd/ftpusers onerr=succeed
#
# pam_unix: autenticacion clasica contra /etc/shadow (contrasena del sistema).
#   shadow: leer hashes desde /etc/shadow (requiere que vsftpd corra como root).
#   nullok: NO permitir contrasenas vacias (nullok es el nombre aunque parece
#           lo contrario — sin nullok si la cuenta no tiene pass, falla).
#
auth       required     pam_unix.so shadow nullok
#
# ─── CUENTA ───────────────────────────────────────────────────────────────────
#
# pam_unix: verificar que la cuenta exista, no este bloqueada ni expirada.
#
account    required     pam_unix.so
#
# pam_nologin: si existe /etc/nologin, solo root puede entrar.
#   Util para modo de mantenimiento del servidor.
#
account    required     pam_nologin.so
#
# ─── SESION ───────────────────────────────────────────────────────────────────
#
# pam_loginuid: registra el UID real del usuario en el kernel audit subsystem.
#   Necesario para que los logs de auditoria sean correctos.
#
session    required     pam_loginuid.so
#
# pam_keyinit: inicializa el keyring del kernel para la sesion.
#   revoke: revocar al cerrar sesion.
#
session    optional     pam_keyinit.so force revoke
#
# pam_limits: aplica los limites de /etc/security/limits.conf
#   (max archivos abiertos, max procesos, etc.)
#
session    required     pam_limits.so
PAM_VSFTPD

    chmod 644 "$pam_file"
    aputs_success "PAM vsftpd reescrito sin pam_shells: $pam_file"

    # ── Verificar que /etc/vsftpd/ftpusers existe ────────────────────────────
    #
    # pam_listfile referencia este archivo. Si no existe, pam lanza warning.
    # ftpusers lista cuentas del sistema que NUNCA deben poder usar FTP,
    # independientemente de su contraseña.
    #
    local ftpusers_file="/etc/vsftpd/ftpusers"
    if [[ ! -f "$ftpusers_file" ]]; then
        mkdir -p /etc/vsftpd
        cat > "$ftpusers_file" <<FTPUSERS
# /etc/vsftpd/ftpusers
#
# Usuarios del sistema BLOQUEADOS para FTP.
# pam_listfile rechaza cualquier login que aparezca en esta lista.
# Agregue aqui cuentas privilegiadas que nunca deben usar FTP.
#
root
bin
daemon
adm
lp
sync
shutdown
halt
mail
operator
games
nobody
FTPUSERS
        chmod 640 "$ftpusers_file"
        aputs_success "Archivo ftpusers creado: $ftpusers_file"
    else
        aputs_info "ftpusers ya existe: $ftpusers_file"
    fi
}

# ─── Función auxiliar: crear estructura de directorios base ──────────────────
#
# Crea los directorios raíz de vsftpd:
#   /srv/ftp/              — raíz del servidor (root:ftp 755)
#   /srv/ftp/general/      — compartido y anon_root (root:ftp 555, sin escritura en raiz)
#   /srv/ftp/reprobados/   — exclusivo grupo reprobados (root:reprobados 2770+sticky)
#   /srv/ftp/recursadores/ — exclusivo grupo recursadores (root:recursadores 2770+sticky)
#
# El sticky bit (+t) en directorios de grupo evita que un miembro borre
# archivos subidos por otro miembro del mismo grupo.
# El setgid bit (2xxx) hace que los archivos creados hereden el grupo del dir.
#
_crear_estructura_base() {
    # Directorio raíz FTP
    mkdir -p "$FTP_ROOT"
    chown root:root "$FTP_ROOT"
    chmod 755 "$FTP_ROOT"
    aputs_success "Directorio raiz: $FTP_ROOT (root:root 755)"

    # Directorio general: lectura/ejecución para todos, sin escritura en la raíz.
    # Los permisos 555 son OBLIGATORIOS porque este directorio actúa como
    # anon_root de vsftpd: el daemon rechaza cualquier chroot cuya raíz
    # tenga bit de escritura (error "refusing to run with writable root").
    # Los usuarios autenticados escriben dentro de él via ACLs; el anónimo
    # solo puede listar y descargar.
    mkdir -p "$FTP_GENERAL"
    chown root:ftp "$FTP_GENERAL"
    chmod 555 "$FTP_GENERAL"
    aputs_success "Directorio general: $FTP_GENERAL (root:ftp 555)"

    # ACLs en general: solo ACLs DEFAULT (-d) para que los ARCHIVOS creados dentro
    # hereden permisos de lectura/escritura para todos los usuarios FTP.
    # NO se aplican ACLs de entrada (-m sin -d) sobre el directorio mismo —
    # eso le devolvería el bit de escritura al directorio y rompería el anon_root.
    if command -v setfacl &>/dev/null; then
        setfacl -d -m other::rwx "$FTP_GENERAL" 2>/dev/null || true
        setfacl -d -m group::rwx "$FTP_GENERAL" 2>/dev/null || true
        aputs_success "ACLs default aplicadas en $FTP_GENERAL (heredadas por archivos nuevos)"
    else
        aputs_warning "setfacl no disponible — instale: dnf install acl"
    fi

    # Directorios de grupos base
    local g
    for g in "${FTP_GROUPS_BASE[@]}"; do
        local dir="$FTP_ROOT/$g"
        mkdir -p "$dir"
        chown root:"$g" "$dir"
        chmod 2770 "$dir"
        chmod +t "$dir"
        aputs_success "Directorio de grupo: $dir (root:$g 3770)"
    done
}

# ─── Función auxiliar: escribir vsftpd.conf ──────────────────────────────────
#
# Recibe los parámetros recolectados interactivamente y genera
# un vsftpd.conf limpio, comentado y seguro.
#
# Cada directiva va explicada porque el archivo queda como documentación viva
# del servidor para el administrador que lo tome después.
#
_escribir_vsftpd_conf() {
    local ip_srv="$1"
    local pto_ctrl="$2"
    local pmin="$3"
    local pmax="$4"
    local max_cli="$5"
    local max_ip="$6"
    local t_sesion="$7"
    local t_datos="$8"
    local banner_txt="$9"

    cat > "$FTP_CONFIG" <<VSFTPD_CONF
#
# /etc/vsftpd/vsftpd.conf
#
# Generado por el Gestor FTP en Fedora Server
# Fecha: $(date '+%Y-%m-%d %H:%M:%S')
#
# ─── MODO DE ESCUCHA ──────────────────────────────────────────────────────────
#
# listen=YES: vsftpd corre como daemon standalone (no via inetd/xinetd).
# listen_ipv6=NO: desactivado para evitar conflicto con listen=YES en Fedora.
# La combinacion listen=YES + listen_ipv6=YES causa error de socket duplicado.
#
listen=YES
listen_ipv6=NO
listen_address=${ip_srv}
listen_port=${pto_ctrl}
#
# ─── ACCESO Y AUTENTICACION ───────────────────────────────────────────────────
#
# anonymous_enable=YES: permite acceso sin contraseña al directorio general.
#   El usuario anónimo ve ÚNICAMENTE /srv/ftp/general (definido en anon_root).
#   No puede acceder a chroots de usuarios ni directorios de grupos.
#
# anon_root: raíz que ve el usuario anónimo al conectarse.
#   DEBE tener permisos 555 (sin bit de escritura) — vsftpd rechaza
#   chroots escribibles con error "refusing to run with writable root".
#
# no_anon_password=YES: el cliente anónimo no necesita enviar contraseña.
#   Sin esta directiva, lftp envía un email de convención como password;
#   con ella, la conexión anónima se acepta directamente.
#
# local_enable=YES: permite login a usuarios del sistema Linux (/etc/passwd).
#   Cada usuario FTP ES un usuario del sistema con shell=/sbin/nologin.
#
# local_umask=022: los archivos subidos tienen permisos rw-r--r-- por defecto.
#   Se ajustará via ACL por directorio de grupo.
#
anonymous_enable=YES
anon_root=${FTP_GENERAL}
no_anon_password=YES
local_enable=YES
local_umask=022
#
# ─── PERMISOS DE ESCRITURA ────────────────────────────────────────────────────
#
# write_enable=YES: permite comandos de escritura (STOR, DELE, MKD, RMD).
#   Sin esto los usuarios solo pueden descargar — no subir archivos.
#
write_enable=YES
#
# ─── CHROOT (JAULA DE DIRECTORIOS) ───────────────────────────────────────────
#
# chroot_local_user=YES: enjaulaacada usuario en su directorio home.
#   El usuario ve "/" pero en realidad esta en /srv/ftp/ftp_<usuario>/.
#   No puede navegar fuera de esa raiz — proteccion de confidencialidad.
#
# allow_writeable_chroot=NO: el directorio chroot RAIZ no puede ser escribible.
#   vsftpd v3+ rechaza chroots con bit w por seguridad (CVE histotico).
#   Por eso el chroot raiz es root:root 755 y la carpeta privada del usuario
#   vive UN nivel mas abajo (/srv/ftp/ftp_usuario/usuario/ 700).
#
chroot_local_user=YES
allow_writeable_chroot=NO
#
# ─── MODO PASIVO (PASV) ───────────────────────────────────────────────────────
#
# FTP tiene DOS modos para el canal de datos:
#
#   ACTIVO: el servidor conecta HACIA el cliente (puerto 20 -> puerto alto cliente).
#     Problema: falla cuando el cliente esta detras de NAT o firewall.
#
#   PASIVO: el cliente conecta hacia el servidor en un puerto efimero.
#     Solucion: funciona con NAT. Es el modo que usan FileZilla, WinSCP, etc.
#
# pasv_enable=YES: activa modo pasivo.
# pasv_address: IP publica/accesible del servidor para que el cliente sepa adonde conectar.
# pasv_min_port / pasv_max_port: rango de puertos efimeros para datos pasivos.
#   Estos puertos DEBEN estar abiertos en el firewall del servidor.
#
pasv_enable=YES
pasv_address=${ip_srv}
pasv_min_port=${pmin}
pasv_max_port=${pmax}
#
# ─── LIMITES DE CONEXION ──────────────────────────────────────────────────────
#
# max_clients: maximo de clientes conectados simultaneamente al servidor.
# max_per_ip: maximo de conexiones desde una misma IP.
#   Limitar por IP previene que un usuario monopolice el servidor o haga DoS.
#
max_clients=${max_cli}
max_per_ip=${max_ip}
#
# ─── TIMEOUTS ─────────────────────────────────────────────────────────────────
#
# idle_session_timeout: segundos de inactividad antes de desconectar al cliente.
#   Libera recursos de sesiones abandonadas.
#
# data_connection_timeout: segundos para que inicie una transferencia de datos.
#   Si el cliente abre el canal pero no empieza a transferir, se cierra.
#
idle_session_timeout=${t_sesion}
data_connection_timeout=${t_datos}
#
# ─── MENSAJES ─────────────────────────────────────────────────────────────────
#
# ftpd_banner: mensaje que ve el cliente al conectarse (antes de autenticarse).
#   Identifica el servidor y advierte sobre acceso no autorizado.
#
# dirmessage_enable=YES: muestra el contenido de .message cuando se entra a un dir.
#   Útil para instrucciones por carpeta.
#
ftpd_banner=${banner_txt}
dirmessage_enable=YES
#
# ─── LOGGING ──────────────────────────────────────────────────────────────────
#
# xferlog_enable=YES: registra todas las transferencias.
# xferlog_std_format=YES: formato estandar wu-ftpd (compatible con herramientas de análisis).
# log_ftp_protocol=YES: registra comandos FTP — util para diagnostico y auditoria.
# vsftpd_log_file: ruta del archivo de log de vsftpd.
# xferlog_file: ruta del log de transferencias.
#
xferlog_enable=YES
xferlog_std_format=YES
log_ftp_protocol=YES
vsftpd_log_file=/var/log/vsftpd.log
xferlog_file=/var/log/xferlog
#
# ─── SEGURIDAD ADICIONAL ──────────────────────────────────────────────────────
#
# use_localtime=YES: usa la hora local del servidor en los logs.
# tcp_wrappers=NO: en Fedora moderno, tcp_wrappers esta deprecado.
#
use_localtime=YES
tcp_wrappers=NO
#
# ─── SOPORTE PAM ──────────────────────────────────────────────────────────────
#
# pam_service_name=vsftpd: indica a PAM que use /etc/pam.d/vsftpd.
#   PAM gestiona la autenticacion real contra /etc/shadow.
#
pam_service_name=vsftpd
VSFTPD_CONF

    chmod 600 "$FTP_CONFIG"
    aputs_success "Configuracion escrita: $FTP_CONFIG"
}

# ─── Función auxiliar: configurar SELinux ────────────────────────────────────
#
# Por defecto SELinux en Fedora Server bloquea vsftpd para acceder a /srv/ftp.
# El contexto esperado es public_content_t (lectura) o public_content_rw_t (escritura).
# También necesitamos activar el booleano SELinux ftpd_full_access si usamos
# chroot fuera de /var/ftp (que es el home default de vsftpd).
#
_configurar_selinux() {
    local pmin="$1"
    local pmax="$2"

    if ! command -v getenforce &>/dev/null; then
        aputs_info "SELinux no esta disponible en este sistema"
        return 0
    fi

    local modo_sel
    modo_sel=$(getenforce 2>/dev/null)
    aputs_info "SELinux modo: $modo_sel"

    if [[ "$modo_sel" == "Disabled" ]]; then
        aputs_info "SELinux desactivado — no se requiere configuracion adicional"
        return 0
    fi

    # Aplicar contexto correcto a /srv/ftp recursivamente
    if command -v semanage &>/dev/null; then
        # public_content_rw_t permite a vsftpd leer y escribir en el directorio
        semanage fcontext -a -t public_content_rw_t "${FTP_ROOT}(/.*)?" 2>/dev/null \
            || semanage fcontext -m -t public_content_rw_t "${FTP_ROOT}(/.*)?" 2>/dev/null \
            || true
        aputs_success "Contexto SELinux registrado: public_content_rw_t para $FTP_ROOT"
    else
        aputs_warning "semanage no disponible — instale: dnf install policycoreutils-python-utils"
    fi

    # Restaurar contextos en disco
    if command -v restorecon &>/dev/null; then
        restorecon -Rv "$FTP_ROOT" &>/dev/null
        aputs_success "Contextos SELinux aplicados en $FTP_ROOT"
    fi

    # Booleanos SELinux necesarios para vsftpd con chroot en /srv/ftp
    local booleanos=(
        "ftpd_full_access"         # acceso completo de vsftpd al sistema de archivos
        "ftpd_use_passive_mode"    # permite modo pasivo
        "allow_ftpd_full_access"   # alternativo en algunas versiones de policy
    )

    local bool
    for bool in "${booleanos[@]}"; do
        if setsebool -P "$bool" on 2>/dev/null; then
            aputs_success "Booleano SELinux activado: $bool"
        fi
        # Si el booleano no existe, setsebool falla en silencio — no es error
    done

    # Registrar puertos PASV en SELinux
    if command -v semanage &>/dev/null && [[ -n "$pmin" && -n "$pmax" ]]; then
        semanage port -a -t ftp_data_port_t -p tcp "${pmin}-${pmax}" 2>/dev/null \
            || semanage port -m -t ftp_data_port_t -p tcp "${pmin}-${pmax}" 2>/dev/null \
            || true
        aputs_success "Puertos PASV $pmin-$pmax registrados en SELinux"
    fi
}

# ─── Función auxiliar: configurar firewalld ──────────────────────────────────
#
# Abre en la zona 'internal' (Red_Sistemas 192.168.100.0/24):
#   - Servicio predefinido 'ftp' (puerto 21/tcp)
#   - Rango de puertos PASV (tcp)
# La zona 'internal' corresponde a la interfaz de Red_Sistemas del servidor.
#
_configurar_firewall() {
    local pmin="$1"
    local pmax="$2"

    if ! command -v firewall-cmd &>/dev/null; then
        aputs_warning "firewalld no disponible — configure el firewall manualmente"
        return 0
    fi

    if ! systemctl is-active --quiet firewalld 2>/dev/null; then
        aputs_warning "firewalld inactivo — no se aplica configuracion de firewall"
        return 0
    fi

    # Agregar servicio ftp a la zona internal (persistente)
    firewall-cmd --zone="$FTP_ZONE_INTERNA" --add-service=ftp --permanent 2>/dev/null \
        && aputs_success "Servicio 'ftp' (puerto 21) abierto en zona $FTP_ZONE_INTERNA" \
        || aputs_warning "No se pudo abrir el servicio ftp en $FTP_ZONE_INTERNA"

    # Agregar rango PASV (persistente)
    firewall-cmd --zone="$FTP_ZONE_INTERNA" \
        --add-port="${pmin}-${pmax}/tcp" --permanent 2>/dev/null \
        && aputs_success "Rango PASV $pmin-$pmax/tcp abierto en zona $FTP_ZONE_INTERNA" \
        || aputs_warning "No se pudo abrir el rango PASV en $FTP_ZONE_INTERNA"

    # Recargar para aplicar reglas permanentes
    firewall-cmd --reload 2>/dev/null \
        && aputs_success "Reglas de firewall recargadas" \
        || aputs_warning "No se pudo recargar firewalld"
}