#
# validators_ftp.sh
#
# Validaciones específicas para la configuración del servicio FTP (vsftpd)
#

# ─────────────────────────────────────────────────────────────────────────────
#   PUERTOS
# ─────────────────────────────────────────────────────────────────────────────

# Valida el puerto de comandos FTP (por defecto 21)
# FTP usa DOS canales:
#   - Canal de control (comandos): puerto 21  — aquí se autentica y negocia
#   - Canal de datos (transferencia): puerto 20 en modo activo
# Rango permitido: 1-65535  |  Advertencia si < 1024
# Uso: ftp_validar_puerto_control "21"
ftp_validar_puerto_control() {
    local puerto="$1"

    # Debe ser un entero positivo
    if [[ ! "$puerto" =~ ^[0-9]+$ ]]; then
        aputs_error "El puerto debe ser un numero entero positivo"
        aputs_info "Ejemplo: 21 (estandar FTP), 2121 (alternativo)"
        return 1
    fi

    # Rango TCP/IP válido
    if (( puerto < 1 || puerto > 65535 )); then
        aputs_error "Puerto fuera de rango. Debe estar entre 1 y 65535"
        return 1
    fi

    # Advertencia para puertos de sistema
    if (( puerto < 1024 )); then
        aputs_warning "El puerto $puerto es un puerto de sistema (requiere privilegios root)"
        aputs_info "Puerto estandar FTP: 21 — alternativo recomendado: 2121"
    fi

    # Aviso si se usa el puerto FTP estándar
    if (( puerto == 21 )); then
        aputs_info "Usando el puerto FTP estandar (21)"
    fi

    # El puerto 20 está reservado para datos en modo activo
    if (( puerto == 20 )); then
        aputs_error "El puerto 20 esta reservado para el canal de datos FTP activo"
        aputs_info "Use el puerto 21 para el canal de control"
        return 1
    fi

    return 0
}

