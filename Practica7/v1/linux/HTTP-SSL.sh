#!/bin/bash
# 
# ssl/ssl_http.sh — Configuración SSL/HTTPS en Apache, Nginx y Tomcat
#
# Propósito:
#   Para cada servicio HTTP instalado, habilitar HTTPS usando el certificado
#   compartido generado por ssl_cert.sh. El script detecta qué servicios
#   están instalados y pregunta cuál(es) configurar.
#
#   NO reinstala servicios — solo edita configuraciones existentes.
#
# Funciones públicas:
#   ssl_http_aplicar_apache()  — VirtualHost :443 + redirect HTTP->HTTPS
#   ssl_http_aplicar_nginx()   — bloque server SSL + return 301
#   ssl_http_aplicar_tomcat()  — Connector HTTPS + keystore .p12
#   ssl_http_aplicar_todos()   — detecta instalados y aplica a cada uno
#   ssl_http_estado()          — muestra estado SSL de los tres servicios
#   ssl_menu_http()            — submenú interactivo
#
# Requiere:
#   utils.sh, ssl_utils.sh, ssl_cert.sh cargados previamente
# 

[[ -n "${_SSL_HTTP_LOADED:-}" ]] && return 0
readonly _SSL_HTTP_LOADED=1

# Marcadores para identificar bloques insertados (para revertir/detectar)
readonly _SSL_HTTP_MARCA_APACHE="# === Practica7 SSL Apache ==="
readonly _SSL_HTTP_MARCA_NGINX="# === Practica7 SSL Nginx ==="


