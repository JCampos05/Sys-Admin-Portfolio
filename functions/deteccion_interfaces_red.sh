# detecta las interfaces de red del SO -> 
# si hubo exito, hace que el usuario escoja una, de lo contrario tira error
deteccion_interfaces_red(){
    INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo")

    #validacion de haber encontrado o no interfaces
    if [ "${#INTERFACES[@]}" -eq 0 ]; then
        echo ""
        echo "No se detectaron interfaces de red"
        exit 1
    fi

    echo ""
    echo "Interfaces de red detectadas:"
    echo "$INTERFACES"

    while true; do
        read -rp "Seleccione el número de la interfaz para DHCP [1-${#INTERFACES[@]}]: " selection
    done
    echo ""
    echo "Interfaz de red seleccionada"
    echo "$selection"
}