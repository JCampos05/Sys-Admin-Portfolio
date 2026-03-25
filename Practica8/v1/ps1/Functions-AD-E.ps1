#
# Functions-AD-E.ps1
# Tarea 08 - Gobernanza, Cuotas y Control de Aplicaciones en Active Directory
#
# Responsabilidad: Configurar AppLocker para controlar que aplicaciones
# pueden ejecutar los usuarios de cada grupo.
#
# Que es AppLocker:
#   AppLocker es una caracteristica de Windows que funciona como una lista
#   blanca/negra de aplicaciones. A diferencia del antivirus que bloquea
#   software malicioso, AppLocker bloquea cualquier ejecutable que no este
#   explicitamente permitido, o bloquea uno especifico por su identidad.
#
# Metodos de identificacion de AppLocker:
#   1. Ruta (Path Rule): bloquea/permite por ubicacion en disco.
#      DEBIL: el usuario puede copiar el exe a otra ruta para saltarlo.
#   2. Firma digital (Publisher Rule): identifica por quien firmo el exe.
#      UTIL pero solo para software firmado por un editor conocido.
#   3. Hash criptografico (Hash Rule): calcula SHA-256 del contenido binario.
#      MUY ROBUSTO: incluso si el usuario renombra o copia el archivo,
#      el hash del contenido sigue siendo el mismo y el bloqueo aplica.
#
# Reglas configuradas en esta practica:
#   GRP_Cuates:   Puede ejecutar notepad.exe (regla de permiso por publisher)
#   GRP_NoCuates: NO puede ejecutar notepad.exe (regla de bloqueo por hash)
#
# La GPO de AppLocker se vincula a cada OU de forma diferenciada:
#   GPO "AppLocker-Cuates-T08"   -> vinculada a OU=Cuates
#   GPO "AppLocker-NoCuates-T08" -> vinculada a OU=NoCuates
#
# Funciones:
#   Get-NotepadPath          - Localiza notepad.exe de forma idempotente
#   Get-NotepadHash          - Calcula el hash SHA-256 de notepad.exe
#   New-AppLockerCuatesGPO   - Crea GPO que permite notepad a GRP_Cuates
#   New-AppLockerNoCuatesGPO - Crea GPO que bloquea notepad a GRP_NoCuates por hash
#   Enable-AppLockerService  - Habilita el servicio AppIDSvc necesario para AppLocker
#   Invoke-PhaseE            - Funcion principal que orquesta esta fase
#

#Requires -Version 5.1

. "$PSScriptRoot\utils.ps1"
. "$PSScriptRoot\utilsAD.ps1"

