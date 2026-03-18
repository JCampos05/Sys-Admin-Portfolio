#
# FunctionsFTP-C.ps1
# Grupo C — Usuarios y grupos FTP
#
# Requiere: utilsFTP.ps1, subMainFTP.ps1, FunctionsFTP-D.ps1
#

function Load-FtpGroups {
    $script:FTP_GROUPS = @()
    if (-not (Test-Path $script:FTP_GROUPS_FILE)) { return }
    Get-Content $script:FTP_GROUPS_FILE | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith('#')) {
            $script:FTP_GROUPS += $line
        }
    }
}

function Save-FtpGroups {
    if (-not (Test-Path $script:FTP_ROOT)) {
        New-Item -ItemType Directory -Path $script:FTP_ROOT -Force | Out-Null
    }
    $script:FTP_GROUPS | Set-Content $script:FTP_GROUPS_FILE
}

function Request-InitialGroups {
    if ((Test-Path $script:FTP_GROUPS_FILE) -and (Get-Content $script:FTP_GROUPS_FILE | Where-Object { $_.Trim() })) {
        Load-FtpGroups
        msg_info "Grupos existentes: $($script:FTP_GROUPS -join ', ')"
        return
    }

    Write-Separator
    msg_info "Define los grupos FTP (al menos uno). Linea vacia para terminar."
    Write-Separator

    $script:FTP_GROUPS = @()
    while ($true) {
        $grupo = Read-Input "Nombre del grupo (Enter para terminar): "
        if ([string]::IsNullOrWhiteSpace($grupo)) {
            if ($script:FTP_GROUPS.Count -eq 0) { msg_error "Al menos un grupo requerido"; continue }
            break
        }
        if ($grupo -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
            msg_error "Nombre invalido: solo minusculas, numeros, _ y -"
            continue
        }
        if ($script:FTP_GROUPS -contains $grupo) {
            msg_alert "'$grupo' ya esta en la lista"; continue
        }
        $script:FTP_GROUPS += $grupo
        msg_success "Grupo '$grupo' agregado"
    }

    Save-FtpGroups
    msg_success "Grupos guardados: $($script:FTP_GROUPS -join ', ')"
}

function Show-FtpGroups {
    Write-Separator
    msg_info "Grupos FTP:"
    foreach ($grupo in $script:FTP_GROUPS) {
        $dir = "$script:FTP_ROOT\grupos\$grupo"
        Write-Host ""
        Write-Host "  Grupo     : $grupo"
        Write-Host "  Directorio: $dir"
        if (Test-Path $dir) {
            $acl = (Get-Acl $dir).Access | Where-Object { $_.IdentityReference -notlike "*SYSTEM*" -and $_.IdentityReference -notlike "*Administrators*" }
            Write-Host "  Permisos  : $($acl | ForEach-Object { "$($_.IdentityReference): $($_.FileSystemRights)" } | Select-Object -First 3)"
        } else {
            Write-Host "  Directorio: no existe"
        }
        # Miembros desde metadatos
        $miembros = @()
        if (Test-Path $script:FTP_META) {
            $miembros = Get-Content $script:FTP_META | Where-Object { $_ -match ":${grupo}$" } | ForEach-Object { ($_ -split ':')[0] }
        }
        Write-Host "  Miembros  : $(if ($miembros) { $miembros -join ', ' } else { '(sin miembros)' })"
    }
    Write-Host ""
    Write-Separator
    msg_info "Directorio general: $script:FTP_GENERAL"
    if (Test-Path $script:FTP_GENERAL) {
        $acl = (Get-Acl $script:FTP_GENERAL).Access | Where-Object { $_.IdentityReference -like "*$script:FTP_GROUP_ALL*" }
        Write-Host "  Permisos grupo ftp_users: $($acl.FileSystemRights)"
    }
}

