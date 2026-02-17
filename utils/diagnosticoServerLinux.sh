#!/bin/bash

echo "────────────────────────────────────────"
echo "   Diagnostico Server Linux"
echo "────────────────────────────────────────"
echo ""

echo "1. INFORMACIÓN BÁSICA"
echo "────────────────────────────────────────"
echo "Hostname:"
hostname
echo ""
echo "Usuario actual:"
whoami
echo ""
echo "Fecha del sistema:"
date
echo ""
read -rp a

echo "2. INTERFACES DE RED"
echo "────────────────────────────────────────"
ip link show
echo ""
echo "Configuración IP:"
ip addr show
echo ""
echo "Rutas:"
ip route show
echo ""
read -rp a

echo "3. Conexiones NetworkManager"
echo "────────────────────────────────────────"
nmcli connection show
echo ""
echo "Estado de dispositivos:"
nmcli device status
echo ""
read -rp a

echo "4. Firewall"
echo "────────────────────────────────────────"
sudo systemctl status firewalld --no-pager | head -n 5
echo ""
echo "Zonas activas:"
sudo firewall-cmd --get-active-zones
echo ""
echo "Configuración de todas las zonas:"
for zona in $(sudo firewall-cmd --get-active-zones | grep -v "interfaces:"); do
    if [[ ! -z "$zona" ]]; then
        echo ""
        echo "=== ZONA: $zona ==="
        sudo firewall-cmd --zone=$zona --list-all
    fi
done
echo ""
read -rp a

echo "5. Servicios DNS"
echo "────────────────────────────────────────"
echo "BIND instalado:"
rpm -qa | grep bind
echo ""
echo "Estado servicio named:"
sudo systemctl status named --no-pager | head -n 5
echo ""
if [[ -f /etc/named.conf ]]; then
    echo "named.conf existe: SÍ"
    echo "Zonas configuradas en named.conf:"
    sudo grep -E "^zone" /etc/named.conf
else
    echo "named.conf existe: NO"
fi
echo ""
read -rp a

echo "6. Archivos de Zona"
echo "────────────────────────────────────────"
echo "Archivos .zone en /var/named:"
sudo ls -lh /var/named/*.zone 2>/dev/null || echo "No hay archivos .zone"
echo ""

echo "7. Servicios DHCP"
echo "────────────────────────────────────────"
echo "DHCP instalado:"
rpm -qa | grep dhcp-server
echo ""
echo "Estado servicio dhcpd:"
sudo systemctl status dhcpd --no-pager 2>&1 | head -n 5
echo ""

echo "8. Conectividad"
echo "────────────────────────────────────────"
echo "Ping a Internet (8.8.8.8):"
ping -c 2 8.8.8.8 2>&1 | tail -n 2
echo ""

echo "────────────────────────────────────────"
echo "Fin del Diagnostico"
echo "────────────────────────────────────────"
