#
# Verifica conectividad y estado SSH de los servidores conocidos
#

verificar_conectividad() {
    clear
    draw_header "Verificar Conectividad con Servidores"

    local servidores=(
        "${SVR_LINUX_NOMBRE}|${SVR_LINUX_IP}|${SVR_LINUX_USER}|${SVR_LINUX_PUERTO}"
        "${SVR_WIN_NOMBRE}|${SVR_WIN_IP}|${SVR_WIN_USER}|${SVR_WIN_PUERTO}"
    )

    for entrada in "${servidores[@]}"; do
        # Separar campos del servidor
        local nombre ip usuario puerto
        IFS='|' read -r nombre ip usuario puerto <<< "$entrada"

        echo ""
        aputs_info "Verificando: ${nombre} (${ip})"
        draw_line

        # ─ Ping 
        echo -ne "  Ping (ICMP)          : "
        if check_conectividad "$ip"; then
            echo -e "${GREEN}ACCESIBLE${NC}"
        else
            echo -e "${RED}SIN RESPUESTA${NC}"
            aputs_warning "El host $ip no responde a ping"
        fi

        # ─ Puerto SSH 
        echo -ne "  Puerto ${puerto}/TCP (SSH)  : "
        if check_puerto_ssh "$ip" "$puerto"; then
            echo -e "${GREEN}ABIERTO${NC}"
        else
            echo -e "${RED}CERRADO o FILTRADO${NC}"
            aputs_warning "No se puede alcanzar el puerto SSH ${puerto} en ${ip}"
        fi

        # ─ Handshake SSH ─────────────────────────────────────────
        # -o ConnectTimeout=4: maximo 4 segundos de espera
        # El codigo de salida 255 = error de conexion, otros = conectado pero autenticacion fallida
        echo -ne "  Handshake SSH        : "
        local salida_ssh
        salida_ssh=$(ssh \
            -o BatchMode=yes \
            -o ConnectTimeout=4 \
            -o StrictHostKeyChecking=no \
            -p "$puerto" \
            "${usuario}@${ip}" \
            "echo OK" 2>&1)
        local codigo=$?

        if [[ $codigo -eq 0 ]]; then
            echo -e "${GREEN}EXITOSO (clave configurada)${NC}"
        elif [[ $codigo -eq 255 ]]; then
            echo -e "${RED}FALLO DE CONEXION${NC}"
            aputs_warning "No se pudo establecer la sesion SSH"
        else
            # Conectó pero la autenticacion fallo (password requerida, etc.)
            echo -e "${YELLOW}SERVIDOR RESPONDE (autenticacion pendiente)${NC}"
        fi

        # ─ Clave en known_hosts ──────────────────────────────────
        echo -ne "  En known_hosts       : "
        if ssh-keygen -F "${ip}" &>/dev/null; then
            echo -e "${GREEN}SI${NC}"
        else
            echo -e "${YELLOW}NO (primera conexion pedira confirmacion)${NC}"
        fi

        echo ""
    done

    draw_line
    aputs_info "Verificacion completada"
}