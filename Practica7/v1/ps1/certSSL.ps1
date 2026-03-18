#
# certSSL.ps1
# Generación del certificado SSL autofirmado — Windows Server
#
# Requiere: utils.ps1, utilsHTTP.ps1, utilsSSL.ps1 cargados previamente
#
. "$PSScriptRoot\utils.ps1"  # garantiza aputs_*, draw_line, check_connectivity en este scope


#Requires -Version 5.1

# (guardia eliminada — dot-source controlado por mainSSL.ps1)

# =============================================================================
# ssl_cert_generar
# =============================================================================
function ssl_cert_generar {
    ssl_mostrar_banner "SSL — Generar Certificado"

    # Verificar openssl (necesario para exportar PEM)
    $opensslCmd = Get-Command openssl -ErrorAction SilentlyContinue
    if (-not $opensslCmd) {
        aputs_error "openssl no encontrado"
        aputs_info  "Instale con: choco install openssl -y"
        return $false
    }

    # Si ya existe el certificado, preguntar
    if (ssl_cert_existe) {
        aputs_warning "Ya existe un certificado en $($Script:SSL_DIR)"
        Write-Host ""
        ssl_cert_mostrar_info
        Write-Host ""
        $resp = Read-MenuInput "¿Desea regenerarlo? Se perderá el actual [s/N]"
        if ($resp -notmatch '^[Ss]$') { return $true }
        Write-Host ""
    }

    # Crear directorio con permisos restrictivos
    aputs_info "Preparando directorio $($Script:SSL_DIR)..."
    if (-not (Test-Path $Script:SSL_DIR)) {
        New-Item -ItemType Directory -Path $Script:SSL_DIR -Force | Out-Null
    }
    # Solo Administradores y SYSTEM pueden acceder a la clave
    $acl = Get-Acl $Script:SSL_DIR
    $acl.SetAccessRuleProtection($true, $false)
    # Usar SID bien conocidos — funcionan en cualquier idioma de Windows
    $sidAdmin  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544") # Administrators/Administradores
    $sidSystem = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")     # SYSTEM
    $adminRule  = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidAdmin,  "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidSystem, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    try { $acl.AddAccessRule($adminRule)  } catch {}
    try { $acl.AddAccessRule($systemRule) } catch {}
    try { Set-Acl -Path $Script:SSL_DIR -AclObject $acl } catch {}
    aputs_success "Directorio listo"
    Write-Host ""

    # ── Personalización del certificado (equivalente a certSSL.sh de Linux) ──
    # Mostrar valores por defecto y preguntar si se quieren cambiar.
    # Si el usuario presiona Enter o responde N, se usan los valores de utilsSSL.ps1.
    aputs_info "Datos del certificado (valores por defecto):"
    Write-Host ""
    Write-Host ("  {0,-20} {1}" -f "Dominio (CN):",       $Script:SSL_DOMAIN)
    Write-Host ("  {0,-20} {1}" -f "Organización:",       "Administracion de Sistemas")
    Write-Host ("  {0,-20} {1}" -f "Unidad (OU):",        "Practica7")
    Write-Host ("  {0,-20} {1}" -f "País:",               "MX")
    Write-Host ("  {0,-20} {1}" -f "Estado:",             "Mexico")
    Write-Host ("  {0,-20} {1}" -f "Ciudad:",             "Mexico City")
    Write-Host ("  {0,-20} {1}" -f "Validez:",            "$($Script:SSL_DAYS) días")
    Write-Host ("  {0,-20} {1}" -f "Clave RSA:",          "2048 bits")
    Write-Host ""

    $personalizar = Read-MenuInput "¿Personalizar los datos del certificado? [s/N]"

    # Valores que se usarán — inicializados con los defaults
    $certCN   = $Script:SSL_DOMAIN
    $certO    = "Administracion de Sistemas"
    $certOU   = "Practica7"
    $certC    = "MX"
    $certST   = "Mexico"
    $certL    = "Mexico City"
    $certDays = $Script:SSL_DAYS

    if ($personalizar -match '^[sS]$') {
        Write-Host ""
        aputs_info "Ingresa el valor deseado o presiona Enter para conservar el default:"
        Write-Host ""

        $tmp = Read-Host "  Dominio / CN   [$certCN]"
        if ($tmp) { $certCN = $tmp }

        $tmp = Read-Host "  Organización   [$certO]"
        if ($tmp) { $certO = $tmp }

        $tmp = Read-Host "  Unidad / OU    [$certOU]"
        if ($tmp) { $certOU = $tmp }

        $tmp = Read-Host "  País (2 letras) [$certC]"
        if ($tmp) { $certC = $tmp.Substring(0, [Math]::Min(2, $tmp.Length)).ToUpper() }

        $tmp = Read-Host "  Estado         [$certST]"
        if ($tmp) { $certST = $tmp }

        $tmp = Read-Host "  Ciudad         [$certL]"
        if ($tmp) { $certL = $tmp }

        $tmp = Read-Host "  Validez (días) [$certDays]"
        if ($tmp -match '^\d+$') { $certDays = [int]$tmp }

        Write-Host ""
        draw_line
        aputs_info "Certificado que se generará:"
        Write-Host ""
        Write-Host ("  {0,-20} {1}" -f "Dominio (CN):",   $certCN)
        Write-Host ("  {0,-20} {1}" -f "Organización:",   $certO)
        Write-Host ("  {0,-20} {1}" -f "Unidad (OU):",    $certOU)
        Write-Host ("  {0,-20} {1}" -f "País:",           $certC)
        Write-Host ("  {0,-20} {1}" -f "Estado:",         $certST)
        Write-Host ("  {0,-20} {1}" -f "Ciudad:",         $certL)
        Write-Host ("  {0,-20} {1}" -f "Validez:",        "$certDays días")
        Write-Host ""

        $confirmar = Read-MenuInput "¿Confirmar y generar? [S/n]"
        if ($confirmar -match '^[nN]$') { return $false }
        draw_line
    }

    Write-Host ""
    aputs_info "Generando certificado..."
    aputs_info "CN: $certCN | O: $certO | OU: $certOU | C: $certC | Días: $certDays"
    Write-Host ""

    # ── Paso 1: Generar con New-SelfSignedCertificate ─────────────────────────
    aputs_info "Generando certificado en el almacén de Windows..."
    Write-Host ""

    try {
        # Eliminar certificados anteriores con el mismo FriendlyName
        Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -eq $Script:SSL_CERT_FRIENDLY } |
            ForEach-Object { Remove-Item $_.PSPath -Force }

        # Subject construido con los valores elegidos (default o personalizados)
        $subjectFinal = "CN=$certCN,OU=$certOU,O=$certO,C=$certC"

        $cert = New-SelfSignedCertificate `
            -DnsName $certCN `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -NotAfter (Get-Date).AddDays($certDays) `
            -FriendlyName $Script:SSL_CERT_FRIENDLY `
            -Subject $subjectFinal `
            -KeyAlgorithm RSA `
            -KeyLength 2048 `
            -HashAlgorithm SHA256 `
            -KeyUsage DigitalSignature, KeyEncipherment `
            -KeyExportPolicy Exportable `
            -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.1") `
            -ErrorAction Stop

        $Script:SSL_THUMBPRINT = $cert.Thumbprint
        aputs_success "Certificado generado en almacén — Thumbprint: $($Script:SSL_THUMBPRINT)"
    }
    catch {
        aputs_error "Error al generar el certificado: $($_.Exception.Message)"
        return $false
    }

    # ── Paso 2: Exportar PFX (para IIS y Tomcat) ──────────────────────────────
    aputs_info "Exportando PFX para IIS/Tomcat..."
    try {
        $secPass = ConvertTo-SecureString $Script:SSL_PFX_PASS -AsPlainText -Force
        Export-PfxCertificate `
            -Cert "Cert:\LocalMachine\My\$($Script:SSL_THUMBPRINT)" `
            -FilePath $Script:SSL_PFX `
            -Password $secPass `
            -Force `
            -ErrorAction Stop | Out-Null
        aputs_success "PFX exportado: $($Script:SSL_PFX)"
    }
    catch {
        aputs_error "Error al exportar PFX: $($_.Exception.Message)"
        return $false
    }

    # ── Paso 3: Exportar PEM con openssl (para Apache y Nginx) ────────────────
    aputs_info "Exportando PEM (crt + key) con openssl para Apache/Nginx..."
    try {
        # Exportar PFX primero (ya hecho), luego convertir a PEM
        # Certificado público (.crt)
        $result = openssl pkcs12 `
            -in $Script:SSL_PFX `
            -clcerts -nokeys `
            -out $Script:SSL_CERT `
            -passin "pass:$($Script:SSL_PFX_PASS)" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "openssl pkcs12 -clcerts: $result" }
        aputs_success "Certificado PEM: $($Script:SSL_CERT)"

        # Clave privada (.key)
        $result = openssl pkcs12 `
            -in $Script:SSL_PFX `
            -nocerts -nodes `
            -out $Script:SSL_KEY `
            -passin "pass:$($Script:SSL_PFX_PASS)" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "openssl pkcs12 -nocerts: $result" }
        aputs_success "Clave privada PEM: $($Script:SSL_KEY)"

        # Restringir permisos de la clave (solo Admins)
        # Para archivos usar InheritanceFlags None (no ContainerInherit)
        try {
            $sidAdmin2  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
            $sidSystem2 = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
            $adminFileRule  = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sidAdmin2,  "FullControl", "None", "None", "Allow")
            $systemFileRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sidSystem2, "FullControl", "None", "None", "Allow")
            $aclKey = Get-Acl $Script:SSL_KEY
            $aclKey.SetAccessRuleProtection($true, $false)
            $aclKey.AddAccessRule($adminFileRule)
            $aclKey.AddAccessRule($systemFileRule)
            Set-Acl -Path $Script:SSL_KEY -AclObject $aclKey
        } catch {
            aputs_warning "No se pudieron restringir permisos del .key — continuando"
        }
    }
    catch {
        aputs_error "Error al exportar PEM: $_"
        aputs_info  "Apache y Nginx necesitan openssl — verificar instalación"
        return $false
    }

    # ── Paso 4: Agregar a hosts con el CN real (puede ser personalizado) ─────
    ssl_cert_agregar_hosts $certCN

    Write-Host ""
    aputs_success "Certificado listo"
    Write-Host ""
    Write-Host ("  {0,-12} {1}" -f "Almacén:",     "Cert:\LocalMachine\My")
    Write-Host ("  {0,-12} {1}" -f "Thumbprint:",  $Script:SSL_THUMBPRINT)
    Write-Host ("  {0,-12} {1}" -f "PFX:",         $Script:SSL_PFX)
    Write-Host ("  {0,-12} {1}" -f "CRT (PEM):",   $Script:SSL_CERT)
    Write-Host ("  {0,-12} {1}" -f "KEY (PEM):",   $Script:SSL_KEY)
    Write-Host ""
    return $true
}

# =============================================================================
# ssl_cert_mostrar_info
# =============================================================================
function ssl_cert_mostrar_info {
    # Intentar leer desde el almacén de Windows primero
    $cert = $null
    if (ssl_cert_importado) {
        $cert = Get-ChildItem Cert:\LocalMachine\My |
            Where-Object { $_.Thumbprint -eq $Script:SSL_THUMBPRINT } |
            Select-Object -First 1
    }

    if ($null -ne $cert) {
        aputs_info "Información del certificado (almacén Windows):"
        Write-Host ""
        Write-Host ("  {0,-16} {1}" -f "CN:",          ($cert.Subject -replace ".*CN=([^,]+).*", '$1'))
        Write-Host ("  {0,-16} {1}" -f "Subject:",     $cert.Subject)
        Write-Host ("  {0,-16} {1}" -f "Issuer:",      $cert.Issuer)
        Write-Host ("  {0,-16} {1}" -f "Válido desde:",$cert.NotBefore.ToString("yyyy-MM-dd HH:mm:ss"))
        Write-Host ("  {0,-16} {1}" -f "Válido hasta:",$cert.NotAfter.ToString("yyyy-MM-dd HH:mm:ss"))
        Write-Host ("  {0,-16} {1}" -f "Thumbprint:",  $cert.Thumbprint)
        Write-Host ""

        if ($cert.NotAfter -gt (Get-Date)) {
            aputs_success "Certificado VIGENTE"
        } else {
            aputs_error   "Certificado EXPIRADO"
        }
    }
    elseif (ssl_cert_existe) {
        # Fallback: leer el .crt con openssl
        aputs_info "Información del certificado (archivo PEM):"
        Write-Host ""
        $info = openssl x509 -in $Script:SSL_CERT -noout -subject -issuer -dates 2>&1
        $info | ForEach-Object { Write-Host "  $_" }
        Write-Host ""
    }
    else {
        aputs_warning "No existe certificado"
        aputs_info    "Ejecute la opción 1 para generarlo"
    }
}

# =============================================================================
# ssl_cert_agregar_hosts
# =============================================================================
function ssl_cert_agregar_hosts {
    param([string]$Dominio = $Script:SSL_DOMAIN)

    $hostsFile = "C:\Windows\System32\drivers\etc\hosts"
    $entrada   = "127.0.0.1  $Dominio"

    $contenido = Get-Content $hostsFile -ErrorAction SilentlyContinue
    if ($contenido -match [regex]::Escape($Dominio)) {
        aputs_info "hosts ya contiene entrada para $Dominio"
        return
    }

    try {
        Add-Content -Path $hostsFile -Value "" -Encoding ASCII
        Add-Content -Path $hostsFile -Value "# Practica7 SSL/TLS" -Encoding ASCII
        Add-Content -Path $hostsFile -Value $entrada -Encoding ASCII
        aputs_success "Añadido a hosts: $entrada"
    }
    catch {
        aputs_error "No se pudo modificar hosts: $($_.Exception.Message)"
    }
}

# =============================================================================
# ssl_menu_cert  — submenú interactivo
# =============================================================================
function ssl_menu_cert {
    while ($true) {
        Clear-Host
        ssl_mostrar_banner "Tarea 07 — Certificado SSL/TLS"

        if (ssl_cert_existe) {
            Write-Host "  Estado: ${GREEN}[● Certificado generado]${NC}"
        } else {
            Write-Host "  Estado: ${RED}[○ Sin certificado]${NC}"
        }
        Write-Host ""
        Write-Host "  ${BLUE}1)${NC} Generar certificado autofirmado"
        Write-Host "  ${BLUE}2)${NC} Ver información del certificado"
        Write-Host "  ${BLUE}3)${NC} Verificar entrada en hosts"
        Write-Host "  ${BLUE}0)${NC} Volver"
        Write-Host ""

        $op = Read-Host "  Opción"
        switch ($op) {
            "1" { ssl_cert_generar;     pause_menu }
            "2" { ssl_cert_mostrar_info; pause_menu }
            "3" {
                Write-Host ""
                aputs_info "Entradas de $($Script:SSL_DOMAIN) en hosts:"
                Write-Host ""
                $h = Get-Content "C:\Windows\System32\drivers\etc\hosts" |
                    Where-Object { $_ -match [regex]::Escape($Script:SSL_DOMAIN) }
                if ($h) { $h | ForEach-Object { Write-Host "  $_" } }
                else    { Write-Host "  (no encontrado)" }
                pause_menu
            }
            "0" { return }
            default { aputs_error "Opción inválida"; Start-Sleep -Seconds 1 }
        }
    }
}