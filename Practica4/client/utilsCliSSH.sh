#
# Funciones de utilidad comunes para el cliente SSH
#
# Uso: source utilsCliSSH.sh
#

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m'

aputs_info() {
    echo -e "${CYAN}[INFO]  ${NC}$1"
}

aputs_success() {
    echo -e "${GREEN}[SUCCESS]    ${NC}$1"
}

aputs_warning() {
    echo -e "${YELLOW}[WARN]  ${NC}$1"
}

aputs_error() {
    echo -e "${RED}[ERROR] ${NC}$1"
}

# Solicitar input con prompt formateado
# Uso: agets "Descripcion del campo" variable
agets() {
    local prompt="$1"
    local varname="$2"
    echo -ne "${CYAN}[INPUT] ${NC}${prompt}: "
    read -r "$varname"
}


draw_line() {
    echo -e "${GRAY}────────────────────────────────────────${NC}"
}

draw_header() {
    local titulo="$1"
    echo ""
    draw_line
    echo -e "  ${titulo}"
    draw_line
}

pause() {
    echo ""
    read -rp "  Presiona Enter para continuar..."
}

#
#   Checar privilegios
#
check_ssh_tools() {
    local falta=0

    if ! command -v ssh &>/dev/null; then
        aputs_error "ssh no esta instalado"
        aputs_info  "Instala con: sudo dnf install -y openssh-clients"
        falta=1
    fi

    if ! command -v scp &>/dev/null; then
        aputs_error "scp no esta instalado"
        aputs_info  "Instala con: sudo dnf install -y openssh-clients"
        falta=1
    fi

    if ! command -v ssh-keygen &>/dev/null; then
        aputs_warning "ssh-keygen no encontrado (necesario para generar claves)"
    fi

    return $falta
}

# Verifica conectividad basica con ping
# Uso: check_conectividad "192.168.100.10"
check_conectividad() {
    local host="$1"
    ping -c 1 -W 2 "$host" &>/dev/null
    return $?
}

# Verifica que el puerto SSH este abierto en el destino
# Uso: check_puerto_ssh "192.168.100.10" 22
check_puerto_ssh() {
    local host="$1"
    local puerto="${2:-22}"
    # timeout 3: no esperar mas de 3 segundos
    # /dev/null: descartar la conexion sin hacer nada
    timeout 3 bash -c "echo >/dev/tcp/${host}/${puerto}" 2>/dev/null
    return $?
}

#
#   Servicores — Configuracion en sesion
#

# Variables globales de sesion 
SVR_LINUX_IP=""
SVR_LINUX_USER=""
SVR_LINUX_PUERTO=""
SVR_LINUX_NOMBRE="Fedora Server"

SVR_WIN_IP=""
SVR_WIN_USER=""
SVR_WIN_PUERTO=""
SVR_WIN_NOMBRE="Windows Server"

