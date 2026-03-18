#
# repoHTTP.ps1
# Override de instalación HTTP desde repositorio FTP local — Práctica 7 Windows
#
function check_service_active {
    param([string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -ne $svc -and $svc.Status -eq 'Running') { return $true }
    # Nginx especial: puede correr como proceso sin servicio Windows
    if ($ServiceName -eq "nginx") {
        return ($null -ne (Get-Process -Name "nginx" -ErrorAction SilentlyContinue))
    }
    return $false
}

function http_get_conf_archivo {
    param([string]$Servicio)
    switch ($Servicio.ToLower()) {
        "apache" {
            # Verificar que la ruta en HTTP_CONF_APACHE existe
            if ($Script:HTTP_CONF_APACHE -and (Test-Path $Script:HTTP_CONF_APACHE)) {
                return $Script:HTTP_CONF_APACHE
            }
            # Buscar httpd.conf en rutas conocidas
            foreach ($c in @(
                "C:\Apache24\conf\httpd.conf",
                "$env:APPDATA\Apache24\conf\httpd.conf",
                "$env:APPDATA\Apache2.4\conf\httpd.conf",
                "C:\tools\httpd\conf\httpd.conf"
            )) {
                if (Test-Path $c) { $Script:HTTP_CONF_APACHE = $c; return $c }
            }
            return $Script:HTTP_CONF_APACHE
        }
        "iis"    { return $Script:HTTP_CONF_IIS    }
        "nginx"  { return $Script:HTTP_CONF_NGINX  }
        "tomcat" { return $Script:HTTP_CONF_TOMCAT }
        default  { return "" }
    }
}

# 
# HELPERS INTERNOS
# 
# Devuelve la ruta del directorio del repositorio para el servicio dado
function _repo_dir_servicio {
    param([string]$Servicio)

    # Inicializar rutas si la funcion esta disponible
    if (Get-Command _ssl_repo_init_rutas -ErrorAction SilentlyContinue) {
        _ssl_repo_init_rutas
    }

    # Intentar con variables de scope Script
    $ruta = switch ($Servicio.ToLower()) {
        "iis"    { $Script:SSL_REPO_IIS    }
        "apache" { $Script:SSL_REPO_APACHE }
        "nginx"  { $Script:SSL_REPO_NGINX  }
        "tomcat" { $Script:SSL_REPO_TOMCAT }
        default  { $null }
    }

    # Si las variables no estan inicializadas, construir la ruta directamente
    if (-not $ruta) {
        $ftpRoot = $script:FTP_ROOT
        if (-not $ftpRoot) { $ftpRoot = $global:FTP_ROOT }
        if (-not $ftpRoot) { $ftpRoot = "C:\FTP" }
        $repoBase = "$ftpRoot\LocalUser\repo\repositorio\http\Windows"
        $ruta = switch ($Servicio.ToLower()) {
            "iis"    { "$repoBase\IIS"    }
            "apache" { "$repoBase\Apache" }
            "nginx"  { "$repoBase\Nginx"  }
            "tomcat" { "$repoBase\Tomcat" }
            default  { $null }
        }
    }

    return $ruta
}

# Extrae la versión de un nombre de archivo de instalador
# nginx-1.26.2.zip -> "1.26.2"
# apache-tomcat-10.1.31.exe -> "10.1.31"
# httpd-2.4.62-win64-VS17.zip -> "2.4.62"
function _repo_extraer_version {
    param([string]$NombreArchivo)
    # Patrones en orden de especificidad
    if ($NombreArchivo -match 'tomcat[_-](\d+\.\d+\.\d+)') { return $Matches[1] }
    if ($NombreArchivo -match 'httpd[_-](\d+\.\d+\.\d+)') { return $Matches[1] }
    if ($NombreArchivo -match 'nginx[_-](\d+\.\d+\.\d+)') { return $Matches[1] }
    if ($NombreArchivo -match '(\d+\.\d+[\.\d]*)') { return $Matches[1] }
    return $NombreArchivo  # fallback: devolver el nombre completo
}

# Verifica el SHA256 de un archivo contra su .sha256
function _repo_verificar_sha256 {
    param([string]$Archivo)
    $shaFile = "$Archivo.sha256"
    if (-not (Test-Path $shaFile)) {
        aputs_warning "Sin .sha256 para: $(Split-Path $Archivo -Leaf)"
        return $true   # sin checksum disponible -> continuar de todas formas
    }
    $contenido    = (Get-Content $shaFile -Raw).Trim()
    $hashEsperado = ($contenido -split '\s+')[0].ToLower()
    $hashActual   = (Get-FileHash -Path $Archivo -Algorithm SHA256).Hash.ToLower()
    if ($hashActual -eq $hashEsperado) {
        aputs_success "SHA256 OK: $(Split-Path $Archivo -Leaf)"
        return $true
    }
    aputs_error "SHA256 FALLO: $(Split-Path $Archivo -Leaf) — archivo corrupto"
    return $false
}

# 
# Lee los binarios del repositorio local en lugar de consultar choco
# 
function http_consultar_versiones {
    param([string]$Servicio)

    # IIS: sin versiones seleccionables
    if ($Servicio -eq "iis") {
        $iisVer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" `
                  -ErrorAction SilentlyContinue).VersionString
        return @("sistema ($iisVer)")
    }

    $repoDir = _repo_dir_servicio $Servicio

    # Si el directorio del repo existe y tiene instaladores -> usarlos
    if ($repoDir -and (Test-Path $repoDir)) {
        $instaladores = Get-ChildItem $repoDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '\.sha256$' -and
                           $_.Name -notmatch '^install_' }

        if ($instaladores.Count -gt 0) {
            aputs_info "Consultando versiones disponibles de '$Servicio' en repositorio FTP..."
            Write-Host ""

            # Extraer versiones de los nombres de archivo, ordenar descendente
            $versiones = $instaladores |
                ForEach-Object { _repo_extraer_version $_.Name } |
                Sort-Object -Descending {
                    $parteNum = ($_ -split '[^0-9.]')[0].TrimEnd('.')
                    $segs = $parteNum -split '\.' | ForEach-Object {
                        $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 }
                    }
                    while ($segs.Count -lt 4) { $segs = @($segs) + @(0) }
                    '{0:D5}{1:D5}{2:D5}{3:D5}' -f $segs[0],$segs[1],$segs[2],$segs[3]
                }

            aputs_success "Se encontraron $($versiones.Count) versión(es) en el repositorio local"
            Write-Host ""

            # Mostrar la tabla de versiones aquí para que el usuario la vea
            # ANTES de que http_menu_instalar (P6) ejecute pause_menu y
            # http_seleccionar_version — así el usuario sabe qué tiene disponible
            http_draw_servicio_header $Servicio "Versiones disponibles en repositorio"
            Write-Host ("  {0,-6} {1,-30} {2}" -f "NUM", "VERSION", "ETIQUETA")
            Write-Host "  $("─" * 55)"
            $i = 1
            foreach ($v in $versiones) {
                $etiqueta = switch ($i) {
                    1 { "Latest / Stable" }
                    2 { "Versión anterior" }
                    default { "Disponible" }
                }
                Write-Host ("  {0,-6} {1,-30} {2}" -f "$i)", $v, $etiqueta)
                $i++
            }
            Write-Host ""

            return @($versiones)
        }
    }

    # Repositorio vacío -> fallback a choco (comportamiento de P6)
    aputs_warning "Repositorio local vacío para '$Servicio' — usando Chocolatey"
    aputs_info    "Ejecute el Paso 3 para descargar los instaladores al repositorio"
    Write-Host ""

    # Llamar a la versión original de FunctionsHTTP-B.ps1
    # Como ya fue sobreescrita por este archivo, necesitamos llamar choco directamente
    $paquete = http_nombre_paquete $Servicio
    aputs_info "Consultando versiones de $paquete en Chocolatey..."
    $salidaRaw = choco search $paquete --exact --all-versions 2>$null
    if (-not $salidaRaw -or $salidaRaw.Count -eq 0) {
        $salidaRaw = choco list $paquete --exact --all-versions 2>$null
    }
    $paqueteEsc = [regex]::Escape($paquete)
    $versiones = $salidaRaw |
        Where-Object { $_ -imatch "^${paqueteEsc}\s+\d" } |
        ForEach-Object { ($_ -split '\s+')[1].Trim() } |
        Where-Object { $_ -match '^\d' }

    if (-not $versiones -or @($versiones).Count -eq 0) {
        return @("latest")
    }
    return @($versiones)
}

