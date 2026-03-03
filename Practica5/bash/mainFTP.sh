#
#
# Script principal — Gestor del Servicio FTP (vsftpd) en Fedora Server
# Punto único de entrada. Carga módulos con 'source' y llama a sus funciones.
#
# Arquitectura:
#
# Estructura de directorios en disco:
#   /srv/ftp/
#   ├── general/              — compartido por todos (root:ftp 775+sticky)
#   ├── reprobados/           — exclusivo del grupo (root:reprobados 2770+sticky)
#   ├── recursadores/         — exclusivo del grupo (root:recursadores 2770+sticky)
#   └── ftp_<usuario>/        — chroot raiz de cada usuario (root:root 755)
#       ├── <usuario>/        — carpeta privada del usuario (usuario:grupo 700)
#       ├── general/          — bind mount -> /srv/ftp/general
#       └── <grupo>/          — bind mount -> /srv/ftp/<grupo>
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Carga de bibliotecas ────────────────────────────────────────────────────
# Esto hace que todas las funciones y variables de cada archivo
# queden disponibles en este script sin necesidad de exportarlas
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/validatorsFTP.sh"

# Módulos funcionales — cada uno define una o más funciones
source "${SCRIPT_DIR}/1.verificarFTP.sh"
source "${SCRIPT_DIR}/2.instalar_configurar.sh"
source "${SCRIPT_DIR}/3.usuarios_grupos.sh"
source "${SCRIPT_DIR}/4.directorios.sh"
source "${SCRIPT_DIR}/5.monitorFTP.sh"

# ─── Menú principal ──────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        echo ""
        aputs_info "┌──────────────────────────────────────┐"
        aputs_info "|---|   Gestor del Servicio FTP     |---|"
        aputs_info "└──────────────────────────────────────┘"
        echo ""
        aputs_info "Seleccione una opcion:"
        echo ""
        aputs_info "  1) Verificar instalacion FTP"
        aputs_info "  2) Instalar y configurar FTP"
        aputs_info "  3) Gestion de usuarios y grupos"
        aputs_info "  4) Estructura de directorios"
        aputs_info "  5) Monitor FTP"
        aputs_info "  6) Salir"
        echo ""

        local op
        read -rp "  Opcion: " op

        case "$op" in
            1)
                verificar_ftp
                ;;
            2)
                instalar_configurar_ftp
                ;;
            3)
                gestionar_usuarios_grupos
                continue
                ;;
            4)
                gestionar_directorios
                continue
                ;;
            5)
                monitor_ftp
                ;;
            6)
                clear
                echo ""
                aputs_info "Saliendo del Gestor FTP..."
                echo ""
                exit 0
                ;;
            *)
                aputs_error "Opcion invalida. Seleccione una opcion del 1 al 6"
                sleep 2
                continue
                ;;
        esac
        echo ""
        pause
    done
}

# ─── Punto de entrada ────────────────────────────────────────────────────────
if ! check_privileges; then
    echo ""
    aputs_error "Este script requiere permisos de root."
    aputs_info  "Ejecute: sudo bash mainFTP.sh"
    echo ""
    exit 1
fi

main_menu