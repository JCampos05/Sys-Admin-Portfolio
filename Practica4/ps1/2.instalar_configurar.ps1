#
# Instala OpenSSH Server y realiza la configuración base en Windows Server
#
# Depende de: utils.psm1, validators_ssh.psm1
#
. "$scriptDir\validator_ssh.ps1"

function Invoke-InstalarConfigurarSSH {
    Clear-Host
    Draw-Header "Instalar y Configurar OpenSSH Server"

    if (-not (Test-AdminPrivileges)) { return }

    # Ruta del sshd_config en Windows (diferente a Linux)
    $sshdConfig = "$env:ProgramData\ssh\sshd_config"

    # ─── 1. Verificar si ya está instalado ───────────────────────────────
    Write-Info "1. Verificando instalacion previa..."
    Write-Host ""

    $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" -ErrorAction SilentlyContinue

    if ($cap -and $cap.State -eq 'Installed') {
        Write-Warn "OpenSSH Server ya esta instalado: $($cap.Name)"
        Write-Host ""
        $continuar = Read-Input "Desea continuar igualmente con la configuracion? (s/n)"
        if ($continuar -ne 's' -and $continuar -ne 'S') {
            Write-Info "Operacion cancelada"
            return
        }
    } else {
        Write-Info "OpenSSH Server no esta instalado. Instalando..."
        Write-Host ""

        # Add-WindowsCapability instala la feature opcional de OpenSSH
        try {
            Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" -ErrorAction Stop | Out-Null
            Write-Success "OpenSSH Server instalado correctamente"
        } catch {
            Write-Err "Error durante la instalacion: $($_.Exception.Message)"
            Write-Info "Verifique la conexion a internet y Windows Update"
            return
        }
    }

    Write-Host ""
    Draw-Line

    # ─── 2. Habilitar e iniciar el servicio ──────────────────────────────
    Write-Info "2. Configurando el servicio sshd..."
    Write-Host ""

    # Set-Service -StartupType Automatic: equivalente a 'systemctl enable' en Linux
    # Hace que el servicio arranque automáticamente con Windows
    Write-Info "Habilitando inicio automatico (Automatic)..."
    try {
        Set-Service -Name sshd -StartupType Automatic -ErrorAction Stop
        Write-Success "sshd configurado para inicio automatico"
    } catch {
        Write-Err "No se pudo configurar el inicio automatico: $($_.Exception.Message)"
        return
    }

    Write-Host ""

    # Start-Service: equivalente a 'systemctl start' en Linux
    Write-Info "Iniciando el servicio ahora..."
    try {
        Start-Service -Name sshd -ErrorAction Stop
        Start-Sleep -Seconds 2

        if (Test-ServiceRunning "sshd") {
            Write-Success "sshd iniciado correctamente"
        } else {
            Write-Err "sshd no arranco correctamente"
            return
        }
    } catch {
        Write-Err "Error al iniciar sshd: $($_.Exception.Message)"
        return
    }

    Draw-Line

    # ─── 3. Configuración base de sshd_config ────────────────────────────
    Write-Info "3. Aplicando configuracion base en sshd_config..."
    Write-Host ""

    # Verificar que el archivo existe (se crea al instalar OpenSSH)
    if (-not (Test-Path $sshdConfig)) {
        Write-Err "No se encontro sshd_config en: $sshdConfig"
        Write-Info "Intente reiniciar el servicio sshd y vuelva a intentar"
        return
    }

    # Crear backup antes de modificar
    $backup = "$sshdConfig.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item -Path $sshdConfig -Destination $backup -Force
    Write-Success "Backup creado: $backup"
    Write-Host ""

    # Solicitar el usuario que podrá conectarse
    $usuarioSSH = ""
    while ($true) {
        $usuarioSSH = Read-Input "Usuario de Windows para SSH (ej: Administrador)"
        if (Test-SSHUsuarioExiste $usuarioSSH) { break }
        Write-Host ""
    }

    Write-Host ""

    # Función interna: establece o agrega una directiva en sshd_config
    function Set-SshdParam {
        param(
            [string]$Directiva,
            [string]$Valor
        )

        $contenido = Get-Content $sshdConfig

        # Buscar si la directiva existe (activa o comentada)
        $encontrado = $false
        $nuevoContenido = $contenido | ForEach-Object {
            if ($_ -match "^#?\s*${Directiva}\s+") {
                $encontrado = $true
                "$Directiva $Valor"   # Reemplazar la línea completa
            } else {
                $_   # Mantener las demás líneas igual
            }
        }

        # Si no existía la directiva, agregarla al final
        if (-not $encontrado) {
            $nuevoContenido += "$Directiva $Valor"
        }

        # Reescribir el archivo (Set-Content equivale al > en redirección)
        $nuevoContenido | Set-Content -Path $sshdConfig -Encoding UTF8
    }

    Write-Info "Escribiendo parametros en sshd_config..."
    Write-Host ""

    # Puerto 22 — estándar SSH, requerido por la práctica
    Set-SshdParam "Port" "22"
    Write-Host "    Port                   -> 22"

    # Desactivar login directo como root/Administrador integrado
    Set-SshdParam "PermitRootLogin" "no"
    Write-Host "    PermitRootLogin        -> no"

    # Habilitar autenticación por clave pública
    Set-SshdParam "PubkeyAuthentication" "yes"
    Write-Host "    PubkeyAuthentication   -> yes"

    # Mantener contraseña activa 
    Set-SshdParam "PasswordAuthentication" "yes"
    Write-Host "    PasswordAuthentication -> yes"

    # No reenviar gráficos por SSH
    Set-SshdParam "X11Forwarding" "no"
    Write-Host "    X11Forwarding          -> no"

    # Mostrar último login al conectar
    Set-SshdParam "PrintLastLog" "yes"
    Write-Host "    PrintLastLog           -> yes"

    # AllowUsers: lista blanca de usuarios permitidos
    Set-SshdParam "AllowUsers" $usuarioSSH
    Write-Host "    AllowUsers             -> $usuarioSSH"

    if ($usuarioSSH -eq 'Administrador' -or $usuarioSSH -eq 'Administrator') {
        Set-SshdParam "AuthorizedKeysFile" "__PROGRAMDATA__/ssh/administrators_authorized_keys"
        Write-Host "    AuthorizedKeysFile     -> (ruta especial Administrador)"
    } else {
        Set-SshdParam "AuthorizedKeysFile" ".ssh/authorized_keys"
        Write-Host "    AuthorizedKeysFile     -> .ssh/authorized_keys"
    }

    Draw-Line

    # ─── 4. Reiniciar servicio para aplicar cambios ───────────────────────
    Write-Info "4. Reiniciando sshd para aplicar cambios..."
    Write-Host ""

    try {
        Restart-Service -Name sshd -Force -ErrorAction Stop
        Start-Sleep -Seconds 2

        if (Test-ServiceRunning "sshd") {
            Write-Success "sshd reiniciado y activo correctamente"

            $proc = Get-Process -Name "sshd" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($proc) { Write-Host "    Nuevo PID: $($proc.Id)" }
        } else {
            Write-Err "sshd no arranco tras el reinicio"
            return
        }
    } catch {
        Write-Err "Error al reiniciar sshd: $($_.Exception.Message)"
        return
    }

    Draw-Line
    Write-Host ""
    Write-Success "Instalacion y configuracion completado"
}