function New-FtpGroup {
    Write-Separator
    $nuevoGrupo = Read-Input "Nombre del nuevo grupo: "

    if ([string]::IsNullOrWhiteSpace($nuevoGrupo) -or $nuevoGrupo -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
        msg_error "Nombre invalido"; return
    }
    if ($script:FTP_GROUPS -contains $nuevoGrupo) {
        msg_alert "El grupo '$nuevoGrupo' ya existe"; return
    }

    # Crear grupo local Windows si no existe
    if (-not (Get-LocalGroup -Name $nuevoGrupo -ErrorAction SilentlyContinue)) {
        try {
            New-LocalGroup -Name $nuevoGrupo -Description "Grupo FTP: $nuevoGrupo" -ErrorAction Stop | Out-Null
            msg_success "Grupo local '$nuevoGrupo' creado"
        } catch {
            msg_error "No se pudo crear el grupo local: $_"; return
        }
    }

    # Crear directorio y aplicar permisos
    $dir = "$script:FTP_ROOT\grupos\$nuevoGrupo"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Disable-NtfsInheritance $dir
    Set-NtfsPermission $dir "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $dir "NT AUTHORITY\SYSTEM"    "FullControl"
    Set-NtfsPermission $dir $nuevoGrupo              "Modify"

    $script:FTP_GROUPS += $nuevoGrupo
    Save-FtpGroups
    msg_success "Grupo '$nuevoGrupo' creado"
}

function Remove-FtpGroup {
    Write-Separator
    Show-FtpGroups

    $grupoEliminar = Read-Input "Nombre del grupo a eliminar: "
    if ($script:FTP_GROUPS -notcontains $grupoEliminar) {
        msg_error "Grupo no encontrado"; return
    }
    if ($script:FTP_GROUPS.Count -le 1) {
        msg_error "Debe quedar al menos un grupo"; return
    }

    # Reasignar usuarios del grupo
    $miembros = @()
    if (Test-Path $script:FTP_META) {
        $miembros = Get-Content $script:FTP_META | Where-Object { $_ -match ":${grupoEliminar}$" } | ForEach-Object { ($_ -split ':')[0] }
    }
    if ($miembros.Count -gt 0) {
        msg_info "Usuarios a reasignar: $($miembros -join ', ')"
        $grupoDestino = Select-FtpGroup
        foreach ($u in $miembros) {
            Meta-Set $u $grupoDestino
            Update-FtpUserVirtualDirectories $u $grupoDestino
            # Mover al nuevo grupo local Windows
            try {
                Remove-LocalGroupMember -Group $grupoEliminar -Member $u -ErrorAction SilentlyContinue
                Add-LocalGroupMember    -Group $grupoDestino  -Member $u -ErrorAction SilentlyContinue
            } catch {}
            msg_success "'$u' reasignado a '$grupoDestino'"
        }
    }

    # Eliminar directorio
    $dir = "$script:FTP_ROOT\grupos\$grupoEliminar"
    if (Test-Path $dir) {
        if (Confirm-Action "Eliminar directorio $dir?") {
            Remove-Item $dir -Recurse -Force
            msg_success "Directorio eliminado"
        }
    }

    # Eliminar grupo local Windows
    try { Remove-LocalGroup -Name $grupoEliminar -ErrorAction SilentlyContinue } catch {}

    $script:FTP_GROUPS = $script:FTP_GROUPS | Where-Object { $_ -ne $grupoEliminar }
    Save-FtpGroups
    msg_success "Grupo '$grupoEliminar' eliminado"
}

function Select-FtpGroup {
    while ($true) {
        Write-Host "  Grupos disponibles:"
        for ($i = 0; $i -lt $script:FTP_GROUPS.Count; $i++) {
            Write-Host "    $($i+1)) $($script:FTP_GROUPS[$i])"
        }
        $sel = Read-Input "Selecciona grupo [1-$($script:FTP_GROUPS.Count)]: "
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $script:FTP_GROUPS.Count) {
            return $script:FTP_GROUPS[[int]$sel - 1]
        }
        msg_error "Seleccion invalida"
    }
}

function Manage-GroupDirectoryPermissions {
    Write-Separator
    msg_info "Permisos actuales:"
    Write-Host ""
    foreach ($path in @($script:FTP_ROOT, $script:FTP_GENERAL)) {
        if (Test-Path $path) {
            Write-Host "  $path"
        }
    }
    foreach ($grupo in $script:FTP_GROUPS) {
        $d = "$script:FTP_ROOT\grupos\$grupo"
        Write-Host "  $d $(if (-not (Test-Path $d)) { '(no existe)' })"
    }
    Write-Separator
    Repair-FtpPermissions
}

