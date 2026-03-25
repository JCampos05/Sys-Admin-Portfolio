#
# main.ps1
#
# Responsabilidad: Punto de entrada unico del proyecto.
# Orquesta la ejecucion de todas las fases en orden, maneja el estado
# entre reinicios del servidor y valida el entorno antes de comenzar.
#
# Flujo de ejecucion:
#   Primera ejecucion (estado INIT):
#     1. Validar prerequisitos
#     2. Solicitar y validar nombre de dominio
#     3. Fase A: Instalar AD DS -> reinicio automatico
#
#   Segunda ejecucion (post-reinicio, estado AD_INSTALLED):
#     4. Fase B: Crear OUs, grupos, usuarios, carpetas
#     5. Fase C: Configurar LogonHours y GPO de logoff
#     6. Fase D: Instalar FSRM, cuotas, file screening
#     7. Fase E: Configurar AppLocker
#     8. Limpiar tarea programada del reinicio
#     9. Mostrar resumen final
#
# Como manejar el estado entre reinicios:
#   El archivo .install_state guarda la ultima fase completada.
#   Al iniciar, main.ps1 lee ese archivo y salta las fases ya completadas.
#   Esto hace que el script sea idempotente: si falla en la Fase D,
#   se puede volver a ejecutar y continuara desde la Fase D sin repetir A, B y C.
#

#Requires -Version 5.1

# Establecer el directorio de trabajo al directorio donde esta este script
# $PSScriptRoot es la carpeta del script que se esta ejecutando
Set-Location $PSScriptRoot

# Cargar todos los modulos en orden de dependencia
# utils.ps1 primero porque todos los demas lo usan
. "$PSScriptRoot\utils.ps1"
. "$PSScriptRoot\utilsAD.ps1"
. "$PSScriptRoot\validatorsAD.ps1"
. "$PSScriptRoot\Functions-AD-A.ps1"
. "$PSScriptRoot\Functions-AD-B.ps1"
. "$PSScriptRoot\Functions-AD-C.ps1"
. "$PSScriptRoot\Functions-AD-D.ps1"
. "$PSScriptRoot\Functions-AD-E.ps1"

function Show-Banner {
    Clear-Host
    draw_line
    Write-Host "  Tarea 08: Gobernanza, Cuotas y Control de Aplicaciones en AD"
    Write-Host "  Administracion de Sistemas - Windows Server 2022"
    draw_line
    Write-Host "  Servidor: $env:COMPUTERNAME"
    Write-Host "  Usuario:  $env:USERNAME"
    Write-Host "  Fecha:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    draw_line
    Write-Host ""
}

# -------------------------------------------------------------------------
# Request-DomainName
# Solicita al usuario el nombre del dominio AD de forma interactiva,
# validando el formato con Test-DomainNameFormat de validatorsAD.ps1
# hasta que el usuario ingrese un nombre valido o cancele.
# Retorna: string con el nombre de dominio validado, o $null si el usuario cancela.
# -------------------------------------------------------------------------
function Request-DomainName {
    draw_header "Configuracion del Dominio Active Directory"

    aputs_info "Se creara un nuevo bosque de Active Directory."
    aputs_info "El nombre del dominio debe cumplir estas reglas:"
    Write-Host "   - Formato: prefijo.sufijo   (ej: sistemas.local)"
    Write-Host "   - Sufijos permitidos: .local | .lan | .internal"
    Write-Host "   - Prefijo maximo 15 caracteres (limite NetBIOS)"
    Write-Host "   - Solo letras, numeros y guiones en el prefijo"
    Write-Host "   - NO usar TLDs reales como .com, .net, .org"
    draw_line

    $maxAttempts = 5
    $attempt     = 0

    while ($attempt -lt $maxAttempts) {
        $attempt++
        $domainName = agets "Ingrese el nombre del dominio (intento $attempt/$maxAttempts)"

        if ($domainName -eq "salir" -or $domainName -eq "exit") {
            aputs_warning "El usuario cancelo la configuracion."
            return $null
        }

        if (Test-DomainNameFormat -DomainName $domainName) {
            aputs_success "Nombre de dominio aceptado: $domainName"
            return $domainName
        }

        if ($attempt -lt $maxAttempts) {
            aputs_warning "Intente nuevamente. (Escriba 'salir' para cancelar)"
        }
    }

    aputs_error "Se alcanzaron los $maxAttempts intentos maximos. Abortando."
    return $null
}

# -------------------------------------------------------------------------
# Get-StoredDomainName
# Lee el nombre del dominio guardado en el archivo .install_state.
# Se usa despues del reinicio para que las fases B-E sepan el dominio
# sin tener que pedirlo al usuario de nuevo.
# El archivo guarda el dominio en la segunda linea con formato: DOMAIN=nombre
# Retorna: string con el nombre del dominio, o $null si no se encuentra.
# -------------------------------------------------------------------------
function Get-StoredDomainName {
    if (-not (Test-Path $script:INSTALL_STATE)) {
        return $null
    }

    $lines = Get-Content $script:INSTALL_STATE -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        if ($line -match "^DOMAIN=(.+)$") {
            return $matches[1].Trim()
        }
    }

    return $null
}

