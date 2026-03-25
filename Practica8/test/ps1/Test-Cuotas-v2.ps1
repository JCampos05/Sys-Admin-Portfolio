#
# Test-Cuotas.ps1
#
# Corre en DOS escenarios sin cambiar nada:
#   - Servidor Windows: escribe directamente en C:\Perfiles\<usuario>
#   - Cliente Win10:    monta \\SVR\Perfiles$ y escribe via share de red
#
# Uso:
#   En servidor: powershell -ExecutionPolicy Bypass -File Test-Cuotas.ps1
#   En cliente:  powershell -ExecutionPolicy Bypass -File Test-Cuotas.ps1
#

#Requires -Version 5.1

# 
# COLORES Y HELPERS
# 
$ESC    = [char]27
$GREEN  = "$ESC[0;32m"
$RED    = "$ESC[0;31m"
$YELLOW = "$ESC[1;33m"
$BLUE   = "$ESC[0;34m"
$CYAN   = "$ESC[0;36m"
$GRAY   = "$ESC[0;90m"
$NC     = "$ESC[0m"

function aputs_info    { param($m) Write-Host "${BLUE}[INFO]${NC}    $m" }
function aputs_success { param($m) Write-Host "${GREEN}[OK]${NC}      $m" }
function aputs_warning { param($m) Write-Host "${YELLOW}[WARN]${NC}    $m" }
function aputs_error   { param($m) Write-Host "${RED}[ERROR]${NC}   $m" }
function draw_line     { Write-Host "────────────────────────────────────────────────────────" }

function draw_result {
    param([string]$Descripcion, [string]$Esperado, [bool]$Resultado)
    $icono   = if ($Resultado) { "${GREEN}  PASS  ${NC}" } else { "${RED}  FAIL  ${NC}" }
    $espStr  = if ($Esperado -eq "FALLA") { "${YELLOW}$Esperado${NC}" } else { "${GREEN}$Esperado${NC}" }
    Write-Host ("  {0}  {1,-45} Esperado: {2}" -f $icono, $Descripcion, $espStr)
}

# 
# DETECCION DE ENTORNO
# Determina si estamos en el servidor (acceso directo a C:\Perfiles)
# o en el cliente Win10 (necesita montar el share de red).
# 
function Get-Entorno {
    # Si C:\Perfiles existe y tiene carpetas de usuario -> somos el servidor
    if (Test-Path "C:\Perfiles") {
        $subcarpetas = Get-ChildItem "C:\Perfiles" -Directory -ErrorAction SilentlyContinue
        if ($subcarpetas.Count -gt 0) {
            return "SERVIDOR"
        }
    }

    # Verificar si hay un dominio AD configurado en esta maquina
    $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs.PartOfDomain) {
        return "CLIENTE"
    }

    # Fallback: preguntar al usuario
    return "DESCONOCIDO"
}

# 
# MONTAR SHARE DE RED (solo cliente Win10)
# Monta \\SERVIDOR\Perfiles$ como unidad temporal para las pruebas.
# 
function Mount-SharePerfiles {
    param(
        [string]$ServidorIP,
        [string]$Usuario,
        [string]$Password,
        [string]$UsuarioACarpeta,
        [string]$Letra = "Z"
    )

    # Limpiar montaje previo
    net use "${Letra}:" /delete /y 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500

    # Resolver nombre NetBIOS del servidor via PTR DNS
    # Kerberos valida el SPN con nombre de host, no IP
    $servidorRef = $ServidorIP
    try {
        $ptr = Resolve-DnsName $ServidorIP -ErrorAction Stop |
               Where-Object { $_.Type -eq "PTR" } | Select-Object -First 1
        if ($ptr) {
            $servidorRef = $ptr.NameHost.Split(".")[0]
            aputs_info "Nombre NetBIOS resuelto: $servidorRef"
        }
    } catch { }

    # Comando exacto que funciona segun referencia:
    #   net use Z: \SERVIDOR\Perfiles$\usuario
    # Sin /user, sin password, sin /persistent
    # Kerberos de la sesion activa maneja la autenticacion automaticamente
    $sharePath   = "\\$servidorRef\Perfiles`$\$UsuarioACarpeta"
    $sharePathIP = "\\$ServidorIP\Perfiles`$\$UsuarioACarpeta"

    aputs_info "net use ${Letra}: $sharePath"
    $r1 = net use "${Letra}:" $sharePath /persistent:yes 2>&1
    if ($LASTEXITCODE -eq 0) {
        aputs_success "Z: montado: ${Letra}: -> $sharePath"
        return "${Letra}:"
    }
    aputs_warning "Con nombre fallo ($r1), intentando con IP..."

    $r2 = net use "${Letra}:" $sharePathIP /persistent:yes 2>&1
    if ($LASTEXITCODE -eq 0) {
        aputs_success "Z: montado (IP): ${Letra}: -> $sharePathIP"
        return "${Letra}:"
    }
    aputs_warning "Con IP fallo ($r2), intentando con credenciales..."

    $r3 = net use "${Letra}:" $sharePathIP /user:"$Usuario" "$Password" 2>&1
    if ($LASTEXITCODE -eq 0) {
        aputs_success "Z: montado (cred): ${Letra}: -> $sharePathIP"
        return "${Letra}:"
    }

    aputs_error "No se pudo montar Z:. Ultimo error: $r3"
    aputs_info  "Intente manualmente: net use Z: $sharePath"
    return $null
}

