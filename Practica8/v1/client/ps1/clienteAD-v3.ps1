#
# clienteAD-v2.ps1 - VERSION 2 - AppLocker Local
#
# Las reglas se escriben directamente en:
#   HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2
#
# Flujo:
#   Estado INIT   -> configura red, une al dominio, mueve a OU=Equipos, reinicia
#   Estado JOINED -> configura AppLocker local, gpupdate
#   Estado DONE   -> menu de verificacion
#
# CRITICO: Siempre APAGAR completamente y ENCENDER.
#          NUNCA usar Reiniciar ni Logoff para probar usuarios.
#

#Requires -Version 5.1


$STATE_FILE  = "C:\Windows\Temp\clienteAD_state.txt"
$SCRIPT_PATH = $MyInvocation.MyCommand.Path
$TARGET_OU   = "Equipos"

# -------------------------------------------------------------------------
# COLORES Y HELPERS
# -------------------------------------------------------------------------
$ESC    = [char]27
$GREEN  = "$ESC[0;32m"
$RED    = "$ESC[0;31m"
$YELLOW = "$ESC[1;33m"
$BLUE   = "$ESC[0;34m"
$NC     = "$ESC[0m"

function aputs_info    { param($m) Write-Host "${BLUE}[INFO]${NC} $m" }
function aputs_success { param($m) Write-Host "${GREEN}[OK]${NC}   $m" }
function aputs_warning { param($m) Write-Host "${YELLOW}[WARN]${NC} $m" }
function aputs_error   { param($m) Write-Host "${RED}[ERR]${NC}  $m" }
function draw_line     { Write-Host "────────────────────────────────────────────────" }
function draw_header   {
    param([string]$Title)
    Write-Host ""; draw_line
    Write-Host "  $Title"
    draw_line; Write-Host ""
}
function pause_menu { Write-Host ""; Read-Host "  Presiona Enter para continuar..." }

# -------------------------------------------------------------------------
# ESTADO
# -------------------------------------------------------------------------
function Get-ClientState {
    if (-not (Test-Path $STATE_FILE)) { return "INIT" }
    $s = Get-Content $STATE_FILE -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($s)) { return "INIT" }
    return @($s)[0].Trim()
}

function Set-ClientState {
    param([string]$State)
    $State | Out-File $STATE_FILE -Encoding UTF8 -Force
    aputs_info "Estado: $State"
}

# -------------------------------------------------------------------------
# DETECTAR CONFIGURACION DEL DOMINIO
# Lee la informacion del dominio desde el registro una vez unido
# -------------------------------------------------------------------------
function Get-DomainConfig {
    $cs = Get-WmiObject Win32_ComputerSystem
    $domain = $cs.Domain
    if ($domain -eq "WORKGROUP" -or [string]::IsNullOrEmpty($domain)) {
        return $null
    }

    # Obtener IP del DC buscando en DNS
    $dcIP = $null
    try {
        $dcRecord = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$domain" `
                    -Type SRV -ErrorAction Stop | Select-Object -First 1
        $dcHostname = $dcRecord.NameTarget
        $dcIP = (Resolve-DnsName -Name $dcHostname -ErrorAction Stop |
                 Where-Object { $_.Type -eq "A" } |
                 Select-Object -First 1).IPAddress
    } catch {
        # Fallback: buscar DC en la misma subred que el adaptador interno
        $internalIP = (Get-NetIPAddress -AddressFamily IPv4 |
                       Where-Object { $_.IPAddress -like "192.168.*" -and
                                      $_.IPAddress -notlike "192.168.70.*" -and
                                      $_.IPAddress -notlike "192.168.75.*" } |
                       Select-Object -First 1).IPAddress
        if ($internalIP) {
            $subnet = ($internalIP -split "\.")[0..2] -join "."
            # El DC tipicamente termina en .20
            $candidates = @("$subnet.20", "$subnet.1", "$subnet.10")
            foreach ($c in $candidates) {
                if (Test-Connection -ComputerName $c -Count 1 -Quiet) {
                    $dcIP = $c
                    break
                }
            }
        }
    }

    return @{
        Domain   = $domain
        NetBIOS  = ($domain.Split(".")[0]).ToUpper()
        DcIP     = $dcIP
    }
}