# -------------------------------------------------------------------------
# Remove-PostRebootTask
# Elimina la tarea programada que lanzaba este script tras el reinicio.
# Se llama una vez que todas las fases post-reinicio han completado
# para evitar que el script se ejecute en cada inicio de sesion.
# -------------------------------------------------------------------------
function Remove-PostRebootTask {
    $taskName = "Tarea08-Continuar"
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if ($null -ne $task) {
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            aputs_success "Tarea programada '$taskName' eliminada."
            Write-ADLog "Tarea programada de reinicio eliminada" "INFO"
        } catch {
            aputs_warning "No se pudo eliminar la tarea programada: $($_.Exception.Message)"
        }
    }
}

# -------------------------------------------------------------------------
# Show-FinalSummary
# Muestra un resumen del estado final de la instalacion con los
# datos mas importantes para verificar que todo funciono correctamente.
# -------------------------------------------------------------------------
function Show-FinalSummary {
    param([string]$DomainName)

    draw_header "Resumen Final - Tarea 08 Completada"

    $domainShort = ($DomainName.Split(".")[0]).ToUpper()

    Write-Host ""
    aputs_success "Active Directory Domain Services: instalado"
    aputs_success "Dominio: $DomainName  (NetBIOS: $domainShort)"
    aputs_success "OUs creadas: Cuates y NoCuates"
    aputs_success "Grupos: GRP_Cuates (10MB, 8AM-3PM) y GRP_NoCuates (5MB, 3PM-2AM)"
    aputs_success "Usuarios: user01-user05 (Cuates) | user06-user10 (NoCuates)"
    aputs_success "LogonHours configurados por grupo"
    aputs_success "GPO de logoff forzado vinculada al dominio"
    aputs_success "FSRM instalado con cuotas hard 10MB/5MB"
    aputs_success "File Screening activo: bloqueados .mp3 .mp4 .exe .msi"
    aputs_success "AppLocker: notepad permitido (Cuates) / bloqueado por hash (NoCuates)"

    draw_line
    aputs_info "Archivos generados:"
    aputs_info "  Log de la practica: C:\Tarea08\tarea08.log"
    aputs_info "  XML AppLocker Cuates:   C:\Tarea08\applocker_cuates.xml"
    aputs_info "  XML AppLocker NoCuates: C:\Tarea08\applocker_nocuates.xml"
    aputs_info "  Carpetas de usuario:    C:\Perfiles\"
    draw_line
    aputs_info "Proximos pasos:"
    aputs_info "  1. Ejecutar script de union del cliente Linux (main.sh)"
    aputs_info "  2. Unir cliente Windows 10 al dominio con Add-Computer"
    aputs_info "  3. Probar inicio de sesion con user01 (Cuates) y user06 (NoCuates)"
    aputs_info "  4. Verificar cuotas copiando archivos mayores a 5MB o 10MB"
    aputs_info "  5. Verificar AppLocker intentando abrir notepad desde NoCuates"
    draw_line
}

# 
# PUNTO DE ENTRADA PRINCIPAL
# 

Show-Banner

# Verificar privilegios de administrador antes de hacer nada
if (-not (check_privileges)) {
    aputs_error "Ejecute este script como Administrador."
    aputs_info  "Clic derecho en PowerShell -> Ejecutar como administrador"
    exit 1
}

# Leer el estado actual para saber en que punto del proceso estamos
$currentState = Get-InstallState
aputs_info "Estado actual de instalacion: $currentState"
Write-ADLog "main.ps1 iniciado. Estado: $currentState" "INFO"

