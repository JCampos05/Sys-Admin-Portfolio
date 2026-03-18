#
# verifySSL.ps1
# Verificación general y reporte final — Windows Server
#
# Funciones públicas:
#   ssl_verify_certificado()   — cert: existencia, vigencia, CN
#   ssl_verify_ftp()           — IIS-FTP: servicio + FTPS
#   ssl_verify_http()          — IIS, Apache, Nginx, Tomcat: HTTP + HTTPS
#   ssl_verify_todo()          — reporte completo + tabla resumen
#   ssl_menu_verify()          — submenú interactivo
#
# Requiere: utils.ps1, utilsHTTP.ps1, utilsSSL.ps1
#
. "$PSScriptRoot\utils.ps1"  # garantiza aputs_*, draw_line, check_connectivity en este scope


#Requires -Version 5.1


# 
# HELPER DE FILA
# 
function _v_check {
    param(
        [string]$Desc,
        [string]$Result,   # ok | fail | warn | skip
        [string]$Detalle = ""
    )
    $icono = switch ($Result) {
        "ok"   { "${GREEN}  OK  ${NC}" }
        "fail" { "${RED}  FAIL${NC}" }
        "warn" { "${YELLOW}  WARN${NC}" }
        "skip" { "${GRAY}  SKIP${NC}" }
        default{ "  ?   " }
    }
    $det = if ($Detalle) { $Detalle } else { "" }
    Write-Host ("  {0}  {1,-38} {2}" -f $icono, $Desc, $det)
}

# 
# ssl_verify_certificado
# 
function ssl_verify_certificado {
    Write-Host ""
    aputs_info "── Certificado SSL/TLS ──"
    Write-Host ""

    # Existencia PEM
    if (-not (Test-Path $Script:SSL_CERT)) {
        _v_check "Archivo $($Script:SSL_CERT)" "fail" "(no existe)"
        return
    }
    _v_check "Archivo $($Script:SSL_CERT)" "ok"

    if (-not (Test-Path $Script:SSL_KEY)) {
        _v_check "Clave $($Script:SSL_KEY)" "fail" "(no existe)"
        return
    }
    _v_check "Clave $($Script:SSL_KEY)" "ok"

    # Existencia PFX
    if (Test-Path $Script:SSL_PFX) {
        _v_check "PFX $($Script:SSL_PFX)" "ok"
    }
    else {
        _v_check "PFX $($Script:SSL_PFX)" "warn" "(necesario para IIS/Tomcat)"
    }

    # Vigencia con openssl
    $openssl = Get-Command openssl -ErrorAction SilentlyContinue
    if ($openssl) {
        $endDate = openssl x509 -in $Script:SSL_CERT -noout -enddate 2>&1
        $expired = openssl x509 -in $Script:SSL_CERT -noout -checkend 0 2>&1
        if ($LASTEXITCODE -eq 0) {
            $expStr = ($endDate -replace "notAfter=", "").Trim()
            _v_check "Certificado vigente" "ok" "expira: $expStr"
        }
        else {
            _v_check "Certificado vigente" "fail" "(EXPIRADO)"
        }

        # CN
        $cn = (openssl x509 -in $Script:SSL_CERT -noout -subject 2>&1) -replace ".*CN\s*=\s*([^,/]+).*", '$1'
        $cn = $cn.Trim()
        if ($cn -eq $Script:SSL_DOMAIN) {
            _v_check "CN = $($Script:SSL_DOMAIN)" "ok"
        }
        else {
            _v_check "CN = $($Script:SSL_DOMAIN)" "fail" "(encontrado: $cn)"
        }
    }
    else {
        _v_check "Vigencia (openssl)" "skip" "(openssl no instalado)"
    }

    # Almacén Windows
    if (ssl_cert_importado) {
        $cert = Get-ChildItem Cert:\LocalMachine\My |
            Where-Object { $_.Thumbprint -eq $Script:SSL_THUMBPRINT } |
            Select-Object -First 1
        if ($cert -and $cert.NotAfter -gt (Get-Date)) {
            _v_check "Almacén Windows (LocalMachine\My)" "ok" "Thumbprint: $($Script:SSL_THUMBPRINT.Substring(0,16))..."
        }
        else {
            _v_check "Almacén Windows (LocalMachine\My)" "warn" "(no encontrado o expirado)"
        }
    }
    else {
        _v_check "Almacén Windows (LocalMachine\My)" "warn" "(no importado — necesario para IIS)"
    }

    Write-Host ""
}

