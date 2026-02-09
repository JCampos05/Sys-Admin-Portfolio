#ver estado del servicio DHCP
Get-Service DHCPServer

#ver estado detallado del servicio
Get-Service DHCPServer | Format-List *

#reiniciar el servicio DHCP
Restart-Service DHCPServer -Force

#ver todas las concesiones activas
Get-DhcpServerv4Lease -ScopeId 192.168.100.0 # <-- segmento de red propuesto

#ver solo concesiones activas
Get-DhcpServerv4Lease -ScopeId 192.168.100.0 | Where-Object {$_.AddressState -eq "Active"}

# contar concesiones activas
(Get-DhcpServerv4Lease -ScopeId 192.168.100.0 | Where-Object {$_.AddressState -eq "Active"}).Count