# 
# PRUEBA INDIVIDUAL
# Intenta escribir un archivo de tamano dado en la carpeta destino.
# Retorna $true si la escritura FALLO (cuota bloqueó) o $false si pasó.
# El parametro $Debefallar indica cual es el resultado esperado.
# 
function Invoke-PruebaEscritura {
    param(
        [string]$RutaArchivo,
        [long]$TamanoBytesContenido,
        [bool]$DebeFallar,
        [string]$Descripcion
    )

    $chunkSize = 64 * 1024  # 64 KB por chunk
    $buffer    = New-Object byte[] $chunkSize
    $fallo     = $false
    $mensajeError = ""

    try {
        $stream = [System.IO.File]::Open(
            $RutaArchivo,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $escritos = [long]0
        while ($escritos -lt $TamanoBytesContenido) {
            $restante  = $TamanoBytesContenido - $escritos
            $aEscribir = [Math]::Min($chunkSize, $restante)
            $stream.Write($buffer, 0, $aEscribir)
            $escritos += $aEscribir
        }
        $stream.Flush()
        $stream.Close()
        $stream.Dispose()
        $fallo = $false
    } catch {
        $fallo        = $true
        $mensajeError = $_.Exception.Message
        # Cerrar stream si quedo abierto
        if ($null -ne $stream) {
            try { $stream.Close(); $stream.Dispose() } catch { }
        }
    }

    # Limpiar el archivo si se creo (completo o parcial)
    Start-Sleep -Milliseconds 200
    if (Test-Path $RutaArchivo) {
        Remove-Item $RutaArchivo -Force -ErrorAction SilentlyContinue
    }

    # Evaluar resultado contra lo esperado
    $paso = ($fallo -eq $DebeFallar)
    $esperadoStr = if ($DebeFallar) { "FALLA" } else { "EXITO" }
    draw_result -Descripcion $Descripcion -Esperado $esperadoStr -Resultado $paso

    if (-not $paso) {
        if ($DebeFallar -and -not $fallo) {
            aputs_warning "  El archivo se escribio cuando debia ser bloqueado."
            aputs_warning "  Verifique que la cuota HARD esta aplicada en esa carpeta."
        } elseif (-not $DebeFallar -and $fallo) {
            aputs_warning "  El archivo fue bloqueado cuando debia permitirse."
            aputs_warning "  Error: $mensajeError"
        }
    }

    return $paso
}

function Invoke-PruebasUsuario {
    param(
        [string]$CarpetaBase,
        [string]$Usuario,
        [int]$CuotaMB,
        [string]$Grupo
    )

    $carpetaUsuario = if ([string]::IsNullOrEmpty($Usuario)) {
        $CarpetaBase   # Z: ya ES la carpeta del usuario
    } else {
        Join-Path $CarpetaBase $Usuario
    }

    Write-Host ""
    draw_line
    Write-Host "  ${CYAN}Usuario: $Usuario${NC}   ${GRAY}($Grupo — cuota $CuotaMB MB)${NC}"
    draw_line
    Write-Host ""

    # Verificar que la carpeta existe
    if (-not (Test-Path $carpetaUsuario)) {
        aputs_error "Carpeta no encontrada: $carpetaUsuario"
        aputs_info  "Verifique que el share esta montado y que la Fase B se completo."
        return @{ Total = 0; Pasaron = 0; Fallaron = 0 }
    }

    # Limpiar archivos residuales de pruebas anteriores
    aputs_info "Limpiando archivos residuales de pruebas anteriores..."
    Get-ChildItem $carpetaUsuario -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "prueba_*" -or $_.Name -like "test_*" } |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

    # Calcular espacio real disponible en la carpeta
    # Hay que considerar archivos existentes del usuario que consumen cuota
    $usoActualBytes = (Get-ChildItem $carpetaUsuario -File -Recurse -ErrorAction SilentlyContinue |
                       Measure-Object -Property Length -Sum).Sum
    if ($null -eq $usoActualBytes) { $usoActualBytes = 0 }
    $usoActualMB    = [Math]::Round($usoActualBytes / 1MB, 2)
    $cuotaBytes     = [long]($CuotaMB * 1MB)
    $disponibleMB   = [Math]::Round(($cuotaBytes - $usoActualBytes) / 1MB, 2)

    if ($usoActualBytes -gt 0) {
        aputs_warning "Archivos existentes en la carpeta: $usoActualMB MB usados de $CuotaMB MB"
        aputs_warning "Espacio disponible para pruebas: $disponibleMB MB"
        Write-Host ""
        if ($disponibleMB -le 1) {
            aputs_error "Espacio insuficiente para pruebas significativas ($disponibleMB MB libres)."
            aputs_info  "Elimine archivos de la carpeta del usuario antes de probar."
            aputs_info  "Archivos en la carpeta:"
            Get-ChildItem $carpetaUsuario -File -ErrorAction SilentlyContinue |
                ForEach-Object { aputs_info "  $($_.Name) ($([Math]::Round($_.Length/1KB,1)) KB)" }
            return @{ Total = 0; Pasaron = 0; Fallaron = 0 }
        }
        aputs_info "Ajustando tamanos de prueba al espacio disponible..."
    }

    # Ajustar tamanos de prueba considerando el uso actual
    # Dentro del limite: disponible - 1MB (debe pasar)
    # Fuera del limite:  cuota total + 1MB (debe fallar — siempre excede la cuota)
    $dentroMB = [Math]::Max(1, [int]($disponibleMB - 1))
    $fueraMB  = $CuotaMB + 1
    $dentroB  = [long]($dentroMB * 1MB)
    $fueraB   = [long]($fueraMB  * 1MB)

    if ($usoActualBytes -gt 0) {
        aputs_info "Prueba DENTRO del limite: $dentroMB MB (disponible: $disponibleMB MB)"
        aputs_info "Prueba FUERA del limite:  $fueraMB MB (cuota total: $CuotaMB MB)"
    }

    $total    = 0
    $pasaron  = 0
    $fallaron = 0

    # Los tamanos $dentroMB/$fueraMB/$dentroB/$fueraB ya fueron calculados
    # arriba considerando el uso actual de la carpeta.

    $archivo1 = Join-Path $carpetaUsuario "prueba_sobre_cuota_${fueraMB}mb.bin"
    $p1 = Invoke-PruebaEscritura `
        -RutaArchivo            $archivo1 `
        -TamanoBytesContenido   $fueraB `
        -DebeFallar             $true `
        -Descripcion            "Archivo ${fueraMB}MB (supera cuota ${CuotaMB}MB)"
    $total++; if ($p1) { $pasaron++ } else { $fallaron++ }

    $archivo2 = Join-Path $carpetaUsuario "prueba_dentro_cuota_${dentroMB}mb.bin"
    $p2 = Invoke-PruebaEscritura `
        -RutaArchivo            $archivo2 `
        -TamanoBytesContenido   $dentroB `
        -DebeFallar             $false `
        -Descripcion            "Archivo ${dentroMB}MB (dentro de cuota ${CuotaMB}MB)"
    $total++; if ($p2) { $pasaron++ } else { $fallaron++ }

    $archivo3 = Join-Path $carpetaUsuario "prueba_bloqueado.exe"
    $p3 = Invoke-PruebaEscritura `
        -RutaArchivo            $archivo3 `
        -TamanoBytesContenido   1024 `
        -DebeFallar             $true `
        -Descripcion            "Archivo .exe (file screening activo)"
    $total++; if ($p3) { $pasaron++ } else { $fallaron++ }


    $archivo4 = Join-Path $carpetaUsuario "prueba_bloqueado.mp3"
    $p4 = Invoke-PruebaEscritura `
        -RutaArchivo            $archivo4 `
        -TamanoBytesContenido   1024 `
        -DebeFallar             $true `
        -Descripcion            "Archivo .mp3 (file screening activo)"
    $total++; if ($p4) { $pasaron++ } else { $fallaron++ }

    $archivo5 = Join-Path $carpetaUsuario "prueba_bloqueado.msi"
    $p5 = Invoke-PruebaEscritura `
        -RutaArchivo            $archivo5 `
        -TamanoBytesContenido   1024 `
        -DebeFallar             $true `
        -Descripcion            "Archivo .msi (file screening activo)"
    $total++; if ($p5) { $pasaron++ } else { $fallaron++ }

    Write-Host ""
    aputs_info "Resultado $Usuario : $pasaron/$total pruebas correctas"

    return @{ Total = $total; Pasaron = $pasaron; Fallaron = $fallaron }
}

