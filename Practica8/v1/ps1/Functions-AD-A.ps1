#
# Functions-AD-A.ps1
#
#
# Funciones:
#   Install-ADDSRole         - Instala los roles AD DS y DNS si no estan presentes
#   Invoke-DomainPromotion   - Promueve el servidor como DC de un nuevo bosque
#   Set-ADFirewallRules      - Crea reglas de firewall para los puertos de AD
#   Invoke-PhaseA            - Funcion principal que orquesta esta fase completa
#

#Requires -Version 5.1

. "$PSScriptRoot\utils.ps1"
. "$PSScriptRoot\utilsAD.ps1"

# -------------------------------------------------------------------------
# Install-ADDSRole
# Instala los roles de Windows necesarios para Active Directory:
#   - AD-Domain-Services: el servicio de directorio en si
#   - DNS: necesario porque AD depende de DNS para que los clientes
#     encuentren el DC mediante registros SRV (_kerberos._tcp, _ldap._tcp)
#   - RSAT-AD-PowerShell: las herramientas de PowerShell para gestionar AD
#     (New-ADUser, New-ADGroup, etc.)
# La instalacion es idempotente: si el rol ya esta instalado, no hace nada.
# Retorna: $true si los roles quedaron instalados, $false si hubo error.
# -------------------------------------------------------------------------
function Install-ADDSRole {
    aputs_info "Verificando roles AD DS y DNS..."

    $adInstalled  = Test-WindowsFeatureInstalled "AD-Domain-Services"
    $dnsInstalled = Test-WindowsFeatureInstalled "DNS"
    $rsatInstalled = Test-WindowsFeatureInstalled "RSAT-AD-PowerShell"

    if ($adInstalled -and $dnsInstalled -and $rsatInstalled) {
        aputs_success "Roles AD DS, DNS y RSAT ya estan instalados"
        Write-ADLog "Roles AD DS/DNS/RSAT verificados como ya instalados" "INFO"
        return $true
    }

    aputs_info "Instalando roles AD DS, DNS y herramientas RSAT..."
    aputs_info "Este proceso puede tardar varios minutos..."
    Write-ADLog "Iniciando instalacion de roles AD DS, DNS, RSAT" "INFO"

    try {
        $result = Install-WindowsFeature `
            -Name AD-Domain-Services, DNS, RSAT-AD-PowerShell `
            -IncludeManagementTools `
            -ErrorAction Stop

        if ($result.Success) {
            aputs_success "Roles instalados correctamente"
            Write-ADLog "Roles AD DS, DNS, RSAT instalados con exito" "SUCCESS"
            return $true
        } else {
            aputs_error "La instalacion de roles fallo sin excepcion"
            aputs_info  "Codigo de salida: $($result.ExitCode)"
            Write-ADLog "Fallo instalacion de roles: $($result.ExitCode)" "ERROR"
            return $false
        }
    } catch {
        aputs_error "Error al instalar roles: $($_.Exception.Message)"
        Write-ADLog "Excepcion instalando roles: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Invoke-DomainPromotion {
    param(
        [string]$DomainName,
        [SecureString]$DSRMPassword
    )

    # Derivar el nombre NetBIOS del prefijo del dominio (todo en mayusculas)
    $netbiosName = ($DomainName.Split(".")[0]).ToUpper()

    aputs_info "Iniciando promocion a Domain Controller..."
    aputs_info "Dominio: $DomainName"
    aputs_info "NetBIOS: $netbiosName"
    aputs_info "Nivel funcional: Windows Server 2016 (WinThreshold)"
    Write-ADLog "Iniciando promocion DC para dominio: $DomainName" "INFO"

    try {
        Install-ADDSForest `
            -DomainName              $DomainName `
            -DomainNetbiosName       $netbiosName `
            -DomainMode              "WinThreshold" `
            -ForestMode              "WinThreshold" `
            -InstallDns              `
            -SafeModeAdministratorPassword $DSRMPassword `
            -Force                   `
            -NoRebootOnCompletion    `
            -ErrorAction Stop

        aputs_success "Promocion a DC completada. Pendiente de reinicio."
        Write-ADLog "Promocion DC completada exitosamente para: $DomainName" "SUCCESS"
        return $true

    } catch {
        aputs_error "Error durante la promocion a DC:"
        aputs_error $_.Exception.Message
        Write-ADLog "Error en promocion DC: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# -------------------------------------------------------------------------
# Puertos y su proposito:
#   53  TCP/UDP - DNS: los clientes resuelven el nombre del dominio
#   88  TCP/UDP - Kerberos: autenticacion de usuarios y equipos
#   135 TCP     - RPC Endpoint Mapper: negociacion de puertos dinamicos
#   389 TCP/UDP - LDAP: consultas al directorio de usuarios y grupos
#   445 TCP     - SMB/CIFS: distribucion de politicas de grupo (SYSVOL)
#   636 TCP     - LDAPS: LDAP cifrado con SSL
#   3268 TCP    - Global Catalog: busquedas en todo el bosque
#   3269 TCP    - Global Catalog sobre SSL
# -------------------------------------------------------------------------
function Set-ADFirewallRules {
    aputs_info "Configurando reglas de firewall para Active Directory..."
    Write-ADLog "Configurando reglas de firewall para AD" "INFO"

    # Definir puertos a abrir con su descripcion
    $tcpPorts = @{
        53   = "AD-DNS-TCP"
        88   = "AD-Kerberos-TCP"
        135  = "AD-RPC-TCP"
        389  = "AD-LDAP-TCP"
        445  = "AD-SMB-TCP"
        636  = "AD-LDAPS-TCP"
        3268 = "AD-GlobalCatalog-TCP"
        3269 = "AD-GlobalCatalogSSL-TCP"
    }

    $udpPorts = @{
        53  = "AD-DNS-UDP"
        88  = "AD-Kerberos-UDP"
        389 = "AD-LDAP-UDP"
    }

    # Crear reglas TCP
    foreach ($port in $tcpPorts.Keys) {
        $ruleName = $tcpPorts[$port]
        $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

        if ($null -ne $existing) {
            aputs_info "Regla TCP $port ya existe: $ruleName"
            continue
        }

        try {
            New-NetFirewallRule `
                -DisplayName $ruleName `
                -Direction   Inbound `
                -Protocol    TCP `
                -LocalPort   $port `
                -Action      Allow `
                -Profile     Any `
                -ErrorAction Stop | Out-Null

            aputs_success "Regla TCP $port creada: $ruleName"
            Write-ADLog "Regla firewall TCP $port creada" "SUCCESS"
        } catch {
            aputs_warning "No se pudo crear regla TCP $port : $($_.Exception.Message)"
        }
    }

    # Crear reglas UDP
    foreach ($port in $udpPorts.Keys) {
        $ruleName = $udpPorts[$port]
        $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

        if ($null -ne $existing) {
            aputs_info "Regla UDP $port ya existe: $ruleName"
            continue
        }

        try {
            New-NetFirewallRule `
                -DisplayName $ruleName `
                -Direction   Inbound `
                -Protocol    UDP `
                -LocalPort   $port `
                -Action      Allow `
                -Profile     Any `
                -ErrorAction Stop | Out-Null

            aputs_success "Regla UDP $port creada: $ruleName"
            Write-ADLog "Regla firewall UDP $port creada" "SUCCESS"
        } catch {
            aputs_warning "No se pudo crear regla UDP $port : $($_.Exception.Message)"
        }
    }

    aputs_success "Configuracion de firewall para AD completada"
}

# -------------------------------------------------------------------------
# Invoke-PhaseA
# Funcion principal de esta fase. Orquesta la instalacion completa de AD DS.
# Flujo:
#   1. Verificar si los roles ya estan instalados (idempotencia)
#   2. Instalar roles AD DS + DNS + RSAT
#   3. Configurar firewall
#   4. Pedir la contrasena DSRM al administrador
#   5. Promover el servidor a DC
#   6. Guardar estado "AD_INSTALLED"
#   7. Programar continuacion automatica post-reinicio
#   8. Reiniciar el servidor
#
# Parametros:
#   $DomainName - Nombre del dominio validado por main.ps1
# -------------------------------------------------------------------------
function Invoke-PhaseA {
    param(
        [string]$DomainName
    )

    draw_header "Fase A: Instalacion de Active Directory Domain Services"
    Write-ADLog "=== INICIO FASE A ===" "INFO"

    # Verificar si esta fase ya fue completada (idempotencia post-reinicio)
    $state = Get-InstallState
    if ($state -ne "INIT") {
        aputs_success "Fase A ya completada (estado: $state). Saltando."
        return $true
    }

    # Paso 1: Instalar roles
    aputs_info "Paso 1/4: Instalando roles de Windows..."
    $rolesOk = Install-ADDSRole
    if (-not $rolesOk) {
        aputs_error "Fallo la instalacion de roles. Abortando Fase A."
        return $false
    }

    # Paso 2: Configurar firewall
    aputs_info "Paso 2/4: Configurando reglas de firewall..."
    Set-ADFirewallRules

    # Paso 3: Solicitar contrasena DSRM
    # La contrasena DSRM es para el modo de recuperacion de AD (no es la del admin)
    # Debe cumplir requisitos de complejidad de Windows
    aputs_info "Paso 3/4: Configuracion de seguridad del dominio"
    draw_line
    aputs_info "Se solicitara la contrasena del Modo de Restauracion de Servicios de Directorio (DSRM)."
    aputs_info "Esta contrasena se usa SOLO en recuperacion de desastres, no en el uso diario."
    aputs_info "Debe cumplir: mayusculas + minusculas + numeros + simbolos, minimo 8 caracteres."
    draw_line

    $dsrmPass1 = Read-Host "Ingrese la contrasena DSRM" -AsSecureString
    $dsrmPass2 = Read-Host "Confirme la contrasena DSRM" -AsSecureString

    # Comparar las dos contrasenas
    $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($dsrmPass1))
    $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($dsrmPass2))

    if ($plain1 -ne $plain2) {
        aputs_error "Las contrasenas no coinciden. Abortando."
        return $false
    }

    # Limpiar las cadenas planas de memoria inmediatamente
    $plain1 = $null
    $plain2 = $null

    # Paso 4: Promover a DC
    aputs_info "Paso 4/4: Promoviendo servidor a Domain Controller..."
    aputs_warning "Este proceso tarda 2-5 minutos. No interrumpa el script."

    $promotionOk = Invoke-DomainPromotion -DomainName $DomainName -DSRMPassword $dsrmPass1

    if (-not $promotionOk) {
        aputs_error "Fallo la promocion a DC. Abortando Fase A."
        return $false
    }

    # Guardar el nombre del dominio en el archivo de estado para que
    # las fases siguientes (post-reinicio) sepan cual es el dominio
    $stateContent = "AD_INSTALLED`nDOMAIN=$DomainName"
    $stateContent | Out-File -FilePath $script:INSTALL_STATE -Encoding UTF8 -Force
    Write-ADLog "Estado actualizado a AD_INSTALLED con dominio: $DomainName" "SUCCESS"

    # Configurar tarea programada para que main.ps1 continue automaticamente
    # despues del reinicio sin que el usuario tenga que lanzarlo manualmente
    $taskAction  = New-ScheduledTaskAction `
        -Execute "PowerShell.exe" `
        -Argument "-ExecutionPolicy Bypass -File `"$script:SCRIPTS_BASE\main.ps1`""

    $taskTrigger = New-ScheduledTaskTrigger -AtLogOn

    $taskSettings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 60) `
        -RestartCount 0

    # Registrar la tarea para que corra como SYSTEM al iniciar sesion
    Register-ScheduledTask `
        -TaskName   "Tarea08-Continuar" `
        -Action     $taskAction `
        -Trigger    $taskTrigger `
        -RunLevel   Highest `
        -User       "SYSTEM" `
        -Settings   $taskSettings `
        -Force | Out-Null

    aputs_success "Tarea programada creada: el script continuara tras el reinicio."
    aputs_warning "El servidor se reiniciara en 15 segundos..."
    aputs_info    "Despues del reinicio, inicie sesion y el script continuara automaticamente."
    Write-ADLog "Reinicio programado post-instalacion AD DS" "INFO"

    Start-Sleep -Seconds 15
    Restart-Computer -Force
}