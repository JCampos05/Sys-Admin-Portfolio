#
# HTTP-SSL.ps1
#
. "$PSScriptRoot\utils.ps1"  # garantiza aputs_*, draw_line, check_connectivity en este scope


#Requires -Version 5.1

# (guardia eliminada — dot-source controlado por mainSSL.ps1)

function _ssl_seleccionar_puerto_https {
    param(
        [string]$Servicio,
        [int]$HttpPort,
        [ref]$VarDestino
    )

    $puertoSugerido = ssl_puerto_https $HttpPort

    Write-Host ""
    aputs_info "Puerto HTTP activo    : ${HttpPort}/tcp"
    aputs_info "Puerto HTTPS sugerido : ${puertoSugerido}/tcp"
    Write-Host ""

    $resp = Read-MenuInput "¿Usar puerto HTTPS ${puertoSugerido}? [S/n/otro número]"

    # Enter o S -> usar el sugerido
    if ([string]::IsNullOrEmpty($resp) -or $resp -match '^[sS]$') {
        $VarDestino.Value = $puertoSugerido
        aputs_success "Puerto HTTPS: ${puertoSugerido}/tcp"
        Write-Host ""
        return
    }

    # Si ingresaron directamente un número, usarlo como candidato
    $candidato = ""
    if ($resp -match '^\d+$') { $candidato = $resp }

    # Pedir puerto con validación
    while ($true) {
        if ($candidato -ne "") {
            $puertoElegido = $candidato
            $candidato = ""
        } else {
            $puertoElegido = Read-MenuInput "Puerto HTTPS [1-65535, distinto de ${HttpPort}]"
        }

        if (-not ($puertoElegido -match '^\d+$') -or
            [int]$puertoElegido -lt 1 -or [int]$puertoElegido -gt 65535) {
            aputs_error "Puerto inválido — debe ser un número entre 1 y 65535"
            Write-Host ""
            continue
        }

        if ([int]$puertoElegido -eq $HttpPort) {
            aputs_error "El puerto HTTPS no puede ser el mismo que el HTTP (${HttpPort})"
            Write-Host ""
            continue
        }

        # Advertir si el puerto ya está en uso
        $enUso = Get-NetTCPConnection -LocalPort ([int]$puertoElegido) -State Listen `
            -ErrorAction SilentlyContinue
        if ($enUso) {
            aputs_warning "El puerto ${puertoElegido} ya está en uso"
            $forzar = Read-MenuInput "¿Continuar de todas formas? [s/N]"
            if ($forzar -notmatch '^[sS]$') { Write-Host ""; continue }
        }

        break
    }

    $VarDestino.Value = [int]$puertoElegido
    aputs_success "Puerto HTTPS seleccionado: ${puertoElegido}/tcp"
    Write-Host ""
}

function _ssl_actualizar_index {
    param(
        [string]$Servicio,
        [int]$HttpPort,
        [int]$HttpsPort
    )

    # Para Tomcat: refrescar la ruta del webroot porque puede haberse instalado
    # después de que utilsHTTP.ps1 inicializó HTTP_DIR_TOMCAT con el fallback
    # C:\ProgramData\Tomcat9 en lugar del real C:\Program Files\...\Tomcat 10.1
    if ($Servicio.ToLower() -eq "tomcat" -and $Script:HTTP_CONF_TOMCAT -and (Test-Path $Script:HTTP_CONF_TOMCAT)) {
        $tomcatBase  = Split-Path (Split-Path $Script:HTTP_CONF_TOMCAT)
        $webappsReal = Join-Path $tomcatBase "webapps\ROOT"
        if (Test-Path $webappsReal) {
            $Script:HTTP_DIR_TOMCAT = $webappsReal
        }
    }

    # Obtener el webroot del servicio
    $webroot = ""
    switch ($Servicio.ToLower()) {
        "iis"    { $webroot = $Script:HTTP_DIR_IIS    }
        "apache" { $webroot = $Script:HTTP_DIR_APACHE }
        "nginx"  { $webroot = $Script:HTTP_DIR_NGINX  }
        "tomcat" { $webroot = $Script:HTTP_DIR_TOMCAT }
    }
    if ([string]::IsNullOrEmpty($webroot) -or -not (Test-Path $webroot)) { return }

    $indexFile = Join-Path $webroot "index.html"
    if (-not (Test-Path $indexFile)) { return }

    # Obtener CN del certificado
    $certCN = $Script:SSL_DOMAIN
    try {
        $certCN = (openssl x509 -in $Script:SSL_CERT -noout -subject 2>&1) `
            -replace ".*CN\s*=\s*([^,/]+).*", '$1' | ForEach-Object { $_.Trim() }
        if ([string]::IsNullOrEmpty($certCN)) { $certCN = $Script:SSL_DOMAIN }
    } catch {}

    # Nombre para mostrar
    $nombreDisplay = switch ($Servicio.ToLower()) {
        "iis"    { "IIS (Internet Information Services)" }
        "apache" { "Apache HTTP Server"                  }
        "nginx"  { "Nginx"                               }
        "tomcat" { "Apache Tomcat"                       }
        default  { $Servicio                             }
    }

    # Versión del servicio (igual que P6 — leer desde los binarios)
    $version = ""
    try {
        switch ($Servicio.ToLower()) {
            "iis"    { $version = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" -EA SilentlyContinue).VersionString }
            "apache" {
                $apacheExe = Join-Path (Split-Path (Split-Path $Script:HTTP_CONF_APACHE)) "bin\httpd.exe"
                if (Test-Path $apacheExe) {
                    $v = & $apacheExe -v 2>&1 | Select-String "Apache/"
                    if ($v) { $version = ($v -replace ".*Apache/([^\s]+).*", '$1').Trim() }
                }
            }
            "nginx"  {
                $nginxDir = Split-Path (Split-Path $Script:HTTP_CONF_NGINX)
                $nginxExe = Join-Path $nginxDir "nginx.exe"
                if (Test-Path $nginxExe) {
                    $v = & $nginxExe -v 2>&1
                    if ($v) { $version = ($v -replace ".*nginx/([^\s]+).*", '$1').Trim() }
                }
            }
            "tomcat" {
                $v = Get-Service -Name "Tomcat*" -EA SilentlyContinue | Select-Object -First 1
                if ($v) { $version = $v.DisplayName -replace "[^0-9\.]", "" }
            }
        }
    } catch {}
    if ([string]::IsNullOrEmpty($version)) { $version = "Windows Server" }

    $fecha = Get-Date -Format "yyyy-MM-dd HH:mm"

    aputs_info "Actualizando index.html con puertos SSL..."

    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>$nombreDisplay</title>
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
    <h1>$nombreDisplay</h1>
    <p>Despliegue exitoso</p>
    <table>
        <tr><td>Version</td>      <td>$version</td></tr>
        <tr><td>Puerto HTTP</td>  <td>${HttpPort}/tcp -> redirect HTTPS</td></tr>
        <tr><td>Puerto HTTPS</td> <td class="ssl">${HttpsPort}/tcp (SSL/TLS activo)</td></tr>
        <tr><td>Certificado</td>  <td class="cert">$certCN (autofirmado)</td></tr>
        <tr><td>Webroot</td>      <td>$webroot</td></tr>
        <tr><td>Fecha</td>        <td>$fecha</td></tr>
    </table>
</body>
</html>
"@

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($indexFile, $html, $utf8NoBom)
    aputs_success "index.html actualizado — HTTP:${HttpPort} -> HTTPS:${HttpsPort} ($certCN)"
}

# 
# IIS
# 
function ssl_http_aplicar_iis {
    ssl_mostrar_banner "SSL — IIS"

    if (-not (ssl_servicio_instalado "iis")) {
        aputs_warning "IIS no está instalado — omitiendo"
        return $true
    }
    if (-not (ssl_cert_existe)) {
        aputs_error "Certificado no generado — ejecute primero el Paso 2"
        return $false
    }

    # Asegurar que el certificado está en el almacén de Windows
    if (-not (ssl_cert_importado)) {
        aputs_info "Importando certificado al almacén de Windows..."
        try {
            $secPass = ConvertTo-SecureString $Script:SSL_PFX_PASS -AsPlainText -Force
            $cert = Import-PfxCertificate `
                -FilePath $Script:SSL_PFX `
                -CertStoreLocation "Cert:\LocalMachine\My" `
                -Password $secPass `
                -Exportable `
                -ErrorAction Stop
            $Script:SSL_THUMBPRINT = $cert.Thumbprint
            # Marcar como de confianza
            Import-Certificate -FilePath $Script:SSL_CERT `
                -CertStoreLocation "Cert:\LocalMachine\Root" `
                -ErrorAction SilentlyContinue | Out-Null
            aputs_success "Certificado importado — Thumbprint: $($Script:SSL_THUMBPRINT)"
        }
        catch {
            aputs_error "Error al importar certificado: $($_.Exception.Message)"
            return $false
        }
    }

    $httpPort  = ssl_leer_puerto_http "iis"
    $httpsPort = 0
    _ssl_seleccionar_puerto_https "iis" $httpPort ([ref]$httpsPort)
    aputs_info "El puerto HTTP ($httpPort) se mantiene activo con redirect -> HTTPS"

    try {
        Import-Module WebAdministration -ErrorAction Stop
    }
    catch {
        aputs_error "Módulo WebAdministration no disponible"
        aputs_info  "Instale con: Install-WindowsFeature Web-Scripting-Tools"
        return $false
    }

    $siteName = "Default Web Site"

    # Backup de applicationHost.config
    ssl_hacer_backup $Script:HTTP_CONF_IIS

    # Eliminar bindings HTTPS existentes en ese puerto (pueden tener HostHeader incorrecto)
    # y recrear sin HostHeader para permitir acceso por IP
    aputs_info "Configurando binding HTTPS en puerto $httpsPort (sin HostHeader)..."
    try {
        Get-WebBinding -Name $siteName -Protocol "https" -Port $httpsPort `
            -ErrorAction SilentlyContinue | Remove-WebBinding -ErrorAction SilentlyContinue
        New-WebBinding -Name $siteName `
            -Protocol "https" `
            -Port $httpsPort `
            -IPAddress "*" `
            -ErrorAction Stop
        aputs_success "Binding HTTPS agregado"
    }
    catch {
        aputs_error "Error al agregar binding HTTPS: $($_.Exception.Message)"
        return $false
    }

    # Asociar el certificado al binding HTTPS
    aputs_info "Asociando certificado al binding HTTPS..."
    try {
        $binding = Get-WebBinding -Name $siteName `
            -Protocol "https" -Port $httpsPort
        $binding.AddSslCertificate($Script:SSL_THUMBPRINT, "My")
        aputs_success "Certificado asociado al binding"
    }
    catch {
        # Si ya está asociado, el error es esperado
        if ($_.Exception.Message -match "already") {
            aputs_info "Certificado ya estaba asociado"
        }
        else {
            aputs_warning "No se pudo asociar con WebAdministration — intentando con netsh..."
            $appId = "{$([guid]::NewGuid().ToString().ToUpper())}"
            netsh http add sslcert `
                ipport="0.0.0.0:$httpsPort" `
                certhash=$Script:SSL_THUMBPRINT `
                appid="$appId" | Out-Null
            if ($LASTEXITCODE -eq 0) {
                aputs_success "Certificado asociado con netsh"
            }
            else {
                aputs_error "No se pudo asociar el certificado al puerto $httpsPort"
                return $false
            }
        }
    }

    # Configurar redirect HTTP -> HTTPS usando HttpRedirect nativo de IIS
    aputs_info "Configurando redirect HTTP -> HTTPS (HttpRedirect nativo)..."
    $webConfig = Join-Path $Script:HTTP_DIR_IIS "web.config"
    $marcaSSL  = "<!-- Practica7 SSL Redirect -->"

    # Verificar si URL Rewrite está instalado
    $urlRewriteOk = $false
    try {
        $wr = Get-WebConfiguration -Filter "system.webServer/rewrite" -PSPath "IIS:\" -ErrorAction SilentlyContinue
        $urlRewriteOk = ($null -ne $wr)
    } catch {}

    if (-not (Test-Path $webConfig) -or
        -not ((Get-Content $webConfig -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($marcaSSL))) {

        if ($urlRewriteOk) {
            # URL Rewrite disponible — usar redirect 301 limpio
            $redirectXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
    <system.webServer>
        $marcaSSL
        <rewrite>
            <rules>
                <rule name="HTTP to HTTPS Redirect" stopProcessing="true">
                    <match url="(.*)" />
                    <conditions>
                        <add input="{HTTPS}" pattern="^OFF$" />
                    </conditions>
                    <action type="Redirect"
                            url="https://{HTTP_HOST}:$($httpsPort){REQUEST_URI}"
                            redirectType="Permanent" />
                </rule>
            </rules>
        </rewrite>
    </system.webServer>
</configuration>
"@
        } else {
            # URL Rewrite NO instalado — usar httpRedirect nativo de IIS
            # httpRedirect es una característica de IIS base, no requiere módulos extra
            aputs_info "URL Rewrite no instalado — usando httpRedirect nativo de IIS"
            $redirectXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
    <system.webServer>
        $marcaSSL
        <httpRedirect enabled="true"
                      destination="https://{HTTP_HOST}:$($httpsPort)/"
                      exactDestination="false"
                      httpResponseStatus="Permanent" />
    </system.webServer>
</configuration>
"@
        }

        try {
            Set-Content -Path $webConfig -Value $redirectXml -Encoding UTF8 -Force
            aputs_success "Redirect HTTP->HTTPS configurado en web.config"
        }
        catch {
            aputs_warning "No se pudo crear web.config: $($_.Exception.Message)"
        }
    }
    else {
        aputs_info "Redirect ya configurado"
    }

    # Abrir puerto HTTPS en firewall
    ssl_abrir_puerto_firewall $httpsPort

    # Reiniciar SOLO W3SVC — NO usar iisreset (mata FTPSVC y deja FTP Site detenido)
    aputs_info "Reiniciando W3SVC (preservando FTP)..."
    $appcmdIIS = "$env:SystemRoot\system32\inetsrv\appcmd.exe"
    try {
        Restart-Service -Name "W3SVC" -Force -ErrorAction Stop
        Start-Sleep -Seconds 3
        if (-not (check_service_active "W3SVC")) {
            aputs_error "W3SVC no levantó — revise el Visor de Eventos"
            return $false
        }
        aputs_success "W3SVC reiniciado"
    } catch {
        aputs_warning "Restart-Service W3SVC falló: $($_.Exception.Message) — usando iisreset"
        iisreset /restart /noforce 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        if (-not (check_service_active "W3SVC")) {
            aputs_error "IIS no levantó — revise el Visor de Eventos"
            return $false
        }
    }
    # Restaurar FTP Site si quedó detenido por el reinicio
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $ftpSite = Get-Website | Where-Object { $_.Name -match "FTP" } | Select-Object -First 1
        if ($ftpSite) {
            $ftpBinding = Get-WebBinding -Name $ftpSite.Name -Protocol "ftp" -ErrorAction SilentlyContinue
            if (-not $ftpBinding) {
                New-WebBinding -Name $ftpSite.Name -Protocol ftp -Port 21 -IPAddress "*" -ErrorAction SilentlyContinue | Out-Null
                aputs_success "Binding FTP *:21 restaurado en $($ftpSite.Name)"
            }
            if ((Get-Website -Name $ftpSite.Name).State -ne "Started") {
                & $appcmdIIS start site /site.name:"$($ftpSite.Name)" 2>$null | Out-Null
                Start-Sleep -Seconds 2
            }
            if ((Get-Website -Name $ftpSite.Name).State -eq "Started") {
                aputs_success "FTP Site $($ftpSite.Name) activo"
            } else {
                aputs_warning "FTP Site no inició — verifique manualmente"
            }
        }
    } catch {}

    Write-Host ""
    _ssl_actualizar_index "iis" $httpPort $httpsPort
    Write-Host ""
    aputs_success "IIS HTTPS configurado en puerto $httpsPort"
    aputs_info    "HTTP  : http://localhost:$httpPort  (redirect -> HTTPS)"
    aputs_info    "HTTPS : curl.exe -k https://localhost:$httpsPort"
    return $true
}

function ssl_http_aplicar_apache {
    ssl_mostrar_banner "SSL — Apache (httpd)"

    if (-not (ssl_servicio_instalado "apache")) {
        aputs_warning "Apache no está instalado — omitiendo"
        return $true
    }
    if (-not (ssl_cert_existe)) {
        aputs_error "Certificado no generado — ejecute primero el Paso 2"
        return $false
    }

    $httpPort  = ssl_leer_puerto_http "apache"
    $httpsPort = 0
    _ssl_seleccionar_puerto_https "apache" $httpPort ([ref]$httpsPort)
    aputs_info "El puerto HTTP ($httpPort) se mantiene activo con redirect -> HTTPS"
    aputs_info "Se agrega Listen 0.0.0.0:$httpsPort en ssl_reprobados.conf"
    Write-Host ""

    # Verificar mod_ssl
    $apacheDir = Split-Path (Split-Path $Script:HTTP_CONF_APACHE)
    $modSsl    = Join-Path $apacheDir "modules\mod_ssl.so"
    if (-not (Test-Path $modSsl)) {
        aputs_error "mod_ssl.so no encontrado en $modSsl"
        aputs_info  "Apache para Windows debe incluir mod_ssl (disponible en httpd.apache.org)"
        return $false
    }

    # Asegurar que LoadModule ssl_module está activo en httpd.conf
    $confApache = Get-Content $Script:HTTP_CONF_APACHE -Raw
    if ($confApache -match '#\s*LoadModule ssl_module') {
        aputs_info "Habilitando mod_ssl en httpd.conf..."
        ssl_hacer_backup $Script:HTTP_CONF_APACHE
        $confApache = $confApache -replace '#(\s*LoadModule ssl_module)', '$1'
        Set-Content -Path $Script:HTTP_CONF_APACHE -Value $confApache -Encoding UTF8
        aputs_success "mod_ssl habilitado"
    }

    # Deshabilitar el ssl.conf por defecto si existe (igual que en Linux)
    $sslConfDefault = Join-Path (Split-Path $Script:HTTP_CONF_APACHE -Parent) "extra\httpd-ssl.conf"
    if (Test-Path $sslConfDefault) {
        if ($confApache -match 'Include.*httpd-ssl\.conf') {
            ssl_hacer_backup $Script:HTTP_CONF_APACHE
            $confApache = $confApache -replace '(?m)^(\s*Include.*httpd-ssl\.conf)', '#$1'
            Set-Content -Path $Script:HTTP_CONF_APACHE -Value $confApache -Encoding UTF8
            aputs_info "httpd-ssl.conf por defecto deshabilitado"
        }
    }

    $confApacheText = [System.IO.File]::ReadAllText($Script:HTTP_CONF_APACHE)
    if ($confApacheText -match '(?m)^Include\s+conf/extra/httpd-ahssl\.conf') {
        aputs_info "Deshabilitando httpd-ahssl.conf (interfiere con SSL en puerto 443)..."
        $confApacheText = $confApacheText -replace `
            '(?m)^(Include\s+conf/extra/httpd-ahssl\.conf)', '# [P7] $1'
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Script:HTTP_CONF_APACHE, $confApacheText, $utf8NoBom)
        aputs_success "httpd-ahssl.conf deshabilitado en httpd.conf"
    }

    # Crear archivo SSL dedicado
    $confSSLDir = Split-Path $Script:HTTP_CONF_APACHE -Parent
    # Actualizar la constante con la ruta real detectada
    $Script:SSL_CONF_APACHE_SSL = Join-Path $confSSLDir "ssl_reprobados.conf"

    # Derivar DocumentRoot desde la ruta real del httpd.conf del servicio
    # HTTP_DIR_APACHE puede apuntar a AppData si se instaló con choco
    # pero el servicio puede estar corriendo desde C:\Apache24
    $apacheRootReal = Split-Path $confSSLDir
    $docRootReal = $Script:HTTP_DIR_APACHE
    # Leer DocumentRoot directamente del httpd.conf activo
    if (Test-Path $Script:HTTP_CONF_APACHE) {
        $drLine = Get-Content $Script:HTTP_CONF_APACHE |
            Where-Object { $_ -match '^\s*DocumentRoot\s+"' } | Select-Object -First 1
        if ($drLine -match 'DocumentRoot\s+"([^"]+)"') {
            $docRootReal = $Matches[1]
            $Script:HTTP_DIR_APACHE = $docRootReal -replace '/', '\'
        }
    }
    # Fallback: htdocs junto al httpd.conf
    if (-not $docRootReal -or -not (Test-Path ($docRootReal -replace '/','\'))) {
        $htdocsFallback = Join-Path $apacheRootReal "htdocs"
        if (Test-Path $htdocsFallback) {
            $docRootReal = $htdocsFallback -replace '\\', '/'
            $Script:HTTP_DIR_APACHE = $htdocsFallback
        }
    }
    $docRootFwd = $docRootReal -replace '\\', '/'

    # Verificar si ya está configurado
    if (Test-Path $Script:SSL_CONF_APACHE_SSL) {
        $contenidoSSL = Get-Content $Script:SSL_CONF_APACHE_SSL -Raw -ErrorAction SilentlyContinue
        if ($contenidoSSL -match [regex]::Escape($Script:SSL_MARCA_APACHE)) {
            aputs_warning "SSL de Apache ya está configurado"
            $resp = Read-MenuInput "¿Reaplicar? [s/N]"
            if ($resp -notmatch '^[Ss]$') { return $true }
            Remove-Item $Script:SSL_CONF_APACHE_SSL -Force
        }
    }

    ssl_hacer_backup $Script:HTTP_CONF_APACHE
    Write-Host ""

    # Habilitar mod_headers, mod_ssl, mod_socache_shmcb si están comentados
    if (Test-Path $Script:HTTP_CONF_APACHE) {
        $httpdText = [System.IO.File]::ReadAllText($Script:HTTP_CONF_APACHE)
        $modified = $false
        foreach ($modName in @("headers_module modules/mod_headers.so",
                               "ssl_module modules/mod_ssl.so",
                               "socache_shmcb_module modules/mod_socache_shmcb.so",
                               "rewrite_module modules/mod_rewrite.so")) {
            $modShort = ($modName -split ' ')[0]
            if ($httpdText -match "#LoadModule\s+$modShort") {
                $httpdText = $httpdText -replace "#(LoadModule\s+$modShort)", '$1'
                $modified = $true
                aputs_success "Modulo habilitado: $modShort"
            }
        }
        if ($modified) {
            [System.IO.File]::WriteAllText($Script:HTTP_CONF_APACHE, $httpdText,
                [System.Text.Encoding]::UTF8)
        }
    }
    Write-Host ""

    aputs_info "Creando $($Script:SSL_CONF_APACHE_SSL)..."

    # Rutas con barras hacia adelante (Apache en Windows las necesita así)
    $certFwd = $Script:SSL_CERT -replace '\\', '/'
    $keyFwd  = $Script:SSL_KEY  -replace '\\', '/'

    $confSSL = @"
$($Script:SSL_MARCA_APACHE)
# Generado por mainSSL.ps1 — Práctica 7 SSL

# VirtualHost HTTPS en puerto $httpsPort
# Listen 0.0.0.0:puerto — fuerza escucha en TODAS las interfaces (no solo loopback)
# Sin la IP explícita, Apache en Windows puede ligar solo a 127.0.0.1
# cuando hay múltiples interfaces de red activas
Listen 0.0.0.0:${httpsPort}

<VirtualHost *:${httpsPort}>
    ServerName $($Script:SSL_DOMAIN)

    SSLEngine on
    SSLCertificateFile    "$certFwd"
    SSLCertificateKeyFile "$keyFwd"

    SSLProtocol all -SSLv2 -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite HIGH:!aNULL:!MD5:!3DES

    Header always set Strict-Transport-Security "max-age=31536000"

    DocumentRoot "$docRootFwd"
    ErrorLog  "logs/ssl_error.log"
    CustomLog "logs/ssl_access.log" combined
</VirtualHost>

# Redirect HTTP -> HTTPS en puerto $httpPort
<VirtualHost *:${httpPort}>
    ServerName $($Script:SSL_DOMAIN)
    RewriteEngine On
    RewriteRule ^ https://%{HTTP_HOST}:${httpsPort}%{REQUEST_URI} [R=301,L]
</VirtualHost>
$($Script:SSL_MARCA_APACHE)
"@

    Set-Content -Path $Script:SSL_CONF_APACHE_SSL -Value $confSSL -Encoding UTF8
    aputs_success "Archivo SSL creado"
    Write-Host ""

    # Agregar Include en httpd.conf si no existe
    $confActual = Get-Content $Script:HTTP_CONF_APACHE -Raw
    $includeLinea = "Include conf/ssl_reprobados.conf"
    if ($confActual -notmatch [regex]::Escape("ssl_reprobados.conf")) {
        Add-Content -Path $Script:HTTP_CONF_APACHE -Value "`n$includeLinea" -Encoding UTF8
        aputs_success "Include agregado en httpd.conf"
    }

    # Abrir puerto
    ssl_abrir_puerto_firewall $httpsPort

    # Validar y reiniciar
    aputs_info "Validando configuración de Apache..."
    $apacheExe = Join-Path $apacheDir "bin\httpd.exe"
    if (Test-Path $apacheExe) {
        $test = & $apacheExe -t 2>&1
        if ($LASTEXITCODE -eq 0) {
            aputs_success "Sintaxis OK"
        }
        else {
            aputs_error "Error en la configuración:"
            $test | ForEach-Object { Write-Host "  $_" }
            return $false
        }
    }
    Write-Host ""

    if (http_reiniciar_servicio "apache") {
        Write-Host ""
        _ssl_actualizar_index "apache" $httpPort $httpsPort
        Write-Host ""
        aputs_success "Apache HTTPS configurado en puerto $httpsPort"
        aputs_info    "HTTP  : http://localhost:$httpPort  (redirect -> HTTPS)"
        aputs_info    "HTTPS : curl.exe -k https://localhost:$httpsPort"
        return $true
    }
    return $false
}

function ssl_http_aplicar_nginx {
    ssl_mostrar_banner "SSL — Nginx"

    if (-not (ssl_servicio_instalado "nginx")) {
        aputs_warning "Nginx no está instalado — omitiendo"
        return $true
    }
    if (-not (ssl_cert_existe)) {
        aputs_error "Certificado no generado — ejecute primero el Paso 2"
        return $false
    }

    $httpPort  = ssl_leer_puerto_http "nginx"
    $httpsPort = 0
    _ssl_seleccionar_puerto_https "nginx" $httpPort ([ref]$httpsPort)
    aputs_info "El puerto HTTP ($httpPort) se mantiene activo con redirect 301 -> HTTPS"
    aputs_info "Se agrega server { listen 0.0.0.0:$httpsPort ssl } como bloque adicional"
    Write-Host ""

    # Verificar si ya está configurado
    $confNginx = Get-Content $Script:HTTP_CONF_NGINX -Raw -ErrorAction SilentlyContinue
    if ($confNginx -match [regex]::Escape($Script:SSL_MARCA_NGINX)) {
        aputs_warning "SSL de Nginx ya está configurado"
        $resp = Read-MenuInput "¿Reaplicar? [s/N]"
        if ($resp -notmatch '^[Ss]$') { return $true }
        # Eliminar bloque anterior
        _ssl_http_eliminar_bloque_nginx
        $confNginx = Get-Content $Script:HTTP_CONF_NGINX -Raw
    }

    ssl_hacer_backup $Script:HTTP_CONF_NGINX
    Write-Host ""

    aputs_info "Agregando bloque SSL a $($Script:HTTP_CONF_NGINX)..."

    # Rutas con barras hacia adelante para nginx
    $certFwd = $Script:SSL_CERT -replace '\\', '/'
    $keyFwd  = $Script:SSL_KEY  -replace '\\', '/'

    $bloqueSSL = @"

    $($Script:SSL_MARCA_NGINX)
    server {
        listen 0.0.0.0:${httpsPort} ssl;
        server_name $($Script:SSL_DOMAIN);

        ssl_certificate     "$certFwd";
        ssl_certificate_key "$keyFwd";

        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;
        ssl_session_cache   shared:SSL:10m;
        ssl_session_timeout 10m;

        add_header Strict-Transport-Security "max-age=31536000" always;

        location / {
            root   html;
            index  index.html index.htm;
        }

        error_log  logs/ssl_error.log;
        access_log logs/ssl_access.log;
    }
    $($Script:SSL_MARCA_NGINX)
"@

    # Paso 1: insertar el bloque HTTPS antes del cierre del bloque http {}
    $idx = $confNginx.LastIndexOf('}')
    if ($idx -lt 0) {
        aputs_error "No se encontró el cierre del bloque http {} en nginx.conf"
        return $false
    }
    $nuevoConf = $confNginx.Substring(0, $idx) + $bloqueSSL + "`n" + $confNginx.Substring($idx)

    $lineaRedirect   = "        return 301 https://`$host:${httpsPort}`$request_uri;"
    $lineas          = $nuevoConf -split "`n"
    $dentroServer    = $false
    $profundidad     = 0
    $tieneListenHTTP = $false
    $yaTieneRedirect = $false
    $inicioServer    = -1
    $insertarEn      = -1   # índice de línea donde insertar el return 301
    $resultado       = [System.Collections.Generic.List[string]]::new()

    for ($i = 0; $i -lt $lineas.Count; $i++) {
        $linea     = $lineas[$i]
        $lineaTrim = $linea.TrimStart()

        # Ignorar líneas comentadas para el análisis de bloques
        $esComentario = $lineaTrim.StartsWith('#')

        if (-not $esComentario) {
            # Detectar apertura de server { (fuera de un bloque server = nivel http)
            if (-not $dentroServer -and $lineaTrim -match '^server\s*\{') {
                $dentroServer    = $true
                $profundidad     = 1
                $tieneListenHTTP = $false
                $yaTieneRedirect = $false
                $inicioServer    = $i
                $insertarEn      = -1
            }
            elseif ($dentroServer) {
                # Contar llaves para saber cuándo termina el bloque
                $profundidad += ($linea.ToCharArray() | Where-Object { $_ -eq '{' }).Count
                $profundidad -= ($linea.ToCharArray() | Where-Object { $_ -eq '}' }).Count

                # Detectar si este server{} escucha en el puerto HTTP
                if ($lineaTrim -match "^\s*listen\s+$httpPort\s*;") {
                    $tieneListenHTTP = $true
                }

                # Detectar si ya tiene un return 301
                if ($lineaTrim -match 'return\s+301') {
                    $yaTieneRedirect = $true
                }

                # Guardar la posición del primer "location" para insertar antes
                if ($insertarEn -lt 0 -and $lineaTrim -match '^location\s') {
                    $insertarEn = $i
                }

                # Fin del bloque server{}
                if ($profundidad -le 0) {
                    $dentroServer = $false

                    # Si este era el bloque HTTP que buscamos, inyectar redirect
                    if ($tieneListenHTTP -and -not $yaTieneRedirect) {
                        # Posición de inserción: antes del primer location, o antes del }
                        $posInsertar = if ($insertarEn -gt 0) { $insertarEn } else { $i }
                        $resultado.Insert($posInsertar + $resultado.Count - $i, $lineaRedirect)
                        aputs_success "Redirect HTTP->HTTPS inyectado en server{} real (puerto $httpPort, línea $posInsertar)"
                        $tieneListenHTTP = $false  # Evitar doble inserción
                    }
                }
            }
        }

        $resultado.Add($linea)
    }

    if ($tieneListenHTTP) {
        # El bloque no cerró correctamente — insertar de todas formas
        aputs_warning "server{} con listen $httpPort no cerró — redirect puede estar mal"
    }

    # Verificar que se inyectó
    $nuevoConf = $resultado -join "`n"
    if ($nuevoConf -notmatch 'return\s+301') {
        aputs_warning "No se encontró server{} real con listen $httpPort — redirect no aplicado"
        aputs_info    "El servidor HTTPS funcionará, pero HTTP no redirigirá automáticamente"
    }

    # Escribir SIN BOM — nginx no acepta UTF-8 BOM
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Script:HTTP_CONF_NGINX, $nuevoConf, $utf8NoBom)
    aputs_success "Bloque SSL insertado en nginx.conf"
    Write-Host ""

    # Abrir puerto
    ssl_abrir_puerto_firewall $httpsPort

    # Validar y reiniciar
    aputs_info "Validando configuración de Nginx..."
    $nginxDir = Split-Path (Split-Path $Script:HTTP_CONF_NGINX)
    $nginxExe = Join-Path $nginxDir "nginx.exe"
    if (Test-Path $nginxExe) {
        # -p especifica el directorio raíz de nginx (prefix path)
        # Sin -p, nginx busca conf/ relativo al directorio actual
        $test = & $nginxExe -p $nginxDir -t 2>&1
        if ($LASTEXITCODE -eq 0) {
            aputs_success "Sintaxis OK"
        }
        else {
            aputs_error "Error en nginx.conf:"
            $test | ForEach-Object { Write-Host "  $_" }
            return $false
        }
    }
    Write-Host ""

    # Reiniciar nginx con -p para especificar directorio raíz
    aputs_info "Reiniciando Nginx..."
    $svcNginx = Get-Service -Name $Script:HTTP_WINSVC_NGINX -ErrorAction SilentlyContinue
    if ($svcNginx -and $svcNginx.Status -eq "Running") {
        Restart-Service -Name $Script:HTTP_WINSVC_NGINX -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    } else {
        # Sin servicio: usar proceso con -p prefix
        Get-Process -Name "nginx" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Start-Process -FilePath $nginxExe -ArgumentList "-p `"$nginxDir`"" `
            -WorkingDirectory $nginxDir -WindowStyle Hidden
        Start-Sleep -Seconds 2
    }
    Write-Host ""
    aputs_success "Nginx HTTPS configurado en puerto $httpsPort"
    aputs_info    "HTTP  : http://localhost:$httpPort  (redirect -> HTTPS)"
    aputs_info    "HTTPS : curl.exe -k https://localhost:$httpsPort"
    _ssl_actualizar_index "nginx" $httpPort $httpsPort
    return $true
}

