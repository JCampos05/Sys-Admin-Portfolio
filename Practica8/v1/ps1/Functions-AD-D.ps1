#
# Functions-AD-D.ps1
#
# Responsabilidad: Instalar y configurar el Administrador de Recursos del
# Servidor de Archivos (File Server Resource Manager - FSRM) para:
#   1. Aplicar cuotas de disco estrictas por carpeta de usuario
#   2. Bloquear el guardado de archivos con extensiones prohibidas
#
# Que es FSRM:
#   FSRM es un rol de Windows Server que monitorea el almacenamiento de forma
#   activa. A diferencia de los permisos NTFS (que controlan quien puede acceder),
#   FSRM controla CUANTO y QUE TIPO de archivos pueden existir en una carpeta.
#
# Dos componentes principales de FSRM en esta practica:
#
# Cuotas (Quotas):
#   Limita el espacio total que puede ocupar una carpeta.
#   Cuota "Hard" (estricta) = el sistema rechaza fisicamente el archivo
#   cuando se alcanza el limite. El usuario recibe un error de disco lleno.
#   Cuota "Soft" = solo genera una alerta pero permite seguir escribiendo.
#   En esta practica se usan cuotas HARD (estrictas) segun la rubrica.
#
# Apantallamiento de Archivos (File Screening):
#   Bloquea la creacion de archivos segun su extension dentro de una carpeta.
#   "Active Screening" = bloqueo activo (el archivo no se puede guardar)
#   "Passive Screening" = solo genera un evento en el log pero no bloquea
#   En esta practica se usa Active Screening (bloqueo real).
#
# Cuotas por grupo:
#   GRP_Cuates:   10 MB por carpeta de usuario en C:\Perfiles\<usuario>
#   GRP_NoCuates:  5 MB por carpeta de usuario en C:\Perfiles\<usuario>
#
# Extensiones bloqueadas para todos:
#   Multimedia: .mp3, .mp4
#   Ejecutables: .exe, .msi
#
# Funciones:
#   Install-FSRMRole               - Instala el rol FSRM si no esta presente
#   New-QuotaTemplates             - Crea las plantillas de cuota de 5 MB y 10 MB
#   Set-UserQuotas                 - Aplica la cuota correcta a cada carpeta segun grupo
#   New-BlockedFilesGroup          - Crea el grupo de tipos de archivo bloqueados
#   New-FileScreenTemplate         - Crea la plantilla de apantallamiento
#   Set-FileScreens                - Aplica el apantallamiento a todas las carpetas
#   Invoke-PhaseD                  - Funcion principal que orquesta esta fase
#

#Requires -Version 5.1

. "$PSScriptRoot\utils.ps1"
. "$PSScriptRoot\utilsAD.ps1"

# Nombres de las plantillas de cuota (constantes para reutilizar en todo el archivo)
$script:QUOTA_TEMPLATE_10MB = "Cuota-10MB-Cuates"
$script:QUOTA_TEMPLATE_5MB  = "Cuota-5MB-NoCuates"
$script:FILEGROUP_NAME      = "ArchivosProhibidos-T08"
$script:FILESCREEN_TEMPLATE = "Pantalla-Prohibidos-T08"