# -------------------------------------------------------------------------
# Rama 1: Primera ejecucion - Estado INIT
# Validar entorno, pedir nombre de dominio e instalar AD DS
# -------------------------------------------------------------------------
if ($currentState -eq "INIT") {

    aputs_info "Primera ejecucion detectada. Iniciando configuracion completa."

    # Ejecutar todas las validaciones de prerequisitos
    $validationsPassed = Invoke-AllValidations
    if (-not $validationsPassed) {
        aputs_error "Las validaciones fallaron. Corrija los errores y vuelva a ejecutar."
        Write-ADLog "Ejecucion abortada: validaciones fallidas" "ERROR"
        pause_menu
        exit 1
    }

    Write-Host ""
    aputs_success "Todas las validaciones pasaron. Continuando con la instalacion."
    pause_menu

    # Solicitar el nombre del dominio
    $domainName = Request-DomainName
    if ($null -eq $domainName) {
        aputs_error "No se configuro un nombre de dominio. Abortando."
        exit 1
    }

    # Confirmar antes de proceder con la instalacion de AD DS
    draw_line
    aputs_warning "ATENCION: Esto instalara Active Directory en este servidor."
    aputs_warning "El servidor se reiniciara automaticamente despues de la instalacion."
    aputs_warning "Dominio que se creara: $domainName"
    draw_line
    $confirm = agets "Escriba 'SI' para confirmar y continuar"
    if ($confirm -ne "SI") {
        aputs_warning "Instalacion cancelada por el usuario."
        exit 0
    }

    # Ejecutar Fase A (instala AD DS y reinicia el servidor)
    $phaseAOk = Invoke-PhaseA -DomainName $domainName
    if (-not $phaseAOk) {
        aputs_error "Fase A fallo. Revise C:\Tarea08\tarea08.log para detalles."
        pause_menu
        exit 1
    }

    # Si llegamos aqui sin reinicio es porque algo interrumpio el proceso
    aputs_warning "El servidor deberia haberse reiniciado. Verifique manualmente."
    exit 0
}

# -------------------------------------------------------------------------
# Rama 2: Ejecucion post-reinicio - Estado AD_INSTALLED o superior
# Continuar con las fases B, C, D y E
# -------------------------------------------------------------------------
if ($currentState -match "AD_INSTALLED|STRUCTURE_DONE|LOGONHOURS_DONE|FSRM_DONE") {

    aputs_info "Continuando configuracion post-reinicio (estado: $currentState)"

    # Recuperar el nombre del dominio guardado en .install_state
    $domainName = Get-StoredDomainName
    if ($null -eq $domainName) {
        aputs_error "No se pudo recuperar el nombre del dominio del archivo de estado."
        aputs_error "Archivo: C:\Tarea08\.install_state"
        aputs_info  "Verifique que el archivo contiene una linea con formato DOMAIN=nombre"
        exit 1
    }

    aputs_success "Dominio recuperado del estado: $domainName"

    # Ejecutar Fase B si no esta completada
    if ($currentState -eq "AD_INSTALLED") {
        Write-Host ""
        $phaseBOk = Invoke-PhaseB -DomainName $domainName
        if (-not $phaseBOk) {
            aputs_error "Fase B fallo. Revise el log y vuelva a ejecutar."
            pause_menu
            exit 1
        }
        $currentState = Get-InstallState
    }

    # Ejecutar Fase C si no esta completada
    if ($currentState -eq "STRUCTURE_DONE") {
        Write-Host ""
        $phaseCOk = Invoke-PhaseC -DomainName $domainName
        if (-not $phaseCOk) {
            aputs_error "Fase C fallo. Revise el log y vuelva a ejecutar."
            pause_menu
            exit 1
        }
        $currentState = Get-InstallState
    }

    # Ejecutar Fase D si no esta completada
    if ($currentState -eq "LOGONHOURS_DONE") {
        Write-Host ""
        $phaseDOk = Invoke-PhaseD
        if (-not $phaseDOk) {
            aputs_error "Fase D fallo. Revise el log y vuelva a ejecutar."
            pause_menu
            exit 1
        }
        $currentState = Get-InstallState
    }

    # Ejecutar Fase E si no esta completada
    if ($currentState -eq "FSRM_DONE") {
        Write-Host ""
        $phaseEOk = Invoke-PhaseE -DomainName $domainName
        if (-not $phaseEOk) {
            aputs_error "Fase E fallo. Revise el log y vuelva a ejecutar."
            pause_menu
            exit 1
        }
    }

    # Limpiar la tarea programada del reinicio
    Remove-PostRebootTask

    # Mostrar resumen final
    Show-FinalSummary -DomainName $domainName

    Write-ADLog "Tarea 08 completada exitosamente en dominio $domainName" "SUCCESS"
    pause_menu
    exit 0
}

# -------------------------------------------------------------------------
# Estado APPLOCKER_DONE: todas las fases completadas
# -------------------------------------------------------------------------
if ($currentState -eq "APPLOCKER_DONE") {
    $domainName = Get-StoredDomainName
    aputs_success "Tarea 08 ya esta completamente configurada."
    aputs_info    "Dominio: $domainName"
    aputs_info    "Si necesita volver a ejecutar alguna fase, edite C:\Tarea08\.install_state"
    aputs_info    "y cambie el valor a la fase anterior que desea re-ejecutar."
    Show-FinalSummary -DomainName $domainName
    pause_menu
    exit 0
}

# Estado desconocido
aputs_error "Estado desconocido en .install_state: $currentState"
aputs_info  "Valores validos: INIT, AD_INSTALLED, STRUCTURE_DONE, LOGONHOURS_DONE, FSRM_DONE, APPLOCKER_DONE"
aputs_info  "Edite C:\Tarea08\.install_state manualmente para corregir."
exit 1