function _ssl_http_eliminar_bloque_nginx {
    $conf = Get-Content $Script:HTTP_CONF_NGINX -Raw -ErrorAction SilentlyContinue
    if (-not $conf) { return }

    $marca   = [regex]::Escape($Script:SSL_MARCA_NGINX)
    $patron  = "(?s)\s*$marca.*?$marca\s*"
    $limpio  = $conf -replace $patron, ""
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Script:HTTP_CONF_NGINX, $limpio, $utf8NoBom)
    aputs_info "Bloque SSL anterior eliminado de nginx.conf"
}

# 
# TOMCAT (Windows — keystore PKCS12, igual que Linux)
# 
function ssl_http_aplicar_tomcat {
    ssl_mostrar_banner "SSL — Tomcat"

    if (-not (ssl_servicio_instalado "tomcat")) {
        aputs_warning "Tomcat no está instalado — omitiendo"
        return $true
    }
    if (-not (ssl_cert_existe)) {
        aputs_error "Certificado no generado — ejecute primero el Paso 2"
        return $false
    }

    $httpPort  = ssl_leer_puerto_http "tomcat"
    $httpsPort = 0
    _ssl_seleccionar_puerto_https "tomcat" $httpPort ([ref]$httpsPort)
    aputs_info "El puerto HTTP ($httpPort) se mantiene activo"
    # Detectar rutas de Tomcat en tiempo de ejecucion — pueden haber cambiado
    # si Tomcat se instalo DESPUES de que mainSSL.ps1 cargara utilsSSL.ps1
    http_detectar_rutas_reales -ErrorAction SilentlyContinue 2>$null
    $serverXml = $Script:HTTP_CONF_TOMCAT
    # Recalcular keystore basandose en la ruta real de server.xml
    if ($serverXml -and (Test-Path (Split-Path $serverXml -Parent) -ErrorAction SilentlyContinue)) {
        $keystore = "$(Split-Path $serverXml -Parent)\reprobados.p12"
        $Script:SSL_KEYSTORE_TOMCAT = $keystore
    } else {
        $keystore = $Script:SSL_KEYSTORE_TOMCAT
        if (-not $keystore) { $keystore = Get-SslKeystoreTomcat }
    }

    aputs_info "server.xml:       $serverXml"
    aputs_info "Keystore destino: $keystore"
    Write-Host ""

    if (-not (Test-Path $serverXml)) {
        aputs_error "No se encontró server.xml en $serverXml"
        return $false
    }

    # Generar keystore PKCS12 con openssl
    aputs_info "Generando keystore PKCS12..."
    $opensslCmd = Get-Command openssl -ErrorAction SilentlyContinue
    if (-not $opensslCmd) {
        # Fallback: usar el PFX directamente si openssl no está disponible
        aputs_warning "openssl no encontrado — copiando PFX como keystore"
        Copy-Item $Script:SSL_PFX $keystore -Force
    }
    else {
        $result = openssl pkcs12 -export `
            -in  $Script:SSL_CERT `
            -inkey $Script:SSL_KEY `
            -out $keystore `
            -name $Script:SSL_DOMAIN `
            -passout "pass:$($Script:SSL_PFX_PASS)" 2>&1
        if ($LASTEXITCODE -ne 0) {
            aputs_error "Error al generar keystore: $result"
            return $false
        }
    }

    # Ajustar permisos del keystore (solo Administradores y Tomcat)
    try {
        $aclKs = Get-Acl $keystore
        $tomcatSvcUser = "NT SERVICE\$($Script:HTTP_WINSVC_TOMCAT)"
        $tomcatRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $tomcatSvcUser, "ReadAndExecute", "None", "None", "Allow")
        $aclKs.AddAccessRule($tomcatRule)
        Set-Acl -Path $keystore -AclObject $aclKs -ErrorAction SilentlyContinue
    } catch {}

    aputs_success "Keystore generado: $keystore"
    Write-Host ""

    ssl_hacer_backup $serverXml
    Write-Host ""

    aputs_info "Configurando Connector HTTPS en server.xml (sintaxis Tomcat 10.1)..."

    # Rutas con barras hacia adelante — Java no acepta backslash en rutas
    $keystoreFwd = $keystore -replace '\\', '/'

    # El bloque XML completo del conector con la estructura correcta para Tomcat 10+
    $connectorBloque = @"
    <!-- Practica7 SSL — Connector HTTPS puerto $httpsPort -->
    <Connector port="$httpsPort"
               protocol="org.apache.coyote.http11.Http11NioProtocol"
               SSLEnabled="true"
               maxThreads="150"
               scheme="https"
               secure="true">
        <SSLHostConfig>
            <Certificate certificateKeystoreFile="$keystoreFwd"
                         certificateKeystorePassword="$($Script:SSL_PFX_PASS)"
                         certificateKeystoreType="PKCS12"
                         type="RSA"/>
        </SSLHostConfig>
    </Connector>
"@

    # Usar [xml] para manipular el XML de forma segura (no con regex en XML)
    try {
        [xml]$doc = [System.IO.File]::ReadAllText($serverXml, [System.Text.Encoding]::UTF8)

        # Localizar el elemento <Service name="Catalina">
        $service = $doc.Server.Service | Where-Object { $_.name -eq "Catalina" }
        if (-not $service) {
            # Fallback: tomar el primer Service
            $service = $doc.Server.Service | Select-Object -First 1
        }

        # Eliminar conectores SSL anteriores (cualquier puerto o versión legacy)
        $aEliminar = @()
        foreach ($c in $service.Connector) {
            if ($c.SSLEnabled -eq "true" -or $c.port -eq "$httpsPort") {
                $aEliminar += $c
            }
        }
        foreach ($c in $aEliminar) {
            aputs_info "Eliminando conector SSL anterior en puerto $($c.port)"
            $service.RemoveChild($c) | Out-Null
        }

        # Crear el nuevo Connector como nodo XML
        $nuevoConector = $doc.CreateElement("Connector")
        $nuevoConector.SetAttribute("port",        "$httpsPort")
        $nuevoConector.SetAttribute("protocol",    "org.apache.coyote.http11.Http11NioProtocol")
        $nuevoConector.SetAttribute("SSLEnabled",  "true")
        $nuevoConector.SetAttribute("maxThreads",  "150")
        $nuevoConector.SetAttribute("scheme",      "https")
        $nuevoConector.SetAttribute("secure",      "true")

        # Crear hijo <SSLHostConfig>
        $sslHostConfig = $doc.CreateElement("SSLHostConfig")

        # Crear nieto <Certificate .../>
        $certificate = $doc.CreateElement("Certificate")
        $certificate.SetAttribute("certificateKeystoreFile",     $keystoreFwd)
        $certificate.SetAttribute("certificateKeystorePassword", $Script:SSL_PFX_PASS)
        $certificate.SetAttribute("certificateKeystoreType",     "PKCS12")
        $certificate.SetAttribute("type",                        "RSA")

        # Ensamblar jerarquía: Connector > SSLHostConfig > Certificate
        $sslHostConfig.AppendChild($certificate) | Out-Null
        $nuevoConector.AppendChild($sslHostConfig) | Out-Null
        $service.AppendChild($nuevoConector) | Out-Null

        # Guardar preservando encoding UTF-8 sin BOM
        $settings = New-Object System.Xml.XmlWriterSettings
        $settings.Indent = $true
        $settings.IndentChars = "    "
        $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
        $writer = [System.Xml.XmlWriter]::Create($serverXml, $settings)
        $doc.Save($writer)
        $writer.Close()

        aputs_success "Connector HTTPS Tomcat 10.1 agregado correctamente"
    }
    catch {
        aputs_error "Error al modificar server.xml con [xml]: $($_.Exception.Message)"
        aputs_info  "Intentando método de texto como fallback..."

        # Fallback de texto plano: insertar antes de </Service>
        $xmlStr = [System.IO.File]::ReadAllText($serverXml, [System.Text.Encoding]::UTF8)

        # Eliminar conectores SSL anteriores (regex seguro para self-closing y con hijos)
        $xmlStr = [regex]::Replace($xmlStr,
            '(?s)\s*<!--\s*Practica7 SSL[^>]*-->.*?</Connector>', '')
        $xmlStr = [regex]::Replace($xmlStr,
            '(?s)<Connector[^>]*SSLEnabled="true".*?</Connector>', '')
        $xmlStr = [regex]::Replace($xmlStr,
            '(?s)<Connector[^>]*port="' + $httpsPort + '".*?</Connector>', '')

        # Insertar el nuevo bloque
        $xmlStr = $xmlStr -replace '</Service>', "$connectorBloque`n    </Service>"

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($serverXml, $xmlStr, $utf8NoBom)
        aputs_success "Connector insertado (método texto)"
    }

    # Verificación rápida de que quedó bien
    $verificacion = Get-Content $serverXml -Raw
    if ($verificacion -match 'SSLEnabled="true"' -and $verificacion -match 'SSLHostConfig') {
        aputs_success "server.xml verificado: estructura SSLHostConfig presente"
    } elseif ($verificacion -match 'SSLEnabled="true"') {
        aputs_warning "SSLEnabled presente pero sin SSLHostConfig — puede fallar en Tomcat 10+"
    } else {
        aputs_error "No se encontró el Connector SSL en server.xml"
        return $false
    }
    Write-Host ""

    ssl_abrir_puerto_firewall $httpsPort

    Write-Host ""
    if (http_reiniciar_servicio "tomcat") {
        Write-Host ""
        _ssl_actualizar_index "tomcat" $httpPort $httpsPort
        Write-Host ""
        aputs_success "Tomcat HTTPS configurado en puerto $httpsPort"
        aputs_info    "HTTP  : http://localhost:$httpPort"
        aputs_info    "HTTPS : curl.exe -k https://localhost:$httpsPort"
        return $true
    }
    return $false
}

