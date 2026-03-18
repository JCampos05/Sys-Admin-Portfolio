#
# utilsSSL.ps1
# Constantes globales y helpers compartidos para SSL/TLS — Windows Server
#
# Uso: . "$PSScriptRoot\utilsSSL.ps1"
# Requiere: utils.ps1, utilsHTTP.ps1 cargados previamente
#
. "$PSScriptRoot\utils.ps1"  # garantiza aputs_*, draw_line, check_connectivity en este scope


#Requires -Version 5.1

# 
# CONSTANTES DE CERTIFICADO
# Todos los servicios (IIS, Apache, Nginx, Tomcat, IIS-FTP) usan el mismo par
# 

# Directorio donde viven el certificado y la clave
$Script:SSL_DIR = "C:\ssl\reprobados"

# Ruta del certificado en formato PEM (para Apache, Nginx)
$Script:SSL_CERT = "$($Script:SSL_DIR)\reprobados.crt"

# Ruta de la clave privada PEM (para Apache, Nginx)
$Script:SSL_KEY = "$($Script:SSL_DIR)\reprobados.key"

# Certificado en formato PFX/PKCS12 (para IIS, Tomcat)
$Script:SSL_PFX = "$($Script:SSL_DIR)\reprobados.pfx"

# Contraseña del PFX — simple para entorno de clase
$Script:SSL_PFX_PASS = "reprobados"

# Nombre de dominio — CN del certificado (debe coincidir con Linux)
$Script:SSL_DOMAIN = "reprobados.com"

# Días de validez del certificado
$Script:SSL_DAYS = 365

# Huella del certificado en el almacén de Windows (se llena tras importar)
$Script:SSL_THUMBPRINT = ""

# Nombre amistoso en el almacén de certificados de Windows
$Script:SSL_CERT_FRIENDLY = "reprobados_p7"

# 
# El script de Windows descarga los instaladores desde el repositorio FTP
# 

$Script:SSL_FTP_SERVER = "192.168.100.10"
$Script:SSL_FTP_USER = "repo"
$Script:SSL_FTP_PASS = "reprobados"
$Script:SSL_FTP_REPO_BASE  = "/repositorio/http/Windows"
$Script:SSL_FTP_REPO_IIS   = "$($Script:SSL_FTP_REPO_BASE)/IIS"
$Script:SSL_FTP_REPO_APACHE = "$($Script:SSL_FTP_REPO_BASE)/Apache"
$Script:SSL_FTP_REPO_NGINX  = "$($Script:SSL_FTP_REPO_BASE)/Nginx"
$Script:SSL_FTP_REPO_TOMCAT = "$($Script:SSL_FTP_REPO_BASE)/Tomcat"

# Directorio local donde se descargan los instaladores antes de instalar
$Script:SSL_REPO_LOCAL = "C:\ssl\repositorio"

# 
# CONSTANTES DE CONFIGURACIÓN SSL POR SERVICIO
# 

# Apache: archivo de VirtualHost SSL dedicado
# NOTA: se calcula en tiempo de ejecución con Get-SslConfApacheSsl
# porque HTTP_CONF_APACHE puede no estar resuelto al cargar este módulo
$Script:SSL_CONF_APACHE_SSL = ""   # se rellena por Get-SslConfApacheSsl

# Tomcat: keystore PKCS12
$Script:SSL_KEYSTORE_TOMCAT = ""   # se rellena por Get-SslKeystoreTomcat

# Funciones lazy para obtener las rutas derivadas en tiempo de ejecución
function Get-SslConfApacheSsl {
    if ($Script:HTTP_CONF_APACHE -and (Test-Path (Split-Path $Script:HTTP_CONF_APACHE -Parent))) {
        $Script:SSL_CONF_APACHE_SSL = "$(Split-Path $Script:HTTP_CONF_APACHE -Parent)\ssl_reprobados.conf"
    } elseif (-not $Script:SSL_CONF_APACHE_SSL) {
        $Script:SSL_CONF_APACHE_SSL = "C:\tools\httpd\conf\ssl_reprobados.conf"
    }
    return $Script:SSL_CONF_APACHE_SSL
}

function Get-SslKeystoreTomcat {
    if ($Script:HTTP_CONF_TOMCAT -and (Test-Path (Split-Path $Script:HTTP_CONF_TOMCAT -Parent) -ErrorAction SilentlyContinue)) {
        $Script:SSL_KEYSTORE_TOMCAT = "$(Split-Path $Script:HTTP_CONF_TOMCAT -Parent)\reprobados.p12"
    } elseif (-not $Script:SSL_KEYSTORE_TOMCAT) {
        $Script:SSL_KEYSTORE_TOMCAT = "C:\ProgramData\Tomcat9\conf\reprobados.p12"
    }
    return $Script:SSL_KEYSTORE_TOMCAT
}