# Valida el rango de puertos pasivos (PASV) de vsftpd
# En modo PASIVO el servidor abre un puerto efímero para el canal de datos.
# vsftpd lo limita con pasv_min_port y pasv_max_port.
# Reglas:
#   - Ambos valores deben ser enteros en 1024-65535
#   - min debe ser estrictamente menor que max
#   - Rango mínimo recomendado: 100 puertos libres
# Uso: ftp_validar_rango_pasv "50000" "51000"
ftp_validar_rango_pasv() {
    local pmin="$1"
    local pmax="$2"

    # Validar formato de ambos extremos
    if [[ ! "$pmin" =~ ^[0-9]+$ ]] || [[ ! "$pmax" =~ ^[0-9]+$ ]]; then
        aputs_error "Los puertos PASV deben ser numeros enteros positivos"
        aputs_info "Ejemplo: min=50000 max=51000"
        return 1
    fi

    # No usar puertos de sistema para PASV
    if (( pmin < 1024 )); then
        aputs_error "El puerto PASV minimo ($pmin) no puede ser menor a 1024"
        aputs_info "Use puertos en el rango 1024-65535"
        return 1
    fi

    if (( pmax > 65535 )); then
        aputs_error "El puerto PASV maximo ($pmax) supera el limite TCP (65535)"
        return 1
    fi

    # El minimo debe ser menor que el máximo
    if (( pmin >= pmax )); then
        aputs_error "El puerto minimo ($pmin) debe ser menor que el maximo ($pmax)"
        return 1
    fi

    # Rango mínimo recomendado para evitar saturación con múltiples clientes
    local rango=$(( pmax - pmin ))
    if (( rango < 100 )); then
        aputs_warning "Rango PASV muy estrecho ($rango puertos). Se recomiendan al menos 100"
        aputs_info "Con pocos puertos disponibles, clientes simultaneos pueden no conectar"
    fi

    aputs_info "Rango PASV valido: $pmin - $pmax ($rango puertos disponibles)"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#   USUARIOS Y GRUPOS
# ─────────────────────────────────────────────────────────────────────────────

# Valida el nombre de un usuario FTP (= usuario del sistema Linux)
# Reglas POSIX + restricciones vsftpd:
#   - Solo letras minúsculas, números, punto, guion y guion bajo
#   - Debe comenzar con letra minúscula o guion bajo
#   - Longitud: 1-32 caracteres
#   - No puede ser un nombre reservado del sistema
# Uso: ftp_validar_nombre_usuario "juan_perez"
ftp_validar_nombre_usuario() {
    local usuario="$1"

    # No puede estar vacío
    if [[ -z "$usuario" ]]; then
        aputs_error "El nombre de usuario no puede estar vacio"
        return 1
    fi

    # Longitud máxima Linux: 32 caracteres
    if (( ${#usuario} > 32 )); then
        aputs_error "El nombre de usuario no puede superar 32 caracteres (actual: ${#usuario})"
        return 1
    fi

    # Patrón POSIX para nombres de usuario
    if [[ ! "$usuario" =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]]; then
        aputs_error "Nombre de usuario invalido: '$usuario'"
        aputs_info "Solo se permiten: letras minusculas, numeros, punto (.), guion (-) y guion bajo (_)"
        aputs_info "No puede comenzar con numero ni con guion"
        return 1
    fi

    # Lista de nombres reservados del sistema que no deben usarse como FTP
    local reservados=(root bin daemon adm lp sync shutdown halt mail operator
        games ftp nobody systemd-network dbus polkitd sshd chrony vsftpd
        nfsnobody www-data apache nginx anonymous)

    local r
    for r in "${reservados[@]}"; do
        if [[ "$usuario" == "$r" ]]; then
            aputs_error "El nombre '$usuario' esta reservado por el sistema"
            aputs_info "Elija un nombre que no sea una cuenta del sistema"
            return 1
        fi
    done

    return 0
}

# Valida que un usuario FTP ya exista en el sistema
# Combina: formato válido + existencia real en /etc/passwd
# Uso: ftp_validar_usuario_existe "juan_perez"
ftp_validar_usuario_existe() {
    local usuario="$1"

    # Primero validamos formato
    if ! ftp_validar_nombre_usuario "$usuario"; then
        return 1
    fi

    # Luego verificamos existencia real
    if ! id "$usuario" &>/dev/null; then
        aputs_error "El usuario '$usuario' no existe en el sistema"
        aputs_info "Usuarios FTP registrados:"
        # Mostrar usuarios con UID >= 1000, excluir nobody (65534)
        awk -F: '$3 >= 1000 && $3 < 65534 {print "  - " $1}' /etc/passwd
        return 1
    fi

    return 0
}

# Valida el nombre de un grupo FTP
# Reglas:
#   - Solo letras minúsculas, números, guion y guion bajo
#   - Debe comenzar con letra minúscula o guion bajo
#   - Longitud: 1-32 caracteres
#   - No puede ser un grupo reservado del sistema
# Uso: ftp_validar_nombre_grupo "reprobados"
ftp_validar_nombre_grupo() {
    local grupo="$1"

    if [[ -z "$grupo" ]]; then
        aputs_error "El nombre del grupo no puede estar vacio"
        return 1
    fi

    if (( ${#grupo} > 32 )); then
        aputs_error "El nombre del grupo no puede superar 32 caracteres"
        return 1
    fi

    # Solo minúsculas, números, guion y guion bajo
    if [[ ! "$grupo" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        aputs_error "Nombre de grupo invalido: '$grupo'"
        aputs_info "Solo se permiten: letras minusculas, numeros, guion (-) y guion bajo (_)"
        aputs_info "No puede comenzar con numero ni con guion"
        return 1
    fi

    # Grupos reservados del sistema
    local reservados=(root bin daemon adm lp mail games users ftp nobody
        systemd-journal wheel sudo docker)

    local r
    for r in "${reservados[@]}"; do
        if [[ "$grupo" == "$r" ]]; then
            aputs_error "El nombre '$grupo' esta reservado por el sistema"
            return 1
        fi
    done

    return 0
}

# Valida que un grupo ya exista en el sistema
# Uso: ftp_validar_grupo_existe "reprobados"
ftp_validar_grupo_existe() {
    local grupo="$1"

    # Primero validamos formato
    if ! ftp_validar_nombre_grupo "$grupo"; then
        return 1
    fi

    # Verificar existencia en el sistema
    if ! getent group "$grupo" &>/dev/null; then
        aputs_error "El grupo '$grupo' no existe en el sistema"
        aputs_info "Grupos FTP disponibles:"
        # Mostrar grupos con GID >= 1000
        getent group | awk -F: '$3 >= 1000 {print "  - " $1}' | head -20
        return 1
    fi

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#   CONTRASEÑAS
# ─────────────────────────────────────────────────────────────────────────────

# Valida que una contraseña cumpla con los requisitos mínimos de seguridad FTP
# Requisitos:
#   - Mínimo 8 caracteres (FTP viaja en texto claro sin TLS = contraseña robusta)
#   - Al menos una letra mayúscula
#   - Al menos una letra minúscula
#   - Al menos un dígito
# Uso: ftp_validar_contrasena "MiPass123"
ftp_validar_contrasena() {
    local pass="$1"

    if [[ -z "$pass" ]]; then
        aputs_error "La contrasena no puede estar vacia"
        return 1
    fi

    # Longitud mínima: 8 caracteres
    # FTP sin TLS expone credenciales — una contraseña débil es un riesgo crítico
    if (( ${#pass} < 8 )); then
        aputs_error "La contrasena debe tener al menos 8 caracteres (actual: ${#pass})"
        aputs_info "FTP transmite credenciales sin cifrar — use contrasenas robustas"
        return 1
    fi

    # Debe contener al menos una mayúscula
    if [[ ! "$pass" =~ [A-Z] ]]; then
        aputs_error "La contrasena debe contener al menos una letra mayuscula"
        return 1
    fi

    # Debe contener al menos una minúscula
    if [[ ! "$pass" =~ [a-z] ]]; then
        aputs_error "La contrasena debe contener al menos una letra minuscula"
        return 1
    fi

    # Debe contener al menos un dígito
    if [[ ! "$pass" =~ [0-9] ]]; then
        aputs_error "La contrasena debe contener al menos un numero"
        return 1
    fi

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#   DIRECTORIOS Y RUTAS
# ─────────────────────────────────────────────────────────────────────────────

# Valida que una ruta de directorio sea absoluta y tenga formato correcto
# Una ruta absoluta comienza con '/' y no contiene componentes peligrosos (..)
# Uso: ftp_validar_ruta_directorio "/srv/ftp"
ftp_validar_ruta_directorio() {
    local ruta="$1"

    if [[ -z "$ruta" ]]; then
        aputs_error "La ruta no puede estar vacia"
        return 1
    fi

    # Debe ser una ruta absoluta
    if [[ "$ruta" != /* ]]; then
        aputs_error "La ruta debe ser absoluta (comenzar con /)"
        aputs_info "Ejemplo: /srv/ftp"
        return 1
    fi

    # No permitir traversal de directorios (componente ..)
    if [[ "$ruta" =~ \.\. ]]; then
        aputs_error "La ruta no puede contener '..' (traversal de directorios)"
        return 1
    fi

    # No permitir caracteres especiales peligrosos en la ruta
    if [[ "$ruta" =~ [[:space:]] ]]; then
        aputs_error "La ruta no puede contener espacios"
        aputs_info "Use guiones o guiones bajos en lugar de espacios"
        return 1
    fi

    return 0
}

# Valida que un directorio chroot exista y tenga los permisos correctos
# vsftpd exige que el directorio chroot raiz:
#   - Exista en disco
#   - Sea propiedad de root:root
#   - NO sea escribible por el usuario (chmod sin w para propietario no-root)
# Uso: ftp_validar_directorio_chroot "/srv/ftp/ftp_usuario"
ftp_validar_directorio_chroot() {
    local dir="$1"

    # Primero validar formato de ruta
    if ! ftp_validar_ruta_directorio "$dir"; then
        return 1
    fi

    # El directorio debe existir
    if [[ ! -d "$dir" ]]; then
        aputs_error "El directorio chroot no existe: $dir"
        aputs_info "Cree el directorio antes de configurarlo como chroot"
        return 1
    fi

    # Verificar propietario root:root
    local owner
    owner=$(stat -c '%U:%G' "$dir" 2>/dev/null)
    if [[ "$owner" != "root:root" ]]; then
        aputs_error "El directorio chroot debe ser propiedad de root:root (actual: $owner)"
        aputs_info "Ejecute: chown root:root '$dir'"
        return 1
    fi

    # Verificar que no sea escribible por otros (vsftpd rechaza chroot escribibles)
    local perms
    perms=$(stat -c '%a' "$dir" 2>/dev/null)
    # El bit de escritura para grupo (020) u otros (002) invalida el chroot vsftpd
    if (( (8#$perms & 8#022) != 0 )); then
        aputs_error "El directorio chroot no puede ser escribible por grupo u otros (perms: $perms)"
        aputs_info "Ejecute: chmod 755 '$dir'"
        return 1
    fi

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#   CONFIGURACIÓN VSFTPD
# ─────────────────────────────────────────────────────────────────────────────

# Valida el número máximo de clientes simultáneos en vsftpd
# Directiva: max_clients
# Rango razonable: 1-200
# Uso: ftp_validar_max_clientes "50"
ftp_validar_max_clientes() {
    local valor="$1"

    if [[ ! "$valor" =~ ^[0-9]+$ ]]; then
        aputs_error "max_clients debe ser un numero entero positivo"
        return 1
    fi

    if (( valor < 1 )); then
        aputs_error "max_clients minimo es 1"
        aputs_info "Un valor de 0 deshabilita el limite (no recomendado)"
        return 1
    fi

    if (( valor > 200 )); then
        aputs_error "max_clients maximo recomendado es 200"
        aputs_info "Un numero muy alto puede saturar CPU y memoria del servidor"
        return 1
    fi

    if (( valor > 50 )); then
        aputs_warning "Mas de 50 clientes simultaneos puede impactar el rendimiento"
        aputs_info "Ajuste segun los recursos de hardware disponibles"
    fi

    return 0
}

# Valida el máximo de conexiones por IP en vsftpd
# Directiva: max_per_ip
# Rango razonable: 1-20
# Uso: ftp_validar_max_por_ip "5"
ftp_validar_max_por_ip() {
    local valor="$1"

    if [[ ! "$valor" =~ ^[0-9]+$ ]]; then
        aputs_error "max_per_ip debe ser un numero entero positivo"
        return 1
    fi

    if (( valor < 1 )); then
        aputs_error "max_per_ip minimo es 1"
        return 1
    fi

    if (( valor > 20 )); then
        aputs_error "max_per_ip maximo recomendado es 20"
        aputs_info "Limitar por IP previene abusos desde una misma fuente"
        return 1
    fi

    # Advertencia si el valor es muy permisivo
    if (( valor > 5 )); then
        aputs_warning "Mas de 5 conexiones por IP puede facilitar abusos"
        aputs_info "Se recomienda max_per_ip <= 3 en entornos de produccion"
    fi

    return 0
}

# Valida el tiempo de inactividad de sesión (idle_session_timeout)
# Tiempo en segundos antes de desconectar un cliente inactivo
# Rango razonable: 30-900 segundos
# Uso: ftp_validar_timeout_sesion "300"
ftp_validar_timeout_sesion() {
    local valor="$1"

    if [[ ! "$valor" =~ ^[0-9]+$ ]]; then
        aputs_error "idle_session_timeout debe ser un numero entero de segundos"
        return 1
    fi

    if (( valor < 30 )); then
        aputs_error "Timeout minimo es 30 segundos"
        aputs_info "Un valor muy bajo desconecta clientes legitimos en operaciones lentas"
        return 1
    fi

    if (( valor > 900 )); then
        aputs_error "Timeout maximo recomendado es 900 segundos (15 minutos)"
        aputs_info "Sesiones inactivas largas consumen recursos innecesariamente"
        return 1
    fi

    if (( valor > 300 )); then
        aputs_warning "Se recomienda idle_session_timeout <= 300 segundos (5 minutos)"
    fi

    return 0
}

# Valida el timeout de transferencia de datos (data_connection_timeout)
# Tiempo en segundos para que una transferencia de datos comience
# Rango razonable: 30-600 segundos
# Uso: ftp_validar_timeout_datos "120"
ftp_validar_timeout_datos() {
    local valor="$1"

    if [[ ! "$valor" =~ ^[0-9]+$ ]]; then
        aputs_error "data_connection_timeout debe ser un numero entero de segundos"
        return 1
    fi

    if (( valor < 30 )); then
        aputs_error "Timeout de datos minimo es 30 segundos"
        aputs_info "Con archivos grandes o conexiones lentas, el timeout puede ser muy corto"
        return 1
    fi

    if (( valor > 600 )); then
        aputs_error "Timeout de datos maximo recomendado es 600 segundos (10 minutos)"
        return 1
    fi

    return 0
}

# Valida el número de líneas de log a mostrar en el monitor
# Rango razonable: 10-500 líneas
# Uso: ftp_validar_lineas_log "100"
ftp_validar_lineas_log() {
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
        aputs_error "Maximo recomendado: 500 lineas (valor ingresado: $lineas)"
        aputs_info "Para analisis extenso, use: sudo journalctl -u vsftpd --no-pager"
        return 1
    fi

    return 0
}

# Valida el mensaje de bienvenida FTP (ftpd_banner / banner_file)
# El banner aparece al conectar, ANTES de autenticarse
# Restricciones: no vacío, máximo 200 caracteres, sin caracteres de control
# Uso: ftp_validar_banner "Bienvenido al servidor FTP institucional"
ftp_validar_banner() {
    local texto="$1"

    if [[ -z "$texto" ]]; then
        aputs_error "El texto del banner no puede estar vacio"
        aputs_info "El banner es el mensaje que ve el cliente al conectarse al servidor FTP"
        return 1
    fi

    # Longitud máxima razonable para un banner FTP de una línea
    if (( ${#texto} > 200 )); then
        aputs_error "El banner no puede superar 200 caracteres (actual: ${#texto})"
        aputs_info "Para mensajes largos, configure banner_file en vsftpd.conf"
        return 1
    fi

    # Advertencia si el banner es muy corto
    if (( ${#texto} < 10 )); then
        aputs_warning "El banner es muy corto (${#texto} caracteres)"
        aputs_info "Un banner efectivo identifica el servidor y advierte sobre acceso no autorizado"
    fi

    # No debe contener caracteres de control (salvo texto normal)
    if [[ "$texto" =~ $'\t' ]]; then
        aputs_warning "El banner contiene tabuladores — algunos clientes pueden mostrarlo mal"
    fi

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#   EXPORTAR FUNCIONES
#   Necesario para que los módulos cargados con
#   'source' hereden estas funciones en subshells
# ─────────────────────────────────────────────────────────────────────────────

export -f ftp_validar_puerto_control
export -f ftp_validar_rango_pasv
export -f ftp_validar_nombre_usuario
export -f ftp_validar_usuario_existe
export -f ftp_validar_nombre_grupo
export -f ftp_validar_grupo_existe
export -f ftp_validar_contrasena
export -f ftp_validar_ruta_directorio
export -f ftp_validar_directorio_chroot
export -f ftp_validar_max_clientes
export -f ftp_validar_max_por_ip
export -f ftp_validar_timeout_sesion
export -f ftp_validar_timeout_datos
export -f ftp_validar_lineas_log
export -f ftp_validar_banner