# 
# ssl_verify_ftp
# 
function ssl_verify_ftp {
    Write-Host ""
    aputs_info "── FTP (IIS-FTP / FTPSVC) ──"
    Write-Host ""

    $ftpSvc = Get-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    if (-not $ftpSvc) {
        _v_check "FTPSVC instalado" "skip" "(IIS-FTP no instalado)"
        Write-Host ""
        return
    }
    _v_check "FTPSVC instalado" "ok"

    if ($ftpSvc.Status -eq 'Running') {
        _v_check "FTPSVC activo" "ok"
    }
    else {
        _v_check "FTPSVC activo" "fail" "(inactivo)"
    }

    # Puerto 21 — IIS-FTP puede no aparecer en Get-NetTCPConnection en algunos
    # casos (IPv6 dual-stack). Usar netstat como fallback confiable.
    $puerto21Ok = check_port_listening 21
    if (-not $puerto21Ok) {
        # Fallback: netstat -ano es más confiable que Get-NetTCPConnection para FTP
        $netstatOut = netstat -ano 2>&1 | Out-String
        $puerto21Ok = $netstatOut -match ':21\s'
    }
    if ($puerto21Ok) {
        _v_check "Puerto 21 escuchando" "ok"
    }
    else {
        _v_check "Puerto 21 escuchando" "warn" "(no detectado — puede ser normal en IIS-FTP)"
    }

    # SSL en IIS-FTP
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $ftpSite = Get-Website | Where-Object {
            (Get-WebBinding -Name $_.Name -ErrorAction SilentlyContinue |
             Where-Object { $_.Protocol -eq "ftp" }) -ne $null
        } | Select-Object -First 1

        if ($ftpSite) {
            $sslHash = (Get-ItemProperty "IIS:\Sites\$($ftpSite.Name)" `
                -Name "ftpServer.security.ssl.serverCertHash" `
                -ErrorAction SilentlyContinue)
            if ($sslHash -and $sslHash -eq $Script:SSL_THUMBPRINT) {
                _v_check "FTPS SSL en IIS-FTP" "ok" "(cert: reprobados.com)"
            }
            elseif ($sslHash) {
                _v_check "FTPS SSL en IIS-FTP" "warn" "(cert diferente al de P7)"
            }
            else {
                _v_check "FTPS SSL en IIS-FTP" "warn" "(sin certificado configurado)"
            }
        }
        else {
            _v_check "Sitio FTP activo" "warn" "(no encontrado)"
        }
    }
    catch {
        _v_check "FTPS SSL en IIS-FTP" "skip" "(WebAdministration no disponible)"
    }

    Write-Host ""
}