# 
# FLUJO SERVIDOR
# Corre las pruebas directamente contra C:\Perfiles\
# 
function Invoke-FlujoDesdeServidor {
    draw_line
    Write-Host "  ${CYAN}Modo: SERVIDOR${NC} — acceso directo a C:\Perfiles\"
    draw_line

    $carpetaBase = "C:\Perfiles"

    # Verificar que FSRM esta instalado
    $fsrm = Get-WindowsFeature "FS-Resource-Manager" -ErrorAction SilentlyContinue
    if ($fsrm.InstallState -ne "Installed") {
        aputs_error "FSRM no esta instalado. Ejecute la Fase D desde mainAD.ps1."
        return
    }
    aputs_success "FSRM instalado"

    # Verificar cuotas configuradas
    try {
        $cuotas = Get-FsrmQuota -ErrorAction Stop
        aputs_success "Cuotas FSRM: $($cuotas.Count) configuradas"
    } catch {
        aputs_error "No hay cuotas FSRM configuradas. Ejecute la Fase D."
        return
    }

    # Mostrar estado de cuotas antes de las pruebas
    Write-Host ""
    aputs_info "Estado de cuotas antes de las pruebas:"
    Write-Host ""
    Write-Host ("  {0,-20} {1,-10} {2,-10} {3}" -f "Carpeta","Limite","Uso actual","Tipo")
    Write-Host "  ────────────────────────────────────────────────"
    foreach ($q in $cuotas | Sort-Object Path) {
        $limite = "$([Math]::Round($q.Size/1MB,0)) MB"
        $uso    = "$([Math]::Round($q.Usage/1KB,1)) KB"
        $tipo   = if ($q.SoftLimit) { "Soft" } else { "Hard" }
        $leaf   = Split-Path $q.Path -Leaf
        Write-Host ("  {0,-20} {1,-10} {2,-10} {3}" -f $leaf, $limite, $uso, $tipo)
    }

    # Construir lista de usuarios a probar desde las cuotas FSRM reales
    # Asi no hay nada hardcodeado — si hay mas usuarios o cuotas diferentes,
    # el script los detecta automaticamente.
    Write-Host ""
    aputs_info "Usuarios con cuota configurada en FSRM:"
    Write-Host ""
    Write-Host ("  {0,-20} {1,-10} {2,-10} {3}" -f "Usuario","Limite","Uso actual","Tipo")
    Write-Host "  ────────────────────────────────────────────────"

    $usuariosConCuota = @()
    foreach ($q in $cuotas | Sort-Object Path) {
        $limite  = "$([Math]::Round($q.Size/1MB,0)) MB"
        $uso     = "$([Math]::Round($q.Usage/1KB,1)) KB"
        $tipo    = if ($q.SoftLimit) { "Soft" } else { "Hard" }
        $usuario = Split-Path $q.Path -Leaf
        Write-Host ("  {0,-20} {1,-10} {2,-10} {3}" -f $usuario, $limite, $uso, $tipo)
        $usuariosConCuota += @{
            Usuario = $usuario
            CuotaMB = [int][Math]::Round($q.Size/1MB, 0)
            Path    = $q.Path
        }
    }

    # Pedir al usuario que seleccione cual probar
    Write-Host ""
    aputs_info "Ingrese el usuario a probar (o 'todos' para probar todos con cuota):"
    $seleccion = (Read-Host "  Usuario").Trim().ToLower()

    $aProbar = @()
    if ($seleccion -eq "todos") {
        $aProbar = $usuariosConCuota
    } else {
        $encontrado = $usuariosConCuota | Where-Object { $_.Usuario -eq $seleccion }
        if ($null -eq $encontrado) {
            aputs_error "Usuario '$seleccion' no tiene cuota configurada en FSRM."
            aputs_info  "Verifique que la Fase B y D se completaron correctamente."
            return
        }
        $aProbar = @($encontrado)
    }

    # Inferir grupo desde el tamano de cuota (10MB=Cuates, 5MB=NoCuates)
    # Si la cuota tiene un valor diferente, mostrar el valor real.
    $totalGlobal   = 0
    $pasaronGlobal = 0

    foreach ($u in $aProbar) {
        $grupoStr = switch ($u.CuotaMB) {
            10      { "Cuates" }
            5       { "NoCuates" }
            default { "$($u.CuotaMB)MB" }
        }
        $res = Invoke-PruebasUsuario `
            -CarpetaBase $carpetaBase `
            -Usuario     $u.Usuario `
            -CuotaMB     $u.CuotaMB `
            -Grupo       $grupoStr
        $totalGlobal   += $res.Total
        $pasaronGlobal += $res.Pasaron
    }

    # Mostrar eventos FSRM generados por las pruebas
    Write-Host ""
    draw_line
    aputs_info "Eventos FSRM generados por las pruebas (evidencia para rubrica):"
    Write-Host ""
    try {
        $eventos = Get-WinEvent -LogName "Microsoft-Windows-FSRM/Operational" `
                   -MaxEvents 20 -ErrorAction Stop |
                   Where-Object { $_.Id -in @(8215, 8214, 8210) } |
                   Select-Object -First 10
        if ($eventos.Count -eq 0) {
            aputs_warning "No hay eventos FSRM recientes. Los bloqueos generan eventos ID 8215."
        } else {
            foreach ($ev in $eventos) {
                $msg = $ev.Message -replace "\s+", " "
                $msg = if ($msg.Length -gt 100) { $msg.Substring(0,100) + "..." } else { $msg }
                Write-Host "  $($ev.TimeCreated.ToString('HH:mm:ss'))  ID:$($ev.Id)  $msg"
            }
        }
    } catch {
        aputs_warning "No se pudieron leer eventos FSRM: $($_.Exception.Message)"
    }

    # Resumen final
    Write-Host ""
    draw_line
    $color = if ($pasaronGlobal -eq $totalGlobal) { $GREEN } else { $YELLOW }
    Write-Host "  ${color}Resultado global: $pasaronGlobal / $totalGlobal pruebas correctas${NC}"
    draw_line
}

# 
# FLUJO CLIENTE WIN10
# Monta el share de red y corre las pruebas desde el cliente.
# 
function Invoke-FlujoDesdeCliente {
    draw_line
    Write-Host "  ${CYAN}Modo: CLIENTE Win10${NC} — via share \\SVR\Perfiles$"
    draw_line
    Write-Host ""

    # Detectar IP del servidor por la red INTERNA (192.168.100.x)
    $servidorIP = $null
    try {
        $dcRecord = Resolve-DnsName "_ldap._tcp.dc._msdcs.$env:USERDNSDOMAIN" `
                    -Type SRV -ErrorAction Stop | Select-Object -First 1
        $todasIPs = Resolve-DnsName $dcRecord.NameTarget -ErrorAction Stop |
                    Where-Object { $_.Type -eq "A" }
        $ipInterna = $todasIPs | Where-Object {
            $_.IPAddress -like "192.168.*" -and
            $_.IPAddress -notlike "192.168.70.*" -and
            $_.IPAddress -notlike "192.168.75.*"
        } | Select-Object -First 1
        if ($null -ne $ipInterna) {
            $servidorIP = $ipInterna.IPAddress
            aputs_info "Servidor detectado (red interna): $servidorIP"
        }
    } catch { }

    if ([string]::IsNullOrEmpty($servidorIP)) {
        $servidorIP = Read-Host "  IP del servidor DC (red interna, ej: 192.168.100.20)"
    }

    # Pedir el usuario a probar
    # El usuario determina la carpeta y la cuota — no hay nada hardcodeado.
    Write-Host ""
    aputs_info "Ingrese el usuario cuya carpeta quiere probar."
    aputs_info "Ejemplos: user01 (Cuates, 10MB) | user06 (NoCuates, 5MB)"
    Write-Host ""
    $usuarioAPROBAR = Read-Host "  Usuario a probar"
    $usuarioAPROBAR = $usuarioAPROBAR.Trim().ToLower()

    if ([string]::IsNullOrWhiteSpace($usuarioAPROBAR)) {
        aputs_error "Usuario no ingresado. Abortando."
        return
    }

    # Montar el share con el usuario de la sesion activa
    Write-Host ""
    aputs_info "Usuario de sesion: $env:USERDOMAIN\$env:USERNAME"
    $password = Read-Host "  Password de $env:USERNAME" -AsSecureString
    $passwordPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))

    # Inferir grupo del usuario por numero (user01-05=Cuates, user06-10=NoCuates)
    $cuotaMB  = $null
    $grupoStr = $null
    $numMatch = [regex]::Match($usuarioAPROBAR, '\d+$')
    if ($numMatch.Success) {
        $num = [int]$numMatch.Value
        if ($num -ge 1 -and $num -le 5)      { $cuotaMB = 10; $grupoStr = "Cuates"   }
        elseif ($num -ge 6 -and $num -le 10) { $cuotaMB = 5;  $grupoStr = "NoCuates" }
    }
    if ($null -eq $cuotaMB) {
        Write-Host "  ${BLUE}1)${NC} Cuates (10MB)  ${BLUE}2)${NC} NoCuates (5MB)"
        $opG = Read-Host "  Grupo del usuario"
        if ($opG -eq "1") { $cuotaMB = 10; $grupoStr = "Cuates" }
        else               { $cuotaMB = 5;  $grupoStr = "NoCuates" }
    }

    $letra     = "Z"
    $totalGlobal   = 0
    $pasaronGlobal = 0
    $primeraVez    = $true

    # Bucle: probar usuario actual y opcionalmente mas usuarios
    do {
        # Montar Z: directamente en la subcarpeta del usuario
        # Esto hace que Z: sea solo su carpeta y FSRM registre el uso correctamente
        $rutaShare = Mount-SharePerfiles `
            -ServidorIP      $servidorIP `
            -Usuario         "$env:USERDOMAIN\$usuarioAPROBAR" `
            -Password        $passwordPlain `
            -UsuarioACarpeta $usuarioAPROBAR `
            -Letra           $letra
        $passwordPlain = $null

        if ($null -eq $rutaShare) {
            aputs_error "No se pudo montar \\$servidorIP\Perfiles$\$usuarioAPROBAR"
            aputs_info  "  net use Z: \\$servidorIP\Perfiles$\$usuarioAPROBAR"
        } else {
            aputs_info "Z: montado en: \\$servidorIP\Perfiles$\$usuarioAPROBAR"
            aputs_info "Usuario: $usuarioAPROBAR | Grupo: $grupoStr | Cuota: $cuotaMB MB"

            # Z: ya ES la carpeta del usuario — las pruebas escriben en Z:\
            # Pasamos Z: como carpeta y cadena vacia como usuario para que
            # Invoke-PruebasUsuario construya la ruta como "Z:\"
            $res = Invoke-PruebasUsuario `
                -CarpetaBase "${letra}:" `
                -Usuario     "" `
                -CuotaMB     $cuotaMB `
                -Grupo       $grupoStr
            $totalGlobal   += $res.Total
            $pasaronGlobal += $res.Pasaron
        }

        Write-Host ""
        $otrasPruebas = Read-Host "  Probar otro usuario? (S/N)"
        if ($otrasPruebas.ToUpper() -eq "S") {
            $usuarioAPROBAR = (Read-Host "  Usuario a probar").Trim().ToLower()
            $cuotaMB  = $null; $grupoStr = $null
            $numMatch2 = [regex]::Match($usuarioAPROBAR, '\d+$')
            if ($numMatch2.Success) {
                $num2 = [int]$numMatch2.Value
                if ($num2 -ge 1 -and $num2 -le 5)      { $cuotaMB = 10; $grupoStr = "Cuates"   }
                elseif ($num2 -ge 6 -and $num2 -le 10) { $cuotaMB = 5;  $grupoStr = "NoCuates" }
            }
            if ($null -eq $cuotaMB) {
                Write-Host "  ${BLUE}1)${NC} Cuates (10MB)  ${BLUE}2)${NC} NoCuates (5MB)"
                $opG2 = Read-Host "  Grupo"
                if ($opG2 -eq "1") { $cuotaMB = 10; $grupoStr = "Cuates" }
                else                { $cuotaMB = 5;  $grupoStr = "NoCuates" }
            }
            $pass2 = Read-Host "  Password de $usuarioAPROBAR" -AsSecureString
            $passwordPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass2))
        }
    } while ($otrasPruebas.ToUpper() -eq "S")

    # Resumen final
    Write-Host ""
    draw_line
    $color = if ($pasaronGlobal -eq $totalGlobal) { $GREEN } else { $YELLOW }
    Write-Host "  ${color}Resultado global: $pasaronGlobal / $totalGlobal pruebas correctas${NC}"
    draw_line
    Write-Host ""
    aputs_success "Z: sigue montado en \\$servidorIP\Perfiles$\$usuarioAPROBAR"
    aputs_info    "Puedes ver los archivos en el Explorador en Z:\"
    aputs_info    "Los eventos FSRM quedan registrados en el servidor."
    aputs_info    "Para desmontar manualmente: net use Z: /delete"
}

# 
# PUNTO DE ENTRADA
# 
Clear-Host
Write-Host ""
Write-Host "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
Write-Host "${CYAN}║${NC}  Test-Cuotas.ps1 — Tarea 08 FSRM                     ${CYAN}║${NC}"
Write-Host "${CYAN}║${NC}  Prueba de Cuotas y File Screening                    ${CYAN}║${NC}"
Write-Host "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
Write-Host ""
Write-Host "  Equipo: $env:COMPUTERNAME"
Write-Host "  Usuario: $env:USERNAME"
Write-Host "  Fecha:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$esAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$esServidor = (Test-Path "C:\Perfiles") -and
              ((Get-ChildItem "C:\Perfiles" -Directory -ErrorAction SilentlyContinue).Count -gt 0)

if (-not $esAdmin -and $esServidor) {
    # Solo elevar si estamos en el servidor y no somos admin
    aputs_warning "Modo servidor requiere Administrador. Solicitando elevacion via UAC..."
    Start-Sleep -Seconds 1
    try {
        Start-Process PowerShell.exe `
            -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
            -Verb RunAs `
            -Wait
    } catch {
        Write-Host ""
        aputs_error "Elevacion cancelada o denegada."
        aputs_info  "Ejecute manualmente como Administrador en el servidor."
    }
    exit
}
# En modo CLIENTE corremos directamente como user01 sin elevar.
# user01 tiene FullControl sobre su carpeta en el share Perfiles$.

# Detectar entorno
$entorno = Get-Entorno

if ($entorno -eq "DESCONOCIDO") {
    Write-Host ""
    Write-Host "  No se pudo detectar el entorno automaticamente."
    Write-Host "  ${BLUE}1)${NC} Soy el SERVIDOR (acceso directo a C:\Perfiles)"
    Write-Host "  ${BLUE}2)${NC} Soy el CLIENTE Win10 (necesito montar el share)"
    Write-Host ""
    $op = Read-Host "  Opcion"
    $entorno = if ($op -eq "1") { "SERVIDOR" } else { "CLIENTE" }
}

Write-Host ""
aputs_info "Entorno detectado: $entorno"
Write-Host ""

switch ($entorno) {
    "SERVIDOR" { Invoke-FlujoDesdeServidor }
    "CLIENTE"  { Invoke-FlujoDesdeCliente  }
}

Write-Host ""
Read-Host "  Presiona Enter para salir..."