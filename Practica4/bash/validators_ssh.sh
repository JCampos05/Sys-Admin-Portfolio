#
# Validaciones específicas para la configuración del servicio SSH
#
# Requiere:
#   utils.sh debe estar cargado antes (para aputs_error / aputs_info)
#

# Valida el formato de una dirección IPv4 (X.X.X.X, cada octeto 0-255)
ssh_validar_ip() {
    local ip="$1"

    # Verificar que tenga exactamente el patrón X.X.X.X
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        aputs_error "Formato de IP invalido: '$ip'"
        aputs_info "El formato correcto es X.X.X.X (ej: 192.168.100.10)"
        return 1
    fi

    # Verificar que cada octeto esté en el rango 0-255
    local octeto
    for octeto in ${ip//./ }; do
        if (( octeto < 0 || octeto > 255 )); then
            aputs_error "Octeto fuera de rango (0-255): $octeto"
            return 1
        fi
    done

    # Rechazar loopback y broadcast total
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"

    if [[ "$o1" -eq 127 ]]; then
        aputs_error "La IP $ip es de loopback y no es valida para SSH remoto"
        return 1
    fi

    if [[ "$o1" -eq 0 ]]; then
        aputs_error "La red 0.0.0.0/8 es reservada y no es valida"
        return 1
    fi

    if [[ "$o1" -eq 255 && "$o2" -eq 255 && "$o3" -eq 255 && "$o4" -eq 255 ]]; then
        aputs_error "255.255.255.255 es broadcast y no es valida para SSH"
        return 1
    fi

    return 0
}

# Valida que un número de puerto sea válido para SSH
# Rango permitido: 1-65535
# Puertos del sistema (1-1023) requieren advertencia
# Uso: ssh_validar_puerto "22"
ssh_validar_puerto() {
    local puerto="$1"

    # Debe ser un número entero positivo
    if [[ ! "$puerto" =~ ^[0-9]+$ ]]; then
        aputs_error "El puerto debe ser un numero entero positivo"
        aputs_info "Ejemplo: 22, 2222, 2200"
        return 1
    fi

    # Rango válido de puertos TCP/IP
    if (( puerto < 1 || puerto > 65535 )); then
        aputs_error "Puerto fuera de rango. Debe estar entre 1 y 65535"
        return 1
    fi

    # El puerto 0 está reservado por el sistema
    if (( puerto == 0 )); then
        aputs_error "El puerto 0 esta reservado por el sistema operativo"
        return 1
    fi

    # Advertencia para puertos conocidos (bien conocidos = 1-1023)
    if (( puerto < 1024 )); then
        aputs_warning "El puerto $puerto es un puerto de sistema (requiere privilegios root)"
        aputs_info "Se recomienda usar puertos >= 1024 para mayor seguridad"
    fi

    # Advertencia específica si se usa el puerto SSH estándar
    if (( puerto == 22 )); then
        aputs_info "Usando el puerto SSH estandar (22)"
    fi

    return 0
}

# Valida MaxAuthTries: número de intentos de autenticación permitidos
# Rango razonable: 1 a 10
# Uso: ssh_validar_max_auth_tries "3"
ssh_validar_max_auth_tries() {
    local valor="$1"

    if [[ ! "$valor" =~ ^[0-9]+$ ]]; then
        aputs_error "MaxAuthTries debe ser un numero entero positivo"
        return 1
    fi

    if (( valor < 1 )); then
        aputs_error "MaxAuthTries minimo es 1"
        aputs_info "Un valor de 0 bloquea todos los intentos de login"
        return 1
    fi

    if (( valor > 10 )); then
        aputs_error "MaxAuthTries maximo recomendado es 10"
        aputs_info "Un valor muy alto facilita ataques de fuerza bruta"
        return 1
    fi

    # Aviso si el valor es mayor que 3 (buena práctica es 3 o menos)
    if (( valor > 3 )); then
        aputs_warning "Se recomienda MaxAuthTries <= 3 para mayor seguridad"
    fi

    return 0
}

# Valida LoginGraceTime: segundos que tiene el cliente para autenticarse
# Rango razonable: 10 a 300 segundos
# Uso: ssh_validar_login_grace_time "30"
ssh_validar_login_grace_time() {
    local valor="$1"

    if [[ ! "$valor" =~ ^[0-9]+$ ]]; then
        aputs_error "LoginGraceTime debe ser un numero entero de segundos"
        return 1
    fi

    if (( valor < 10 )); then
        aputs_error "LoginGraceTime minimo es 10 segundos"
        aputs_info "Un valor muy bajo puede cortar conexiones legitimas lentas"
        return 1
    fi

    if (( valor > 300 )); then
        aputs_error "LoginGraceTime maximo recomendado es 300 segundos (5 minutos)"
        aputs_info "Un tiempo muy largo deja conexiones colgadas sin autenticar"
        return 1
    fi

    # Informar del valor estándar recomendado
    if (( valor > 60 )); then
        aputs_warning "Se recomienda LoginGraceTime <= 60 segundos para mejor seguridad"
    fi

    return 0
}

# Valida MaxSessions: número máximo de sesiones SSH simultáneas por conexión
# Rango razonable: 1 a 20
# Uso: ssh_validar_max_sessions "10"
ssh_validar_max_sessions() {
    local valor="$1"

    if [[ ! "$valor" =~ ^[0-9]+$ ]]; then
        aputs_error "MaxSessions debe ser un numero entero positivo"
        return 1
    fi

    if (( valor < 1 )); then
        aputs_error "MaxSessions minimo es 1"
        return 1
    fi

    if (( valor > 20 )); then
        aputs_error "MaxSessions maximo recomendado es 20"
        aputs_info "Un numero muy alto puede saturar el servidor"
        return 1
    fi

    return 0
}

# Valida que un nombre de usuario del sistema sea válido
# Reglas: solo letras minúsculas, números, guiones y guión bajo
#         no puede comenzar con número ni guión
# Uso: ssh_validar_nombre_usuario "adminuser"
ssh_validar_nombre_usuario() {
    local usuario="$1"

    if [[ -z "$usuario" ]]; then
        aputs_error "El nombre de usuario no puede estar vacio"
        return 1
    fi

    # Longitud máxima en Linux para usernames es 32 caracteres
    if (( ${#usuario} > 32 )); then
        aputs_error "El nombre de usuario no puede superar 32 caracteres"
        return 1
    fi

    # Solo letras minúsculas, números, guiones y guión bajo
    if [[ ! "$usuario" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        aputs_error "Nombre de usuario invalido: '$usuario'"
        aputs_info "Solo se permiten: letras minusculas, numeros, guion (-) y guion bajo (_)"
        aputs_info "No puede comenzar con numero ni con guion"
        return 1
    fi

    return 0
}

# Valida que un usuario exista realmente en el sistema
# Combina: formato válido + existencia real
# Uso: ssh_validar_usuario_existe "adminuser"
ssh_validar_usuario_existe() {
    local usuario="$1"

    # Primero validamos el formato
    if ! ssh_validar_nombre_usuario "$usuario"; then
        return 1
    fi

    # Luego verificamos que exista en /etc/passwd
    if ! id "$usuario" &>/dev/null; then
        aputs_error "El usuario '$usuario' no existe en el sistema"
        aputs_info "Usuarios disponibles (no sistema):"
        # Listar usuarios con UID >= 1000 (usuarios reales, no del sistema)
        awk -F: '$3 >= 1000 && $3 < 65534 {print "  - " $1}' /etc/passwd
        return 1
    fi

    return 0
}

# Valida el tipo de clave criptográfica para ssh-keygen
# Tipos aceptados: rsa, ed25519, ecdsa
# Uso: ssh_validar_tipo_clave "ed25519"
ssh_validar_tipo_clave() {
    local tipo="$1"

    if [[ -z "$tipo" ]]; then
        aputs_error "Debe especificar un tipo de clave"
        aputs_info "Tipos disponibles: rsa, ed25519, ecdsa"
        return 1
    fi

    # Convertir a minúsculas para comparación
    local tipo_lower="${tipo,,}"

    case "$tipo_lower" in
        rsa|ed25519|ecdsa)
            # Tipo válido, continuar
            ;;
        dsa)
            # DSA está deprecado desde OpenSSH 7.0
            aputs_error "El tipo DSA esta deprecado y no es seguro"
            aputs_info "Use: rsa (2048+ bits), ed25519 (recomendado) o ecdsa"
            return 1
            ;;
        *)
            aputs_error "Tipo de clave no valido: '$tipo'"
            aputs_info "Tipos aceptados: rsa, ed25519, ecdsa"
            aputs_info "  - ed25519:  Mas moderno y seguro (recomendado)"
            aputs_info "  - rsa:      Compatible con sistemas mas antiguos (minimo 2048 bits)"
            aputs_info "  - ecdsa:    Curva eliptica, buen balance seguridad/velocidad"
            return 1
            ;;
    esac

    return 0
}

# Valida el número de bits para clave RSA
# Valores aceptados: 2048, 3072, 4096
# Solo aplica para RSA (ed25519 y ecdsa no usan bits configurables)
# Uso: ssh_validar_bits_rsa "4096"
ssh_validar_bits_rsa() {
    local bits="$1"

    if [[ ! "$bits" =~ ^[0-9]+$ ]]; then
        aputs_error "El numero de bits debe ser un entero positivo"
        return 1
    fi

    case "$bits" in
        2048)
            aputs_info "2048 bits: Aceptable, minimo recomendado actualmente"
            ;;
        3072)
            aputs_info "3072 bits: Buena seguridad (recomendado)"
            ;;
        4096)
            aputs_info "4096 bits: Maxima seguridad (ligeramente mas lento)"
            ;;
        1024|512)
            aputs_error "Los bits $bits son inseguros para RSA"
            aputs_info "El minimo aceptable es 2048 bits"
            return 1
            ;;
        *)
            aputs_error "Numero de bits no estandar: $bits"
            aputs_info "Valores aceptados para RSA: 2048, 3072, 4096"
            return 1
            ;;
    esac

    return 0
}

