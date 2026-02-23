#
# 5.monitor_ssh.ps1
# Monitoreo del servicio SSH en Windows: estado, conexiones y logs
#
# Depende de: utils.psm1, validators_ssh.psm1
#

function Invoke-MonitorSSH {
    Clear-Host

    if (-not (Test-AdminPrivileges)) { return }

    $sshdConfig = "$env:ProgramData\ssh\sshd_config"

    # Leer puerto configurado
    $puerto = 22
    if (Test-Path $sshdConfig) {
        $lineaPuerto = Select-String -Path $sshdConfig -Pattern "^Port\s+" | Select-Object -First 1
        if ($lineaPuerto) { $puerto = [int]($lineaPuerto.Line.Split()[1]) }
    }

    _Mostrar-EstadoServicio -Puerto $puerto
    _Mostrar-ConexionesActivas -Puerto $puerto
    _Mostrar-ConfigActiva -SshdConfig $sshdConfig

    Write-Host ""
    Draw-Line
    $verLogs = Read-Input "Ver logs detallados del servicio? (s/n)"
    if ($verLogs -eq 's' -or $verLogs -eq 'S') {
        _Mostrar-Logs
    }

    Write-Host ""
    Draw-Line
    Write-Info "Monitor actualizado: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
}

# ─── Estado del servicio ──────────────────────────────────────────────────────
function _Mostrar-EstadoServicio {
    param([int]$Puerto)

    Draw-Header "Estado del Servicio SSH"

    if (Test-ServiceRunning "sshd") {
        Write-Success "Estado: ACTIVO (Running)"
        Write-Host ""

        $svc  = Get-Service -Name "sshd"
        $proc = Get-Process -Name "sshd" -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($proc) {
            Write-Host "  PID del proceso : $($proc.Id)"
            Write-Host "  Memoria         : $([math]::Round($proc.WorkingSet64/1MB, 2)) MB"
            Write-Host "  CPU (s totales) : $([math]::Round($proc.TotalProcessorTime.TotalSeconds, 2))s"
            Write-Host "  Iniciado a las  : $($proc.StartTime)"
        }

        Write-Host "  StartType       : $($svc.StartType)"

        if (Test-ServiceAutoStart "sshd") {
            Write-Host "  Inicio en boot  : HABILITADO (Automatic)"
        } else {
            Write-Warn "  Inicio en boot  : DESHABILITADO"
        }

    } else {
        Write-Err "Estado: INACTIVO"
        Write-Host ""
        Write-Info "Inicie el servicio con: Start-Service -Name sshd"
    }

    Write-Host ""
    Write-Info "Puerto en escucha:"
    Write-Host ""

    if (Test-PuertoEscuchando $Puerto) {
        Write-Success "  Puerto ${Puerto}/TCP - Escuchando"

        Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue |
            ForEach-Object {
                Write-Host "       Direccion: $($_.LocalAddress):$($_.LocalPort)"
            }
    } else {
        Write-Host "  [--] Puerto ${Puerto}/TCP - No escuchando"
    }
}