# -------------------------------------------------------------------------
# PASO 1: CONFIGURAR RED
# Detecta automaticamente el adaptador de red interna
# -------------------------------------------------------------------------
function Step-ConfigurarRed {
    draw_header "Paso 1/2: Configurar Red y DNS"

    # Detectar adaptador en subred interna (no NAT ni Host-Only)
    $ifaceAlias = $null
    $currentIP  = $null
    foreach ($a in (Get-NetAdapter | Where-Object { $_.Status -eq "Up" })) {
        $ip = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 `
               -ErrorAction SilentlyContinue).IPAddress
        if ($ip -and $ip -notlike "192.168.70.*" -and $ip -notlike "192.168.75.*" `
            -and $ip -notlike "127.*" -and $ip -notlike "169.*") {
            $ifaceAlias = $a.Name
            $currentIP  = $ip
            aputs_info "Adaptador Red_Sistemas detectado: $ifaceAlias (IP actual: $ip)"
            break
        }
    }

    if ($null -eq $ifaceAlias) {
        # No tiene IP interna aun — tomar el primer adaptador Up que no sea loopback
        foreach ($a in (Get-NetAdapter | Where-Object { $_.Status -eq "Up" })) {
            $ip = (Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 `
                   -ErrorAction SilentlyContinue).IPAddress
            if ($ip -and $ip -notlike "127.*") {
                $ifaceAlias = $a.Name
                aputs_info "Adaptador candidato: $ifaceAlias"
                break
            }
        }
    }

    if ($null -eq $ifaceAlias) {
        aputs_error "No se pudo identificar el adaptador de red interno."
        Get-NetAdapter | Format-Table Name, Status -AutoSize
        return $null
    }

    # Pedir IP si no tiene una en subred interna
    if ($null -eq $currentIP -or $currentIP -like "192.168.70.*" -or $currentIP -like "192.168.75.*") {
        $clientIP = Read-Host "  IP estatica para este cliente (ej: 192.168.100.40)"
        if ([string]::IsNullOrWhiteSpace($clientIP)) {
            aputs_error "IP no proporcionada."
            return $null
        }
        Get-NetIPAddress -InterfaceAlias $ifaceAlias -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceAlias $ifaceAlias -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceAlias $ifaceAlias -AddressFamily IPv4 `
            -IPAddress $clientIP -PrefixLength 24 -ErrorAction Stop | Out-Null
        aputs_success "IP configurada: $clientIP/24"
    } else {
        aputs_info "IP ya configurada: $currentIP"
        $clientIP = $currentIP
    }

    # Fijar metrica para que sea la interfaz preferida
    Set-NetIPInterface -InterfaceAlias $ifaceAlias -InterfaceMetric 10 `
        -AutomaticMetric Disabled -ErrorAction SilentlyContinue

    # Pedir IP del DC para configurar DNS
    $dcIP = Read-Host "  IP del servidor DC (ej: 192.168.100.20)"
    if ([string]::IsNullOrWhiteSpace($dcIP)) {
        aputs_error "IP del DC no proporcionada."
        return $null
    }

    Set-DnsClientServerAddress -InterfaceAlias $ifaceAlias `
        -ServerAddresses $dcIP -ErrorAction SilentlyContinue
    aputs_success "DNS configurado: $dcIP"

    # Deshabilitar registro DNS en otras interfaces
    foreach ($a in (Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.Name -ne $ifaceAlias })) {
        Set-DnsClient -InterfaceAlias $a.Name `
            -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 3

    if (-not (Test-Connection -ComputerName $dcIP -Count 2 -Quiet)) {
        aputs_error "No se puede alcanzar el DC en $dcIP"
        return $null
    }
    aputs_success "DC alcanzable: $dcIP"

    # Obtener nombre del dominio via DNS
    $domainName = Read-Host "  Nombre del dominio (ej: reprobados.local)"
    $resolve = Resolve-DnsName $domainName -ErrorAction SilentlyContinue
    if ($null -eq $resolve) {
        aputs_error "No se puede resolver $domainName"
        return $null
    }
    aputs_success "DNS resuelve $domainName correctamente"

    return @{
        IfaceAlias = $ifaceAlias
        ClientIP   = $clientIP
        DcIP       = $dcIP
        Domain     = $domainName
        NetBIOS    = ($domainName.Split(".")[0]).ToUpper()
    }
}

# -------------------------------------------------------------------------
# PASO 2: UNIR AL DOMINIO
# -------------------------------------------------------------------------
function Step-UnirDominio {
    param([hashtable]$NetConfig)

    draw_header "Paso 2/2: Unir al Dominio $($NetConfig.Domain)"

    $currentDomain = (Get-WmiObject Win32_ComputerSystem).Domain
    if ($currentDomain -eq $NetConfig.Domain) {
        aputs_success "El equipo ya esta unido a $($NetConfig.Domain)"
        Set-ClientState "JOINED"
        return $true
    }

    aputs_warning "El equipo se reiniciara al completar la union."

    $cred = Get-Credential `
        -UserName "$($NetConfig.NetBIOS)\Administrador" `
        -Message  "Contrasena del Administrador del dominio $($NetConfig.Domain)"

    if ($null -eq $cred) {
        aputs_error "No se proporcionaron credenciales."
        return $false
    }

    try {
        Add-Computer -DomainName $NetConfig.Domain -Credential $cred -Force -ErrorAction Stop
        aputs_success "Union al dominio completada."
    } catch {
        aputs_error "Error al unirse: $($_.Exception.Message)"
        return $false
    }

    # Mover equipo a OU=Equipos ANTES del reinicio
    aputs_info "Moviendo equipo a OU=$TARGET_OU en el servidor..."
    try {
        $moveResult = Invoke-Command `
            -ComputerName $NetConfig.DcIP `
            -Credential   $cred `
            -ErrorAction  Stop `
            -ScriptBlock  {
                param($computerName, $targetOU, $domain)
                Import-Module ActiveDirectory -ErrorAction SilentlyContinue
                $waited = 0
                $computer = $null
                while ($null -eq $computer -and $waited -lt 30) {
                    Start-Sleep -Seconds 3
                    $waited += 3
                    $computer = Get-ADComputer -Filter "Name -eq '$computerName'" `
                                -ErrorAction SilentlyContinue
                }
                if ($null -eq $computer) {
                    return @{ Ok = $false; Msg = "Equipo no encontrado en AD despues de 30s" }
                }
                $targetDN = "OU=$targetOU,DC=$($domain.Replace('.', ',DC='))"
                if ($computer.DistinguishedName -like "*$targetOU*") {
                    return @{ Ok = $true; Msg = "Ya en $targetDN" }
                }
                try {
                    Move-ADObject -Identity $computer.DistinguishedName `
                                  -TargetPath $targetDN -ErrorAction Stop
                    return @{ Ok = $true; Msg = "Movido a $targetDN" }
                } catch {
                    return @{ Ok = $false; Msg = $_.Exception.Message }
                }
            } -ArgumentList $env:COMPUTERNAME, $TARGET_OU, $NetConfig.Domain

        if ($moveResult.Ok) {
            aputs_success "Equipo movido: $($moveResult.Msg)"
        } else {
            aputs_warning "PSRemoting fallo: $($moveResult.Msg)"
            aputs_info    "Mueva el equipo manualmente en el servidor:"
            aputs_info    "  Move-ADObject -Identity 'CN=$env:COMPUTERNAME,CN=Computers,...' -TargetPath 'OU=$TARGET_OU,...'"
        }
    } catch {
        aputs_warning "PSRemoting no disponible: $($_.Exception.Message)"
        aputs_info    "Mueva el equipo manualmente a OU=$TARGET_OU antes de encender el cliente"
    }

    # Guardar config de red para post-reinicio
    @{
        DcIP    = $NetConfig.DcIP
        Domain  = $NetConfig.Domain
        NetBIOS = $NetConfig.NetBIOS
    } | ConvertTo-Json | Out-File "C:\Windows\Temp\clienteAD_netconfig.json" -Force

    # Tarea programada para post-reinicio
    $taskAction = New-ScheduledTaskAction `
        -Execute  "PowerShell.exe" `
        -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$SCRIPT_PATH`""
    $taskTrigger  = New-ScheduledTaskTrigger -AtStartup
    $taskSettings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -RestartCount 1 `
        -RestartInterval (New-TimeSpan -Minutes 1)
    try {
        Register-ScheduledTask -TaskName "ClienteAD-PostUnion" `
            -Action $taskAction -Trigger $taskTrigger `
            -RunLevel Highest -User "SYSTEM" `
            -Settings $taskSettings -Force | Out-Null
        aputs_success "Tarea programada registrada para post-reinicio"
    } catch {
        aputs_warning "No se pudo registrar tarea: $($_.Exception.Message)"
    }

    Set-ClientState "JOINED"
    aputs_warning "Reiniciando en 10 segundos..."
    Start-Sleep -Seconds 10
    Restart-Computer -Force
    return $true
}

