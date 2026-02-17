#!/bin/bash
#
# Script para configurar el cliente DNS con IP dinámica del servidor
# 

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Funciones de salida
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

# Función para mostrar uso
mostrar_uso() {
    echo ""
    echo "Uso: $0 <IP_SERVIDOR_DNS>"
    echo ""
    echo "Ejemplo:"
    echo "  $0 192.168.100.10"
    echo "  $0 192.168.100.50"
    echo ""
    echo "Descripción:"
    echo "  Configura el cliente para usar el servidor DNS especificado."
    echo "  Desactiva systemd-resolved y configura /etc/resolv.conf."
    echo ""
}

# Función para validar IP
validar_ip() {
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

# Función principal
configurar_dns() {
    local dns_server="$1"
    
    echo ""
    echo "────────────────────────────────────────"
    echo "  Configuracion -> Cliente -> DNS"
    echo "────────────────────────────────────────"
    echo ""
    
    aputs_info "Servidor DNS: $dns_server"
    echo ""
    
    # Paso 1: Desactivar systemd-resolved
    aputs_info "PASO 1: Desactivando systemd-resolved..."
    
    if systemctl is-active --quiet systemd-resolved; then
        sudo systemctl stop systemd-resolved 2>/dev/null
        sudo systemctl disable systemd-resolved 2>/dev/null
        aputs_success "systemd-resolved detenido y deshabilitado"
    else
        aputs_info "systemd-resolved ya estaba inactivo"
    fi
    
    echo ""
    
    # Paso 2: Configurar /etc/resolv.conf
    aputs_info "PASO 2: Configurando /etc/resolv.conf..."
    
    # Quitar protección si existe
    sudo chattr -i /etc/resolv.conf 2>/dev/null
    
    # Eliminar archivo existente
    sudo rm -f /etc/resolv.conf
    
    # Crear nuevo archivo
    cat << EOF | sudo tee /etc/resolv.conf > /dev/null
nameserver $dns_server
nameserver 8.8.8.8
EOF
    
    # Proteger archivo
    sudo chattr +i /etc/resolv.conf
    
    aputs_success "/etc/resolv.conf configurado y protegido"
    echo ""
    
    # Paso 3: Verificar configuración
    aputs_info "PASO 3: Verificando configuración..."
    echo ""
    
    echo "Contenido de /etc/resolv.conf:"
    cat /etc/resolv.conf | sed 's/^/  /'
    
    echo ""
    echo "────────────────────────────────────────────────────"
    aputs_success "Configuracion Completada exitosamente"
    echo "────────────────────────────────────────────────────"
    echo ""
    
    # Paso 4: Probar conectividad
    aputs_info "Probando conectividad con el servidor DNS..."
    
    if ping -c 2 -W 2 "$dns_server" &>/dev/null; then
        aputs_success "Servidor DNS alcanzable: $dns_server"
    else
        aputs_warning "No se pudo hacer ping al servidor DNS"
        aputs_warning "Verifique que el servidor este en la misma red"
    fi
    
    echo ""
    
    # Paso 5: Probar resolución DNS (opcional)
    aputs_info "Puede probar la resolucion DNS con:"
    echo "  dig test1.com"
    echo "  nslookup test1.com"
    echo ""
}

# Script principal
main() {
    # Verificar que se ejecute con privilegios
    if [[ $EUID -ne 0 ]]; then
        if ! sudo -n true 2>/dev/null; then
            aputs_error "Este script requiere privilegios de sudo"
            exit 1
        fi
    fi
    
    # Verificar argumentos
    if [[ $# -eq 0 ]]; then
        aputs_error "Falta el argumento: IP del servidor DNS"
        mostrar_uso
        exit 1
    fi
    
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        mostrar_uso
        exit 0
    fi
    
    local dns_server="$1"
    
    # Validar IP
    if ! validar_ip "$dns_server"; then
        aputs_error "IP invalida: $dns_server"
        echo ""
        aputs_info "El formato debe ser: XXX.XXX.XXX.XXX"
        aputs_info "Ejemplo: 192.168.100.10"
        exit 1
    fi
    
    # Ejecutar configuración
    configurar_dns "$dns_server"
}

# Ejecutar
main "$@"