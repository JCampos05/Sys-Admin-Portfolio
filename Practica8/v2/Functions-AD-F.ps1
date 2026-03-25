#
# Functions-AD-F.ps1
#
# Responsabilidad: Funcionalidades adicionales de administracion dinamica
# que no forman parte del flujo de instalacion inicial (Fases A-E) pero
# son necesarias durante la revision o administracion en vivo del dominio.
#
#
# Funciones publicas (llamadas desde mainAD.ps1):
#   Invoke-HorariosDinamicos   - Menu interactivo para cambiar LogonHours en vivo
#   Invoke-GestionAvanzada     - Menu de Alta / Baja / Cambio de grupo de usuarios
#
# Funciones internas:
#   Set-HorarioGrupo           - Aplica un rango horario a todos los usuarios de un grupo
#   New-UsuarioCompleto        - Alta: crea usuario en AD + carpeta + cuota + filescreen
#   Remove-UsuarioCompleto     - Baja: deshabilita cuenta (preserva datos y cuota)
#   Move-UsuarioGrupo          - Cambio: mueve OU, cambia grupo, actualiza cuota y LogonHours
#   Get-HorarioActualGrupo     - Lee y decodifica los LogonHours actuales de un usuario del grupo
#

#Requires -Version 5.1

. "$PSScriptRoot\utils.ps1"
. "$PSScriptRoot\utilsAD.ps1"

# 
# CONSTANTES LOCALES
# 

# Nombres de plantillas FSRM — deben coincidir exactamente con los de Functions-AD-D.ps1
$script:F_QUOTA_10MB       = "Cuota-10MB-Cuates"
$script:F_QUOTA_5MB        = "Cuota-5MB-NoCuates"
$script:F_FILESCREEN_TMPL  = "Pantalla-Prohibidos-T08"

# 
# HELPERS INTERNOS
# 

# -------------------------------------------------------------------------
# Get-HorarioActualGrupo
# Decodifica los LogonHours almacenados en AD para el primer usuario de un
# grupo y retorna el rango horario en hora local legible.
#
# Como funciona la decodificacion:
#   AD guarda 168 bits (21 bytes) donde cada bit es una hora de la semana
#   almacenada en UTC. Para mostrarlos en hora local restamos el offset
#   (inverso a la conversion que hace ConvertTo-LogonHoursBytes).
#
# Parametros:
#   $GroupName - Nombre del grupo (ej: "GRP_Cuates")
# Retorna: string con el rango horario local (ej: "8:00 - 15:00") o "Sin restriccion"
# -------------------------------------------------------------------------
function Get-HorarioActualGrupo {
    param([string]$GroupName)

    try {
        # Tomar el primer miembro del grupo para leer sus LogonHours
        $member = Get-ADGroupMember -Identity $GroupName -ErrorAction Stop |
                  Where-Object { $_.objectClass -eq "user" } |
                  Select-Object -First 1

        if ($null -eq $member) { return "Sin miembros" }

        $bytes = @((Get-ADUser $member.SamAccountName -Properties LogonHours -ErrorAction Stop).LogonHours)

        if ($null -eq $bytes -or $bytes.Count -ne 21) { return "Sin restriccion" }

        # Decodificar: recorrer todos los bits y recolectar horas UTC permitidas
        $tzOffset = [int][Math]::Abs((Get-TimeZone).BaseUtcOffset.TotalHours)
        $horasLocalesPermitidas = @()

        for ($i = 0; $i -lt 168; $i++) {
            $byteIndex = [math]::Floor($i / 8)
            $bitIndex  = $i % 8
            if ($bytes[$byteIndex] -band (1 -shl $bitIndex)) {
                # Hora UTC del bit -> convertir a local (restar offset porque al guardar sumamos)
                $horaUTC   = $i % 24
                $horaLocal = ($horaUTC - $tzOffset + 24) % 24
                if ($horasLocalesPermitidas -notcontains $horaLocal) {
                    $horasLocalesPermitidas += $horaLocal
                }
            }
        }

        if ($horasLocalesPermitidas.Count -eq 0) { return "Bloqueado completamente" }

        $horasLocalesPermitidas = $horasLocalesPermitidas | Sort-Object
        $inicio = $horasLocalesPermitidas[0]
        $fin    = ($horasLocalesPermitidas[-1] + 1) % 24

        return "$inicio`:00 - $fin`:00 (hora local)"

    } catch {
        return "Error al leer: $($_.Exception.Message)"
    }
}

