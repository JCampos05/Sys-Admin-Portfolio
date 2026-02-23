#
# Verifica el estado de instalación del servicio OpenSSH en Windows Server
#
# Depende de: utils.ps1
#

function Invoke-VerificarSSH {
    Clear-Host
    Draw-Header "Verificacion de Instalacion SSH"

    $errores      = 0
    $advertencias = 0

    # ─── 1. Windows Capability OpenSSH.Server ────────────────────────────
    # Get-WindowsCapability consulta si la feature está instalada.
    Write-Info "1. Verificando OpenSSH Server (Windows Capability)..."
    Write-Host ""

    try {
        $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" -ErrorAction Stop

        if ($cap.State -eq 'Installed') {
            Write-Success "OpenSSH Server: INSTALADO"
            Write-Host "    Version/Name : $($cap.Name)"
        } else {
            Write-Err "OpenSSH Server: NO instalado (estado: $($cap.State))"
            Write-Info "Vaya a la opcion 2) Instalar/Configurar SSH para instalarlo"
            $errores++
        }
    } catch {
        Write-Err "No se pudo consultar las Capabilities de Windows"
        Write-Host "    Detalle: $($_.Exception.Message)"
        $errores++
    }

    Draw-Line

    # ─── 2. Estado del servicio sshd ─────────────────────────────────────
    Write-Info "2. Estado del servicio sshd..."
    Write-Host ""

    if (Test-ServiceRunning "sshd") {
        Write-Success "Servicio sshd: ACTIVO (Running)"

        # Obtener información del proceso
        try {
            $svc = Get-Service -Name "sshd"
            Write-Host "    StartType    : $($svc.StartType)"

            # PID del proceso sshd
            $proc = Get-Process -Name "sshd" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($proc) {
                Write-Host "    PID          : $($proc.Id)"
                Write-Host "    Memoria      : $([math]::Round($proc.WorkingSet64/1MB, 2)) MB"
            }
        } catch {}

    } else {
        Write-Err "Servicio sshd: INACTIVO"
        $errores++
    }

    Write-Host ""

    # Inicio automático con el sistema
    if (Test-ServiceAutoStart "sshd") {
        Write-Success "Inicio automatico en boot: HABILITADO (Automatic)"
    } else {
        Write-Warn "Inicio automatico en boot: DESHABILITADO"
        Write-Info "El servicio no arrancara al reiniciar el servidor"
        $advertencias++
    }

    Draw-Line

    # ─── 3. Puerto en escucha ─────────────────────────────────────────────
    Write-Info "3. Verificando puerto en escucha..."
    Write-Host ""

    # Leer puerto configurado en sshd_config de Windows
    $sshdConfig = "$env:ProgramData\ssh\sshd_config"
    $puerto = 22

    if (Test-Path $sshdConfig) {
        $lineaPuerto = Select-String -Path $sshdConfig -Pattern "^Port\s+" | Select-Object -First 1
        if ($lineaPuerto) {
            $puerto = [int]($lineaPuerto.Line.Split()[1])
        }
    }

    Write-Info "Puerto configurado en sshd_config: $puerto"
    Write-Host ""

    if (Test-PuertoEscuchando $puerto) {
        Write-Success "Puerto ${puerto}/TCP: ESCUCHANDO"

        # Mostrar detalles de la conexión
        Get-NetTCPConnection -LocalPort $puerto -State Listen -ErrorAction SilentlyContinue |
            ForEach-Object {
                Write-Host "    Direccion local: $($_.LocalAddress):$($_.LocalPort)"
            }
    } else {
        Write-Err "Puerto ${puerto}/TCP: NO escuchando"
        Write-Info "El servicio puede estar caido o el puerto configurado difiere"
        $errores++
    }

    Draw-Line

    # ─── 4. Archivo de configuración ─────────────────────────────────────
    Write-Info "4. Archivo de configuracion..."
    Write-Host ""

    if (Test-Path $sshdConfig) {
        Write-Success "Archivo sshd_config: ENCONTRADO"
        Write-Host "    Ruta     : $sshdConfig"

        $info = Get-Item $sshdConfig
        Write-Host "    Tamanio  : $($info.Length) bytes"
        Write-Host "    Modificado: $($info.LastWriteTime)"
    } else {
        Write-Err "Archivo sshd_config NO encontrado en: $sshdConfig"
        Write-Info "Instale OpenSSH Server primero (opcion 2)"
        $errores++
    }

    Draw-Line

    # ─── 5. Firewall de Windows ───────────────────────────────────────────
    # En Windows el firewall se gestiona con Get-NetFirewallRule
    Write-Info "5. Verificando reglas de Firewall de Windows..."
    Write-Host ""

    $reglaSSH = Get-NetFirewallRule -DisplayName "*SSH*" -ErrorAction SilentlyContinue |
                Where-Object { $_.Enabled -eq 'True' } |
                Select-Object -First 1

    if ($reglaSSH) {
        Write-Success "Regla de firewall SSH: ENCONTRADA y HABILITADA"
        Write-Host "    Nombre   : $($reglaSSH.DisplayName)"
        Write-Host "    Direccion: $($reglaSSH.Direction)"
        Write-Host "    Accion   : $($reglaSSH.Action)"
    } else {
        Write-Warn "No se encontro regla de firewall habilitada para SSH"
        Write-Info "Vaya a la opcion 6) Firewall para configurarla"
        $advertencias++
    }

    Draw-Line

    # ─── 6. Resumen ───────────────────────────────────────────────────────
    Write-Info "Resumen de verificacion:"
    Write-Host ""

    if ($errores -eq 0 -and $advertencias -eq 0) {
        Write-Success "SSH completamente operativo y configurado"
    } elseif ($errores -eq 0) {
        Write-Warn "SSH operativo con $advertencias advertencia(s)"
    } else {
        Write-Err "SSH con $errores error(es) critico(s) y $advertencias advertencia(s)"
    }

    Write-Host ""
    Write-Host "  Errores criticos : $errores"
    Write-Host "  Advertencias     : $advertencias"
}