# 
# FTP SSL (IIS-FTP)
# 
function ssl_ftp_aplicar_iis {
    ssl_mostrar_banner "FTPS — IIS FTP"

    # Verificar que FTPSVC está instalado
    $ftpSvc = Get-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    if (-not $ftpSvc) {
        aputs_warning "IIS-FTP (FTPSVC) no está instalado — omitiendo"
        aputs_info    "Instale desde: Características de Windows -> IIS -> FTP Server"
        return $true
    }

    if (-not (ssl_cert_importado)) {
        aputs_error "Certificado no importado en el almacén de Windows"
        aputs_info  "Ejecute primero el Paso 2 — Generar certificado"
        return $false
    }

    try {
        Import-Module WebAdministration -ErrorAction Stop
    }
    catch {
        aputs_error "WebAdministration no disponible"
        return $false
    }

    # Configurar SSL en el sitio FTP
    aputs_info "Configurando SSL en sitio FTP..."
    try {
        # Obtener el nombre del sitio FTP
        $ftpSite = Get-Website | Where-Object { $_.serverAutoStart -and
            (Get-WebBinding -Name $_.Name | Where-Object { $_.Protocol -eq "ftp" }) } |
            Select-Object -First 1

        if (-not $ftpSite) {
            aputs_warning "No se encontró sitio FTP activo — usando 'Default FTP Site'"
            $ftpSiteName = "Default FTP Site"
        }
        else {
            $ftpSiteName = $ftpSite.Name
        }

        aputs_info "Sitio FTP: $ftpSiteName"

        # Habilitar SSL en el sitio FTP
        Set-ItemProperty "IIS:\Sites\$ftpSiteName" `
            -Name "ftpServer.security.ssl.controlChannelPolicy" `
            -Value 0  # 0 = Allow SSL, 1 = Require SSL
        Set-ItemProperty "IIS:\Sites\$ftpSiteName" `
            -Name "ftpServer.security.ssl.dataChannelPolicy" `
            -Value 0
        Set-ItemProperty "IIS:\Sites\$ftpSiteName" `
            -Name "ftpServer.security.ssl.serverCertHash" `
            -Value $Script:SSL_THUMBPRINT

        aputs_success "SSL habilitado en sitio FTP: $ftpSiteName"
        aputs_info    "Modo: Allow SSL (TLS explícito — igual que vsftpd en Linux)"
    }
    catch {
        aputs_error "Error al configurar SSL en IIS-FTP: $($_.Exception.Message)"
        return $false
    }

    # Reiniciar FTPSVC
    aputs_info "Reiniciando FTPSVC..."
    try {
        Restart-Service FTPSVC -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        aputs_success "FTPSVC reiniciado"
    }
    catch {
        aputs_error "Error al reiniciar FTPSVC: $($_.Exception.Message)"
        return $false
    }

    Write-Host ""
    aputs_success "FTPS configurado en IIS"
    aputs_info    "Prueba: openssl s_client -connect 192.168.100.20:21 -starttls ftp"
    return $true
}

