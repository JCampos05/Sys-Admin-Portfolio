#
# Script principal — Gestor del Servicio SSH en Fedora Server
# Punto único de entrada. Carga módulos con 'source' y llama a sus funciones.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Carga de bibliotecas ───────────────────────────────────────────
# Esto hace que todas las funciones y variables de cada archivo
# queden disponibles en este script sin necesidad de exportarlas
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/validators_ssh.sh"

# Módulos funcionales — cada uno define una o más funciones
source "${SCRIPT_DIR}/1.verificar_ssh.sh"
source "${SCRIPT_DIR}/2.instalar_configurar.sh"
source "${SCRIPT_DIR}/3.hardening.sh"
source "${SCRIPT_DIR}/4.claves.sh"
source "${SCRIPT_DIR}/5.monitor_ssh.sh"
source "${SCRIPT_DIR}/6.firewall.sh"

# ─── Menú principal ───────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        echo ""
        aputs_info "┌──────────────────────────────────────┐"
        aputs_info "|---|   Gestor del Servicio SSH    |---|"
        aputs_info "└──────────────────────────────────────┘"
        echo ""
        aputs_info "Seleccione una opcion:"
        echo ""
        aputs_info "  1) Verificar instalacion SSH"
        aputs_info "  2) Instalar y configurar SSH"
        aputs_info "  3) Hardening (seguridad)"
        aputs_info "  4) Gestion de claves"
        aputs_info "  5) Monitor SSH"
        aputs_info "  6) Firewall"
        aputs_info "  7) Salir"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1)
                verificar_ssh
                ;;
            2)
                instalar_configurar_ssh
                ;;
            3)
                hardening_ssh
                ;;
            4)
                gestionar_claves_ssh
                continue
                ;;
            5)
                monitor_ssh
                ;;
            6)
                gestionar_firewall_ssh
                continue
                ;;
            7)
                clear
                echo ""
                aputs_info "Saliendo del Gestor SSH..."
                echo ""
                exit 0
                ;;
            *)
                aputs_error "Opcion invalida. Seleccione una opcion del 1 al 7"
                sleep 2
                continue
                ;;
        esac
        echo ""
        pause
    done
}

# ─── Punto de entrada ─────────────────────────────────────────────────────────
# Verificamos privilegios una sola vez al arrancar
if ! check_privileges; then
    echo ""
    aputs_error "Este script requiere permisos de sudo."
    aputs_info  "Ejecute: sudo -v  y luego vuelva a correr el script."
    echo ""
    exit 1
fi

main_menu