# ─── Conexiones activas ───────────────────────────────────────────────────────
function _Mostrar-ConexionesActivas {
    param([int]$Puerto)

    Draw-Header "Conexiones SSH Activas"

    # Get-NetTCPConnection muestra conexiones TCP establecidas
    $conexiones = Get-NetTCPConnection -LocalPort $Puerto -State Established -ErrorAction SilentlyContinue

    if ($conexiones) {
        $total = ($conexiones | Measure-Object).Count
        Write-Info "Conexiones establecidas: $total"
        Write-Host ""

        Write-Host ("  {0,-15} {1,-25} {2,-25}" -f "ESTADO", "LOCAL", "REMOTO")
        Write-Host "────────────────────────────────────────────────────────────────"

        foreach ($c in $conexiones) {
            Write-Host ("  {0,-15} {1,-25} {2,-25}" -f `
                $c.State,
                "$($c.LocalAddress):$($c.LocalPort)",
                "$($c.RemoteAddress):$($c.RemotePort)")
        }
    } else {
        Write-Info "No hay conexiones SSH activas en este momento"
    }

    Write-Host ""

    Write-Info "Sesiones de usuario en el sistema:"
    Write-Host ""
    try {
        $sesiones = query user 2>$null
        if ($sesiones) {
            $sesiones | ForEach-Object { Write-Host "  $_" }
        } else {
            Write-Info "No se encontraron sesiones activas"
        }
    } catch {
        Write-Warn "No se pudo consultar las sesiones activas"
    }
}

# ─── Configuración activa ─────────────────────────────────────────────────────
function _Mostrar-ConfigActiva {
    param([string]$SshdConfig)

    Draw-Header "Configuracion Activa de sshd_config"

    if (-not (Test-Path $SshdConfig)) {
        Write-Err "No se encontro sshd_config en: $SshdConfig"
        return
    }

    Write-Info "Parametros de seguridad relevantes:"
    Write-Host ""

    $parametros = @(
        "Port", "PermitRootLogin", "PasswordAuthentication",
        "PubkeyAuthentication", "MaxAuthTries", "LoginGraceTime",
        "MaxSessions", "X11Forwarding", "AllowUsers", "Banner"
    )

    foreach ($param in $parametros) {
        $linea = Select-String -Path $SshdConfig -Pattern "^${param}\s+" | Select-Object -First 1
        if ($linea) {
            $valor = ($linea.Line -split '\s+', 2)[1]
            Write-Host ("  {0,-28} -> {1}" -f $param, $valor)
        } else {
            Write-Host ("  {0,-28} -> (predeterminado del sistema)" -f $param)
        }
    }
}

# ─── Logs del servicio ────────────────────────────────────────────────────────
# En Windows, los logs de SSH se encuentran en el Visor de Eventos (Event Log)
# bajo "OpenSSH" o en el archivo de log configurado en sshd_config
function _Mostrar-Logs {
    Clear-Host
    Draw-Header "Logs del Servicio SSH"

    Write-Host ""
    Write-Info "Cuantas lineas de log desea ver?"
    Write-Info "Rango valido: 10 a 500"
    Write-Host ""

    $lineas = ""
    while ($true) {
        $lineas = Read-Input "Numero de lineas [50]"
        if ([string]::IsNullOrWhiteSpace($lineas)) { $lineas = "50" }
        if (Test-SSHLineasLog $lineas) { break }
        Write-Host ""
    }

    $n = [int]$lineas

    Write-Host ""
    Draw-Line
    Write-Info "Ultimos $n eventos de OpenSSH en el Visor de Eventos:"
    Draw-Line
    Write-Host ""

    try {
        # Get-WinEvent lee el registro de eventos de Windows
        # Los eventos de OpenSSH se registran bajo "OpenSSH/Operational"
        $eventos = Get-WinEvent -LogName 'OpenSSH/Operational' `
                                -MaxEvents $n `
                                -ErrorAction Stop

        foreach ($ev in $eventos) {
            $nivel = switch ($ev.Level) {
                1 { "CRITICO" }
                2 { "ERROR  " }
                3 { "WARN   " }
                4 { "INFO   " }
                default { "DEBUG  " }
            }
            Write-Host "  [$nivel] $($ev.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))  $($ev.Message.Split("`n")[0])"
        }
    } catch {
        # Si el log de OpenSSH no está disponible, intentar con el log de Aplicación
        Write-Warn "Log 'OpenSSH/Operational' no disponible. Buscando en System..."
        Write-Host ""

        try {
            Get-WinEvent -LogName 'System' -MaxEvents $n -ErrorAction Stop |
                Where-Object { $_.ProviderName -like '*ssh*' } |
                ForEach-Object {
                    Write-Host "  $($_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))  $($_.Message.Split("`n")[0])"
                }
        } catch {
            Write-Warn "No se encontraron eventos SSH en el registro del sistema"
            Write-Info "Habilite el log con: eventcreate /L OpenSSH/Operational"
        }
    }

    Write-Host ""
    Draw-Line

    # Resumen de eventos de seguridad
    Write-Info "Resumen de seguridad (ultimas 24 horas):"
    Write-Host ""

    try {
        $desde = (Get-Date).AddHours(-24)

        $fallidos = (Get-WinEvent -LogName 'OpenSSH/Operational' `
            -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.TimeCreated -gt $desde -and
                        $_.Message -match 'Failed|Invalid'
                    } | Measure-Object).Count

        $exitosos = (Get-WinEvent -LogName 'OpenSSH/Operational' `
            -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.TimeCreated -gt $desde -and
                        $_.Message -match 'Accepted'
                    } | Measure-Object).Count

        Write-Host "  Intentos fallidos   : $fallidos"
        Write-Host "  Logins exitosos     : $exitosos"

        if ($fallidos -gt 10) {
            Write-Host ""
            Write-Warn "Alto numero de intentos fallidos. Revise las reglas de firewall"
        }
    } catch {
        Write-Warn "No se pudieron calcular estadisticas de seguridad"
    }
}