# 
# ORQUESTADOR
# 
function ssl_http_aplicar_todos {
    ssl_mostrar_banner "SSL — Configurar HTTPS en servicios HTTP"

    if (-not (ssl_cert_existe)) {
        aputs_error "Certificado no generado"
        aputs_info  "Ejecute primero: Paso 2 — Generar certificado SSL"
        return $false
    }

    # Detectar servicios instalados
    $disponibles = @()
    foreach ($svc in @("iis", "apache", "nginx", "tomcat")) {
        if (ssl_servicio_instalado $svc) { $disponibles += $svc }
    }

    if ($disponibles.Count -eq 0) {
        aputs_error "No hay servicios HTTP instalados"
        aputs_info  "Ejecute primero el Paso 4 — Instalar HTTP"
        return $false
    }

    aputs_info "Servicios HTTP detectados:"
    Write-Host ""
    foreach ($svc in $disponibles) {
        Write-Host ("  ${GREEN}[●]${NC} $svc")
    }
    Write-Host ""

    # Preguntar cuáles configurar
    $aplicar = @{}
    foreach ($svc in $disponibles) {
        $resp = Read-MenuInput "¿Configurar SSL en $svc? [S/n]"
        $aplicar[$svc] = ($resp -notmatch '^[Nn]$')
    }

    Write-Host ""
    draw_line
    Write-Host ""

    $errores = 0
    if ($aplicar["iis"]    ) { if (-not (ssl_http_aplicar_iis))    { $errores++ }; Write-Host "" }
    if ($aplicar["apache"] ) { if (-not (ssl_http_aplicar_apache)) { $errores++ }; Write-Host "" }
    if ($aplicar["nginx"]  ) { if (-not (ssl_http_aplicar_nginx))  { $errores++ }; Write-Host "" }
    if ($aplicar["tomcat"] ) { if (-not (ssl_http_aplicar_tomcat)) { $errores++ }; Write-Host "" }

    draw_line
    if ($errores -eq 0) {
        aputs_success "SSL aplicado correctamente a todos los servicios seleccionados"
    }
    else {
        aputs_warning "$errores servicio(s) con errores — revise los mensajes anteriores"
    }

    return ($errores -eq 0)
}

