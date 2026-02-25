#
# Establece una sesion SSH interactiva con el servidor elegido
#
# Depende de: utilsCliSSH.sh, validatorsCliSSH.sh
#

conectar_servidor() {
    clear
    draw_header "Conectar a Servidor via SSH"

    # ─── Elegir servidor ─────────────────────────────────────────
    if ! elegir_servidor; then
        return 1
    fi

    echo ""
    draw_line

    # ─── Verificar conectividad previa ───────────────────────────
    aputs_info "Verificando accesibilidad del servidor..."
    echo ""

    if ! check_conectividad "$SVR_IP"; then
        aputs_warning "El host $SVR_IP no responde a ping"
        aputs_info    "Intentando conectar de todas formas..."
    else
        aputs_success "Host accesible"
    fi

    if ! check_puerto_ssh "$SVR_IP" "$SVR_PUERTO"; then
        aputs_error "El puerto SSH ${SVR_PUERTO} no esta accesible en ${SVR_IP}"
        aputs_info  "Verifique que el servicio sshd este activo en el servidor"
        return 1
    fi

    aputs_success "Puerto ${SVR_PUERTO}/TCP accesible"
    echo ""
    draw_line

    # ─── Opciones de conexion ────────────────────────────────────
    aputs_info "Opciones de autenticacion:"
    echo ""
    echo "  1) Con clave publica (sin contrasena)"
    echo "  2) Con contrasena"
    echo ""

    local op_auth
    agets "Metodo [1/2]" op_auth

    # Armar opciones SSH comunes
    # -o StrictHostKeyChecking=accept-new: acepta claves nuevas automaticamente
    # -p: puerto configurado
    local opts_base=(
        -o StrictHostKeyChecking=accept-new
        -o ConnectTimeout=8
        -p "$SVR_PUERTO"
    )

    echo ""
    draw_line

    case "$op_auth" in
        1)
            # ─ Clave publica ────────────────────────────────────
            aputs_info "Buscando claves disponibles en ~/.ssh/..."
            echo ""

            local claves=()
            while IFS= read -r clave; do
                # Solo archivos privados
                claves+=("$clave")
                echo "  - $clave"
            done < <(find ~/.ssh -maxdepth 1 -type f ! -name "*.pub" ! -name "known_hosts" ! -name "config" 2>/dev/null)

            if [[ ${#claves[@]} -eq 0 ]]; then
                aputs_warning "No se encontraron claves privadas en ~/.ssh/"
                aputs_info    "Genera una con la opcion 4 del menu principal de SSH"
                return 1
            fi

            echo ""
            aputs_info "Conectando con clave publica..."
            echo ""
            aputs_info ">>> ssh ${SVR_USER}@${SVR_IP} -p ${SVR_PUERTO}"
            echo ""
            draw_line
            echo ""

            # Lanzar la sesion interactiva
            # El -t asegura que se asigne una terminal (TTY) remota
            ssh "${opts_base[@]}" -t "${SVR_USER}@${SVR_IP}"
            local codigo=$?

            echo ""
            draw_line
            if [[ $codigo -eq 0 ]]; then
                aputs_success "Sesion SSH cerrada correctamente"
            else
                aputs_warning "La sesion termino con codigo: $codigo"
            fi
            ;;

        2)
            # ─ Contrasena ───────────────────────────────────────
            aputs_info "Conectando con contrasena..."
            echo ""
            aputs_info ">>> ssh ${SVR_USER}@${SVR_IP} -p ${SVR_PUERTO}"
            echo ""
            draw_line
            echo ""

            # -o PreferredAuthentications=password: fuerza autenticacion por contrasena
            # -o PubkeyAuthentication=no: evita intentos con claves antes de pedir pass
            ssh "${opts_base[@]}" \
                -o PreferredAuthentications=password \
                -o PubkeyAuthentication=no \
                -t "${SVR_USER}@${SVR_IP}"
            local codigo=$?

            echo ""
            draw_line
            if [[ $codigo -eq 0 ]]; then
                aputs_success "Sesion SSH cerrada correctamente"
            else
                aputs_warning "La sesion termino con codigo: $codigo"
            fi
            ;;

        *)
            aputs_error "Opcion no valida"
            return 1
            ;;
    esac
}