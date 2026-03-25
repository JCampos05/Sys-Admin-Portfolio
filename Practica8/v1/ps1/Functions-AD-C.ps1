#
# Functions-AD-C.ps1
#
# Responsabilidad: Configurar el control de acceso temporal para cada grupo
#
# Mecanismo 1 - LogonHours en el objeto de usuario:
#   El atributo LogonHours en AD define en que horas un usuario PUEDE
#   iniciar sesion. Si intenta entrar fuera de su horario, el DC rechaza
#   la autenticacion. Sin embargo, esto solo bloquea NUEVOS inicios de sesion.
#   Si el usuario ya esta dentro y expira su horario, NO se cierra la sesion
#   automaticamente sin el segundo mecanismo.
#
# Mecanismo 2 - GPO "Seguridad de red: cerrar sesion al expirar horario":
#   Esta politica de grupo le indica al servidor que monitoree activamente
#   las sesiones activas y fuerce el cierre cuando expire el horario permitido.
#   Sin esta GPO, un usuario podria seguir trabajando indefinidamente aunque
#   su ventana de LogonHours haya terminado.
#
#
# Funciones:
#   Set-GroupLogonHours   - Aplica el atributo LogonHours a todos los usuarios de un grupo
#   New-LogoffGPO         - Crea la GPO que fuerza el cierre de sesion al expirar horario
#   Invoke-PhaseC         - Funcion principal que orquesta esta fase
#

#Requires -Version 5.1

. "$PSScriptRoot\utils.ps1"
. "$PSScriptRoot\utilsAD.ps1"

