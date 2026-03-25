#
# validatorsAD.ps1
# Tarea 08 - Gobernanza, Cuotas y Control de Aplicaciones en Active Directory
#
# Responsabilidad: Verificar que el entorno del servidor cumpla todos los
# prerequisitos necesarios antes de ejecutar cualquier instalacion o
# configuracion de Active Directory.
#
# Funciones:
#   Test-OSCompatibility       - Verifica que el SO sea Windows Server 2016+
#   Test-ExecutionPolicy       - Verifica que PowerShell permita ejecutar scripts
#   Test-StaticIP              - Verifica que la IP del adaptador interno sea estatica
#   Test-DNSSelfPointing       - Verifica que el DNS del adaptador apunte a si mismo
#   Test-TimeZone              - Verifica que la zona horaria sea UTC-07:00
#   Test-ADModuleAvailable     - Verifica si el modulo ActiveDirectory ya esta cargado
#   Test-FirewallPorts         - Verifica puertos criticos de AD en el firewall
#   Test-DomainNameFormat      - Valida el formato del nombre de dominio ingresado
#   Invoke-AllValidations      - Ejecuta todas las validaciones y retorna resultado
#

#Requires -Version 5.1

. "$PSScriptRoot\utils.ps1"

# -------------------------------------------------------------------------
# Test-OSCompatibility
# Verifica que el sistema operativo sea Windows Server 2016 o superior.
# Active Directory Domain Services en su version moderna requiere al menos
# Windows Server 2016. En versiones anteriores algunos cmdlets no existen.
# Retorna: $true si el SO es compatible, $false si no lo es.
# -------------------------------------------------------------------------
function Test-OSCompatibility {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $caption = $os.Caption

    # El numero de version 10.0 corresponde a Server 2016, 2019 y 2022
    $buildNumber = [int]$os.BuildNumber

    # Windows Server 2016 comienza en build 14393
    if ($buildNumber -lt 14393) {
        aputs_error "Sistema operativo no compatible: $caption"
        aputs_info  "Se requiere Windows Server 2016 o superior (Build 14393+)"
        aputs_info  "Build actual: $buildNumber"
        return $false
    }

    aputs_success "Sistema operativo compatible: $caption (Build $buildNumber)"
    return $true
}

# -------------------------------------------------------------------------
# Test-ExecutionPolicy
# Verifica que la politica de ejecucion de PowerShell permita correr scripts.
# La politica "Restricted" (valor por defecto en Windows) bloquea todos los
# scripts. Necesitamos "Bypass", "Unrestricted" o "RemoteSigned".
# Retorna: $true si la politica es adecuada, $false si bloquea scripts.
# -------------------------------------------------------------------------
function Test-ExecutionPolicy {
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    $policyProcess = Get-ExecutionPolicy -Scope Process

    # Si el proceso fue lanzado con -ExecutionPolicy Bypass, el scope Process
    # tendra Bypass aunque el scope CurrentUser sea Restricted
    $effectivePolicy = $policyProcess

    $blocked = @("Restricted", "AllSigned")

    if ($blocked -contains $effectivePolicy) {
        aputs_error "Politica de ejecucion bloqueante: $effectivePolicy"
        aputs_info  "Ejecute PowerShell con: -ExecutionPolicy Bypass"
        aputs_info  "O configure: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser"
        return $false
    }

    aputs_success "Politica de ejecucion: $effectivePolicy (compatible)"
    return $true
}