# 
# ssl_verify_http
# 
function ssl_verify_http {
    Write-Host ""
    aputs_info "── Servicios HTTP/HTTPS ──"
    Write-Host ""

    $servicios = @(
        @{ Nombre = "IIS";    Svc = "iis"    }
        @{ Nombre = "Apache"; Svc = "apache" }
        @{ Nombre = "Nginx";  Svc = "nginx"  }
        @{ Nombre = "Tomcat"; Svc = "tomcat" }
    )

    foreach ($item in $servicios) {
        $nombre = $item.Nombre
        $svc    = $item.Svc

        if (-not (ssl_servicio_instalado $svc)) {
            _v_check $nombre "skip" "(no instalado)"
            continue
        }

        # Activo — Nginx en Windows puede correr como proceso en lugar de servicio
        $estaActivo = ssl_servicio_activo $svc
        if (-not $estaActivo -and $svc -eq "nginx") {
            # Nginx instalado desde ZIP no tiene servicio Windows — verificar proceso
            $estaActivo = $null -ne (Get-Process -Name "nginx" -ErrorAction SilentlyContinue)
        }
        if ($estaActivo) {
            _v_check "$nombre activo" "ok"
        }
        else {
            _v_check "$nombre activo" "fail" "(inactivo)"
            continue
        }

        $httpPort  = ssl_leer_puerto_http $svc
        # Leer el puerto HTTPS REAL desde los archivos de configuración.
        # ssl_puerto_https() usa la fórmula +363 pero el usuario puede haber
        # elegido un puerto diferente al aplicar SSL con el nuevo script.
        $httpsPort = ssl_leer_puerto_https $svc

        # Prueba HTTP
        try {
            $httpResp = curl.exe -s -o NUL -w "%{http_code}" `
                --connect-timeout 3 `
                "http://localhost:$httpPort" 2>&1
            switch -Regex ($httpResp) {
                "^2" {
                    # IIS con httpRedirect nativo devuelve 200 con redirección interna
                    # (no expone código 301 a curl). Verificar si hay binding HTTPS activo.
                    if ($svc -eq "iis") {
                        try {
                            Import-Module WebAdministration -EA Stop
                            $hasHttps = Get-WebBinding -Name "Default Web Site" `
                                -Protocol "https" -EA SilentlyContinue
                            if ($hasHttps) {
                                _v_check "$nombre HTTP :$httpPort" "ok" "HTTP $httpResp (redirect interno IIS -> HTTPS)"
                            } else {
                                _v_check "$nombre HTTP :$httpPort" "ok" "HTTP $httpResp"
                            }
                        } catch {
                            _v_check "$nombre HTTP :$httpPort" "ok" "HTTP $httpResp"
                        }
                    } else {
                        _v_check "$nombre HTTP :$httpPort" "ok" "HTTP $httpResp"
                    }
                }
                "^30[1278]"{ _v_check "$nombre HTTP :$httpPort" "ok"   "Redirect $httpResp -> HTTPS" }
                "^0+$|^$"  { _v_check "$nombre HTTP :$httpPort" "fail" "(sin respuesta)" }
                default    { _v_check "$nombre HTTP :$httpPort" "warn" "HTTP $httpResp" }
            }
        }
        catch {
            _v_check "$nombre HTTP :$httpPort" "fail" "(error al conectar)"
        }

        # Prueba HTTPS
        try {
            $httpsResp = curl.exe -sk -o NUL -w "%{http_code}" `
                --connect-timeout 3 `
                "https://localhost:$httpsPort" 2>&1
            switch -Regex ($httpsResp) {
                "^2"       { _v_check "$nombre HTTPS :$httpsPort" "ok"   "HTTP $httpsResp" }
                "^30[1278]"{ _v_check "$nombre HTTPS :$httpsPort" "ok"   "HTTP $httpsResp (redirect)" }
                "^0+$|^$"  { _v_check "$nombre HTTPS :$httpsPort" "warn" "(sin respuesta — SSL no configurado?)" }
                default    { _v_check "$nombre HTTPS :$httpsPort" "warn" "HTTP $httpsResp" }
            }
        }
        catch {
            _v_check "$nombre HTTPS :$httpsPort" "fail" "(error al conectar)"
        }

        # TLS handshake con openssl
        $openssl = Get-Command openssl -ErrorAction SilentlyContinue
        if ($openssl) {
            $tlsOut = (echo "Q" | timeout /t 5 openssl s_client `
                -connect "127.0.0.1:$httpsPort" `
                -CAfile $Script:SSL_CERT 2>&1) -join "`n"
            $proto = ($tlsOut | Select-String "Protocol\s*:\s*(.+)" |
                ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } |
                Select-Object -First 1)
            if ($proto) {
                _v_check "$nombre TLS handshake" "ok" "$proto"
            }
            elseif ($httpsResp -and $httpsResp -notmatch "^0") {
                _v_check "$nombre TLS handshake" "ok" "(TLS activo — protocolo no detectado)"
            }
            else {
                _v_check "$nombre TLS handshake" "warn" "(sin respuesta en :$httpsPort)"
            }
        }

        Write-Host ""
    }
}

# 
# ssl_verify_todo  — reporte completo
# 
function ssl_verify_todo {
    Clear-Host
    ssl_mostrar_banner "Tarea 07 — Verificación General"

    aputs_info "Servidor: 192.168.100.20 (Windows Server)"
    aputs_info "Fecha:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host ""
    draw_line

    ssl_verify_certificado
    draw_line

    ssl_verify_ftp
    draw_line

    ssl_verify_http
    draw_line

    # Tabla resumen
    Write-Host ""
    aputs_info "Resumen de servicios:"
    Write-Host ""
    Write-Host ("  {0,-10} {1,-12} {2,-12} {3,-6} {4}" -f `
        "Servicio", "Puerto HTTP", "Puerto HTTPS", "SSL", "Estado")
    Write-Host "  ─────────────────────────────────────────────────────"

    foreach ($svc in @("iis", "apache", "nginx", "tomcat")) {
        if (-not (ssl_servicio_instalado $svc)) {
            Write-Host ("  {0,-10} {1,-12} {2,-12} {3,-6} {4}" -f `
                $svc, "-", "-", "-", "no instalado")
            continue
        }

        $httpPort  = ssl_leer_puerto_http $svc
        $httpsPort = ssl_leer_puerto_https $svc

        # SSL activo
        $sslOk = $false
        switch ($svc) {
            "iis"    {
                try {
                    Import-Module WebAdministration -EA Stop
                    $sslOk = ($null -ne (Get-WebBinding -Name "Default Web Site" -Protocol "https" -EA SilentlyContinue))
                } catch {}
            }
            "apache" { $sslOk = (Test-Path $Script:SSL_CONF_APACHE_SSL) }
            "nginx"  {
                $c = Get-Content $Script:HTTP_CONF_NGINX -Raw -EA SilentlyContinue
                $sslOk = ($c -match [regex]::Escape($Script:SSL_MARCA_NGINX))
            }
            "tomcat" {
                $c = Get-Content $Script:HTTP_CONF_TOMCAT -Raw -EA SilentlyContinue
                $sslOk = ($c -match 'SSLEnabled="true"')
            }
        }

        $sslStr    = if ($sslOk) { "YES" } else { "NO" }
        # Nginx puede correr como proceso sin servicio Windows
        $esActivo  = ssl_servicio_activo $svc
        if (-not $esActivo -and $svc -eq "nginx") {
            $esActivo = $null -ne (Get-Process -Name "nginx" -ErrorAction SilentlyContinue)
        }
        $activoStr = if ($esActivo) { "activo" } else { "inactivo" }

        Write-Host ("  {0,-10} {1,-12} {2,-12} {3,-6} {4}" -f `
            $svc, $httpPort, $httpsPort, $sslStr, $activoStr)
    }

    Write-Host ""
    draw_line
    Write-Host ""
    aputs_success "Verificación completada"
    Write-Host ""
}

# 
# ssl_menu_verify  — submenú interactivo
# 
function ssl_menu_verify {
    while ($true) {
        Clear-Host
        ssl_mostrar_banner "Tarea 07 — Verificación y Testing"

        Write-Host "  ${BLUE}1)${NC} Verificación general completa (recomendado)"
        Write-Host "  ${BLUE}2)${NC} Verificar solo certificado SSL"
        Write-Host "  ${BLUE}3)${NC} Verificar solo FTP (IIS-FTP + TLS)"
        Write-Host "  ${BLUE}4)${NC} Verificar solo servicios HTTP/HTTPS"
        Write-Host "  ${BLUE}0)${NC} Volver"
        Write-Host ""

        $op = Read-Host "  Opción"
        switch ($op) {
            "1" { ssl_verify_todo;        pause_menu }
            "2" { ssl_verify_certificado; pause_menu }
            "3" { ssl_verify_ftp;         pause_menu }
            "4" { ssl_verify_http;        pause_menu }
            "0" { return }
            default { aputs_error "Opción inválida"; Start-Sleep -Seconds 1 }
        }
    }
}