function Repair-FtpGroupMemberships {
    Write-Separator
    msg_process "Verificando grupos de usuarios FTP..."
    if (-not (Test-Path $script:FTP_META)) { msg_alert "No hay usuarios registrados"; return }

    Get-Content $script:FTP_META | ForEach-Object {
        if ($_ -match '^(.+):(.+)$') {
            $u = $Matches[1]; $g = $Matches[2]
            # Verificar que el usuario pertenece al grupo correcto en Windows
            $enGrupo = Get-LocalGroupMember -Group $g -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$u" }
            if (-not $enGrupo) {
                try {
                    Add-LocalGroupMember -Group $g -Member $u -ErrorAction Stop
                    msg_success "$u : agregado a grupo '$g'"
                } catch {
                    msg_error "No se pudo agregar '$u' a '$g': $_"
                }
            } else {
                msg_info "$u : grupo '$g' OK"
            }
            # Garantizar que esta en ftp_users
            $enFtpUsers = Get-LocalGroupMember -Group $script:FTP_GROUP_ALL -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$u" }
            if (-not $enFtpUsers) {
                Add-LocalGroupMember -Group $script:FTP_GROUP_ALL -Member $u -ErrorAction SilentlyContinue
            }
        }
    }
    msg_success "Revision completada"
}

function Menu-Grupos {
    $salir = $false
    while (-not $salir) {
        Clear-Host
        Draw-Header "Gestion de Grupos FTP"
        Write-Host "  1) Listar grupos y miembros"
        Write-Host "  2) Crear grupo FTP"
        Write-Host "  3) Eliminar grupo FTP"
        Write-Host "  4) Ver/reparar permisos NTFS de directorios"
        Write-Host "  5) Reparar membresias de usuarios en grupos Windows"
        Write-Host "  6) Volver al menu principal"
        Write-Host ""

        $op = Read-MenuInput "Opcion"
        switch ($op) {
            "1" {
                Show-FtpGroups
                Pause-Menu
            }
            "2" {
                New-FtpGroup
                Pause-Menu
            }
            "3" {
                Remove-FtpGroup
                Pause-Menu
            }
            "4" {
                # Muestra paths de todos los dirs y llama Repair-FtpPermissions
                Manage-GroupDirectoryPermissions
                Pause-Menu
            }
            "5" {
                # Compara metadatos con grupos locales Windows y corrige
                Repair-FtpGroupMemberships
                Pause-Menu
            }
            "6" { $salir = $true }
            default {
                msg_error "Opcion invalida. Seleccione del 1 al 6"
                Start-Sleep -Seconds 2
            }
        }
    }
}

$script:_USUARIOS_RESERVADOS = @(
    'Administrator','Guest','DefaultAccount','WDAGUtilityAccount',
    'SYSTEM','LOCAL SERVICE','NETWORK SERVICE','ftp_users'
)

# Validadores
function Test-FtpUsername {
    param([string]$nombre)
    if ($nombre -notmatch '^[a-z_][a-z0-9_.\-]{0,31}$') {
        msg_error "Nombre invalido '${nombre}': minusculas/numeros/_.-; max 32; empieza con letra o _"
        return $false
    }
    if ($script:_USUARIOS_RESERVADOS -contains $nombre) {
        msg_error "Nombre reservado: '$nombre'"
        return $false
    }
    return $true
}

# Convierte texto plano a SecureString
function ConvertTo-SecurePass {
    param([string]$plain)
    return ConvertTo-SecureString $plain -AsPlainText -Force
}

function Read-ConfirmedPassword {
    # Devuelve el texto plano validado contra la politica del sistema.
    # El llamador convierte a SecureString con ConvertTo-SecurePass justo antes de usarla.
    while ($true) {
        $p1 = Read-Host -Prompt "-> Contrasena" -AsSecureString
        $p2 = Read-Host -Prompt "-> Confirma contrasena" -AsSecureString

        $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
        $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))

        if ([string]::IsNullOrEmpty($plain1)) { msg_error "La contrasena no puede estar vacia"; continue }
        if ($plain1 -ne $plain2) { msg_error "Las contrasenas no coinciden"; continue }

        # Verificar contra la politica del sistema con usuario temporal
        $tmpUser = "_chk$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        $secPass = ConvertTo-SecurePass $plain1
        try {
            New-LocalUser -Name $tmpUser -Password $secPass -ErrorAction Stop | Out-Null
            Remove-LocalUser -Name $tmpUser -ErrorAction SilentlyContinue
            return $plain1   # devolver texto plano
        } catch {
            Remove-LocalUser -Name $tmpUser -ErrorAction SilentlyContinue
            msg_error "La contrasena no cumple la politica del sistema"
            msg_info  "Requisitos: minimo 7 caracteres, mayusculas, minusculas, numeros y/o simbolos"
            msg_info  "La contrasena NO puede contener el nombre de usuario"
        }
    }
}

