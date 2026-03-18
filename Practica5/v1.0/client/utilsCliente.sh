#
# utils_cliente.sh
#
# Funciones de utilidad compartidas para el gestor del cliente FTP.
# Es una versión reducida de utils.sh del servidor, adaptada al cliente.
#
# Diferencias respecto al utils.sh del servidor:
#   - check_privileges: NO requiere root (el cliente no necesita privilegios)
#   - Se agrega check_ip_valida para validar IPs ingresadas por el usuario
#

# ─── Colores ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ─── Salida formateada ────────────────────────────────────────────────────────
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
# Uso: agets "Ingrese la IP" mi_variable
agets() {
    local prompt="$1"
    local var_name="$2"
    echo -ne "${CYAN}[INPUT]${NC} $prompt: "
    read -r "$var_name"
}

# ─── Control de flujo ─────────────────────────────────────────────────────────
pause() {
    echo ""
    read -rp "  Presiona Enter para continuar..."
}

# ─── Visual ───────────────────────────────────────────────────────────────────
draw_line() {
    echo "────────────────────────────────────────"
}

draw_header() {
    local title="$1"
    echo ""
    draw_line
    echo "  $title"
    draw_line
}

# ─── Red ─────────────────────────────────────────────────────────────────────

# Valida formato IPv4 (no verifica conectividad, solo formato)
# Uso: check_ip_valida "192.168.100.10"
check_ip_valida() {
    local ip="$1"
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

    if [[ ! "$ip" =~ $regex ]]; then
        return 1
    fi

    # Verificar que cada octeto esté en 0-255
    local IFS='.'
    local -a octetos
    read -ra octetos <<< "$ip"
    local o
    for o in "${octetos[@]}"; do
        if (( o < 0 || o > 255 )); then
            return 1
        fi
    done
    return 0
}

# Verifica conectividad básica (ping) a una IP
# Uso: check_ping "192.168.100.10"
check_ping() {
    local host="$1"
    ping -c 1 -W 2 "$host" &>/dev/null
}

# Verifica si el puerto 21 de un host responde (TCP connect)
# Uso: check_puerto_ftp "192.168.100.10"
check_puerto_ftp() {
    local host="$1"
    # timeout 3: si en 3 segundos no conecta, falla
    timeout 3 bash -c "echo > /dev/tcp/${host}/21" 2>/dev/null
}

# Verifica si lftp está instalado
check_lftp_instalado() {
    command -v lftp &>/dev/null
}

# ─── Exportar funciones ───────────────────────────────────────────────────────
export -f aputs_info
export -f aputs_success
export -f aputs_warning
export -f aputs_error
export -f agets
export -f pause
export -f draw_line
export -f draw_header
export -f check_ip_valida
export -f check_ping
export -f check_puerto_ftp
export -f check_lftp_instalado