function Step-ConfigurarAppLocker {
    draw_header "Configuracion AppLocker Local"

    # Leer config de red guardada
    $netConfigPath = "C:\Windows\Temp\clienteAD_netconfig.json"
    $netConfig = $null
    if (Test-Path $netConfigPath) {
        $netConfig = Get-Content $netConfigPath | ConvertFrom-Json
    }

    if ($null -eq $netConfig) {
        $domainConfig = Get-DomainConfig
        if ($null -eq $domainConfig) {
            aputs_error "No se pudo obtener configuracion del dominio."
            return $false
        }
        $netConfig = $domainConfig
    }

    aputs_info "Dominio: $($netConfig.Domain)"

    # Iniciar AppIDSvc
    aputs_info "Iniciando AppIDSvc..."
    sc.exe config AppIDSvc start= auto 2>&1 | Out-Null
    sc.exe start  AppIDSvc        2>&1 | Out-Null
    Start-Sleep -Seconds 5
    $svc = Get-Service AppIDSvc -ErrorAction SilentlyContinue
    if ($svc.Status -eq "Running") {
        aputs_success "AppIDSvc: Running"
    } else {
        aputs_warning "AppIDSvc no arranco — reintentando..."
        Start-Sleep -Seconds 5
        sc.exe start AppIDSvc 2>&1 | Out-Null
    }

    # Forzar GPOs para obtener informacion del dominio
    aputs_info "Aplicando GPOs del dominio..."
    gpupdate /force 2>&1 | Out-Null

    # Obtener SID de GRP_NoCuates desde AD
    aputs_info "Obteniendo SID de GRP_NoCuates desde AD..."
    $sidNoCuates = $null
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $sidNoCuates = (Get-ADGroup "GRP_NoCuates" -ErrorAction Stop).SID.Value
        aputs_success "SID GRP_NoCuates: $sidNoCuates"
    } catch {
        # Si el modulo AD no esta disponible, obtener via LDAP
        aputs_warning "Modulo AD no disponible, intentando via DirectorySearcher..."
        try {
            $searcher = New-Object System.DirectoryServices.DirectorySearcher
            $searcher.Filter = "(&(objectClass=group)(sAMAccountName=GRP_NoCuates))"
            $result = $searcher.FindOne()
            if ($result) {
                $sidBytes = $result.Properties["objectsid"][0]
                $sid = New-Object System.Security.Principal.SecurityIdentifier($sidBytes, 0)
                $sidNoCuates = $sid.Value
                aputs_success "SID GRP_NoCuates (LDAP): $sidNoCuates"
            }
        } catch {
            aputs_error "No se pudo obtener SID de GRP_NoCuates: $($_.Exception.Message)"
            aputs_info  "Verifique que el equipo esta unido al dominio y AD es accesible"
            return $false
        }
    }

    if ($null -eq $sidNoCuates) {
        aputs_error "SID de GRP_NoCuates no obtenido. No se puede continuar."
        return $false
    }

    # Calcular hashes de notepad.exe en el cliente
    # Se calculan localmente para garantizar que coinciden con los binarios del sistema
    aputs_info "Calculando hashes de notepad.exe en este cliente..."
    $notepadPaths = @(
        "$env:SystemRoot\System32\notepad.exe",
        "$env:SystemRoot\SysWOW64\notepad.exe"
    )

    $notepadHashes = @()
    foreach ($path in $notepadPaths) {
        if (Test-Path $path) {
            try {
                $info = Get-AppLockerFileInformation -Path $path -ErrorAction Stop
                $hash = $info.Hash.HashDataString
                $len  = (Get-Item $path).Length
                $notepadHashes += @{ Path = $path; Hash = $hash; Length = $len }
                aputs_success "Hash: $path -> $hash"
            } catch {
                aputs_warning "No se pudo obtener hash de $path"
            }
        }
    }

    if ($notepadHashes.Count -eq 0) {
        aputs_error "No se pudo calcular ningun hash de notepad.exe"
        return $false
    }

    # Construir reglas de hash Deny para NoCuates
    $denyRules = ""
    $ruleIndex = 1
    foreach ($np in $notepadHashes) {
        $ruleId = "c4d7e8f1-5678-4def-abcd-00000000000$ruleIndex"
        $denyRules += @"

    <FileHashRule
      Id="$ruleId"
      Name="Bloquear Notepad NoCuates - $([System.IO.Path]::GetDirectoryName($np.Path) | Split-Path -Leaf)"
      Description="Deny notepad.exe por hash SHA256 para GRP_NoCuates"
      UserOrGroupSid="$sidNoCuates"
      Action="Deny">
      <Conditions>
        <FileHashCondition>
          <FileHash Type="SHA256"
                    Data="$($np.Hash)"
                    SourceFileLength="$($np.Length)"
                    SourceFileName="notepad.exe" />
        </FileHashCondition>
      </Conditions>
    </FileHashRule>
"@
        $ruleIndex++
    }

    # XML completo de AppLocker
    # CRITICO: Las reglas Allow usan $sidNoCuates en lugar de S-1-1-0 (Everyone).
    # Si se usa Everyone en Allow y el SID del grupo en Deny por hash,
    # en Win10 19045 Allow sigue ganando porque Everyone incluye al grupo.
    # Al usar el SID del grupo en AMBAS reglas (Allow y Deny), el motor
    # de AppLocker local evalua correctamente: Deny hash tiene precedencia
    # sobre Allow ruta para el mismo usuario/grupo.
    $appLockerXml = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Appx" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Dll" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule
      Id="fd686d83-a829-4351-8ff4-27c7de5755d2"
      Name="Permitir Administradores sin restriccion"
      Description="Administradores pueden ejecutar cualquier aplicacion"
      UserOrGroupSid="S-1-5-32-544"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000010"
      Name="Permitir Windows a NoCuates"
      Description="Permite ejecutar desde WINDIR al grupo NoCuates - SID especifico"
      UserOrGroupSid="$sidNoCuates"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="%WINDIR%\*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000011"
      Name="Permitir Program Files a NoCuates"
      Description="Permite ejecutar desde Program Files al grupo NoCuates"
      UserOrGroupSid="$sidNoCuates"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="%PROGRAMFILES%\*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000012"
      Name="Permitir Program Files x86 a NoCuates"
      Description="Permite ejecutar desde Program Files x86 al grupo NoCuates"
      UserOrGroupSid="$sidNoCuates"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="%PROGRAMFILES(X86)%\*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000020"
      Name="Permitir Windows a Cuates"
      Description="Permite ejecutar desde WINDIR a usuarios Cuates (S-1-1-0 sin notepad Deny)"
      UserOrGroupSid="S-1-1-0"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="%WINDIR%\*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000021"
      Name="Permitir Program Files a Cuates"
      Description="Permite ejecutar desde Program Files a todos"
      UserOrGroupSid="S-1-1-0"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="%PROGRAMFILES%\*" />
      </Conditions>
    </FilePathRule>$denyRules
  </RuleCollection>
  <RuleCollection Type="MsiInstaller" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Script" EnforcementMode="NotConfigured" />