# Metadatos
function Init-FtpMeta {
    if (-not (Test-Path $script:FTP_ROOT)) {
        New-Item -ItemType Directory -Path $script:FTP_ROOT -Force | Out-Null
    }
    if (-not (Test-Path $script:FTP_META)) {
        New-Item -ItemType File -Path $script:FTP_META -Force | Out-Null
    }
    msg_success "Archivo de metadatos inicializado"
}

function Meta-GetGroup {
    param([string]$usuario)
    if (-not (Test-Path $script:FTP_META)) { return $null }
    $linea = Get-Content $script:FTP_META | Where-Object { $_ -match "^${usuario}:" } | Select-Object -First 1
    if ($linea) { return ($linea -split ':')[1] }
    return $null
}

function Meta-Set {
    param([string]$usuario, [string]$grupo)
    $newLine = "${usuario}:${grupo}"
    if (Test-Path $script:FTP_META) {
        $lines = @(Get-Content $script:FTP_META | Where-Object { $_ -notmatch "^${usuario}:" })
        $lines += $newLine
        [System.IO.File]::WriteAllLines($script:FTP_META, $lines, [System.Text.Encoding]::UTF8)
    } else {
        [System.IO.File]::WriteAllLines($script:FTP_META, @($newLine), [System.Text.Encoding]::UTF8)
    }
}

function Meta-Delete {
    param([string]$usuario)
    if (Test-Path $script:FTP_META) {
        $lines = @(Get-Content $script:FTP_META | Where-Object { $_ -notmatch "^${usuario}:" })
        [System.IO.File]::WriteAllLines($script:FTP_META, $lines, [System.Text.Encoding]::UTF8)
    }
}

function Meta-Exists {
    param([string]$usuario)
    if (-not (Test-Path $script:FTP_META)) { return $false }
    return [bool](Get-Content $script:FTP_META | Where-Object { $_ -match "^${usuario}:" })
}

# Gestion de cuentas Windows
function New-FtpWindowsUser {
    param([string]$usuario, [string]$password, [string]$grupo)
    try {
        $secPass = ConvertTo-SecurePass $password
        # Crear cuenta local
        New-LocalUser -Name $usuario `
            -Password $secPass `
            -FullName "FTP: $usuario" `
            -Description "Usuario FTP" `
            -PasswordNeverExpires `
            -ErrorAction Stop | Out-Null

        # Agregar a grupo FTP especifico y a ftp_users
        Add-LocalGroupMember -Group $grupo                  -Member $usuario -ErrorAction SilentlyContinue
        Add-LocalGroupMember -Group $script:FTP_GROUP_ALL   -Member $usuario -ErrorAction SilentlyContinue

        # Denegar inicio de sesion local (equivalente a nologin en Linux)
        # Se hace via Local Security Policy / secedit
        Deny-LocalLogon $usuario

        msg_success "Usuario Windows '$usuario' creado (grupo: $grupo)"
        return $true
    } catch {
        msg_error "No se pudo crear el usuario Windows: $_"
        return $false
    }
}

# Deniega el inicio de sesion local al usuario via secedit
function Deny-LocalLogon {
    param([string]$usuario)
    try {
        $tmpCfg = "$env:TEMP\ftp_secedit_deny.inf"
        $tmpDb  = "$env:TEMP\ftp_secedit.sdb"

        # Exportar politica actual
        secedit /export /cfg $tmpCfg /quiet 2>$null

        $content = Get-Content $tmpCfg -Raw
        $sid = (New-Object System.Security.Principal.NTAccount($usuario)).Translate([System.Security.Principal.SecurityIdentifier]).Value

        if ($content -match 'SeDenyInteractiveLogonRight\s*=\s*(.*)') {
            $actual = $Matches[1].Trim()
            if ($actual -notlike "*$sid*") {
                $content = $content -replace 'SeDenyInteractiveLogonRight\s*=\s*.*', "SeDenyInteractiveLogonRight = $actual,*$sid"
            }
        } else {
            $content += "`nSeDenyInteractiveLogonRight = *$sid"
        }

        $content | Set-Content $tmpCfg -Encoding Unicode
        secedit /configure /cfg $tmpCfg /db $tmpDb /quiet 2>$null
        Remove-Item $tmpCfg,$tmpDb -ErrorAction SilentlyContinue
        msg_success "Inicio de sesion local denegado para '$usuario'"
    } catch {
        msg_alert "No se pudo denegar inicio de sesion local para '$usuario': $_"
    }
}

