#
# mainCliSSH.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/utilsCliSSH.sh"
source "$SCRIPT_DIR/validatorsCliSSH.sh"

source "$SCRIPT_DIR/1.verificar_Conectividad.sh"
source "$SCRIPT_DIR/2.Conectar.sh"
source "$SCRIPT_DIR/3.execute_remoto.sh"
source "$SCRIPT_DIR/4.execute_remoto.sh"


if ! check_ssh_tools; then
    echo ""
    echo "Instale las herramientas necesarias antes de continuar."
    exit 1
fi

configurar_servidores

menu_principal() {
    local salir=false

    while [[ "$salir" == false ]]; do
        clear
        echo ""
        echo -e "${CYAN}  ┌─────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}  │───│   Cliente SSH — Fedora Workstation  │───│${NC}"
        echo -e "${CYAN}  └─────────────────────────────────────────┘${NC}"
        echo ""
        aputs_info "Servidores disponibles:"
        echo -e "  ${GRAY}• Fedora Server   : ${SVR_LINUX_USER}@${SVR_LINUX_IP}${NC}"
        echo -e "  ${GRAY}• Windows Server  : ${SVR_WIN_USER}@${SVR_WIN_IP}${NC}"
        echo ""
        draw_line
        aputs_info "Seleccione una opcion:"
        echo ""
        aputs_info "  1) Verificar conectividad con servidores"
        aputs_info "  2) Conectar a servidor (sesion interactiva)"
        aputs_info "  3) Ejecutar script o comando remoto"
        aputs_info "  4) Reconfigurar servidores (IPs / usuarios)"
        aputs_info "  5) Salir"
        echo ""

        local op
        agets "Opcion" op

        case "$op" in
            1)
                verificar_conectividad
                pause
                ;;
            2)
                conectar_servidor
                pause
                ;;
            3)
                ejecutar_remoto
                pause
                ;;
            4)
                configurar_servidores
                ;;
            5)
                clear
                echo ""
                aputs_info "Saliendo del Cliente SSH..."
                echo ""
                salir=true
                ;;
            *)
                aputs_error "Opcion invalida. Seleccione del 1 al 4"
                sleep 2
                ;;
        esac
    done
}

menu_principal