</AppLockerPolicy>
"@

    # Guardar XML localmente
    $xmlPath = "C:\Windows\Temp\AppLocker_Local.xml"
    $appLockerXml | Out-File $xmlPath -Encoding UTF8 -Force
    aputs_info "XML de AppLocker guardado: $xmlPath"

    # Limpiar politicas GPO anteriores que puedan interferir
    aputs_info "Limpiando politicas AppLocker anteriores..."
    $basePath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2"
    if (Test-Path $basePath) {
        Remove-Item -Path $basePath -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $basePath -Force | Out-Null

    # Aplicar politica localmente
    aputs_info "Aplicando politica AppLocker localmente..."
    try {
        Set-AppLockerPolicy -XmlPolicy $xmlPath -ErrorAction Stop
        aputs_success "Politica AppLocker aplicada"
    } catch {
        aputs_error "Error al aplicar politica: $($_.Exception.Message)"
        return $false
    }

    # Reiniciar AppIDSvc para que cargue las nuevas reglas
    aputs_info "Reiniciando AppIDSvc para cargar nuevas reglas..."
    sc.exe stop AppIDSvc 2>&1 | Out-Null
    Start-Sleep -Seconds 5
    sc.exe start AppIDSvc 2>&1 | Out-Null
    Start-Sleep -Seconds 10

    # Verificar que las reglas cargaron
    $ruleCount = (Get-AppLockerPolicy -Effective -Xml | `
        Select-String "FileHashRule|FilePathRule" | Measure-Object).Count
    if ($ruleCount -gt 0) {
        aputs_success "AppLocker activo: $ruleCount reglas cargadas"
    } else {
        aputs_warning "AppLocker no muestra reglas aun. Puede tardar hasta 2 minutos."
    }

    # Eliminar tarea programada de post-union (ya no se necesita)
    Unregister-ScheduledTask -TaskName "ClienteAD-PostUnion" `
        -Confirm:$false -ErrorAction SilentlyContinue

    # Registrar tarea de arranque para pre-cargar AppLocker antes del primer login
    aputs_info "Registrando tarea de arranque para pre-carga de AppLocker..."
    Register-AppLockerBootTask | Out-Null

    Set-ClientState "DONE"
    aputs_success "Configuracion AppLocker completada."
    aputs_info    "IMPORTANTE: Apaga completamente la VM y enciendela para probar."
    aputs_info    "  NoCuates (user06-10): notepad BLOQUEADO por hash"
    aputs_info    "  Cuates   (user01-05): notepad PERMITIDO"
    return $true
}

# -------------------------------------------------------------------------
# MENU DE VERIFICACION
# -------------------------------------------------------------------------
function Show-MenuVerificacion {
    draw_header "Cliente AD v2 — Verificacion"

    $domain = (Get-WmiObject Win32_ComputerSystem).Domain
    $svc    = Get-Service "AppIDSvc" -ErrorAction SilentlyContinue
    $svcSt  = if ($svc.Status -eq "Running") { "${GREEN}Running${NC}" } else { "${RED}Stopped${NC}" }
    $ruleCount = (Get-AppLockerPolicy -Effective -Xml | `
        Select-String "FileHashRule|FilePathRule" | Measure-Object).Count

    Write-Host "  Equipo:   $env:COMPUTERNAME"
    Write-Host "  Dominio:  $domain"
    Write-Host "  AppIDSvc: $svcSt"
    Write-Host "  Reglas AppLocker activas: $ruleCount"
    Write-Host "  Hora: $(Get-Date -Format 'HH:mm')"
    Write-Host ""
    Write-Host "  ${BLUE}1)${NC} Re-aplicar AppLocker local"
    Write-Host "  ${BLUE}2)${NC} Ver reglas efectivas"
    Write-Host "  ${BLUE}3)${NC} Re-aplicar GPOs (gpupdate)"
    Write-Host "  ${BLUE}4)${NC} Ver ultimos eventos AppLocker"
    Write-Host "  ${BLUE}5)${NC} Re-registrar tarea de arranque AppLocker"
    Write-Host "  ${BLUE}0)${NC} Salir"
    Write-Host ""

    $op = Read-Host "  Opcion"
    switch ($op) {
        "1" {
            Set-ClientState "JOINED"
            Step-ConfigurarAppLocker
            pause_menu
        }
        "2" {
            Get-AppLockerPolicy -Effective | Format-List
            Get-AppLockerPolicy -Effective -Xml
            pause_menu
        }
        "3" {
            gpupdate /force
            sc.exe start AppIDSvc 2>&1 | Out-Null
            aputs_success "GPOs actualizadas."
            pause_menu
        }
        "4" {
            Get-WinEvent -LogName "Microsoft-Windows-AppLocker/EXE and DLL" -MaxEvents 10 |
                Select-Object TimeCreated, Id, Message | Format-List
            pause_menu
        }
        "5" {
            aputs_info "Re-registrando tarea de arranque para AppLocker..."
            Register-AppLockerBootTask
            aputs_info "En el proximo arranque, AppLocker estara listo antes del primer login."
            pause_menu
        }
        "0" { return }
    }
}

function Register-AppLockerBootTask {
    $taskName   = "AppLocker-PrecargarReglas"
    $scriptBlock = @'
Start-Sleep -Seconds 10
sc.exe stop AppIDSvc | Out-Null
Start-Sleep -Seconds 3
sc.exe start AppIDSvc | Out-Null
Start-Sleep -Seconds 20
'@
    # Guardar el script en disco para que la tarea lo ejecute
    $bootScriptPath = "C:\Windows\Temp\AppLocker_Boot.ps1"
    $scriptBlock | Out-File -FilePath $bootScriptPath -Encoding UTF8 -Force

    $action = New-ScheduledTaskAction `
        -Execute  "PowerShell.exe" `
        -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$bootScriptPath`""

    # AtStartup: se ejecuta cuando el sistema arranca, antes del login
    $trigger = New-ScheduledTaskTrigger -AtStartup

    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
        -RestartCount 1 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -StartWhenAvailable $true

    try {
        Register-ScheduledTask `
            -TaskName $taskName `
            -Action   $action `
            -Trigger  $trigger `
            -RunLevel Highest `
            -User     "SYSTEM" `
            -Settings $settings `
            -Force    | Out-Null

        aputs_success "Tarea '$taskName' registrada — AppLocker listo antes del primer login"
        Write-ADLog "Tarea $taskName registrada para pre-carga de AppLocker" "SUCCESS"
        return $true
    } catch {
        aputs_warning "No se pudo registrar tarea de arranque: $($_.Exception.Message)"
        return $false
    }
}

# 
# PUNTO DE ENTRADA
# 
Clear-Host
draw_header "Cliente Windows 10 v2 — Tarea 08 Active Directory"
Write-Host "  Equipo: $env:COMPUTERNAME"
Write-Host "  Fecha:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
draw_line

# Verificar privilegios
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    aputs_error "Requiere privilegios de Administrador."
    exit 1
}

$state = Get-ClientState
aputs_info "Estado: $state"
Write-Host ""

switch ($state) {
    "JOINED" {
        aputs_info "Post-reinicio detectado. Configurando AppLocker..."
        Step-ConfigurarAppLocker
        Write-Host ""
        aputs_success "Listo. Apaga la VM completamente y enciendela."
        aputs_info    "Espera 2 minutos despues del arranque antes de probar."
        pause_menu
    }
    "DONE" {
        Show-MenuVerificacion
    }
    default {
        # Primera ejecucion — configurar red y unirse al dominio
        $netConfig = Step-ConfigurarRed
        if ($null -eq $netConfig) {
            aputs_error "Error en red. Corrija y vuelva a ejecutar."
            pause_menu
            exit 1
        }
        Write-Host ""
        Step-UnirDominio -NetConfig $netConfig
    }
}