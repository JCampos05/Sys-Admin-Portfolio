# detecta las interfaces de red del SO -> 
# si hubo exito, hace que el usuario escoja una, de lo contrario tira error

function validar_ip {
    param([string]$ip)
    
    if ($ip -notmatch '^(\d{1,3}\.){3}\d{1,3}$') {
        Write-Host ""
        Write-Host "Formato IPv4 Incorrecto. Verifique nuevamente" -ForegroundColor Red
        return $false  # formato incorrecto
    }
    
    # Verificar que cada octeto esté en el rango 0-255
    $octetos = $ip.Split('.')
    foreach ($i in $octetos) {
        $num = [int]$i
        # Si algún octeto es mayor a 255 o menor a 0, la IP es incorrecta
        if ($num -lt 0 -or $num -gt 255) {
            Write-Host ""
            Write-Host "Formato IPv4 Incorrecto. Verifique nuevamente" -ForegroundColor Red
            return $false
        }
    }
    
    Write-Host ""
    Write-Host "Formato IPv4 correcto" -ForegroundColor Green
    return $true  # IP correcta
}