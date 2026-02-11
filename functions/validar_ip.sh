# valida una direccion IPv4 mediante expresión regular y con ciclo for el formato de cada octeo
# Funcion 1: Validar formato basico de IPv4
validar_formato_ip(){
    local ip=$1

    # Verificar que tenga el patron correcto: numero.numero.numero.numero
    if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    # Verificar que cada octeto este en el rango 0-255
    local octeto
    for octeto in ${ip//./ }; do
        if ((octeto < 0 || octeto > 255)); then
            return 1
        fi
    done
    
    return 0
}