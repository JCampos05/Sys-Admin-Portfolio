#
# repoFTP.ps1
# Repositorio FTP de instaladores Windows — Práctica 7
#
#
. "$PSScriptRoot\utils.ps1"  # garantiza aputs_*, draw_line, check_connectivity en este scope


#Requires -Version 5.1

# (guardia eliminada — dot-source controlado por mainSSL.ps1)

# 
# CONSTANTES DEL REPOSITORIO
# Se derivan de FTP_ROOT de P5 — el repositorio vive dentro del árbol FTP
# 

$Script:SSL_REPO_FTP_USER = "repo"

# Las rutas del repositorio se resuelven en tiempo de ejecución porque
# $script:FTP_ROOT viene de subMainFTP.ps1 de P5 y su scope puede variar.
# _ssl_repo_init_rutas() se llama automáticamente la primera vez que se necesitan.
$Script:SSL_REPO_USER_DIR = ""
$Script:SSL_REPO_ROOT     = ""
$Script:SSL_REPO_WIN      = ""
$Script:SSL_REPO_IIS      = ""
$Script:SSL_REPO_APACHE   = ""
$Script:SSL_REPO_NGINX    = ""
$Script:SSL_REPO_TOMCAT   = ""

function _ssl_repo_init_rutas {
    # Obtener FTP_ROOT desde múltiples scopes posibles
    # subMainFTP.ps1 de P5 define $script:FTP_ROOT pero ese scope puede no
    # propagarse a módulos de P7. Buscar en todos los scopes disponibles.
    $ftpRoot = $null
    if ((Get-Variable FTP_ROOT -Scope Script -ErrorAction SilentlyContinue) -and $script:FTP_ROOT) {
        $ftpRoot = $script:FTP_ROOT
    } elseif ((Get-Variable FTP_ROOT -Scope Global -ErrorAction SilentlyContinue) -and $global:FTP_ROOT) {
        $ftpRoot = $global:FTP_ROOT
    } else {
        # Fallback: leer directamente de subMainFTP.ps1 si existe
        $subMain = Join-Path (Split-Path $PSScriptRoot -Parent) "P5\subMainFTP.ps1"
        if (Test-Path $subMain) {
            $lineaRoot = Get-Content $subMain | Where-Object { $_ -match '^\$script:FTP_ROOT\s*=' } | Select-Object -First 1
            if ($lineaRoot -match '"([^"]+)"') { $ftpRoot = $Matches[1] }
        }
        if (-not $ftpRoot) { $ftpRoot = "C:\FTP" }
    }

    $Script:SSL_REPO_USER_DIR = "$ftpRoot\LocalUser\$($Script:SSL_REPO_FTP_USER)"
    $Script:SSL_REPO_ROOT     = "$($Script:SSL_REPO_USER_DIR)\repositorio"
    $Script:SSL_REPO_WIN      = "$($Script:SSL_REPO_ROOT)\http\Windows"
    $Script:SSL_REPO_IIS      = "$($Script:SSL_REPO_WIN)\IIS"
    $Script:SSL_REPO_APACHE   = "$($Script:SSL_REPO_WIN)\Apache"
    $Script:SSL_REPO_NGINX    = "$($Script:SSL_REPO_WIN)\Nginx"
    $Script:SSL_REPO_TOMCAT   = "$($Script:SSL_REPO_WIN)\Tomcat"
}

# Inicializar inmediatamente (FTP_ROOT ya debería estar disponible al cargar este módulo)
_ssl_repo_init_rutas

# 
# HELPERS INTERNOS
# 

function _ssl_repo_dir_servicio {
    param([string]$Servicio)
    switch ($Servicio.ToLower()) {
        "iis"    { return $Script:SSL_REPO_IIS    }
        "apache" { return $Script:SSL_REPO_APACHE }
        "nginx"  { return $Script:SSL_REPO_NGINX  }
        "tomcat" { return $Script:SSL_REPO_TOMCAT }
        default  { aputs_error "Servicio desconocido: $Servicio"; return $null }
    }
}

