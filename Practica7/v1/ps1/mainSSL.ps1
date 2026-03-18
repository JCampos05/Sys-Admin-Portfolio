#
# mainSSL.ps1
# Orquestador principal — Práctica 7 Windows Server
#

#Requires -Version 5.1
#Requires -RunAsAdministrator

# 
# RUTAS BASE
# 
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Definition
$P5_DIR     = Join-Path (Split-Path $SCRIPT_DIR -Parent) "P5"
$P6_DIR     = Join-Path (Split-Path $SCRIPT_DIR -Parent) "P6"
$P7_DIR     = $SCRIPT_DIR

# 
# VERIFICAR ESTRUCTURA DE ARCHIVOS
# 
function _verificar_estructura {
    $errores = 0

    $archivos = @(
        # P5
        "$P5_DIR\utils.ps1",
        "$P5_DIR\utilsFTP.ps1",
        "$P5_DIR\validatorsFTP.ps1",
        "$P5_DIR\FunctionsFTP-A.ps1",
        "$P5_DIR\FunctionsFTP-B.ps1",
        "$P5_DIR\FunctionsFTP-C.ps1",
        "$P5_DIR\FunctionsFTP-D.ps1",
        "$P5_DIR\mainFTP.ps1",
        # P6
        "$P6_DIR\utilsHTTP.ps1",
        "$P6_DIR\validatorsHTTP.ps1",
        "$P6_DIR\FunctionsHTTP-A.ps1",
        "$P6_DIR\FunctionsHTTP-B.ps1",
        "$P6_DIR\FunctionsHTTP-C.ps1",
        "$P6_DIR\FunctionsHTTP-D.ps1",
        "$P6_DIR\FunctionsHTTP-E.ps1",
        # P7
        "$P7_DIR\utilsSSL.ps1",
        "$P7_DIR\certSSL.ps1",
        "$P7_DIR\repoFTP.ps1",
        "$P7_DIR\HTTP-SSL.ps1",
        "$P7_DIR\verifySSL.ps1"
    )

    foreach ($f in $archivos) {
        if (-not (Test-Path $f)) {
            Write-Host "  [ERROR] No encontrado: $f" -ForegroundColor Red
            $errores++
        }
    }

    if ($errores -gt 0) {
        Write-Host ""
        Write-Host "  Verifique que P5, P6 y P7 están en el mismo directorio padre." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}

function _icono_estado {
    param([bool]$Ok)
    if ($Ok) { return "${GREEN}●${NC}" } else { return "${RED}○${NC}" }
}

function _estado_ftp {
    $svc = Get-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    return ($null -ne $svc -and $svc.Status -eq 'Running')
}

function _estado_ftps {
    try {
        Import-Module WebAdministration -EA Stop
        $ftpSite = Get-Website | Where-Object {
            (Get-WebBinding -Name $_.Name -EA SilentlyContinue |
             Where-Object { $_.Protocol -eq "ftp" }) -ne $null
        } | Select-Object -First 1
        if (-not $ftpSite) { return $false }
        $hash = Get-ItemProperty "IIS:\Sites\$($ftpSite.Name)" `
            -Name "ftpServer.security.ssl.serverCertHash" -EA SilentlyContinue
        return ($hash -and $hash -ne "")
    } catch { return $false }
}

function _estado_cert {
    if (Get-Command ssl_cert_existe -ErrorAction SilentlyContinue) {
        return [bool](ssl_cert_existe)
    }
    return [bool]((Test-Path $Script:SSL_CERT) -and (Test-Path $Script:SSL_KEY))
}

function _estado_repo {
    # Verificar repo local de instalación (C:\ssl\repositorio\)
    $countLocal = (Get-ChildItem $Script:SSL_REPO_LOCAL -Recurse -File `
        -Include "*.msi","*.exe","*.zip" -EA SilentlyContinue).Count
    if ($countLocal -gt 0) { return $true }

    # También verificar el repo FTP local (C:\FTP\LocalUser\repo\repositorio\http\Windows\)
    # Esta carpeta la crea repoFTP.ps1 con los instaladores descargados con choco
    if ($Script:SSL_REPO_WIN -and (Test-Path $Script:SSL_REPO_WIN -EA SilentlyContinue)) {
        $countFTP = (Get-ChildItem $Script:SSL_REPO_WIN -Recurse -File `
            -Include "*.msi","*.exe","*.zip","*.ps1" -EA SilentlyContinue).Count
        return ($countFTP -gt 0)
    }
    return $false
}

function _estado_http {
    foreach ($svc in @("iis","apache","nginx","tomcat")) {
        if (ssl_servicio_instalado $svc) { return $true }
    }
    return $false
}

function _estado_ssl_http {
    # Apache
    if (Test-Path $Script:SSL_CONF_APACHE_SSL) { return $true }
    # Nginx
    $c = Get-Content $Script:HTTP_CONF_NGINX -Raw -EA SilentlyContinue
    if ($c -match [regex]::Escape($Script:SSL_MARCA_NGINX)) { return $true }
    # Tomcat
    $c = Get-Content $Script:HTTP_CONF_TOMCAT -Raw -EA SilentlyContinue
    if ($c -match 'SSLEnabled="true"') { return $true }
    # IIS
    try {
        Import-Module WebAdministration -EA Stop
        $b = Get-WebBinding -Name "Default Web Site" -Protocol "https" -EA SilentlyContinue
        if ($b) { return $true }
    } catch {}
    return $false
}

# 
# PASOS
# 

function _paso_1_ftp {
    Clear-Host
    ssl_mostrar_banner "Paso 1 — Instalar y configurar FTP"
    aputs_info "Entrando al menú de instalación FTP (Práctica 5)..."
    Write-Host ""
    pause_menu

    # Intentar llamar al menú de P5 si está cargado
    if (Get-Command ftp_menu_instalacion -ErrorAction SilentlyContinue) {
        ftp_menu_instalacion
    }
    elseif (Get-Command Show-FtpMainMenu -ErrorAction SilentlyContinue) {
        Show-FtpMainMenu
    }
    else {
        # Fallback: ejecutar mainFTP.ps1 directamente
        aputs_info "Cargando menú FTP de P5..."
        & "$P5_DIR\mainFTP.ps1"
    }
}

function _paso_2_cert {
    Clear-Host
    ssl_mostrar_banner "Paso 2 — Generar certificado SSL"

    Write-Host ""
    Write-Host "  ${CYAN}Este paso generará:${NC}"
    Write-Host "    • Certificado autofirmado reprobados.com"
    Write-Host "    • Clave privada RSA 2048 bits"
    Write-Host "    • PFX para IIS y Tomcat"
    Write-Host "    • PEM (.crt/.key) para Apache y Nginx"
    Write-Host ""

    $resp = Read-MenuInput "¿Generar/regenerar el certificado SSL? [S/n]"
    if ($resp -match '^[Nn]$') {
        aputs_info "Omitido — puede generarlo desde el menú principal (opción C)"
        pause_menu
        return
    }

    ssl_cert_generar
    pause_menu
}

function _paso_3_repo {
    Clear-Host
    ssl_mostrar_banner "Paso 3 — Descargar instaladores del repositorio FTP"

    Write-Host ""
    Write-Host "  ${CYAN}Este paso descargará instaladores desde:${NC}"
    Write-Host "    ftp://$($Script:SSL_FTP_SERVER)/repositorio/http/Windows/"
    Write-Host "    └── IIS/ Apache/ Nginx/ Tomcat/"
    Write-Host ""
    Write-Host "  ${GRAY}Los instaladores se guardan en: $($Script:SSL_REPO_LOCAL)${NC}"
    Write-Host ""

    ssl_menu_repo
}

function _paso_4_http {
    Clear-Host
    ssl_mostrar_banner "Paso 4 — Instalar y configurar HTTP"
    aputs_info "Entrando al menú de instalación HTTP (Práctica 6)..."

    # Mostrar instaladores disponibles en el repo local
    if (Test-Path $Script:SSL_REPO_LOCAL) {
        $rpms = Get-ChildItem $Script:SSL_REPO_LOCAL -Recurse -File `
            -Include "*.msi","*.exe","*.zip" -ErrorAction SilentlyContinue
        if ($rpms.Count -gt 0) {
            Write-Host ""
            aputs_info "Instaladores disponibles en el repositorio local:"
            Write-Host ""
            $rpms | ForEach-Object { Write-Host "    $($_.Name)" }
            Write-Host ""
            draw_line
        }
    }

    Write-Host ""
    pause_menu

    if (Get-Command http_menu_instalar -ErrorAction SilentlyContinue) {
        http_menu_instalar
    }
    else {
        aputs_error "http_menu_instalar no encontrada"
        aputs_info  "Verifique que FunctionsHTTP-B.ps1 se cargó correctamente"
        pause_menu
        return
    }
}

function _paso_5_ssl {
    Clear-Host
    ssl_mostrar_banner "Paso 5 — Configurar SSL/HTTPS + FTPS"

    # Verificar que hay servicios HTTP instalados
    if (-not (_estado_http)) {
        aputs_error "No hay servicios HTTP instalados"
        aputs_info  "Ejecute primero el Paso 4 — Instalar HTTP"
        pause_menu
        return
    }

    Write-Host ""
    Write-Host "  ${CYAN}Este paso configurará:${NC}"
    Write-Host "    • Certificado SSL (si no existe)"
    Write-Host "    • HTTPS en los servicios HTTP instalados"
    Write-Host "    • Redirect HTTP → HTTPS"
    Write-Host "    • FTPS en IIS-FTP (opcional)"
    Write-Host ""

    $resp = Read-MenuInput "¿Aplicar SSL/HTTPS? [S/n]"
    if ($resp -match '^[Nn]$') {
        aputs_info "SSL/HTTPS omitido"
        pause_menu
        return
    }

    Write-Host ""

    # Generar certificado si no existe
    if (-not (ssl_cert_existe)) {
        aputs_info "El certificado no existe — generando..."
        Write-Host ""
        if (-not (ssl_cert_generar)) { pause_menu; return }
        Write-Host ""
    }
    else {
        aputs_info "Certificado ya existe — reutilizando"
        ssl_cert_mostrar_info
        Write-Host ""
    }

    # Aplicar SSL a servicios HTTP
    ssl_http_aplicar_todos

    # Ofrecer configurar FTPS
    Write-Host ""
    $respFtp = Read-MenuInput "¿Configurar también FTPS en IIS-FTP? [s/N]"
    if ($respFtp -match '^[Ss]$') {
        ssl_ftp_aplicar_iis
    }

    pause_menu
}

function _paso_6_testing {
    ssl_verify_todo
    pause_menu
}

# 
# MENÚ PRINCIPAL
# 
function _dibujar_menu {
    Clear-Host

    $s1    = _icono_estado (_estado_ftp)
    $s2    = _icono_estado (_estado_ftps)
    $sCert = _icono_estado (_estado_cert)
    $s3    = _icono_estado (_estado_repo)
    $s4    = _icono_estado (_estado_http)
    $s5    = _icono_estado (_estado_ssl_http)

    Write-Host ""
    Write-Host "${CYAN}╔══════════════════════════════════════════╗${NC}"
    Write-Host "${CYAN}║${NC}    Infraestructura Segura FTP/HTTP       ${CYAN}║${NC}"
    Write-Host "${CYAN}╚══════════════════════════════════════════╝${NC}"
    Write-Host ""

    Write-Host "  Certificado SSL: $sCert"
    Write-Host ""

    Write-Host "  ${GRAY}── Fase FTP ──────────────────────────────────────────${NC}"
    Write-Host "  ${BLUE}1)${NC} $s1 Instalar y configurar FTP (IIS-FTP)"
    Write-Host "  ${BLUE}2)${NC} $s2 Configurar FTPS/TLS          ${GRAY}(requiere paso 1)${NC}"
    Write-Host ""

    Write-Host "  ${GRAY}── Fase Repositorio ──────────────────────────────────${NC}"
    Write-Host "  ${BLUE}3)${NC} $s3 Descargar instaladores del repo FTP Linux"
    Write-Host ""

    Write-Host "  ${GRAY}── Fase HTTP ─────────────────────────────────────────${NC}"
    Write-Host "  ${BLUE}4)${NC} $s4 Instalar y configurar HTTP"
    Write-Host "  ${BLUE}5)${NC} $s5 Configurar SSL/HTTPS          ${GRAY}(requiere paso 4)${NC}"
    Write-Host ""

    Write-Host "  ${GRAY}── Extras ────────────────────────────────────────────${NC}"
    Write-Host "  ${BLUE}6)${NC}    Verificación general completa"
    Write-Host "  ${BLUE}F)${NC}    Menú completo FTP    ${GRAY}(Práctica 5)${NC}"
    Write-Host "  ${BLUE}H)${NC}    Menú completo HTTP   ${GRAY}(Práctica 6)${NC}"
    Write-Host "  ${BLUE}C)${NC}    Gestionar certificado SSL"
    Write-Host "  ${BLUE}R)${NC}    Menú repositorio FTP"
    Write-Host ""
    Write-Host "  ${BLUE}0)${NC}    Salir"
    Write-Host ""
}

function main_menu {
    while ($true) {
        _dibujar_menu

        $op = Read-Host "  Opción"

        switch ($op.ToUpper()) {
            "1" { _paso_1_ftp   }
            "2" {
                # FTPS directamente (sin pasar por _paso_5_ssl)
                Clear-Host
                ssl_mostrar_banner "Paso 2 — Configurar FTPS en IIS-FTP"
                if (-not (ssl_cert_existe)) {
                    aputs_error "Genere el certificado primero (opción C)"
                    pause_menu
                } else {
                    ssl_ftp_aplicar_iis
                    pause_menu
                }
            }
            "3" { _paso_3_repo  }
            "4" { _paso_4_http  }
            "5" { _paso_5_ssl   }
            "6" { _paso_6_testing }

            "F" {
                if (Get-Command ftp_menu_principal -EA SilentlyContinue) {
                    ftp_menu_principal
                } elseif (Get-Command Show-FtpMainMenu -EA SilentlyContinue) {
                    Show-FtpMainMenu
                } else {
                    & "$P5_DIR\mainFTP.ps1"
                }
            }
            "H" {
                if (Get-Command http_menu_principal -EA SilentlyContinue) {
                    http_menu_principal
                } else {
                    & "$P6_DIR\mainHTTP.ps1"
                }
            }
            "C" { ssl_menu_cert   }
            "R" { ssl_menu_repo   }

            "0" {
                Write-Host ""
                aputs_info "Saliendo de la Práctica 7..."
                Write-Host ""
                exit 0
            }
            default {
                aputs_error "Opción inválida"
                Start-Sleep -Seconds 1
            }
        }
    }
}

# 
# PUNTO DE ENTRADA
# 

. "$P7_DIR\utils.ps1"

# También cargar Read-MenuInput si está en utils o en un helper inline
# (algunos builds de P6 lo tienen en utilsHTTP.ps1 — aquí definimos fallback)
if (-not (Get-Command Read-MenuInput -ErrorAction SilentlyContinue)) {
    function Read-MenuInput {
        param([string]$Prompt)
        Write-Host -NoNewline "${CYAN}[INPUT]${NC}   $Prompt`: "
        return (Read-Host)
    }
}

# 2. Verificar privilegios (check_privileges ya está definida desde utils.ps1)
if (-not (check_privileges)) {
    Write-Host ""
    aputs_error "Este script requiere permisos de Administrador."
    aputs_info  "Haga clic derecho en PowerShell → 'Ejecutar como administrador'"
    Write-Host ""
    exit 1
}

# 3. Verificar estructura de archivos
_verificar_estructura

# 4. Cargar todos los módulos con dot-source a nivel raíz del script
# (dot-source dentro de funciones no expone las definiciones al scope del caller)

# ── P5 — FTP ────────────────────────────────────────────────────────────────
. "$P5_DIR\utils.ps1"
. "$P5_DIR\utilsFTP.ps1"
. "$P5_DIR\validatorsFTP.ps1"
. "$P5_DIR\FunctionsFTP-A.ps1"
. "$P5_DIR\FunctionsFTP-B.ps1"
. "$P5_DIR\FunctionsFTP-C.ps1"
. "$P5_DIR\FunctionsFTP-D.ps1"

# ── P6 — HTTP ───────────────────────────────────────────────────────────────
. "$P6_DIR\utilsHTTP.ps1"
. "$P6_DIR\validatorsHTTP.ps1"
. "$P6_DIR\FunctionsHTTP-A.ps1"
. "$P6_DIR\FunctionsHTTP-B.ps1"
. "$P6_DIR\FunctionsHTTP-C.ps1"
. "$P6_DIR\FunctionsHTTP-D.ps1"
. "$P6_DIR\FunctionsHTTP-E.ps1"

# Detectar rutas reales ANTES de cargar utilsSSL.ps1
http_detectar_rutas_reales

# ── P7 — SSL/TLS ─────────────────────────────────────────────────────────────
. "$P7_DIR\utilsSSL.ps1"
. "$P7_DIR\certSSL.ps1"
. "$P7_DIR\repoFTP.ps1"
. "$P7_DIR\HTTP-SSL.ps1"
. "$P7_DIR\verifySSL.ps1"
. "$P7_DIR\repoHTTP.ps1"  # al final para que sus overrides no sean sobreescritos

# Inicializar rutas SSL que dependen de las rutas HTTP detectadas
Get-SslConfApacheSsl  | Out-Null
Get-SslKeystoreTomcat | Out-Null

# 4. Dependencias HTTP (choco, curl, etc.)
if (-not (http_verificar_dependencias)) {
    Write-Host ""
    aputs_error "Dependencias faltantes. Resuelva los errores antes de continuar."
    pause_menu
    exit 1
}

# Verificar e instalar openssl antes de entrar al menú
# openssl es necesario para exportar certificados a PEM (Apache/Nginx)
aputs_info "Verificando openssl..."
$opensslOk = Get-Command openssl -ErrorAction SilentlyContinue
if (-not $opensslOk) {
    aputs_info "openssl no encontrado — instalando con choco..."
    & choco install openssl -y --no-progress 2>&1 | Out-Null
    # Refrescar PATH para que openssl sea visible en esta sesión
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
    $opensslOk = Get-Command openssl -ErrorAction SilentlyContinue
    if ($opensslOk) {
        aputs_success "openssl instalado: $(openssl version 2>&1 | Select-Object -First 1)"
    } else {
        aputs_warning "openssl no pudo instalarse — la generacion de certificados puede fallar"
        aputs_info    "Instale manualmente: choco install openssl -y"
    }
} else {
    aputs_success "openssl disponible: $(openssl version 2>&1 | Select-Object -First 1)"
}

Write-Host ""
pause_menu

# 5. Menú principal
main_menu