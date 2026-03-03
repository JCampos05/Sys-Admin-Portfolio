# Resuelve nombres de identidad conocidos a SID para evitar problemas con idioma del SO.
function Resolve-Identity {
    param([string]$identity)
    $wellKnown = @{
        "BUILTIN\Administrators"        = [System.Security.Principal.SecurityIdentifier]"S-1-5-32-544"
        "NT AUTHORITY\SYSTEM"           = [System.Security.Principal.SecurityIdentifier]"S-1-5-18"
        "NT AUTHORITY\NETWORK SERVICE"  = [System.Security.Principal.SecurityIdentifier]"S-1-5-20"
        "Everyone"                      = [System.Security.Principal.SecurityIdentifier]"S-1-1-0"
    }
    if ($wellKnown.ContainsKey($identity)) {
        return $wellKnown[$identity].Translate([System.Security.Principal.NTAccount]).Value
    }
    return $identity
}

# Aplica un permiso NTFS a un directorio.
function Set-NtfsPermission {
    param(
        [string]$path,
        [string]$identity,
        [string]$rights,
        [string]$type        = "Allow",
        [string]$inheritance = "ContainerInherit,ObjectInherit",
        [string]$propagation = "None"
    )
    try {
        $resolvedIdentity = Resolve-Identity $identity
        $acl  = Get-Acl $path
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $resolvedIdentity, $rights, $inheritance, $propagation, $type
        )
        $acl.SetAccessRule($rule)
        Set-Acl -Path $path -AclObject $acl
        return $true
    } catch {
        msg_error "Error aplicando permisos en ${path}: $_"
        return $false
    }
}

# Elimina todos los permisos heredados y deja solo los explicitos.
function Disable-NtfsInheritance {
    param([string]$path)
    $acl = Get-Acl $path
    $acl.SetAccessRuleProtection($true, $true)
    Set-Acl -Path $path -AclObject $acl
}

# Elimina permisos de una identidad en un directorio.
function Remove-NtfsPermission {
    param([string]$path, [string]$identity)
    try {
        $resolved = Resolve-Identity $identity
        $acl   = Get-Acl $path
        $rules = $acl.Access | Where-Object {
            $_.IdentityReference.Value -like "*$resolved*" -or
            $_.IdentityReference.Value -like "*$identity*"
        }
        foreach ($rule in $rules) { $acl.RemoveAccessRule($rule) | Out-Null }
        Set-Acl -Path $path -AclObject $acl
    } catch {
        msg_alert "No se pudo eliminar permiso de ${identity} en ${path}: $_"
    }
}

# Crea la estructura base: LocalUser\, Public\ y carpetas de grupo.
function New-FtpDirectoryStructure {
    msg_process "Creando estructura base en $script:FTP_ROOT..."

    @(
        $script:FTP_ROOT,
        "$script:FTP_ROOT\LocalUser",
        $script:FTP_GENERAL,
        "$script:FTP_ROOT\grupos"
    ) | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }

    foreach ($grupo in $script:FTP_GROUPS) {
        $dir = "$script:FTP_ROOT\grupos\$grupo"
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    # Raiz FTP
    Disable-NtfsInheritance $script:FTP_ROOT
    Set-NtfsPermission $script:FTP_ROOT "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $script:FTP_ROOT "NT AUTHORITY\SYSTEM"    "FullControl"

    # LocalUser
    Disable-NtfsInheritance "$script:FTP_ROOT\LocalUser"
    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "NT AUTHORITY\SYSTEM"    "FullControl"

    # Public (general) — todos los usuarios FTP pueden leer/escribir
    # IUSR necesita acceso para que el anonimo pueda listar y leer
    Disable-NtfsInheritance $script:FTP_GENERAL
    Set-NtfsPermission $script:FTP_GENERAL "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $script:FTP_GENERAL "NT AUTHORITY\SYSTEM"    "FullControl"
    Set-NtfsPermission $script:FTP_GENERAL $script:FTP_GROUP_ALL    "Modify"
    Set-NtfsPermission $script:FTP_GENERAL "IUSR"                   "ReadAndExecute"
    # FIX: Deny explícito para IUSR — gana sobre cualquier Allow heredado de grupo
    Set-NtfsPermission $script:FTP_GENERAL "IUSR" "Write,Delete,DeleteSubdirectoriesAndFiles,CreateFiles,CreateDirectories" "Deny"

    # LocalUser necesita acceso de listado para IUSR

    # LocalUser necesita acceso de listado para IUSR (para que anonymous pueda entrar a Public)
    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "IUSR" "ReadAndExecute" "Allow" "None" "None"

    # Carpetas de grupo
    foreach ($grupo in $script:FTP_GROUPS) {
        $dir = "$script:FTP_ROOT\grupos\$grupo"
        Disable-NtfsInheritance $dir
        Set-NtfsPermission $dir "BUILTIN\Administrators" "FullControl"
        Set-NtfsPermission $dir "NT AUTHORITY\SYSTEM"    "FullControl"
        Set-NtfsPermission $dir $grupo                   "Modify"
    }

    msg_success "Estructura base creada"
}

