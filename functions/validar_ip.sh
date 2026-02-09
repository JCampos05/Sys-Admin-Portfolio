# valida una direccion IPv4 mediante expresión regular y con ciclo for el formato de cada octeo
validar_ip(){
    local ip=$1

    if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1  # formato incorrecto
    fi

    for i in ${ip//./ }; do
        # si algún octeto es mayor a 255 o menor a 0, la IP es incorrecta
        if ((i < 0 || i > 255)); then
            return 1
        fi
    done
    
    return 0  # IP correcta
}