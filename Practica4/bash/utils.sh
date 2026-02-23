#
# utils.sh
# 
#   COLORES
# 
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'
# 
#   SALIDA FORMATEADA
# 
# Funciones de salida formateada
aputs_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

aputs_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

aputs_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

aputs_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Entrada de dato con prompt formateado
# Uso: agets "Ingrese el usuario" mi_variable
agets() {
    local prompt="$1"
    local var_name="$2"
    echo -ne "${CYAN}[INPUT]${NC} $prompt: "
    read -r "$var_name"
}
# 
#   CONTROL DE FLUJO
# 
# Pausa hasta que el usuario presione Enter
pause() {
    echo ""
    read -rp "  Presiona Enter para continuar..."
}
# 
#   PRIVILEGIOS
# 
# Verifica que el script se ejecute con permisos sudo
# SSH necesita sudo para modificar /etc/ssh/sshd_config y manejar el servicio
check_privileges() {
    if [[ $EUID -eq 0 ]]; then
        aputs_warning "Detectado ejecucion directa como root o sudo"
        return 0
    fi

    if ! sudo -n true 2>/dev/null; then
        aputs_error "Se requieren privilegios de sudo para administrar SSH"
        aputs_info "Ejecute: sudo -v   (para activar sudo en esta sesion)"
        return 1
    fi

    return 0
}
# 
#   VERIFICACIÓN DE PAQUETES Y SERVICIOS
# 
# Verifica si un paquete RPM está instalado
# Uso: check_package_installed "openssh-server"
check_package_installed() {
    local package="$1"
    if rpm -qa | grep -q "^${package}-[0-9]"; then
        return 0
    else
        return 1
    fi
}
# Verifica si un servicio systemd está activo (corriendo ahora mismo)
check_service_active() {
    local service="$1"
    if sudo systemctl is-active --quiet "$service" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Verifica si un servicio systemd está habilitado (arranca en boot)
check_service_enabled() {
    local service="$1"
    if sudo systemctl is-enabled --quiet "$service" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}
# 
#   RED
# 
# Devuelve la IP de una interfaz de red
# Uso: get_interface_ip "eth0"
get_interface_ip() {
    local interface="$1"
    ip -4 addr show "$interface" 2>/dev/null | grep -oP 'inet \K[^/]+' || echo "Sin IP"
}

# Lista interfaces de red excluyendo loopback
get_network_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v "lo"
}

# Verifica conectividad con ping a un host
# Uso: check_connectivity "192.168.100.10"
check_connectivity() {
    local host="${1:-8.8.8.8}"
    if ping -c 1 -W 2 "$host" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Verifica si un puerto TCP está en escucha
# Uso: check_port_listening 22
check_port_listening() {
    local port="$1"
    if sudo ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        return 0
    else
        return 1
    fi
}
# 
#   USUARIOS DEL SISTEMA
# 
# Verifica si un usuario existe en el sistema
# Uso: check_user_exists "adminuser"
check_user_exists() {
    local user="$1"
    if id "$user" &>/dev/null; then
        return 0
    else
        return 1
    fi
}
# 
#   VISUAL: LÍNEAS Y CABECERAS
# 
# Línea separadora horizontal
draw_line() {
    echo "────────────────────────────────────────"
}
# Cabecera con título centrado entre separadores
# Uso: draw_header "Monitor SSH"
draw_header() {
    local title="$1"
    echo ""
    draw_line
    echo "  $title"
    draw_line
}
# 
#   EXPORTAR FUNCIONES
#   Necesario para que los módulos cargados con
#   'source' hereden estas funciones en subshells
# 
export -f aputs_info
export -f aputs_success
export -f aputs_warning
export -f aputs_error
export -f agets
export -f pause
export -f check_privileges
export -f check_package_installed
export -f check_service_active
export -f check_service_enabled
export -f get_interface_ip
export -f get_network_interfaces
export -f check_connectivity
export -f check_port_listening
export -f check_user_exists
export -f draw_line
export -f draw_header