# CRUD publico
function New-FtpUsersLote {
    Write-Separator
    $n = Read-Input "Numero de usuarios a crear: "
    if ($n -notmatch '^\d+$' -or [int]$n -lt 1) { msg_error "Numero invalido"; return }

    $total = [int]$n; $creados = 0
    while ($creados -lt $total) {
        Write-Separator
        msg_info "Usuario $($creados+1) de $total"

        # Nombre
        $usuario = ""
        while ($true) {
            $usuario = Read-Input "Nombre de usuario FTP: "
            if (-not (Test-FtpUsername $usuario)) { continue }
            if (Meta-Exists $usuario) { msg_error "Ya existe '$usuario'"; continue }
            if (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue) { msg_error "Usuario Windows '$usuario' ya existe"; continue }
            break
        }

        # Contrasena
        $pass = Read-ConfirmedPassword

        # Grupo
        $grupo = Select-FtpGroup

        # Crear
        if (New-FtpWindowsUser $usuario $pass $grupo) {
            New-FtpUserDirectories $usuario $grupo
            Meta-Set $usuario $grupo
            msg_success "Usuario '$usuario' creado en grupo '$grupo'"
        }

        $creados++
    }

    Restart-FtpService
    msg_success "$total usuario(s) procesados."
}

function Update-FtpUser {
    Write-Separator
    $usuario = Read-Input "Nombre del usuario FTP a actualizar: "
    if (-not (Meta-Exists $usuario)) { msg_error "El usuario '$usuario' no existe"; return }

    $grupoActual = Meta-GetGroup $usuario
    msg_info "Usuario FTP : $usuario"
    msg_info "Grupo       : $grupoActual"
    msg_info "(Enter = sin cambios)"
    Write-Separator

    # Cambiar nombre
    $nuevoNombre = Read-Input "Nuevo nombre FTP [$usuario]: "
    if (-not [string]::IsNullOrWhiteSpace($nuevoNombre) -and $nuevoNombre -ne $usuario) {
        if (-not (Test-FtpUsername $nuevoNombre)) {
            msg_error "Nombre invalido — sin cambios"
        } elseif (Meta-Exists $nuevoNombre) {
            msg_error "'$nuevoNombre' ya en uso"
        } else {
            try {
                Rename-LocalUser -Name $usuario -NewName $nuevoNombre -ErrorAction Stop
                # Renombrar carpeta
                $oldDir = "$script:FTP_ROOT\LocalUser\$usuario"
                $newDir = "$script:FTP_ROOT\LocalUser\$nuevoNombre"
                if (Test-Path $oldDir) { Rename-Item $oldDir $newDir }
                # Actualizar meta
                $lines = Get-Content $script:FTP_META | ForEach-Object { $_ -replace "^${usuario}:", "${nuevoNombre}:" }
                $lines | Set-Content $script:FTP_META
                # Actualizar Virtual Directories
                Remove-FtpUserVirtualDirectories $usuario
                Add-FtpVirtualDirectory -usuario $nuevoNombre -vdirName "general"      -physicalPath $script:FTP_GENERAL
                Add-FtpVirtualDirectory -usuario $nuevoNombre -vdirName $grupoActual   -physicalPath "$script:FTP_ROOT\grupos\$grupoActual"
                msg_success "Usuario renombrado: '$usuario' -> '$nuevoNombre'"
                $usuario = $nuevoNombre
            } catch {
                msg_error "No se pudo renombrar: $_"
            }
        }
    }

    # Cambiar contrasena
    if (Confirm-Action "Cambiar contrasena?") {
        $newPass = Read-ConfirmedPassword
        try {
            Set-LocalUser -Name $usuario -Password (ConvertTo-SecurePass $newPass) -ErrorAction Stop
            msg_success "Contrasena actualizada"
        } catch {
            msg_error "No se pudo cambiar la contrasena: $_"
        }
    }

    # Cambiar grupo
    msg_info "Grupo actual: $grupoActual"
    if (Confirm-Action "Cambiar grupo?") {
        $nuevoGrupo = Select-FtpGroup
        if ($nuevoGrupo -ne $grupoActual) {
            try {
                Remove-LocalGroupMember -Group $grupoActual  -Member $usuario -ErrorAction SilentlyContinue
                Add-LocalGroupMember    -Group $nuevoGrupo   -Member $usuario -ErrorAction Stop
                Meta-Set $usuario $nuevoGrupo
                Update-FtpUserVirtualDirectories $usuario $nuevoGrupo
                msg_success "Grupo: '$grupoActual' -> '$nuevoGrupo'"
            } catch {
                msg_error "No se pudo cambiar el grupo: $_"
            }
        } else {
            msg_info "Mismo grupo — sin cambios"
        }
    }

    Restart-FtpService
    msg_success "Actualizacion de '$usuario' completada"
}