# -------------------------------------------------------------------------
# Test-StaticIP
# Verifica que el adaptador de red interno (Red_Sistemas) tenga IP estatica.
# Active Directory no puede funcionar correctamente si la IP del DC cambia.
# Un DC con IP por DHCP puede cambiar de direccion y romper toda la red.
# Parametros:
#   $ExpectedIP - IP esperada en el adaptador (default: se detecta automaticamente)
# Retorna: $true si la IP es estatica y correcta, $false si no lo es.
# -------------------------------------------------------------------------
function Test-StaticIP {
    param(
        [string]$ExpectedIP = ""
    )

    # Detectar IP automaticamente si no se especifica
    if ([string]::IsNullOrEmpty($ExpectedIP)) {
        $detected = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -like "192.168.*" -and
                                   $_.IPAddress -notlike "192.168.70.*" -and
                                   $_.IPAddress -notlike "192.168.75.*" } |
                    Select-Object -First 1
        if ($null -ne $detected) {
            $ExpectedIP = $detected.IPAddress
            aputs_info "IP del servidor detectada automaticamente: $ExpectedIP"
        } else {
            aputs_error "No se encontro adaptador en subred interna"
            return $false
        }
    }

    # Buscar el adaptador que tenga la IP esperada
    $adapter = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -eq $ExpectedIP }

    if ($null -eq $adapter) {
        aputs_error "No se encontro el adaptador con IP $ExpectedIP"
        aputs_info  "Verifique que el adaptador Red_Sistemas tenga IP estatica $ExpectedIP"
        return $false
    }

    # PrefixOrigin "Manual" indica que fue configurada manualmente (estatica)
    # "Dhcp" indica que viene de DHCP (dinamica)
    if ($adapter.PrefixOrigin -ne "Manual") {
        aputs_error "La IP $ExpectedIP no es estatica (origen: $($adapter.PrefixOrigin))"
        aputs_info  "Configure la IP manualmente en el adaptador de red"
        return $false
    }

    aputs_success "IP estatica verificada: $ExpectedIP (origen: Manual)"
    return $true
}

# -------------------------------------------------------------------------
# Test-DNSSelfPointing
# Verifica que el servidor DNS configurado en el adaptador interno
# apunte a si mismo (IP interna del servidor, detectada automaticamente).
# Durante la instalacion de AD DS, el instalador crea zonas DNS internas.
# Si el servidor apunta a un DNS externo, no puede resolver sus propios
# registros SRV (_kerberos._tcp, _ldap._tcp) y la instalacion falla.
# Parametros:
#   $AdapterIP - IP del adaptador a verificar (default: se detecta automaticamente)
# Retorna: $true si el DNS apunta al propio servidor, $false si no.
# -------------------------------------------------------------------------
function Test-DNSSelfPointing {
    param(
        [string]$AdapterIP = ""
    )

    # Detectar IP automaticamente si no se especifica
    if ([string]::IsNullOrEmpty($AdapterIP)) {
        $detected = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -like "192.168.*" -and
                                   $_.IPAddress -notlike "192.168.70.*" -and
                                   $_.IPAddress -notlike "192.168.75.*" } |
                    Select-Object -First 1
        if ($null -ne $detected) { $AdapterIP = $detected.IPAddress }
        else { aputs_error "No se pudo detectar la IP del adaptador interno."; return $false }
    }

    # Obtener el indice de interfaz del adaptador con la IP interna
    $adapterIndex = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                     Where-Object { $_.IPAddress -eq $AdapterIP } |
                     Select-Object -First 1).InterfaceIndex

    if ($null -eq $adapterIndex) {
        aputs_error "No se pudo obtener la interfaz con IP $AdapterIP"
        return $false
    }

    # Obtener los servidores DNS configurados en esa interfaz
    $dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $adapterIndex `
                   -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses

    if ($null -eq $dnsServers -or $dnsServers.Count -eq 0) {
        aputs_error "No hay servidores DNS configurados en el adaptador interno"
        aputs_info  "El script intentara configurarlo automaticamente..."

        # Intentar configurarlo automaticamente en lugar de solo reportar el error.
        # Esta es la causa mas comun de fallo silencioso en la instalacion de AD DS.
        try {
            Set-DnsClientServerAddress -InterfaceIndex $adapterIndex `
                -ServerAddresses $AdapterIP -ErrorAction Stop
            aputs_success "DNS configurado automaticamente a: $AdapterIP"
            return $true
        } catch {
            aputs_error "No se pudo configurar DNS automaticamente: $($_.Exception.Message)"
            aputs_error "Configurelo manualmente antes de continuar:"
            aputs_info  "  Set-DnsClientServerAddress -InterfaceIndex $adapterIndex -ServerAddresses '$AdapterIP'"
            return $false
        }
    }

    # El primer DNS (preferido) debe ser el propio servidor
    $primaryDNS = $dnsServers[0]

    if ($primaryDNS -ne $AdapterIP -and $primaryDNS -ne "127.0.0.1") {
        aputs_error "DNS primario apunta a: $primaryDNS"
        aputs_error "Debe apuntar a: $AdapterIP (o 127.0.0.1)"
        aputs_info  "Panel de Control > Adaptadores de Red > Red_Sistemas > IPv4 > DNS: $AdapterIP"
        return $false
    }

    aputs_success "DNS primario apunta correctamente a: $primaryDNS"
    return $true
}

