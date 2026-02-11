# detecta las interfaces de red del SO -> 
# si hubo exito, hace que el usuario escoja una, de lo contrario tira error

# Valida el formato basico de IPv4
function validar_formato_ip {
    param([string]$ip)
    
    # Verifica que tenga el patron correcto: numero.numero.numero.numero
    if ($ip -notmatch '^(\d{1,3}\.){3}\d{1,3}$') {
        return $false
    }
    
    # Verifica que cada octeto este en el rango 0-255
    $octetos = $ip.Split('.')
    foreach ($octeto in $octetos) {
        $num = [int]$octeto
        if ($num -lt 0 -or $num -gt 255) {
            return $false
        }
    }
    
    return $true
}