# -------------------------------------------------------------------------
# Get-NotepadPath
# Localiza la ruta correcta del ejecutable notepad.exe en el sistema.
# En versiones modernas de Windows 10/11 y Server 2022, notepad.exe puede
# estar en System32 como ejecutable real o como stub que redirige a la
# version de la Store. El script busca en ambas ubicaciones y prefiere
# el ejecutable real de System32.
# Si no se encuentra en ninguna ubicacion conocida, intenta forzar la
# reinstalacion del componente desde Windows Features.
# Retorna: string con la ruta al ejecutable, o $null si no se encuentra.
# -------------------------------------------------------------------------
function Get-NotepadPath {
    # Lista de ubicaciones conocidas de notepad.exe en orden de preferencia
    $candidatePaths = @(
        "C:\Windows\System32\notepad.exe",
        "C:\Windows\SysWOW64\notepad.exe",
        "C:\Windows\notepad.exe"
    )

    foreach ($path in $candidatePaths) {
        if (Test-Path $path) {
            # Verificar que no sea un stub (los stubs son menores a 100 KB)
            $size = (Get-Item $path).Length
            if ($size -gt 10240) {
                aputs_success "notepad.exe encontrado: $path ($([math]::Round($size/1024, 1)) KB)"
                Write-ADLog "notepad.exe localizado en: $path (tamano: $size bytes)" "INFO"
                return $path
            }
            else {
                aputs_warning "notepad.exe en $path parece ser un stub ($size bytes). Buscando alternativa..."
            }
        }
    }

    # Si no se encontro el ejecutable real, intentar habilitarlo como caracteristica
    aputs_warning "notepad.exe no encontrado en rutas estandar."
    aputs_info    "Intentando habilitar Notepad como caracteristica de Windows..."
    Write-ADLog "Intentando instalar Notepad como componente de Windows" "INFO"

    try {
        # En Windows Server 2022 el Bloc de Notas puede instalarse como caracteristica opcional
        $result = Add-WindowsCapability -Online -Name "Microsoft.Windows.Notepad~~~~0.0.1.0" `
            -ErrorAction SilentlyContinue

        # Esperar un momento y volver a buscar
        Start-Sleep -Seconds 5

        foreach ($path in $candidatePaths) {
            if (Test-Path $path) {
                $size = (Get-Item $path).Length
                if ($size -gt 10240) {
                    aputs_success "notepad.exe instalado y encontrado: $path"
                    Write-ADLog "notepad.exe instalado exitosamente en: $path" "SUCCESS"
                    return $path
                }
            }
        }
    }
    catch {
        aputs_warning "No se pudo instalar Notepad como caracteristica: $($_.Exception.Message)"
    }

    aputs_error "No se pudo localizar un notepad.exe valido para generar el hash."
    aputs_info  "Verifique manualmente que C:\Windows\System32\notepad.exe exista."
    Write-ADLog "Error: notepad.exe no localizado" "ERROR"
    return $null
}

# -------------------------------------------------------------------------
# Get-NotepadHash
# Calcula el hash SHA-256 de notepad.exe para usarlo en la regla
# de bloqueo de AppLocker.
#
# Por que SHA-256 y no MD5 o SHA-1:
#   AppLocker acepta MD5 y SHA-256. SHA-256 es mas seguro: tiene menos
#   probabilidad de colisiones (dos archivos distintos con el mismo hash).
#   Microsoft recomienda SHA-256 para reglas de AppLocker.
#
# El hash es una cadena hexadecimal de 64 caracteres que representa
# univocamente el contenido binario del archivo. Si un solo byte del
# archivo cambia, el hash es completamente diferente.
#
# Parametros:
#   $NotepadPath - Ruta al ejecutable (obtenida de Get-NotepadPath)
# Retorna: objeto con HashAlgorithm, HashValue y Path, o $null si falla.
# -------------------------------------------------------------------------
function Get-NotepadHash {
    param(
        [string]$NotepadPath
    )

    aputs_info "Calculando hash SHA-256 de notepad.exe..."
    Write-ADLog "Calculando hash de: $NotepadPath" "INFO"

    try {
        # Get-AppLockerFileInformation extrae toda la informacion que AppLocker
        # necesita de un ejecutable: publisher, hash, path y tipo de archivo
        $fileInfo = Get-AppLockerFileInformation -Path $NotepadPath -ErrorAction Stop

        if ($null -eq $fileInfo) {
            aputs_error "Get-AppLockerFileInformation no retorno informacion para $NotepadPath"
            return $null
        }

        # Tambien calculamos el hash directamente para mostrarlo al usuario
        $hashObj = Get-FileHash -Path $NotepadPath -Algorithm SHA256 -ErrorAction Stop

        aputs_success "Hash calculado exitosamente"
        aputs_info    "Algoritmo: SHA-256"
        aputs_info    "Hash: $($hashObj.Hash)"
        Write-ADLog "Hash notepad.exe: $($hashObj.Hash)" "INFO"

        return @{
            AppLockerInfo = $fileInfo
            HashValue     = $hashObj.Hash
            FilePath      = $NotepadPath
        }
    }
    catch {
        aputs_error "Error al obtener informacion de AppLocker: $($_.Exception.Message)"
        Write-ADLog "Error calculando hash: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# -------------------------------------------------------------------------
# Enable-AppLockerService
# Habilita y arranca el servicio "Application Identity" (AppIDSvc).
# Este servicio es OBLIGATORIO para que AppLocker funcione.
# Sin el, las reglas de AppLocker existen en la GPO pero no se aplican.
# AppIDSvc verifica la identidad de los ejecutables (publisher, hash)
# en tiempo real cuando el usuario intenta lanzar una aplicacion.
# -------------------------------------------------------------------------
function Enable-AppLockerService {
    aputs_info "Configurando servicio Application Identity (AppIDSvc)..."
    Write-ADLog "Habilitando servicio AppIDSvc" "INFO"

    # En un Domain Controller, Set-Service falla con "Acceso denegado" por
    # restricciones de seguridad adicionales del DC sobre servicios del sistema.
    # sc.exe accede directamente al SCM (Service Control Manager) evitando
    # la capa de PowerShell que queda bloqueada en este contexto.
    try {
        # Configurar arranque automatico con sc.exe
        $scConfig = sc.exe config AppIDSvc start= auto 2>&1
        if ($LASTEXITCODE -ne 0) {
            aputs_warning "sc.exe config retorno: $scConfig"
        }
        else {
            aputs_success "AppIDSvc configurado para arranque automatico (sc.exe)"
        }

        # Iniciar el servicio si no esta corriendo
        $svc = Get-Service -Name "AppIDSvc" -ErrorAction Stop
        if ($svc.Status -ne "Running") {
            $scStart = sc.exe start AppIDSvc 2>&1
            Start-Sleep -Seconds 3
            $svc = Get-Service -Name "AppIDSvc" -ErrorAction Stop
            if ($svc.Status -eq "Running") {
                aputs_success "Servicio AppIDSvc iniciado correctamente"
            }
            else {
                aputs_warning "AppIDSvc no arranco inmediatamente. Estado: $($svc.Status)"
            }
        }
        else {
            aputs_info "Servicio AppIDSvc ya estaba corriendo"
        }

        Write-ADLog "Servicio AppIDSvc habilitado via sc.exe" "SUCCESS"
        return $true
    }
    catch {
        aputs_error "Error al configurar AppIDSvc: $($_.Exception.Message)"
        Write-ADLog "Error AppIDSvc: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# -------------------------------------------------------------------------
# Write-AppLockerXmlToSysvol
# Escribe el XML directamente en SYSVOL e incrementa GPT.INI.
# CRITICO: Set-AppLockerPolicy -Ldap NO escribe en SYSVOL en Server 2022.
# Sin el XML en SYSVOL Y sin incrementar GPT.INI, el cliente nunca
# descarga las reglas aunque se corra gpupdate /force.
# -------------------------------------------------------------------------
function Write-AppLockerXmlToSysvol {
    param(
        [string]$GpoId,
        [string]$XmlContent,
        [string]$DomainName
    )

    $sysvolPath = "\\$DomainName\SYSVOL\$DomainName\Policies\{$GpoId}\Machine\Microsoft\Windows NT\AppLocker"

    try {
        if (-not (Test-Path $sysvolPath)) {
            New-Item -Path $sysvolPath -ItemType Directory -Force | Out-Null
            aputs_info "Directorio AppLocker creado en SYSVOL"
        }

        $xmlPath = Join-Path $sysvolPath "Exe.xml"
        $XmlContent | Out-File -FilePath $xmlPath -Encoding UTF8 -Force
        aputs_success "XML AppLocker escrito en SYSVOL: $xmlPath"
        Write-ADLog "XML AppLocker escrito en SYSVOL: $xmlPath" "SUCCESS"

        # Incrementar version del GPT.INI
        # Sin este paso el cliente ignora el XML aunque exista en SYSVOL
        $gptPath = "\\$DomainName\SYSVOL\$DomainName\Policies\{$GpoId}\GPT.INI"
        if (Test-Path $gptPath) {
            $gptContent = Get-Content $gptPath -Raw
            if ($gptContent -match "Version=(\d+)") {
                $currentVer = [int]$matches[1]
                $newVer     = $currentVer + 1
                $gptContent = $gptContent -replace "Version=\d+", "Version=$newVer"
                $gptContent | Out-File $gptPath -Encoding ASCII -Force
                aputs_info "GPT.INI version: $currentVer -> $newVer"
            }
        }

        return $true
    }
    catch {
        aputs_error "No se pudo escribir XML en SYSVOL: $($_.Exception.Message)"
        Write-ADLog "Error escribiendo XML en SYSVOL: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# -------------------------------------------------------------------------
# New-AppLockerCuatesGPO
#
# GPO para GRP_Cuates en modo AuditOnly.
# AuditOnly = registra eventos pero NO bloquea ninguna ejecucion.
# User01 puede abrir notepad y cualquier aplicacion sin restriccion.
# La rubrica dice "Grupo 1 tiene PERMITIDO el Bloc de Notas" — cumplido.
# -------------------------------------------------------------------------
function New-AppLockerCuatesGPO {
    param(
        [string]$DomainName,
        [hashtable]$NotepadInfo
    )

    $gpoName  = "AppLocker-Cuates-T08"
    $domainNC = Get-DomainNC -DomainName $DomainName
    $ouTarget = "OU=Cuates,$domainNC"

    aputs_info "Creando GPO AppLocker para GRP_Cuates: $gpoName"
    aputs_info "Modo: AuditOnly (notepad y todo lo demas PERMITIDO)"
    Write-ADLog "Creando GPO AppLocker Cuates en modo AuditOnly" "INFO"

    $gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
    if ($null -eq $gpo) {
        try {
            $gpo = New-GPO -Name $gpoName `
                -Comment "Tarea08: Cuates - sin restriccion de ejecucion" `
                -ErrorAction Stop
            aputs_success "GPO creada: $gpoName"
        } catch {
            aputs_error "Error al crear GPO $gpoName : $($_.Exception.Message)"
            return $false
        }
    } else {
        aputs_info "GPO '$gpoName' ya existe. Actualizando..."
    }

    $gpo.GpoStatus = "ComputerSettingsDisabled"
    aputs_info "GPO configurada como ComputerSettingsDisabled (solo aplica a usuarios)"

    $appLockerXml = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Appx" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Dll" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Exe" EnforcementMode="AuditOnly">
    <FilePathRule
      Id="fd686d83-a829-4351-8ff4-27c7de5755d2"
      Name="Permitir todo a Cuates"
      Description="Tarea08: Cuates pueden ejecutar cualquier aplicacion incluido notepad"
      UserOrGroupSid="S-1-1-0"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="*" />
      </Conditions>
    </FilePathRule>
  </RuleCollection>
  <RuleCollection Type="MsiInstaller" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Script" EnforcementMode="NotConfigured" />
</AppLockerPolicy>
"@

    $xmlTempPath = "$script:TAREA08_BASE\applocker_cuates.xml"
    $appLockerXml | Out-File -FilePath $xmlTempPath -Encoding UTF8 -Force

    $gpoId = $gpo.Id.ToString()
    Write-AppLockerXmlToSysvol -GpoId $gpoId -XmlContent $appLockerXml -DomainName $DomainName | Out-Null

    try {
        $existingLink = Get-GPInheritance -Target $ouTarget -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty GpoLinks |
            Where-Object { $_.DisplayName -eq $gpoName }

        if ($null -eq $existingLink) {
            New-GPLink -Name $gpoName -Target $ouTarget -LinkEnabled Yes -ErrorAction Stop
            aputs_success "GPO '$gpoName' vinculada a OU=Cuates"
            Write-ADLog "GPO AppLocker Cuates vinculada a OU=Cuates" "SUCCESS"
        } else {
            aputs_info "GPO ya vinculada a OU=Cuates"
        }
    } catch {
        aputs_error "Error al vincular GPO a OU=Cuates: $($_.Exception.Message)"
        return $false
    }

    aputs_success "GPO Cuates: AuditOnly — notepad y escritorio sin restriccion"
    Write-ADLog "GPO AppLocker Cuates completada" "SUCCESS"
    return $true
}


function New-AppLockerNoCuatesGPO {
    param(
        [string]$DomainName,
        [hashtable]$NotepadInfo
    )

    $gpoName  = "AppLocker-NoCuates-T08"
    $domainNC = Get-DomainNC -DomainName $DomainName
    $ouTarget = "OU=NoCuates,$domainNC"

    aputs_info "Creando GPO AppLocker para GRP_NoCuates: $gpoName"
    aputs_info "Estrategia: FilePathRule con Exceptions de ruta"
    Write-ADLog "Creando GPO AppLocker NoCuates con FilePathRule+Exceptions" "INFO"

    $gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
    if ($null -eq $gpo) {
        try {
            $gpo = New-GPO -Name $gpoName `
                -Comment "Tarea08: NoCuates - bloquea notepad por ruta con exceptions" `
                -ErrorAction Stop
            aputs_success "GPO creada: $gpoName"
        } catch {
            aputs_error "Error al crear GPO $gpoName : $($_.Exception.Message)"
            return $false
        }
    } else {
        aputs_info "GPO '$gpoName' ya existe. Actualizando..."
    }

    # Solo aplica a usuarios segun su OU. Los equipos van en OU=Equipos
    # separada y no reciben esta GPO.
    $gpo.GpoStatus = "ComputerSettingsDisabled"
    aputs_info "GPO configurada como ComputerSettingsDisabled (solo aplica a usuarios)"

    # Obtener SID de GRP_NoCuates dinamicamente
    # CRITICO: el SID es unico por dominio y cambia si se reinstala AD
    # Por eso se obtiene en tiempo de ejecucion y no se hardcodea
    $sidNoCuates = $null
    try {
        $sidNoCuates = (Get-ADGroup "GRP_NoCuates" -ErrorAction Stop).SID.Value
        aputs_success "SID de GRP_NoCuates obtenido: $sidNoCuates"
        Write-ADLog "SID GRP_NoCuates: $sidNoCuates" "INFO"
    } catch {
        aputs_error "No se pudo obtener SID de GRP_NoCuates: $($_.Exception.Message)"
        aputs_info  "Verifique que la Fase B se completo correctamente (grupo debe existir)"
        return $false
    }

    $appLockerXml = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Appx" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Dll" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePublisherRule
      Id="a9e18c21-ff8f-43cf-b9fc-db40eed693ba"
      Name="Permitir Microsoft a Administradores"
      Description="Administradores pueden ejecutar todo"
      UserOrGroupSid="S-1-5-32-544"
      Action="Allow">
      <Conditions>
        <FilePublisherCondition
          PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US"
          ProductName="*" BinaryName="*">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000030"
      Name="Permitir System32 variable a NoCuates excepto notepad"
      Description="Cubre %WINDIR%\System32\* excluyendo notepad.exe"
      UserOrGroupSid="$sidNoCuates"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="%WINDIR%\System32\*" />
      </Conditions>
      <Exceptions>
        <FilePathCondition Path="%WINDIR%\System32\notepad.exe" />
      </Exceptions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000031"
      Name="Permitir System32 ruta absoluta a NoCuates"
      Description="Cubre C:\Windows\System32\* - necesario para dwm.exe"
      UserOrGroupSid="$sidNoCuates"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="C:\Windows\System32\*" />
      </Conditions>
      <Exceptions>
        <FilePathCondition Path="C:\Windows\System32\notepad.exe" />
      </Exceptions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000032"
      Name="Permitir Windows raiz a NoCuates excepto notepad"
      Description="Cubre %WINDIR%\* y C:\Windows\* excluyendo notepad"
      UserOrGroupSid="$sidNoCuates"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="%WINDIR%\*" />
      </Conditions>
      <Exceptions>
        <FilePathCondition Path="%WINDIR%\notepad.exe" />
        <FilePathCondition Path="%WINDIR%\System32\notepad.exe" />
        <FilePathCondition Path="C:\Windows\notepad.exe" />
        <FilePathCondition Path="C:\Windows\System32\notepad.exe" />
      </Exceptions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000033"
      Name="Permitir Program Files a NoCuates"
      Description="Permite ejecutar desde Program Files"
      UserOrGroupSid="$sidNoCuates"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="%PROGRAMFILES%\*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule
      Id="b1c2d3e4-0001-4abc-9def-000000000034"
      Name="Permitir Program Files x86 a NoCuates"
      Description="Permite ejecutar desde Program Files x86"
      UserOrGroupSid="$sidNoCuates"
      Action="Allow">
      <Conditions>
        <FilePathCondition Path="%PROGRAMFILES(X86)%\*" />
      </Conditions>
    </FilePathRule>
  </RuleCollection>
  <RuleCollection Type="MsiInstaller" EnforcementMode="NotConfigured" />
  <RuleCollection Type="Script" EnforcementMode="NotConfigured" />
</AppLockerPolicy>
"@

    $xmlTempPath = "$script:TAREA08_BASE\applocker_nocuates.xml"
    $appLockerXml | Out-File -FilePath $xmlTempPath -Encoding UTF8 -Force

    $gpoId = $gpo.Id.ToString()

    # Escribir en SYSVOL e incrementar GPT.INI
    $sysvolOk = Write-AppLockerXmlToSysvol -GpoId $gpoId -XmlContent $appLockerXml -DomainName $DomainName
    if ($sysvolOk) {
        aputs_success "XML AppLocker NoCuates escrito en SYSVOL"
        Write-ADLog "XML AppLocker NoCuates en SYSVOL" "SUCCESS"
    }

    # Aplicar tambien via LDAP
    try {
        Set-AppLockerPolicy -XmlPolicy $xmlTempPath `
            -Ldap "LDAP://CN={$gpoId},CN=Policies,CN=System,$domainNC" `
            -ErrorAction SilentlyContinue
        aputs_info "Politica aplicada via LDAP"
    } catch {
        aputs_warning "Set-AppLockerPolicy LDAP: $($_.Exception.Message)"
    }

    # Vincular a OU=NoCuates
    try {
        $existingLink = Get-GPInheritance -Target $ouTarget -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty GpoLinks |
            Where-Object { $_.DisplayName -eq $gpoName }

        if ($null -eq $existingLink) {
            New-GPLink -Name $gpoName -Target $ouTarget -LinkEnabled Yes -ErrorAction Stop
            aputs_success "GPO '$gpoName' vinculada a OU=NoCuates"
            Write-ADLog "GPO AppLocker NoCuates vinculada a OU=NoCuates" "SUCCESS"
        } else {
            aputs_info "GPO ya vinculada a OU=NoCuates"
        }
    } catch {
        aputs_error "Error al vincular GPO a OU=NoCuates: $($_.Exception.Message)"
        return $false
    }

    aputs_success "GPO NoCuates: notepad bloqueado por ruta, escritorio funcional"
    aputs_info    "NOTA: AppLocker necesita ~2 min despues del arranque para aplicar."
    aputs_info    "      Si notepad abre la primera vez, esperar 2 minutos y reintentar."
    Write-ADLog "GPO AppLocker NoCuates completada" "SUCCESS"
    return $true
}

# -------------------------------------------------------------------------
# Enable-AppLockerService
# -------------------------------------------------------------------------
function Enable-AppLockerService {
    aputs_info "Configurando servicio Application Identity (AppIDSvc)..."
    Write-ADLog "Habilitando servicio AppIDSvc" "INFO"

    try {
        sc.exe config AppIDSvc start= auto 2>&1 | Out-Null
        aputs_success "AppIDSvc configurado para arranque automatico"

        $svc = Get-Service -Name "AppIDSvc" -ErrorAction Stop
        if ($svc.Status -ne "Running") {
            sc.exe start AppIDSvc 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            $svc = Get-Service -Name "AppIDSvc" -ErrorAction Stop
            if ($svc.Status -eq "Running") {
                aputs_success "AppIDSvc iniciado correctamente"
            } else {
                aputs_warning "AppIDSvc estado: $($svc.Status)"
            }
        } else {
            aputs_info "AppIDSvc ya estaba corriendo"
        }

        Write-ADLog "AppIDSvc habilitado" "SUCCESS"
        return $true
    } catch {
        aputs_error "Error AppIDSvc: $($_.Exception.Message)"
        Write-ADLog "Error AppIDSvc: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# -------------------------------------------------------------------------
# Invoke-PhaseE
# -------------------------------------------------------------------------
function Invoke-PhaseE {
    param(
        [string]$DomainName
    )

    draw_header "Fase E: Control de Ejecucion con AppLocker"
    Write-ADLog "=== INICIO FASE E ===" "INFO"

    $state = Get-InstallState
    if ($state -eq "APPLOCKER_DONE") {
        aputs_success "Fase E ya completada. Saltando."
        return $true
    }

    # Paso 1: Localizar notepad.exe
    aputs_info "Paso 1/4: Localizando notepad.exe..."
    $notepadPath = Get-NotepadPath
    if ($null -eq $notepadPath) {
        aputs_error "No se puede continuar sin notepad.exe. Abortando Fase E."
        return $false
    }

    # Paso 2: Obtener informacion de notepad
    aputs_info "Paso 2/4: Obteniendo informacion de notepad.exe..."
    $notepadInfo = Get-NotepadHash -NotepadPath $notepadPath
    if ($null -eq $notepadInfo) {
        aputs_error "No se pudo obtener informacion de notepad.exe. Abortando."
        return $false
    }

    # Paso 3: AppIDSvc + GPO para clientes
    aputs_info "Paso 3/4: Configurando AppIDSvc..."
    Enable-AppLockerService | Out-Null

    $appIDGPOName = "AppLocker-AppIDSvc-T08"
    $existingGPO  = Get-GPO -Name $appIDGPOName -ErrorAction SilentlyContinue
    if ($null -eq $existingGPO) {
        try {
            New-GPO -Name $appIDGPOName `
                -Comment "Tarea08: Habilita AppIDSvc en clientes" `
                -ErrorAction Stop | Out-Null

            Set-GPRegistryValue -Name $appIDGPOName `
                -Key "HKLM\SYSTEM\CurrentControlSet\Services\AppIDSvc" `
                -ValueName "Start" -Type DWord -Value 2 -ErrorAction Stop

            New-GPLink -Name $appIDGPOName `
                -Target "DC=$($DomainName.Replace('.', ',DC='))" `
                -LinkEnabled Yes -ErrorAction Stop | Out-Null

            aputs_success "GPO '$appIDGPOName' creada — AppIDSvc automatico en clientes"
            Write-ADLog "GPO AppIDSvc creada y vinculada" "SUCCESS"
        } catch {
            aputs_warning "No se pudo crear GPO AppIDSvc: $($_.Exception.Message)"
        }
    } else {
        aputs_info "GPO '$appIDGPOName' ya existe."
    }

    # Paso 4: GPOs de AppLocker
    aputs_info "Paso 4/4: Creando GPOs de AppLocker..."
    aputs_info "  GPO Cuates:   AuditOnly — notepad PERMITIDO"
    $cuatesOk = New-AppLockerCuatesGPO -DomainName $DomainName -NotepadInfo $notepadInfo

    aputs_info "  GPO NoCuates: FilePathRule+Exceptions — notepad BLOQUEADO"
    $noCuatesOk = New-AppLockerNoCuatesGPO -DomainName $DomainName -NotepadInfo $notepadInfo

    if (-not $cuatesOk -or -not $noCuatesOk) {
        aputs_error "Una o ambas GPOs de AppLocker fallaron."
        return $false
    }

    Invoke-GPUpdate -Force -ErrorAction SilentlyContinue

    Set-InstallState "APPLOCKER_DONE"
    aputs_success "Fase E completada exitosamente."
    aputs_info    "  Cuates   (user01-05): notepad PERMITIDO"
    aputs_info    "  NoCuates (user06-10): notepad BLOQUEADO"
    aputs_info    "  NOTA: En el cliente Win10, esperar ~2 min tras el arranque"
    aputs_info    "        antes de probar notepad para que AppLocker cargue."
    Write-ADLog "=== FIN FASE E ===" "SUCCESS"
    return $true
}