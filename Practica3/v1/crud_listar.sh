#!/bin/bash
#
# crud_listar.sh
# Submódulo para listar dominios y registros DNS
#

# Cargar utilidades
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Función para listar solo nombres de dominios
listar_dominios_simple() {
    clear
    draw_header "Listado de Dominios"
    
    if [[ ! -d /var/named ]]; then
        aputs_warning "No hay dominios configurados"
        return
    fi
    
    local zonas=$(sudo find /var/named -maxdepth 1 -name "*.zone" -type f 2>/dev/null | wc -l)
    
    if [[ $zonas -eq 0 ]]; then
        aputs_info "No hay dominios configurados"
        return
    fi
    
    aputs_info "Dominios configurados: $zonas"
    echo ""
    
    local contador=1
    while IFS= read -r zona_file; do
        local dominio=$(basename "$zona_file" .zone)
        echo "  $contador) $dominio"
        ((contador++))
    done < <(sudo find /var/named -maxdepth 1 -name "*.zone" -type f 2>/dev/null | sort)
}

# Función para listar con resumen
listar_dominios_resumen() {
    clear
    draw_header "Listado de Dominios Resumidos"
    
    if [[ ! -d /var/named ]]; then
        aputs_warning "No hay dominios configurados"
        return
    fi
    
    local zonas=$(sudo find /var/named -maxdepth 1 -name "*.zone" -type f 2>/dev/null | wc -l)
    
    if [[ $zonas -eq 0 ]]; then
        aputs_info "No hay dominios configurados"
        return
    fi
    
    aputs_info "Total de dominios: $zonas"
    echo ""
    draw_line
    echo ""
    
    while IFS= read -r zona_file; do
        local dominio=$(basename "$zona_file" .zone)
        
        # Obtener IP principal (registro @)
        local ip_principal=$(sudo grep "^@.*IN.*A" "$zona_file" | head -n 1 | awk '{print $NF}')
        
        # Contar registros
        local total_registros=$(sudo grep -c "^[^;].*IN.*[A-Z]" "$zona_file" 2>/dev/null || echo "0")
        
        # Obtener serial
        local serial=$(sudo grep -m1 "Serial" "$zona_file" | grep -oP '\d{10}')
        
        echo "Dominio: $dominio"
        echo "  IP principal: ${ip_principal:-No configurado}"
        echo "  Registros: $total_registros"
        echo "  Serial: ${serial:-No disponible}"
        
        # Validar zona
        if sudo named-checkzone "$dominio" "$zona_file" &>/dev/null; then
            echo "  Estado: OK"
        else
            echo "  Estado: ERROR"
        fi
        
        echo ""
    done < <(sudo find /var/named -maxdepth 1 -name "*.zone" -type f 2>/dev/null | sort)
}

# Función para listar detallado
listar_dominios_detallado() {
    clear
    draw_header "Listado de Dominios detallado"
    
    if [[ ! -d /var/named ]]; then
        aputs_warning "No hay dominios configurados"
        return
    fi
    
    local zonas=$(sudo find /var/named -maxdepth 1 -name "*.zone" -type f 2>/dev/null | wc -l)
    
    if [[ $zonas -eq 0 ]]; then
        aputs_info "No hay dominios configurados"
        return
    fi
    
    while IFS= read -r zona_file; do
        local dominio=$(basename "$zona_file" .zone)
        
        echo ""
        draw_line
        aputs_success "DOMINIO: $dominio"
        draw_line
        echo ""
        
        # Mostrar registros SOA
        aputs_info "Registro SOA:"
        sudo grep -A 5 "IN.*SOA" "$zona_file" | sed 's/^/  /'
        echo ""
        
        # Mostrar registros NS
        aputs_info "Servidores de Nombres (NS):"
        sudo grep "IN.*NS" "$zona_file" | grep -v "^;" | sed 's/^/  /' || echo "  Ninguno"
        echo ""
        
        # Mostrar registros A
        aputs_info "Registros A (IPv4):"
        sudo grep "IN.*A" "$zona_file" | grep -v "IN.*AAAA" | grep -v "^;" | sed 's/^/  /' || echo "  Ninguno"
        echo ""
        
        # Mostrar registros CNAME
        local cnamesexist=$(sudo grep "IN.*CNAME" "$zona_file" | grep -v "^;" | wc -l)
        if [[ $cnames -gt 0 ]]; then
            aputs_info "Registros CNAME (Alias):"
            sudo grep "IN.*CNAME" "$zona_file" | grep -v "^;" | sed 's/^/  /'
            echo ""
        fi
        
        # Mostrar registros MX
        local mxexist=$(sudo grep "IN.*MX" "$zona_file" | grep -v "^;" | wc -l)
        if [[ $mxexist -gt 0 ]]; then
            aputs_info "Registros MX (Correo):"
            sudo grep "IN.*MX" "$zona_file" | grep -v "^;" | sed 's/^/  /'
            echo ""
        fi
        
        # Mostrar registros TXT
        local txtexist=$(sudo grep "IN.*TXT" "$zona_file" | grep -v "^;" | wc -l)
        if [[ $txtexist -gt 0 ]]; then
            aputs_info "Registros TXT:"
            sudo grep "IN.*TXT" "$zona_file" | grep -v "^;" | sed 's/^/  /'
            echo ""
        fi
        
        echo ""
        
    done < <(sudo find /var/named -maxdepth 1 -name "*.zone" -type f 2>/dev/null | sort)
}

# Función para listar dominio específico
listar_dominio_especifico() {
    clear
    draw_header "Listar Dominio especifico"
    
    # Primero mostrar dominios disponibles
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
    
    local dominio_buscar
    read -rp "Ingrese el dominio a consultar: " dominio_buscar
    
    if [[ -z "$dominio_buscar" ]]; then
        aputs_warning "No se ingreso ningun dominio"
        return
    fi
    
    local zona_file="/var/named/${dominio_buscar}.zone"
    
    if [[ ! -f "$zona_file" ]]; then
        aputs_error "El dominio '$dominio_buscar' no existe"
        return
    fi
    
    clear
    draw_header "DOMINIO: $dominio_buscar"
    
    # Serial
    local serial=$(sudo grep -m1 "Serial" "$zona_file" | grep -oP '\d{10}')
    aputs_info "Serial: ${serial:-No disponible}"
    
    # Estado
    if sudo named-checkzone "$dominio_buscar" "$zona_file" &>/dev/null; then
        aputs_success "Estado: VALIDO"
    else
        aputs_error "Estado: INVALIDO"
    fi
    
    echo ""
    draw_line
    echo ""
    
    # Mostrar contenido completo del archivo
    aputs_info "Contenido del archivo de zona:"
    echo ""
    sudo cat "$zona_file" | grep -v "^;" | grep -v "^$"
}

# Menú de listado
listar_dominios_menu() {
    clear
    draw_header "Listar Dominios"
    echo ""
    aputs_info "Tipo de listado:"
    echo ""
    aputs_info "1) Solo nombres de dominios"
    aputs_info "2) Resumen (dominio + IP + registros)"
    aputs_info "3) Detallado (todos los registros)"
    aputs_info "4) Filtrar por dominio especifico"
    echo ""
    
    local list_type
    read -rp "Opcion: " list_type

    case $list_type in
    1)
        listar_dominios_simple
        ;;
    2)
        listar_dominios_resumen
        ;;
    3)
        listar_dominios_detallado
        ;;
    4)
        listar_dominio_especifico
        ;;
    *)
        aputs_error "Opcion invalida"
        ;;
    esac
}