# Crea junction point de linkPath -> targetPath.
function Add-FtpJunction {
    param([string]$linkPath, [string]$targetPath)
    if (Test-Path $linkPath) { return }
    if (-not (Test-Path $targetPath)) {
        New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
    }
    $result = cmd /c "mklink /J `"$linkPath`" `"$targetPath`"" 2>&1
    if ($LASTEXITCODE -eq 0) {
        msg_success "Junction: $linkPath -> $targetPath"
    } else {
        msg_error "Error creando junction $linkPath : $result"
    }
}

# Elimina junction points de un usuario sin borrar el contenido.
function Remove-FtpUserJunctions {
    param([string]$usuario)
    $userDir = "$script:FTP_ROOT\LocalUser\$usuario"
    $targets = @("general") + $script:FTP_GROUPS
    foreach ($t in $targets) {
        $link = "$userDir\$t"
        if (Test-Path $link) {
            $item = Get-Item $link -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                cmd /c "rmdir `"$link`"" | Out-Null
                msg_success "Junction eliminado: $link"
            }
        }
    }
}

# Crea la estructura del usuario:
#   C:\FTP\LocalUser\<usuario>\
#   ├── personal\    carpeta privada fisica
#   ├── general\     junction -> C:\FTP\LocalUser\Public
#   └── <grupo>\     junction -> C:\FTP\grupos\<grupo>
#
function New-FtpUserDirectories {
    param([string]$usuario, [string]$grupo)

    $userDir  = "$script:FTP_ROOT\LocalUser\$usuario"
    $personal = "$userDir\personal"

    # Crear directorios fisicos
    New-Item -ItemType Directory -Path $userDir  -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType Directory -Path $personal -Force -ErrorAction SilentlyContinue | Out-Null

    # Raiz: el usuario puede listar pero NO modificar ni borrar en la raiz
    # Esto protege los junctions — no puede borrarlos porque no tiene Delete aqui
    Disable-NtfsInheritance $userDir
    Set-NtfsPermission $userDir "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $userDir "NT AUTHORITY\SYSTEM"    "FullControl"
    Set-NtfsPermission $userDir $usuario "ReadAndExecute" "Allow" "None" "None"

    # Personal: control total dentro de la carpeta
    Disable-NtfsInheritance $personal
    Set-NtfsPermission $personal "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $personal "NT AUTHORITY\SYSTEM"    "FullControl"
    Set-NtfsPermission $personal $usuario                 "Modify"

    # Junctions
    Add-FtpJunction "$userDir\general" $script:FTP_GENERAL
    Add-FtpJunction "$userDir\$grupo"  "$script:FTP_ROOT\grupos\$grupo"

    msg_success "Directorios de '$usuario' creados"
}

# Elimina la carpeta del usuario y sus junctions.
function Remove-FtpUserDirectories {
    param([string]$usuario)
    $userDir = "$script:FTP_ROOT\LocalUser\$usuario"
    if (Test-Path $userDir) {
        Remove-FtpUserJunctions $usuario
        Remove-Item $userDir -Recurse -Force -ErrorAction SilentlyContinue
        msg_success "Directorio '$userDir' eliminado"
    }
}

# Actualiza junctions cuando cambia el grupo del usuario.
function Update-FtpUserVirtualDirectories {
    param([string]$usuario, [string]$nuevoGrupo)
    Remove-FtpUserJunctions $usuario
    $userDir = "$script:FTP_ROOT\LocalUser\$usuario"
    Add-FtpJunction "$userDir\general"     $script:FTP_GENERAL
    Add-FtpJunction "$userDir\$nuevoGrupo" "$script:FTP_ROOT\grupos\$nuevoGrupo"
}

# Alias de compatibilidad
function Remove-FtpUserVirtualDirectories {
    param([string]$usuario)
    Remove-FtpUserJunctions $usuario
}

# Repara permisos NTFS de toda la estructura.
function Repair-FtpPermissions {
    Write-Separator
    msg_process "Reparando permisos NTFS..."

    Set-NtfsPermission $script:FTP_ROOT "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission $script:FTP_ROOT "NT AUTHORITY\SYSTEM"    "FullControl"

    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "BUILTIN\Administrators" "FullControl"
    Set-NtfsPermission "$script:FTP_ROOT\LocalUser" "NT AUTHORITY\SYSTEM"    "FullControl"

    if (Test-Path $script:FTP_GENERAL) {
        Set-NtfsPermission $script:FTP_GENERAL "BUILTIN\Administrators" "FullControl"
        Set-NtfsPermission $script:FTP_GENERAL "NT AUTHORITY\SYSTEM"    "FullControl"
        Set-NtfsPermission $script:FTP_GENERAL $script:FTP_GROUP_ALL    "Modify"
        Set-NtfsPermission $script:FTP_GENERAL "IUSR"                   "ReadAndExecute"
        # FIX: Deny explícito para IUSR — gana sobre cualquier Allow heredado de grupo
        Set-NtfsPermission $script:FTP_GENERAL "IUSR" "Write,Delete,DeleteSubdirectoriesAndFiles,CreateFiles,CreateDirectories" "Deny"
        msg_success "$script:FTP_GENERAL reparado"
    }

    foreach ($grupo in $script:FTP_GROUPS) {
        $dir = "$script:FTP_ROOT\grupos\$grupo"
        if (Test-Path $dir) {
            Set-NtfsPermission $dir "BUILTIN\Administrators" "FullControl"
            Set-NtfsPermission $dir "NT AUTHORITY\SYSTEM"    "FullControl"
            Set-NtfsPermission $dir $grupo                   "Modify"
            msg_success "$dir reparado"
        }
    }

    if (Test-Path $script:FTP_META) {
        Get-Content $script:FTP_META | ForEach-Object {
            if ($_ -match '^(.+):(.+)$') {
                $u = $Matches[1]
                $userDir  = "$script:FTP_ROOT\LocalUser\$u"
                $personal = "$userDir\personal"
                if (Test-Path $userDir) {
                    Set-NtfsPermission $userDir  "BUILTIN\Administrators" "FullControl"
                    Set-NtfsPermission $userDir  "NT AUTHORITY\SYSTEM"    "FullControl"
                    Set-NtfsPermission $userDir  $u "ReadAndExecute" "Allow" "None" "None"
                    msg_success "$userDir reparado"
                }
                if (Test-Path $personal) {
                    Set-NtfsPermission $personal "BUILTIN\Administrators" "FullControl"
                    Set-NtfsPermission $personal "NT AUTHORITY\SYSTEM"    "FullControl"
                    Set-NtfsPermission $personal $u                       "Modify"
                    msg_success "$personal reparado"
                }
            }
        }
    }

    msg_success "Reparacion completada"
}

function Menu-Directorios {
    $salir = $false
    while (-not $salir) {
        Clear-Host
        Draw-Header "Directorios y Permisos FTP"
        Write-Host "  1) Ver estructura de directorios FTP"
        Write-Host "  2) Crear estructura base (Public + grupos)"
        Write-Host "  3) Crear directorios para un usuario existente"
        Write-Host "  4) Eliminar directorios de un usuario"
        Write-Host "  5) Reparar permisos NTFS de toda la estructura"
        Write-Host "  6) Volver al menu principal"
        Write-Host ""

        $op = Read-MenuInput "Opcion"
        switch ($op) {
            "1" {
                if (-not (Test-Path $script:FTP_ROOT)) {
                    msg_warn "El directorio raiz $script:FTP_ROOT no existe aun"
                    msg_info "Use la opcion 2 para crear la estructura base"
                    Pause-Menu
                    break
                }

                Write-Separator
                # Cabecera de columnas
                Write-Host ("  {0,-28} {1,-12} {2,-22} {3}" -f "NOMBRE","PERMISOS","PROPIETARIO:GRUPO","NOTA") `
                    -ForegroundColor $script:COLOR_TITLE
                Write-Separator

                # Muestra la raiz
                $rootAcl = Get-Acl $script:FTP_ROOT -ErrorAction SilentlyContinue
                $rootOwner = if ($rootAcl) { $rootAcl.Owner } else { "?" }
                Write-Host ("  {0,-28} {1,-12} {2}" -f "$script:FTP_ROOT/", "", $rootOwner) `
                    -ForegroundColor Cyan

                # Funcion recursiva de arbol
                function Show-FtpTree {
                    param([string]$Ruta, [string]$Prefijo, [int]$MaxDepth, [int]$Depth)
                    if ($Depth -gt $MaxDepth) { return }

                    $items = Get-ChildItem -Path $Ruta -Force -ErrorAction SilentlyContinue |
                             Sort-Object { -not $_.PSIsContainer }, Name

                    for ($i = 0; $i -lt $items.Count; $i++) {
                        $item     = $items[$i]
                        $esUltimo = ($i -eq $items.Count - 1)
                        $rama     = if ($esUltimo) { "└── " } else { "├── " }
                        $siguPref = if ($esUltimo) { "$Prefijo    " } else { "$Prefijo│   " }

                        $esJunction = $item.PSIsContainer -and
                                      ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)

                        # Permisos y propietario
                        $permStr  = ""
                        $ownerStr = ""
                        $nota     = ""
                        try {
                            $acl      = Get-Acl $item.FullName -ErrorAction Stop
                            $ownerStr = $acl.Owner -replace '.*\\',''   # solo la parte tras el backslash
                            # Resumir derechos relevantes (excluir Admins/SYSTEM)
                            $relevant = $acl.Access | Where-Object {
                                $_.IdentityReference -notlike "*Administrators*" -and
                                $_.IdentityReference -notlike "*SYSTEM*"
                            } | Select-Object -First 1
                            if ($relevant) {
                                $who      = ($relevant.IdentityReference -replace '.*\\','')
                                $rights   = switch -Wildcard ($relevant.FileSystemRights.ToString()) {
                                    "*FullControl*"      { "rwxrwxrwx" }
                                    "*Modify*"           { "drwxrws--T" }
                                    "*ReadAndExecute*"   { "dr-xrwxr-x" }
                                    default              { "d????????" }
                                }
                                $permStr  = $rights
                                $ownerStr = "$($ownerStr):$who"
                            }
                        } catch {}

                        if ($esJunction) {
                            $target = (Get-Item $item.FullName -ErrorAction SilentlyContinue).Target
                            $nota   = "\033[0;36m[junction -> $target]\033[0m"
                            Write-Host ("  $Prefijo$rama") -NoNewline
                            Write-Host ("{0,-24}" -f "$($item.Name)/") -ForegroundColor Cyan -NoNewline
                            Write-Host (" {0,-12} {1,-22} " -f $permStr, $ownerStr) -NoNewline
                            Write-Host "[junction -> $target]" -ForegroundColor DarkGray
                        } elseif ($item.PSIsContainer) {
                            Write-Host ("  $Prefijo$rama") -NoNewline
                            Write-Host ("{0,-24}" -f "$($item.Name)/") -ForegroundColor Cyan -NoNewline
                            Write-Host (" {0,-12} {1}" -f $permStr, $ownerStr)
                            Show-FtpTree -Ruta $item.FullName -Prefijo $siguPref -MaxDepth $MaxDepth -Depth ($Depth+1)
                        } else {
                            $tam = if ($item.Length -ge 1KB) { "{0:F0}KB" -f ($item.Length/1KB) }
                                   else { "$($item.Length)B" }
                            Write-Host ("  $Prefijo$rama") -NoNewline
                            Write-Host ("{0,-24}" -f $item.Name) -ForegroundColor White -NoNewline
                            Write-Host (" {0,-12} {1,-22} " -f $permStr, $ownerStr) -NoNewline
                            Write-Host "[$tam]" -ForegroundColor Yellow
                        }
                    }
                }

                Show-FtpTree -Ruta $script:FTP_ROOT -Prefijo "" -MaxDepth 4 -Depth 0

                # Contadores
                $totalDirs  = (Get-ChildItem $script:FTP_ROOT -Recurse -Directory -ErrorAction SilentlyContinue | Measure-Object).Count
                $totalFiles = (Get-ChildItem $script:FTP_ROOT -Recurse -File    -ErrorAction SilentlyContinue | Measure-Object).Count
                $tamTotal   = (Get-ChildItem $script:FTP_ROOT -Recurse -File    -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                $tamStr     = if ($tamTotal -ge 1MB)     { "{0:F0}M"  -f ($tamTotal/1MB) }
                              elseif ($tamTotal -ge 1KB) { "{0:F0}K"  -f ($tamTotal/1KB) }
                              else                       { "${tamTotal}B" }

                Write-Separator
                msg_info "Directorios: $totalDirs  |  Ficheros: $totalFiles  |  Tamaño total: $tamStr"
                Write-Host ""
                Write-Host "  " -NoNewline
                Write-Host "■ Directorio  " -ForegroundColor Cyan    -NoNewline
                Write-Host "■ Junction  "   -ForegroundColor DarkGray -NoNewline
                Write-Host "■ Tamaño fichero" -ForegroundColor Yellow
                Pause-Menu
            }
            "2" {
                New-FtpDirectoryStructure
                Pause-Menu
            }
            "3" {
                $usuario = Read-MenuInput "Nombre del usuario FTP"
                $grupo   = Read-MenuInput "Grupo del usuario"
                New-FtpUserDirectories $usuario $grupo
                Pause-Menu
            }
            "4" {
                $usuario = Read-MenuInput "Nombre del usuario FTP"
                if (Confirm-MenuAction "Eliminar directorios de '$usuario'?") {
                    Remove-FtpUserDirectories $usuario
                }
                Pause-Menu
            }
            "5" {
                Repair-FtpPermissions
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