# 
# ssl_http_estado  — solo lectura
# 
function ssl_http_estado {
    aputs_info "Estado SSL de servicios HTTP:"
    Write-Host ""

    foreach ($svc in @("iis", "apache", "nginx", "tomcat")) {
        if (-not (ssl_servicio_instalado $svc)) {
            Write-Host ("  {0,-8} — ${GRAY}no instalado${NC}" -f $svc)
            continue
        }

        # ¿SSL configurado?
        $sslOk = $false
        switch ($svc) {
            "iis" {
                try {
                    Import-Module WebAdministration -ErrorAction Stop
                    $b = Get-WebBinding -Name "Default Web Site" -Protocol "https" `
                        -ErrorAction SilentlyContinue
                    $sslOk = ($null -ne $b)
                } catch {}
            }
            "apache" {
                $sslOk = (Test-Path $Script:SSL_CONF_APACHE_SSL)
            }
            "nginx" {
                $c = Get-Content $Script:HTTP_CONF_NGINX -Raw -ErrorAction SilentlyContinue
                $sslOk = ($c -match [regex]::Escape($Script:SSL_MARCA_NGINX))
            }
            "tomcat" {
                $c = Get-Content $Script:HTTP_CONF_TOMCAT -Raw -ErrorAction SilentlyContinue
                $sslOk = ($c -match 'SSLEnabled="true"')
            }
        }

        $sslStr    = if ($sslOk) { "${GREEN}YES${NC}" } else { "${YELLOW}NO${NC}  " }
        $activoStr = if (ssl_servicio_activo $svc) { "${GREEN}activo${NC}" } else { "${RED}inactivo${NC}" }

        Write-Host ("  {0,-8} — SSL: " -f $svc) -NoNewline
        Write-Host $sslStr -NoNewline
        Write-Host " | Estado: " -NoNewline
        Write-Host $activoStr
    }
    Write-Host ""
}

# 
# ssl_menu_http  — submenú interactivo
# 
function ssl_menu_http {
    while ($true) {
        Clear-Host
        ssl_mostrar_banner "Tarea 07 — SSL/HTTPS en servicios HTTP"
        ssl_http_estado

        Write-Host "  ${BLUE}1)${NC} Configurar SSL en todos los servicios instalados"
        Write-Host "  ${BLUE}2)${NC} Configurar SSL solo en IIS"
        Write-Host "  ${BLUE}3)${NC} Configurar SSL solo en Apache"
        Write-Host "  ${BLUE}4)${NC} Configurar SSL solo en Nginx"
        Write-Host "  ${BLUE}5)${NC} Configurar SSL solo en Tomcat"
        Write-Host "  ${BLUE}6)${NC} Configurar FTPS en IIS-FTP"
        Write-Host "  ${BLUE}0)${NC} Volver"
        Write-Host ""

        $op = Read-Host "  Opción"
        switch ($op) {
            "1" { ssl_http_aplicar_todos;    pause_menu }
            "2" { ssl_http_aplicar_iis;      pause_menu }
            "3" { ssl_http_aplicar_apache;   pause_menu }
            "4" { ssl_http_aplicar_nginx;    pause_menu }
            "5" { ssl_http_aplicar_tomcat;   pause_menu }
            "6" { ssl_ftp_aplicar_iis;       pause_menu }
            "0" { return }
            default { aputs_error "Opción inválida"; Start-Sleep -Seconds 1 }
        }
    }
}