# Valida el texto de un banner SSH
# El banner aparece ANTES del login, como aviso legal
# Restricciones: no vacío, máximo 500 caracteres
# Uso: ssh_validar_banner "Texto del aviso legal"
ssh_validar_banner() {
    local texto="$1"

    if [[ -z "$texto" ]]; then
        aputs_error "El texto del banner no puede estar vacio"
        aputs_info "El banner es el aviso legal que ve el usuario antes de autenticarse"
        return 1
    fi

    # Longitud máxima razonable para un banner
    if (( ${#texto} > 500 )); then
        aputs_error "El banner no puede superar 500 caracteres (actual: ${#texto})"
        return 1
    fi

    # Longitud mínima: debe ser un mensaje significativo
    if (( ${#texto} < 10 )); then
        aputs_warning "El banner es muy corto (${#texto} caracteres)"
        aputs_info "Un banner efectivo suele incluir: aviso de acceso restringido y consecuencias"
    fi

    return 0
}

# Valida el número de líneas de log a mostrar
# Rango razonable: 10 a 500 líneas
# Uso: ssh_validar_lineas_log "50"
ssh_validar_lineas_log() {
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
        aputs_info "Para analisis extenso, use: sudo journalctl -u sshd --no-pager"
        return 1
    fi

    return 0
}

export -f ssh_validar_ip
export -f ssh_validar_puerto
export -f ssh_validar_max_auth_tries
export -f ssh_validar_login_grace_time
export -f ssh_validar_max_sessions
export -f ssh_validar_nombre_usuario
export -f ssh_validar_usuario_existe
export -f ssh_validar_tipo_clave
export -f ssh_validar_bits_rsa
export -f ssh_validar_banner
export -f ssh_validar_lineas_log