# Colores base
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

aputs_sysinfo() {
    echo -e "  ${CYAN}•${NC} $*"
}
#Ejemplo
aputs_sysinfo "Verificando dependencias..."
aputs_sysinfo "Verificando permisos..."
#
#
agets() {
    local prompt="$1"
    local var_name="$2"
    echo -e "${CYAN}[INPUT]${NC} $prompt: "
    read -r "$var_name"
}
#Ejemplo:
agets "Nombre del proyecto" PROJECT_NAME
#
#
aputs_confirm(){
    echo -ne "${CYAN}[?]${NC} $*"
}


# Mostrar paso numerado
aputs_step() {
    local step="$1"
    shift
    echo -e "${BOLD}${BLUE}[Step $step]${NC} $*"
}
#Ejemplo
aputs_step 1 "Configuración inicial"
#
#
#
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