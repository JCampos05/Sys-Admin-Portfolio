#
# Functions-AD-B.ps1
# Funciones:
#   New-ADStructure        - Crea las OUs y grupos de seguridad
#   Import-UsersFromCSV    - Lee el CSV y crea los 10 usuarios en sus OUs
#   New-AllProfileFolders  - Crea la carpeta personal de cada usuario
#   Invoke-PhaseB          - Funcion principal que orquesta esta fase
#

#Requires -Version 5.1

. "$PSScriptRoot\utils.ps1"
. "$PSScriptRoot\utilsAD.ps1"

function New-ADStructure {
    param(
        [string]$DomainName
    )

    # Obtener el Distinguished Name raiz del dominio
    # Ej: "sistemas.local" -> "DC=sistemas,DC=local"
    $domainNC = Get-DomainNC -DomainName $DomainName

    aputs_info "DN del dominio: $domainNC"
    Write-ADLog "Creando estructura AD en dominio: $domainNC" "INFO"

    # --- Crear OU Cuates ---
    if (Test-OUExists -OUName "Cuates" -DomainNC $domainNC) {
        aputs_info "OU 'Cuates' ya existe. Omitiendo creacion."
    } else {
        try {
            New-ADOrganizationalUnit `
                -Name                  "Cuates" `
                -Path                  $domainNC `
                -Description           "Grupo 1: acceso 8AM-3PM, cuota 10MB, Bloc de Notas permitido" `
                -ProtectedFromAccidentalDeletion $false `
                -ErrorAction Stop

            aputs_success "OU 'Cuates' creada"
            Write-ADLog "OU Cuates creada en $domainNC" "SUCCESS"
        } catch {
            aputs_error "Error al crear OU Cuates: $($_.Exception.Message)"
            Write-ADLog "Error creando OU Cuates: $($_.Exception.Message)" "ERROR"
            return $false
        }
    }

    if (Test-OUExists -OUName "Equipos" -DomainNC $domainNC) {
        aputs_info "OU 'Equipos' ya existe. Omitiendo creacion."
    } else {
        try {
            New-ADOrganizationalUnit `
                -Name                  "Equipos" `
                -Path                  $domainNC `
                -Description           "Equipos cliente del dominio (Win10, Linux)" `
                -ProtectedFromAccidentalDeletion $false `
                -ErrorAction Stop

            aputs_success "OU 'Equipos' creada"
            Write-ADLog "OU Equipos creada en $domainNC" "SUCCESS"
        } catch {
            aputs_error "Error al crear OU Equipos: $($_.Exception.Message)"
            Write-ADLog "Error creando OU Equipos: $($_.Exception.Message)" "ERROR"
            return $false
        }
    }

    # --- Crear OU NoCuates ---
    if (Test-OUExists -OUName "NoCuates" -DomainNC $domainNC) {
        aputs_info "OU 'NoCuates' ya existe. Omitiendo creacion."
    } else {
        try {
            New-ADOrganizationalUnit `
                -Name                  "NoCuates" `
                -Path                  $domainNC `
                -Description           "Grupo 2: acceso 3PM-2AM, cuota 5MB, Bloc de Notas bloqueado" `
                -ProtectedFromAccidentalDeletion $false `
                -ErrorAction Stop

            aputs_success "OU 'NoCuates' creada"
            Write-ADLog "OU NoCuates creada en $domainNC" "SUCCESS"
        } catch {
            aputs_error "Error al crear OU NoCuates: $($_.Exception.Message)"
            Write-ADLog "Error creando OU NoCuates: $($_.Exception.Message)" "ERROR"
            return $false
        }
    }

    # DN de cada OU para usarlas como contenedor de los grupos
    $ouCuates   = "OU=Cuates,$domainNC"
    $ouNoCuates = "OU=NoCuates,$domainNC"

    # --- Crear Grupo GRP_Cuates dentro de OU Cuates ---
    if (Test-ADGroupExists -GroupName "GRP_Cuates") {
        aputs_info "Grupo 'GRP_Cuates' ya existe. Omitiendo creacion."
    } else {
        try {
            New-ADGroup `
                -Name            "GRP_Cuates" `
                -SamAccountName  "GRP_Cuates" `
                -GroupScope      Global `
                -GroupCategory   Security `
                -Path            $ouCuates `
                -Description     "Grupo de seguridad para usuarios Cuates" `
                -ErrorAction Stop

            aputs_success "Grupo 'GRP_Cuates' creado en OU Cuates"
            Write-ADLog "Grupo GRP_Cuates creado" "SUCCESS"
        } catch {
            aputs_error "Error al crear grupo GRP_Cuates: $($_.Exception.Message)"
            return $false
        }
    }

    # --- Crear Grupo GRP_NoCuates dentro de OU NoCuates ---
    if (Test-ADGroupExists -GroupName "GRP_NoCuates") {
        aputs_info "Grupo 'GRP_NoCuates' ya existe. Omitiendo creacion."
    } else {
        try {
            New-ADGroup `
                -Name            "GRP_NoCuates" `
                -SamAccountName  "GRP_NoCuates" `
                -GroupScope      Global `
                -GroupCategory   Security `
                -Path            $ouNoCuates `
                -Description     "Grupo de seguridad para usuarios NoCuates" `
                -ErrorAction Stop

            aputs_success "Grupo 'GRP_NoCuates' creado en OU NoCuates"
            Write-ADLog "Grupo GRP_NoCuates creado" "SUCCESS"
        } catch {
            aputs_error "Error al crear grupo GRP_NoCuates: $($_.Exception.Message)"
            return $false
        }
    }

    aputs_success "Estructura de AD (OUs y grupos) lista."
    return $true
}

# -------------------------------------------------------------------------
# Import-UsersFromCSV
# Lee el archivo CSV de usuarios y crea cada uno en Active Directory,
# colocandolo en la OU correcta segun el atributo "Departamento" del CSV
# y agregandolo al grupo de seguridad correspondiente.
#
# El CSV tiene estas columnas: Nombre, Apellido, Usuario, Password, Departamento
# El atributo "Departamento" determina si va a OU Cuates o OU NoCuates.
#
# Por cada usuario se configura:
#   - SamAccountName: nombre de inicio de sesion (ej: user01)
#   - UserPrincipalName: nombre@dominio (ej: user01@sistemas.local)
#   - DisplayName: nombre completo visible
#   - OU de destino: segun Departamento del CSV
#   - Grupo: GRP_Cuates o GRP_NoCuates
#   - PasswordNeverExpires: true (para no complicar la practica)
#   - Cuenta habilitada: true
#
# Parametros:
#   $CsvPath    - Ruta al archivo CSV 
#   $DomainName - Nombre del dominio (ej: "sistemas.local")
# Retorna: $true si todos los usuarios fueron creados, $false si hubo errores.
# -------------------------------------------------------------------------
function Import-UsersFromCSV {
    param(
        [string]$CsvPath,
        [string]$DomainName
    )

    # Verificar que el CSV existe
    if (-not (Test-Path $CsvPath)) {
        aputs_error "Archivo CSV no encontrado: $CsvPath"
        aputs_info  "Coloque el archivo usuarios.csv en C:\Tarea08\data\"
        return $false
    }

    $domainNC = Get-DomainNC -DomainName $DomainName

    aputs_info "Leyendo archivo CSV: $CsvPath"
    Write-ADLog "Importando usuarios desde CSV: $CsvPath" "INFO"

    try {
        $users = Import-Csv -Path $CsvPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        aputs_error "Error al leer el CSV: $($_.Exception.Message)"
        return $false
    }

    $totalUsers  = $users.Count
    $createdCount = 0
    $skippedCount = 0
    $errorCount   = 0

    aputs_info "Usuarios encontrados en CSV: $totalUsers"

    foreach ($row in $users) {
        $samAccount = $row.Usuario.Trim()
        $firstName  = $row.Nombre.Trim()
        $lastName   = $row.Apellido.Trim()
        $department = $row.Departamento.Trim()
        $password   = $row.Password.Trim()
        $displayName = "$firstName $lastName"
        $upn         = "$samAccount@$DomainName"

        # Determinar OU y grupo segun el Departamento del CSV
        switch ($department) {
            "Cuates" {
                $ouPath    = "OU=Cuates,$domainNC"
                $groupName = "GRP_Cuates"
            }
            "NoCuates" {
                $ouPath    = "OU=NoCuates,$domainNC"
                $groupName = "GRP_NoCuates"
            }
            default {
                aputs_warning "Departamento desconocido '$department' para usuario $samAccount. Omitiendo."
                Write-ADLog "Departamento invalido '$department' para $samAccount" "WARNING"
                $errorCount++
                continue
            }
        }

        # Verificar si el usuario ya existe (idempotencia)
        if (Test-ADUserExists -SamAccountName $samAccount) {
            aputs_info "Usuario '$samAccount' ya existe en AD. Verificando grupo..."

            # Asegurarse de que este en el grupo correcto aunque ya existiera
            try {
                Add-ADGroupMember -Identity $groupName -Members $samAccount -ErrorAction SilentlyContinue
            } catch { }

            $skippedCount++
            continue
        }

        # Convertir la contrasena a SecureString
        $securePass = ConvertTo-SecureString $password -AsPlainText -Force

        # Crear el usuario en AD
        try {
            New-ADUser `
                -SamAccountName       $samAccount `
                -UserPrincipalName    $upn `
                -GivenName            $firstName `
                -Surname              $lastName `
                -DisplayName          $displayName `
                -Name                 $displayName `
                -Department           $department `
                -AccountPassword      $securePass `
                -Path                 $ouPath `
                -Enabled              $true `
                -PasswordNeverExpires $true `
                -ChangePasswordAtLogon $false `
                -ErrorAction Stop

            aputs_success "Usuario creado: $samAccount -> OU $department"
            Write-ADLog "Usuario $samAccount creado en OU $department" "SUCCESS"
            $createdCount++

        } catch {
            aputs_error "Error al crear usuario $samAccount : $($_.Exception.Message)"
            Write-ADLog "Error creando usuario $samAccount : $($_.Exception.Message)" "ERROR"
            $errorCount++
            continue
        }

        # Agregar el usuario al grupo de seguridad correspondiente
        try {
            Add-ADGroupMember -Identity $groupName -Members $samAccount -ErrorAction Stop
            aputs_success "Usuario $samAccount agregado a $groupName"
            Write-ADLog "Usuario $samAccount agregado a $groupName" "SUCCESS"
        } catch {
            aputs_warning "No se pudo agregar $samAccount a $groupName : $($_.Exception.Message)"
            Write-ADLog "Error agregando $samAccount a $groupName : $($_.Exception.Message)" "WARNING"
        }
    }

    draw_line
    aputs_info    "Resumen de importacion:"
    aputs_success "  Creados:  $createdCount"
    aputs_info    "  Existentes (omitidos): $skippedCount"
    if ($errorCount -gt 0) {
        aputs_warning "  Errores: $errorCount"
    }
    Write-ADLog "Importacion CSV: $createdCount creados, $skippedCount omitidos, $errorCount errores" "INFO"

    return ($errorCount -eq 0)
}