# 
# Instala Apache desde el .zip del repositorio local
# 
function http_instalar_apache {
    param([string]$Version, [int]$Puerto)

    http_draw_servicio_header "Apache (httpd)" "Instalacion desde repositorio FTP"

    $repoDir = _repo_dir_servicio "apache"
    $instaladores = if ($repoDir -and (Test-Path $repoDir)) {
        Get-ChildItem $repoDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '\.sha256$' }
    }

    # Si no hay binario en el repo -> fallback a choco
    if (-not $instaladores -or $instaladores.Count -eq 0) {
        aputs_warning "Sin instaladores Apache en el repositorio — instalando con choco"
        if ($Version -eq "latest") { & choco install apache-httpd -y }
        else { & choco install apache-httpd "--version=$Version" -y }
        # Después del install, continuar con el resto de la configuración igual que P6
        # (detección de httpd.conf, puerto, servicio, firewall, index)
        _repo_configurar_post_apache $Puerto $Version
        return $?
    }

    # Encontrar el instalador que corresponde a la versión elegida
    $archivo = $instaladores | Where-Object {
        (_repo_extraer_version $_.Name) -eq $Version
    } | Select-Object -First 1

    if (-not $archivo) {
        $archivo = $instaladores | Select-Object -First 1
        aputs_warning "Versión $Version no encontrada exactamente — usando: $($archivo.Name)"
    }

    draw_line
    aputs_info "PASO 1/5 — Instalación desde repositorio FTP local"
    draw_line
    aputs_info "Archivo: $($archivo.FullName)"
    aputs_info "Tamaño: $([Math]::Round($archivo.Length/1MB, 1)) MB"
    Write-Host ""

    # Verificar integridad SHA256
    aputs_info "Verificando integridad SHA256..."
    if (-not (_repo_verificar_sha256 $archivo.FullName)) {
        aputs_error "El instalador está corrupto — vuelva a descargarlo en el Paso 3"
        return $false
    }
    Write-Host ""

    # Apache viene como .zip — extraer a C:\tools\httpd\
    # El ZIP de Apache Lounge extrae como Apache24\ directamente
    # Usar .NET ZipFile para evitar problemas de Expand-Archive en PS 5.1
    aputs_info "Extrayendo $($archivo.Name) a C:\..."
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        # Limpiar instalacion anterior si existe
        if (Test-Path "C:\Apache24") {
            Remove-Item "C:\Apache24" -Recurse -Force -ErrorAction SilentlyContinue
        }
        # ExtractToDirectory requiere path sin barra final en PS 5.1
        $extractBase = "C:\Apache_extract_tmp"
        New-Item -ItemType Directory -Path $extractBase -Force | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($archivo.FullName, $extractBase)

        # El ZIP extrae como Apache24\ — mover a C:\Apache24
        $apacheSubdir = Join-Path $extractBase "Apache24"
        if (Test-Path $apacheSubdir) {
            if (Test-Path "C:\Apache24") {
                Remove-Item "C:\Apache24" -Recurse -Force -ErrorAction SilentlyContinue
            }
            Move-Item $apacheSubdir "C:\Apache24" -Force
        }
        Remove-Item $extractBase -Recurse -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path "C:\Apache24\bin\httpd.exe")) {
            aputs_error "httpd.exe no encontrado tras la extraccion"
            return $false
        }
        $Script:HTTP_CONF_APACHE = "C:\Apache24\conf\httpd.conf"
        aputs_success "Apache extraido en: C:\Apache24"
    } catch {
        aputs_error "Error al extraer: $($_.Exception.Message)"
        return $false
    }


    # Actualizar la constante de ruta
    $confCandidatos = @(
        "C:\tools\httpd\conf\httpd.conf",
        "$destDir\conf\httpd.conf"
    )
    foreach ($c in $confCandidatos) {
        if (Test-Path $c) { $Script:HTTP_CONF_APACHE = $c; break }
    }

    # Configurar puerto, registrar servicio, etc. (lógica común de P6)
    _repo_configurar_post_apache $Puerto $Version

    # Ofrecer SSL inmediatamente tras instalar
    _repo_ofrecer_ssl "apache" $Puerto
    return $true
}

# 
# Instala Nginx desde el .zip del repositorio local
# 
function http_instalar_nginx {
    param([string]$Version, [int]$Puerto)

    http_draw_servicio_header "Nginx" "Instalacion desde repositorio FTP"

    $repoDir = _repo_dir_servicio "nginx"
    $instaladores = if ($repoDir -and (Test-Path $repoDir)) {
        Get-ChildItem $repoDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '\.sha256$' }
    }

    if (-not $instaladores -or $instaladores.Count -eq 0) {
        aputs_warning "Sin instaladores Nginx en el repositorio — instalando con choco"
        & choco install nginx -y
        _repo_configurar_post_nginx $Puerto $Version
        return $?
    }

    $archivo = $instaladores | Where-Object {
        (_repo_extraer_version $_.Name) -eq $Version
    } | Select-Object -First 1
    if (-not $archivo) { $archivo = $instaladores | Select-Object -First 1 }

    draw_line
    aputs_info "PASO 1/5 — Instalación desde repositorio FTP local"
    draw_line
    aputs_info "Archivo: $($archivo.FullName)"
    Write-Host ""

    aputs_info "Verificando integridad SHA256..."
    if (-not (_repo_verificar_sha256 $archivo.FullName)) {
        aputs_error "El instalador está corrupto — vuelva a descargarlo"
        return $false
    }
    Write-Host ""

    # nginx viene como .zip — extraer a C:\tools\
    aputs_info "Extrayendo $($archivo.Name) a C:\tools\..."
    try {
        Expand-Archive -Path $archivo.FullName -DestinationPath "C:\tools" -Force -ErrorAction Stop
        # El .zip extrae como nginx-1.26.2\ — buscar y apuntar la constante
        $nginxDir = Get-ChildItem "C:\tools" -Directory |
            Where-Object { $_.Name -match '^nginx' } |
            Sort-Object Name -Descending |
            Select-Object -First 1
        if ($nginxDir) {
            $Script:HTTP_CONF_NGINX = "$($nginxDir.FullName)\conf\nginx.conf"
            $Script:HTTP_DIR_NGINX  = "$($nginxDir.FullName)\html"
            aputs_success "Extraído en: $($nginxDir.FullName)"
        }
    }
    catch {
        aputs_error "Error al extraer: $($_.Exception.Message)"
        return $false
    }

    _repo_configurar_post_nginx $Puerto $Version

    # Ofrecer SSL inmediatamente tras instalar
    _repo_ofrecer_ssl "nginx" $Puerto
    return $true
}

