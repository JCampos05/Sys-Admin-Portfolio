#
# Módulo: Instalar y configurar el cliente FTP (lftp)
#
# Requiere:
#   utils_cliente.sh 
#

# ─── Función principal ────────────────────────────────────────────────────────

instalar_cliente_ftp() {
    draw_header "Instalar y Configurar Cliente FTP (lftp)"

    # ── Paso 1: Instalar lftp ─────────────────────────────────────────────────
    echo ""
    aputs_info "[ Paso 1/4 ] Instalacion de lftp"
    draw_line

    if check_lftp_instalado; then
        local version
        version=$(lftp --version 2>/dev/null | head -1)
        aputs_success "lftp ya esta instalado: $version"
    else
        aputs_info "Instalando lftp con dnf..."
        # lftp no requiere root para usarse, pero sí para instalarse
        if sudo dnf install -y lftp 2>/dev/null; then
            aputs_success "lftp instalado correctamente"
        else
            aputs_error "Error al instalar lftp"
            aputs_info  "Verifique la conexion a internet y que dnf este disponible"
            return 1
        fi
    fi

    # ── Paso 2: Directorio de configuración del gestor ────────────────────────
    echo ""
    aputs_info "[ Paso 2/4 ] Directorio de configuracion del gestor"
    draw_line

    if [[ ! -d "$CLIENT_CONFIG_DIR" ]]; then
        mkdir -p "$CLIENT_CONFIG_DIR"
        aputs_success "Directorio creado: $CLIENT_CONFIG_DIR"
    else
        aputs_success "Directorio ya existe: $CLIENT_CONFIG_DIR"
    fi

    # ── Paso 3: Archivo de servidores ─────────────────────────────────────────
    echo ""
    aputs_info "[ Paso 3/4 ] Archivo de servidores ($CLIENT_CONFIG_FILE)"
    draw_line

    if [[ ! -f "$CLIENT_CONFIG_FILE" ]]; then
        cat > "$CLIENT_CONFIG_FILE" <<'EOF'
# Configuracion de servidores FTP
# Generado por el Gestor del Cliente FTP
# Formato: CLAVE=valor (una por linea, sin espacios alrededor del =)
IP_FEDORA=
IP_WINDOWS=
EOF
        aputs_success "Archivo creado: $CLIENT_CONFIG_FILE"
        aputs_info    "Use la opcion 0 del menu principal para configurar las IPs"
    else
        aputs_success "Archivo ya existe: $CLIENT_CONFIG_FILE"
    fi

    # ── Paso 4: ~/.lftprc — configuración global de lftp ─────────────────────
    echo ""
    aputs_info "[ Paso 4/4 ] Configuracion global lftp (~/.lftprc)"
    draw_line

    local lftprc="${HOME}/.lftprc"

    # Si ya existe, preguntar si sobreescribir
    if [[ -f "$lftprc" ]]; then
        aputs_warning "El archivo $lftprc ya existe"
        local resp
        agets "Sobreescribir con la configuracion recomendada? [s/N]" resp
        if [[ ! "$resp" =~ ^[Ss]$ ]]; then
            aputs_info "Configuracion existente conservada"
            aputs_success "Instalacion completada"
            return 0
        fi
    fi

    cat > "$lftprc" <<'EOF'
# ~/.lftprc — Configuracion global del cliente lftp
# Generado por el Gestor del Cliente FTP

# Modo pasivo siempre activo:
#   El cliente inicia AMBAS conexiones (control y datos).
#   Necesario cuando el cliente esta detras de NAT o firewall.
set ftp:passive-mode true

# Timeout de conexion en segundos:
#   Si el servidor no responde en 15s, lftp abandona el intento.
set net:timeout 15

# Reintentos ante error de red transitorio:
set net:max-retries 2

# Pausa entre reintentos (segundos):
set net:reconnect-interval-base 5

# Compatibilidad con servidores que no implementan FEAT (como IIS FTP):
#   FEAT es un comando FTP moderno que lista extensiones soportadas.
#   Algunos servidores lo implementan parcialmente y responden con error.
set ftp:use-feat false

# Codificacion UTF-8 para nombres de archivo:
set ftp:charset utf-8
EOF

    aputs_success "Configuracion global escrita en: $lftprc"
    aputs_success "Instalacion del cliente FTP completada"
}