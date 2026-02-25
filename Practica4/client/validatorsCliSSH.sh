#
# Validaciones especificas para el script cliente SSH
#

# Valida el formato de una direccion IPv4
# Uso: validar_ip "192.168.100.10"
validar_ip() {
    local ip="$1"

    if [[ -z "$ip" ]]; then
        aputs_error "La IP no puede estar vacia"
        return 1
    fi

    # Formato X.X.X.X
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        aputs_error "Formato de IP invalido: '$ip'"
        aputs_info  "Formato correcto: X.X.X.X  (ej: 10.0.0.1)"
        return 1
    fi

    # Cada octeto entre 0 y 255
    local IFS='.'
    read -ra octetos <<< "$ip"
    for oct in "${octetos[@]}"; do
        if (( oct < 0 || oct > 255 )); then
            aputs_error "Octeto fuera de rango (0-255): $oct"
            return 1
        fi
    done

    # Rechazar loopback
    if [[ "${octetos[0]}" == "127" ]]; then
        aputs_error "La IP $ip es de loopback y no es valida para SSH remoto"
        return 1
    fi

    return 0
}

# Valida que un numero de puerto sea valido (1-65535)
# Uso: validar_puerto "22"
validar_puerto() {
    local puerto="$1"

    if [[ ! "$puerto" =~ ^[0-9]+$ ]]; then
        aputs_error "El puerto debe ser un numero entero positivo"
        return 1
    fi

    if (( puerto < 1 || puerto > 65535 )); then
        aputs_error "Puerto fuera de rango. Debe estar entre 1 y 65535"
        return 1
    fi

    return 0
}

# Valida que el nombre de usuario no este vacio y no tenga espacios
# Uso: validar_usuario "adminuser"
validar_usuario() {
    local usuario="$1"

    if [[ -z "$usuario" ]]; then
        aputs_error "El nombre de usuario no puede estar vacio"
        return 1
    fi

    if [[ "$usuario" =~ [[:space:]] ]]; then
        aputs_error "El nombre de usuario no puede contener espacios"
        return 1
    fi

    return 0
}

# Valida que una ruta local exista (archivo o directorio)
# Uso: validar_ruta_local "/home/user/archivo.sh"
validar_ruta_local() {
    local ruta="$1"

    if [[ -z "$ruta" ]]; then
        aputs_error "La ruta no puede estar vacia"
        return 1
    fi

    if [[ ! -e "$ruta" ]]; then
        aputs_error "La ruta no existe: '$ruta'"
        return 1
    fi

    return 0
}

# Valida que una ruta local sea un archivo legible
# Uso: validar_archivo_local "/home/user/script.sh"
validar_archivo_local() {
    local ruta="$1"

    if ! validar_ruta_local "$ruta"; then
        return 1
    fi

    if [[ ! -f "$ruta" ]]; then
        aputs_error "La ruta existe pero no es un archivo regular: '$ruta'"
        return 1
    fi

    if [[ ! -r "$ruta" ]]; then
        aputs_error "No tienes permiso de lectura sobre: '$ruta'"
        return 1
    fi

    return 0
}

# Valida que una ruta remota no este vacia y tenga formato basico
# Uso: validar_ruta_remota "/home/adminuser/"
validar_ruta_remota() {
    local ruta="$1"

    if [[ -z "$ruta" ]]; then
        aputs_error "La ruta remota no puede estar vacia"
        aputs_info  "Ejemplos: ~/  /home/usuario/  C:/Users/Usuario/"
        return 1
    fi

    return 0
}

# Valida que el comando remoto no este vacio
# Uso: validar_comando "bash ~/main.sh"
validar_comando() {
    local cmd="$1"

    if [[ -z "$cmd" ]]; then
        aputs_error "El comando no puede estar vacio"
        return 1
    fi

    # Advertir si parece un comando potencialmente destructivo
    if echo "$cmd" | grep -qE '\brm\s+-rf\b|\bformat\b|\bmkfs\b|\bdd\s+if='; then
        aputs_warning "El comando parece destructivo. Verifique antes de continuar."
    fi

    return 0
}

# Exportar funciones
export -f validar_ip validar_puerto validar_usuario
export -f validar_ruta_local validar_archivo_local
export -f validar_ruta_remota validar_comando