# Marca de identificación de bloques insertados (igual que Linux para consistencia)
$Script:SSL_MARCA_APACHE = "# === Practica7 SSL Apache ==="
$Script:SSL_MARCA_NGINX  = "# === Practica7 SSL Nginx ==="

# 
# LÓGICA DE PUERTOS HTTPS
# 

# ssl_puerto_https <puertoHttp>  ->   devuelve el puerto HTTPS asignado
function ssl_puerto_https {
    param([int]$HttpPort)
    switch ($HttpPort) {
        80   { return 443  }
        8080 { return 8443 }
        default { return ($HttpPort + 363) }
    }
}

function ssl_leer_puerto_https {
    param([string]$Servicio)

    switch ($Servicio.ToLower()) {
        "iis" {
            try {
                Import-Module WebAdministration -ErrorAction Stop
                $binding = Get-WebBinding -Name "Default Web Site" `
                    -Protocol "https" -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($binding) {
                    $port = $binding.bindingInformation -replace ".*:(\d+):.*", '$1'
                    if ($port -match '^\d+$') { return [int]$port }
                }
            } catch {}
            # Fallback al calculado
            return ssl_puerto_https (ssl_leer_puerto_http "iis")
        }

        "apache" {
            # Leer el Listen del VirtualHost SSL en ssl_reprobados.conf
            $confSsl = $Script:SSL_CONF_APACHE_SSL
            if (Test-Path $confSsl) {
                $listen = Select-String -Path $confSsl `
                    -Pattern "^Listen\s+(0\.0\.0\.0:)?(\d+)" |
                    Select-Object -First 1
                if ($listen -and $listen.Matches[0].Groups[2].Value) {
                    return [int]$listen.Matches[0].Groups[2].Value
                }
            }
            return ssl_puerto_https (ssl_leer_puerto_http "apache")
        }

        "nginx" {
            # Leer el listen con ssl en nginx.conf (excluir líneas comentadas)
            if (Test-Path $Script:HTTP_CONF_NGINX) {
                $lineas = Get-Content $Script:HTTP_CONF_NGINX
                foreach ($linea in $lineas) {
                    $trim = $linea.TrimStart()
                    if ($trim.StartsWith('#')) { continue }
                    # Buscar: listen [0.0.0.0:]PUERTO ssl;
                    if ($trim -match '^\s*listen\s+(?:0\.0\.0\.0:)?(\d+)\s+ssl') {
                        return [int]$Matches[1]
                    }
                }
            }
            return ssl_puerto_https (ssl_leer_puerto_http "nginx")
        }

        "tomcat" {
            # Leer el Connector SSL en server.xml
            if (Test-Path $Script:HTTP_CONF_TOMCAT) {
                try {
                    [xml]$doc = [System.IO.File]::ReadAllText(
                        $Script:HTTP_CONF_TOMCAT,
                        [System.Text.Encoding]::UTF8)
                    $service = $doc.Server.Service |
                        Where-Object { $_.name -eq "Catalina" } |
                        Select-Object -First 1
                    if (-not $service) {
                        $service = $doc.Server.Service | Select-Object -First 1
                    }
                    foreach ($c in $service.Connector) {
                        if ($c.SSLEnabled -eq "true" -and $c.port -match '^\d+$') {
                            return [int]$c.port
                        }
                    }
                } catch {}
            }
            return ssl_puerto_https (ssl_leer_puerto_http "tomcat")
        }

        default {
            return ssl_puerto_https (ssl_leer_puerto_http $Servicio)
        }
    }
}

