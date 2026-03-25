#
# utilsAD.ps1
#
# Funciones:
#   Get-InstallState              - Lee el estado actual de instalacion del archivo flag
#   Set-InstallState              - Escribe el estado de instalacion en el archivo flag
#   Test-WindowsFeatureInstalled  - Verifica si un rol/caracteristica de Windows esta instalado
#   ConvertTo-LogonHoursBytes     - Convierte rango horario local a los 21 bytes que requiere AD
#   Get-DomainNC                  - Retorna el Distinguished Name del dominio (ej: DC=lab,DC=local)
#   Test-OUExists                 - Verifica si una Unidad Organizativa existe en AD
#   Test-ADUserExists             - Verifica si un usuario de AD existe
#   Test-ADGroupExists            - Verifica si un grupo de AD existe
#   New-ProfileFolder             - Crea la carpeta personal de un usuario con permisos correctos
#   Write-ADLog                   - Escribe una linea en el log de la practica
#

#Requires -Version 5.1

. "$PSScriptRoot\utils.ps1"

# SCRIPTS_BASE: ruta donde viven los scripts de la practica.
# Se obtiene de PSScriptRoot en lugar de hardcodearse, de modo que
# funciona independientemente del usuario o carpeta desde donde se ejecute.
$script:SCRIPTS_BASE   = $PSScriptRoot

# Ruta de datos criticos que AD necesita en produccion:
#   .install_state : flag de fase entre reinicios
#   tarea08.log    : log de evidencias para la rubrica
# Se separa de los scripts para que sobreviva a cualquier limpieza del directorio de trabajo.
$script:TAREA08_BASE   = "C:\Tarea08"
$script:INSTALL_STATE  = "$script:TAREA08_BASE\.install_state"
$script:LOG_FILE       = "$script:TAREA08_BASE\tarea08.log"
$script:PROFILES_BASE  = "C:\Perfiles"

# Ruta al CSV de usuarios. Vive junto a los scripts porque es un archivo fuente,
# no un archivo generado por la ejecucion.
$script:CSV_PATH       = "$script:SCRIPTS_BASE\data\usuarios.csv"

# -------------------------------------------------------------------------
# Get-InstallState
# Lee el archivo .install_state para saber en que fase quedo el script
# antes del ultimo reinicio. Esto permite que main.ps1 continue desde
# donde se quedo sin repetir pasos ya completados.
# El archivo contiene una sola linea con el nombre de la fase completada.
# Fases posibles: "INIT", "AD_INSTALLED", "STRUCTURE_DONE",
#                 "LOGONHOURS_DONE", "FSRM_DONE", "APPLOCKER_DONE"
# Retorna: string con la fase actual, o "INIT" si el archivo no existe.
# -------------------------------------------------------------------------
function Get-InstallState {
    if (-not (Test-Path $script:INSTALL_STATE)) {
        return "INIT"
    }

    # Leer solo la primera linea del archivo.
    # El archivo tiene dos lineas: la fase en la linea 1 y DOMAIN=nombre en la linea 2.
    $lines = Get-Content $script:INSTALL_STATE -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($null -eq $lines -or @($lines).Count -eq 0) {
        return "INIT"
    }

    $state = @($lines)[0].Trim()

    if ([string]::IsNullOrWhiteSpace($state)) {
        return "INIT"
    }

    return $state
}

# -------------------------------------------------------------------------
# Set-InstallState
# Escribe el estado actual en el archivo flag .install_state.
# Se llama al completar cada fase para registrar el progreso.
# Parametros:
#   $State - Nombre de la fase completada (ej: "AD_INSTALLED")
# -------------------------------------------------------------------------
function Set-InstallState {
    param(
        [string]$State
    )

    if (-not (Test-Path $script:TAREA08_BASE)) {
        New-Item -ItemType Directory -Path $script:TAREA08_BASE -Force | Out-Null
    }

    # Preservar la linea DOMAIN= si ya existe en el archivo.
    $domainLine = $null
    if (Test-Path $script:INSTALL_STATE) {
        $existing = Get-Content $script:INSTALL_STATE -Encoding UTF8 -ErrorAction SilentlyContinue
        $domainLine = @($existing) | Where-Object { $_ -match "^DOMAIN=" } | Select-Object -First 1
    }

    $State | Out-File -FilePath $script:INSTALL_STATE -Encoding UTF8 -Force

    if (-not [string]::IsNullOrWhiteSpace($domainLine)) {
        $domainLine | Add-Content -Path $script:INSTALL_STATE -Encoding UTF8
    }

    Write-ADLog "Estado actualizado: $State"
    aputs_info "Estado guardado: $State"
}

# -------------------------------------------------------------------------
# Test-WindowsFeatureInstalled
# Verifica si un rol o caracteristica de Windows Server esta instalado.
# Parametros:
#   $FeatureName - Nombre del rol (ej: "AD-Domain-Services", "FS-Resource-Manager")
# Retorna: $true si el rol esta instalado, $false si no lo esta.
# -------------------------------------------------------------------------
function Test-WindowsFeatureInstalled {
    param(
        [string]$FeatureName
    )

    $feature = Get-WindowsFeature -Name $FeatureName -ErrorAction SilentlyContinue

    if ($null -eq $feature) {
        aputs_warning "Rol no encontrado en el sistema: $FeatureName"
        return $false
    }

    if ($feature.InstallState -eq "Installed") {
        return $true
    }

    return $false
}

