function Show-FtpStatus {
    Write-Separator
    msg_info "Estado del servicio FTP:"
    $svc = Get-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    if ($null -eq $svc) { msg_error "Servicio FTPSVC no encontrado"; return }

    Write-Host "  Estado      : $($svc.Status)"
    Write-Host "  Inicio      : $($svc.StartType)"

    Write-Separator
    msg_info "Puertos en escucha:"
    $listening = netstat -an | Select-String ":21\s"
    if ($listening) { $listening | ForEach-Object { Write-Host "  $_" } }
    else { msg_alert "Puerto 21 no detectado en escucha" }

    Write-Separator
    msg_info "Conexiones activas:"
    $conns = netstat -an | Select-String ":21\s.*ESTABLISHED"
    if ($conns) { $conns | ForEach-Object { Write-Host "  $_" } }
    else { msg_info "Sin conexiones activas" }

    Write-Separator
    msg_info "Log reciente:"
    $logDir = "$env:SystemDrive\inetpub\logs\LogFiles"
    $logFile = Get-ChildItem "$logDir\FTPSVC*\*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($logFile) {
        Get-Content $logFile.FullName -Tail 20
    } else {
        msg_alert "No se encontro archivo de log FTP"
    }

    Write-Separator
    Show-FtpUsers
}

function Start-FtpService {
    msg_process "Iniciando FTPSVC..."
    try {
        Start-Service -Name "FTPSVC" -ErrorAction Stop
        msg_success "Servicio FTP iniciado"
    } catch {
        msg_error "No se pudo iniciar el servicio: $_"
    }
}

function Stop-FtpService {
    if (-not (Confirm-Action "Confirma detener el servicio FTP")) { return }
    try {
        Stop-Service -Name "FTPSVC" -Force -ErrorAction Stop
        msg_success "Servicio FTP detenido"
    } catch {
        msg_error "No se pudo detener el servicio: $_"
    }
}

function Restart-FtpService {
    msg_process "Reiniciando FTPSVC..."
    try {
        Restart-Service -Name "FTPSVC" -Force -ErrorAction Stop
        msg_success "Servicio FTP reiniciado"
    } catch {
        msg_error "No se pudo reiniciar el servicio: $_"
    }
}

function Toggle-FtpAutoStart {
    $svc = Get-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    if ($null -eq $svc) { msg_error "Servicio FTPSVC no encontrado"; return }

    if ($svc.StartType -eq "Automatic") {
        Set-Service -Name "FTPSVC" -StartupType Manual
        msg_success "Arranque automatico deshabilitado (Manual)"
    } else {
        Set-Service -Name "FTPSVC" -StartupType Automatic
        msg_success "Arranque automatico habilitado"
    }
}

function Menu-Servicio {
    $salir = $false
    while (-not $salir) {
        Clear-Host
        Draw-Header "Control del Servicio FTP"
        Write-Host "  1) Ver estado del servicio y logs recientes"
        Write-Host "  2) Iniciar servicio FTP"
        Write-Host "  3) Detener servicio FTP"
        Write-Host "  4) Reiniciar servicio FTP"
        Write-Host "  5) Alternar arranque automatico"
        Write-Host "  6) Volver al menu principal"
        Write-Host ""

        $op = Read-MenuInput "Opcion"
        switch ($op) {
            "1" {
                Show-FtpStatus
                Pause-Menu
            }
            "2" {
                Start-FtpService
                Pause-Menu
            }
            "3" {
                Stop-FtpService
                Pause-Menu
            }
            "4" {
                Restart-FtpService
                Pause-Menu
            }
            "5" {
                Toggle-FtpAutoStart
                Pause-Menu
            }
            "6" { $salir = $true }
            default {
                msg_error "Opcion invalida. Seleccione del 1 al 6"
                Start-Sleep -Seconds 2
            }
        }
    }
}