# -----------------------------------------------------------------------------
# Actualiza el index.html del servicio para mostrar ambos puertos (HTTP y HTTPS).
# Se llama después de aplicar SSL para que el usuario vea la info correcta.
# -----------------------------------------------------------------------------
_ssl_actualizar_index() {
    local servicio="$1"
    local http_port="$2"
    local https_port="$3"

    local webroot
    webroot=$(http_get_webroot "$servicio" 2>/dev/null) || true
    [[ -z "$webroot" ]] && return 0

    local index_file="${webroot}/index.html"
    [[ ! -f "$index_file" ]] && return 0

    local version=""
    version=$(rpm -q --queryformat "%{VERSION}-%{RELEASE}"               "$(http_nombre_paquete "$servicio" 2>/dev/null)" 2>/dev/null) || true

    local usuario=""
    usuario=$(http_get_usuario_servicio "$servicio" 2>/dev/null) || true

    local cert_cn=""
    cert_cn=$(openssl x509 -in "${SSL_CERT}" -noout -subject 2>/dev/null               | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 | tr -d ' ') || true

    local nombre_display
    case "$servicio" in
        httpd)  nombre_display="Apache HTTP Server" ;;
        nginx)  nombre_display="Nginx"              ;;
        tomcat) nombre_display="Apache Tomcat"      ;;
        *)      nombre_display="$servicio"          ;;
    esac

    aputs_info "Actualizando index.html con puertos SSL..."

    cat > "$index_file" << HTMLEOF
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>${nombre_display}</title>
    <style>
        body { font-family: sans-serif; max-width: 500px; margin: 60px auto; color: #222; }
        h1   { border-bottom: 2px solid #222; padding-bottom: 8px; }
        td   { padding: 6px 16px 6px 0; }
        td:first-child { font-weight: bold; color: #555; }
        .ssl  { color: #2a7; font-weight: bold; }
        .cert { color: #666; font-size: 0.9em; }
    </style>
</head>
<body>
    <h1>${nombre_display}</h1>
    <p>Despliegue exitoso</p>
    <table>
        <tr><td>Version</td>     <td>${version}</td></tr>
        <tr><td>Puerto HTTP</td>  <td>${http_port}/tcp -> redirect HTTPS</td></tr>
        <tr><td>Puerto HTTPS</td> <td class="ssl">${https_port}/tcp (SSL/TLS activo)</td></tr>
        <tr><td>Certificado</td>  <td class="cert">${cert_cn:-reprobados.com} (autofirmado)</td></tr>
        <tr><td>Webroot</td>     <td>${webroot}</td></tr>
        <tr><td>Usuario</td>     <td>${usuario}</td></tr>
        <tr><td>Fecha</td>       <td>$(date '+%Y-%m-%d %H:%M')</td></tr>
    </table>
</body>
</html>
HTMLEOF
    aputs_success "index.html actualizado — HTTP:${http_port} -> HTTPS:${https_port} (${cert_cn:-?})"
}

# -----------------------------------------------------------------------------
# _ssl_seleccionar_puerto_https  <servicio>  <http_port>  <var_destino>
#
# Muestra el puerto HTTPS calculado por defecto y pregunta al usuario si
# quiere conservarlo o ingresar uno diferente.
# Usa las mismas validaciones de http_validar_puerto() de P6.
#
# Parámetros:
#   $1 — nombre del servicio (httpd|nginx|tomcat) — para mostrar contexto
#   $2 — puerto HTTP actual del servicio
#   $3 — nombre de variable donde guardar el puerto HTTPS elegido
# -----------------------------------------------------------------------------
_ssl_seleccionar_puerto_https() {
    local servicio="$1"
    local http_port="$2"
    local _var_destino="$3"

    # Puerto sugerido por la lógica actual (80->443, 8080->8443, otro->otro+363)
    local puerto_sugerido
    puerto_sugerido=$(ssl_puerto_https "${http_port}")

    echo ""
    aputs_info "Puerto HTTP activo    : ${http_port}/tcp"
    aputs_info "Puerto HTTPS sugerido : ${puerto_sugerido}/tcp"
    echo ""
    echo -ne "  ${YELLOW}[?]${NC} ¿Usar puerto HTTPS ${puerto_sugerido}? [S/n/otro]: "
    local resp
    read -r resp

    # Enter o S -> usar el sugerido
    if [[ -z "$resp" || "$resp" =~ ^[sS]$ ]]; then
        printf -v "$_var_destino" "%s" "$puerto_sugerido"
        aputs_success "Puerto HTTPS: ${puerto_sugerido}/tcp"
        echo ""
        return 0
    fi

    # n -> no usar el sugerido, pedir uno nuevo
    # Si ingresaron un número directamente, usarlo como candidato
    local candidato=""
    if [[ "$resp" =~ ^[0-9]+$ ]]; then
        candidato="$resp"
    fi

    # Pedir puerto con las mismas validaciones de P6
    local puerto_elegido
    while true; do
        if [[ -n "$candidato" ]]; then
            # Ya tenemos un candidato de la respuesta anterior
            puerto_elegido="$candidato"
            candidato=""
        else
            echo -ne "  Puerto HTTPS [1-65535, distinto de ${http_port}]: "
            read -r puerto_elegido
        fi

        # Validar con la función de P6 si está disponible, o validación básica
        if declare -f http_validar_puerto &>/dev/null; then
            if ! http_validar_puerto "$puerto_elegido"; then
                echo ""
                continue
            fi
        else
            # Validación básica inline
            if ! [[ "$puerto_elegido" =~ ^[0-9]+$ ]] ||                (( puerto_elegido < 1 || puerto_elegido > 65535 )); then
                aputs_error "Puerto inválido — debe ser un número entre 1 y 65535"
                echo ""
                continue
            fi
        fi

        # No puede ser el mismo que el puerto HTTP
        if [[ "$puerto_elegido" == "$http_port" ]]; then
            aputs_error "El puerto HTTPS no puede ser el mismo que el HTTP (${http_port})"
            echo ""
            continue
        fi

        # Advertir si el puerto ya está en uso por otro proceso
        if ss -tlnp 2>/dev/null | grep -q ":${puerto_elegido} "; then
            aputs_warning "El puerto ${puerto_elegido} ya está en uso"
            echo -ne "  ${YELLOW}[?]${NC} ¿Continuar de todas formas? [s/N]: "
            local forzar; read -r forzar
            [[ ! "$forzar" =~ ^[sS]$ ]] && { echo ""; continue; }
        fi

        break
    done

    printf -v "$_var_destino" "%s" "$puerto_elegido"
    aputs_success "Puerto HTTPS seleccionado: ${puerto_elegido}/tcp"
    echo ""
    return 0
}

# 
# APACHE
# 

ssl_http_aplicar_apache() {
    ssl_mostrar_banner "SSL — Apache (httpd)"

    # Prerequisitos
    if ! ssl_servicio_instalado httpd; then
        aputs_warning "Apache (httpd) no está instalado — omitiendo"
        return 0
    fi

    if ! ssl_cert_existe; then
        aputs_error "Certificado no generado — ejecute primero el Paso 2"
        return 1
    fi

    # Detectar puerto HTTP y seleccionar puerto HTTPS
    local http_port
    http_port=$(ssl_leer_puerto_http httpd)
    local https_port
    _ssl_seleccionar_puerto_https "httpd" "${http_port}" https_port

    aputs_info "El puerto HTTP (${http_port}) se mantiene activo con redirect -> HTTPS"
    aputs_info "Se agrega Listen ${https_port} en ssl_reprobados.conf (puerto adicional)"
    echo ""

    # Verificar si ya está configurado
    if [[ -f "${SSL_CONF_APACHE_SSL}" ]] && \
       grep -q "${_SSL_HTTP_MARCA_APACHE}" "${SSL_CONF_APACHE_SSL}" 2>/dev/null; then
        aputs_warning "SSL de Apache ya está configurado"
        echo -ne "${YELLOW}[?]${NC} ¿Reaplicar? [s/N]: "
        local resp; read -r resp
        [[ ! "$resp" =~ ^[sS]$ ]] && return 0
        rm -f "${SSL_CONF_APACHE_SSL}"
    fi

    # Instalar mod_ssl si falta
    if ! rpm -q mod_ssl &>/dev/null; then
        aputs_info "Instalando mod_ssl..."
        if dnf install -y mod_ssl &>/dev/null; then
            aputs_success "mod_ssl instalado"
            # Deshabilitar el ssl.conf por defecto de mod_ssl:
            # apunta a /etc/pki/tls/certs/localhost.crt que no existe en producción
            # Nuestro ssl_reprobados.conf reemplaza toda esa configuración
            if [[ -f /etc/httpd/conf.d/ssl.conf ]]; then
                mv /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/ssl.conf.disabled
                aputs_info "ssl.conf por defecto deshabilitado (ssl.conf.disabled)"
            fi
        else
            aputs_error "No se pudo instalar mod_ssl"
            return 1
        fi
    else
        aputs_info "mod_ssl ya instalado"
    fi
    echo ""

    # Backup de httpd.conf
    ssl_hacer_backup "${SSL_CONF_APACHE}"
    echo ""

    # Crear archivo de configuración SSL dedicado
    aputs_info "Creando ${SSL_CONF_APACHE_SSL}..."

    cat > "${SSL_CONF_APACHE_SSL}" << EOF
${_SSL_HTTP_MARCA_APACHE}
# Generado por mainT07.sh — Práctica 7 SSL

# VirtualHost HTTPS en puerto ${https_port}
Listen ${https_port}

<VirtualHost *:${https_port}>
    ServerName ${SSL_DOMAIN}

    # Certificado compartido de la práctica
    SSLEngine on
    SSLCertificateFile    ${SSL_CERT}
    SSLCertificateKeyFile ${SSL_KEY}

    # Protocolos seguros — deshabilitar SSLv2/v3 y TLS 1.0/1.1
    SSLProtocol all -SSLv2 -SSLv3 -TLSv1 -TLSv1.1

    # Cifrados recomendados
    SSLCipherSuite HIGH:!aNULL:!MD5:!3DES

    # Cabeceras de seguridad
    Header always set Strict-Transport-Security "max-age=31536000"

    DocumentRoot /var/www/html
    ErrorLog  /var/log/httpd/ssl_error.log
    CustomLog /var/log/httpd/ssl_access.log combined
</VirtualHost>

# Redirect HTTP -> HTTPS en puerto ${http_port}
<VirtualHost *:${http_port}>
    ServerName ${SSL_DOMAIN}
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{SERVER_NAME}:${https_port}\$1 [R=301,L]
</VirtualHost>
${_SSL_HTTP_MARCA_APACHE}
EOF

    aputs_success "Archivo SSL creado"
    echo ""

    # Validar sintaxis antes de reiniciar
    aputs_info "Validando configuración de Apache..."
    if httpd -t 2>/dev/null; then
        aputs_success "Sintaxis OK"
    else
        aputs_error "Error en la configuración — verifique el archivo"
        aputs_info  "Comando: httpd -t"
        return 1
    fi
    echo ""

    # Abrir puerto HTTPS en firewall
    ssl_abrir_puerto_firewall "${https_port}"
    echo ""

    # Reiniciar Apache
    aputs_info "Reiniciando httpd..."
    if systemctl restart httpd 2>/dev/null; then
        aputs_success "httpd reiniciado"
    else
        aputs_error "Error al reiniciar httpd"
        aputs_info  "Ver log: journalctl -u httpd -n 20"
        return 1
    fi

    echo ""
    _ssl_actualizar_index "httpd" "${http_port}" "${https_port}"
    echo ""
    aputs_success "Apache HTTPS configurado en puerto ${https_port}"
    aputs_info    "HTTP  : http://localhost:${http_port}  (redirect -> HTTPS)"
    aputs_info    "HTTPS : curl -k https://localhost:${https_port}"
    return 0
}

# 
# NGINX
# 

ssl_http_aplicar_nginx() {
    ssl_mostrar_banner "SSL — Nginx"

    if ! ssl_servicio_instalado nginx; then
        aputs_warning "Nginx no está instalado — omitiendo"
        return 0
    fi

    if ! ssl_cert_existe; then
        aputs_error "Certificado no generado — ejecute primero el Paso 2"
        return 1
    fi

    local http_port
    http_port=$(ssl_leer_puerto_http nginx)
    local https_port
    _ssl_seleccionar_puerto_https "nginx" "${http_port}" https_port

    aputs_info "El puerto HTTP (${http_port}) se mantiene activo con redirect 301 -> HTTPS"
    aputs_info "Se agrega server { listen ${https_port} ssl } como bloque adicional"
    echo ""

    # Verificar si ya está configurado
    if grep -q "${_SSL_HTTP_MARCA_NGINX}" "${SSL_CONF_NGINX}" 2>/dev/null; then
        aputs_warning "SSL de Nginx ya está configurado"
        echo -ne "${YELLOW}[?]${NC} ¿Reaplicar? [s/N]: "
        local resp; read -r resp
        [[ ! "$resp" =~ ^[sS]$ ]] && return 0
        # Eliminar bloque SSL anterior
        _ssl_http_eliminar_bloque_nginx
    fi

    ssl_hacer_backup "${SSL_CONF_NGINX}"
    echo ""

    aputs_info "Agregando bloque SSL a ${SSL_CONF_NGINX}..."

    # El bloque SSL se agrega antes del cierre del bloque http {}
    # Usamos una marca temporal para insertar antes de la última llave
    local bloque_ssl
    bloque_ssl=$(cat << EOF

    ${_SSL_HTTP_MARCA_NGINX}
    # Generado por mainT07.sh — Práctica 7 SSL

    server {
        listen ${https_port} ssl;
        server_name ${SSL_DOMAIN};

        ssl_certificate     ${SSL_CERT};
        ssl_certificate_key ${SSL_KEY};

        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;
        ssl_session_cache   shared:SSL:10m;
        ssl_session_timeout 10m;

        add_header Strict-Transport-Security "max-age=31536000" always;

        location / {
            root  /usr/share/nginx/html;
            index index.html index.htm;
        }

        error_log  /var/log/nginx/ssl_error.log;
        access_log /var/log/nginx/ssl_access.log;
    }

    # Redirect HTTP -> HTTPS
    server {
        listen ${http_port};
        server_name ${SSL_DOMAIN};
        return 301 https://\$host:${https_port}\$request_uri;
    }
    ${_SSL_HTTP_MARCA_NGINX}
EOF
)

    # Insertar el bloque antes de la última } del archivo (cierre de http {})
    # python3 es más confiable que sed para esto
    python3 << NGINXPY
import re, sys

conf_file  = "${SSL_CONF_NGINX}"
https_port = "${https_port}"
http_port  = "${http_port}"
ssl_cert   = "${SSL_CERT}"
ssl_key    = "${SSL_KEY}"
domain     = "${SSL_DOMAIN}"
marca      = "${_SSL_HTTP_MARCA_NGINX}"

with open(conf_file) as f:
    content = f.read()

# Estrategia correcta:
# 1. Agregar server block HTTPS nuevo
# 2. MODIFICAR el server block HTTP existente agregando return 301
#    (no agregar un segundo bloque con el mismo puerto — nginx ignoraria el duplicado)

# Bloque HTTPS
ssl_block = (
    "\n    " + marca + "\n"
    "    server {\n"
    "        listen " + https_port + " ssl;\n"
    "        server_name " + domain + ";\n"
    "        ssl_certificate     " + ssl_cert + ";\n"
    "        ssl_certificate_key " + ssl_key + ";\n"
    "        ssl_protocols       TLSv1.2 TLSv1.3;\n"
    "        ssl_ciphers         HIGH:!aNULL:!MD5;\n"
    "        ssl_session_cache   shared:SSL:10m;\n"
    "        add_header Strict-Transport-Security \"max-age=31536000\" always;\n"
    "        location / {\n"
    "            root  /usr/share/nginx/html;\n"
    "            index index.html index.htm;\n"
    "        }\n"
    "        error_log  /var/log/nginx/ssl_error.log;\n"
    "        access_log /var/log/nginx/ssl_access.log;\n"
    "    }\n"
    "    " + marca + "\n"
)

redirect_line = "        return 301 https://\$host:" + https_port + "\$request_uri;"

# Modificar el server block existente del puerto HTTP
# Buscamos el server{} que contiene "listen <http_port>" y le agregamos return 301
# antes de cualquier location o antes del cierre del bloque
def add_redirect_to_server(content, http_port, redirect_line, marca):
    # Encontrar todos los bloques server{}
    result = []
    i = 0
    modified = False
    while i < len(content):
        # Buscar inicio de server {
        m = re.search(r"\bserver\s*\{", content[i:])
        if not m:
            result.append(content[i:])
            break
        result.append(content[i:i+m.end()])
        i += m.end()
        # Extraer contenido del bloque server{}
        depth = 1
        start = i
        while i < len(content) and depth > 0:
            if content[i] == "{": depth += 1
            elif content[i] == "}": depth -= 1
            i += 1
        block = content[start:i-1]  # sin el }
        # Ver si este server{} escucha en http_port
        if re.search(r"listen\s+" + re.escape(http_port) + r"[;\s]", block) and not modified:
            # Agregar return 301 antes del primer location o antes del cierre
            loc_m = re.search(r"\blocation\s*[/\w]", block)
            if loc_m:
                insert_pos = loc_m.start()
                block = block[:insert_pos] + "    " + marca + " redirect\n" + redirect_line + "\n        " + marca + " redirect\n        " + block[insert_pos:]
            else:
                block = block + "\n        " + marca + " redirect\n" + redirect_line + "\n        " + marca + " redirect\n    "
            modified = True
        result.append(block + "}")
    return "".join(result), modified

new_content, modified = add_redirect_to_server(content, http_port, redirect_line, marca)

if not modified:
    print("  WARN: no se encontro server block con listen " + http_port + " — redirect no aplicado")

# Insertar bloque HTTPS antes del cierre de http{}
m2 = re.search(r"\bhttp\s*\{", new_content)
if not m2:
    print("ERROR: no se encontro bloque http{} en nginx.conf")
    sys.exit(1)

depth = 1
pos = m2.end()
while pos < len(new_content) and depth > 0:
    if new_content[pos] == "{":
        depth += 1
    elif new_content[pos] == "}":
        depth -= 1
    pos += 1

close_pos = pos - 1
new_content = new_content[:close_pos] + ssl_block + new_content[close_pos:]

with open(conf_file, "w") as f:
    f.write(new_content)

print("  HTTPS agregado + redirect HTTP->HTTPS aplicado en server block existente")
print("  Bloque SSL insertado dentro de http { }")
NGINXPY

    if [[ $? -ne 0 ]]; then
        aputs_error "Error al modificar nginx.conf"
        return 1
    fi

    aputs_success "Configuración SSL agregada"
    echo ""

    # Validar sintaxis
    aputs_info "Validando configuración de Nginx..."
    if nginx -t 2>/dev/null; then
        aputs_success "Sintaxis OK"
    else
        aputs_error "Error en nginx.conf"
        aputs_info  "Comando: nginx -t"
        return 1
    fi
    echo ""

    ssl_abrir_puerto_firewall "${https_port}"
    echo ""

    aputs_info "Reiniciando nginx..."
    if systemctl restart nginx 2>/dev/null; then
        aputs_success "nginx reiniciado"
    else
        aputs_error "Error al reiniciar nginx"
        return 1
    fi

    echo ""
    _ssl_actualizar_index "nginx" "${http_port}" "${https_port}"
    echo ""
    aputs_success "Nginx HTTPS configurado en puerto ${https_port}"
    aputs_info    "HTTP  : http://localhost:${http_port}  (redirect -> HTTPS)"
    aputs_info    "HTTPS : curl -k https://localhost:${https_port}"
    return 0
}

# -----------------------------------------------------------------------------
# _ssl_http_eliminar_bloque_nginx
# Elimina el bloque SSL insertado en nginx.conf (para reaplicar o revertir)
# -----------------------------------------------------------------------------
_ssl_http_eliminar_bloque_nginx() {
    local marca_escapada
    marca_escapada=$(echo "${_SSL_HTTP_MARCA_NGINX}" | sed 's/[#=\/]/\\&/g')
    sed -i "/${marca_escapada}/,/${marca_escapada}/d" "${SSL_CONF_NGINX}" 2>/dev/null
    aputs_info "Bloque SSL anterior eliminado de nginx.conf"
}

# 
# TOMCAT
# 

ssl_http_aplicar_tomcat() {
    ssl_mostrar_banner "SSL — Tomcat"

    if ! ssl_servicio_instalado tomcat; then
        aputs_warning "Tomcat no está instalado — omitiendo"
        return 0
    fi

    if ! ssl_cert_existe; then
        aputs_error "Certificado no generado — ejecute primero el Paso 2"
        return 1
    fi

    local server_xml
    server_xml=$(SSL_CONF_TOMCAT)
    local keystore
    keystore=$(SSL_KEYSTORE_TOMCAT)
    local http_port
    http_port=$(ssl_leer_puerto_http tomcat)
    local https_port
    _ssl_seleccionar_puerto_https "tomcat" "${http_port}" https_port

    aputs_info "server.xml detectado:  ${server_xml}"
    aputs_info "Puerto HTTP:           ${http_port}/tcp (redirect -> HTTPS)"
    aputs_info "Puerto HTTPS:          ${https_port}/tcp"
    aputs_info "Keystore destino:      ${keystore}"
    echo ""

    if [[ ! -f "${server_xml}" ]]; then
        aputs_error "No se encontró server.xml en ${server_xml}"
        return 1
    fi

    # Paso 1: Generar keystore PKCS12
    aputs_info "Generando keystore PKCS12..."
    if openssl pkcs12 -export \
        -in  "${SSL_CERT}" \
        -inkey "${SSL_KEY}" \
        -out "${keystore}" \
        -name "${SSL_DOMAIN}" \
        -passout pass:reprobados 2>/dev/null; then
        chmod 640 "${keystore}"
        # Asegurar que el usuario tomcat puede leer el keystore
        if getent group tomcat &>/dev/null; then
            chown root:tomcat "${keystore}"
            aputs_success "Permisos keystore: root:tomcat 640"
        else
            chmod 644 "${keystore}"
            aputs_warning "Grupo tomcat no encontrado — keystore con permisos 644"
        fi
    else
        aputs_error "Error al generar keystore PKCS12"
        return 1
    fi
    echo ""

    # Paso 2: Agregar Connector SSL en server.xml
    ssl_hacer_backup "${server_xml}"
    echo ""

    aputs_info "Agregando Connector HTTPS en server.xml..."

    # Verificar si ya hay un Connector HTTPS
    if grep -q "SSLEnabled=\"true\"" "${server_xml}" 2>/dev/null; then
        # Ya existe — eliminarlo para reinsertar con los datos actuales
        aputs_info "Eliminando Connector HTTPS anterior para actualizar..."
        python3 << RMCONNECTORPY
import re
server_xml = "${server_xml}"
with open(server_xml) as f:
    content = f.read()
content = re.sub(
    r"\s*<!--\s*Practica7 SSL[^>]*-->\s*<Connector[^>]*>.*?</Connector>",
    "", content, flags=re.DOTALL
)
# También eliminar el formato antiguo self-closing por si acaso
content = re.sub(
    r"\s*<!--\s*Practica7 SSL[^>]*-->\s*<Connector[^/]*/\s*>",
    "", content, flags=re.DOTALL
)
with open(server_xml, "w") as f:
    f.write(content)
print("  Connector anterior eliminado")
RMCONNECTORPY
        # Insertar el Connector SSL antes de </Service>
        local conector
        conector="    <!-- Practica7 SSL — Connector HTTPS puerto ${https_port} -->
    <Connector port=\"${https_port}\"
               protocol=\"org.apache.coyote.http11.Http11NioProtocol\"
               SSLEnabled=\"true\"
               maxThreads=\"150\"
               scheme=\"https\"
               secure=\"true\"
               keystoreFile=\"${keystore}\"
               keystorePass=\"reprobados\"
               keystoreType=\"PKCS12\"
               clientAuth=\"false\"
               sslProtocol=\"TLS\"
               sslEnabledProtocols=\"TLSv1.2,TLSv1.3\" />"

        # Insertar el Connector antes de </Service> usando python3
        # sed falla con los caracteres especiales del XML
        python3 << TOMCATPY
server_xml  = "${server_xml}"
https_port  = "${https_port}"
keystore    = "${keystore}"

with open(server_xml) as f:
    content = f.read()

connector = (
    "\n    <!-- Practica7 SSL - Connector HTTPS puerto " + https_port + " -->\n"
    "    <Connector port=\"" + https_port + "\"\n"
    "               protocol=\"org.apache.coyote.http11.Http11NioProtocol\"\n"
    "               SSLEnabled=\"true\"\n"
    "               maxThreads=\"150\"\n"
    "               scheme=\"https\"\n"
    "               secure=\"true\">\n"
    "        <SSLHostConfig>\n"
    "            <Certificate certificateKeystoreFile=\"" + keystore + "\"\n"
    "                         certificateKeystorePassword=\"reprobados\"\n"
    "                         certificateKeystoreType=\"PKCS12\"\n"
    "                         type=\"RSA\" />\n"
    "        </SSLHostConfig>\n"
    "    </Connector>\n"
)

if '</Service>' not in content:
    print("ERROR: no se encontro </Service> en server.xml")
    raise SystemExit(1)

new_content = content.replace('</Service>', connector + '</Service>', 1)

with open(server_xml, 'w') as f:
    f.write(new_content)

print("  Connector HTTPS insertado en server.xml")
TOMCATPY

        if grep -q "SSLEnabled=\"true\"" "${server_xml}"; then
            aputs_success "Connector HTTPS agregado"
        else
            aputs_error "No se pudo agregar el Connector en server.xml"
            return 1
        fi
    fi
    echo ""

    ssl_abrir_puerto_firewall "${https_port}"
    echo ""

    # Agregar redirect HTTP->HTTPS en web.xml de la app ROOT
    # Tomcat no tiene redirect nativo en server.xml — se configura via Security Constraint
    local webxml
    local catalina_home="${CATALINA_HOME:-/usr/share/tomcat}"
    webxml="${catalina_home}/webapps/ROOT/WEB-INF/web.xml"

    if [[ -f "$webxml" ]]; then
        if ! grep -q "Practica7 SSL redirect" "$webxml" 2>/dev/null; then
            aputs_info "Agregando redirect HTTP->HTTPS en web.xml..."
            ssl_hacer_backup "$webxml"

            python3 << WEBXMLPY
import re

webxml = "${webxml}"
https_port = "${https_port}"

with open(webxml) as f:
    content = f.read()

redirect_block = """
  <!-- Practica7 SSL redirect: fuerza HTTPS -->
  <security-constraint>
    <web-resource-collection>
      <web-resource-name>Redirect HTTP to HTTPS</web-resource-name>
      <url-pattern>/*</url-pattern>
    </web-resource-collection>
    <user-data-constraint>
      <transport-guarantee>CONFIDENTIAL</transport-guarantee>
    </user-data-constraint>
  </security-constraint>
"""

if "</web-app>" in content:
    content = content.replace("</web-app>", redirect_block + "</web-app>", 1)
    with open(webxml, "w") as f:
        f.write(content)
    print("  Redirect CONFIDENTIAL agregado en web.xml")
else:
    print("  WARN: no se encontro </web-app> en web.xml")
WEBXMLPY
            aputs_success "Redirect HTTP->HTTPS configurado en web.xml"
        else
            aputs_info "Redirect ya configurado en web.xml"
        fi
    else
        # web.xml no existe — crearlo con el mínimo necesario
        aputs_info "web.xml no encontrado — creando estructura mínima..."
        mkdir -p "$(dirname "$webxml")"
        cat > "$webxml" << 'WEBXMLBASE'
<?xml version="1.0" encoding="UTF-8"?>
<web-app xmlns="https://jakarta.ee/xml/ns/jakartaee"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="https://jakarta.ee/xml/ns/jakartaee
         https://jakarta.ee/xml/ns/jakartaee/web-app_6_0.xsd"
         version="6.0">
</web-app>
WEBXMLBASE
        aputs_success "web.xml base creado"
        # Ahora agregar el security-constraint de redirect
        python3 << WEBXMLPY2
webxml = "${webxml}"
https_port = "${https_port}"
with open(webxml) as f:
    content = f.read()
redirect_block = """
  <!-- Practica7 SSL redirect -->
  <security-constraint>
    <web-resource-collection>
      <web-resource-name>Redirect HTTP to HTTPS</web-resource-name>
      <url-pattern>/*</url-pattern>
    </web-resource-collection>
    <user-data-constraint>
      <transport-guarantee>CONFIDENTIAL</transport-guarantee>
    </user-data-constraint>
  </security-constraint>
"""
content = content.replace("</web-app>", redirect_block + "</web-app>", 1)
with open(webxml, "w") as f:
    f.write(content)
print("  Redirect CONFIDENTIAL agregado en web.xml creado")
WEBXMLPY2
        aputs_success "Redirect HTTP->HTTPS configurado"
    fi
    echo ""

    aputs_info "Reiniciando tomcat..."
    systemctl stop tomcat 2>/dev/null || true
    sleep 2
    if systemctl start tomcat 2>/dev/null; then
        # Tomcat tarda en inicializar los Connectors — esperar hasta 30s
        aputs_info "Esperando que Tomcat inicialice el Connector SSL..."
        local intentos=0
        local listo=false
        while (( intentos < 15 )); do
            sleep 2
            intentos=$(( intentos + 1 ))
            if ss -tlnp 2>/dev/null | grep -q ":${https_port}"; then
                listo=true
                break
            fi
            printf "    Intento %d/15 — puerto %s aún no disponible...\n" "$intentos" "${https_port}"
        done

        if $listo; then
            aputs_success "tomcat activo — puerto ${https_port} listo"
        else
            aputs_warning "Tomcat arrancó pero el puerto ${https_port} no responde"
            aputs_info   "Verificando logs de error..."
            journalctl -u tomcat -n 15 --no-pager 2>/dev/null | grep -i "error\|exception\|ssl\|keystore" | sed "s/^/    /" || true
            aputs_info   "Log completo: journalctl -u tomcat -n 30"
        fi
    else
        aputs_error "Error al iniciar tomcat"
        journalctl -u tomcat -n 20 --no-pager 2>/dev/null | sed "s/^/    /"
        return 1
    fi

    echo ""
    _ssl_actualizar_index "tomcat" "${http_port}" "${https_port}"
    echo ""
    aputs_success "Tomcat HTTPS configurado en puerto ${https_port}"
    aputs_info    "HTTP  : http://localhost:${http_port}  (redirect -> HTTPS)"
    aputs_info    "HTTPS : curl -k https://localhost:${https_port}"
    return 0
}

# 
# ORQUESTADOR
# 

ssl_http_aplicar_todos() {
    ssl_mostrar_banner "SSL — Configurar HTTPS en servicios HTTP"

    if ! ssl_cert_existe; then
        aputs_error "Certificado no generado"
        aputs_info  "Ejecute primero: Paso 2 — Generar certificado SSL"
        return 1
    fi

    # Detectar servicios instalados
    local servicios_disponibles=()
    ssl_servicio_instalado httpd  && servicios_disponibles+=("Apache (httpd)")
    ssl_servicio_instalado nginx  && servicios_disponibles+=("Nginx")
    ssl_servicio_instalado tomcat && servicios_disponibles+=("Tomcat")

    if [[ ${#servicios_disponibles[@]} -eq 0 ]]; then
        aputs_error "No hay servicios HTTP instalados"
        aputs_info  "Ejecute primero: Paso 5 — Instalar HTTP"
        return 1
    fi

    aputs_info "Servicios HTTP detectados:"
    echo ""
    for svc in "${servicios_disponibles[@]}"; do
        printf "  ${GREEN}[●]${NC} %s\n" "$svc"
    done
    echo ""

    # Preguntar qué servicios configurar
    local aplicar_apache=false
    local aplicar_nginx=false
    local aplicar_tomcat=false

    if ssl_servicio_instalado httpd; then
        echo -ne "  ${CYAN}[?]${NC} ¿Configurar SSL en Apache? [S/n]: "
        local r; read -r r
        [[ ! "$r" =~ ^[nN]$ ]] && aplicar_apache=true
    fi

    if ssl_servicio_instalado nginx; then
        echo -ne "  ${CYAN}[?]${NC} ¿Configurar SSL en Nginx?  [S/n]: "
        local r; read -r r
        [[ ! "$r" =~ ^[nN]$ ]] && aplicar_nginx=true
    fi

    if ssl_servicio_instalado tomcat; then
        echo -ne "  ${CYAN}[?]${NC} ¿Configurar SSL en Tomcat? [S/n]: "
        local r; read -r r
        [[ ! "$r" =~ ^[nN]$ ]] && aplicar_tomcat=true
    fi

    echo ""
    draw_line
    echo ""

    local errores=0

    $aplicar_apache && { ssl_http_aplicar_apache || (( errores++ )); echo ""; }
    $aplicar_nginx  && { ssl_http_aplicar_nginx  || (( errores++ )); echo ""; }
    $aplicar_tomcat && { ssl_http_aplicar_tomcat || (( errores++ )); echo ""; }

    draw_line
    if (( errores == 0 )); then
        aputs_success "SSL aplicado correctamente a todos los servicios seleccionados"
    else
        aputs_warning "${errores} servicio(s) con errores — revise los mensajes anteriores"
    fi

    return $(( errores > 0 ? 1 : 0 ))
}

# -----------------------------------------------------------------------------
# ssl_http_estado
#
# Muestra el estado SSL de los tres servicios sin modificar nada.
# -----------------------------------------------------------------------------
ssl_http_estado() {
    aputs_info "Estado SSL de servicios HTTP:"
    echo ""

    # Apache
    if ssl_servicio_instalado httpd; then
        local apache_ssl="NO"
        [[ -f "${SSL_CONF_APACHE_SSL}" ]] && \
            grep -q "${_SSL_HTTP_MARCA_APACHE}" "${SSL_CONF_APACHE_SSL}" 2>/dev/null && \
            apache_ssl="YES"
        local apache_up="${RED}inactivo${NC}"
        systemctl is-active --quiet httpd 2>/dev/null && apache_up="${GREEN}activo${NC}"
        printf "  Apache  — SSL: %-5s | " "$apache_ssl"
        echo -e "Estado: ${apache_up}"
    else
        printf "  Apache  — ${GRAY}no instalado${NC}\n"
    fi

    # Nginx
    if ssl_servicio_instalado nginx; then
        local nginx_ssl="NO"
        grep -q "${_SSL_HTTP_MARCA_NGINX}" "${SSL_CONF_NGINX}" 2>/dev/null && nginx_ssl="YES"
        local nginx_up="${RED}inactivo${NC}"
        systemctl is-active --quiet nginx 2>/dev/null && nginx_up="${GREEN}activo${NC}"
        printf "  Nginx   — SSL: %-5s | " "$nginx_ssl"
        echo -e "Estado: ${nginx_up}"
    else
        printf "  Nginx   — ${GRAY}no instalado${NC}\n"
    fi

    # Tomcat
    if ssl_servicio_instalado tomcat; then
        local tomcat_ssl="NO"
        grep -q "SSLEnabled=\"true\"" "$(SSL_CONF_TOMCAT)" 2>/dev/null && tomcat_ssl="YES"
        local tomcat_up="${RED}inactivo${NC}"
        systemctl is-active --quiet tomcat 2>/dev/null && tomcat_up="${GREEN}activo${NC}"
        printf "  Tomcat  — SSL: %-5s | " "$tomcat_ssl"
        echo -e "Estado: ${tomcat_up}"
    else
        printf "  Tomcat  — ${GRAY}no instalado${NC}\n"
    fi

    echo ""
}

# -----------------------------------------------------------------------------
# ssl_menu_http — submenú interactivo del módulo SSL HTTP
# -----------------------------------------------------------------------------
ssl_menu_http() {
    while true; do
        clear
        ssl_mostrar_banner "Tarea 07 — SSL/HTTPS en servicios HTTP"

        ssl_http_estado

        echo -e "  ${BLUE}1)${NC} Configurar SSL en todos los servicios instalados"
        echo -e "  ${BLUE}2)${NC} Configurar SSL solo en Apache"
        echo -e "  ${BLUE}3)${NC} Configurar SSL solo en Nginx"
        echo -e "  ${BLUE}4)${NC} Configurar SSL solo en Tomcat"
        echo -e "  ${BLUE}0)${NC} Volver"
        echo ""

        local op
        read -rp "  Opción: " op

        case "$op" in
            1) ssl_http_aplicar_todos;   pause ;;
            2) ssl_http_aplicar_apache;  pause ;;
            3) ssl_http_aplicar_nginx;   pause ;;
            4) ssl_http_aplicar_tomcat;  pause ;;
            0) return 0 ;;
            *) aputs_error "Opción inválida"; sleep 1 ;;
        esac
    done
}

export -f _ssl_seleccionar_puerto_https
export -f _ssl_actualizar_index
export -f ssl_http_aplicar_apache
export -f ssl_http_aplicar_nginx
export -f ssl_http_aplicar_tomcat
export -f ssl_http_aplicar_todos
export -f ssl_http_estado
export -f ssl_menu_http
export -f _ssl_http_eliminar_bloque_nginx