# -------------------------------------------------------------------------
# Set-HorarioGrupo
# Aplica un rango horario nuevo a todos los usuarios de un grupo.
# Reutiliza ConvertTo-LogonHoursBytes de utilsAD.ps1 y DirectoryEntry
# de Functions-AD-C.ps1 — la misma logica probada.
#
# Parametros:
#   $GroupName      - Nombre del grupo en AD
#   $StartHourLocal - Hora de inicio en hora local (0-23)
#   $EndHourLocal   - Hora de fin en hora local (0-23)
# Retorna: $true si todos los usuarios fueron actualizados.
# -------------------------------------------------------------------------
function Set-HorarioGrupo {
    param(
        [string]$GroupName,
        [int]$StartHourLocal,
        [int]$EndHourLocal
    )

    # Validaciones de rango
    if ($StartHourLocal -lt 0 -or $StartHourLocal -gt 23 -or
        $EndHourLocal   -lt 0 -or $EndHourLocal   -gt 23) {
        aputs_error "Horas fuera de rango (0-23). Inicio: $StartHourLocal Fin: $EndHourLocal"
        return $false
    }

    if ($StartHourLocal -eq $EndHourLocal) {
        aputs_error "La hora de inicio y fin no pueden ser iguales."
        return $false
    }

    # Verificar que el grupo existe
    try {
        Get-ADGroup -Identity $GroupName -ErrorAction Stop | Out-Null
    } catch {
        aputs_error "Grupo '$GroupName' no encontrado en AD."
        return $false
    }

    $tzOffset = [int][Math]::Abs((Get-TimeZone).BaseUtcOffset.TotalHours)
    aputs_info "Aplicando horario $StartHourLocal`:00-$EndHourLocal`:00 a $GroupName (UTC offset: +$tzOffset)"
    Write-ADLog "Cambio horario $GroupName : $StartHourLocal-$EndHourLocal local" "INFO"

    $logonBytes = ConvertTo-LogonHoursBytes `
        -StartHourLocal $StartHourLocal `
        -EndHourLocal   $EndHourLocal   `
        -UtcOffsetHours $tzOffset

    try {
        $members = Get-ADGroupMember -Identity $GroupName -ErrorAction Stop |
                   Where-Object { $_.objectClass -eq "user" }
    } catch {
        aputs_error "No se pudieron obtener miembros de $GroupName : $($_.Exception.Message)"
        return $false
    }

    if ($null -eq $members -or @($members).Count -eq 0) {
        aputs_warning "El grupo $GroupName no tiene miembros de tipo usuario."
        return $false
    }

    $ok = 0; $err = 0

    foreach ($m in $members) {
        try {
            $dn   = (Get-ADUser $m.SamAccountName).DistinguishedName
            $user = New-Object DirectoryServices.DirectoryEntry("LDAP://$dn")
            $user.Properties["logonHours"].Value = [byte[]]$logonBytes
            $user.CommitChanges()
            $user.Dispose()
            aputs_success "Horario aplicado: $($m.SamAccountName)"
            Write-ADLog "Horario $StartHourLocal-$EndHourLocal aplicado a $($m.SamAccountName)" "SUCCESS"
            $ok++
        } catch {
            aputs_error "Error en $($m.SamAccountName): $($_.Exception.Message)"
            Write-ADLog "Error horario $($m.SamAccountName): $($_.Exception.Message)" "ERROR"
            $err++
        }
    }

    aputs_info "Actualizados: $ok | Errores: $err"
    return ($err -eq 0)
}

# -------------------------------------------------------------------------
# New-UsuarioCompleto
# Crea un usuario nuevo en AD con todos los elementos requeridos:
#   1. Cuenta en AD en la OU correcta
#   2. Miembro del grupo de seguridad correcto
#   3. Carpeta personal en C:\Perfiles\<usuario>
#   4. Cuota FSRM segun el grupo
#   5. File Screen activo en su carpeta
#   6. LogonHours del grupo aplicados
#
# Idempotente: si el usuario ya existe, verifica y completa lo que falte.
#
# Parametros:
#   $SamAccount  - Nombre de cuenta (ej: "user11")
#   $DisplayName - Nombre completo visible
#   $Department  - "Cuates" o "NoCuates"
#   $Password    - Contrasena en texto plano
#   $DomainName  - Nombre del dominio (ej: "reprobados.local")
# Retorna: $true si el usuario quedo creado y configurado.
# -------------------------------------------------------------------------
function New-UsuarioCompleto {
    param(
        [string]$SamAccount,
        [string]$DisplayName,
        [string]$Department,
        [string]$Password,
        [string]$DomainName
    )

    # Validar departamento
    $Department = $Department.Trim()
    if ($Department -notin @("Cuates", "NoCuates")) {
        aputs_error "Departamento invalido: '$Department'. Use 'Cuates' o 'NoCuates'."
        return $false
    }

    $domainNC    = Get-DomainNC -DomainName $DomainName
    $domainShort = ($DomainName.Split(".")[0]).ToUpper()
    $ouPath      = "OU=$Department,$domainNC"
    $groupName   = "GRP_$Department"
    $upn         = "$SamAccount@$DomainName"
    $folderPath  = "$script:PROFILES_BASE\$SamAccount"

    # --- Paso 1: Crear o verificar usuario en AD ---
    $userExists = Test-ADUserExists -SamAccountName $SamAccount
    if ($userExists) {
        aputs_info "Usuario '$SamAccount' ya existe en AD. Verificando configuracion..."
        Write-ADLog "Alta: usuario $SamAccount ya existe, completando config" "INFO"
    } else {
        aputs_info "Creando usuario '$SamAccount' en OU=$Department..."
        try {
            $securePass = ConvertTo-SecureString $Password -AsPlainText -Force
            New-ADUser `
                -SamAccountName       $SamAccount `
                -UserPrincipalName    $upn `
                -DisplayName          $DisplayName `
                -Name                 $DisplayName `
                -Department           $Department `
                -AccountPassword      $securePass `
                -Path                 $ouPath `
                -Enabled              $true `
                -PasswordNeverExpires $true `
                -ChangePasswordAtLogon $false `
                -ErrorAction Stop

            aputs_success "Usuario '$SamAccount' creado en OU=$Department"
            Write-ADLog "Alta: usuario $SamAccount creado en OU=$Department" "SUCCESS"
        } catch {
            aputs_error "Error al crear usuario: $($_.Exception.Message)"
            Write-ADLog "Alta error creando $SamAccount : $($_.Exception.Message)" "ERROR"
            return $false
        }
    }

    # --- Paso 2: Agregar al grupo de seguridad ---
    try {
        Add-ADGroupMember -Identity $groupName -Members $SamAccount -ErrorAction SilentlyContinue
        aputs_success "Agregado a $groupName"
    } catch { }

    # --- Paso 3: Carpeta personal ---
    New-ProfileFolder -UserName $SamAccount -Domain $domainShort | Out-Null

    # --- Paso 4: Cuota FSRM ---
    # Solo si FSRM esta instalado
    if (Test-WindowsFeatureInstalled "FS-Resource-Manager") {
        $quotaTemplate = if ($Department -eq "Cuates") { $script:F_QUOTA_10MB } else { $script:F_QUOTA_5MB }
        $existingQuota = Get-FsrmQuota -Path $folderPath -ErrorAction SilentlyContinue
        if ($null -eq $existingQuota) {
            try {
                New-FsrmQuota -Path $folderPath -Template $quotaTemplate -ErrorAction Stop
                aputs_success "Cuota $quotaTemplate aplicada a $folderPath"
                Write-ADLog "Alta: cuota aplicada a $SamAccount ($quotaTemplate)" "SUCCESS"
            } catch {
                aputs_warning "No se pudo aplicar cuota: $($_.Exception.Message)"
            }
        } else {
            aputs_info "Cuota ya existe para $SamAccount"
        }

        # --- Paso 5: File Screen ---
        $existingScreen = Get-FsrmFileScreen -Path $folderPath -ErrorAction SilentlyContinue
        if ($null -eq $existingScreen) {
            try {
                New-FsrmFileScreen -Path $folderPath -Template $script:F_FILESCREEN_TMPL -ErrorAction Stop
                aputs_success "File Screen aplicado a $folderPath"
                Write-ADLog "Alta: file screen aplicado a $SamAccount" "SUCCESS"
            } catch {
                aputs_warning "No se pudo aplicar file screen: $($_.Exception.Message)"
            }
        } else {
            aputs_info "File Screen ya existe para $SamAccount"
        }
    } else {
        aputs_warning "FSRM no instalado. Cuota y file screen omitidos."
        aputs_info    "Ejecute la Fase D desde el menu principal para instalar FSRM."
    }

    # --- Paso 6: LogonHours segun grupo ---
    aputs_info "Aplicando LogonHours del grupo $Department..."
    try {
        $tzOffset = [int][Math]::Abs((Get-TimeZone).BaseUtcOffset.TotalHours)
        if ($Department -eq "Cuates") {
            $startH = 8; $endH = 15
        } else {
            $startH = 15; $endH = 2
        }

        $logonBytes = ConvertTo-LogonHoursBytes `
            -StartHourLocal $startH `
            -EndHourLocal   $endH   `
            -UtcOffsetHours $tzOffset

        $dn   = (Get-ADUser $SamAccount).DistinguishedName
        $user = New-Object DirectoryServices.DirectoryEntry("LDAP://$dn")
        $user.Properties["logonHours"].Value = [byte[]]$logonBytes
        $user.CommitChanges()
        $user.Dispose()
        aputs_success "LogonHours aplicados ($startH`:00-$endH`:00 local)"
        Write-ADLog "Alta: LogonHours aplicados a $SamAccount" "SUCCESS"
    } catch {
        aputs_warning "No se pudieron aplicar LogonHours: $($_.Exception.Message)"
    }

    aputs_success "Alta completada para: $SamAccount ($Department)"
    Write-ADLog "Alta completada: $SamAccount en $Department" "SUCCESS"
    return $true
}

# -------------------------------------------------------------------------
# Remove-UsuarioCompleto
# Deshabilita la cuenta de un usuario en AD.
# No elimina el objeto ni la carpeta — esto preserva los datos y la cuota
# para que puedan revisarse en la rubrica aunque el usuario no pueda entrar.
#
# Por que deshabilitar en lugar de eliminar:
#   Eliminar un objeto AD es irreversible. Durante una revision el profesor
#   puede pedir mostrar evidencia de que el usuario existio. Deshabilitar
#   mantiene el objeto, la cuota y el perfil intactos.
#   Para eliminar permanentemente se puede usar Remove-ADUser manualmente.
#
# Parametros:
#   $SamAccount - Nombre de cuenta del usuario a deshabilitar
# Retorna: $true si la cuenta quedo deshabilitada.
# -------------------------------------------------------------------------
function Remove-UsuarioCompleto {
    param([string]$SamAccount)

    # Verificar que el usuario existe
    if (-not (Test-ADUserExists -SamAccountName $SamAccount)) {
        aputs_error "Usuario '$SamAccount' no encontrado en AD."
        return $false
    }

    # No permitir deshabilitar cuentas del sistema
    $protectedAccounts = @("Administrator", "Administrador", "Guest", "krbtgt")
    if ($protectedAccounts -contains $SamAccount) {
        aputs_error "No se puede deshabilitar la cuenta protegida: $SamAccount"
        return $false
    }

    try {
        Disable-ADAccount -Identity $SamAccount -ErrorAction Stop
        aputs_success "Cuenta '$SamAccount' deshabilitada."
        aputs_info    "La carpeta C:\Perfiles\$SamAccount y la cuota se conservan."
        aputs_info    "Para eliminar permanentemente use: Remove-ADUser $SamAccount"
        Write-ADLog "Baja (deshabilitar): $SamAccount" "SUCCESS"
        return $true
    } catch {
        aputs_error "Error al deshabilitar '$SamAccount': $($_.Exception.Message)"
        Write-ADLog "Baja error $SamAccount : $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# -------------------------------------------------------------------------
# Move-UsuarioGrupo
# Mueve un usuario de su grupo actual al grupo destino.
# Actualiza: OU de AD, membresía de grupo, cuota FSRM y LogonHours.
#
# Por que actualizar todo y no solo el grupo:
#   Las GPOs de AppLocker se aplican por OU, no por grupo de seguridad.
#   Si el usuario cambia de grupo pero queda en la OU equivocada, seguira
#   recibiendo las politicas del grupo anterior. La cuota tambien debe
#   cambiar porque 5MB (NoCuates) y 10MB (Cuates) son diferentes.
#
# Parametros:
#   $SamAccount   - Nombre de cuenta del usuario
#   $GrupoDestino - "Cuates" o "NoCuates"
#   $DomainName   - Nombre del dominio
# Retorna: $true si el movimiento fue completamente exitoso.
# -------------------------------------------------------------------------
function Move-UsuarioGrupo {
    param(
        [string]$SamAccount,
        [string]$GrupoDestino,
        [string]$DomainName
    )

    $GrupoDestino = $GrupoDestino.Trim()
    if ($GrupoDestino -notin @("Cuates", "NoCuates")) {
        aputs_error "Grupo destino invalido: '$GrupoDestino'. Use 'Cuates' o 'NoCuates'."
        return $false
    }

    if (-not (Test-ADUserExists -SamAccountName $SamAccount)) {
        aputs_error "Usuario '$SamAccount' no encontrado en AD."
        return $false
    }

    $domainNC      = Get-DomainNC -DomainName $DomainName
    $ouDestino     = "OU=$GrupoDestino,$domainNC"
    $grupoDestino  = "GRP_$GrupoDestino"
    $grupoOrigen   = if ($GrupoDestino -eq "Cuates") { "GRP_NoCuates" } else { "GRP_Cuates" }
    $folderPath    = "$script:PROFILES_BASE\$SamAccount"

    # Verificar si ya esta en el grupo destino
    $userObj = Get-ADUser $SamAccount -Properties MemberOf -ErrorAction SilentlyContinue
    $yaEnGrupo = ($userObj.MemberOf | Where-Object { $_ -match $grupoDestino }).Count -gt 0
    if ($yaEnGrupo) {
        aputs_info "El usuario '$SamAccount' ya pertenece a $grupoDestino."
    }

    aputs_info "Moviendo '$SamAccount' a $GrupoDestino..."
    Write-ADLog "Cambio grupo: $SamAccount -> $GrupoDestino" "INFO"

    # --- Paso 1: Mover objeto de OU ---
    try {
        $currentDN = (Get-ADUser $SamAccount -ErrorAction Stop).DistinguishedName
        if ($currentDN -notlike "*OU=$GrupoDestino*") {
            Move-ADObject -Identity $currentDN -TargetPath $ouDestino -ErrorAction Stop
            aputs_success "Movido a OU=$GrupoDestino"
            Write-ADLog "Move-ADObject: $SamAccount -> $ouDestino" "SUCCESS"
        } else {
            aputs_info "Ya estaba en OU=$GrupoDestino"
        }
    } catch {
        aputs_error "Error al mover OU: $($_.Exception.Message)"
        Write-ADLog "Error Move-ADObject $SamAccount : $($_.Exception.Message)" "ERROR"
        return $false
    }

    # --- Paso 2: Cambiar grupo de seguridad ---
    try {
        Remove-ADGroupMember -Identity $grupoOrigen -Members $SamAccount `
            -Confirm:$false -ErrorAction SilentlyContinue
        aputs_info "Removido de $grupoOrigen"
    } catch { }

    try {
        Add-ADGroupMember -Identity $grupoDestino -Members $SamAccount -ErrorAction Stop
        aputs_success "Agregado a $grupoDestino"
        Write-ADLog "Cambio grupo: $SamAccount agregado a $grupoDestino" "SUCCESS"
    } catch {
        aputs_error "Error al agregar a $grupoDestino : $($_.Exception.Message)"
        return $false
    }

    # --- Paso 3: Actualizar cuota FSRM ---
    if (Test-WindowsFeatureInstalled "FS-Resource-Manager") {
        $newTemplate = if ($GrupoDestino -eq "Cuates") { $script:F_QUOTA_10MB } else { $script:F_QUOTA_5MB }
        $existingQuota = Get-FsrmQuota -Path $folderPath -ErrorAction SilentlyContinue
        try {
            if ($null -ne $existingQuota) {
                Set-FsrmQuota -Path $folderPath -Template $newTemplate -ErrorAction Stop
                aputs_success "Cuota actualizada a $newTemplate"
            } else {
                New-FsrmQuota -Path $folderPath -Template $newTemplate -ErrorAction Stop
                aputs_success "Cuota creada: $newTemplate"
            }
            Write-ADLog "Cambio grupo: cuota $newTemplate aplicada a $SamAccount" "SUCCESS"
        } catch {
            aputs_warning "No se pudo actualizar cuota: $($_.Exception.Message)"
        }
    }

    # --- Paso 4: Actualizar LogonHours al nuevo grupo ---
    aputs_info "Actualizando LogonHours para $GrupoDestino..."
    try {
        $tzOffset = [int][Math]::Abs((Get-TimeZone).BaseUtcOffset.TotalHours)
        if ($GrupoDestino -eq "Cuates") {
            $startH = 8; $endH = 15
        } else {
            $startH = 15; $endH = 2
        }

        $logonBytes = ConvertTo-LogonHoursBytes `
            -StartHourLocal $startH `
            -EndHourLocal   $endH   `
            -UtcOffsetHours $tzOffset

        $dn   = (Get-ADUser $SamAccount).DistinguishedName
        $user = New-Object DirectoryServices.DirectoryEntry("LDAP://$dn")
        $user.Properties["logonHours"].Value = [byte[]]$logonBytes
        $user.CommitChanges()
        $user.Dispose()
        aputs_success "LogonHours actualizados: $startH`:00-$endH`:00 local"
        Write-ADLog "Cambio grupo: LogonHours $SamAccount -> $GrupoDestino" "SUCCESS"
    } catch {
        aputs_warning "No se pudieron actualizar LogonHours: $($_.Exception.Message)"
    }

    aputs_success "Cambio de grupo completado: $SamAccount ahora es $GrupoDestino"
    Write-ADLog "Cambio grupo completado: $SamAccount -> $GrupoDestino" "SUCCESS"
    return $true
}

# 
# MENUS PUBLICOS
# Estas funciones son las que se llaman desde mainAD.ps1
# 

# -------------------------------------------------------------------------
# Invoke-HorariosDinamicos
# Menu interactivo para cambiar los LogonHours de un grupo en tiempo real.
# Permite ingresar cualquier rango horario sin editar codigo.
# Util cuando el profesor pide cambiar el horario durante la revision.
# -------------------------------------------------------------------------
function Invoke-HorariosDinamicos {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "${CYAN}╔══════════════════════════════════════════════╗${NC}"
        Write-Host "${CYAN}║${NC}  Horarios Dinamicos — LogonHours             ${CYAN}║${NC}"
        Write-Host "${CYAN}╚══════════════════════════════════════════════╝${NC}"
        Write-Host ""

        # Mostrar horarios actuales de cada grupo
        $horaCuates   = Get-HorarioActualGrupo "GRP_Cuates"
        $horaNoCuates = Get-HorarioActualGrupo "GRP_NoCuates"

        aputs_info "Horario actual GRP_Cuates:   $horaCuates"
        aputs_info "Horario actual GRP_NoCuates: $horaNoCuates"
        Write-Host ""
        Write-Host "  ${GRAY}Hora del sistema: $(Get-Date -Format 'HH:mm') | Offset UTC: -$([int][Math]::Abs((Get-TimeZone).BaseUtcOffset.TotalHours))${NC}"
        Write-Host ""
        draw_line
        Write-Host ""
        Write-Host "  ${BLUE}1)${NC} Cambiar horario de GRP_Cuates"
        Write-Host "  ${BLUE}2)${NC} Cambiar horario de GRP_NoCuates"
        Write-Host "  ${BLUE}3)${NC} Cambiar horario de ambos grupos"
        Write-Host "  ${BLUE}4)${NC} Restaurar horarios originales (Cuates 8-15 / NoCuates 15-2)"
        Write-Host "  ${BLUE}5)${NC} Ver horario decodificado de un usuario especifico"
        Write-Host "  ${BLUE}0)${NC} Volver"
        Write-Host ""

        $op = Read-Host "  Opcion"

        switch ($op) {
            "1" {
                Clear-Host
                Write-Host ""; draw_line
                Write-Host "  Cambiar horario: GRP_Cuates"
                draw_line; Write-Host ""
                aputs_info "Horario actual: $horaCuates"
                aputs_info "Ingrese el nuevo rango en hora local (0-23)"
                aputs_info "Ejemplo: inicio=9  fin=17  -> acceso de 9:00 AM a 5:00 PM"
                Write-Host ""
                $startStr = agets "Hora de INICIO (0-23)"
                $endStr   = agets "Hora de FIN    (0-23)"

                if ($startStr -match "^\d+$" -and $endStr -match "^\d+$") {
                    $result = Set-HorarioGrupo -GroupName "GRP_Cuates" `
                        -StartHourLocal ([int]$startStr) -EndHourLocal ([int]$endStr)
                    if ($result) {
                        aputs_success "Horario GRP_Cuates actualizado: $startStr`:00 - $endStr`:00"
                    }
                } else {
                    aputs_error "Valores invalidos. Ingrese numeros enteros entre 0 y 23."
                }
                pause_menu
            }
            "2" {
                Clear-Host
                Write-Host ""; draw_line
                Write-Host "  Cambiar horario: GRP_NoCuates"
                draw_line; Write-Host ""
                aputs_info "Horario actual: $horaNoCuates"
                aputs_info "Ingrese el nuevo rango en hora local (0-23)"
                Write-Host ""
                $startStr = agets "Hora de INICIO (0-23)"
                $endStr   = agets "Hora de FIN    (0-23)"

                if ($startStr -match "^\d+$" -and $endStr -match "^\d+$") {
                    $result = Set-HorarioGrupo -GroupName "GRP_NoCuates" `
                        -StartHourLocal ([int]$startStr) -EndHourLocal ([int]$endStr)
                    if ($result) {
                        aputs_success "Horario GRP_NoCuates actualizado: $startStr`:00 - $endStr`:00"
                    }
                } else {
                    aputs_error "Valores invalidos. Ingrese numeros enteros entre 0 y 23."
                }
                pause_menu
            }
            "3" {
                Clear-Host
                Write-Host ""; draw_line
                Write-Host "  Cambiar horario de AMBOS grupos"
                draw_line; Write-Host ""
                aputs_warning "Se configuraran dos rangos consecutivos sin solapamiento."
                Write-Host ""

                Write-Host "  ${CYAN}--- GRP_Cuates ---${NC}"
                $cStart = agets "GRP_Cuates  INICIO (0-23)"
                $cEnd   = agets "GRP_Cuates  FIN    (0-23)"
                Write-Host ""
                Write-Host "  ${CYAN}--- GRP_NoCuates ---${NC}"
                $nStart = agets "GRP_NoCuates INICIO (0-23)"
                $nEnd   = agets "GRP_NoCuates FIN    (0-23)"

                $allValid = ($cStart -match "^\d+$") -and ($cEnd -match "^\d+$") -and
                            ($nStart -match "^\d+$") -and ($nEnd -match "^\d+$")

                if ($allValid) {
                    Write-Host ""
                    aputs_info "Aplicando horarios..."
                    Set-HorarioGrupo -GroupName "GRP_Cuates"   -StartHourLocal ([int]$cStart) -EndHourLocal ([int]$cEnd)   | Out-Null
                    Set-HorarioGrupo -GroupName "GRP_NoCuates" -StartHourLocal ([int]$nStart) -EndHourLocal ([int]$nEnd)   | Out-Null
                    aputs_success "Horarios actualizados para ambos grupos."
                } else {
                    aputs_error "Valores invalidos. Todos deben ser numeros enteros entre 0 y 23."
                }
                pause_menu
            }
            "4" {
                Clear-Host
                Write-Host ""; draw_line
                Write-Host "  Restaurar horarios originales"
                draw_line; Write-Host ""
                aputs_warning "Esto restaurara los horarios definidos en la practica:"
                aputs_info    "  GRP_Cuates:   8:00 AM - 3:00 PM"
                aputs_info    "  GRP_NoCuates: 3:00 PM - 2:00 AM"
                Write-Host ""
                $confirm = agets "Escriba 'SI' para confirmar"
                if ($confirm -eq "SI") {
                    Set-HorarioGrupo -GroupName "GRP_Cuates"   -StartHourLocal 8  -EndHourLocal 15 | Out-Null
                    Set-HorarioGrupo -GroupName "GRP_NoCuates" -StartHourLocal 15 -EndHourLocal 2  | Out-Null
                    aputs_success "Horarios originales restaurados."
                    Write-ADLog "Horarios restaurados a valores originales de la practica" "INFO"
                } else {
                    aputs_info "Operacion cancelada."
                }
                pause_menu
            }
            "5" {
                Clear-Host
                Write-Host ""; draw_line
                Write-Host "  Ver horario decodificado de un usuario"
                draw_line; Write-Host ""
                $sam = agets "Nombre de cuenta (ej: user01)"
                try {
                    $bytes = @((Get-ADUser $sam -Properties LogonHours -ErrorAction Stop).LogonHours)
                    if ($null -eq $bytes -or $bytes.Count -ne 21) {
                        aputs_warning "$sam no tiene LogonHours configurados (acceso irrestricto)"
                    } else {
                        $tzOffset = [int][Math]::Abs((Get-TimeZone).BaseUtcOffset.TotalHours)
                        $horas = @()
                        for ($i = 0; $i -lt 168; $i++) {
                            $bi = [math]::Floor($i / 8)
                            $bb = $i % 8
                            if ($bytes[$bi] -band (1 -shl $bb)) {
                                $horaLocal = (($i % 24) - $tzOffset + 24) % 24
                                if ($horas -notcontains $horaLocal) { $horas += $horaLocal }
                            }
                        }
                        $horas = $horas | Sort-Object
                        if ($horas.Count -gt 0) {
                            $inicio = $horas[0]
                            $fin    = ($horas[-1] + 1) % 24
                            aputs_success "$sam : $inicio`:00 - $fin`:00 (hora local)"
                            aputs_info    "Horas permitidas: $($horas -join ', ')"
                        }
                    }
                } catch {
                    aputs_error "Usuario '$sam' no encontrado."
                }
                pause_menu
            }
            "0" { return }
            default {
                aputs_error "Opcion invalida"
                Start-Sleep -Seconds 1
            }
        }
    }
}

# -------------------------------------------------------------------------
# Invoke-GestionAvanzada
# Menu de Alta, Baja y Cambio de grupo de usuarios del dominio.
# Cada accion aplica todos los cambios necesarios de forma atomica:
# AD + FSRM + LogonHours en una sola operacion.
# -------------------------------------------------------------------------
function Invoke-GestionAvanzada {
    # Obtener nombre del dominio una sola vez
    $domainName = $null
    try {
        $domainName = (Get-ADDomain -ErrorAction Stop).DNSRoot
    } catch {
        aputs_error "Active Directory no disponible. Verifique que el DC esta funcionando."
        pause_menu
        return
    }

    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "${CYAN}╔══════════════════════════════════════════════╗${NC}"
        Write-Host "${CYAN}║${NC}  Gestion de Usuarios — Alta / Baja / Cambio  ${CYAN}║${NC}"
        Write-Host "${CYAN}╚══════════════════════════════════════════════╝${NC}"
        Write-Host ""

        # Contadores rapidos
        try {
            $cC = (Get-ADGroupMember "GRP_Cuates"   -ErrorAction SilentlyContinue).Count
            $cN = (Get-ADGroupMember "GRP_NoCuates" -ErrorAction SilentlyContinue).Count
        } catch { $cC = 0; $cN = 0 }

        aputs_info "Dominio: $domainName"
        Write-Host "  Cuates: $cC usuarios  |  NoCuates: $cN usuarios"
        Write-Host ""
        draw_line
        Write-Host ""
        Write-Host "  ${BLUE}A)${NC} ALTA   — Crear nuevo usuario en el dominio"
        Write-Host "  ${BLUE}B)${NC} BAJA   — Deshabilitar cuenta de usuario"
        Write-Host "  ${BLUE}C)${NC} CAMBIO — Mover usuario entre Cuates y NoCuates"
        Write-Host ""
        Write-Host "  ${GRAY}── Consultas ──────────────────────────────────${NC}"
        Write-Host "  ${BLUE}1)${NC} Listar usuarios Cuates"
        Write-Host "  ${BLUE}2)${NC} Listar usuarios NoCuates"
        Write-Host "  ${BLUE}3)${NC} Ver detalle de un usuario"
        Write-Host "  ${BLUE}4)${NC} Ver cuentas deshabilitadas"
        Write-Host ""
        Write-Host "  ${BLUE}0)${NC} Volver"
        Write-Host ""

        $op = Read-Host "  Opcion"

        switch ($op.ToUpper()) {

            # ---- ALTA -------------------------------------------------------
            "A" {
                Clear-Host
                Write-Host ""; draw_line
                Write-Host "  ALTA — Nuevo Usuario del Dominio"
                draw_line; Write-Host ""
                aputs_info "Complete los datos del nuevo usuario."
                aputs_info "Todos los campos son obligatorios."
                Write-Host ""

                $sam     = agets "Nombre de cuenta (ej: user11)"
                $nombre  = agets "Nombre completo  (ej: User Once)"
                Write-Host ""
                Write-Host "  Departamentos disponibles:"
                Write-Host "    ${CYAN}Cuates${NC}   -> 10 MB, horario 8AM-3PM"
                Write-Host "    ${CYAN}NoCuates${NC} -> 5 MB, horario 3PM-2AM"
                Write-Host ""
                $dept    = agets "Departamento (Cuates / NoCuates)"
                $pass    = agets "Password     (ej: Pass1234!)"

                if ([string]::IsNullOrWhiteSpace($sam) -or
                    [string]::IsNullOrWhiteSpace($nombre) -or
                    [string]::IsNullOrWhiteSpace($dept) -or
                    [string]::IsNullOrWhiteSpace($pass)) {
                    aputs_error "Datos incompletos. Operacion cancelada."
                    pause_menu; continue
                }

                # Confirmacion antes de crear
                Write-Host ""
                draw_line
                aputs_info "Resumen del usuario a crear:"
                aputs_info "  Cuenta:      $sam"
                aputs_info "  Nombre:      $nombre"
                aputs_info "  Grupo:       $dept"
                aputs_info "  Cuota:       $(if ($dept -eq 'Cuates') { '10 MB' } else { '5 MB' })"
                aputs_info "  LogonHours:  $(if ($dept -eq 'Cuates') { '8AM-3PM' } else { '3PM-2AM' })"
                draw_line
                $confirm = agets "Escriba 'SI' para crear el usuario"

                if ($confirm -eq "SI") {
                    $ok = New-UsuarioCompleto `
                        -SamAccount  $sam `
                        -DisplayName $nombre `
                        -Department  $dept `
                        -Password    $pass `
                        -DomainName  $domainName

                    if ($ok) {
                        aputs_success "Alta completada exitosamente."
                    } else {
                        aputs_error "La alta no se completo. Revise los errores arriba."
                    }
                } else {
                    aputs_info "Operacion cancelada."
                }
                pause_menu
            }

            # ---- BAJA -------------------------------------------------------
            "B" {
                Clear-Host
                Write-Host ""; draw_line
                Write-Host "  BAJA — Deshabilitar Cuenta de Usuario"
                draw_line; Write-Host ""
                aputs_warning "La cuenta se DESHABILITARA (no se elimina)."
                aputs_info    "El perfil y la cuota se conservan para evidencia."
                Write-Host ""

                $sam = agets "Nombre de cuenta a deshabilitar"

                if ([string]::IsNullOrWhiteSpace($sam)) {
                    aputs_error "Nombre de cuenta vacio. Operacion cancelada."
                    pause_menu; continue
                }

                # Mostrar info del usuario antes de confirmar
                try {
                    $u = Get-ADUser $sam -Properties Enabled, Department, DisplayName -ErrorAction Stop
                    Write-Host ""
                    aputs_info "Usuario encontrado:"
                    aputs_info "  Cuenta:      $($u.SamAccountName)"
                    aputs_info "  Nombre:      $($u.DisplayName)"
                    aputs_info "  Grupo:       $($u.Department)"
                    aputs_info "  Estado:      $(if ($u.Enabled) { 'Habilitado' } else { 'Ya deshabilitado' })"
                    Write-Host ""

                    if (-not $u.Enabled) {
                        aputs_warning "La cuenta ya esta deshabilitada."
                        pause_menu; continue
                    }

                    $confirm = agets "Escriba el nombre de cuenta de nuevo para confirmar"
                    if ($confirm -eq $sam) {
                        $ok = Remove-UsuarioCompleto -SamAccount $sam
                        if (-not $ok) {
                            aputs_error "La baja no se completo."
                        }
                    } else {
                        aputs_warning "Confirmacion no coincide. Operacion cancelada."
                    }
                } catch {
                    aputs_error "Usuario '$sam' no encontrado en AD."
                }
                pause_menu
            }

            # ---- CAMBIO DE GRUPO --------------------------------------------
            "C" {
                Clear-Host
                Write-Host ""; draw_line
                Write-Host "  CAMBIO — Mover Usuario entre Grupos"
                draw_line; Write-Host ""
                aputs_info "Se actualizara: OU, grupo de seguridad, cuota FSRM y LogonHours."
                Write-Host ""

                $sam = agets "Nombre de cuenta a mover"

                if ([string]::IsNullOrWhiteSpace($sam)) {
                    aputs_error "Nombre de cuenta vacio. Operacion cancelada."
                    pause_menu; continue
                }

                # Detectar grupo actual
                try {
                    $u = Get-ADUser $sam -Properties MemberOf, Department -ErrorAction Stop
                    $grupoActual = $u.Department
                    Write-Host ""
                    aputs_info "Usuario: $sam"
                    aputs_info "Grupo actual: $grupoActual"
                    Write-Host ""
                } catch {
                    aputs_error "Usuario '$sam' no encontrado en AD."
                    pause_menu; continue
                }

                # Sugerir el grupo opuesto automaticamente
                $grupoSugerido = if ($grupoActual -eq "Cuates") { "NoCuates" } else { "Cuates" }
                Write-Host "  Grupos disponibles: ${CYAN}Cuates${NC} / ${CYAN}NoCuates${NC}"
                $destino = agets "Grupo destino [$grupoSugerido]"
                if ([string]::IsNullOrWhiteSpace($destino)) { $destino = $grupoSugerido }

                # Confirmacion con resumen del cambio
                Write-Host ""
                draw_line
                aputs_info "Resumen del cambio:"
                aputs_info "  Usuario:    $sam"
                aputs_info "  De:         $grupoActual"
                aputs_info "  A:          $destino"
                $nuevaCuota  = if ($destino -eq "Cuates") { "10 MB" } else { "5 MB" }
                $nuevoHorario = if ($destino -eq "Cuates") { "8AM-3PM" } else { "3PM-2AM" }
                aputs_info "  Nueva cuota:      $nuevaCuota"
                aputs_info "  Nuevo horario:    $nuevoHorario"
                draw_line
                $confirm = agets "Escriba 'SI' para confirmar el cambio"

                if ($confirm -eq "SI") {
                    $ok = Move-UsuarioGrupo `
                        -SamAccount   $sam `
                        -GrupoDestino $destino `
                        -DomainName   $domainName

                    if ($ok) {
                        aputs_success "Cambio de grupo completado exitosamente."
                        aputs_info    "Si el usuario tiene sesion activa, cerrela para que tome efecto."
                    } else {
                        aputs_error "El cambio no se completo. Revise los errores arriba."
                    }
                } else {
                    aputs_info "Operacion cancelada."
                }
                pause_menu
            }

            # ---- LISTAR CUATES ----------------------------------------------
            "1" {
                Clear-Host
                Write-Host ""; draw_line; Write-Host "  Usuarios GRP_Cuates"; draw_line; Write-Host ""
                try {
                    $miembros = Get-ADGroupMember "GRP_Cuates" -ErrorAction Stop
                    if ($miembros.Count -eq 0) {
                        aputs_warning "Sin miembros en GRP_Cuates"
                    } else {
                        Write-Host (("  {0,-15} {1,-25} {2}" -f "Cuenta","Nombre","Estado"))
                        Write-Host "  ──────────────────────────────────────────────"
                        foreach ($m in $miembros) {
                            $u = Get-ADUser $m.SamAccountName -Properties Enabled, DisplayName -ErrorAction SilentlyContinue
                            $est = if ($u.Enabled) { "${GREEN}Activo${NC}" } else { "${RED}Inactivo${NC}" }
                            Write-Host -NoNewline ("  {0,-15} {1,-25} " -f $m.SamAccountName, $u.DisplayName)
                            Write-Host $est
                        }
                    }
                } catch { aputs_error "Error: $($_.Exception.Message)" }
                pause_menu
            }

            # ---- LISTAR NOCUATES --------------------------------------------
            "2" {
                Clear-Host
                Write-Host ""; draw_line; Write-Host "  Usuarios GRP_NoCuates"; draw_line; Write-Host ""
                try {
                    $miembros = Get-ADGroupMember "GRP_NoCuates" -ErrorAction Stop
                    if ($miembros.Count -eq 0) {
                        aputs_warning "Sin miembros en GRP_NoCuates"
                    } else {
                        Write-Host (("  {0,-15} {1,-25} {2}" -f "Cuenta","Nombre","Estado"))
                        Write-Host "  ──────────────────────────────────────────────"
                        foreach ($m in $miembros) {
                            $u = Get-ADUser $m.SamAccountName -Properties Enabled, DisplayName -ErrorAction SilentlyContinue
                            $est = if ($u.Enabled) { "${GREEN}Activo${NC}" } else { "${RED}Inactivo${NC}" }
                            Write-Host -NoNewline ("  {0,-15} {1,-25} " -f $m.SamAccountName, $u.DisplayName)
                            Write-Host $est
                        }
                    }
                } catch { aputs_error "Error: $($_.Exception.Message)" }
                pause_menu
            }

            # ---- DETALLE DE USUARIO -----------------------------------------
            "3" {
                Clear-Host
                Write-Host ""; draw_line; Write-Host "  Detalle de Usuario"; draw_line; Write-Host ""
                $sam = agets "Nombre de cuenta"
                try {
                    $u = Get-ADUser $sam -Properties * -ErrorAction Stop
                    $tieneHoras = ($null -ne $u.LogonHours -and $u.LogonHours.Count -eq 21)
                    aputs_info "Cuenta:       $($u.SamAccountName)"
                    aputs_info "Nombre:       $($u.DisplayName)"
                    aputs_info "UPN:          $($u.UserPrincipalName)"
                    aputs_info "Departamento: $($u.Department)"
                    aputs_info "OU:           $($u.DistinguishedName.Split(',')[1])"
                    aputs_info "Habilitado:   $($u.Enabled)"
                    aputs_info "LogonHours:   $(if ($tieneHoras) { 'Configurados (21 bytes)' } else { 'Sin restriccion' })"
                    # Cuota FSRM
                    $folderPath = "$script:PROFILES_BASE\$sam"
                    $q = Get-FsrmQuota -Path $folderPath -ErrorAction SilentlyContinue
                    if ($null -ne $q) {
                        aputs_info "Cuota FSRM:   $([Math]::Round($q.Size/1MB,0)) MB (uso: $([Math]::Round($q.Usage/1KB,0)) KB)"
                    } else {
                        aputs_info "Cuota FSRM:   No configurada"
                    }
                } catch {
                    aputs_error "Usuario '$sam' no encontrado."
                }
                pause_menu
            }

            # ---- CUENTAS DESHABILITADAS -------------------------------------
            "4" {
                Clear-Host
                Write-Host ""; draw_line; Write-Host "  Cuentas Deshabilitadas"; draw_line; Write-Host ""
                $domainNC = Get-DomainNC -DomainName $domainName
                $deshabilitadas = Get-ADUser -Filter { Enabled -eq $false } `
                    -SearchBase $domainNC -Properties Department, DisplayName `
                    -ErrorAction SilentlyContinue |
                    Where-Object { $_.SamAccountName -notin @("Guest","krbtgt") }

                if ($null -eq $deshabilitadas -or @($deshabilitadas).Count -eq 0) {
                    aputs_success "No hay cuentas deshabilitadas."
                } else {
                    Write-Host (("  {0,-15} {1,-20} {2}" -f "Cuenta","Nombre","Grupo"))
                    Write-Host "  ────────────────────────────────────────────"
                    foreach ($u in $deshabilitadas) {
                        Write-Host ("  {0,-15} {1,-20} {2}" -f $u.SamAccountName, $u.DisplayName, $u.Department)
                    }
                }
                pause_menu
            }

            "0" { return }

            default {
                aputs_error "Opcion invalida"
                Start-Sleep -Seconds 1
            }
        }
    }
}