# 
# Instala Tomcat desde el .exe del repositorio local
# 
function http_instalar_tomcat {
    param([string]$Version, [int]$Puerto)

    http_draw_servicio_header "Tomcat" "Instalacion desde repositorio FTP"

    $repoDir = _repo_dir_servicio "tomcat"
    $instaladores = if ($repoDir -and (Test-Path $repoDir)) {
        Get-ChildItem $repoDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '\.sha256$' }
    }

    if (-not $instaladores -or $instaladores.Count -eq 0) {
        aputs_warning "Sin instaladores Tomcat en el repositorio — instalando con choco"
        & choco install tomcat -y
        return $?
    }

    $archivo = $instaladores | Where-Object {
        (_repo_extraer_version $_.Name) -eq $Version
    } | Select-Object -First 1
    if (-not $archivo) { $archivo = $instaladores | Select-Object -First 1 }

    draw_line
    aputs_info "PASO 1/5 — Verificar Java + instalar desde repositorio FTP"
    draw_line

    # Tomcat requiere Java — buscar en disco o instalar
    $javaExe = $null

    # Buscar java.exe en ubicaciones conocidas
    $javaCandidatos = @(
        "$env:ProgramFiles\Eclipse Adoptium",
        "$env:ProgramFiles\Java",
        "$env:ProgramFiles\Microsoft",
        "$env:ProgramFiles\OpenJDK",
        "C:\Program Files\Eclipse Adoptium",
        "C:\Program Files\Java",
        "C:\Program Files\OpenJDK"
    )
    foreach ($base in $javaCandidatos) {
        if (Test-Path $base) {
            $found = Get-ChildItem $base -Recurse -Filter "java.exe" -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($found) { $javaExe = $found.FullName; break }
        }
    }

    # También intentar con el PATH actual
    if (-not $javaExe) {
        $javaCmd = Get-Command java -ErrorAction SilentlyContinue
        if ($javaCmd) { $javaExe = $javaCmd.Source }
    }

    if (-not $javaExe) {
        aputs_warning "Java no encontrado — instalando con choco..."
        & choco install openjdk -y --no-progress 2>&1 | Out-Null
        # Refrescar PATH
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("PATH","User")
        # Buscar de nuevo tras instalar
        foreach ($base in $javaCandidatos) {
            if (Test-Path $base) {
                $found = Get-ChildItem $base -Recurse -Filter "java.exe" -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($found) { $javaExe = $found.FullName; break }
            }
        }
        if (-not $javaExe) {
            $javaCmd = Get-Command java -ErrorAction SilentlyContinue
            if ($javaCmd) { $javaExe = $javaCmd.Source }
        }
    }

    if ($javaExe) {
        $javaDir = Split-Path (Split-Path $javaExe)
        $env:JAVA_HOME = $javaDir
        $env:PATH = "$javaDir\bin;$env:PATH"
        aputs_success "Java encontrado: $javaExe"
    } else {
        aputs_error "Java no pudo instalarse — Tomcat no funcionara sin JDK"
        aputs_info  "Instale manualmente: choco install openjdk -y"
        return $false
    }
    Write-Host ""

    aputs_info "Archivo: $($archivo.FullName)"
    aputs_info "Verificando integridad SHA256..."
    if (-not (_repo_verificar_sha256 $archivo.FullName)) {
        aputs_error "El instalador esta corrupto — vuelva a descargarlo"
        return $false
    }
    Write-Host ""

    # Instalar Tomcat — puede ser .exe (instalador nativo) o .zip (empaquetado)
    aputs_info "Instalando Tomcat..."
    aputs_info "Esto puede tardar 1-2 minutos..."
    Write-Host ""

    $tomcatInstalado = $false

    if ($archivo.Extension -eq ".exe") {
        # Instalador nativo Windows — acepta /S para silencioso
        try {
            aputs_info "JAVA_HOME: $env:JAVA_HOME"
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $archivo.FullName
            $psi.Arguments = "/S"
            $psi.UseShellExecute = $false
            $psi.EnvironmentVariables["JAVA_HOME"] = $env:JAVA_HOME
            $psi.EnvironmentVariables["PATH"] = $env:PATH
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.WaitForExit()
            if ($p.ExitCode -ne 0) {
                aputs_warning "Instalador retorno codigo $($p.ExitCode) — verificando..."
            }
            $tomcatInstalado = $true
        }
        catch {
            aputs_error "Error al ejecutar instalador: $($_.Exception.Message)"
            return $false
        }
    } elseif ($archivo.Extension -eq ".zip") {
        # ZIP empaquetado — extraer a C:\Program Files\Apache Software Foundation\
        aputs_info "Archivo ZIP detectado — extrayendo..."
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $destBase = "C:\Program Files\Apache Software Foundation"
            if (-not (Test-Path $destBase)) {
                New-Item -ItemType Directory -Path $destBase -Force | Out-Null
            }
            # Limpiar extracción anterior si existe
            $tmpExtract = "C:\tomcat_extract_tmp"
            if (Test-Path $tmpExtract) { Remove-Item $tmpExtract -Recurse -Force }
            New-Item -ItemType Directory -Path $tmpExtract -Force | Out-Null
            [System.IO.Compression.ZipFile]::ExtractToDirectory($archivo.FullName, $tmpExtract)

            # Mover el directorio extraído a Program Files
            $extractedDir = Get-ChildItem $tmpExtract -Directory | Select-Object -First 1
            if ($extractedDir) {
                $destDir2 = Join-Path $destBase $extractedDir.Name
                if (Test-Path $destDir2) { Remove-Item $destDir2 -Recurse -Force -EA SilentlyContinue }
                Move-Item $extractedDir.FullName $destDir2 -Force
                aputs_success "Tomcat extraído en: $destDir2"
                $tomcatInstalado = $true
            }
            Remove-Item $tmpExtract -Recurse -Force -EA SilentlyContinue

            # Registrar como servicio usando el exe de Tomcat
            $tomcatExeFound = Get-ChildItem $destBase -Recurse -Filter "tomcat*.exe" `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($tomcatExeFound) {
                aputs_info "Registrando servicio Tomcat..."
                & $tomcatExeFound.FullName install 2>$null | Out-Null
                Start-Sleep -Seconds 3
            }
        }
        catch {
            aputs_error "Error al extraer ZIP: $($_.Exception.Message)"
            return $false
        }
    } else {
        aputs_error "Formato no soportado: $($archivo.Extension) — se esperaba .exe o .zip"
        return $false
    }

    if (-not $tomcatInstalado) { return $false }

    # Verificar que Tomcat quedó instalado
    # El instalador nativo puede tardar unos segundos extra
    Start-Sleep -Seconds 5
    $tomcatSvc = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^Tomcat' } | Select-Object -First 1

    # Si no hay servicio, buscar el directorio de instalación directamente
    if (-not $tomcatSvc) {
        $tomcatDirs = @(
            "C:\Program Files\Apache Software Foundation",
            "C:\Program Files (x86)\Apache Software Foundation"
        )
        foreach ($base in $tomcatDirs) {
            if (Test-Path $base) {
                $tomcatDir = Get-ChildItem $base -Directory |
                    Where-Object { $_.Name -match "Tomcat" } |
                    Select-Object -First 1
                if ($tomcatDir) {
                    aputs_info "Tomcat instalado en: $($tomcatDir.FullName)"
                    aputs_info "Registrando servicio manualmente..."
                    $tomcatExe = Get-ChildItem $tomcatDir.FullName -Recurse `
                        -Filter "tomcat*.exe" -ErrorAction SilentlyContinue |
                        Select-Object -First 1
                    if ($tomcatExe) {
                        & $tomcatExe.FullName install 2>$null | Out-Null
                        Start-Sleep -Seconds 2
                        $tomcatSvc = Get-Service -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -match "^Tomcat" } |
                            Select-Object -First 1
                    }
                }
            }
        }
    }

    if ($tomcatSvc) {
        $Script:HTTP_WINSVC_TOMCAT = $tomcatSvc.Name
        aputs_success "Tomcat instalado — servicio: $($tomcatSvc.Name)"

        # Detectar server.xml
        # Buscar server.xml en todas las ubicaciones posibles
        $xmlCandidatos = @(
            "C:\Program Files\Apache Software Foundation\Tomcat 10.1\conf\server.xml",
            "C:\Program Files\Apache Software Foundation\Tomcat 10.0\conf\server.xml",
            "C:\Program Files\Apache Software Foundation\Tomcat 9.0\conf\server.xml",
            "C:\ProgramData\Tomcat10\conf\server.xml",
            "C:\ProgramData\Tomcat9\conf\server.xml"
        )
        # También buscar dinámicamente
        if (-not ($xmlCandidatos | Where-Object { Test-Path $_ })) {
            $found = Get-ChildItem "C:\Program Files\Apache Software Foundation" `
                -Recurse -Filter "server.xml" -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($found) { $xmlCandidatos = @($found.FullName) + $xmlCandidatos }
        }
        foreach ($c in $xmlCandidatos) {
            if (Test-Path $c) {
                $Script:HTTP_CONF_TOMCAT = $c
                # Actualizar también el webroot derivando desde server.xml
                $tomcatBase   = Split-Path (Split-Path $c)
                $webappsRoot  = Join-Path $tomcatBase "webapps\ROOT"
                if (Test-Path $webappsRoot) {
                    $Script:HTTP_DIR_TOMCAT = $webappsRoot
                    aputs_info "Tomcat webroot: $($Script:HTTP_DIR_TOMCAT)"
                }
                break
            }
        }

        # Configurar puerto en server.xml
        if ($Script:HTTP_CONF_TOMCAT -and (Test-Path $Script:HTTP_CONF_TOMCAT)) {
            http_crear_backup $Script:HTTP_CONF_TOMCAT
            [xml]$xml = Get-Content $Script:HTTP_CONF_TOMCAT
            foreach ($c in $xml.Server.Service.Connector) {
                if ($c.protocol -match 'HTTP') {
                    $c.SetAttribute("port", "$Puerto"); break
                }
            }
            $xml.Save($Script:HTTP_CONF_TOMCAT)
            aputs_success "Puerto $Puerto configurado en server.xml"
        }

        Set-Service -Name $Script:HTTP_WINSVC_TOMCAT -StartupType Automatic `
            -ErrorAction SilentlyContinue
        Restart-Service -Name $Script:HTTP_WINSVC_TOMCAT -Force `
            -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3

        if (check_service_active $Script:HTTP_WINSVC_TOMCAT) {
            aputs_success "Tomcat activo"
        } else {
            aputs_warning "Tomcat no levantó — revise el Visor de Eventos"
        }

        _http_configurar_firewall_inicial "tomcat" $Puerto
        Write-Host ""
        http_crear_index "tomcat" $Version $Puerto
        http_draw_resumen "Apache Tomcat" "$Puerto" "$Version"

        # Ofrecer SSL inmediatamente tras instalar
        _repo_ofrecer_ssl "tomcat" $Puerto
        return $true
    }
    else {
        aputs_error "No se detectó el servicio Tomcat tras la instalación"
        aputs_info  "Verifique manualmente en services.msc"
        return $false
    }
}

function _repo_configurar_post_apache {
    param([int]$Puerto, [string]$Version)

    Write-Host ""
    draw_line
    aputs_info "PASO 2/5 — Localizar httpd.conf y configurar puerto"
    draw_line

    # Determinar qué httpd.exe usa el servicio Windows — es el que debemos configurar
    $svcApache = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -imatch '^Apache' } | Select-Object -First 1
    $httpdExeSvc = $null
    if ($svcApache) {
        $svcWmi = Get-WmiObject Win32_Service -Filter "Name='$($svcApache.Name)'" -EA SilentlyContinue
        if ($svcWmi -and $svcWmi.PathName) {
            $httpdExeSvc = $svcWmi.PathName -replace '"','' -replace '\s+-k.*',''
            $httpdExeSvc = $httpdExeSvc.Trim()
        }
    }

    # Derivar el httpd.conf del ejecutable del servicio
    $confFromSvc = if ($httpdExeSvc -and (Test-Path $httpdExeSvc)) {
        $apacheRootSvc = Split-Path (Split-Path $httpdExeSvc)
        Join-Path $apacheRootSvc "conf\httpd.conf"
    } else { $null }

    # Lista de candidatos — el del servicio tiene prioridad
    $candidatos = @(
        $confFromSvc,
        $Script:HTTP_CONF_APACHE,
        "C:\Apache24\conf\httpd.conf",
        "C:\tools\httpd\conf\httpd.conf",
        "$env:APPDATA\Apache24\conf\httpd.conf"
    ) | Where-Object { $_ }

    $confReal = $null
    foreach ($c in $candidatos) {
        if ($c -and (Test-Path $c)) { $confReal = $c; break }
    }
    if (-not $confReal) {
        foreach ($base in @("C:\Apache24","C:\tools","C:\Apache2.4")) {
            $found = Get-ChildItem $base -Recurse -Filter httpd.conf `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $confReal = $found.FullName; break }
        }
    }

    if ($confReal) {
        $Script:HTTP_CONF_APACHE = $confReal
        $apacheRoot  = Split-Path (Split-Path $confReal)
        $srvrootFwd  = $apacheRoot -replace '\\', '/'
        http_crear_backup $confReal

        $bytes = [System.IO.File]::ReadAllBytes($confReal)
        $enc   = if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) {
            [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        } else { [System.Text.Encoding]::UTF8.GetString($bytes) }

        $enc = $enc -replace 'Define SRVROOT ".*"', "Define SRVROOT `"$srvrootFwd`""
        $enc = $enc -replace 'Listen\s+\d+',        "Listen $Puerto"
        $enc = $enc -replace 'ServerName\s+\S+:\d+', "ServerName localhost:$Puerto"

        # Deshabilitar httpd-ahssl.conf — conflictúa con puerto 443 de IIS
        if ($enc -match '(?m)^Include\s+conf/extra/httpd-ahssl\.conf') {
            $enc = $enc -replace '(?m)^(Include\s+conf/extra/httpd-ahssl\.conf)', '# [P7] $1'
            aputs_info "httpd-ahssl.conf deshabilitado (conflicto con puerto 443 de IIS)"
        }

        # Asegurar que ssl_reprobados.conf está incluido
        if ($enc -notmatch 'ssl_reprobados') {
            $enc += "`r`nInclude conf/ssl_reprobados.conf`r`n"
            aputs_info "Include ssl_reprobados.conf agregado"
        }

        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($confReal, $enc, $utf8NoBom)
        aputs_success "Puerto $Puerto y SRVROOT configurados en: $confReal"

        # Si hay un ssl_reprobados.conf en otra instalación de Apache, copiarlo aquí
        $sslConfDestino = Join-Path $apacheRoot "conf\ssl_reprobados.conf"
        $sslConfOrigen  = @(
            "$env:APPDATA\Apache24\conf\ssl_reprobados.conf",
            "C:\Apache24\conf\ssl_reprobados.conf"
        ) | Where-Object { $_ -ne $sslConfDestino -and (Test-Path $_) } | Select-Object -First 1
        if ($sslConfOrigen -and -not (Test-Path $sslConfDestino)) {
            Copy-Item $sslConfOrigen $sslConfDestino -Force
            aputs_success "ssl_reprobados.conf sincronizado desde: $sslConfOrigen"
        }
        $Script:SSL_CONF_APACHE_SSL = $sslConfDestino

        # Registrar/actualizar el servicio apuntando al ejecutable correcto
        $httpdExe = Join-Path $apacheRoot "bin\httpd.exe"
        if (-not $svcApache) {
            if (Test-Path $httpdExe) {
                & $httpdExe -k install -n "Apache" 2>$null | Out-Null
                $Script:HTTP_WINSVC_APACHE = "Apache"
                aputs_success "Servicio Apache registrado: $httpdExe"
            }
        } else {
            $Script:HTTP_WINSVC_APACHE = $svcApache.Name
            $exeActual = if ($httpdExeSvc) { $httpdExeSvc } else { "" }
            if ($exeActual -and ($exeActual -ne $httpdExe) -and (Test-Path $httpdExe)) {
                aputs_info "Actualizando servicio -> $httpdExe"
                $regKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$($svcApache.Name)"
                Set-ItemProperty -Path $regKey -Name "ImagePath" `
                    -Value "`"$httpdExe`" -k runservice" -ErrorAction SilentlyContinue
                aputs_success "Registro del servicio actualizado"
            }
        }

        Set-Service -Name $Script:HTTP_WINSVC_APACHE -StartupType Automatic -EA SilentlyContinue
        Stop-Service  -Name $Script:HTTP_WINSVC_APACHE -Force -EA SilentlyContinue
        Start-Sleep -Seconds 2
        Start-Service -Name $Script:HTTP_WINSVC_APACHE -EA SilentlyContinue
        Start-Sleep -Seconds 2

        if (check_service_active $Script:HTTP_WINSVC_APACHE) {
            aputs_success "Apache activo"
        } else {
            aputs_error "Apache no levantó — revise el Visor de Eventos"
        }
    } else {
        aputs_warning "httpd.conf no encontrado — configure el puerto manualmente"
    }

    # Detectar DocumentRoot real
    $docRoot = $Script:HTTP_DIR_APACHE
    if ($confReal -and (Test-Path $confReal)) {
        $drLine = Get-Content $confReal |
            Where-Object { $_ -match '^\s*DocumentRoot\s+"' } | Select-Object -First 1
        if ($drLine -match 'DocumentRoot\s+"([^"]+)"') {
            $docRoot = $Matches[1] -replace '/', '\'
            $Script:HTTP_DIR_APACHE = $docRoot
        }
    }
    if (-not $docRoot -or -not (Test-Path $docRoot)) {
        if ($confReal) {
            $htdocs = Join-Path (Split-Path (Split-Path $confReal)) "htdocs"
            if (Test-Path $htdocs) { $docRoot = $htdocs; $Script:HTTP_DIR_APACHE = $docRoot }
        }
    }

    http_crear_usuario_dedicado $Script:HTTP_USUARIO_APACHE $docRoot
    _http_configurar_firewall_inicial "apache" $Puerto
    Write-Host ""
    http_crear_index "apache" $Version $Puerto
    http_draw_resumen "Apache HTTP Server" "$Puerto" "$Version"
}

function _repo_configurar_post_nginx {
    param([int]$Puerto, [string]$Version)

    Write-Host ""
    draw_line
    aputs_info "PASO 2/5 — Configurar puerto en nginx.conf"
    draw_line

    if (-not $Script:HTTP_CONF_NGINX -or -not (Test-Path $Script:HTTP_CONF_NGINX)) {
        # Buscar nginx.conf en C:\tools
        $nginxConf = Get-ChildItem "C:\tools" -Recurse -Filter nginx.conf `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($nginxConf) { $Script:HTTP_CONF_NGINX = $nginxConf.FullName }
    }

    if ($Script:HTTP_CONF_NGINX -and (Test-Path $Script:HTTP_CONF_NGINX)) {
        http_crear_backup $Script:HTTP_CONF_NGINX
        $bytes = [System.IO.File]::ReadAllBytes($Script:HTTP_CONF_NGINX)
        $enc   = [System.Text.Encoding]::UTF8.GetString($bytes)
        $enc   = $enc -replace 'listen\s+\d+;', "listen $Puerto;"
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Script:HTTP_CONF_NGINX, $enc, $utf8NoBom)
        aputs_success "Puerto $Puerto configurado en nginx.conf"
    }

    # Registrar nginx como servicio con NSSM si está disponible
    $nginxDir = Split-Path (Split-Path $Script:HTTP_CONF_NGINX)
    $nginxExe = Join-Path $nginxDir "nginx.exe"
    $svcNginx = Get-Service -Name "nginx" -ErrorAction SilentlyContinue
    if (-not $svcNginx -and (Test-Path $nginxExe)) {
        $nssm = Get-Command nssm -ErrorAction SilentlyContinue
        if ($nssm) {
            & nssm install nginx $nginxExe 2>$null
            & nssm set nginx AppDirectory $nginxDir 2>$null
            aputs_success "Servicio nginx registrado con NSSM"
        } else {
            # Sin NSSM: arrancar directamente
            Start-Process $nginxExe -WorkingDirectory $nginxDir -WindowStyle Hidden
            aputs_info "Nginx iniciado (sin servicio Windows — instale NSSM para persistencia)"
        }
    }

    Set-Service -Name $Script:HTTP_WINSVC_NGINX -StartupType Automatic `
        -ErrorAction SilentlyContinue
    Restart-Service -Name $Script:HTTP_WINSVC_NGINX -Force `
        -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    http_crear_usuario_dedicado $Script:HTTP_USUARIO_NGINX $Script:HTTP_DIR_NGINX
    _http_configurar_firewall_inicial "nginx" $Puerto
    Write-Host ""
    http_crear_index "nginx" $Version $Puerto
    http_draw_resumen "Nginx" "$Puerto" "$Version"
}

