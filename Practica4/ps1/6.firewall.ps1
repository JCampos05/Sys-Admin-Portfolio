#
# Gestión del Firewall de Windows para el servicio SSH
#
# Depende de: utils.psm1, validators_ssh.psm1
#
# Nota: En Windows se usa el Firewall de Windows (netsh / New-NetFirewallRule)
#

# ─── 1. Ver estado actual del firewall ───────────────────────────────────────
function _Ver-EstadoFirewall {
    Clear-Host
    Draw-Header "Estado del Firewall de Windows"

    Write-Host ""

    # Perfiles de firewall: Domain, Private, Public
    # Get-NetFirewallProfile devuelve el estado de cada perfil
    Write-Info "Estado por perfil:"
    Write-Host ""

    Get-NetFirewallProfile | ForEach-Object {
        $estado = if ($_.Enabled) { "ACTIVO" } else { "INACTIVO" }
        $color  = if ($_.Enabled) { "Green"  } else { "Red"     }
        Write-Host "  $($_.Name.PadRight(10)) : " -NoNewline
        Write-Host $estado -ForegroundColor $color
    }

    Write-Host ""
    Draw-Line

    # Reglas relacionadas con SSH
    Write-Info "Reglas de firewall para SSH:"
    Write-Host ""

    $reglasSSH = Get-NetFirewallRule -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match 'SSH|OpenSSH' }

    if ($reglasSSH) {
        foreach ($regla in $reglasSSH) {
            $habilitada = if ($regla.Enabled -eq 'True') { "[ACTIVA]" } else { "[INACTIVA]" }
            $colorHab   = if ($regla.Enabled -eq 'True') { "Green" } else { "Yellow" }

            Write-Host "  " -NoNewline
            Write-Host $habilitada -ForegroundColor $colorHab -NoNewline
            Write-Host " $($regla.DisplayName)"
            Write-Host "    Direccion : $($regla.Direction)"
            Write-Host "    Accion    : $($regla.Action)"

            # Obtener puertos de la regla
            $portFilter = $regla | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            if ($portFilter) {
                Write-Host "    Puerto    : $($portFilter.LocalPort)/$($portFilter.Protocol)"
            }
            Write-Host ""
        }
    } else {
        Write-Warn "No se encontraron reglas de firewall para SSH"
        Write-Info "Use la opcion 2) para crear la regla del puerto 22"
    }

    Draw-Line

    # Estado específico del puerto 22
    Write-Info "Verificacion directa del puerto 22:"
    Write-Host ""

    if (Test-PuertoEscuchando 22) {
        Write-Success "Puerto 22/TCP: ESCUCHANDO"
    } else {
        Write-Warn "Puerto 22/TCP: No escuchando (servicio sshd puede estar inactivo)"
    }
}

# ─── 2. Permitir SSH estándar (puerto 22) ────────────────────────────────────
function _Permitir-SSHEstandar {
    Clear-Host
    Draw-Header "Permitir SSH en el Firewall"

    Write-Host ""
    Write-Info "Se creara una regla para permitir conexiones entrantes en el puerto 22/TCP"
    Write-Host ""

    # Verificar si ya existe una regla para SSH
    $reglaExiste = Get-NetFirewallRule -DisplayName "OpenSSH-SSH" -ErrorAction SilentlyContinue
    if ($reglaExiste -and $reglaExiste.Enabled -eq 'True') {
        Write-Success "La regla 'OpenSSH-SSH' ya existe y esta habilitada"
        return
    }

    $confirmar = Read-Input "Confirma agregar regla SSH al firewall? (s/n)"
    if ($confirmar -ne 's' -and $confirmar -ne 'S') {
        Write-Info "Operacion cancelada"
        return
    }

    Write-Host ""

    try {
        # New-NetFirewallRule crea una nueva regla en el Firewall
        New-NetFirewallRule `
            -Name          "OpenSSH-SSH-In-TCP" `
            -DisplayName   "OpenSSH-SSH" `
            -Description   "Permite conexiones SSH entrantes en el puerto 22" `
            -Enabled       True `
            -Direction     Inbound `
            -Protocol      TCP `
            -LocalPort     22 `
            -Action        Allow `
            -ErrorAction   Stop | Out-Null

        Write-Success "Regla de firewall creada correctamente"
        Write-Host ""
        Write-Host "  Nombre       : OpenSSH-SSH"
        Write-Host "  Puerto       : 22/TCP"
        Write-Host "  Direccion    : Entrante (Inbound)"
        Write-Host "  Accion       : Permitir (Allow)"

    } catch {
        # Si ya existe con ese nombre, solo habilitarla
        if ($_.Exception.Message -match 'already exists') {
            Write-Warn "La regla ya existe. Habilitandola..."
            Enable-NetFirewallRule -Name "OpenSSH-SSH-In-TCP" -ErrorAction SilentlyContinue
            Write-Success "Regla habilitada"
        } else {
            Write-Err "Error al crear la regla: $($_.Exception.Message)"
            return
        }
    }

    Write-Host ""
    Write-Success "Puerto 22/TCP habilitado para conexiones SSH entrantes"
}

# ─── 3. Permitir puerto personalizado ────────────────────────────────────────
function _Permitir-PuertoCustom {
    Clear-Host
    Draw-Header "Permitir Puerto Personalizado"

    Write-Host ""
    Write-Info "Ingrese el puerto que desea abrir para SSH"
    Write-Host ""

    $puerto = ""
    while ($true) {
        $puerto = Read-Input "Numero de puerto"
        if (Test-SSHPuerto $puerto) { break }
        Write-Host ""
    }

    $p = [int]$puerto
    Write-Host ""

    # Verificar si ya existe una regla para ese puerto
    $reglaExiste = Get-NetFirewallRule -ErrorAction SilentlyContinue |
                    Where-Object { $_ | Get-NetFirewallPortFilter | Where-Object { $_.LocalPort -eq $p } }

    if ($reglaExiste) {
        Write-Warn "Ya existe una regla para el puerto $p"
        return
    }

    $confirmar = Read-Input "Abrir puerto ${p}/TCP en el firewall? (s/n)"
    if ($confirmar -ne 's' -and $confirmar -ne 'S') {
        Write-Info "Operacion cancelada"
        return
    }

    Write-Host ""

    try {
        New-NetFirewallRule `
            -Name          "SSH-Custom-Port-$p" `
            -DisplayName   "SSH Puerto $p" `
            -Description   "Permite conexiones SSH entrantes en el puerto $p" `
            -Enabled       True `
            -Direction     Inbound `
            -Protocol      TCP `
            -LocalPort     $p `
            -Action        Allow `
            -ErrorAction   Stop | Out-Null

        Write-Success "Regla creada: puerto ${p}/TCP habilitado"

    } catch {
        Write-Err "Error al crear la regla: $($_.Exception.Message)"
    }
}