# -------------------------------------------------------------------------
# New-AllProfileFolders
# Crea la carpeta personal de cada usuario en C:\Perfiles\<usuario>.
# Esta carpeta es donde el FSRM aplicara las cuotas de disco.
# Llama a New-ProfileFolder de utilsAD.ps1 por cada usuario del CSV.
#
# Parametros:
#   $CsvPath    - Ruta al archivo CSV para leer los usuarios
#   $DomainName - Nombre del dominio (para configurar permisos NTFS)
# Retorna: $true si todas las carpetas quedaron creadas.
# -------------------------------------------------------------------------
function New-AllProfileFolders {
    param(
        [string]$CsvPath,
        [string]$DomainName
    )

    # Crear la carpeta raiz C:\Perfiles si no existe
    if (-not (Test-Path "C:\Perfiles")) {
        New-Item -ItemType Directory -Path "C:\Perfiles" -Force | Out-Null
        aputs_success "Carpeta raiz C:\Perfiles creada"
        Write-ADLog "Carpeta raiz C:\Perfiles creada" "SUCCESS"
    } else {
        aputs_info "Carpeta raiz C:\Perfiles ya existe"
    }

    # Leer el CSV para obtener los nombres de usuario
    try {
        $users = Import-Csv -Path $CsvPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        aputs_error "Error al leer CSV para crear carpetas: $($_.Exception.Message)"
        return $false
    }

    # El nombre del dominio corto (NetBIOS) para los permisos NTFS
    # Ej: "sistemas.local" -> "SISTEMAS"
    $domainShort = ($DomainName.Split(".")[0]).ToUpper()

    $allOk = $true
    foreach ($row in $users) {
        $samAccount = $row.Usuario.Trim()
        aputs_info "Creando carpeta para: $samAccount"

        $ok = New-ProfileFolder -UserName $samAccount -Domain $domainShort
        if (-not $ok) {
            $allOk = $false
        }
    }

    aputs_success "Carpetas de perfiles creadas en C:\Perfiles\"
    return $allOk
}