# -------------------------------------------------------------------------
# Set-GroupLogonHours
# Obtiene todos los usuarios de un grupo de AD y aplica el atributo
# LogonHours a cada uno con el rango horario especificado.
#
# Por que se aplica por usuario y no por grupo:
#   El atributo LogonHours es una propiedad del OBJETO USUARIO en AD,
#   no del grupo. No existe "LogonHours de grupo". Por eso iteramos
#   sobre los miembros del grupo y aplicamos el atributo individualmente.
#
# Parametros:
#   $GroupName      - Nombre del grupo 
#   $StartHourLocal - Hora de inicio en hora local 
#   $EndHourLocal   - Hora de fin en hora local 
# Retorna: $true si todos los usuarios fueron actualizados, $false si hubo errores.
# -------------------------------------------------------------------------
function Set-GroupLogonHours {
    param(
        [string]$GroupName,
        [int]$StartHourLocal,
        [int]$EndHourLocal
    )

    aputs_info "Configurando LogonHours para grupo: $GroupName"
    # Obtener offset UTC del sistema en tiempo de ejecucion
    # Evita hardcodear UTC-7 y hace el script portable a cualquier zona horaria
    $tzOffset = [int][Math]::Abs((Get-TimeZone).BaseUtcOffset.TotalHours)
    aputs_info "Horario local: $StartHourLocal:00 - $EndHourLocal:00 (offset UTC: +$tzOffset)"
    Write-ADLog "Aplicando LogonHours a $GroupName ($StartHourLocal-$EndHourLocal local, UTC+$tzOffset)" "INFO"

    # Convertir el rango horario a los 21 bytes que AD espera
    # UtcOffsetHours se obtiene del sistema dinamicamente (no hardcodeado)
    $logonBytes = ConvertTo-LogonHoursBytes `
        -StartHourLocal $StartHourLocal `
        -EndHourLocal   $EndHourLocal `
        -UtcOffsetHours $tzOffset

    # Obtener todos los miembros directos del grupo
    try {
        $members = Get-ADGroupMember -Identity $GroupName -ErrorAction Stop |
                   Where-Object { $_.objectClass -eq "user" }
    } catch {
        aputs_error "No se pudo obtener miembros de $GroupName : $($_.Exception.Message)"
        return $false
    }

    if ($null -eq $members -or @($members).Count -eq 0) {
        aputs_warning "El grupo $GroupName no tiene miembros. Verifique que la Fase B se completo."
        return $false
    }

    $updatedCount = 0
    $errorCount   = 0

    foreach ($member in $members) {
        try {
            # Set-ADUser -Replace y -Add fallan con el atributo binario LogonHours
            # cuando el atributo existe con valor vacio en AD (comportamiento conocido).
            # La solucion robusta es usar DirectoryServices.DirectoryEntry directamente
            # que bypasea las restricciones del modulo ActiveDirectory de PowerShell.
            $dn   = (Get-ADUser $member.SamAccountName).DistinguishedName
            $user = New-Object DirectoryServices.DirectoryEntry("LDAP://$dn")
            # Usar .Value = [byte[]] en lugar de .Clear() + .Add()
            # .Add() falla cuando el atributo existe con valor vacio en AD.
            # .Value asigna directamente sin importar el estado anterior.
            $user.Properties["logonHours"].Value = [byte[]]$logonBytes
            $user.CommitChanges()
            $user.Dispose()

            aputs_success "LogonHours aplicado a: $($member.SamAccountName)"
            Write-ADLog "LogonHours aplicado a $($member.SamAccountName)" "SUCCESS"
            $updatedCount++
        } catch {
            aputs_error "Error al aplicar LogonHours a $($member.SamAccountName) : $($_.Exception.Message)"
            Write-ADLog "Error LogonHours $($member.SamAccountName): $($_.Exception.Message)" "ERROR"
            $errorCount++
        }
    }

    aputs_info "Actualizados: $updatedCount | Errores: $errorCount"
    return ($errorCount -eq 0)
}

function New-LogoffGPO {
    param(
        [string]$DomainName
    )

    $gpoName = "Politica-ForzarLogoff-T08"

    aputs_info "Configurando GPO de cierre de sesion forzado: $gpoName"
    Write-ADLog "Creando GPO de logoff forzado: $gpoName" "INFO"

    # Verificar si la GPO ya existe (idempotencia)
    $existingGPO = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
    if ($null -ne $existingGPO) {
        aputs_info "GPO '$gpoName' ya existe. Verificando vinculacion..."
        Write-ADLog "GPO $gpoName ya existia" "INFO"
    } else {
        # Crear la GPO nueva
        try {
            $gpo = New-GPO -Name $gpoName `
                           -Comment "Tarea08: Fuerza cierre de sesion al expirar LogonHours" `
                           -ErrorAction Stop

            aputs_success "GPO creada: $gpoName"
            Write-ADLog "GPO $gpoName creada con GUID: $($gpo.Id)" "SUCCESS"
        } catch {
            aputs_error "Error al crear GPO: $($_.Exception.Message)"
            return $false
        }
    }

    try {
        # Clave principal de LanManServer
        Set-GPRegistryValue `
            -Name      $gpoName `
            -Key       "HKLM\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters" `
            -ValueName "EnableForcedLogOff" `
            -Type      DWord `
            -Value     1 `
            -ErrorAction Stop

        aputs_success "EnableForcedLogOff = 1 configurado en LanManServer"
        Write-ADLog "GPO: EnableForcedLogOff = 1" "SUCCESS"
    } catch {
        aputs_error "Error al configurar EnableForcedLogOff: $($_.Exception.Message)"
        Write-ADLog "Error configurando EnableForcedLogOff: $($_.Exception.Message)" "ERROR"
        return $false
    }

    try {
        # Clave de seguridad Lsa (necesaria en Windows 10)
        Set-GPRegistryValue `
            -Name      $gpoName `
            -Key       "HKLM\SYSTEM\CurrentControlSet\Control\Lsa" `
            -ValueName "ForceLogoffWhenHourExpire" `
            -Type      DWord `
            -Value     1 `
            -ErrorAction Stop

        aputs_success "ForceLogoffWhenHourExpire = 1 configurado en Lsa"
        Write-ADLog "GPO: ForceLogoffWhenHourExpire = 1" "SUCCESS"
    } catch {
        aputs_warning "Error al configurar ForceLogoffWhenHourExpire: $($_.Exception.Message)"
        Write-ADLog "Warning ForceLogoffWhenHourExpire: $($_.Exception.Message)" "WARNING"
        # No es fatal, LanManServer ya esta configurado
    }

    # Vincular la GPO a la raiz del dominio
    # Al vincularla al dominio (no a una OU especifica) aplica a TODOS los usuarios
    # y equipos del dominio. Los LogonHours individuales ya se encargan de
    # diferenciar el horario por grupo.
    $domainTarget = $DomainName  # Ej: "sistemas.local"

    try {
        # Verificar si ya esta vinculada
        $existingLink = Get-GPInheritance -Target $domainTarget -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty GpoLinks |
                        Where-Object { $_.DisplayName -eq $gpoName }

        if ($null -ne $existingLink) {
            aputs_info "GPO ya estaba vinculada al dominio."
        } else {
            try {
                New-GPLink `
                    -Name   $gpoName `
                    -Target "DC=$($DomainName.Replace('.', ',DC='))" `
                    -LinkEnabled Yes `
                    -ErrorAction Stop

                aputs_success "GPO vinculada al dominio: $DomainName"
                Write-ADLog "GPO $gpoName vinculada al dominio $DomainName" "SUCCESS"
            } catch {
                # Si ya estaba vinculada (carrera entre verificacion y creacion), no es error
                if ($_.Exception.Message -match "already linked") {
                    aputs_info "GPO ya estaba vinculada (detectado en creacion). Continuando."
                } else {
                    aputs_error "Error al vincular GPO al dominio: $($_.Exception.Message)"
                    Write-ADLog "Error vinculando GPO: $($_.Exception.Message)" "ERROR"
                    return $false
                }
            }
        }
    } catch {
        aputs_error "Error general en vinculacion de GPO: $($_.Exception.Message)"
        Write-ADLog "Error vinculando GPO: $($_.Exception.Message)" "ERROR"
        return $false
    }

    # Forzar actualizacion de politicas en el servidor
    # gpupdate /force hace que el servidor procese inmediatamente las GPOs
    # sin esperar el ciclo de refresco automatico (cada 90 minutos por defecto)
    aputs_info "Forzando actualizacion de politicas de grupo..."
    Invoke-GPUpdate -Force -ErrorAction SilentlyContinue

    aputs_success "GPO de logoff forzado configurada y vinculada."
    return $true
}

function Invoke-PhaseC {
    param(
        [string]$DomainName
    )

    draw_header "Fase C: Control de Acceso Temporal (LogonHours y GPO)"
    Write-ADLog "=== INICIO FASE C ===" "INFO"

    # Verificar idempotencia
    $state = Get-InstallState
    if ($state -match "LOGONHOURS_DONE|FSRM_DONE|APPLOCKER_DONE") {
        aputs_success "Fase C ya completada (estado: $state). Saltando."
        return $true
    }

    # Paso 1: LogonHours para GRP_Cuates (8 AM a 3 PM local)
    aputs_info "Paso 1/3: Configurando LogonHours para GRP_Cuates (8:00 AM - 3:00 PM)..."
    $cuatesOk = Set-GroupLogonHours `
        -GroupName      "GRP_Cuates" `
        -StartHourLocal 8 `
        -EndHourLocal   15

    if (-not $cuatesOk) {
        aputs_error "Fallo la configuracion de LogonHours para GRP_Cuates."
    }

    # Paso 2: LogonHours para GRP_NoCuates (3 PM a 2 AM local)
    aputs_info "Paso 2/3: Configurando LogonHours para GRP_NoCuates (3:00 PM - 2:00 AM)..."
    $noCuatesOk = Set-GroupLogonHours `
        -GroupName      "GRP_NoCuates" `
        -StartHourLocal 15 `
        -EndHourLocal   2

    if (-not $noCuatesOk) {
        aputs_error "Fallo la configuracion de LogonHours para GRP_NoCuates."
    }

    # Paso 3: GPO de cierre de sesion forzado
    aputs_info "Paso 3/3: Creando GPO para forzar cierre de sesion al expirar horario..."
    $gpoOk = New-LogoffGPO -DomainName $DomainName

    if (-not $gpoOk) {
        aputs_error "Fallo la creacion de la GPO de logoff."
        return $false
    }

    Set-InstallState "LOGONHOURS_DONE"
    aputs_success "Fase C completada: control de acceso temporal configurado."
    Write-ADLog "=== FIN FASE C ===" "SUCCESS"
    return $true
}