# 
# Agrega la pregunta "¿cuántas versiones descargar?" antes de descargar
# 
function ssl_repo_descargar_paquete {
    param([string]$Servicio)

    $destDir = _repo_dir_servicio $Servicio
    if (-not $destDir) { return $false }

    Write-Host ""
    draw_line
    aputs_info "Descargando: $Servicio"
    draw_line
    Write-Host ""

    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    # ── Preguntar cuántas versiones almacenar ─────────────────────────────────
    aputs_info "¿Cuántas versiones desea almacenar en el repositorio?"
    Write-Host ""
    Write-Host "  Más versiones permiten elegir al instalar (como en Linux)"
    Write-Host "  Cada versión ocupa espacio adicional en disco"
    Write-Host ""

    $numVersiones = ""
    do {
        $numVersiones = Read-Host "  Número de versiones [1-3, Enter=1]"
        if ([string]::IsNullOrWhiteSpace($numVersiones)) { $numVersiones = "1" }
    } while ($numVersiones -notmatch '^[123]$')
    $numVersiones = [int]$numVersiones

    aputs_success "$numVersiones versión(es) a descargar"
    Write-Host ""

    # Limpiar instaladores anteriores
    $anteriores = Get-ChildItem $destDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.sha256$' }
    if ($anteriores.Count -gt 0) {
        aputs_info "Limpiando instaladores anteriores..."
        $anteriores | Remove-Item -Force
        Get-ChildItem $destDir -Filter "*.sha256" -ErrorAction SilentlyContinue |
            Remove-Item -Force
        aputs_success "Limpiado"
    }

    if (-not (check_connectivity "8.8.8.8")) {
        aputs_error "Sin conectividad a internet"
        return $false
    }

    $descargaOk = $false

    switch ($Servicio.ToLower()) {

        "iis" {
            # IIS: generar script de activación (1 versión siempre)
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
            # Apache para Windows via choco install -> copiar al repositorio
            # Usamos choco install (no choco download que requiere plugin extra)
            # y luego copiamos el binario instalado al repositorio como "instalador"
            aputs_info "Instalando apache-httpd con choco para capturar binarios..."
            & choco install apache-httpd -y --no-progress 2>&1 | Out-Null

            # Buscar el directorio de instalación
            $apacheInstalado = $null
            $candidatos = @(
                "$env:APPDATA\Apache24",
                "$env:APPDATA\Apache2.4",
                "C:\Apache24",
                "C:\tools\httpd"
            )
            foreach ($c in $candidatos) {
                if (Test-Path "$c\bin\httpd.exe") { $apacheInstalado = $c; break }
            }
            if (-not $apacheInstalado) {
                $exe = Get-ChildItem $env:APPDATA -Recurse -Filter httpd.exe `
                    -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($exe) { $apacheInstalado = Split-Path (Split-Path $exe.FullName) }
            }

            if ($apacheInstalado) {
                # Obtener versión real
                $httpdExe = "$apacheInstalado\bin\httpd.exe"
                $verReal  = ""
                try {
                    $verInfo = & $httpdExe -v 2>&1 | Select-String "Apache/"
                    if ($verInfo -match "Apache/(\d+\.\d+\.\d+)") { $verReal = $Matches[1] }
                } catch {}
                if (-not $verReal) { $verReal = "2.4.x" }

                # Comprimir el directorio instalado como .zip para el repositorio
                # Excluir logs\ — Apache los tiene abiertos y Compress-Archive falla
                $zipDest = Join-Path $destDir "httpd-$verReal-win64.zip"
                aputs_info "Comprimiendo Apache $verReal para el repositorio (sin logs)..."
                try {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    $zipStream = [System.IO.File]::Open($zipDest,
                        [System.IO.FileMode]::Create,
                        [System.IO.FileAccess]::Write)
                    $archive = New-Object System.IO.Compression.ZipArchive($zipStream,
                        [System.IO.Compression.ZipArchiveMode]::Create)

                    $baseLen = $apacheInstalado.Length + 1
                    Get-ChildItem $apacheInstalado -Recurse -File -ErrorAction SilentlyContinue |
                        Where-Object {
                            # Excluir logs y archivos .pid que Apache mantiene abiertos
                            $_.FullName -notmatch '\\logs\\' -and
                            $_.Extension -ne '.pid'
                        } | ForEach-Object {
                            $entryName = "Apache24\" + $_.FullName.Substring($baseLen)
                            try {
                                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                                    $archive, $_.FullName, $entryName,
                                    [System.IO.Compression.CompressionLevel]::Fastest) | Out-Null
                            } catch {}
                        }

                    $archive.Dispose()
                    $zipStream.Dispose()
                    aputs_success "Apache $verReal empaquetado: $(Split-Path $zipDest -Leaf)"
                    $descargaOk = $true
                }
                catch {
                    aputs_error "No se pudo empaquetar: $($_.Exception.Message)"
                    if ($zipStream) { try { $zipStream.Dispose() } catch {} }
                }
            }
            else {
                aputs_error "No se encontró Apache instalado por choco"
                aputs_info  "Instale manualmente con: choco install apache-httpd -y"
                aputs_info  "Luego copie el directorio a: $destDir"
            }
        }

        "nginx" {
            # Nginx: descargar $numVersiones versiones desde nginx.org
            $versionesNginx = @("1.26.2","1.24.0","1.22.1")
            $descargadas = 0
            foreach ($ver in $versionesNginx) {
                if ($descargadas -ge $numVersiones) { break }
                $url      = "https://nginx.org/download/nginx-$ver.zip"
                $destFile = Join-Path $destDir "nginx-$ver.zip"
                aputs_info "Descargando Nginx $ver..."
                try {
                    Invoke-WebRequest -Uri $url -OutFile $destFile `
                        -UseBasicParsing -MaximumRedirection 5 -ErrorAction Stop
                    aputs_success "Descargado: nginx-$ver.zip"
                    $descargadas++
                    $descargaOk = $true
                }
                catch {
                    aputs_warning "No se pudo descargar Nginx ${ver}: $($_.Exception.Message)"
                    Remove-Item $destFile -ErrorAction SilentlyContinue
                }
            }
            if (-not $descargaOk) {
                aputs_error "No se pudo descargar ninguna versión de Nginx"
                aputs_info  "Descargue manualmente desde https://nginx.org/en/download.html"
            }
        }

        "tomcat" {
            # Tomcat: descargar instalador .exe oficial desde Apache
            # Se descarga una vez al repo y de ahí se instala sin internet
            aputs_info "Descargando instalador oficial de Apache Tomcat al repositorio..."

            $descargadas = 0
            $majores = @("10", "9")

            foreach ($major in $majores) {
                if ($descargadas -ge $numVersiones) { break }
                try {
                    $indexUrl = "https://dlcdn.apache.org/tomcat/tomcat-${major}/"
                    $resp = Invoke-WebRequest -Uri $indexUrl -UseBasicParsing -ErrorAction Stop
                    $versiones = $resp.Links |
                        Where-Object { $_.href -match "^v${major}\." } |
                        Select-Object -ExpandProperty href |
                        ForEach-Object { $_ -replace '/$','' -replace '^v','' } |
                        Sort-Object { [version]($_ -replace '[^0-9.]','') } -Descending

                    foreach ($ver in $versiones) {
                        if ($descargadas -ge $numVersiones) { break }
                        $exeUrl  = "https://dlcdn.apache.org/tomcat/tomcat-${major}/v${ver}/bin/apache-tomcat-${ver}.exe"
                        $destFile = Join-Path $destDir "apache-tomcat-${ver}.exe"
                        aputs_info "Descargando Tomcat ${ver}..."
                        try {
                            Invoke-WebRequest -Uri $exeUrl -OutFile $destFile `
                                -UseBasicParsing -MaximumRedirection 5 -ErrorAction Stop
                            if ((Get-Item $destFile).Length -gt 1MB) {
                                aputs_success "Descargado: apache-tomcat-${ver}.exe ($([Math]::Round((Get-Item $destFile).Length/1MB,1)) MB)"
                                $descargadas++
                                $descargaOk = $true
                            } else {
                                Remove-Item $destFile -Force -EA SilentlyContinue
                            }
                        } catch {
                            aputs_warning "No se pudo descargar Tomcat ${ver}"
                            Remove-Item $destFile -EA SilentlyContinue
                        }
                    }
                } catch {
                    aputs_warning "No se pudo consultar versiones Tomcat ${major}"
                }
            }

            if (-not $descargaOk) {
                aputs_error "No se pudo descargar ninguna version de Tomcat"
                aputs_info  "Descargue manualmente el instalador .exe desde:"
                aputs_info  "  https://tomcat.apache.org/download-10.cgi"
                aputs_info  "Y copielo a: $destDir"
            }
        }
    }

    if (-not $descargaOk) { return $false }

    # Listar lo descargado
    $descargados = Get-ChildItem $destDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.sha256$' }

    if ($descargados.Count -eq 0) { return $false }

    Write-Host ""
    aputs_success "Instalador(es) descargado(s):"
    foreach ($f in $descargados) {
        Write-Host ("    {0,-50} {1} MB" -f $f.Name, [Math]::Round($f.Length/1MB, 1))
    }

    # Generar SHA256 para cada archivo
    Write-Host ""
    aputs_info "Generando checksums SHA256..."
    Write-Host ""
    foreach ($f in $descargados) {
        $shaFile = "$($f.FullName).sha256"
        $hash = (Get-FileHash -Path $f.FullName -Algorithm SHA256).Hash.ToLower()
        "$hash  $($f.Name)" | Set-Content -Path $shaFile -Encoding ASCII
        aputs_success "$($f.Name).sha256 -> $($hash.Substring(0,16))..."
    }

    Write-Host ""
    aputs_success "Paquete '$Servicio' listo en el repositorio ($($descargados.Count) versión(es))"
    return $true
}

# 
# Configura IIS sin reiniciar W3SVC ni tocar FTPSVC
# Solo modifica bindings via WebAdministration — sin iisreset, sin Restart-Service
# 
function http_instalar_iis {
    param([string]$Version, [int]$Puerto)

    http_draw_servicio_header "IIS" "Configuracion HTTP (sin tocar FTP)"

    # Instalar features si no están
    $iisInstalado = (Get-WindowsFeature -Name "Web-Server" -ErrorAction SilentlyContinue).Installed
    if (-not $iisInstalado) {
        aputs_info "Instalando features de IIS..."
        Import-Module ServerManager -ErrorAction SilentlyContinue
        $features = @("Web-Server","Web-Common-Http","Web-Static-Content",
            "Web-Default-Doc","Web-Http-Logging","Web-Security",
            "Web-Filtering","Web-Performance","Web-Stat-Compression",
            "Web-Mgmt-Tools","Web-Scripting-Tools")
        foreach ($feat in $features) {
            $r = Install-WindowsFeature -Name $feat -ErrorAction SilentlyContinue
            if ($r.Success) { Write-Host "  ${GREEN}[OK]${NC}  $feat" }
        }
        aputs_success "Features de IIS instaladas"
    } else {
        aputs_info "IIS ya instalado — solo configurando binding"
    }

    # Cargar WebAdministration
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    $appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"

    # ── GARANTIZAR BINDING FTP ANTES DE TOCAR NADA ────────────────────────────
    # El FTP Site puede tener <bindings></bindings> vacío en applicationHost.config.
    # Cuando IIS recarga el config (por cualquier cambio de binding), el FTP Site
    # arranca sin puerto y queda inaccesible aunque FTPSVC siga Running.
    # La solución: asegurar el binding *:21 ANTES de cualquier modificación.
    aputs_info "Garantizando binding FTP en puerto 21 antes de configurar HTTP..."
    try {
        $ftpSite = Get-Website | Where-Object { $_.Name -match "FTP" } |
            Select-Object -First 1
        if ($ftpSite) {
            $ftpBinding = Get-WebBinding -Name $ftpSite.Name -Protocol "ftp" `
                -ErrorAction SilentlyContinue
            if (-not $ftpBinding) {
                # Binding FTP ausente — agregarlo ahora
                New-WebBinding -Name $ftpSite.Name -Protocol ftp -Port 21 `
                    -IPAddress "*" -ErrorAction SilentlyContinue | Out-Null
                aputs_success "Binding FTP *:21 agregado a '$($ftpSite.Name)' (estaba vacío)"
            } else {
                aputs_info "Binding FTP verificado: $($ftpBinding.bindingInformation)"
            }
        }
    } catch {
        aputs_warning "No se pudo verificar binding FTP: $($_.Exception.Message)"
    }

    # ── CONFIGURAR BINDING HTTP ────────────────────────────────────────────────
    # Modificar binding HTTP usando appcmd — no causa reinicio de otros sitios.
    # appcmd modifica applicationHost.config y notifica a IIS para recargar
    # solo el sitio afectado, sin detener otros sitios.
    aputs_info "Configurando binding HTTP en puerto $Puerto (sin afectar FTP)..."
    $bindingOk = $false
    try {
        # appcmd set site modifica solo el Default Web Site
        $resultado = & $appcmd set site "Default Web Site" `
            /bindings:"http/*:${Puerto}:" 2>&1
        Start-Sleep -Milliseconds 500

        # Verificar que el binding quedó correctamente
        $binding = Get-WebBinding -Name "Default Web Site" -Protocol "http" `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.bindingInformation -match ":${Puerto}:" }
        if ($binding) {
            aputs_success "Binding HTTP configurado: *:${Puerto} (via appcmd)"
            $bindingOk = $true
        } else {
            aputs_warning "appcmd no confirmó el binding — usando WebAdministration como fallback"
        }
    } catch {
        aputs_warning "appcmd falló: $($_.Exception.Message)"
    }

    if (-not $bindingOk) {
        # Fallback: WebAdministration con restauración garantizada de FTP
        try {
            Import-Module WebAdministration -ErrorAction Stop

            # Quitar binding HTTP anterior y agregar el nuevo
            Get-WebBinding -Name "Default Web Site" -Protocol "http" `
                -ErrorAction SilentlyContinue | Remove-WebBinding -ErrorAction SilentlyContinue
            New-WebBinding -Name "Default Web Site" -Protocol http `
                -Port $Puerto -IPAddress "*" -ErrorAction Stop | Out-Null
            aputs_success "Binding HTTP configurado: *:${Puerto} (via WebAdministration)"
            $bindingOk = $true
        } catch {
            aputs_error "Error configurando binding HTTP: $($_.Exception.Message)"
        }
    }

    # ── RESTAURAR FTP DESPUÉS DEL CAMBIO DE BINDING ───────────────────────────
    # Cualquier cambio en applicationHost.config causa que IIS recargue todos
    # los sitios. El FTP Site puede quedar sin binding o detenido.
    # Esperar brevemente para que IIS procese el cambio y luego restaurar.
    Start-Sleep -Seconds 1
    aputs_info "Verificando y restaurando FTP Site post-cambio..."
    try {
        $ftpSite = Get-Website | Where-Object { $_.Name -match "FTP" } |
            Select-Object -First 1
        if ($ftpSite) {
            # 1. Garantizar binding FTP otra vez (puede haberse perdido en el reload)
            $ftpBinding = Get-WebBinding -Name $ftpSite.Name -Protocol "ftp" `
                -ErrorAction SilentlyContinue
            if (-not $ftpBinding) {
                New-WebBinding -Name $ftpSite.Name -Protocol ftp -Port 21 `
                    -IPAddress "*" -ErrorAction SilentlyContinue | Out-Null
                aputs_success "Binding FTP *:21 restaurado en '$($ftpSite.Name)'"
            }

            # 2. Asegurar serverAutoStart="true" en applicationHost.config
            # Si está en false, IIS no lo levanta en el próximo reload
            $autoStart = (Get-ItemProperty "IIS:\Sites\$($ftpSite.Name)" `
                -Name serverAutoStart -ErrorAction SilentlyContinue)
            if ($autoStart -ne $true) {
                Set-ItemProperty "IIS:\Sites\$($ftpSite.Name)" `
                    -Name serverAutoStart -Value $true -ErrorAction SilentlyContinue
                aputs_success "FTP Site serverAutoStart=true garantizado"
            }

            # 3. Iniciar el FTP Site si quedó detenido
            $ftpEstado = (Get-Website -Name $ftpSite.Name).State
            if ($ftpEstado -ne "Started") {
                aputs_info "FTP Site detenido — iniciando..."
                # appcmd es más confiable que Start-Website para FTP
                & $appcmd start site /site.name:"$($ftpSite.Name)" 2>$null | Out-Null
                Start-Sleep -Seconds 2
                $ftpEstado = (Get-Website -Name $ftpSite.Name).State
            }

            if ($ftpEstado -eq "Started") {
                aputs_success "FTP Site '$($ftpSite.Name)' activo en puerto 21"
            } else {
                aputs_warning "FTP Site no inició — intente manualmente: appcmd start site /site.name:`"$($ftpSite.Name)`""
            }
        }
    } catch {
        aputs_warning "Error verificando FTP post-cambio: $($_.Exception.Message)"
    }

    # Desactivar idleTimeout del DefaultAppPool — si está en 20min detiene FTP Site
    try {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        Set-WebConfiguration `
            "/system.applicationHost/applicationPools/add[@name='DefaultAppPool']/processModel/@idleTimeout" `
            -Value "00:00:00" -ErrorAction SilentlyContinue
        aputs_success "DefaultAppPool idleTimeout desactivado"
    } catch {}

    # Crear app pool dedicado para FTP — aislarlo del DefaultAppPool
    # Cuando DefaultAppPool recicla (por Remove/New-WebBinding), FTP Site cae con él
    try {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        $appcmdExe = "$env:SystemRoot\system32\inetsrv\appcmd.exe"

        # Crear FtpAppPool si no existe
        $poolExiste = Get-WebConfiguration "/system.applicationHost/applicationPools/add[@name='FtpAppPool']" -ErrorAction SilentlyContinue
        if (-not $poolExiste) {
            & $appcmdExe add apppool /name:"FtpAppPool" 2>$null | Out-Null
            # Desactivar idleTimeout del nuevo pool
            Set-WebConfiguration `
                "/system.applicationHost/applicationPools/add[@name='FtpAppPool']/processModel/@idleTimeout" `
                -Value "00:00:00" -ErrorAction SilentlyContinue
            aputs_success "App pool dedicado 'FtpAppPool' creado"
        }

        # Mover FTP Site al pool dedicado
        $ftpSite = Get-Website | Where-Object { $_.Name -match "FTP" } | Select-Object -First 1
        if ($ftpSite) {
            $poolActual = (Get-WebConfiguration "/system.applicationHost/sites/site[@name='$($ftpSite.Name)']/application/@applicationPool").Value
            if ($poolActual -ne "FtpAppPool") {
                & $appcmdExe set site /site.name:"$($ftpSite.Name)" "/[path='/'].applicationPool:FtpAppPool" 2>$null | Out-Null
                aputs_success "FTP Site '$($ftpSite.Name)' movido a FtpAppPool — aislado del DefaultAppPool"
            } else {
                aputs_info "FTP Site ya usa FtpAppPool"
            }
        }
    } catch {
        aputs_warning "No se pudo aislar FtpAppPool: $($_.Exception.Message)"
    }

    # Iniciar W3SVC SOLO si no está corriendo — sin Restart, sin iisreset
    $w3 = Get-Service -Name "W3SVC" -ErrorAction SilentlyContinue
    if ($w3 -and $w3.Status -ne "Running") {
        aputs_info "Iniciando W3SVC (primera vez)..."
        Set-Service -Name "W3SVC" -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name "W3SVC" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        if (check_service_active "W3SVC") {
            aputs_success "W3SVC iniciado"
        } else {
            aputs_error "W3SVC no levantó — revise el Visor de Eventos"
            return $false
        }
    } else {
        aputs_success "W3SVC ya estaba activo — no se reinició (FTP intacto)"
    }

    http_crear_usuario_dedicado $Script:HTTP_USUARIO_IIS $Script:HTTP_DIR_IIS
    _http_configurar_firewall_inicial "iis" $Puerto
    Write-Host ""
    http_crear_index "iis" "sistema" $Puerto

    $iisVer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp" `
        -ErrorAction SilentlyContinue).VersionString
    http_draw_resumen "IIS" "$Puerto" "$iisVer"

    # Ofrecer SSL inmediatamente tras instalar
    _repo_ofrecer_ssl "iis" $Puerto
    return $true
}

# 
# _repo_ofrecer_ssl  <servicio>  <httpPort>
#
# Se llama al final de cada http_instalar_* para preguntar si se aplica
# SSL al servicio recién instalado, sin necesidad de volver al menú principal.
#
# Requiere: ssl_cert_generar, ssl_http_aplicar_* de P7 cargados en scope.
# Si P7 no está cargado todavía, omite sin error.
# 
function _repo_ofrecer_ssl {
    param([string]$Servicio, [int]$HttpPort)

    # Solo ofrecer si las funciones SSL de P7 están disponibles
    if (-not (Get-Command ssl_http_aplicar_iis -ErrorAction SilentlyContinue) -and
        -not (Get-Command ssl_cert_generar     -ErrorAction SilentlyContinue)) {
        return  # P7 no cargado — omitir silenciosamente
    }

    Write-Host ""
    draw_line
    Write-Host ""
    $resp = Read-MenuInput "¿Configurar SSL/HTTPS en $Servicio ahora? [s/N]"
    if ($resp -notmatch '^[Ss]$') {
        aputs_info "SSL omitido — puede configurarse después desde el Paso 5"
        return
    }

    Write-Host ""

    # Generar certificado si no existe
    if (Get-Command ssl_cert_existe -ErrorAction SilentlyContinue) {
        if (-not (ssl_cert_existe)) {
            aputs_info "Certificado no existe — generando..."
            Write-Host ""
            if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
                aputs_info "Instalando openssl..."
                & choco install openssl -y --no-progress 2>&1 | Out-Null
                $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                            [System.Environment]::GetEnvironmentVariable("PATH","User")
            }
            if (Get-Command ssl_cert_generar -ErrorAction SilentlyContinue) {
                ssl_cert_generar | Out-Null
            }
        } else {
            aputs_info "Certificado existente — reutilizando"
        }
    }

    Write-Host ""

    # Aplicar SSL solo al servicio recién instalado
    $ok = $false
    switch ($Servicio.ToLower()) {
        "iis"    { if (Get-Command ssl_http_aplicar_iis    -EA SilentlyContinue) { $ok = ssl_http_aplicar_iis    } }
        "apache" { if (Get-Command ssl_http_aplicar_apache -EA SilentlyContinue) { $ok = ssl_http_aplicar_apache } }
        "nginx"  { if (Get-Command ssl_http_aplicar_nginx  -EA SilentlyContinue) { $ok = ssl_http_aplicar_nginx  } }
        "tomcat" { if (Get-Command ssl_http_aplicar_tomcat -EA SilentlyContinue) { $ok = ssl_http_aplicar_tomcat } }
    }

    if ($ok) {
        aputs_success "SSL configurado en $Servicio"
    } else {
        aputs_warning "SSL no pudo configurarse — intente desde el Paso 5 del menú principal"
    }
    Write-Host ""
}



# 
# Para IIS: usa Set-WebConfiguration en lugar de Restart-Service W3SVC
# 
function http_reiniciar_servicio {
    param([string]$Servicio)

    $winsvc  = http_nombre_winsvc $Servicio
    $appcmd  = "$env:SystemRoot\system32\inetsrv\appcmd.exe"

    # IIS necesita tratamiento especial — Restart-Service W3SVC mata FTPSVC
    if ($Servicio -eq "iis" -or $winsvc -eq "W3SVC") {
        aputs_info "Recargando IIS sin reiniciar W3SVC (proteccion FTP)..."
        try {
            Import-Module WebAdministration -ErrorAction Stop

            # Verificar W3SVC
            if (-not (check_service_active "W3SVC")) {
                Start-Service "W3SVC" -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
            aputs_success "W3SVC activo — FTP no interrumpido"

            # Garantizar binding FTP y estado del sitio
            $ftpSite = Get-Website | Where-Object { $_.Name -match "FTP" } |
                Select-Object -First 1
            if ($ftpSite) {
                # Binding
                $ftpBinding = Get-WebBinding -Name $ftpSite.Name -Protocol "ftp" `
                    -ErrorAction SilentlyContinue
                if (-not $ftpBinding) {
                    New-WebBinding -Name $ftpSite.Name -Protocol ftp -Port 21 `
                        -IPAddress "*" -ErrorAction SilentlyContinue | Out-Null
                    aputs_success "Binding FTP *:21 restaurado en '$($ftpSite.Name)'"
                }
                # serverAutoStart
                Set-ItemProperty "IIS:\Sites\$($ftpSite.Name)" `
                    -Name serverAutoStart -Value $true -ErrorAction SilentlyContinue

                # Iniciar si está detenido
                if ((Get-Website -Name $ftpSite.Name).State -ne "Started") {
                    & $appcmd start site /site.name:"$($ftpSite.Name)" 2>$null | Out-Null
                    Start-Sleep -Seconds 2
                    if ((Get-Website -Name $ftpSite.Name).State -eq "Started") {
                        aputs_success "FTP Site '$($ftpSite.Name)' restaurado"
                    } else {
                        aputs_warning "FTP Site no inició — verifique manualmente"
                    }
                } else {
                    aputs_success "FTP Site '$($ftpSite.Name)' activo"
                }
            }
            return $true
        }
        catch {
            aputs_warning "WebAdministration no disponible: $($_.Exception.Message)"
            return (check_service_active "W3SVC")
        }
    }

    # Nginx especial: corre como proceso, no como servicio Windows
    if ($Servicio -eq "nginx" -or $winsvc -eq "nginx") {
        aputs_info "Reiniciando nginx (proceso)..."
        $nginxConf = $Script:HTTP_CONF_NGINX
        $nginxExe  = if ($nginxConf) {
            Join-Path (Split-Path (Split-Path $nginxConf)) "nginx.exe"
        } else { $null }

        # Buscar nginx.exe si no lo tenemos
        if (-not $nginxExe -or -not (Test-Path $nginxExe)) {
            $nginxItem = Get-ChildItem "C:\tools" -Recurse -Filter "nginx.exe" `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($nginxItem) { $nginxExe = $nginxItem.FullName }
        }

        if ($nginxExe -and (Test-Path $nginxExe)) {
            $nginxDir = Split-Path $nginxExe
            # Detener proceso nginx actual
            Get-Process -Name "nginx" -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep -Seconds 2
            # Arrancar nginx de nuevo
            Start-Process -FilePath $nginxExe -WorkingDirectory $nginxDir -WindowStyle Hidden
            Start-Sleep -Seconds 2
            if (Get-Process -Name "nginx" -ErrorAction SilentlyContinue) {
                aputs_success "nginx reiniciado"
                return $true
            } else {
                aputs_error "nginx no levantó"
                return $false
            }
        } else {
            aputs_error "nginx.exe no encontrado"
            return $false
        }
    }

    # Apache: asegurar que el servicio apunta al ejecutable correcto
    if ($Servicio -eq "apache") {
        $svcApache = Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -imatch '^Apache' } | Select-Object -First 1
        if ($svcApache) {
            $svcWmi = Get-WmiObject Win32_Service -Filter "Name='$($svcApache.Name)'" -EA SilentlyContinue
            $exeActual = if ($svcWmi) { $svcWmi.PathName -replace '"','' -replace '\s+-k.*','' -replace '^\s+|\s+$','' } else { "" }
            # Si el servicio apunta a AppData pero C:\Apache24 existe, corregir
            if ($exeActual -match 'AppData' -and (Test-Path "C:\Apache24\bin\httpd.exe")) {
                $regKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$($svcApache.Name)"
                Set-ItemProperty -Path $regKey -Name "ImagePath" `
                    -Value '"C:\Apache24\bin\httpd.exe" -k runservice' -EA SilentlyContinue
                aputs_info "Servicio Apache redirigido a C:\Apache24\bin\httpd.exe"
                # Sincronizar httpd.conf desde AppData a C:\Apache24
                $confAppData = "$env:APPDATA\Apache24\conf\httpd.conf"
                $confApache24 = "C:\Apache24\conf\httpd.conf"
                if (Test-Path $confAppData) {
                    $enc = [System.IO.File]::ReadAllText($confAppData)
                    $enc = $enc -replace 'Define SRVROOT ".*"', 'Define SRVROOT "C:/Apache24"'
                    $enc = $enc -replace '(?m)^(Include\s+conf/extra/httpd-ahssl\.conf)', '# [P7] $1'
                    [System.IO.File]::WriteAllText($confApache24, $enc, (New-Object System.Text.UTF8Encoding $false))
                    aputs_info "httpd.conf sincronizado a C:\Apache24"
                }
                # Sincronizar ssl_reprobados.conf
                $sslAppData = "$env:APPDATA\Apache24\conf\ssl_reprobados.conf"
                $sslApache24 = "C:\Apache24\conf\ssl_reprobados.conf"
                if (Test-Path $sslAppData) {
                    $sslEnc = [System.IO.File]::ReadAllText($sslAppData)
                    $sslEnc = $sslEnc -replace 'DocumentRoot "[^"]*AppData[^"]*"', 'DocumentRoot "C:/Apache24/htdocs"'
                    [System.IO.File]::WriteAllText($sslApache24, $sslEnc, (New-Object System.Text.UTF8Encoding $false))
                    aputs_info "ssl_reprobados.conf sincronizado a C:\Apache24"
                }
                # Copiar index.html
                $idxAppData = "$env:APPDATA\Apache24\htdocs\index.html"
                if (Test-Path $idxAppData) {
                    Copy-Item $idxAppData "C:\Apache24\htdocs\index.html" -Force
                }
            }
            $winsvc = $svcApache.Name
        }
    }

    # Para Apache, Nginx, Tomcat: comportamiento normal
    aputs_info "Reiniciando $winsvc..."
    try {
        Restart-Service -Name $winsvc -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        if (check_service_active $winsvc) {
            aputs_success "$winsvc reiniciado"
            return $true
        } else {
            aputs_error "$winsvc no levanto tras el reinicio"
            return $false
        }
    }
    catch {
        aputs_error "Error al reiniciar ${winsvc}: $($_.Exception.Message)"
        return $false
    }
}

# 
# Mismo tratamiento — para IIS no hace iisreset
# 
function http_recargar_servicio {
    param([string]$Servicio)
    # Delegar al override de http_reiniciar_servicio que ya es seguro para FTP
    return (http_reiniciar_servicio $Servicio)
}

function http_menu_instalar {
    # Paso 1: seleccion de servicio (P6)
    $seleccion = http_seleccionar_servicio

    switch -Wildcard ($seleccion) {
        "cancelar" {
            aputs_info "Instalacion cancelada"
            Start-Sleep -Seconds 2
            return
        }
        "reinstalar:*" {
            $servicio = $seleccion -replace "reinstalar:", ""
            aputs_warning "Desinstalando $servicio..."
            choco uninstall (http_nombre_paquete $servicio) -y 2>$null
            aputs_success "Desinstalado. Continuando con instalacion limpia..."
            Start-Sleep -Seconds 2
            # Continua al flujo normal de instalacion (no return)
        }
        "reconfigurar:*" {
            $servicio    = $seleccion -replace "reconfigurar:", ""
            $verActual   = _http_obtener_version_local $servicio
            $puertoNew   = http_seleccionar_puerto $servicio

            switch ($servicio) {
                "iis" {
                    Import-Module WebAdministration -ErrorAction SilentlyContinue
                    $site = Get-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
                    if ($site) {
                        Remove-WebBinding -Name "Default Web Site" -ErrorAction SilentlyContinue
                        New-WebBinding -Name "Default Web Site" -Protocol http -Port $puertoNew | Out-Null
                        aputs_success "Binding IIS actualizado: puerto $puertoNew"
                    }
                }
                "apache" {
                    $confFile = http_get_conf_archivo $servicio
                    if (Test-Path $confFile) {
                        http_crear_backup $confFile
                        $bytes = [System.IO.File]::ReadAllBytes($confFile)
                        $enc = if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                            [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
                        } else { [System.Text.Encoding]::UTF8.GetString($bytes) }
                        $enc = $enc -replace 'Listen\s+\d+', "Listen $puertoNew"
                        $enc = $enc -replace 'ServerName\s+\S+:\d+', "ServerName localhost:$puertoNew"
                        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                        [System.IO.File]::WriteAllText($confFile, $enc, $utf8NoBom)
                        aputs_success "Puerto $puertoNew configurado en httpd.conf"
                    }
                }
                "nginx" {
                    $confFile = http_get_conf_archivo $servicio
                    if (Test-Path $confFile) {
                        http_crear_backup $confFile
                        $bytes = [System.IO.File]::ReadAllBytes($confFile)
                        $enc = if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                            [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
                        } else { [System.Text.Encoding]::UTF8.GetString($bytes) }
                        $enc = $enc -replace 'listen\s+\d+;', "listen $puertoNew;"
                        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                        [System.IO.File]::WriteAllText($confFile, $enc, $utf8NoBom)
                        aputs_success "Puerto $puertoNew configurado en nginx.conf"
                    }
                }
                "tomcat" {
                    $confFile = http_get_conf_archivo $servicio
                    if (Test-Path $confFile) {
                        http_crear_backup $confFile
                        [xml]$xml = Get-Content $confFile
                        foreach ($c in $xml.Server.Service.Connector) {
                            if ($c.protocol -match 'HTTP') {
                                $c.SetAttribute("port", "$puertoNew"); break
                            }
                        }
                        $xml.Save($confFile)
                        aputs_success "Puerto $puertoNew configurado en server.xml"
                    }
                }
            }

            if (-not (http_reiniciar_servicio $servicio)) {
                aputs_error "El servicio no levanto — revise la configuracion"
                pause_menu
                return
            }

            _http_configurar_firewall_inicial $servicio $puertoNew
            http_crear_index $servicio $verActual $puertoNew
            http_draw_resumen $servicio $puertoNew $verActual

            # SSL — unico punto que no tenia P6
            _repo_ofrecer_ssl $servicio $puertoNew

            pause_menu
            return
        }
        default { $servicio = $seleccion }
    }

    Write-Host ""

    # Pasos 2-5: versiones, version, puerto, confirmacion, instalacion (P6 original)
    $versiones = http_consultar_versiones $servicio
    if (-not $versiones -or $versiones.Count -eq 0) {
        aputs_error "No se pudieron obtener versiones. Verifique la conexion."
        pause_menu
        return
    }

    Write-Host ""
    $version = http_seleccionar_version $servicio $versiones
    Write-Host ""
    pause_menu

    $puerto = http_seleccionar_puerto $servicio
    Write-Host ""

    draw_line
    aputs_info "Resumen de la instalacion a realizar:"
    Write-Host ""
    Write-Host "    Servicio : $servicio"
    Write-Host "    Version  : $version"
    Write-Host "    Puerto   : ${puerto}/tcp"
    Write-Host ""

    $confirmado = $false
    do {
        $resp = agets "Confirmar instalacion? [s/n]"
        $r = http_validar_confirmacion $resp
        if ($r -eq 0) { $confirmado = $true; break }
        if ($r -eq 1) { aputs_info "Instalacion cancelada"; Start-Sleep 2; return }
        Write-Host ""
    } while ($true)

    draw_line
    Write-Host ""

    switch ($servicio) {
        "iis"    { http_instalar_iis    $version $puerto }
        "apache" { http_instalar_apache $version $puerto }
        "nginx"  { http_instalar_nginx  $version $puerto }
        "tomcat" { http_instalar_tomcat $version $puerto }
    }

    Write-Host ""
    pause_menu
}