function Invoke-PhaseB {
    param(
        [string]$DomainName,
        [string]$CsvPath = $script:CSV_PATH
    )

    draw_header "Fase B: Estructura de Active Directory"
    Write-ADLog "=== INICIO FASE B ===" "INFO"

    $state = Get-InstallState
    if ($state -match "STRUCTURE_DONE|LOGONHOURS_DONE|FSRM_DONE|APPLOCKER_DONE") {
        # Verificar si los usuarios realmente existen en AD
        try {
            $cuatesCount   = (Get-ADGroupMember -Identity "GRP_Cuates"   -ErrorAction Stop).Count
            $noCuatesCount = (Get-ADGroupMember -Identity "GRP_NoCuates" -ErrorAction Stop).Count
        } catch {
            $cuatesCount   = 0
            $noCuatesCount = 0
        }

        if ($cuatesCount -gt 0 -and $noCuatesCount -gt 0) {
            aputs_success "Fase B ya completada: $cuatesCount Cuates, $noCuatesCount NoCuates en AD. Saltando."
            return $true
        }

        # Los grupos estan vacios: re-ejecutar solo la importacion de usuarios
        aputs_warning "Estado es $state pero los grupos estan vacios. Re-importando usuarios desde CSV..."
        Write-ADLog "Re-importacion de usuarios por grupos vacios detectados" "WARNING"

        $usersOk = Import-UsersFromCSV -CsvPath $CsvPath -DomainName $DomainName
        if (-not $usersOk) {
            aputs_error "Re-importacion fallo. Verifique que el CSV existe en: $CsvPath"
            return $false
        }
        aputs_success "Usuarios re-importados correctamente."
        return $true
    }

    # Esperar a que los servicios de AD esten completamente listos
    # Despues de un reinicio el servicio ADWS puede tardar unos segundos
    aputs_info "Esperando que los servicios de AD esten listos..."
    $maxWait   = 60
    $waited    = 0
    $adReady   = $false

    while ($waited -lt $maxWait) {
        try {
            Get-ADDomain -ErrorAction Stop | Out-Null
            $adReady = $true
            break
        } catch {
            aputs_info "AD aun no responde, esperando 5 segundos... ($waited/$maxWait s)"
            Start-Sleep -Seconds 5
            $waited += 5
        }
    }

    if (-not $adReady) {
        aputs_error "Active Directory no respondio en $maxWait segundos."
        aputs_error "Verifique que el servidor se haya promovido correctamente."
        return $false
    }

    aputs_success "Servicios de Active Directory listos."

    # Paso 1: Crear OUs y grupos
    aputs_info "Paso 1/3: Creando estructura organizativa (OUs y grupos)..."
    $structureOk = New-ADStructure -DomainName $DomainName
    if (-not $structureOk) {
        aputs_error "Fallo la creacion de la estructura. Abortando Fase B."
        return $false
    }

    # Paso 2: Importar usuarios desde CSV
    aputs_info "Paso 2/3: Importando usuarios desde CSV..."
    $usersOk = Import-UsersFromCSV -CsvPath $CsvPath -DomainName $DomainName
    if (-not $usersOk) {
        aputs_error "Hubo errores al importar usuarios. Revise el log."
        # No abortamos, continuamos aunque haya errores parciales
    }

    # Paso 3: Crear carpetas de perfiles
    aputs_info "Paso 3/4: Creando carpetas de perfiles en C:\Perfiles\..."
    $foldersOk = New-AllProfileFolders -CsvPath $CsvPath -DomainName $DomainName
    if (-not $foldersOk) {
        aputs_warning "Algunas carpetas no se crearon correctamente. Verifique el log."
    }

    # Paso 4: Registrar clientes Linux en DNS
    # Este paso es critico para que sssd funcione en los clientes Linux.
    # Sin el registro DNS, Kerberos no puede verificar la identidad del cliente
    # y sssd queda Offline con error "Server not found in Kerberos database".
    # Se ejecuta aqui para que este listo antes de que el cliente Linux corra main.sh.
    aputs_info "Paso 4/4: Registrando clientes Linux en DNS del DC..."
    $registerScript = Join-Path $PSScriptRoot "Register-ClientDNS.ps1"
    if (Test-Path $registerScript) {
        & "$registerScript"
    } else {
        aputs_warning "Register-ClientDNS.ps1 no encontrado."
        aputs_info    "Para registrar clientes Linux en el DNS del DC manualmente:"
        aputs_info    "  Add-DnsServerResourceRecordA -ZoneName '$DomainName' \"
        aputs_info    "    -Name 'NOMBRE_CLIENTE' -IPv4Address 'IP_CLIENTE' -TimeToLive '01:00:00'"
        aputs_info    "Ejemplo para cliente Linux tipico:"
        aputs_info    "  Add-DnsServerResourceRecordA -ZoneName '$DomainName' \"
        aputs_info    "    -Name 'NOMBRE_CLIENTE_LINUX' -IPv4Address 'IP_CLIENTE_LINUX' -TimeToLive '01:00:00'"
    }

    # Crear share Perfiles$ para que los usuarios puedan acceder a sus carpetas
    # desde los equipos cliente via \SVR\Perfiles$\<usuario>
    # Esto permite probar las cuotas FSRM directamente desde el cliente Win10
    aputs_info "Creando share de red Perfiles$..."
    $existingShare = Get-SmbShare -Name "Perfiles$" -ErrorAction SilentlyContinue
    if ($null -ne $existingShare) {
        aputs_info "Share 'Perfiles$' ya existe. Omitiendo."
    } else {
        try {
            # Usar nombres localizados para compatibilidad con Windows Server en español
            # "Administradores" y "Usuarios del dominio" son los nombres en es-ES
            New-SmbShare -Name "Perfiles$" `
                -Path $script:PROFILES_BASE `
                -FullAccess "Administradores" `
                -ChangeAccess "Usuarios del dominio" `
                -ErrorAction Stop | Out-Null
            aputs_success "Share 'Perfiles$' creado: \\$env:COMPUTERNAME\Perfiles$"
            Write-ADLog "Share Perfiles$ creado en $script:PROFILES_BASE" "SUCCESS"
        } catch {
            # Si falla con nombres localizados, intentar sin permisos y agregar despues
            aputs_warning "Intento 1 fallido: $($_.Exception.Message)"
            aputs_info    "Intentando crear share sin permisos especificos..."
            try {
                New-SmbShare -Name "Perfiles$" -Path $script:PROFILES_BASE -ErrorAction Stop | Out-Null
                Grant-SmbShareAccess -Name "Perfiles$" -AccountName "Everyone" `
                    -AccessRight Change -Force -ErrorAction SilentlyContinue | Out-Null
                aputs_success "Share 'Perfiles$' creado (acceso Everyone)"
                Write-ADLog "Share Perfiles$ creado con acceso Everyone" "SUCCESS"
            } catch {
                aputs_warning "No se pudo crear share Perfiles`$: $($_.Exception.Message)"
                aputs_info    "Creelo manualmente: New-SmbShare -Name 'Perfiles`$' -Path '$script:PROFILES_BASE'"
            }
        }
    }

    # Configurar WinRM TrustedHosts para permitir PSRemoting desde clientes
    # Esto es necesario para que clienteAD.ps1 pueda conectarse al servidor
    # via Invoke-Command y mover el equipo a OU=Equipos automaticamente.
    # Sin esto, el cliente tiene que mover el equipo manualmente.
    aputs_info "Configurando WinRM TrustedHosts para clientes de la red interna..."
    try {
        Enable-PSRemoting -Force -ErrorAction SilentlyContinue | Out-Null
        # Detectar la subred interna del servidor dinamicamente
        $serverIP = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                     Where-Object { $_.IPAddress -like "192.168.*" -and
                                    $_.IPAddress -notlike "192.168.70.*" -and
                                    $_.IPAddress -notlike "192.168.75.*" } |
                     Select-Object -First 1).IPAddress
        $subnet = if ($serverIP) {
            ($serverIP -split "\.")[0..2] -join "." + ".*"
        } else { "192.168.100.*" }

        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $subnet -Force -ErrorAction Stop
        aputs_success "WinRM TrustedHosts configurado: $subnet"
        Write-ADLog "WinRM TrustedHosts configurado para $subnet" "SUCCESS"
    } catch {
        aputs_warning "No se pudo configurar WinRM TrustedHosts: $($_.Exception.Message)"
        aputs_info    "El cliente debera mover el equipo manualmente a OU=Equipos"
    }

    Set-InstallState "STRUCTURE_DONE"
    aputs_success "Fase B completada: estructura de AD lista."
    Write-ADLog "=== FIN FASE B ===" "SUCCESS"
    return $true
}