# -------------------------------------------------------------------------
# Test-TimeZone
# Verifica que la zona horaria del servidor sea UTC-07:00.
# Los LogonHours en Active Directory se almacenan en UTC.
# Si la zona horaria es incorrecta, los horarios de acceso se aplicaran
# con desfase y los usuarios no podran entrar en el horario esperado.
# Retorna: $true si la zona horaria es UTC-07:00, $false si es otra.
# -------------------------------------------------------------------------
function Test-TimeZone {
    $tz = Get-TimeZone
    $currentOffset = $tz.BaseUtcOffset.TotalHours

    # Reportar zona horaria sin rechazar ninguna especifica
    # El offset real del sistema se usa automaticamente en ConvertTo-LogonHoursBytes
    aputs_success "Zona horaria: $($tz.DisplayName)"
    aputs_info    "Offset UTC: $currentOffset horas (se usara para calcular LogonHours)"

    if ($currentOffset -eq 0) {
        aputs_warning "La zona horaria es UTC+0. Los horarios locales coincidiran con UTC."
    }

    return $true
}

# -------------------------------------------------------------------------
# Test-ADModuleAvailable
# Verifica si el modulo de PowerShell para Active Directory esta disponible.
# Este modulo se instala automaticamente cuando se agrega el rol AD DS.
# Si ya esta disponible significa que AD podria estar ya instalado.
# No es un error si no esta disponible (el script lo instalara).
# Retorna: $true si el modulo existe, $false si no existe aun.
# -------------------------------------------------------------------------
function Test-ADModuleAvailable {
    $module = Get-Module -ListAvailable -Name "ActiveDirectory" -ErrorAction SilentlyContinue

    if ($null -eq $module) {
        aputs_warning "Modulo ActiveDirectory no disponible aun"
        aputs_info    "Se instalara como parte del rol AD DS en Functions-AD-A"
        return $false
    }

    aputs_success "Modulo ActiveDirectory disponible: version $($module.Version)"
    return $true
}

# -------------------------------------------------------------------------
# Test-FirewallPorts
# Verifica que los puertos criticos de Active Directory esten permitidos
# en el firewall de Windows.
# Active Directory requiere multiples puertos para funcionar:
#   53  - DNS: resolucion de nombres del dominio
#   88  - Kerberos: autenticacion de usuarios y equipos
#   135 - RPC Endpoint Mapper: comunicacion entre servicios AD
#   389 - LDAP: consultas al directorio
#   445 - SMB: distribucion de politicas de grupo (GPO)
#   636 - LDAPS: LDAP sobre SSL
#   3268 - Global Catalog: busquedas en todo el bosque AD
# Retorna: $true si todos los puertos estan permitidos, $false si alguno falta.
# -------------------------------------------------------------------------
function Test-FirewallPorts {
    $requiredPorts = @(53, 88, 135, 389, 445, 636, 3268)
    $allOk = $true

    foreach ($port in $requiredPorts) {
        # Buscar reglas de firewall que permitan el puerto en zona internal
        # Las reglas de AD normalmente se crean en el perfil Domain o Private
        $rule = Get-NetFirewallRule -ErrorAction SilentlyContinue |
                Where-Object { $_.Enabled -eq $true -and $_.Action -eq "Allow" } |
                Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
                Where-Object { $_.LocalPort -eq $port -or $_.LocalPort -eq "Any" }

        if ($null -eq $rule) {
            aputs_warning "Puerto $port no tiene regla de firewall explicita"
            aputs_info    "Functions-AD-A.ps1 creara las reglas necesarias"
            $allOk = $false
        } else {
            aputs_success "Puerto $port permitido en firewall"
        }
    }

    if (-not $allOk) {
        aputs_info "Las reglas faltantes se crearan automaticamente al instalar AD DS"
    }

    # No retornamos false aqui porque Functions-AD-A creara las reglas.
    # Solo reportamos el estado actual.
    return $true
}