# ─── 4. Bloquear puerto SSH ───────────────────────────────────────────────────
function _Bloquear-PuertoSSH {
    Clear-Host
    Draw-Header "Bloquear Puerto SSH"

    Write-Host ""
    Write-Warn "ATENCION: Bloquear SSH cortara las conexiones remotas activas"
    Write-Warn "Solo haga esto si tiene acceso fisico o consola al servidor"
    Write-Host ""

    $puerto = ""
    while ($true) {
        $puerto = Read-Input "Puerto SSH a bloquear [22]"
        if ([string]::IsNullOrWhiteSpace($puerto)) { $puerto = "22" }
        if (Test-SSHPuerto $puerto) { break }
        Write-Host ""
    }

    Write-Host ""
    $confirmar = Read-Input "Escriba 'CONFIRMAR' para bloquear el puerto $puerto"
    if ($confirmar -ne 'CONFIRMAR') {
        Write-Info "Operacion cancelada"
        return
    }

    Write-Host ""
    $p = [int]$puerto

    # Deshabilitar reglas existentes para ese puerto
    # Disable-NetFirewallRule deshabilita sin eliminar (reversible)
    $reglas = Get-NetFirewallRule -ErrorAction SilentlyContinue |
                Where-Object {
                    ($_.DisplayName -match 'SSH|OpenSSH') -and ($_.Enabled -eq 'True')
                }

    if ($reglas) {
        foreach ($regla in $reglas) {
            Disable-NetFirewallRule -Name $regla.Name -ErrorAction SilentlyContinue
            Write-Success "Regla deshabilitada: $($regla.DisplayName)"
        }
    } else {
        Write-Info "No se encontraron reglas SSH habilitadas"
    }

    Write-Host ""
    Write-Success "Puerto SSH bloqueado en el firewall"
    Write-Info "Para rehabilitar use la opcion 2) de este menu"
}

function Invoke-GestionarFirewallSSH {
    if (-not (Test-AdminPrivileges)) { return }

    $salir = $false
    while (-not $salir) {
        Clear-Host
        Draw-Header "Configuracion Firewall SSH - Windows"
        Write-Host ""
        Write-Info "1) Ver estado actual del firewall"
        Write-Info "2) Permitir SSH en el firewall (puerto 22)"
        Write-Info "3) Permitir puerto personalizado"
        Write-Info "4) Bloquear puerto SSH"
        Write-Info "5) Volver al menu principal"
        Write-Host ""

        $op = Read-Input "Opcion"

        switch ($op) {
            "1" { _Ver-EstadoFirewall      ; Pause-Menu }
            "2" { _Permitir-SSHEstandar    ; Pause-Menu }
            "3" { _Permitir-PuertoCustom   ; Pause-Menu }
            "4" { _Bloquear-PuertoSSH      ; Pause-Menu }
            "5" { $salir = $true }
            default { Write-Err "Opcion invalida" ; Start-Sleep -Seconds 1 }
        }
    }
}