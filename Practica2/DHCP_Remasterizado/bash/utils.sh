#!/bin/bash
#
#   Funciones de utilidad comunes para todos los modulos
#
# Colores base
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'




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

agets() {
    local prompt="$1"
    local var_name="$2"
    echo -ne "${CYAN}[INPUT]${NC} $prompt: "
    read -r "$var_name"
}

# Funcion para pausar y esperar Enter
pause() {
    echo ""
    read -rp "Presiona Enter para continuar..."
}

# Funcion para verificar si se ejecuta con privilegios
check_privileges() {
    if [[ $EUID -eq 0 ]]; then
        aputs_warning "Detectado ejecucion como sudo"
        return 0
    fi

    if ! sudo -n true 2>/dev/null; then
        aputs_error "Se requieren privilegios de sudo para ejecutar esta operacion"
        return 1
    fi
    return 0
}

# Funcion para verificar si un paquete esta instalado
check_package_installed() {
    local package="$1"
    if rpm -qa | grep -q "^${package}-[0-9]"; then
        return 0
    else
        return 1
    fi
}

# Funcion para verificar si un servicio esta activo
check_service_active() {
    local service="$1"
    if sudo systemctl is-active --quiet "$service" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Funcion para verificar si un servicio esta habilitado
check_service_enabled() {
    local service="$1"
    if sudo systemctl is-enabled --quiet "$service" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Funcion para validar formato de IP
validate_ip() {
    local ip="$1"
    local stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

# Funcion para obtener la IP actual de una interfaz
get_interface_ip() {
    local interface="$1"
    ip -4 addr show "$interface" 2>/dev/null | grep -oP 'inet \K[^/]+' || echo "Sin IP"
}

# Funcion para detectar interfaces de red (excluyendo loopback)
get_network_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v "lo"
}

# Funcion para dibujar linea separadora
draw_line() {
    echo "----------------------------------------"
}

# Funcion para dibujar cabecera
draw_header() {
    local title="$1"
    draw_line
    echo "  $title"
    draw_line
}

# Funcion para verificar conectividad
check_connectivity() {
    local host="${1:-8.8.8.8}"
    if ping -c 1 -W 2 "$host" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Funcion para verificar que un comando externo este disponible en el sistema
# Uso: verificar_dependencia "ipcalc" "dnf install ipcalc"
verificar_dependencia() {
    local comando="$1"
    local instruccion="$2"
    if ! command -v "$comando" &>/dev/null; then
        aputs_error "Dependencia no encontrada: $comando"
        if [ -n "$instruccion" ]; then
            aputs_info "Para instalarla ejecute: $instruccion"
        fi
        return 1
    fi
    return 0
}

# Exportar funciones para que esten disponibles en otros scripts
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
export -f validate_ip
export -f get_interface_ip
export -f get_network_interfaces
export -f draw_line
export -f draw_header
export -f check_connectivity
export -f verificar_dependencia