function Remove-FtpUser {
    Write-Separator
    $usuario = Read-Input "Nombre del usuario FTP a eliminar: "
    if (-not (Meta-Exists $usuario)) { msg_error "El usuario '$usuario' no existe"; return }

    $grupo   = Meta-GetGroup $usuario
    $userDir = "$script:FTP_ROOT\LocalUser\$usuario"
    msg_info "Usuario: $usuario  |  Grupo: $grupo  |  Dir: $userDir"

    if (-not (Confirm-Action "Confirma eliminar '$usuario'")) { msg_info "Cancelado"; return }

    $delDir = Confirm-Action "Eliminar directorio del usuario?"

    # Eliminar Virtual Directories
    Remove-FtpUserVirtualDirectories $usuario

    # Eliminar usuario Windows
    try {
        Remove-LocalUser -Name $usuario -ErrorAction Stop
        msg_success "Usuario Windows '$usuario' eliminado"
    } catch {
        msg_alert "No se pudo eliminar el usuario Windows: $_"
    }

    Meta-Delete $usuario

    if ($delDir -and (Test-Path $userDir)) {
        Remove-Item $userDir -Recurse -Force
        msg_success "Directorio eliminado"
    }

    Restart-FtpService
    msg_success "Usuario '$usuario' eliminado"
}

function Show-FtpUsers {
    Write-Separator
    msg_info "Usuarios FTP:"
    if (-not (Test-Path $script:FTP_META) -or -not (Get-Content $script:FTP_META | Where-Object { $_ -match ':' })) {
        msg_alert "No hay usuarios registrados"; return
    }

    "{0,-20} {1,-15} {2,-30}" -f "USUARIO FTP", "GRUPO", "DIRECTORIO" | Write-Host
    "{0,-20} {1,-15} {2,-30}" -f "-----------", "-----", "-----------" | Write-Host

    Get-Content $script:FTP_META | ForEach-Object {
        if ($_ -match '^(.+):(.+)$') {
            $u = $Matches[1]; $g = $Matches[2]
            $userDir = "$script:FTP_ROOT\LocalUser\$u"
            "{0,-20} {1,-15} {2,-30}" -f $u, $g, $userDir | Write-Host
        }
    }
}

function Menu-Usuarios {
    $salir = $false
    while (-not $salir) {
        Clear-Host
        Draw-Header "Gestion de Usuarios FTP"
        Write-Host "  1) Listar usuarios FTP"
        Write-Host "  2) Crear usuario(s) FTP"
        Write-Host "  3) Actualizar usuario (nombre / contrasena / grupo)"
        Write-Host "  4) Eliminar usuario FTP"
        Write-Host "  5) Volver al menu principal"
        Write-Host ""

        $op = Read-MenuInput "Opcion"
        switch ($op) {
            "1" {
                Show-FtpUsers
                Pause-Menu
            }
            "2" {
                # Pregunta cuántos usuarios crear y ejecuta el flujo guiado
                New-FtpUsersLote
                Pause-Menu
            }
            "3" {
                # Pide el nombre del usuario, luego ofrece cambiar
                # nombre, contraseña y grupo por separado (Enter = sin cambios)
                Update-FtpUser
                Pause-Menu
            }
            "4" {
                Remove-FtpUser
                Pause-Menu
            }
            "5" { $salir = $true }
            default {
                msg_error "Opcion invalida. Seleccione del 1 al 5"
                Start-Sleep -Seconds 2
            }
        }
    }
}