function ssl_leer_puerto_http {
    param([string]$Servicio)

    switch ($Servicio.ToLower()) {
        "iis" {
            # IIS: leer el primer binding HTTP del sitio Default Web Site
            try {
                Import-Module WebAdministration -ErrorAction Stop
                $binding = Get-WebBinding -Name "Default Web Site" `
                    -Protocol "http" -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($binding) {
                    $port = $binding.bindingInformation -replace ".*:(\d+):.*", '$1'
                    if ($port -match '^\d+$') { return [int]$port }
                }
            } catch {}
            return 80
        }
        "apache" {
            $conf = $Script:HTTP_CONF_APACHE
            if (Test-Path $conf) {
                $listen = Select-String -Path $conf -Pattern "^Listen\s+(\d+)" |
                    Select-Object -First 1
                if ($listen) {
                    return [int]($listen.Matches[0].Groups[1].Value)
                }
            }
            return 80
        }
        "nginx" {
            $conf = $Script:HTTP_CONF_NGINX
            if (Test-Path $conf) {
                $listen = Select-String -Path $conf -Pattern "^\s+listen\s+(\d+)\s*;" |
                    Where-Object { $_.Line -notmatch "ssl" } |
                    Select-Object -First 1
                if ($listen) {
                    return [int]($listen.Matches[0].Groups[1].Value)
                }
            }
            return 80
        }
        "tomcat" {
            $conf = $Script:HTTP_CONF_TOMCAT
            if (Test-Path $conf) {
                $connector = Select-String -Path $conf `
                    -Pattern 'protocol="HTTP/1\.1"' |
                    Select-Object -First 1
                if ($connector) {
                    if ($connector.Line -match 'port="(\d+)"') {
                        return [int]$Matches[1]
                    }
                }
            }
            return 8080
        }
        default { return 80 }
    }
}

# 
# HELPERS DE ESTADO
# 

# ssl_cert_existe  ->   $true si el par clave+certificado ya fue generado
function ssl_cert_existe {
    return ((Test-Path $Script:SSL_CERT) -and (Test-Path $Script:SSL_KEY))
}

# ssl_pfx_existe  ->   $true si el PFX (para IIS/Tomcat) ya existe
function ssl_pfx_existe {
    return (Test-Path $Script:SSL_PFX)
}

# ssl_cert_importado  ->   $true si el certificado está en el almacén de Windows
function ssl_cert_importado {
    $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -eq $Script:SSL_CERT_FRIENDLY } |
        Select-Object -First 1
    if ($cert) {
        $Script:SSL_THUMBPRINT = $cert.Thumbprint
        return $true
    }
    return $false
}

# ssl_servicio_instalado <servicio>  ->   $true si el servicio Windows existe
function ssl_servicio_instalado {
    param([string]$Servicio)
    # Intentar con http_nombre_winsvc de utilsHTTP.ps1 si está disponible
    if (Get-Command http_nombre_winsvc -ErrorAction SilentlyContinue) {
        $winsvc = http_nombre_winsvc $Servicio
    } else {
        # Fallback interno si utilsHTTP.ps1 no está cargado aún
        $winsvc = switch ($Servicio.ToLower()) {
            "iis"    { "W3SVC"    }
            "apache" { "Apache2.4" }
            "nginx"  { "nginx"    }
            "tomcat" { "Tomcat9"  }
            default  { $Servicio  }
        }
    }
    $svc = Get-Service -Name $winsvc -ErrorAction SilentlyContinue
    if ($null -ne $svc) { return $true }

    # Nginx desde ZIP no tiene servicio Windows — detectar por proceso o conf
    if ($Servicio.ToLower() -eq "nginx") {
        # Verificar si nginx.exe está corriendo como proceso
        $proc = Get-Process -Name "nginx" -ErrorAction SilentlyContinue
        if ($proc) { return $true }
        # Verificar si existe nginx.conf en C:\tools (ruta típica de instalación manual)
        $nginxConf = Get-ChildItem "C:\tools" -Recurse -Filter "nginx.conf" `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($nginxConf) { return $true }
    }

    return $false
}

# ssl_servicio_activo <servicio>  ->   $true si el servicio está corriendo
function ssl_servicio_activo {
    param([string]$Servicio)
    $winsvc = http_nombre_winsvc $Servicio
    return (check_service_active $winsvc)
}

# 
# HELPERS DE BACKUP Y VISUAL
# 

function ssl_hacer_backup {
    param([string]$Archivo)
    if (-not (Test-Path $Archivo)) { return }
    http_crear_backup $Archivo
}

function ssl_mostrar_banner {
    param([string]$Titulo = "SSL/TLS")
    Write-Host ""
    Write-Host "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    $pad = " " * [Math]::Max(0, 44 - $Titulo.Length)
    Write-Host "${CYAN}║${NC}  $Titulo$pad${CYAN}║${NC}"
    Write-Host "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    Write-Host ""
}

# 
# FIREWALL WINDOWS
# 

function ssl_abrir_puerto_firewall {
    param([int]$Puerto, [string]$Descripcion = "Practica7 SSL")

    $ruleName = "P7_SSL_TCP_$Puerto"

    # Verificar si la regla ya existe
    $existe = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existe) {
        aputs_info "Regla firewall ya existe: $ruleName"
        return
    }

    try {
        New-NetFirewallRule `
            -DisplayName $ruleName `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort $Puerto `
            -Action Allow `
            -Profile Any `
            -ErrorAction Stop | Out-Null
        aputs_success "Puerto ${Puerto}/tcp abierto en firewall: $ruleName"
    }
    catch {
        aputs_warning "No se pudo crear regla firewall con New-NetFirewallRule"
        aputs_info    "Intentando con netsh..."
        netsh advfirewall firewall add rule `
            name="$ruleName" `
            protocol=TCP `
            dir=in `
            localport=$Puerto `
            action=allow | Out-Null
        if ($LASTEXITCODE -eq 0) {
            aputs_success "Puerto ${Puerto}/tcp abierto en firewall (netsh)"
        } else {
            aputs_error "No se pudo abrir el puerto $Puerto en el firewall"
        }
    }
}

# 
# DESCARGA DESDE REPOSITORIO FTP
# 

# ssl_ftp_listar_archivos <rutaFtp>  ->   lista de nombres de archivo
function ssl_ftp_listar_archivos {
    param([string]$RutaFtp)

    $uri = "ftp://$($Script:SSL_FTP_SERVER)$RutaFtp/"
    try {
        $request = [System.Net.FtpWebRequest]::Create($uri)
        $request.Method      = [System.Net.WebRequestMethods+Ftp]::ListDirectory
        $request.Credentials = New-Object System.Net.NetworkCredential(
            $Script:SSL_FTP_USER, $Script:SSL_FTP_PASS)
        $request.UsePassive  = $true
        $request.UseBinary   = $true
        $request.KeepAlive   = $false

        $response = $request.GetResponse()
        $reader   = New-Object System.IO.StreamReader($response.GetResponseStream())
        $content  = $reader.ReadToEnd()
        $reader.Close()
        $response.Close()

        return ($content -split "`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne "" })
    }
    catch {
        aputs_error "No se pudo listar FTP: $uri"
        aputs_error $_.Exception.Message
        return @()
    }
}

