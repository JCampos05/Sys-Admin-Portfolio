#
# Aplica parámetros de seguridad al servidor SSH en Windows
#
# Depende de: utils.psm1, validators_ssh.psm1
#

function Invoke-HardeningSSH {
    Clear-Host
    Draw-Header "Hardening de Seguridad SSH"

    if (-not (Test-AdminPrivileges)) { return }

    $sshdConfig = "$env:ProgramData\ssh\sshd_config"

    if (-not (Test-Path $sshdConfig)) {
        Write-Err "No se encontro sshd_config en: $sshdConfig"
        Write-Info "Ejecute primero la opcion 2) Instalar/Configurar SSH"
        return
    }

    Write-Info "Este modulo refuerza la seguridad del servidor SSH."
    Write-Info "Cada parametro se explicara antes de solicitarlo."
    Write-Host ""

    # Backup antes de cualquier cambio
    $backup = "$sshdConfig.hardening_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item -Path $sshdConfig -Destination $backup -Force
    Write-Success "Backup creado: $backup"
    Draw-Line

    # Función interna para modificar directivas
    function Set-SshdParam {
        param([string]$Directiva, [string]$Valor)
        $contenido  = Get-Content $sshdConfig
        $encontrado = $false
        $nuevo = $contenido | ForEach-Object {
            if ($_ -match "^#?\s*${Directiva}\s+") {
                $encontrado = $true
                "$Directiva $Valor"
            } else { $_ }
        }
        if (-not $encontrado) { $nuevo += "$Directiva $Valor" }
        $nuevo | Set-Content -Path $sshdConfig -Encoding UTF8
    }

    # ─── PARÁMETRO 1: MaxAuthTries ────────────────────────────────────────
    Write-Info "MaxAuthTries: Numero maximo de intentos de autenticacion"
    Write-Info "Recomendado: 3  |  Rango valido: 1-10"
    Write-Host ""

    $maxAuth = ""
    while ($true) {
        $maxAuth = Read-Input "MaxAuthTries [3]"
        if ([string]::IsNullOrWhiteSpace($maxAuth)) { $maxAuth = "3" }
        if (Test-SSHMaxAuthTries $maxAuth) { break }
        Write-Host ""
    }

    Set-SshdParam "MaxAuthTries" $maxAuth
    Write-Success "MaxAuthTries configurado: $maxAuth"
    Draw-Line

    # ─── PARÁMETRO 2: LoginGraceTime ──────────────────────────────────────
    Write-Info "LoginGraceTime: Segundos disponibles para completar el login"
    Write-Info "Recomendado: 30  |  Rango valido: 10-300 segundos"
    Write-Host ""

    $graceTime = ""
    while ($true) {
        $graceTime = Read-Input "LoginGraceTime en segundos [30]"
        if ([string]::IsNullOrWhiteSpace($graceTime)) { $graceTime = "30" }
        if (Test-SSHLoginGraceTime $graceTime) { break }
        Write-Host ""
    }

    Set-SshdParam "LoginGraceTime" "${graceTime}s"
    Write-Success "LoginGraceTime configurado: ${graceTime}s"
    Draw-Line

    # ─── PARÁMETRO 3: MaxSessions ─────────────────────────────────────────
    Write-Info "MaxSessions: Sesiones SSH simultaneas maximas por conexion"
    Write-Info "Recomendado: 3  |  Rango valido: 1-20"
    Write-Host ""

    $maxSessions = ""
    while ($true) {
        $maxSessions = Read-Input "MaxSessions [3]"
        if ([string]::IsNullOrWhiteSpace($maxSessions)) { $maxSessions = "3" }
        if (Test-SSHMaxSessions $maxSessions) { break }
        Write-Host ""
    }

    Set-SshdParam "MaxSessions" $maxSessions
    Write-Success "MaxSessions configurado: $maxSessions"
    Draw-Line

    # ─── PARÁMETRO 4: PermitRootLogin ────────────────────────────────────
    # En Windows "root" equivale al "Administrador" integrado
    Write-Info "PermitRootLogin: Permitir login directo como Administrador"
    Write-Info "Recomendado: no (usar usuario normal con privilegios)"
    Write-Host ""
    Write-Host "    1) no               (recomendado)"
    Write-Host "    2) prohibit-password (solo con clave, nunca contrasena)"
    Write-Host "    3) yes              (no recomendado)"
    Write-Host ""

    $valorRoot = ""
    while ($true) {
        $opRoot = Read-Input "Seleccione opcion [1]"
        if ([string]::IsNullOrWhiteSpace($opRoot)) { $opRoot = "1" }
        switch ($opRoot) {
            "1" { $valorRoot = "no";                 break }
            "2" { $valorRoot = "prohibit-password";  break }
            "3" { $valorRoot = "yes"
                  Write-Warn "Permitir root/Administrador es un riesgo de seguridad"
                  break }
            default { Write-Err "Opcion invalida. Seleccione 1, 2 o 3"; continue }
        }
        break
    }

    Set-SshdParam "PermitRootLogin" $valorRoot
    Write-Success "PermitRootLogin configurado: $valorRoot"
    Draw-Line

    # ─── PARÁMETRO 5: PasswordAuthentication ─────────────────────────────
    Write-Info "PasswordAuthentication: Permitir autenticacion con contrasena"
    Write-Warn "Desactivar SOLO si ya tiene claves publicas configuradas (opcion 4)"
    Write-Host ""
    Write-Host "    1) yes  (contrasena permitida)"
    Write-Host "    2) no   (solo claves publicas)"
    Write-Host ""

    $valorPass = ""
    while ($true) {
        $opPass = Read-Input "Seleccione opcion [1]"
        if ([string]::IsNullOrWhiteSpace($opPass)) { $opPass = "1" }
        switch ($opPass) {
            "1" { $valorPass = "yes"; break }
            "2" { $valorPass = "no"
                  Write-Warn "Asegurese de tener claves publicas antes de reconectar"
                  break }
            default { Write-Err "Opcion invalida. Seleccione 1 o 2"; continue }
        }
        break
    }

    Set-SshdParam "PasswordAuthentication" $valorPass
    Write-Success "PasswordAuthentication configurado: $valorPass"
    Draw-Line

    # ─── PARÁMETRO 6: Banner ─────────────────────────────────────────────
    # En Windows el banner se guarda en un archivo de texto plano
    # y sshd_config apunta a él con la directiva Banner
    $bannerPath = "$env:ProgramData\ssh\banner_ssh.txt"

    Write-Info "Banner: Mensaje legal que se muestra antes del login"
    Write-Host ""
    Write-Host "    1) Banner predeterminado (aviso legal generico)"
    Write-Host "    2) Banner personalizado"
    Write-Host "    3) Sin banner"
    Write-Host ""

    $opBanner = Read-Input "Seleccione opcion [1]"
    if ([string]::IsNullOrWhiteSpace($opBanner)) { $opBanner = "1" }

    switch ($opBanner) {
        "1" {
            @"
┌─────────────────────────────────────────────────────────────────┐
|   Sistema de Acceso Restringido                                 |
|   Solo personal autorizado puede acceder a este sistema.        |
|   Todos los accesos son monitoreados y registrados.             |
|   El acceso no autorizado esta prohibido y sera reportado.      |
└─────────────────────────────────────────────────────────────────┘
"@ | Set-Content -Path $bannerPath -Encoding UTF8
            Set-SshdParam "Banner" $bannerPath
            Write-Success "Banner predeterminado creado en: $bannerPath"
        }
        "2" {
            $textoBanner = ""
            while ($true) {
                Write-Host ""
                $textoBanner = Read-Input "Escriba el texto del banner"
                if (Test-SSHBanner $textoBanner) { break }
                Write-Host ""
            }
            $textoBanner | Set-Content -Path $bannerPath -Encoding UTF8
            Set-SshdParam "Banner" $bannerPath
            Write-Success "Banner personalizado guardado"
        }
        "3" {
            Set-SshdParam "Banner" "none"
            Write-Info "Sin banner configurado"
        }
        default {
            Write-Warn "Opcion no reconocida. Se usara banner predeterminado"
        }
    }

    Draw-Line

    # ─── Reinicio del servicio ────────────────────────────────────────────
    Write-Warn "Se reiniciara sshd para aplicar el hardening"
    $confirmar = Read-Input "Confirma el reinicio? (s/n)"

    if ($confirmar -eq 's' -or $confirmar -eq 'S') {
        try {
            Restart-Service -Name sshd -Force -ErrorAction Stop
            Start-Sleep -Seconds 2

            if (Test-ServiceRunning "sshd") {
                Write-Success "sshd reiniciado correctamente con hardening aplicado"
            } else {
                Write-Err "sshd no arranco tras el reinicio"
                Write-Info "Revise el Visor de Eventos: eventvwr.msc"
                return
            }
        } catch {
            Write-Err "Error al reiniciar sshd: $($_.Exception.Message)"
            return
        }
    } else {
        Write-Info "Reinicio pospuesto. Recuerde reiniciar manualmente:"
        Write-Host "    Restart-Service -Name sshd"
    }

    Draw-Line
    Write-Host ""
    Write-Success "Hardening aplicado correctamente"
}