# -------------------------------------------------------------------------
# Install-FSRMRole
# Instala el rol "FS-Resource-Manager" (File Server Resource Manager).
# Este rol no viene instalado por defecto en Windows Server.
# Sin el, los cmdlets New-FsrmQuota, New-FsrmFileScreen etc. no existen.
# La instalacion es idempotente: si ya esta instalado, no hace nada.
# Retorna: $true si el rol quedo instalado, $false si hubo error.
# -------------------------------------------------------------------------
function Install-FSRMRole {
    aputs_info "Verificando rol FSRM (File Server Resource Manager)..."

    if (Test-WindowsFeatureInstalled "FS-Resource-Manager") {
        aputs_success "Rol FSRM ya esta instalado."
        Write-ADLog "Rol FSRM verificado como ya instalado" "INFO"
        return $true
    }

    aputs_info "Instalando rol FSRM. Esto puede tardar unos minutos..."
    Write-ADLog "Instalando rol FS-Resource-Manager" "INFO"

    try {
        $result = Install-WindowsFeature `
            -Name FS-Resource-Manager `
            -IncludeManagementTools `
            -ErrorAction Stop

        if ($result.Success) {
            aputs_success "Rol FSRM instalado correctamente."
            Write-ADLog "Rol FSRM instalado con exito" "SUCCESS"
            return $true
        } else {
            aputs_error "La instalacion de FSRM fallo: $($result.ExitCode)"
            return $false
        }
    } catch {
        aputs_error "Excepcion instalando FSRM: $($_.Exception.Message)"
        Write-ADLog "Error instalando FSRM: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# -------------------------------------------------------------------------
# New-QuotaTemplates
# Crea las plantillas de cuota que se usaran para aplicar los limites
# de almacenamiento a las carpetas de los usuarios.
#
# Por que usar plantillas en lugar de cuotas directas:
#   Las plantillas permiten crear una definicion una vez y aplicarla a
#   multiples carpetas. Si el limite cambia, basta con modificar la plantilla
#   y todas las cuotas que la usan se actualizan automaticamente.
#
# Tipo de cuota: HardLimit
#   "Hard" significa que cuando se alcanza el limite, el sistema rechaza
#   fisicamente cualquier escritura adicional. El usuario recibe un error
#   "No hay espacio suficiente en el disco" aunque el disco fisico tenga espacio.
#   Esto es lo que exige la rubrica: "impida guardar un archivo que supere el limite".
#
# Retorna: $true si ambas plantillas quedaron creadas, $false si hubo error.
# -------------------------------------------------------------------------
function New-QuotaTemplates {
    aputs_info "Creando plantillas de cuota FSRM..."
    Write-ADLog "Creando plantillas de cuota 10MB y 5MB" "INFO"

    # --- Plantilla de 10 MB para GRP_Cuates ---
    $existing10 = Get-FsrmQuotaTemplate -Name $script:QUOTA_TEMPLATE_10MB `
                  -ErrorAction SilentlyContinue

    if ($null -ne $existing10) {
        aputs_info "Plantilla '$($script:QUOTA_TEMPLATE_10MB)' ya existe. Omitiendo."
    } else {
        try {
            # 10 MB en bytes = 10 * 1024 * 1024 = 10485760
            $size10MB = 10MB

            New-FsrmQuotaTemplate `
                -Name        $script:QUOTA_TEMPLATE_10MB `
                -Description "Tarea08: Cuota estricta 10 MB para grupo Cuates" `
                -Size        $size10MB `
                -ErrorAction Stop

            aputs_success "Plantilla de cuota 10 MB creada: $($script:QUOTA_TEMPLATE_10MB)"
            Write-ADLog "Plantilla cuota 10MB creada" "SUCCESS"
        } catch {
            aputs_error "Error al crear plantilla 10 MB: $($_.Exception.Message)"
            Write-ADLog "Error plantilla 10MB: $($_.Exception.Message)" "ERROR"
            return $false
        }
    }

    # --- Plantilla de 5 MB para GRP_NoCuates ---
    $existing5 = Get-FsrmQuotaTemplate -Name $script:QUOTA_TEMPLATE_5MB `
                 -ErrorAction SilentlyContinue

    if ($null -ne $existing5) {
        aputs_info "Plantilla '$($script:QUOTA_TEMPLATE_5MB)' ya existe. Omitiendo."
    } else {
        try {
            # 5 MB en bytes = 5 * 1024 * 1024 = 5242880
            $size5MB = 5MB

            New-FsrmQuotaTemplate `
                -Name        $script:QUOTA_TEMPLATE_5MB `
                -Description "Tarea08: Cuota estricta 5 MB para grupo NoCuates" `
                -Size        $size5MB `
                -ErrorAction Stop

            aputs_success "Plantilla de cuota 5 MB creada: $($script:QUOTA_TEMPLATE_5MB)"
            Write-ADLog "Plantilla cuota 5MB creada" "SUCCESS"
        } catch {
            aputs_error "Error al crear plantilla 5 MB: $($_.Exception.Message)"
            Write-ADLog "Error plantilla 5MB: $($_.Exception.Message)" "ERROR"
            return $false
        }
    }

    return $true
}

# -------------------------------------------------------------------------
# Set-UserQuotas
# Aplica la cuota correcta a la carpeta personal de cada usuario segun
# el grupo al que pertenece (Cuates = 10 MB, NoCuates = 5 MB).
#
# Como funciona la aplicacion de cuota:
#   FSRM monitorea la carpeta C:\Perfiles\<usuario> y cuando el contenido
#   total de esa carpeta alcanza el limite configurado (5 o 10 MB), bloquea
#   cualquier intento de escribir mas datos en ella.
#
# Parametros:
#   $CsvPath - Ruta al CSV para conocer el grupo de cada usuario
# Retorna: $true si todas las cuotas fueron aplicadas.
# -------------------------------------------------------------------------
function Set-UserQuotas {
    param(
        [string]$CsvPath
    )

    aputs_info "Aplicando cuotas de disco a carpetas de usuario..."
    Write-ADLog "Aplicando cuotas FSRM por usuario" "INFO"

    try {
        $users = Import-Csv -Path $CsvPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        aputs_error "Error al leer CSV para cuotas: $($_.Exception.Message)"
        return $false
    }

    $okCount    = 0
    $errorCount = 0

    foreach ($row in $users) {
        $samAccount  = $row.Usuario.Trim()
        $department  = $row.Departamento.Trim()
        $folderPath  = "C:\Perfiles\$samAccount"

        # Determinar que plantilla de cuota usar segun el grupo
        switch ($department) {
            "Cuates"   { $templateName = $script:QUOTA_TEMPLATE_10MB }
            "NoCuates" { $templateName = $script:QUOTA_TEMPLATE_5MB }
            default {
                aputs_warning "Departamento desconocido para $samAccount. Omitiendo cuota."
                continue
            }
        }

        # Crear la carpeta si no existe.
        # Puede faltar si la Fase B no completo correctamente por el CSV ausente.
        # La Fase D la crea aqui para ser autosuficiente y no depender de Fase B.
        if (-not (Test-Path $folderPath)) {
            aputs_warning "Carpeta no encontrada para $samAccount. Creando ahora..."
            try {
                New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
                aputs_success "Carpeta creada: $folderPath"
            } catch {
                aputs_error "No se pudo crear carpeta $folderPath : $($_.Exception.Message)"
                $errorCount++
                continue
            }
        }

        # Verificar si ya existe una cuota para esta carpeta (idempotencia)
        $existingQuota = Get-FsrmQuota -Path $folderPath -ErrorAction SilentlyContinue
        if ($null -ne $existingQuota) {
            aputs_info "Cuota ya existe para $samAccount ($folderPath). Actualizando plantilla..."
            try {
                Set-FsrmQuota -Path $folderPath -Template $templateName -ErrorAction Stop
                aputs_success "Cuota actualizada para $samAccount ($department)"
                $okCount++
            } catch {
                aputs_warning "No se pudo actualizar cuota para $samAccount"
                $errorCount++
            }
            continue
        }

        # Crear la cuota nueva usando la plantilla correspondiente
        try {
            New-FsrmQuota `
                -Path     $folderPath `
                -Template $templateName `
                -ErrorAction Stop

            aputs_success "Cuota aplicada a $samAccount ($department): $templateName"
            Write-ADLog "Cuota $templateName aplicada a $folderPath" "SUCCESS"
            $okCount++
        } catch {
            aputs_error "Error al aplicar cuota a $samAccount : $($_.Exception.Message)"
            Write-ADLog "Error cuota $samAccount : $($_.Exception.Message)" "ERROR"
            $errorCount++
        }
    }

    aputs_info "Cuotas aplicadas: $okCount | Errores: $errorCount"
    return ($errorCount -eq 0)
}