function _ssl_repo_generar_sha256 {
    param([string]$Archivo)
    $sha256File = "$Archivo.sha256"
    $nombre     = Split-Path $Archivo -Leaf
    try {
        $hash = (Get-FileHash -Path $Archivo -Algorithm SHA256).Hash.ToLower()
        "$hash  $nombre" | Set-Content -Path $sha256File -Encoding ASCII
        aputs_success "$nombre.sha256 -> $($hash.Substring(0,16))..."
        return $true
    }
    catch {
        aputs_error "No se pudo generar SHA256 para: $nombre — $($_.Exception.Message)"
        return $false
    }
}

# 
# ssl_repo_crear_estructura
# 
function ssl_repo_crear_estructura {
    _ssl_repo_init_rutas
    ssl_mostrar_banner "Repositorio FTP — Crear Estructura"

    aputs_info "Raíz FTP : $($script:FTP_ROOT)"
    aputs_info "Repo user: $($Script:SSL_REPO_USER_DIR)"
    Write-Host ""

    # ── Crear carpetas ────────────────────────────────────────────────────────
    foreach ($dir in @($Script:SSL_REPO_IIS, $Script:SSL_REPO_APACHE,
                       $Script:SSL_REPO_NGINX, $Script:SSL_REPO_TOMCAT)) {
        if (Test-Path $dir) {
            aputs_info "Ya existe: $dir"
        } else {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            aputs_success "Creado: $dir"
        }
    }

    Write-Host ""

    # Crear usuario "repo" si no existe <------------------------------------------------
    aputs_info "Verificando usuario '$($Script:SSL_REPO_FTP_USER)'..."
    Write-Host ""

    if (Get-LocalUser -Name $Script:SSL_REPO_FTP_USER -ErrorAction SilentlyContinue) {
        aputs_info "Usuario '$($Script:SSL_REPO_FTP_USER)' ya existe"
    }
    else {
        # Pedir contraseña — usar SecureString directamente sin convertir a texto
        aputs_info "Estableciendo contrasena para el usuario 'repo'"
        Write-Host ""
        $securePass = $null
        while ($true) {
            $s1 = Read-Host "  Contrasena (Enter = sin contrasena)" -AsSecureString
            $s2 = Read-Host "  Confirmar contrasena" -AsSecureString

            # Comparar SecureStrings convirtiendo a BSTR solo para comparar
            $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s1)
            $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s2)
            $t1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1)
            $t2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)

            if ($t1 -ne $t2) {
                aputs_error "Las contrasenas no coinciden — intente de nuevo"
                continue
            }

            $securePass = $s1
            break
        }

        try {
            New-LocalUser -Name $Script:SSL_REPO_FTP_USER `
                -Password $securePass `
                -FullName "FTP Repositorio" `
                -Description "Usuario dedicado al repositorio FTP Practica 7" `
                -PasswordNeverExpires `
                -ErrorAction Stop | Out-Null

            # Agregar a ftp_users para que IIS lo reconozca en el sitio FTP
            $grupoFtp = if ($script:FTP_GROUP_ALL) { $script:FTP_GROUP_ALL } else { "ftp_users" }
            $grupoExiste = Get-LocalGroup -Name $grupoFtp -ErrorAction SilentlyContinue
            if ($grupoExiste) {
                Add-LocalGroupMember -Group $grupoFtp `
                    -Member $Script:SSL_REPO_FTP_USER -ErrorAction SilentlyContinue
                aputs_info "Agregado al grupo: $grupoFtp"
            } else {
                aputs_info "Grupo '$grupoFtp' no existe aun — se agregara cuando se instale FTP"
            }

            aputs_success "Usuario '$($Script:SSL_REPO_FTP_USER)' creado"
        }
        catch {
            aputs_error "No se pudo crear el usuario: $($_.Exception.Message)"
            return $false
        }
    }

    Write-Host ""

    # ── Permisos NTFS: IUSR (anónimo) puede leer el repositorio ──────────────
    aputs_info "Aplicando permisos NTFS para acceso anónimo FTP..."
    try {
        foreach ($dir in @($Script:SSL_REPO_USER_DIR, $Script:SSL_REPO_ROOT,
                           "$($Script:SSL_REPO_ROOT)\http", $Script:SSL_REPO_WIN,
                           $Script:SSL_REPO_IIS, $Script:SSL_REPO_APACHE,
                           $Script:SSL_REPO_NGINX, $Script:SSL_REPO_TOMCAT)) {
            $acl     = Get-Acl $dir
            $iusrRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "IUSR", "ReadAndExecute",
                "ContainerInherit,ObjectInherit", "None", "Allow")
            $acl.AddAccessRule($iusrRule)
            Set-Acl -Path $dir -AclObject $acl -ErrorAction SilentlyContinue
        }
        aputs_success "Permisos NTFS aplicados (IUSR: ReadAndExecute)"
    }
    catch {
        aputs_warning "No se pudieron aplicar todos los permisos NTFS: $($_.Exception.Message)"
    }

    Write-Host ""

    # ── Virtual Directory en IIS FTP para el usuario repo ─────────────────────
    aputs_info "Configurando Virtual Directory en IIS FTP para '$($Script:SSL_REPO_FTP_USER)'..."
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $vdirPath = "IIS:\Sites\$($script:FTP_SITE_NAME)\LocalUser\$($Script:SSL_REPO_FTP_USER)"

        if (-not (Test-Path $vdirPath)) {
            New-Item $vdirPath -PhysicalPath $Script:SSL_REPO_USER_DIR `
                -Type VirtualDirectory -ErrorAction Stop | Out-Null
            aputs_success "Virtual Directory creado"
        } else {
            aputs_info "Virtual Directory ya existe"
        }

        # Autorización: repo puede leer+escribir; anónimo solo lee
        $loc = "$($script:FTP_SITE_NAME)/LocalUser/$($Script:SSL_REPO_FTP_USER)"
        Add-WebConfiguration "/system.ftpServer/security/authorization" `
            -PSPath "IIS:" -Location $loc `
            -Value @{ accessType="Allow"; users=$Script:SSL_REPO_FTP_USER; permissions="Read,Write" } `
            -ErrorAction SilentlyContinue
        Add-WebConfiguration "/system.ftpServer/security/authorization" `
            -PSPath "IIS:" -Location $loc `
            -Value @{ accessType="Allow"; users=""; permissions="Read" } `
            -ErrorAction SilentlyContinue

        aputs_success "Autorización FTP configurada"
    }
    catch {
        aputs_warning "Virtual Directory no configurado automáticamente"
        aputs_info    "Configure manualmente en IIS Manager si es necesario"
    }

    Write-Host ""
    draw_line
    aputs_success "Estructura del repositorio lista"
    Write-Host ""
    Write-Host "  $($Script:SSL_REPO_USER_DIR)"
    Write-Host "  └─ repositorio\http\Windows\"
    foreach ($s in @("IIS","Apache","Nginx","Tomcat")) {
        Write-Host "      ├─ $s\"
    }
    Write-Host ""
    aputs_info "Acceso FTP : ftp://192.168.100.20  usuario: $($Script:SSL_REPO_FTP_USER)"
    aputs_info "Navegar a  : /repositorio/http/Windows/{IIS,Apache,Nginx,Tomcat}"
    Write-Host ""
    return $true
}

# 
# ssl_repo_descargar_paquete
# 
function ssl_repo_descargar_paquete {
    param([string]$Servicio)
    _ssl_repo_init_rutas

    $destDir = _ssl_repo_dir_servicio $Servicio
    if (-not $destDir) { return $false }

    Write-Host ""
    draw_line
    aputs_info "Descargando: $Servicio"
    draw_line
    Write-Host ""

    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    # Limpiar instaladores anteriores
    $anteriores = Get-ChildItem $destDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.sha256$' }
    if ($anteriores.Count -gt 0) {
        aputs_info "Limpiando instaladores anteriores..."
        $anteriores | Remove-Item -Force
        Get-ChildItem $destDir -Filter "*.sha256" -ErrorAction SilentlyContinue | Remove-Item -Force
        aputs_success "Limpiado"
    }

    # Verificar conectividad
    if (-not (check_connectivity "8.8.8.8")) {
        aputs_error "Sin conectividad a internet — verifique la interfaz NAT"
        return $false
    }

    # Apache: siempre 1 version (choco solo tiene la version instalada en cache)
    # Nginx/Tomcat: el usuario elige 1-3 versiones
    $numVersiones = 1
    if ($Servicio.ToLower() -eq "apache") {
        aputs_info "Apache: se almacenara 1 version (la disponible en cache de choco)"
        Write-Host ""
    } elseif ($Servicio.ToLower() -notin @("iis","apache")) {
        Write-Host ""
        aputs_info "Cuantas versiones desea almacenar en el repositorio? [1-3, Enter=1]"
        $nv = Read-Host "  Versiones"
        if ($nv -match "^[23]$") { $numVersiones = [int]$nv }
        aputs_success "$numVersiones version(es) a descargar"
        Write-Host ""
    }

    $descargaOk = $false

    switch ($Servicio.ToLower()) {

        "iis" {
            # IIS no tiene .msi: se activa con DISM. Generamos un script de activación
            aputs_info "IIS se activa con DISM — generando script de activación..."
            $scriptContent = @'
# install_iis.ps1  —  Generado por mainSSL.ps1 Practica 7
# Ejecutar como Administrador
$features = @("Web-Server","Web-Ftp-Server","Web-Ftp-Service",
               "Web-Scripting-Tools","Web-Common-Http",
               "Web-Default-Doc","Web-Static-Content","Web-Http-Errors")
Install-WindowsFeature -Name $features -IncludeManagementTools -Verbose
if ((Get-WindowsFeature Web-Server).Installed) {
    Write-Host "[OK] IIS instalado"
    Start-Service W3SVC; Set-Service W3SVC -StartupType Automatic
} else { Write-Host "[ERROR] Fallo la instalacion"; exit 1 }
'@
            $destFile = Join-Path $destDir "install_iis.ps1"
            Set-Content -Path $destFile -Value $scriptContent -Encoding UTF8
            aputs_success "Script creado: install_iis.ps1"
            $descargaOk = $true
        }

        "apache" {
            # Apache: choco install captura el ZIP internamente en su cache
            # Limpiamos el cache primero para poder identificar el archivo nuevo
            $chocoCache = "$env:TEMP\chocolatey\apache-httpd"
            Remove-Item $chocoCache -Recurse -Force -ErrorAction SilentlyContinue

            aputs_info "Instalando apache-httpd con choco (capturando binario)..."

            # Monitorear el directorio TEMP durante la instalacion para capturar el ZIP
            $tempAntes = Get-ChildItem "$env:TEMP\chocolatey" -Recurse -Filter "*.zip" `
                -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName

            & choco install apache-httpd -y 2>&1 | Where-Object { $_ -match "Downloading|Installing|Installed" } |
                ForEach-Object { Write-Host "    $_" }

            # Buscar el ZIP que choco descargó
            $tempDespues = Get-ChildItem "$env:TEMP\chocolatey" -Recurse -Filter "*.zip" `
                -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 1MB }

            $zipChoco = $tempDespues | Where-Object {
                $_.Name -match "apache|httpd" -or $_.DirectoryName -match "apache|httpd"
            } | Select-Object -First 1

            # Si no encontramos por nombre, tomar el ZIP más reciente mayor a 5MB
            if (-not $zipChoco) {
                $zipChoco = $tempDespues | Where-Object { $_.Length -gt 5MB } |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
            }

            if ($zipChoco) {
                $destFile = Join-Path $destDir $zipChoco.Name
                Copy-Item $zipChoco.FullName $destFile -Force
                $sizeMB = [Math]::Round($zipChoco.Length / 1MB, 1)
                aputs_success "Capturado del cache de choco: $($zipChoco.Name) ($sizeMB MB)"
                $descargaOk = $true
            } else {
                # Choco instaló pero sin ZIP en cache — comprimir el directorio instalado
                $apacheDir = $null
                foreach ($c in @("$env:APPDATA\Apache24","$env:APPDATA\Apache2.4","C:\Apache24","C:\tools\httpd")) {
                    if (Test-Path "$c\bin\httpd.exe") { $apacheDir = $c; break }
                }
                if (-not $apacheDir) {
                    $exe = Get-ChildItem "$env:APPDATA" -Recurse -Filter httpd.exe `
                        -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($exe) { $apacheDir = Split-Path (Split-Path $exe.FullName) }
                }
                if ($apacheDir) {
                    $verReal = "2.4.x"
                    try {
                        $vi = & "$apacheDir\bin\httpd.exe" -v 2>&1 | Select-String "Apache/"
                        if ("$vi" -match "Apache/([\d\.]+)") { $verReal = $Matches[1] }
                    } catch {}
                    $zipDest = Join-Path $destDir "httpd-$verReal-win64.zip"
                    aputs_info "Comprimiendo Apache $verReal instalado..."
                    try {
                        Compress-Archive -Path $apacheDir -DestinationPath $zipDest -Force -ErrorAction Stop
                        $sizeMB = [Math]::Round((Get-Item $zipDest).Length / 1MB, 1)
                        aputs_success "Apache $verReal empaquetado ($sizeMB MB)"
                        $descargaOk = $true
                    } catch {
                        aputs_error "No se pudo comprimir: $($_.Exception.Message)"
                    }
                } else {
                    aputs_error "No se encontro Apache tras choco install"
                    aputs_info  "Instale manualmente: choco install apache-httpd -y"
                    aputs_info  "Luego copie el directorio a: $destDir"
                }
            }
        }

        "nginx" {
            # Nginx: nginx.org es accesible directamente con curl.exe
            $nginxVers = @("1.26.2","1.24.0","1.22.1")
            $descargadas = 0
            foreach ($ver in $nginxVers) {
                if ($descargadas -ge $numVersiones) { break }
                $url      = "https://nginx.org/download/nginx-${ver}.zip"
                $destFile = Join-Path $destDir "nginx-${ver}.zip"
                aputs_info "Descargando Nginx ${ver}..."
                & C:\Windows\System32\curl.exe -L -s -o "$destFile" "$url" --max-redirs 5
                if ($LASTEXITCODE -eq 0 -and (Test-Path $destFile) -and (Get-Item $destFile).Length -gt 100000) {
                    $sizeMB = [Math]::Round((Get-Item $destFile).Length / 1MB, 1)
                    aputs_success "Descargado: nginx-${ver}.zip ($sizeMB MB)"
                    $descargadas++
                    $descargaOk = $true
                } else {
                    Remove-Item $destFile -ErrorAction SilentlyContinue
                    aputs_warning "No se pudo descargar Nginx ${ver}"
                }
            }
            if (-not $descargaOk) {
                aputs_error "No se pudo descargar Nginx"
                aputs_info  "Descargue manualmente desde https://nginx.org/en/download.html"
                aputs_info  "y copielo a: $destDir"
            }
        }

        "tomcat" {
            # Tomcat: dlcdn.apache.org es accesible — consultar versión disponible
            aputs_info "Consultando versiones en dlcdn.apache.org/tomcat..."
            $tomcatVers = @()
            try {
                $idx = Invoke-WebRequest "https://dlcdn.apache.org/tomcat/tomcat-10/" `
                    -UseBasicParsing -ErrorAction Stop
                $tomcatVers = $idx.Links | ForEach-Object { $_.href } |
                    Where-Object { $_ -match "^v[\d\.]" } |
                    ForEach-Object { ($_ -replace "^v","") -replace "/$","" } |
                    Sort-Object { [version]($_ -replace "[^0-9\.]","")} -Descending
            } catch {}
            if ($tomcatVers.Count -eq 0) { $tomcatVers = @("10.1.52","10.1.40") }
            aputs_info "Versiones disponibles: $($tomcatVers -join ', ')"

            $descargadas = 0
            foreach ($ver in $tomcatVers) {
                if ($descargadas -ge $numVersiones) { break }
                $url      = "https://dlcdn.apache.org/tomcat/tomcat-10/v${ver}/bin/apache-tomcat-${ver}.exe"
                $destFile = Join-Path $destDir "apache-tomcat-${ver}.exe"
                aputs_info "Descargando Tomcat ${ver}..."
                & C:\Windows\System32\curl.exe -L -s -o "$destFile" "$url" --max-redirs 5
                if ($LASTEXITCODE -eq 0 -and (Test-Path $destFile) -and (Get-Item $destFile).Length -gt 100000) {
                    $sizeMB = [Math]::Round((Get-Item $destFile).Length / 1MB, 1)
                    aputs_success "Descargado: apache-tomcat-${ver}.exe ($sizeMB MB)"
                    $descargadas++
                    $descargaOk = $true
                } else {
                    Remove-Item $destFile -ErrorAction SilentlyContinue
                    aputs_warning "Tomcat ${ver} no disponible"
                }
            }
            if (-not $descargaOk) {
                aputs_error "No se pudo descargar Tomcat"
                aputs_info  "Descargue manualmente desde https://tomcat.apache.org/download-10.cgi"
                aputs_info  "y copielo a: $destDir"
            }
        }
    }

    if (-not $descargaOk) { return $false }

    # Listar lo descargado
    $descargados = Get-ChildItem $destDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.sha256$' }

    if ($descargados.Count -eq 0) {
        aputs_error "No se encontró ningún instalador en $destDir"
        return $false
    }

    Write-Host ""
    aputs_success "Instalador(es) descargado(s):"
    foreach ($f in $descargados) {
        Write-Host ("    {0,-50} {1} KB" -f $f.Name, [Math]::Round($f.Length/1KB, 1))
    }

    # Generar SHA256
    Write-Host ""
    aputs_info "Generando checksums SHA256..."
    Write-Host ""
    foreach ($f in $descargados) {
        _ssl_repo_generar_sha256 $f.FullName | Out-Null
    }

    Write-Host ""
    aputs_success "Paquete '$Servicio' listo en el repositorio"
    return $true
}

# 
# ssl_repo_descargar_todos
# 
function ssl_repo_descargar_todos {
    _ssl_repo_init_rutas
    ssl_mostrar_banner "Repositorio FTP — Descargar paquetes"

    if (-not (check_connectivity "8.8.8.8")) {
        aputs_error "Sin conectividad a internet"
        return $false
    }

    if (-not (Test-Path $Script:SSL_REPO_WIN)) {
        ssl_repo_crear_estructura | Out-Null
    }

    $servicios = @("iis","apache","nginx","tomcat")
    $nombres   = @("IIS","Apache","Nginx","Tomcat")
    $resultado = @{}

    for ($i = 0; $i -lt $servicios.Count; $i++) {
        $svc    = $servicios[$i]
        $nombre = $nombres[$i]
        aputs_info "━━━ $nombre ━━━"
        Write-Host ""
        if (ssl_repo_descargar_paquete $svc) {
            $resultado[$nombre] = "${GREEN}OK${NC}"
        } else {
            $resultado[$nombre] = "${RED}FAIL${NC}"
            aputs_warning "Fallo en $nombre — continuando..."
        }
        Write-Host ""
        Start-Sleep -Seconds 1
    }

    draw_line
    aputs_info "Resumen:"
    Write-Host ""
    for ($i = 0; $i -lt $nombres.Count; $i++) {
        Write-Host ("  {0,-20} " -f $nombres[$i]) -NoNewline
        Write-Host $resultado[$nombres[$i]]
    }
    draw_line
    return $true
}

# 
# ssl_repo_listar
# 
function ssl_repo_listar {
    _ssl_repo_init_rutas
    ssl_mostrar_banner "Repositorio FTP — Contenido Actual"

    if (-not (Test-Path $Script:SSL_REPO_WIN)) {
        aputs_warning "El repositorio no existe aún"
        aputs_info    "Ejecute primero: Opción 1 -> Crear estructura"
        return
    }

    $servicios = @("IIS","Apache","Nginx","Tomcat")
    $dirs      = @($Script:SSL_REPO_IIS,$Script:SSL_REPO_APACHE,
                   $Script:SSL_REPO_NGINX,$Script:SSL_REPO_TOMCAT)

    for ($i = 0; $i -lt $servicios.Count; $i++) {
        $nombre = $servicios[$i]
        $dir    = $dirs[$i]
        Write-Host ""
        Write-Host ("  ${CYAN}[$nombre]${NC}  $dir")
        Write-Host "  ──"

        if (-not (Test-Path $dir)) {
            Write-Host "  ${GRAY}(directorio no existe)${NC}"
            continue
        }

        $archivos = Get-ChildItem $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '\.sha256$' }

        if ($archivos.Count -eq 0) {
            Write-Host "  ${GRAY}(vacío — ejecute la descarga)${NC}"
        } else {
            foreach ($f in $archivos) {
                $shaOk = if (Test-Path "$($f.FullName).sha256") {"${GREEN}[OK]${NC}"} else {"${YELLOW}[!]${NC}"}
                Write-Host ("  $shaOk {0,-45} {1} KB" -f $f.Name, [Math]::Round($f.Length/1KB,1))
            }
        }
    }

    Write-Host ""
    draw_line
    aputs_info "Ruta FTP : ftp://192.168.100.20/repositorio/http/Windows/"
    aputs_info "Usuario  : $($Script:SSL_REPO_FTP_USER)"
    Write-Host ""
}

# 
# ssl_repo_verificar_integridad
# 
function ssl_repo_verificar_integridad {
    _ssl_repo_init_rutas
    ssl_mostrar_banner "Repositorio FTP — Verificación de Integridad"

    if (-not (Test-Path $Script:SSL_REPO_WIN)) {
        aputs_error "El repositorio no existe"; return $false
    }

    $total = 0; $ok = 0; $fail = 0; $sinSha = 0

    aputs_info "Verificando checksums SHA256..."
    Write-Host ""

    $archivos = Get-ChildItem $Script:SSL_REPO_WIN -Recurse -File `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.sha256$' }

    foreach ($f in $archivos) {
        $total++
        $shaFile = "$($f.FullName).sha256"

        if (-not (Test-Path $shaFile)) {
            Write-Host ("  ${YELLOW}[SIN SHA256]${NC} $($f.Name)"); $sinSha++; continue
        }

        $contenido    = (Get-Content $shaFile -Raw).Trim()
        $hashEsperado = ($contenido -split '\s+')[0].ToLower()
        $hashActual   = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash.ToLower()

        if ($hashActual -eq $hashEsperado) {
            Write-Host ("  ${GREEN}[OK]${NC}  $($f.Name)"); $ok++
        } else {
            Write-Host ("  ${RED}[FAIL]${NC} $($f.Name) — hash no coincide"); $fail++
        }
    }

    Write-Host ""
    draw_line
    Write-Host "  Total     : $total"
    Write-Host "  ${GREEN}Correctos${NC} : $ok"
    Write-Host "  ${YELLOW}Sin sha256${NC}: $sinSha"
    Write-Host "  ${RED}Fallidos${NC}  : $fail"
    draw_line
    Write-Host ""

    if ($fail -gt 0) {
        aputs_error "$fail archivo(s) corruptos — vuelva a descargar"
        return $false
    }
    if ($total -eq 0) {
        aputs_warning "No se encontraron instaladores"; return $false
    }
    aputs_success "Integridad verificada — todos los archivos son correctos"
    return $true
}

# 
# ssl_menu_repo
# 
function ssl_menu_repo {
    while ($true) {
        Clear-Host
        ssl_mostrar_banner "Tarea 07 — Repositorio FTP Windows"
        ssl_repo_listar

        Write-Host "  ${BLUE}1)${NC} Crear estructura + usuario 'repo'"
        Write-Host "  ${BLUE}2)${NC} Descargar todos los paquetes"
        Write-Host "  ${BLUE}3)${NC} Descargar paquete individual"
        Write-Host "  ${BLUE}4)${NC} Verificar integridad (SHA256)"
        Write-Host "  ${BLUE}0)${NC} Volver"
        Write-Host ""

        $op = Read-Host "  Opción"
        switch ($op) {
            "1" { ssl_repo_crear_estructura; pause_menu }
            "2" { ssl_repo_descargar_todos;  pause_menu }
            "3" {
                Clear-Host
                ssl_mostrar_banner "Descargar Paquete Individual"
                Write-Host ""
                Write-Host "  ${BLUE}1)${NC} IIS"
                Write-Host "  ${BLUE}2)${NC} Apache"
                Write-Host "  ${BLUE}3)${NC} Nginx"
                Write-Host "  ${BLUE}4)${NC} Tomcat"
                Write-Host ""
                $srv = Read-Host "  Servicio [1-4]"
                switch ($srv) {
                    "1" { ssl_repo_descargar_paquete "iis"    }
                    "2" { ssl_repo_descargar_paquete "apache" }
                    "3" { ssl_repo_descargar_paquete "nginx"  }
                    "4" { ssl_repo_descargar_paquete "tomcat" }
                    default { aputs_error "Opción inválida" }
                }
                pause_menu
            }
            "4" { ssl_repo_verificar_integridad; pause_menu }
            "0" { return }
            default { aputs_error "Opción inválida"; Start-Sleep -Seconds 1 }
        }
    }
}