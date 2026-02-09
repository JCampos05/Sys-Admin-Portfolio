Write-Host "Status Inicial"

Write-Host "1. Nombre del equipo:"
hostname

Write-Host ""
Write-Host "2. Direcciones IP:"
Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress | Out-String

Write-Host ""
Write-Host "3. Espacio en Disco:"
Get-Volume | Out-String