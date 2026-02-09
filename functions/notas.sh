#checar las IPs 
ip -4 addr show

# ver estado del servicio
sudo systemctl status dhcpd

# verifica si el servicio está habilitado al inicio
sudo systemctl is-enabled dhcpd

# ver configuración actual
sudo cat /etc/dhcp/dhcpd.conf

# ver concesiones actuales 
sudo cat /var/lib/dhcpd/dhcpd.leases


#Cliente ------------------
#libera la IP actual
sudo dhclient -r ens160 #ens160 -> la interfaz de red

#solicitar nueva IP
sudo dhclient ens160 #ens160 -> la interfaz de red


#ver informacion de concesion DHCP
cat /var/lib/dhclient/dhclient.leases