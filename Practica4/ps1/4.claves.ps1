#
# Generación y despliegue de claves SSH en Windows Server
#
# Depende de: utils.psm1, validators_ssh.psm1
#

# ─── 1. Generar par de claves ─────────────────────────────────────────────────
function Invoke-GenerarClaves {
    Clear-Host
    Draw-Header "Generar Par de Claves SSH"

    Write-Host ""
    Write-Info "Se generara un par de claves criptograficas:"
    Write-Info "  - Clave PRIVADA: permanece en este equipo"
    Write-Info "  - Clave PUBLICA: se copia al cliente o servidor destino"
    Write-Host ""

    # Verificar que ssh-keygen está disponible
    # En Windows, viene con OpenSSH instalado
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
        Write-Err "ssh-keygen no esta disponible"
        Write-Info "Instale OpenSSH primero con la opcion 2)"
        return
    }

    $sshDir = "$env:USERPROFILE\.ssh"
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        Write-Success "Directorio .ssh creado en: $sshDir"
    }

    Draw-Line

    # ─ Tipo de clave ─────────────────────────────────────────────────────
    Write-Info "Tipo de clave criptografica:"
    Write-Host ""
    Write-Host "    1) ed25519  (recomendado: moderno, rapido y muy seguro)"
    Write-Host "    2) rsa      (compatible con sistemas mas antiguos)"
    Write-Host "    3) ecdsa    (curva eliptica, buen balance)"
    Write-Host ""

    $tipoClave = ""
    while ($true) {
        $opTipo = Read-Input "Tipo de clave [1]"
        if ([string]::IsNullOrWhiteSpace($opTipo)) { $opTipo = "1" }

        switch ($opTipo) {
            "1" { $tipoClave = "ed25519" }
            "2" { $tipoClave = "rsa"     }
            "3" { $tipoClave = "ecdsa"   }
            default { $tipoClave = $opTipo }
        }

        if (Test-SSHIp $tipoClave -eq $null -and (Test-SSHNombreUsuario $tipoClave -eq $null)) {}
        # Usamos el validator de tipo
        if ($tipoClave -match '^(ed25519|rsa|ecdsa)$') { break }
        else {
            Write-Err "Tipo invalido. Seleccione 1, 2 o 3"
            Write-Host ""
        }
    }

    Write-Host ""

    # ─ Bits para RSA ──────────────────────────────────────────────────────
    $bitsArg = ""
    if ($tipoClave -eq "rsa") {
        Write-Info "Numero de bits para RSA:"
        Write-Host "    1) 2048  (minimo aceptable)"
        Write-Host "    2) 3072  (recomendado)"
        Write-Host "    3) 4096  (maxima seguridad)"
        Write-Host ""

        $bitsValor = ""
        while ($true) {
            $opBits = Read-Input "Seleccione opcion [2]"
            if ([string]::IsNullOrWhiteSpace($opBits)) { $opBits = "2" }

            switch ($opBits) {
                "1" { $bitsValor = "2048" }
                "2" { $bitsValor = "3072" }
                "3" { $bitsValor = "4096" }
                default { $bitsValor = $opBits }
            }

            # Importar validator aquí para DSA/bits
            if ($bitsValor -match '^(2048|3072|4096)$') {
                $bitsArg = "-b $bitsValor"
                break
            } else {
                Write-Err "Valor no valido. Use 2048, 3072 o 4096"
                Write-Host ""
            }
        }
        Write-Host ""
    }

    # ─ Ruta del archivo ───────────────────────────────────────────────────
    $rutaDefecto = "$sshDir\id_$tipoClave"
    Write-Info "Ruta del archivo de clave:"
    Write-Info "Predeterminada: $rutaDefecto"
    Write-Host ""

    $rutaClave = Read-Input "Ruta del archivo [Enter = predeterminado]"
    if ([string]::IsNullOrWhiteSpace($rutaClave)) { $rutaClave = $rutaDefecto }

    Write-Host ""

    # Advertir si ya existe
    if (Test-Path $rutaClave) {
        Write-Warn "Ya existe una clave en: $rutaClave"
        $sobrescribir = Read-Input "Sobrescribir? (s/n)"
        if ($sobrescribir -ne 's' -and $sobrescribir -ne 'S') {
            Write-Info "Operacion cancelada"
            return
        }
    }

    Write-Host ""

    # Generar la clave
    # El comentario -C identifica la clave (quien la generó y cuándo)
    $comentario = "$env:USERNAME@$env:COMPUTERNAME`_$(Get-Date -Format 'yyyyMMdd')"
    $comando    = "ssh-keygen -t $tipoClave $bitsArg -f `"$rutaClave`" -C `"$comentario`""

    Write-Info "Generando clave..."
    Write-Host ""

    Invoke-Expression $comando

    if (Test-Path "$rutaClave.pub") {
        Write-Host ""
        Write-Success "Par de claves generado correctamente"
        Write-Host ""
        Write-Host "  Clave privada : $rutaClave"
        Write-Host "  Clave publica : $rutaClave.pub"
        Write-Host ""
        Write-Info "Clave publica generada:"
        Get-Content "$rutaClave.pub"
        Write-Host ""
        Write-Info "Copie esta clave publica al cliente Linux con la opcion 2)"
    } else {
        Write-Err "No se genero el archivo de clave publica"
    }
}