# -------------------------------------------------------------------------
# New-BlockedFilesGroup
# Crea el grupo de tipos de archivo que seran bloqueados por el screening.
# Un "File Group" en FSRM es simplemente una lista de patrones de extension
# que se agrupan bajo un nombre para poder referenciarse desde el screening.
#
# Extensiones bloqueadas:
#   *.mp3  - Audio MPEG Layer 3
#   *.mp4  - Video MPEG-4
#   *.exe  - Ejecutable de Windows
#   *.msi  - Paquete de instalacion de Windows
#
# El patron usa wildcards: "*.mp3" bloquea cualquier archivo con esa extension
# independientemente del nombre base del archivo.
#
# Retorna: $true si el grupo fue creado, $false si hubo error.
# -------------------------------------------------------------------------
function New-BlockedFilesGroup {
    aputs_info "Creando grupo de tipos de archivo bloqueados..."
    Write-ADLog "Creando FsrmFileGroup: $($script:FILEGROUP_NAME)" "INFO"

    # Verificar si ya existe (idempotencia)
    $existing = Get-FsrmFileGroup -Name $script:FILEGROUP_NAME -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        aputs_info "Grupo de archivos '$($script:FILEGROUP_NAME)' ya existe. Omitiendo."
        return $true
    }

    try {
        New-FsrmFileGroup `
            -Name          $script:FILEGROUP_NAME `
            -Description   "Tarea08: Archivos multimedia y ejecutables prohibidos" `
            -IncludePattern @("*.mp3", "*.mp4", "*.exe", "*.msi") `
            -ErrorAction Stop

        aputs_success "Grupo de archivos bloqueados creado: $($script:FILEGROUP_NAME)"
        aputs_info    "Patrones bloqueados: *.mp3, *.mp4, *.exe, *.msi"
        Write-ADLog "FsrmFileGroup $($script:FILEGROUP_NAME) creado con patrones prohibidos" "SUCCESS"
        return $true
    } catch {
        aputs_error "Error al crear grupo de archivos: $($_.Exception.Message)"
        Write-ADLog "Error creando FileGroup: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# -------------------------------------------------------------------------
# New-FileScreenTemplate
# Crea la plantilla de apantallamiento (File Screen Template) que define
# como reaccionar cuando se detecta un archivo bloqueado.
#
# Tipo de pantalla: Active (activo)
#   El archivo es rechazado en el momento de la escritura. El usuario
#   recibe un error "Acceso denegado" o similar. El archivo no se guarda.
#
# Un evento queda registrado en el log de FSRM (ID 8215 en Event Viewer)
# lo que proporciona la evidencia para el documento de la rubrica.
#
# Retorna: $true si la plantilla fue creada.
# -------------------------------------------------------------------------
function New-FileScreenTemplate {
    aputs_info "Creando plantilla de apantallamiento de archivos..."
    Write-ADLog "Creando FsrmFileScreenTemplate: $($script:FILESCREEN_TEMPLATE)" "INFO"

    # Verificar idempotencia
    $existing = Get-FsrmFileScreenTemplate -Name $script:FILESCREEN_TEMPLATE `
                -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        aputs_info "Plantilla de screening '$($script:FILESCREEN_TEMPLATE)' ya existe."
        return $true
    }

    try {
        # -Active es un switch en FSRM (no acepta $true como argumento posicional).
        # Simplemente se incluye el switch para activar el bloqueo real.
        New-FsrmFileScreenTemplate `
            -Name         $script:FILESCREEN_TEMPLATE `
            -Description  "Tarea08: Bloqueo activo de multimedia y ejecutables" `
            -Active `
            -IncludeGroup @($script:FILEGROUP_NAME) `
            -ErrorAction Stop

        aputs_success "Plantilla de apantallamiento creada: $($script:FILESCREEN_TEMPLATE)"
        aputs_info    "Tipo: Active Screening (bloqueo real)"
        Write-ADLog "FsrmFileScreenTemplate $($script:FILESCREEN_TEMPLATE) creado" "SUCCESS"
        return $true
    } catch {
        aputs_error "Error al crear plantilla de screening: $($_.Exception.Message)"
        Write-ADLog "Error creando FileScreenTemplate: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# -------------------------------------------------------------------------
# Set-FileScreens
# Aplica el apantallamiento de archivos a la carpeta de cada usuario.
# Cada carpeta C:\Perfiles\<usuario> tendra un File Screen activo que
# rechazara cualquier intento de guardar archivos prohibidos.
#
# Parametros:
#   $CsvPath - Ruta al CSV para obtener la lista de usuarios
# Retorna: $true si todos los screenings fueron aplicados.
# -------------------------------------------------------------------------
function Set-FileScreens {
    param(
        [string]$CsvPath
    )

    aputs_info "Aplicando apantallamiento de archivos a carpetas de usuario..."
    Write-ADLog "Aplicando File Screens a carpetas de C:\Perfiles\" "INFO"

    try {
        $users = Import-Csv -Path $CsvPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        aputs_error "Error al leer CSV para file screening: $($_.Exception.Message)"
        return $false
    }

    $okCount    = 0
    $errorCount = 0

    foreach ($row in $users) {
        $samAccount = $row.Usuario.Trim()
        $folderPath = "C:\Perfiles\$samAccount"

        if (-not (Test-Path $folderPath)) {
            aputs_warning "Carpeta no encontrada para $samAccount. Creando ahora..."
            try {
                New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
                aputs_success "Carpeta creada: $folderPath"
            } catch {
                aputs_error "No se pudo crear carpeta $folderPath : $($_.Exception.Message)"
                $errorCount++
                continue
            }
        }

        # Verificar si ya tiene un screening aplicado (idempotencia)
        $existingScreen = Get-FsrmFileScreen -Path $folderPath -ErrorAction SilentlyContinue
        if ($null -ne $existingScreen) {
            aputs_info "File Screen ya existe para $samAccount. Omitiendo."
            $okCount++
            continue
        }

        try {
            New-FsrmFileScreen `
                -Path     $folderPath `
                -Template $script:FILESCREEN_TEMPLATE `
                -ErrorAction Stop

            aputs_success "File Screen aplicado a: $folderPath"
            Write-ADLog "FileScreen aplicado a $folderPath" "SUCCESS"
            $okCount++
        } catch {
            aputs_error "Error al aplicar File Screen a $samAccount : $($_.Exception.Message)"
            Write-ADLog "Error FileScreen $samAccount : $($_.Exception.Message)" "ERROR"
            $errorCount++
        }
    }

    aputs_info "File Screens aplicados: $okCount | Errores: $errorCount"
    return ($errorCount -eq 0)
}

# -------------------------------------------------------------------------
# Invoke-PhaseD
# Funcion principal de esta fase. Orquesta la instalacion de FSRM y
# la configuracion completa de cuotas y apantallamiento de archivos.
#
# Parametros:
#   $CsvPath - Ruta al CSV de usuarios
# -------------------------------------------------------------------------
function Invoke-PhaseD {
    param(
        [string]$CsvPath = $script:CSV_PATH
    )

    draw_header "Fase D: Gestion de Almacenamiento (FSRM)"
    Write-ADLog "=== INICIO FASE D ===" "INFO"

    # Verificar idempotencia
    $state = Get-InstallState
    if ($state -match "FSRM_DONE|APPLOCKER_DONE") {
        aputs_success "Fase D ya completada (estado: $state). Saltando."
        return $true
    }

    # Paso 1: Instalar el rol FSRM
    aputs_info "Paso 1/5: Instalando rol FSRM..."
    $fsrmOk = Install-FSRMRole
    if (-not $fsrmOk) {
        aputs_error "No se pudo instalar FSRM. Abortando Fase D."
        return $false
    }

    # Paso 2: Crear plantillas de cuota
    aputs_info "Paso 2/5: Creando plantillas de cuota (5 MB y 10 MB)..."
    $templatesOk = New-QuotaTemplates
    if (-not $templatesOk) {
        aputs_error "Error al crear plantillas de cuota. Abortando."
        return $false
    }

    # Paso 3: Aplicar cuotas a carpetas de usuarios
    aputs_info "Paso 3/5: Aplicando cuotas a carpetas de usuario..."
    $quotasOk = Set-UserQuotas -CsvPath $CsvPath
    if (-not $quotasOk) {
        aputs_warning "Algunas cuotas no se aplicaron. Revise el log."
    }

    # Paso 4: Crear grupo de tipos de archivo bloqueados
    aputs_info "Paso 4/5: Creando grupo de tipos de archivo bloqueados..."
    $fileGroupOk = New-BlockedFilesGroup
    if (-not $fileGroupOk) {
        aputs_error "Error al crear el grupo de archivos bloqueados. Abortando."
        return $false
    }

    # Paso 5a: Crear plantilla de apantallamiento
    aputs_info "Paso 5/5: Configurando apantallamiento activo de archivos..."
    $screenTemplateOk = New-FileScreenTemplate
    if (-not $screenTemplateOk) {
        aputs_error "Error al crear plantilla de screening. Abortando."
        return $false
    }

    # Paso 5b: Aplicar apantallamiento a carpetas
    $screensOk = Set-FileScreens -CsvPath $CsvPath
    if (-not $screensOk) {
        aputs_warning "Algunos file screens no se aplicaron. Revise el log."
    }

    Set-InstallState "FSRM_DONE"
    aputs_success "Fase D completada: FSRM, cuotas y apantallamiento configurados."
    Write-ADLog "=== FIN FASE D ===" "SUCCESS"
    return $true
}