# detecta las interfaces de red del SO -> 
# si hubo exito, hace que el usuario escoja una, de lo contrario tira error
#
function deteccion_interfaces_red {
    # Obtener TODAS las interfaces con IP (incluyendo manuales y DHCP)
    $script:interfaces = Get-NetIPAddress -AddressFamily IPv4 | 
        Where-Object { 
            $_.IPAddress -notlike "127.*" -and
            $_.IPAddress -notlike "169.254.*"
        }
    
    if ($script:interfaces.Count -eq 0) {
        Write-Host ""
        Write-Host "No se detectaron interfaces de red" 
        exit 1
    }
    
    Write-Host ""
    Write-Host "Interfaces de red detectadas:"
    Write-Host ""
    
    $script:listaInterfaces = @()
    $index = 1
    
    foreach ($adapter in $script:interfaces) {
        $netAdapter = Get-NetAdapter -InterfaceIndex $adapter.InterfaceIndex
        
        $info = [PSCustomObject]@{
            Numero    = $index
            Interfaz  = $adapter.InterfaceAlias
            Direccion = $adapter.IPAddress
            Estado    = $netAdapter.Status
            IfIndex   = $adapter.InterfaceIndex
        }
        
        $script:listaInterfaces += $info
        Write-Host ("  {0}) {1,-15} (IP actual: {2})" -f $index, $adapter.InterfaceAlias, $adapter.IPAddress)
        $index++
    }
    Write-Host ""
    
    while ($true) {
        $selection = Read-Host "Seleccione el numero de la interfaz para DHCP [1-$($script:listaInterfaces.Count)]"
        
        if ($selection -match '^\d+$') {
            $selectionNum = [int]$selection
            
            if ($selectionNum -ge 1 -and $selectionNum -le $script:listaInterfaces.Count) {
                $script:interfazSeleccionada = $script:listaInterfaces[$selectionNum - 1]
                break
            }
        }
        
        Write-Host "Seleccion invalida. Ingrese un numero entre 1 y $($script:listaInterfaces.Count)" 
    }
    
    Write-Host ""
    Write-Host "Interfaz de red seleccionada: $($script:interfazSeleccionada.Interfaz)" 
}