# -------------------------------------------------------------------------
# ConvertTo-LogonHoursBytes
# Convierte un rango horario en hora local a los 21 bytes que Active Directory
# usa internamente para representar las horas de acceso permitidas.
#
# Como funciona el formato de 21 bytes:
#   - AD divide la semana en 7 dias x 24 horas = 168 bits
#   - Cada bit representa una hora especifica (1=permitido, 0=bloqueado)
#   - Los 168 bits se agrupan en 21 bytes (168 / 8 = 21)
#   - IMPORTANTE: AD almacena las horas en UTC, no en hora local
#
# Parametros:
#   $StartHourLocal - Hora de inicio en hora local (0-23)
#   $EndHourLocal   - Hora de fin en hora local (0-23)
#   $UtcOffsetHours - Offset POSITIVO de zona horaria
#                     (ej: 7 para UTC-07:00, porque hora_UTC = hora_local + 7)
#
# Retorna: array de 21 bytes para usar en Set-ADUser -LogonHours
# -------------------------------------------------------------------------
function ConvertTo-LogonHoursBytes {
    param(
        [int]$StartHourLocal,
        [int]$EndHourLocal,
        [int]$UtcOffsetHours = 7
    )

    # Convertir horas locales a UTC
    # Para UTC-7: hora_UTC = hora_local + 7
    $startUTC = ($StartHourLocal + $UtcOffsetHours) % 24
    $endUTC   = ($EndHourLocal   + $UtcOffsetHours) % 24

    if ($startUTC -lt 0) { $startUTC += 24 }
    if ($endUTC   -lt 0) { $endUTC   += 24 }

    $bits = New-Object bool[] 168

    for ($day = 0; $day -lt 7; $day++) {
        $dayOffset = $day * 24

        if ($startUTC -lt $endUTC) {
            for ($hour = $startUTC; $hour -lt $endUTC; $hour++) {
                $bits[$dayOffset + $hour] = $true
            }
        } else {
            for ($hour = $startUTC; $hour -lt 24; $hour++) {
                $bits[$dayOffset + $hour] = $true
            }
            for ($hour = 0; $hour -lt $endUTC; $hour++) {
                $bits[$dayOffset + $hour] = $true
            }
        }
    }

    $bytes = New-Object byte[] 21
    for ($i = 0; $i -lt 168; $i++) {
        if ($bits[$i]) {
            $byteIndex = [math]::Floor($i / 8)
            $bitIndex  = $i % 8
            $bytes[$byteIndex] = $bytes[$byteIndex] -bor ([byte](1 -shl $bitIndex))
        }
    }

    return $bytes
}

# -------------------------------------------------------------------------
# Get-DomainNC
# Retorna el Distinguished Name (DN) del dominio en formato LDAP.
# Ej: "sistemas.local" -> "DC=sistemas,DC=local"
# -------------------------------------------------------------------------
function Get-DomainNC {
    param(
        [string]$DomainName
    )

    $parts = $DomainName.Split(".")
    $dn = ($parts | ForEach-Object { "DC=$_" }) -join ","
    return $dn
}

# -------------------------------------------------------------------------
# Test-OUExists
# -------------------------------------------------------------------------
function Test-OUExists {
    param(
        [string]$OUName,
        [string]$DomainNC
    )

    try {
        $ou = Get-ADOrganizationalUnit -Filter "Name -eq '$OUName'" `
              -SearchBase $DomainNC -ErrorAction Stop
        return ($null -ne $ou)
    } catch {
        return $false
    }
}

# -------------------------------------------------------------------------
# Test-ADUserExists
# -------------------------------------------------------------------------
function Test-ADUserExists {
    param(
        [string]$SamAccountName
    )

    try {
        $user = Get-ADUser -Identity $SamAccountName -ErrorAction Stop
        return ($null -ne $user)
    } catch {
        return $false
    }
}

# -------------------------------------------------------------------------
# Test-ADGroupExists
# -------------------------------------------------------------------------
function Test-ADGroupExists {
    param(
        [string]$GroupName
    )

    try {
        $group = Get-ADGroup -Identity $GroupName -ErrorAction Stop
        return ($null -ne $group)
    } catch {
        return $false
    }
}

# -------------------------------------------------------------------------
# New-ProfileFolder
# Crea la carpeta personal de un usuario en $script:PROFILES_BASE\<usuario>
# y configura los permisos NTFS correctos.
# -------------------------------------------------------------------------
function New-ProfileFolder {
    param(
        [string]$UserName,
        [string]$Domain
    )

    $folderPath = "$script:PROFILES_BASE\$UserName"

    if (-not (Test-Path $folderPath)) {
        New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
        aputs_info "Carpeta creada: $folderPath"
    } else {
        aputs_info "Carpeta ya existe: $folderPath"
        return $true
    }

    $acl = Get-Acl -Path $folderPath
    $acl.SetAccessRuleProtection($true, $false)

    $domainUser = "$Domain\$UserName"

    $ruleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    # Usar SID universal de Administradores (S-1-5-32-544) en lugar del nombre
    # "Administrators" porque en un DC el grupo se llama "Administradores" en español
    # y el nombre localizado causa "IdentityNotMappedException" al crear la regla ACL.
    $adminSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $ruleAdmin = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $adminSid, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    $ruleUser = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $domainUser, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
    )

    $acl.AddAccessRule($ruleSystem)
    $acl.AddAccessRule($ruleAdmin)
    $acl.AddAccessRule($ruleUser)

    Set-Acl -Path $folderPath -AclObject $acl
    aputs_success "Permisos configurados en: $folderPath"
    return $true
}

# -------------------------------------------------------------------------
# Write-ADLog
# -------------------------------------------------------------------------
function Write-ADLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    if (-not (Test-Path $script:TAREA08_BASE)) {
        New-Item -ItemType Directory -Path $script:TAREA08_BASE -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry  = "[$timestamp][$Level] $Message"

    Add-Content -Path $script:LOG_FILE -Value $logEntry -Encoding UTF8
}