# ─── 2. Agregar clave pública autorizada ──────────────────────────────────────
# En Windows, la ruta del authorized_keys depende del usuario:
#   - Administrador → C:\ProgramData\ssh\administrators_authorized_keys
#   - Otros usuarios → C:\Users\<usuario>\.ssh\authorized_keys
function Invoke-AgregarClave {
    Clear-Host
    Draw-Header "Agregar Clave Publica Autorizada"

    Write-Host ""
    Write-Info "Esta opcion agrega una clave publica al servidor Windows"
    Write-Info "para que un cliente Linux pueda conectarse sin contrasena."
    Write-Host ""

    # Usuario destino
    $usuario = ""
    while ($true) {
        $usuario = Read-Input "Usuario de Windows donde agregar la clave"
        if (Test-SSHUsuarioExiste $usuario) { break }
        Write-Host ""
    }

    Write-Host ""

    # Determinar ruta correcta según el usuario
    if ($usuario -eq 'Administrador' -or $usuario -eq 'Administrator') {
        # Ruta especial para el Administrador en Windows OpenSSH
        $authKeys = "$env:ProgramData\ssh\administrators_authorized_keys"
        $authDir  = "$env:ProgramData\ssh"
    } else {
        $perfilUsuario = "C:\Users\$usuario"
        $authDir  = "$perfilUsuario\.ssh"
        $authKeys = "$authDir\authorized_keys"
    }

    # Crear directorio si no existe
    if (-not (Test-Path $authDir)) {
        New-Item -ItemType Directory -Path $authDir -Force | Out-Null
        Write-Success "Directorio creado: $authDir"
    }

    Write-Host ""
    Write-Info "Pegue el contenido completo de la clave publica (.pub):"
    Write-Info "Formato esperado: ssh-ed25519 AAAA... usuario@equipo"
    Write-Host ""

    $clavePublica = Read-Input "Clave publica"

    if ([string]::IsNullOrWhiteSpace($clavePublica)) {
        Write-Err "No se ingreso ninguna clave"
        return
    }

    # Validar formato básico de clave SSH
    if ($clavePublica -notmatch '^(ssh-|ecdsa-)') {
        Write-Err "El formato no parece una clave SSH valida"
        Write-Info "La clave debe comenzar con: ssh-rsa, ssh-ed25519 o ecdsa-sha2-nistp256"
        return
    }

    Write-Host ""
    Draw-Line

    # Verificar duplicado
    if ((Test-Path $authKeys) -and (Select-String -Path $authKeys -SimpleMatch $clavePublica -Quiet)) {
        Write-Warn "Esta clave ya existe en authorized_keys"
        return
    }

    # Agregar la clave
    Add-Content -Path $authKeys -Value $clavePublica -Encoding UTF8

    Write-Info "Aplicando permisos correctos al archivo authorized_keys..."

    # Quitar herencia de permisos
    icacls $authKeys /inheritance:r | Out-Null
    # Solo SYSTEM y Administradores tienen acceso
    icacls $authKeys /grant "SYSTEM:(F)" | Out-Null
    icacls $authKeys /grant "Administradores:(F)" | Out-Null

    Write-Success "Clave publica agregada: $authKeys"
    Write-Host ""
    Write-Info "El cliente Linux puede ahora conectarse con:"
    Write-Host "    ssh $usuario@192.168.100.20"
}

# ─── 3. Ver claves autorizadas ────────────────────────────────────────────────
function Invoke-VerAutorizadas {
    Clear-Host
    Draw-Header "Claves Autorizadas en este Servidor"

    Write-Host ""

    # Verificar ambas rutas posibles
    $rutasVerificar = @(
        "$env:ProgramData\ssh\administrators_authorized_keys",
        "$env:USERPROFILE\.ssh\authorized_keys"
    )

    foreach ($ruta in $rutasVerificar) {
        if (Test-Path $ruta) {
            Write-Info "Archivo: $ruta"
            Write-Host ""

            $lineas = Get-Content $ruta | Where-Object { $_ -notmatch '^\s*$' }
            $total  = ($lineas | Measure-Object).Count

            Write-Success "$total clave(s) autorizada(s)"
            Write-Host ""

            $i = 1
            foreach ($linea in $lineas) {
                $partes     = $linea.Split(' ')
                $tipo       = $partes[0]
                $comentario = if ($partes.Count -ge 3) { $partes[2] } else { "(sin comentario)" }

                Write-Host "  $i) Tipo : $tipo"
                Write-Host "     ID   : $comentario"
                $i++
            }
        } else {
            Write-Warn "No existe: $ruta"
        }
        Write-Host ""
    }
}

function Invoke-GestionarClavesSSH {
    if (-not (Test-AdminPrivileges)) { return }

    $salir = $false
    while (-not $salir) {
        Clear-Host
        Draw-Header "Gestion de Claves SSH"
        Write-Host ""
        Write-Info "1) Generar nuevo par de claves (privada + publica)"
        Write-Info "2) Agregar clave publica autorizada a este servidor"
        Write-Info "3) Ver claves autorizadas en este servidor"
        Write-Info "4) Volver al menu principal"
        Write-Host ""

        $op = Read-Input "Opcion"

        switch ($op) {
            "1" { Invoke-GenerarClaves   ; Pause-Menu }
            "2" { Invoke-AgregarClave    ; Pause-Menu }
            "3" { Invoke-VerAutorizadas  ; Pause-Menu }
            "4" { $salir = $true }
            default { Write-Err "Opcion invalida" ; Start-Sleep -Seconds 1 }
        }
    }
}