#!/bin/bash
################################################################################
# crud_eliminar.sh
# Submódulo para eliminar dominios y registros DNS
################################################################################

# Cargar utilidades
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Función para eliminar dominio de named.conf
eliminar_zona_de_named_conf() {
    local dominio="$1"
    
    # Crear backup
    sudo cp /etc/named.conf "/etc/named.conf.backup_$(date +%Y%m%d_%H%M%S)"
    
    # Eliminar entrada de zona (zona y sus 4 líneas)
    sudo sed -i "/^\/\/ Zona: ${dominio}/,/^};/d" /etc/named.conf
    sudo sed -i "/^\/\/ Zona inversa: ${dominio}/,/^};/d" /etc/named.conf
    
    return 0
}

# Función para eliminar registro específico
eliminar_registro_especifico() {
    clear
    draw_header "ELIMINAR REGISTRO ESPECIFICO"
    
    # Listar dominios
    aputs_info "Dominios disponibles:"
    echo ""
    
    local dominios=()
    while IFS= read -r zona_file; do
        local dominio=$(basename "$zona_file" .zone)
        dominios+=("$dominio")
        echo "  - $dominio"
    done < <(sudo find /var/named -maxdepth 1 -name "*.zone" -type f 2>/dev/null | sort)
    
    if [[ ${#dominios[@]} -eq 0 ]]; then
        echo ""
        aputs_warning "No hay dominios configurados"
        return
    fi
    
    echo ""
    
    local dominio
    read -rp "Dominio: " dominio
    
    if [[ -z "$dominio" ]]; then
        aputs_error "Debe especificar un dominio"
        return 1
    fi
    
    local zona_file="/var/named/${dominio}.zone"
    
    if [[ ! -f "$zona_file" ]]; then
        aputs_error "El dominio '$dominio' no existe"
        return 1
    fi
    
    echo ""
    aputs_info "Registros del dominio $dominio:"
    echo ""
    
    # Mostrar registros (excluyendo SOA y comentarios)
    sudo grep "IN.*[A-Z]" "$zona_file" | grep -v "SOA" | grep -v "^;" | nl
    
    echo ""
    
    local nombre_registro
    read -rp "Nombre del registro a eliminar: " nombre_registro
    
    if [[ -z "$nombre_registro" ]]; then
        aputs_error "Debe especificar un registro"
        return 1
    fi
    
    echo ""
    aputs_warning "¿Esta seguro de eliminar el registro '$nombre_registro'?"
    local confirmar
    read -rp "Escriba 'CONFIRMAR' para proceder: " confirmar
    
    if [[ "$confirmar" != "CONFIRMAR" ]]; then
        aputs_info "Eliminacion cancelada"
        return 0
    fi
    
    echo ""
    
    # Crear backup
    sudo cp "$zona_file" "${zona_file}.backup_$(date +%Y%m%d_%H%M%S)"
    
    # Eliminar registro
    sudo sed -i "/^${nombre_registro}[[:space:]]/d" "$zona_file"
    
    # Incrementar serial
    local serial_actual=$(sudo grep -m1 "Serial" "$zona_file" | grep -oP '\d{10}')
    local fecha_hoy=$(date +%Y%m%d)
    local serial_nuevo="${fecha_hoy}01"
    sudo sed -i "s/${serial_actual}/${serial_nuevo}/g" "$zona_file"
    
    # Validar zona
    if sudo named-checkzone "$dominio" "$zona_file" &>/dev/null; then
        aputs_success "Registro eliminado correctamente"
        
        # Preguntar si reiniciar
        echo ""
        local reiniciar
        read -rp "¿Reiniciar servicio named? (s/n): " reiniciar
        
        if [[ "$reiniciar" == "s" || "$reiniciar" == "S" ]]; then
            if sudo systemctl restart named; then
                aputs_success "Servicio reiniciado"
            else
                aputs_error "Error al reiniciar servicio"
            fi
        fi
    else
        aputs_error "Error de sintaxis en la zona"
        sudo named-checkzone "$dominio" "$zona_file" 2>&1 | sed 's/^/  /'
        
        # Restaurar backup
        aputs_warning "Restaurando backup..."
        sudo cp "${zona_file}.backup_$(date +%Y%m%d)*" "$zona_file" 2>/dev/null
        return 1
    fi
}

# Función para eliminar dominio completo
eliminar_dominio_completo() {
    clear
    draw_header "ELIMINAR DOMINIO COMPLETO"
    
    aputs_warning "ADVERTENCIA: Esta accion eliminara el dominio y TODOS sus registros"
    echo ""
    
    # Listar dominios
    aputs_info "Dominios disponibles:"
    echo ""
    
    local dominios=()
    while IFS= read -r zona_file; do
        local dominio=$(basename "$zona_file" .zone)
        dominios+=("$dominio")
        echo "  - $dominio"
    done < <(sudo find /var/named -maxdepth 1 -name "*.zone" -type f 2>/dev/null | sort)
    
    if [[ ${#dominios[@]} -eq 0 ]]; then
        echo ""
        aputs_warning "No hay dominios configurados"
        return
    fi
    
    echo ""
    
    local dominio_eliminar
    read -rp "Nombre del dominio a eliminar: " dominio_eliminar
    
    if [[ -z "$dominio_eliminar" ]]; then
        aputs_error "Debe especificar un dominio"
        return 1
    fi
    
    local zona_file="/var/named/${dominio_eliminar}.zone"
    
    if [[ ! -f "$zona_file" ]]; then
        aputs_error "El dominio '$dominio_eliminar' no existe"
        return 1
    fi
    
    echo ""
    
    # Preguntar por zona inversa
    local eliminar_zona_inversa
    read -rp "¿Eliminar tambien zona inversa? (s/n) [s]: " eliminar_zona_inversa
    eliminar_zona_inversa=${eliminar_zona_inversa:-s}
    
    # Preguntar por backup
    local hacer_backup
    read -rp "¿Hacer backup antes de eliminar? (s/n) [s]: " hacer_backup
    hacer_backup=${hacer_backup:-s}
    
    echo ""
    aputs_warning "¿Esta seguro de eliminar el dominio '$dominio_eliminar' y TODOS sus registros?"
    local confirmar
    read -rp "Escriba el nombre completo del dominio para confirmar: " confirmar
    
    if [[ "$confirmar" != "$dominio_eliminar" ]]; then
        aputs_info "Eliminacion cancelada"
        return 0
    fi
    
    echo ""
    draw_line
    echo ""
    
    # Hacer backup si se solicitó
    if [[ "$hacer_backup" == "s" || "$hacer_backup" == "S" ]]; then
        local backup_dir="/home/$(whoami)/dns_backups/dominio_${dominio_eliminar}_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir"
        
        aputs_info "Creando backup..."
        sudo cp "$zona_file" "$backup_dir/"
        
        if [[ -f "/var/named/${dominio_eliminar}.rev" ]]; then
            sudo cp "/var/named/${dominio_eliminar}.rev" "$backup_dir/"
        fi
        
        aputs_success "Backup creado en: $backup_dir"
        echo ""
    fi
    
    # Eliminar archivo de zona directa
    aputs_info "Eliminando zona directa..."
    if sudo rm -f "$zona_file"; then
        aputs_success "Zona directa eliminada: ${dominio_eliminar}.zone"
    else
        aputs_error "Error al eliminar zona directa"
        return 1
    fi
    
    # Eliminar zona inversa si existe y se solicitó
    if [[ "$eliminar_zona_inversa" == "s" || "$eliminar_zona_inversa" == "S" ]]; then
        if [[ -f "/var/named/${dominio_eliminar}.rev" ]]; then
            aputs_info "Eliminando zona inversa..."
            if sudo rm -f "/var/named/${dominio_eliminar}.rev"; then
                aputs_success "Zona inversa eliminada: ${dominio_eliminar}.rev"
            else
                aputs_warning "Error al eliminar zona inversa"
            fi
        fi
    fi
    
    echo ""
    
    # Eliminar entrada de named.conf
    aputs_info "Eliminando entrada de named.conf..."
    if eliminar_zona_de_named_conf "$dominio_eliminar"; then
        aputs_success "Entrada eliminada de named.conf"
    else
        aputs_error "Error al eliminar entrada de named.conf"
        return 1
    fi
    
    # Validar named.conf
    if sudo named-checkconf; then
        aputs_success "Configuracion de named.conf validada"
    else
        aputs_error "Error en named.conf"
        sudo named-checkconf 2>&1 | sed 's/^/  /'
        return 1
    fi
    
    echo ""
    draw_line
    echo ""
    
    # Reiniciar servicio
    aputs_warning "Se requiere reiniciar el servicio para aplicar cambios"
    local reiniciar
    read -rp "¿Reiniciar servicio named ahora? (s/n): " reiniciar
    
    if [[ "$reiniciar" == "s" || "$reiniciar" == "S" ]]; then
        aputs_info "Reiniciando servicio..."
        
        if sudo systemctl restart named; then
            sleep 2
            if check_service_active "named"; then
                aputs_success "Servicio reiniciado correctamente"
            else
                aputs_error "El servicio no se inicio correctamente"
            fi
        else
            aputs_error "Error al reiniciar servicio"
        fi
    else
        aputs_info "Recuerde reiniciar el servicio manualmente"
    fi
    
    echo ""
    draw_line
    echo ""
    
    aputs_success "DOMINIO ELIMINADO EXITOSAMENTE"
    echo ""
}

# Menú de eliminación
eliminar_menu() {
    clear
    draw_header "ELIMINAR"
    
    aputs_warning "ADVERTENCIA: Esta operacion es irreversible"
    echo ""
    aputs_info "¿Que desea eliminar?"
    echo ""
    aputs_info "1) Eliminar un registro especifico"
    aputs_info "2) Eliminar dominio completo"
    echo ""
    
    local elim_type
    read -rp "Opcion: " elim_type

    case $elim_type in
    1)
        eliminar_registro_especifico
        ;;
    2)
        eliminar_dominio_completo
        ;;
    *)
        aputs_error "Opcion invalida"
        ;;
    esac
}


#!/bin/bash
#
# crud_dominios.sh
# Módulo principal para gestión de dominios DNS (CRUD)
# 

# Cargar utilidades
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Cargar submódulos CRUD
source "${SCRIPT_DIR}/crud_listar.sh"
source "${SCRIPT_DIR}/crud_agregar.sh"
source "${SCRIPT_DIR}/crud_eliminar.sh"

# Menú principal CRUD Dominios
crud_dominios_menu() {
    while true; do
        clear
        echo ""
        aputs_info "┌────────────────────────────────────┐"
        aputs_info "|---|  Gestion de Dominios DNS   |---|"
        aputs_info "└────────────────────────────────────┘"
        
        echo ""
        aputs_info "Seleccione una operacion:"
        echo ""
        aputs_info "1) Listar dominios y registros"
        aputs_info "2) Agregar nuevo dominio"
        aputs_info "3) Agregar registro a dominio existente"
        aputs_info "4) Eliminar registro o dominio"
        aputs_info "5) Volver al menu principal"
        echo ""
        
        local crud_op
        read -rp "Opcion: " crud_op

        case $crud_op in
        1)
            listar_dominios_menu
            ;;
        2)
            agregar_dominio_completo
            ;;
        3)
            agregar_registro_menu
            ;;
        4)
            eliminar_menu
            ;;
        5)
            return 0
            ;;
        6)
            ls #ñiñiñiñiñiñiñiñiñi
            ;;
        *)
            aputs_error "Opcion invalida"
            sleep 1
            ;;
        esac
        
        if [[ $crud_op != 5 ]]; then
            echo ""
            pause
        fi
    done
}

# Función principal
crud_dominios() {
    # Verificar privilegios
    if ! check_privileges; then
        return 1
    fi
    
    # Verificar que BIND esté instalado
    if ! check_package_installed "bind"; then
        clear
        draw_header "CRUD DOMINIOS"
        aputs_error "BIND no esta instalado"
        echo ""
        aputs_info "Ejecute primero la opcion '2) Instalar/config servicio DNS'"
        return 1
    fi
    
    # Verificar que existe named.conf
    if [[ ! -f /etc/named.conf ]]; then
        clear
        draw_header "CRUD DOMINIOS"
        aputs_error "No existe archivo /etc/named.conf"
        echo ""
        aputs_info "Ejecute primero la opcion '2) Instalar/config servicio DNS'"
        return 1
    fi
    
    crud_dominios_menu
}

# Ejecutar si se llama directamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    crud_dominios
fi