# ssl_ftp_descargar <rutaFtp> <archivoNombre> <destLocal>
function ssl_ftp_descargar {
    param(
        [string]$RutaFtp,
        [string]$Archivo,
        [string]$DestLocal
    )

    $uri = "ftp://$($Script:SSL_FTP_SERVER)$RutaFtp/$Archivo"
    $destFile = Join-Path $DestLocal $Archivo

    aputs_info "Descargando: $Archivo"
    aputs_info "Desde: $uri"
    aputs_info "Hacia: $destFile"

    try {
        $request = [System.Net.FtpWebRequest]::Create($uri)
        $request.Method      = [System.Net.WebRequestMethods+Ftp]::DownloadFile
        $request.Credentials = New-Object System.Net.NetworkCredential(
            $Script:SSL_FTP_USER, $Script:SSL_FTP_PASS)
        $request.UsePassive  = $true
        $request.UseBinary   = $true
        $request.KeepAlive   = $false

        $response = $request.GetResponse()
        $stream   = $response.GetResponseStream()
        $file     = [System.IO.File]::Create($destFile)
        $stream.CopyTo($file)
        $file.Close()
        $stream.Close()
        $response.Close()

        $size = (Get-Item $destFile).Length
        aputs_success "Descargado: $Archivo ($([Math]::Round($size/1KB, 1)) KB)"
        return $destFile
    }
    catch {
        aputs_error "Error al descargar: $Archivo"
        aputs_error $_.Exception.Message
        return $null
    }
}

# ssl_verificar_sha256 <archivoInstalador> <archivoSha256>  ->   $true si OK
function ssl_verificar_sha256 {
    param(
        [string]$Archivo,
        [string]$Sha256File
    )

    if (-not (Test-Path $Sha256File)) {
        aputs_warning "Archivo .sha256 no encontrado: $Sha256File"
        return $false
    }

    # El .sha256 contiene: "<hash>  <nombre_archivo>"
    $contenido  = (Get-Content $Sha256File -Raw).Trim()
    $hashEsperado = ($contenido -split '\s+')[0].ToLower()

    $hashActual = (Get-FileHash -Path $Archivo -Algorithm SHA256).Hash.ToLower()

    if ($hashActual -eq $hashEsperado) {
        aputs_success "SHA256 OK: $([System.IO.Path]::GetFileName($Archivo))"
        return $true
    }
    else {
        aputs_error "SHA256 FALLO: $([System.IO.Path]::GetFileName($Archivo))"
        Write-Host "  Esperado: $hashEsperado"
        Write-Host "  Actual:   $hashActual"
        return $false
    }
}