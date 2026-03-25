#
# main.sh
# Tarea 08 - Union de Cliente Linux a Active Directory
#
# Uso:
#   sudo bash main.sh
#   o
#   chmod +x main.sh && sudo ./main.sh
#

# Obtener el directorio donde esta este script para cargar modulos
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cargar modulos en orden de dependencia
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/utilsAD.sh"
source "$SCRIPT_DIR/validatorsAD.sh"
source "$SCRIPT_DIR/Functions-AD-A.sh"

show_banner() {
    clear
    draw_line
    echo "  Tarea 08: Union de Cliente Linux a Active Directory"
    echo "  Administracion de Sistemas - Fedora 43 Workstation"
    draw_line
    echo "  Equipo:   $(hostname)"
    echo "  Usuario:  $(whoami)"
    echo "  Fecha:    $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Dominio:  $DC_DOMAIN"
    echo "  DC:       $DC_IP"
    draw_line
    echo ""
}

# -------------------------------------------------------------------------
# show_final_summary
# Muestra el resumen del estado final de la integracion con AD.
# -------------------------------------------------------------------------
show_final_summary() {
    draw_header "Resumen Final - Cliente Linux unido a AD"

    echo ""
    aputs_success "Dominio: $DC_DOMAIN"
    aputs_success "Paquetes: realmd, sssd, adcli instalados"
    aputs_success "Union al dominio completada"
    aputs_success "sssd.conf configurado con fallback_homedir=/home/%u@%d"
    aputs_success "Creacion automatica de homedir habilitada (mkhomedir)"
    aputs_success "Permisos sudo configurados para administradores de AD"

    draw_line
    aputs_info "Verificaciones post-instalacion:"
    aputs_info "  Resolver usuario AD:     id user01@$DC_DOMAIN"
    aputs_info "  Listar usuarios AD:      getent passwd | grep $DC_DOMAIN"
    aputs_info "  Ver estado del dominio:  realm list"
    aputs_info "  Ver logs de sssd:        sudo journalctl -u sssd -f"
    draw_line
    aputs_info "Para iniciar sesion con un usuario de AD:"
    aputs_info "  ssh user01@${DC_DOMAIN}@$(get_interface_ip $INTERNAL_IFACE)"
    aputs_info "  o desde la pantalla de login del sistema"
    draw_line
}

# 
# PUNTO DE ENTRADA PRINCIPAL
# 

show_banner

# Verificar que se ejecuta con privilegios
if ! check_privileges; then
    aputs_error "Ejecute este script con sudo:"
    aputs_info  "  sudo bash main.sh"
    exit 1
fi

# Ejecutar validaciones de prerequisitos
if ! invoke_all_validations; then
    aputs_error "Las validaciones fallaron. Corrija los errores y vuelva a ejecutar."
    write_ad_log "Ejecucion abortada por validaciones fallidas" "ERROR"
    exit 1
fi

echo ""
aputs_success "Validaciones completadas. Iniciando union al dominio..."
pause

# Ejecutar la fase principal de union al dominio
if ! invoke_phase_a; then
    aputs_error "La union al dominio fallo. Revise /var/log/tarea08-ad.log"
    aputs_info  "Puede volver a ejecutar el script. Es idempotente."
    exit 1
fi

# Mostrar resumen final
show_final_summary

aputs_success "Script completado exitosamente."
aputs_info    "Log completo: /var/log/tarea08-ad.log"
pause

exit 0