# Solicita al usuario los datos de conexion de ambos servidores.
# Uso: configurar_servidores
configurar_servidores() {
    clear
    draw_header "Configuracion de Servidores SSH"
    aputs_info "Ingrese los datos de conexion para cada servidor."
    aputs_info "Estos datos se usaran durante toda la sesion."
    echo ""

    # ─── Fedora Server ───────────────────────────────────────────
    aputs_info "--- ${SVR_LINUX_NOMBRE} ---"
    echo ""

    while true; do
        agets "IP del ${SVR_LINUX_NOMBRE}" SVR_LINUX_IP
        if validar_ip "$SVR_LINUX_IP"; then break; fi
        echo ""
    done

    while true; do
        agets "Usuario SSH del ${SVR_LINUX_NOMBRE}" SVR_LINUX_USER
        if validar_usuario "$SVR_LINUX_USER"; then break; fi
        echo ""
    done

    while true; do
        # Mostrar 22 como sugerencia pero no imponerlo
        echo -ne "${CYAN}[INPUT] ${NC}Puerto SSH del ${SVR_LINUX_NOMBRE} [default: 22]: "
        read -r SVR_LINUX_PUERTO
        # Si el usuario presiona Enter sin escribir nada, usar 22
        SVR_LINUX_PUERTO="${SVR_LINUX_PUERTO:-22}"
        if validar_puerto "$SVR_LINUX_PUERTO"; then break; fi
        echo ""
    done

    echo ""
    draw_line

    # ─── Windows Server ──────────────────────────────────────────
    aputs_info "--- ${SVR_WIN_NOMBRE} ---"
    echo ""

    while true; do
        agets "IP del ${SVR_WIN_NOMBRE}" SVR_WIN_IP
        if validar_ip "$SVR_WIN_IP"; then break; fi
        echo ""
    done

    while true; do
        agets "Usuario SSH del ${SVR_WIN_NOMBRE}" SVR_WIN_USER
        if validar_usuario "$SVR_WIN_USER"; then break; fi
        echo ""
    done

    while true; do
        echo -ne "${CYAN}[INPUT] ${NC}Puerto SSH del ${SVR_WIN_NOMBRE} [default: 22]: "
        read -r SVR_WIN_PUERTO
        SVR_WIN_PUERTO="${SVR_WIN_PUERTO:-22}"
        if validar_puerto "$SVR_WIN_PUERTO"; then break; fi
        echo ""
    done

    echo ""
    draw_line

    # ─── Resumen de configuracion ────────────────────────────────
    aputs_info "Resumen de configuracion:"
    echo ""
    echo "  ${SVR_LINUX_NOMBRE}  : ${SVR_LINUX_USER}@${SVR_LINUX_IP}:${SVR_LINUX_PUERTO}"
    echo "  ${SVR_WIN_NOMBRE}    : ${SVR_WIN_USER}@${SVR_WIN_IP}:${SVR_WIN_PUERTO}"
    echo ""

    # Exportar para que todos los modulos cargados con source los vean
    export SVR_LINUX_IP SVR_LINUX_USER SVR_LINUX_PUERTO SVR_LINUX_NOMBRE
    export SVR_WIN_IP SVR_WIN_USER SVR_WIN_PUERTO SVR_WIN_NOMBRE

    aputs_success "Configuracion guardada para esta sesion"
    pause
}

# Devuelve los datos del servidor segun la eleccion (1=Linux, 2=Windows)
# Uso: get_servidor 1 -> establece SVR_IP, SVR_USER, SVR_PUERTO, SVR_NOMBRE
get_servidor() {
    local eleccion="$1"
    case "$eleccion" in
        1)
            SVR_IP="$SVR_LINUX_IP"
            SVR_USER="$SVR_LINUX_USER"
            SVR_PUERTO="$SVR_LINUX_PUERTO"
            SVR_NOMBRE="$SVR_LINUX_NOMBRE"
            ;;
        2)
            SVR_IP="$SVR_WIN_IP"
            SVR_USER="$SVR_WIN_USER"
            SVR_PUERTO="$SVR_WIN_PUERTO"
            SVR_NOMBRE="$SVR_WIN_NOMBRE"
            ;;
        *)
            aputs_error "Servidor no reconocido: $eleccion"
            return 1
            ;;
    esac
    return 0
}

# Muestra el menu de seleccion de servidor y establece las variables de conexion
# Uso: elegir_servidor -> establece SVR_IP, SVR_USER, SVR_PUERTO, SVR_NOMBRE
elegir_servidor() {
    echo ""
    aputs_info "Seleccione el servidor destino:"
    echo ""
    echo "  1) ${SVR_LINUX_NOMBRE}  (${SVR_LINUX_USER}@${SVR_LINUX_IP}:${SVR_LINUX_PUERTO})"
    echo "  2) ${SVR_WIN_NOMBRE}    (${SVR_WIN_USER}@${SVR_WIN_IP}:${SVR_WIN_PUERTO})"
    echo ""

    local eleccion
    agets "Servidor [1/2]" eleccion

    if ! get_servidor "$eleccion"; then
        return 1
    fi

    aputs_info "Servidor seleccionado: ${SVR_NOMBRE} (${SVR_USER}@${SVR_IP}:${SVR_PUERTO})"
    return 0
}

# Exportar todas las funciones para subshells
export -f aputs_info aputs_success aputs_warning aputs_error agets
export -f draw_line draw_header pause
export -f check_ssh_tools check_conectividad check_puerto_ssh
export -f configurar_servidores get_servidor elegir_servidor
export SVR_LINUX_IP SVR_LINUX_USER SVR_LINUX_PUERTO SVR_LINUX_NOMBRE
export SVR_WIN_IP SVR_WIN_USER SVR_WIN_PUERTO SVR_WIN_NOMBRE