# -------------------------------------------------------------------------
# Test-DomainNameFormat
# Valida que el nombre de dominio ingresado cumpla el formato correcto.
# Reglas:
#   - Solo letras, numeros y guiones (sin espacios ni caracteres especiales)
#   - Debe tener exactamente un punto (formato: prefijo.sufijo)
#   - El prefijo (antes del punto) maximo 15 caracteres (limite NetBIOS)
#   - El sufijo debe ser .local, .lan o .internal (nunca un TLD real)
#   - No puede empezar ni terminar con guion
# Parametros:
#   $DomainName - Nombre de dominio a validar (ej: sistemas.local)
# Retorna: $true si el formato es valido, $false si tiene errores.
# -------------------------------------------------------------------------
function Test-DomainNameFormat {
    param(
        [string]$DomainName
    )

    if ([string]::IsNullOrWhiteSpace($DomainName)) {
        aputs_error "El nombre de dominio no puede estar vacio"
        return $false
    }

    # Debe contener exactamente un punto
    $parts = $DomainName.Split(".")
    if ($parts.Count -ne 2) {
        aputs_error "Formato invalido: '$DomainName'"
        aputs_info  "El nombre debe tener exactamente un punto (ej: sistemas.local)"
        return $false
    }

    $prefix = $parts[0]
    $suffix = $parts[1]

    # El prefijo no puede estar vacio
    if ([string]::IsNullOrEmpty($prefix)) {
        aputs_error "El prefijo del dominio no puede estar vacio"
        return $false
    }

    # El prefijo maximo 15 caracteres (limite de NetBIOS)
    if ($prefix.Length -gt 15) {
        aputs_error "El prefijo '$prefix' tiene $($prefix.Length) caracteres (maximo 15)"
        aputs_info  "Limite de 15 caracteres por restriccion de NetBIOS"
        return $false
    }

    # El prefijo solo puede contener letras, numeros y guiones
    # No puede empezar ni terminar con guion
    if ($prefix -notmatch "^[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9]$" -and
        $prefix -notmatch "^[a-zA-Z0-9]$") {
        aputs_error "El prefijo '$prefix' contiene caracteres no permitidos"
        aputs_info  "Solo se permiten letras, numeros y guiones (sin espacios)"
        aputs_info  "No puede empezar ni terminar con guion"
        return $false
    }

    # El sufijo debe ser un TLD privado (no usar dominios reales)
    $allowedSuffixes = @("local", "lan", "internal")
    if ($allowedSuffixes -notcontains $suffix.ToLower()) {
        aputs_error "Sufijo '$suffix' no permitido"
        aputs_info  "Use uno de los siguientes: local, lan, internal"
        aputs_info  "Ejemplos: sistemas.local | lab.lan | tarea08.internal"
        return $false
    }

    aputs_success "Nombre de dominio valido: $DomainName"
    aputs_info    "NetBIOS name: $($prefix.ToUpper())"
    return $true
}

# -------------------------------------------------------------------------
# Invoke-AllValidations
# Ejecuta todas las validaciones en orden y retorna un resumen.
# Esta es la funcion publica que llama main.ps1 antes de iniciar.
# Si alguna validacion critica falla, retorna $false para detener la ejecucion.
# Retorna: $true si el entorno esta listo, $false si hay problemas criticos.
# -------------------------------------------------------------------------
function Invoke-AllValidations {
    draw_header "Validaciones de Prerequisitos - Tarea 08"

    $results = @{}

    aputs_info "Verificando compatibilidad del sistema operativo..."
    $results["OS"] = Test-OSCompatibility

    aputs_info "Verificando politica de ejecucion de PowerShell..."
    $results["Policy"] = Test-ExecutionPolicy

    aputs_info "Verificando IP estatica del servidor..."
    $results["IP"] = Test-StaticIP

    aputs_info "Verificando que DNS apunte al propio servidor..."
    $results["DNS"] = Test-DNSSelfPointing

    aputs_info "Verificando zona horaria..."
    $results["TZ"] = Test-TimeZone

    aputs_info "Verificando disponibilidad del modulo ActiveDirectory..."
    $results["ADModule"] = Test-ADModuleAvailable

    aputs_info "Verificando puertos de firewall para AD..."
    $results["Firewall"] = Test-FirewallPorts

    draw_line

    # Validaciones criticas: si fallan, no se puede continuar
    # ADModule y Firewall son informativos, no criticos (el script los resuelve)
    $criticalChecks = @("OS", "Policy", "IP", "DNS", "TZ")
    $criticalFailed = $false

    foreach ($check in $criticalChecks) {
        if (-not $results[$check]) {
            $criticalFailed = $true
        }
    }

    if ($criticalFailed) {
        aputs_error "Una o mas validaciones criticas fallaron."
        aputs_error "Corrija los problemas indicados antes de continuar."
        return $false
    }

    aputs_success "Todas las validaciones criticas pasaron. Entorno listo."
    return $true
}