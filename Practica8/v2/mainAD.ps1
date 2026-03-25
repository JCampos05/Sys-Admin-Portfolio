#
# mainAD.ps1
# Orquestador principal con menu interactivo — Tarea 08
# Gobernanza, Cuotas y Control de Aplicaciones en Active Directory
#
# Estructura del menu:
#   Instalacion y configuracion (fases A-E, idempotente)
#   Gestion de usuarios (alta, baja, listar)
#   Monitoreo (cuotas, logonhours, logins, eventos FSRM, AppLocker)
#   Verificacion general
#

#Requires -Version 5.1
#Requires -RunAsAdministrator

#
# RUTAS BASE
#
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Definition

#
# CARGA DE MODULOS
#
. "$SCRIPT_DIR\utils.ps1"
. "$SCRIPT_DIR\utilsAD.ps1"
. "$SCRIPT_DIR\validatorsAD.ps1"
. "$SCRIPT_DIR\Functions-AD-A.ps1"
. "$SCRIPT_DIR\Functions-AD-B.ps1"
. "$SCRIPT_DIR\Functions-AD-C.ps1"
. "$SCRIPT_DIR\Functions-AD-D.ps1"
. "$SCRIPT_DIR\Functions-AD-E.ps1"
. "$SCRIPT_DIR\Functions-AD-F.ps1"

#
# FUNCION DE ENTRADA DE MENU
# Equivalente a Read-MenuInput de practicas anteriores
#
function Read-MenuInput {
    param([string]$Prompt)
    Write-Host -NoNewline "${CYAN}[INPUT]${NC}   ${Prompt}: "
    return (Read-Host)
}

# 
# INDICADORES DE ESTADO
# Cada funcion retorna $true/$false para que _icono_estado los convierta
# 

function _icono_estado {
    param([bool]$Ok)
    if ($Ok) { return "${GREEN}●${NC}" } else { return "${RED}○${NC}" }
}

# Verifica si AD DS esta instalado y el servidor es un DC
function _estado_ad {
    try {
        $domain = Get-ADDomain -ErrorAction Stop
        return ($null -ne $domain)
    } catch {
        return $false
    }
}

# Verifica si las OUs Cuates y NoCuates existen
function _estado_ous {
    if (-not (_estado_ad)) { return $false }
    try {
        $domainNC = Get-DomainNC -DomainName (Get-ADDomain).DNSRoot
        $cuates   = Get-ADOrganizationalUnit -Filter "Name -eq 'Cuates'" `
                    -SearchBase $domainNC -ErrorAction SilentlyContinue
        $noCuates = Get-ADOrganizationalUnit -Filter "Name -eq 'NoCuates'" `
                    -SearchBase $domainNC -ErrorAction SilentlyContinue
        return ($null -ne $cuates -and $null -ne $noCuates)
    } catch { return $false }
}

# Verifica si hay usuarios creados en los grupos
function _estado_usuarios {
    if (-not (_estado_ous)) { return $false }
    try {
        $c = (Get-ADGroupMember "GRP_Cuates"   -ErrorAction Stop).Count
        $n = (Get-ADGroupMember "GRP_NoCuates" -ErrorAction Stop).Count
        return ($c -gt 0 -and $n -gt 0)
    } catch { return $false }
}

# Verifica si los LogonHours estan configurados en al menos un usuario
function _estado_logonhours {
    if (-not (_estado_usuarios)) { return $false }
    try {
        $bytes = (Get-ADUser user01 -Properties LogonHours -ErrorAction Stop).LogonHours
        return ($null -ne $bytes -and $bytes.Count -eq 21)
    } catch { return $false }
}

# Verifica si FSRM esta instalado y hay cuotas configuradas
function _estado_fsrm {
    if (-not (Test-WindowsFeatureInstalled "FS-Resource-Manager")) { return $false }
    try {
        $quota = Get-FsrmQuota -ErrorAction SilentlyContinue | Select-Object -First 1
        return ($null -ne $quota)
    } catch { return $false }
}

# Verifica si las GPOs de AppLocker existen
function _estado_applocker {
    try {
        $gpo1 = Get-GPO -Name "AppLocker-Cuates-T08"   -ErrorAction SilentlyContinue
        $gpo2 = Get-GPO -Name "AppLocker-NoCuates-T08" -ErrorAction SilentlyContinue
        return ($null -ne $gpo1 -and $null -ne $gpo2)
    } catch { return $false }
}

# Verifica si AppIDSvc esta corriendo
function _estado_appidsvc {
    $svc = Get-Service -Name "AppIDSvc" -ErrorAction SilentlyContinue
    return ($null -ne $svc -and $svc.Status -eq 'Running')
}

# 
# BANNER
# 
function _mostrar_banner {
    param([string]$Titulo = "Tarea 08 — AD Governance")
    Write-Host ""
    Write-Host "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    $pad = " " * [Math]::Max(0, 44 - $Titulo.Length)
    Write-Host "${CYAN}║${NC}  $Titulo$pad${CYAN}║${NC}"
    Write-Host "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    Write-Host ""
}

# 
# VERIFICACION — funcion _v_check equivalente a verifySSL.ps1
# 
function _v_check {
    param(
        [string]$Desc,
        [string]$Result,
        [string]$Detalle = ""
    )
    $icono = switch ($Result) {
        "ok"   { "${GREEN}  OK  ${NC}" }
        "fail" { "${RED}  FAIL${NC}" }
        "warn" { "${YELLOW}  WARN${NC}" }
        "skip" { "${GRAY}  SKIP${NC}" }
        default{ "  ?   " }
    }
    $det = if ($Detalle) { $Detalle } else { "" }
    Write-Host ("  {0}  {1,-40} {2}" -f $icono, $Desc, $det)
}

# 
# MENU PRINCIPAL
# 
function _dibujar_menu {
    Clear-Host

    # Calcular indicadores una sola vez
    $sAD     = _icono_estado (_estado_ad)
    $sOUs    = _icono_estado (_estado_ous)
    $sUsers  = _icono_estado (_estado_usuarios)
    $sHours  = _icono_estado (_estado_logonhours)
    $sFSRM   = _icono_estado (_estado_fsrm)
    $sAppL   = _icono_estado (_estado_applocker)
    $sAppSvc = _icono_estado (_estado_appidsvc)

    _mostrar_banner "Tarea 08 — AD Governance"

    # Mostrar dominio si AD esta activo
    try {
        $dom = (Get-ADDomain -ErrorAction SilentlyContinue).DNSRoot
        if ($dom) {
            Write-Host "  Dominio: ${CYAN}$dom${NC}"
            Write-Host "  Servidor: $env:COMPUTERNAME"
        }
    } catch {}
    Write-Host ""

    Write-Host "  ${GRAY}── Instalacion y Configuracion ───────────────────────${NC}"
    Write-Host "  ${BLUE}1)${NC} $sAD   Instalar Active Directory (AD DS + DNS)"
    Write-Host "  ${BLUE}2)${NC} $sOUs  Crear estructura OU + usuarios desde CSV"
    Write-Host "  ${BLUE}3)${NC} $sHours Configurar LogonHours + GPO logoff"
    Write-Host "  ${BLUE}4)${NC} $sFSRM Configurar FSRM (cuotas + file screening)"
    Write-Host "  ${BLUE}5)${NC} $sAppL Configurar AppLocker   ${GRAY}(AppIDSvc: $sAppSvc)${NC}"
    Write-Host ""

    Write-Host "  ${GRAY}── Gestion de Usuarios ───────────────────────────────${NC}"
    Write-Host "  ${BLUE}U)${NC} $sUsers Menu de usuarios (alta, baja, listar)"
    Write-Host ""

    Write-Host "  ${GRAY}── Monitoreo ──────────────────────────────────────────${NC}"
    Write-Host "  ${BLUE}M)${NC}    Menu de monitoreo (cuotas, logins, eventos)"
    Write-Host ""

    Write-Host "  ${GRAY}── Clientes ──────────────────────────────────────────${NC}"
    Write-Host "  ${BLUE}C)${NC}    Menu de clientes (Linux + Windows 10)"
    Write-Host ""
    Write-Host "  ${GRAY}── Administracion Dinamica ───────────────────────────${NC}"
    Write-Host "  ${BLUE}F)${NC}    Horarios dinamicos (cambiar LogonHours en vivo)"
    Write-Host "  ${BLUE}G)${NC}    Gestion avanzada   (Alta / Baja / Cambio de grupo)"
    Write-Host ""
    Write-Host "  ${GRAY}── Herramientas ───────────────────────────────────────${NC}"
    Write-Host "  ${BLUE}V)${NC}    Verificacion general completa"
    Write-Host "  ${BLUE}S)${NC}    Reparar SSH post-DC"
    Write-Host "  ${BLUE}D)${NC}    Registrar cliente Linux en DNS"
    Write-Host ""
    Write-Host "  ${BLUE}0)${NC}    Salir"
    Write-Host ""
}

function main_menu {
    while ($true) {
        _dibujar_menu
        $op = Read-Host "  Opcion"

        switch ($op.ToUpper()) {
            "1" { _menu_instalar_ad    }
            "2" { _menu_estructura     }
            "3" { _menu_logonhours     }
            "4" { _menu_fsrm           }
            "5" { _menu_applocker      }
            "F" { Invoke-HorariosDinamicos  }
            "G" { Invoke-GestionAvanzada    }
            "U" { _menu_usuarios       }
            "M" { _menu_monitoreo      }
            "C" { _menu_clientes       }
            "V" { _menu_verificacion   }
            "S" { _accion_fix_ssh      }
            "D" { _accion_registro_dns }
            "0" {
                Write-Host ""
                aputs_info "Saliendo de Tarea 08..."
                Write-Host ""
                exit 0
            }
            default {
                aputs_error "Opcion invalida"
                Start-Sleep -Seconds 1
            }
        }
    }
}

# 
# SUBMENU 1 — INSTALACION AD DS
# 
function _menu_instalar_ad {
    while ($true) {
        Clear-Host
        _mostrar_banner "Instalacion — Active Directory Domain Services"

        $sAD = _icono_estado (_estado_ad)
        Write-Host "  Estado AD DS: $sAD"
        Write-Host ""

        if (_estado_ad) {
            try {
                $dom = Get-ADDomain -ErrorAction SilentlyContinue
                aputs_success "AD DS activo: $($dom.DNSRoot)"
                aputs_info    "Nivel funcional: $($dom.DomainMode)"
                aputs_info    "DC: $($dom.PDCEmulator)"
            } catch {}
            Write-Host ""
        }

        Write-Host "  ${BLUE}1)${NC} Instalar AD DS y promover como DC (desde cero)"
        Write-Host "  ${BLUE}2)${NC} Verificar estado del servicio AD"
        Write-Host "  ${BLUE}3)${NC} Ver informacion del dominio"
        Write-Host "  ${BLUE}0)${NC} Volver"
        Write-Host ""

        $op = Read-Host "  Opcion"
        switch ($op) {
            "1" {
                Clear-Host
                _mostrar_banner "Instalar AD DS"
                if (_estado_ad) {
                    aputs_warning "AD DS ya esta instalado y configurado."
                    aputs_info    "Dominio: $((Get-ADDomain).DNSRoot)"
                    pause_menu
                } else {
                    $domainName = Request-DomainName
                    if ($null -ne $domainName) {
                        Invoke-PhaseA -DomainName $domainName
                    }
                    pause_menu
                }
            }
            "2" {
                Clear-Host
                _mostrar_banner "Estado del Servicio AD"
                $svcs = @("ADWS","DNS","KDC","NETLOGON","W32Time")
                foreach ($svc in $svcs) {
                    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
                    if ($null -eq $s) {
                        _v_check "Servicio $svc" "skip" "(no encontrado)"
                    } elseif ($s.Status -eq 'Running') {
                        _v_check "Servicio $svc" "ok" "Running"
                    } else {
                        _v_check "Servicio $svc" "fail" "$($s.Status)"
                    }
                }
                pause_menu
            }
            "3" {
                Clear-Host
                _mostrar_banner "Informacion del Dominio"
                if (_estado_ad) {
                    try {
                        $dom = Get-ADDomain -ErrorAction Stop
                        aputs_info "FQDN:           $($dom.DNSRoot)"
                        aputs_info "NetBIOS:        $($dom.NetBIOSName)"
                        aputs_info "Nivel funcional: $($dom.DomainMode)"
                        aputs_info "PDC Emulator:   $($dom.PDCEmulator)"
                        aputs_info "Controladores:  $($dom.ReplicaDirectoryServers -join ', ')"
                    } catch {
                        aputs_error "No se pudo obtener info del dominio: $($_.Exception.Message)"
                    }
                } else {
                    aputs_warning "AD DS no esta configurado."
                }
                pause_menu
            }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

# 
# SUBMENU 2 — ESTRUCTURA OU + USUARIOS
# 
function _menu_estructura {
    while ($true) {
        Clear-Host
        _mostrar_banner "Estructura AD — OUs, Grupos y Usuarios"

        $sOUs   = _icono_estado (_estado_ous)
        $sUsers = _icono_estado (_estado_usuarios)

        try {
            $cCuates   = (Get-ADGroupMember "GRP_Cuates"   -ErrorAction SilentlyContinue).Count
            $cNoCuates = (Get-ADGroupMember "GRP_NoCuates" -ErrorAction SilentlyContinue).Count
        } catch { $cCuates = 0; $cNoCuates = 0 }

        Write-Host "  OUs creadas:    $sOUs"
        Write-Host "  Usuarios en AD: $sUsers   ${GRAY}(Cuates: $cCuates | NoCuates: $cNoCuates)${NC}"
        Write-Host ""
        Write-Host "  ${BLUE}1)${NC} Crear OUs, grupos e importar usuarios desde CSV"
        Write-Host "  ${BLUE}2)${NC} Crear carpetas de perfiles en C:\Perfiles\"
        Write-Host "  ${BLUE}3)${NC} Listar OUs del dominio"
        Write-Host "  ${BLUE}4)${NC} Listar grupos y miembros"
        Write-Host "  ${BLUE}0)${NC} Volver"
        Write-Host ""

        $op = Read-Host "  Opcion"
        switch ($op) {
            "1" {
                Clear-Host
                _mostrar_banner "Crear Estructura AD"
                if (-not (_estado_ad)) {
                    aputs_error "AD DS no esta configurado. Ejecute primero la opcion 1 del menu principal."
                    pause_menu; continue
                }
                $domainName = (Get-ADDomain).DNSRoot
                Invoke-PhaseB -DomainName $domainName
                pause_menu
            }
            "2" {
                Clear-Host
                _mostrar_banner "Crear Carpetas de Perfiles"
                $domainName = (Get-ADDomain -ErrorAction SilentlyContinue).DNSRoot
                New-AllProfileFolders -CsvPath $script:CSV_PATH -DomainName $domainName
                pause_menu
            }
            "3" {
                Clear-Host
                _mostrar_banner "OUs del Dominio"
                Get-ADOrganizationalUnit -Filter * | Select-Object Name, DistinguishedName |
                    Format-Table -AutoSize
                pause_menu
            }
            "4" {
                Clear-Host
                _mostrar_banner "Grupos y Miembros"
                foreach ($grp in @("GRP_Cuates","GRP_NoCuates")) {
                    aputs_info "Grupo: $grp"
                    try {
                        $miembros = Get-ADGroupMember $grp -ErrorAction Stop
                        if ($miembros.Count -eq 0) {
                            aputs_warning "  Sin miembros"
                        } else {
                            $miembros | ForEach-Object {
                                Write-Host "    $($_.SamAccountName) — $($_.Name)"
                            }
                        }
                    } catch {
                        aputs_error "  No se pudo obtener miembros: $($_.Exception.Message)"
                    }
                    Write-Host ""
                }
                pause_menu
            }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

# 
# SUBMENU 3 — LOGONHOURS + GPO LOGOFF
# 
function _menu_logonhours {
    while ($true) {
        Clear-Host
        _mostrar_banner "Control de Acceso Temporal — LogonHours y GPO"

        $sHours = _icono_estado (_estado_logonhours)
        $gpo    = Get-GPO -Name "Politica-ForzarLogoff-T08" -ErrorAction SilentlyContinue
        $sGPO   = _icono_estado ($null -ne $gpo)

        Write-Host "  LogonHours configurados: $sHours"
        Write-Host "  GPO logoff forzado:      $sGPO"
        Write-Host ""
        Write-Host "  ${GRAY}Horarios configurados:${NC}"
        Write-Host "  ${CYAN}GRP_Cuates${NC}   -> 8:00 AM - 3:00 PM"
        Write-Host "  ${CYAN}GRP_NoCuates${NC} -> 3:00 PM - 2:00 AM"
        Write-Host ""
        Write-Host "  ${BLUE}1)${NC} Configurar LogonHours y GPO (Fase C completa)"
        Write-Host "  ${BLUE}2)${NC} Ver horarios configurados de un usuario"
        Write-Host "  ${BLUE}3)${NC} Re-aplicar LogonHours a GRP_Cuates"
        Write-Host "  ${BLUE}4)${NC} Re-aplicar LogonHours a GRP_NoCuates"
        Write-Host "  ${BLUE}5)${NC} Ver GPOs vinculadas al dominio"
        Write-Host "  ${BLUE}6)${NC} Habilitar / Deshabilitar GPO logoff forzado"
        Write-Host "  ${BLUE}0)${NC} Volver"
        Write-Host ""

        $op = Read-Host "  Opcion"
        switch ($op) {
            "1" {
                Clear-Host
                _mostrar_banner "Configurar LogonHours"
                $domainName = (Get-ADDomain -ErrorAction SilentlyContinue).DNSRoot
                Invoke-PhaseC -DomainName $domainName
                pause_menu
            }
            "2" {
                Clear-Host
                _mostrar_banner "LogonHours de Usuario"
                $user = Read-MenuInput "Ingrese el nombre de usuario (ej: user01)"
                try {
                    $bytes = (Get-ADUser $user -Properties LogonHours -ErrorAction Stop).LogonHours
                    if ($null -eq $bytes -or $bytes.Count -eq 0) {
                        aputs_warning "Usuario $user no tiene LogonHours configurados (acceso irrestricto)"
                    } else {
                        aputs_success "Usuario $user tiene LogonHours configurados (21 bytes)"
                        Write-Host "  Bytes: $($bytes -join ' ')"
                    }
                } catch {
                    aputs_error "Usuario no encontrado: $user"
                }
                pause_menu
            }
            "3" {
                Clear-Host
                _mostrar_banner "Re-aplicar LogonHours GRP_Cuates"
                Set-GroupLogonHours -GroupName "GRP_Cuates" -StartHourLocal 8 -EndHourLocal 15
                pause_menu
            }
            "4" {
                Clear-Host
                _mostrar_banner "Re-aplicar LogonHours GRP_NoCuates"
                Set-GroupLogonHours -GroupName "GRP_NoCuates" -StartHourLocal 15 -EndHourLocal 2
                pause_menu
            }
            "5" {
                Clear-Host
                _mostrar_banner "GPOs del Dominio"
                Get-GPO -All | Select-Object DisplayName, GpoStatus, CreationTime |
                    Format-Table -AutoSize
                pause_menu
            }
            "6" {
                Clear-Host
                _mostrar_banner "Habilitar / Deshabilitar GPO Logoff Forzado"
                $gpoLogoff = Get-GPO -Name "Politica-ForzarLogoff-T08" -EA SilentlyContinue
                if ($null -eq $gpoLogoff) {
                    aputs_error "GPO Politica-ForzarLogoff-T08 no encontrada."
                    pause_menu; continue
                }
                $link = Get-GPInheritance -Target "DC=$((Get-ADDomain).DNSRoot.Replace('.', ',DC='))" -EA SilentlyContinue |
                        Select-Object -ExpandProperty GpoLinks |
                        Where-Object { $_.DisplayName -eq "Politica-ForzarLogoff-T08" } |
                        Select-Object -First 1
                $estadoActual = if ($null -ne $link -and $link.Enabled) { "Habilitada" } else { "Deshabilitada" }
                aputs_info "Estado actual: $estadoActual"
                Write-Host ""
                Write-Host "  ${BLUE}1)${NC} Habilitar GPO"
                Write-Host "  ${BLUE}2)${NC} Deshabilitar GPO  ${GRAY}(usar para pruebas de AppLocker)${NC}"
                Write-Host "  ${BLUE}0)${NC} Cancelar"
                Write-Host ""
                $opGpo = Read-Host "  Opcion"
                switch ($opGpo) {
                    "1" {
                        Set-GPLink -Name "Politica-ForzarLogoff-T08" `
                            -Target "DC=$((Get-ADDomain).DNSRoot.Replace('.', ',DC='))" `
                            -LinkEnabled Yes -EA SilentlyContinue
                        aputs_success "GPO habilitada. Los usuarios seran expulsados al expirar horario."
                        Invoke-GPUpdate -Force -EA SilentlyContinue
                    }
                    "2" {
                        Set-GPLink -Name "Politica-ForzarLogoff-T08" `
                            -Target "DC=$((Get-ADDomain).DNSRoot.Replace('.', ',DC='))" `
                            -LinkEnabled No -EA SilentlyContinue
                        aputs_warning "GPO deshabilitada. Los usuarios podran mantener sesion fuera de horario."
                        aputs_info    "Recuerda habilitarla despues de las pruebas."
                        Invoke-GPUpdate -Force -EA SilentlyContinue
                    }
                }
                pause_menu
            }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

# 
# SUBMENU 4 — FSRM
# 
function _menu_fsrm {
    while ($true) {
        Clear-Host
        _mostrar_banner "FSRM — Cuotas y Apantallamiento de Archivos"

        $sFSRM = _icono_estado (_estado_fsrm)
        Write-Host "  FSRM configurado: $sFSRM"
        Write-Host ""
        Write-Host "  ${BLUE}1)${NC} Instalar FSRM y configurar cuotas + screening (Fase D)"
        Write-Host "  ${BLUE}2)${NC} Ver cuotas de todos los usuarios"
        Write-Host "  ${BLUE}3)${NC} Ver uso de disco por usuario"
        Write-Host "  ${BLUE}4)${NC} Ver file screens configurados"
        Write-Host "  ${BLUE}5)${NC} Ver extensiones bloqueadas"
        Write-Host "  ${BLUE}0)${NC} Volver"
        Write-Host ""

        $op = Read-Host "  Opcion"
        switch ($op) {
            "1" {
                Clear-Host
                _mostrar_banner "Configurar FSRM"
                Invoke-PhaseD
                pause_menu
            }
            "2" {
                Clear-Host
                _mostrar_banner "Cuotas Configuradas"
                try {
                    $quotas = Get-FsrmQuota -ErrorAction Stop
                    if ($quotas.Count -eq 0) {
                        aputs_warning "No hay cuotas configuradas."
                    } else {
                        Write-Host ("  {0,-30} {1,-12} {2,-12} {3}" -f `
                            "Carpeta", "Limite", "Uso", "Tipo")
                        Write-Host "  ─────────────────────────────────────────────────────"
                        foreach ($q in $quotas) {
                            $limite = "$([Math]::Round($q.Size/1MB, 0)) MB"
                            $uso    = "$([Math]::Round($q.Usage/1KB, 0)) KB"
                            $tipo   = if ($q.SoftLimit) { "Soft" } else { "Hard" }
                            $path   = Split-Path $q.Path -Leaf
                            Write-Host ("  {0,-30} {1,-12} {2,-12} {3}" -f `
                                $path, $limite, $uso, $tipo)
                        }
                    }
                } catch {
                    aputs_error "FSRM no disponible: $($_.Exception.Message)"
                }
                pause_menu
            }
            "3" {
                Clear-Host
                _mostrar_banner "Uso de Disco por Usuario"
                try {
                    $quotas = Get-FsrmQuota -ErrorAction Stop
                    foreach ($q in $quotas) {
                        $pct    = if ($q.Size -gt 0) { [Math]::Round(($q.Usage / $q.Size) * 100, 1) } else { 0 }
                        $limite = "$([Math]::Round($q.Size/1MB,0)) MB"
                        $uso    = "$([Math]::Round($q.Usage/1KB,0)) KB"
                        $user   = Split-Path $q.Path -Leaf
                        $color  = if ($pct -gt 80) { $RED } elseif ($pct -gt 50) { $YELLOW } else { $GREEN }
                        Write-Host "  ${color}$user${NC}   $uso / $limite  ($pct%)"
                    }
                } catch {
                    aputs_error "FSRM no disponible"
                }
                pause_menu
            }
            "4" {
                Clear-Host
                _mostrar_banner "File Screens Configurados"
                try {
                    $screens = Get-FsrmFileScreen -ErrorAction Stop
                    if ($screens.Count -eq 0) {
                        aputs_warning "No hay file screens configurados."
                    } else {
                        $screens | Select-Object Path, Active, Template |
                            Format-Table -AutoSize
                    }
                } catch {
                    aputs_error "FSRM no disponible"
                }
                pause_menu
            }
            "5" {
                Clear-Host
                _mostrar_banner "Extensiones Bloqueadas"
                try {
                    $group = Get-FsrmFileGroup -Name "ArchivosProhibidos-T08" -ErrorAction Stop
                    aputs_info "Grupo: $($group.Name)"
                    aputs_info "Extensiones bloqueadas:"
                    $group.IncludePattern | ForEach-Object {
                        Write-Host "    $_"
                    }
                } catch {
                    aputs_warning "Grupo ArchivosProhibidos-T08 no encontrado."
                }
                pause_menu
            }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

# 
# SUBMENU 5 — APPLOCKER
# 
function _menu_applocker {
    while ($true) {
        Clear-Host
        _mostrar_banner "AppLocker — Control de Ejecucion"

        $sAppL   = _icono_estado (_estado_applocker)
        $sAppSvc = _icono_estado (_estado_appidsvc)

        Write-Host "  GPOs AppLocker: $sAppL"
        Write-Host "  AppIDSvc:       $sAppSvc"
        Write-Host ""
        Write-Host "  ${BLUE}1)${NC} Configurar AppLocker (Fase E completa)"
        Write-Host "  ${BLUE}2)${NC} Ver GPOs de AppLocker"
        Write-Host "  ${BLUE}3)${NC} Iniciar/verificar servicio AppIDSvc"
        Write-Host "  ${BLUE}4)${NC} Ver hash de notepad.exe registrado"
        Write-Host "  ${BLUE}0)${NC} Volver"
        Write-Host ""

        $op = Read-Host "  Opcion"
        switch ($op) {
            "1" {
                Clear-Host
                _mostrar_banner "Configurar AppLocker"
                $domainName = (Get-ADDomain -ErrorAction SilentlyContinue).DNSRoot
                Invoke-PhaseE -DomainName $domainName
                pause_menu
            }
            "2" {
                Clear-Host
                _mostrar_banner "GPOs de AppLocker"
                foreach ($gpoName in @("AppLocker-Cuates-T08","AppLocker-NoCuates-T08")) {
                    $gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
                    if ($null -ne $gpo) {
                        _v_check $gpoName "ok" "ID: $($gpo.Id.ToString().Substring(0,8))..."
                    } else {
                        _v_check $gpoName "fail" "(no encontrada)"
                    }
                }
                pause_menu
            }
            "3" {
                Clear-Host
                _mostrar_banner "Servicio AppIDSvc"
                sc.exe config AppIDSvc start= auto
                sc.exe start AppIDSvc
                Start-Sleep -Seconds 3
                Start-Sleep -Seconds 3
                $svc = Get-Service -Name "AppIDSvc" -ErrorAction SilentlyContinue
                if ($null -ne $svc -and $svc.Status -eq 'Running') {
                    _v_check "AppIDSvc" "ok" "Running"
                } else {
                    _v_check "AppIDSvc" "fail" "$($svc.Status)"
                }
                pause_menu
            }
            "4" {
                Clear-Host
                _mostrar_banner "Hash de notepad.exe"
                $notepadPath = "C:\Windows\System32\notepad.exe"
                if (Test-Path $notepadPath) {
                    $hash = Get-FileHash -Path $notepadPath -Algorithm SHA256
                    aputs_info "Ruta:      $notepadPath"
                    aputs_info "Algoritmo: SHA-256"
                    aputs_info "Hash:      $($hash.Hash)"
                    aputs_info "Tamano:    $([Math]::Round((Get-Item $notepadPath).Length/1KB,1)) KB"
                } else {
                    aputs_error "notepad.exe no encontrado en $notepadPath"
                }
                pause_menu
            }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

# 
# SUBMENU U — GESTION DE USUARIOS
# 
function _menu_usuarios {
    while ($true) {
        Clear-Host
        _mostrar_banner "Gestion de Usuarios del Dominio"

        try {
            $cCuates   = (Get-ADGroupMember "GRP_Cuates"   -ErrorAction SilentlyContinue).Count
            $cNoCuates = (Get-ADGroupMember "GRP_NoCuates" -ErrorAction SilentlyContinue).Count
        } catch { $cCuates = 0; $cNoCuates = 0 }

        Write-Host "  Cuates: $cCuates usuarios  |  NoCuates: $cNoCuates usuarios"
        Write-Host ""
        Write-Host "  ${BLUE}1)${NC} Listar todos los usuarios del dominio"
        Write-Host "  ${BLUE}2)${NC} Listar usuarios Cuates"
        Write-Host "  ${BLUE}3)${NC} Listar usuarios NoCuates"
        Write-Host "  ${BLUE}4)${NC} Dar de alta un nuevo usuario"
        Write-Host "  ${BLUE}5)${NC} Dar de baja un usuario"
        Write-Host "  ${BLUE}6)${NC} Ver detalle de un usuario"
        Write-Host "  ${BLUE}7)${NC} Habilitar / Deshabilitar usuario"
        Write-Host "  ${BLUE}8)${NC} Cambiar password de usuario"
        Write-Host "  ${BLUE}0)${NC} Volver"
        Write-Host ""

        $op = Read-Host "  Opcion"
        switch ($op) {
            "1" {
                Clear-Host
                _mostrar_banner "Todos los Usuarios del Dominio"
                $domainNC = Get-DomainNC -DomainName (Get-ADDomain).DNSRoot
                Get-ADUser -Filter * -SearchBase $domainNC -Properties Department |
                    Select-Object SamAccountName, Name, Department, Enabled |
                    Sort-Object Department, SamAccountName |
                    Format-Table -AutoSize
                pause_menu
            }
            "2" {
                Clear-Host
                _mostrar_banner "Usuarios Cuates"
                Get-ADGroupMember "GRP_Cuates" | ForEach-Object {
                    $u = Get-ADUser $_.SamAccountName -Properties Enabled
                    $estado = if ($u.Enabled) { "${GREEN}activo${NC}" } else { "${RED}inactivo${NC}" }
                    Write-Host "  $($u.SamAccountName)   $($u.Name)   $estado"
                }
                pause_menu
            }
            "3" {
                Clear-Host
                _mostrar_banner "Usuarios NoCuates"
                Get-ADGroupMember "GRP_NoCuates" | ForEach-Object {
                    $u = Get-ADUser $_.SamAccountName -Properties Enabled
                    $estado = if ($u.Enabled) { "${GREEN}activo${NC}" } else { "${RED}inactivo${NC}" }
                    Write-Host "  $($u.SamAccountName)   $($u.Name)   $estado"
                }
                pause_menu
            }
            "4" {
                Clear-Host
                _mostrar_banner "Alta de Nuevo Usuario"
                $sam      = Read-MenuInput "Nombre de cuenta (ej: user11)"
                $nombre   = Read-MenuInput "Nombre completo"
                $dept     = Read-MenuInput "Departamento (Cuates / NoCuates)"
                $passPlain = Read-MenuInput "Password"

                if ([string]::IsNullOrWhiteSpace($sam) -or [string]::IsNullOrWhiteSpace($dept)) {
                    aputs_error "Datos incompletos."
                    pause_menu; continue
                }

                $domainName = (Get-ADDomain).DNSRoot
                $domainNC   = Get-DomainNC -DomainName $domainName

                switch ($dept) {
                    "Cuates"   { $ouPath = "OU=Cuates,$domainNC";   $group = "GRP_Cuates" }
                    "NoCuates" { $ouPath = "OU=NoCuates,$domainNC"; $group = "GRP_NoCuates" }
                    default    { aputs_error "Departamento invalido. Use Cuates o NoCuates."; pause_menu; continue }
                }

                try {
                    $secPass = ConvertTo-SecureString $passPlain -AsPlainText -Force
                    New-ADUser -SamAccountName $sam -UserPrincipalName "$sam@$domainName" `
                        -Name $nombre -DisplayName $nombre -Department $dept `
                        -AccountPassword $secPass -Path $ouPath `
                        -Enabled $true -PasswordNeverExpires $true `
                        -ChangePasswordAtLogon $false -ErrorAction Stop
                    Add-ADGroupMember -Identity $group -Members $sam -ErrorAction Stop
                    New-ProfileFolder -UserName $sam -Domain ($domainName.Split(".")[0].ToUpper())
                    aputs_success "Usuario $sam creado en $dept y agregado a $group"
                    Write-ADLog "Alta de usuario $sam en $dept" "SUCCESS"
                } catch {
                    aputs_error "Error al crear usuario: $($_.Exception.Message)"
                }
                pause_menu
            }
            "5" {
                Clear-Host
                _mostrar_banner "Baja de Usuario"
                $sam = Read-MenuInput "Nombre de cuenta a dar de baja"
                if (Test-ADUserExists -SamAccountName $sam) {
                    $confirm = Read-MenuInput "Confirme escribiendo el nombre de cuenta de nuevo"
                    if ($confirm -eq $sam) {
                        try {
                            Disable-ADAccount -Identity $sam -ErrorAction Stop
                            aputs_success "Cuenta $sam deshabilitada."
                            aputs_info    "Para eliminar permanentemente: Remove-ADUser $sam"
                            Write-ADLog "Baja (deshabilitar) de usuario $sam" "SUCCESS"
                        } catch {
                            aputs_error "Error: $($_.Exception.Message)"
                        }
                    } else {
                        aputs_warning "Confirmacion no coincide. Operacion cancelada."
                    }
                } else {
                    aputs_error "Usuario $sam no encontrado en AD."
                }
                pause_menu
            }
            "6" {
                Clear-Host
                _mostrar_banner "Detalle de Usuario"
                $sam = Read-MenuInput "Nombre de cuenta"
                try {
                    $u = Get-ADUser $sam -Properties * -ErrorAction Stop
                    aputs_info "SamAccountName:  $($u.SamAccountName)"
                    aputs_info "Nombre:          $($u.DisplayName)"
                    aputs_info "UPN:             $($u.UserPrincipalName)"
                    aputs_info "Departamento:    $($u.Department)"
                    aputs_info "Habilitado:      $($u.Enabled)"
                    aputs_info "UltimLogin:      $($u.LastLogonDate)"
                    aputs_info "OU:              $($u.DistinguishedName)"
                    $tieneHoras = ($null -ne $u.LogonHours -and $u.LogonHours.Count -eq 21)
                    $lhEstado = if ($tieneHoras) { "Configurados" } else { "Sin restriccion" }
                    aputs_info "LogonHours:      $lhEstado"
                } catch {
                    aputs_error "Usuario no encontrado: $sam"
                }
                pause_menu
            }
            "7" {
                Clear-Host
                _mostrar_banner "Habilitar / Deshabilitar Usuario"
                $sam = Read-MenuInput "Nombre de cuenta"
                try {
                    $u = Get-ADUser $sam -Properties Enabled -ErrorAction Stop
                    if ($u.Enabled) {
                        Disable-ADAccount -Identity $sam -ErrorAction Stop
                        aputs_success "Cuenta $sam deshabilitada."
                    } else {
                        Enable-ADAccount -Identity $sam -ErrorAction Stop
                        aputs_success "Cuenta $sam habilitada."
                    }
                } catch {
                    aputs_error "Error: $($_.Exception.Message)"
                }
                pause_menu
            }
            "8" {
                Clear-Host
                _mostrar_banner "Cambiar Password"
                $sam       = Read-MenuInput "Nombre de cuenta"
                $newPass   = Read-MenuInput "Nueva password"
                try {
                    $secPass = ConvertTo-SecureString $newPass -AsPlainText -Force
                    Set-ADAccountPassword -Identity $sam -NewPassword $secPass `
                        -Reset -ErrorAction Stop
                    aputs_success "Password de $sam actualizado."
                    Write-ADLog "Password cambiado para $sam" "SUCCESS"
                } catch {
                    aputs_error "Error: $($_.Exception.Message)"
                }
                pause_menu
            }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

# 
# SUBMENU M — MONITOREO
# 
function _menu_monitoreo {
    while ($true) {
        Clear-Host
        _mostrar_banner "Monitoreo del Dominio"

        Write-Host "  ${BLUE}1)${NC} Uso de cuotas en tiempo real"
        Write-Host "  ${BLUE}2)${NC} Eventos de bloqueo FSRM (archivos rechazados)"
        Write-Host "  ${BLUE}3)${NC} Ultimos inicios de sesion del dominio"
        Write-Host "  ${BLUE}4)${NC} Sesiones activas en el DC"
        Write-Host "  ${BLUE}5)${NC} Usuarios con LogonHours configurados"
        Write-Host "  ${BLUE}6)${NC} Cuentas bloqueadas o deshabilitadas"
        Write-Host "  ${BLUE}7)${NC} Log de la practica (tarea08.log)"
        Write-Host "  ${BLUE}0)${NC} Volver"
        Write-Host ""

        $op = Read-Host "  Opcion"
        switch ($op) {
            "1" {
                Clear-Host
                _mostrar_banner "Uso de Cuotas en Tiempo Real"
                try {
                    $quotas = Get-FsrmQuota -ErrorAction Stop | Sort-Object Usage -Descending
                    Write-Host ""
                    Write-Host ("  {0,-20} {1,-10} {2,-10} {3,-8} {4}" -f `
                        "Usuario","Limite","Uso","Pct","Estado")
                    Write-Host "  ──────────────────────────────────────────────────"
                    foreach ($q in $quotas) {
                        $pct    = if ($q.Size -gt 0) { [Math]::Round(($q.Usage/$q.Size)*100,1) } else { 0 }
                        $limite = "$([Math]::Round($q.Size/1MB,0))MB"
                        $uso    = "$([Math]::Round($q.Usage/1KB,0))KB"
                        $user   = Split-Path $q.Path -Leaf
                        $estado = if ($pct -gt 90) { "${RED}CRITICO${NC}" } `
                                  elseif ($pct -gt 70) { "${YELLOW}ADVERTENCIA${NC}" } `
                                  else { "${GREEN}OK${NC}" }
                        Write-Host ("  {0,-20} {1,-10} {2,-10} {3,-8} " -f `
                            $user,$limite,$uso,"$pct%") -NoNewline
                        Write-Host $estado
                    }
                } catch {
                    aputs_error "FSRM no disponible: $($_.Exception.Message)"
                }
                pause_menu
            }
            "2" {
                Clear-Host
                _mostrar_banner "Eventos de Bloqueo FSRM"
                aputs_info "Buscando eventos de bloqueo en el log de FSRM..."
                try {
                    $events = Get-WinEvent -LogName "Microsoft-Windows-FSRM/Operational" `
                        -MaxEvents 20 -ErrorAction Stop |
                        Where-Object { $_.Id -in @(8215, 8214, 8210) }
                    if ($events.Count -eq 0) {
                        aputs_info "No hay eventos de bloqueo recientes."
                        aputs_info "Los bloqueos ocurren cuando un usuario intenta guardar un archivo prohibido."
                    } else {
                        $events | ForEach-Object {
                            Write-Host "  $($_.TimeCreated)  ID:$($_.Id)  $($_.Message.Substring(0, [Math]::Min(80,$_.Message.Length)))"
                        }
                    }
                } catch {
                    aputs_warning "No se encontraron eventos FSRM. El log puede estar vacio si no hay bloqueos aun."
                }
                pause_menu
            }
            "3" {
                Clear-Host
                _mostrar_banner "Ultimos Inicios de Sesion"
                Get-ADUser -Filter { LastLogonDate -gt "01/01/2020" } `
                    -Properties LastLogonDate, Department |
                    Sort-Object LastLogonDate -Descending |
                    Select-Object -First 20 |
                    Select-Object SamAccountName, Name, Department, LastLogonDate |
                    Format-Table -AutoSize
                pause_menu
            }
            "4" {
                Clear-Host
                _mostrar_banner "Sesiones Activas en el DC"
                aputs_info "Consultando sesiones activas..."
                try {
                    query session 2>&1 | ForEach-Object { Write-Host "  $_" }
                } catch {
                    aputs_warning "No se pudo obtener sesiones: $($_.Exception.Message)"
                }
                pause_menu
            }
            "5" {
                Clear-Host
                _mostrar_banner "Usuarios con LogonHours"
                $domainNC = Get-DomainNC -DomainName (Get-ADDomain).DNSRoot
                $users = Get-ADUser -Filter * -SearchBase $domainNC `
                    -Properties LogonHours, Department |
                    Sort-Object Department, SamAccountName

                Write-Host ("  {0,-12} {1,-15} {2}" -f "Usuario","Departamento","LogonHours")
                Write-Host "  ──────────────────────────────────────────"
                foreach ($u in $users) {
                    $tieneHoras = ($null -ne $u.LogonHours -and $u.LogonHours.Count -eq 21)
                    $icono      = if ($tieneHoras) { "${GREEN}●${NC}" } else { "${RED}○${NC}" }
                    $estadoLH   = if ($tieneHoras) { "Configurado" } else { "Sin restriccion" }
                    Write-Host ("  $icono {0,-12} {1,-15} {2}" -f `
                        $u.SamAccountName, $u.Department, $estadoLH)
                }
                pause_menu
            }
            "6" {
                Clear-Host
                _mostrar_banner "Cuentas Bloqueadas o Deshabilitadas"
                $domainNC = Get-DomainNC -DomainName (Get-ADDomain).DNSRoot

                # LockedOut no es filtrable con Get-ADUser -Filter.
                # Se usa Search-ADAccount para cuentas bloqueadas y
                # Get-ADUser -Filter para deshabilitadas por separado.
                $bloqueadas    = Search-ADAccount -LockedOut -SearchBase $domainNC `
                                 -ErrorAction SilentlyContinue
                $deshabilitadas = Get-ADUser -Filter { Enabled -eq $false } `
                                 -SearchBase $domainNC -Properties Department `
                                 -ErrorAction SilentlyContinue |
                                 Where-Object { $_.SamAccountName -notin @("Guest","krbtgt") }

                $todas = @($bloqueadas) + @($deshabilitadas) | Sort-Object SamAccountName -Unique

                if ($todas.Count -eq 0) {
                    aputs_success "No hay cuentas bloqueadas ni deshabilitadas."
                } else {
                    foreach ($u in $todas) {
                        $full = Get-ADUser $u.SamAccountName -Properties Enabled, LockedOut, Department -EA SilentlyContinue
                        if ($null -ne $full) {
                            $estadoB = if ($full.LockedOut) { "${RED}Bloqueada${NC}" } else { "" }
                            $estadoE = if (-not $full.Enabled) { "${YELLOW}Deshabilitada${NC}" } else { "" }
                            Write-Host "  $($full.SamAccountName)   $($full.Department)   $estadoB $estadoE"
                        }
                    }
                }
                pause_menu
            }
            "7" {
                Clear-Host
                _mostrar_banner "Log de la Practica"
                $logFile = "$script:TAREA08_BASE\tarea08.log"
                if (Test-Path $logFile) {
                    aputs_info "Ultimas 30 entradas de $logFile"
                    Write-Host ""
                    Get-Content $logFile | Select-Object -Last 30 |
                        ForEach-Object { Write-Host "  $_" }
                } else {
                    aputs_warning "Archivo de log no encontrado: $logFile"
                }
                pause_menu
            }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}

# 
# SUBMENU V — VERIFICACION GENERAL
# 
# 
# SUBMENU C - CLIENTES (Linux y Windows 10)
# 
function _menu_clientes {
    while ($true) {
        Clear-Host
        _mostrar_banner "Gestion de Clientes del Dominio"

        # Detectar hora para mostrar que grupo puede iniciar sesion
        $hora = (Get-Date).Hour
        if ($hora -ge 8 -and $hora -lt 15) {
            $grupoActivo = "${GREEN}GRP_Cuates${NC} (8AM-3PM) - user01-user05"
        } elseif ($hora -ge 15 -or $hora -lt 2) {
            $grupoActivo = "${GREEN}GRP_NoCuates${NC} (3PM-2AM) - user06-user10"
        } else {
            $grupoActivo = "${YELLOW}Fuera de horario (2AM-8AM)${NC}"
        }

        Write-Host "  Hora actual:    $(Get-Date -Format 'HH:mm')"
        Write-Host "  Grupo activo:   $grupoActivo"
        Write-Host ""

        # Detectar clientes dinamicamente desde AD y DNS
        # Sin hardcodear nombres ni IPs — busca equipos reales registrados
        $domainDNS   = (Get-ADDomain -EA SilentlyContinue).DNSRoot
        $allComputers = Get-ADComputer -Filter * -Properties OperatingSystem -EA SilentlyContinue |
                        Where-Object { $_.Name -ne $env:COMPUTERNAME }

        $linuxClients = @()
        $win10Clients = @()
        foreach ($c in $allComputers) {
            if ($c.OperatingSystem -like "*Linux*" -or $c.OperatingSystem -like "*Fedora*" -or
                $c.OperatingSystem -like "*Ubuntu*" -or $c.OperatingSystem -like "*Red Hat*") {
                $linuxClients += $c
            } elseif ($c.OperatingSystem -like "*Windows 10*" -or $c.OperatingSystem -like "*Windows 11*" -or
                      $c.OperatingSystem -notlike "*Server*") {
                $win10Clients += $c
            }
        }

        # Si no hay clientes con OS conocido, mostrar todos los no-DC
        if ($linuxClients.Count -eq 0 -and $win10Clients.Count -eq 0) {
            $win10Clients = $allComputers
        }

        # Mostrar estado de conectividad de cada cliente
        foreach ($c in $linuxClients) {
            $ok = $null -ne (Resolve-DnsName "$($c.Name).$domainDNS" -EA SilentlyContinue)
            $s  = if ($ok) { "${GREEN}o${NC}" } else { "${RED}o${NC}" }
            Write-Host "  $s  Cliente Linux  ($($c.Name))"
        }
        foreach ($c in $win10Clients) {
            $ok = $null -ne (Resolve-DnsName "$($c.Name).$domainDNS" -EA SilentlyContinue)
            $s  = if ($ok) { "${GREEN}o${NC}" } else { "${RED}o${NC}" }
            $ou = ($c.DistinguishedName -split ",")[1] -replace "OU=",""
            Write-Host "  $s  Cliente Win10  ($($c.Name) - OU=$ou)"
        }

        # Guardar nombre del Win10 para usarlo en las opciones
        $win10Name = if ($win10Clients.Count -gt 0) { $win10Clients[0].Name } else { $null }
        $linuxName = if ($linuxClients.Count -gt 0) { $linuxClients[0].Name } else { "cliente-linux" }
        Write-Host ""
        Write-Host "  ${GRAY}-- Cliente Linux -----------------------------------------------${NC}"
        Write-Host "  ${BLUE}1)${NC} Registrar cliente Linux en DNS del DC"
        Write-Host "  ${BLUE}2)${NC} Ver instrucciones para ejecutar main.sh en Linux"
        Write-Host ""
        Write-Host "  ${GRAY}-- Cliente Windows 10 ------------------------------------------${NC}"
        Write-Host "  ${BLUE}3)${NC} Registrar cliente Windows 10 en DNS del DC"
        Write-Host "  ${BLUE}4)${NC} Mover equipo Win10 a OU correcta segun hora actual"
        Write-Host "  ${BLUE}5)${NC} Quitar LogonHours temporalmente (prueba AppLocker)"
        Write-Host "  ${BLUE}6)${NC} Restaurar LogonHours"
        Write-Host "  ${BLUE}7)${NC} Ver estado del equipo Win10 en AD"
        Write-Host ""
        Write-Host "  ${BLUE}0)${NC} Volver"
        Write-Host ""

        $op = Read-Host "  Opcion"
        switch ($op) {
            "1" { _accion_registro_dns }
            "2" {
                Clear-Host
                _mostrar_banner "Instrucciones Cliente Linux"
                aputs_info "Ejecutar en el cliente Fedora ($linuxName):"
                Write-Host ""
                Write-Host "  sudo realm leave reprobados.local"
                Write-Host "  sudo bash ~/Documentos/sys_admin_prc/P8/main.sh"
                Write-Host ""
                aputs_info "El script se pausa si el DNS no esta registrado."
                aputs_info "Ejecutar opcion 1 primero si es necesario."
                pause_menu
            }
            "3" {
                Clear-Host
                _mostrar_banner "Registrar Cliente Windows 10 en DNS"
                $domainName = (Get-ADDomain -EA SilentlyContinue).DNSRoot
                if ($null -eq $domainName) { aputs_error "AD no disponible"; pause_menu; continue }
                # Detectar el equipo Win10 registrado en AD
                if ($null -eq $win10Name) {
                    aputs_warning "No hay equipos Win10 registrados en AD aun."
                    aputs_info    "Una vez unido el cliente, el registro DNS se crea automaticamente."
                } else {
                    $clientIP = Read-Host "  IP del cliente Win10 (ej: 192.168.100.40)"
                    try {
                        $existing = Get-DnsServerResourceRecord -ZoneName $domainName `
                            -Name $win10Name -RRType A -EA SilentlyContinue
                        if ($null -ne $existing) {
                            Remove-DnsServerResourceRecord -ZoneName $domainName `
                                -Name $win10Name -RRType A -Force -EA SilentlyContinue
                        }
                        Add-DnsServerResourceRecordA -ZoneName $domainName `
                            -Name $win10Name -IPv4Address $clientIP `
                            -TimeToLive "01:00:00" -EA Stop
                        aputs_success "DNS: $win10Name.$domainName -> $clientIP"
                    } catch {
                        aputs_error "Error: $($_.Exception.Message)"
                    }
                }
                pause_menu
            }
            "4" {
                Clear-Host
                _mostrar_banner "Mover Win10 a OU segun Hora Actual"
                $horaAhora = (Get-Date).Hour
                $domainNC  = (Get-DomainNC -DomainName (Get-ADDomain).DNSRoot)

                if ($horaAhora -ge 8 -and $horaAhora -lt 15) {
                    $ouTarget = "OU=Cuates,$domainNC"
                    $grupo    = "Cuates (8AM-3PM)"
                } else {
                    $ouTarget = "OU=NoCuates,$domainNC"
                    $grupo    = "NoCuates (3PM-2AM)"
                }

                aputs_info "Hora: $(Get-Date -Format 'HH:mm') -> OU $grupo"
                if ($null -eq $win10Name) {
                    aputs_error "No hay equipos Win10 registrados en AD."
                } else {
                    try {
                        $comp = Get-ADComputer $win10Name -EA Stop
                        if ($comp.DistinguishedName -like "*$ouTarget*") {
                            aputs_info "El equipo ya esta en $ouTarget"
                        } else {
                            Move-ADObject -Identity $comp.DistinguishedName -TargetPath $ouTarget -EA Stop
                            aputs_success "Equipo movido a: $ouTarget"
                        }
                        aputs_info "Ejecutar en Win10: gpupdate /force"
                    } catch {
                        aputs_error "Error: $($_.Exception.Message)"
                    }
                }
                pause_menu
            }
            "5" {
                Clear-Host
                _mostrar_banner "Quitar LogonHours (Para Prueba AppLocker)"
                aputs_warning "Esto quita la restriccion horaria de TODOS los usuarios."
                aputs_warning "Los usuarios podran iniciar sesion a cualquier hora."
                $confirm = Read-Host "  Escriba 'SI' para confirmar"
                if ($confirm -eq "SI") {
                    foreach ($sam in @("user01","user02","user03","user04","user05",
                                       "user06","user07","user08","user09","user10")) {
                        try {
                            $dn = (Get-ADUser $sam).DistinguishedName
                            $u  = New-Object DirectoryServices.DirectoryEntry("LDAP://$dn")
                            $u.Properties["logonHours"].Clear()
                            $u.CommitChanges()
                            $u.Dispose()
                            aputs_success "LogonHours quitados: $sam"
                        } catch {
                            aputs_warning "Error en $sam : $($_.Exception.Message)"
                        }
                    }
                    aputs_success "Todos los usuarios sin restriccion horaria."
                    aputs_warning "Recuerda restaurar con la opcion 6."
                }
                pause_menu
            }
            "6" {
                Clear-Host
                _mostrar_banner "Restaurar LogonHours"
                . "$SCRIPT_DIR\utilsAD.ps1"
                . "$SCRIPT_DIR\Functions-AD-C.ps1"
                aputs_info "Restaurando LogonHours..."
                Set-GroupLogonHours -GroupName "GRP_Cuates"   -StartHourLocal 8  -EndHourLocal 15
                Set-GroupLogonHours -GroupName "GRP_NoCuates" -StartHourLocal 15 -EndHourLocal 2
                aputs_success "Restaurados: Cuates 8AM-3PM | NoCuates 3PM-2AM"
                pause_menu
            }
            "7" {
                Clear-Host
                _mostrar_banner "Estado Win10 en AD"
                if ($null -eq $win10Name) {
                    aputs_error "No hay equipos Win10 registrados en AD."
                } else {
                    try {
                        $comp = Get-ADComputer $win10Name -Properties * -EA Stop
                        aputs_info "Nombre:  $($comp.Name)"
                        aputs_info "OU:      $($comp.DistinguishedName)"
                        aputs_info "Unido:   $($comp.WhenCreated)"
                        aputs_info "OS:      $($comp.OperatingSystem)"
                    } catch {
                        aputs_error "Equipo $win10Name no encontrado en AD."
                    }
                }
                pause_menu
            }
            "0" { return }
            default { aputs_error "Opcion invalida"; Start-Sleep -Seconds 1 }
        }
    }
}


function _menu_verificacion {
    Clear-Host
    _mostrar_banner "Verificacion General - Tarea 08"

    aputs_info "Servidor: $env:COMPUTERNAME"
    aputs_info "Fecha:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host ""
    draw_line

    # AD DS
    Write-Host ""
    aputs_info "-- Active Directory --"
    Write-Host ""
    if (_estado_ad) {
        $dom       = Get-ADDomain -ErrorAction SilentlyContinue
        $stOUs     = if (_estado_ous)      { "ok" } else { "fail" }
        $stUsers   = if (_estado_usuarios) { "ok" } else { "fail" }
        $cCuates   = (Get-ADGroupMember "GRP_Cuates"   -EA SilentlyContinue).Count
        $cNoCuates = (Get-ADGroupMember "GRP_NoCuates" -EA SilentlyContinue).Count
        _v_check "AD DS instalado y activo" "ok"    $dom.DNSRoot
        _v_check "OUs Cuates / NoCuates"    $stOUs
        _v_check "Usuarios en grupos"       $stUsers "Cuates: $cCuates | NoCuates: $cNoCuates"
    } else {
        _v_check "AD DS" "fail" "(no instalado)"
    }

    # LogonHours
    Write-Host ""
    aputs_info "-- LogonHours --"
    Write-Host ""
    foreach ($sam in @("user01","user06")) {
        try {
            $lhBytes  = @((Get-ADUser $sam -Properties LogonHours -EA Stop).LogonHours)
            $lhOk     = ($lhBytes.Count -eq 21)
            $lhStatus = if ($lhOk) { "ok"   } else { "fail" }
            $lhDetail = if ($lhOk) { "21 bytes configurados" } else { "sin configurar" }
            _v_check "LogonHours $sam" $lhStatus $lhDetail
        } catch {
            _v_check "LogonHours $sam" "skip" "(usuario no encontrado)"
        }
    }
    $gpoLogoff   = Get-GPO -Name "Politica-ForzarLogoff-T08" -EA SilentlyContinue
    $stGpoLogoff = if ($null -ne $gpoLogoff) { "ok" } else { "fail" }
    _v_check "GPO forzar logoff" $stGpoLogoff

    # FSRM
    Write-Host ""
    aputs_info "-- FSRM --"
    Write-Host ""
    $stFSRM = if (Test-WindowsFeatureInstalled "FS-Resource-Manager") { "ok" } else { "fail" }
    _v_check "Rol FSRM instalado" $stFSRM
    try {
        $q1 = Get-FsrmQuota "C:\Perfiles\user01" -EA Stop
        _v_check "Cuota user01 (10 MB)" "ok" "$([Math]::Round($q1.Size/1MB,0)) MB Hard"
    } catch { _v_check "Cuota user01" "fail" "(no encontrada)" }
    try {
        $q6 = Get-FsrmQuota "C:\Perfiles\user06" -EA Stop
        _v_check "Cuota user06 (5 MB)"  "ok" "$([Math]::Round($q6.Size/1MB,0)) MB Hard"
    } catch { _v_check "Cuota user06" "fail" "(no encontrada)" }
    try {
        $fs      = Get-FsrmFileScreen "C:\Perfiles\user01" -EA Stop
        $stFS    = if ($fs.Active) { "ok" } else { "warn" }
        _v_check "File Screen activo" $stFS $fs.Template
    } catch { _v_check "File Screen" "fail" "(no encontrado)" }

    # AppLocker
    Write-Host ""
    aputs_info "-- AppLocker --"
    Write-Host ""
    foreach ($gpoName in @("AppLocker-Cuates-T08","AppLocker-NoCuates-T08")) {
        $gpo   = Get-GPO -Name $gpoName -EA SilentlyContinue
        $stGpo = if ($null -ne $gpo) { "ok" } else { "fail" }
        _v_check $gpoName $stGpo
    }
    $appSvc   = Get-Service "AppIDSvc" -EA SilentlyContinue
    $stApp    = if ($null -ne $appSvc -and $appSvc.Status -eq "Running") { "ok" } else { "fail" }
    $appDet   = if ($null -ne $appSvc) { "$($appSvc.Status)" } else { "no encontrado" }
    _v_check "AppIDSvc" $stApp $appDet

    # SSH
    Write-Host ""
    aputs_info "-- SSH --"
    Write-Host ""
    $sshd   = Get-Service "sshd" -EA SilentlyContinue
    $stSSH  = if ($null -ne $sshd -and $sshd.Status -eq "Running") { "ok" } else { "fail" }
    _v_check "sshd" $stSSH
    $allow  = Get-Content "C:\ProgramData\ssh\sshd_config" -EA SilentlyContinue |
              Select-String "AllowUsers" | Select-Object -First 1
    $stAllow = if ($null -ne $allow) { "ok" } else { "warn" }
    _v_check "AllowUsers configurado" $stAllow "$allow"

    Write-Host ""
    draw_line
    aputs_success "Verificacion completada."
    pause_menu
}


# 
# ACCION S — REPARAR SSH
# 
function _accion_fix_ssh {
    Clear-Host
    _mostrar_banner "Reparar SSH post-DC"
    $fixScript = Join-Path $SCRIPT_DIR "Fix-SSH-DC.ps1"
    if (Test-Path $fixScript) {
        & "$fixScript"
    } else {
        aputs_error "Fix-SSH-DC.ps1 no encontrado en $SCRIPT_DIR"
    }
    pause_menu
}

# 
# ACCION D — REGISTRAR DNS CLIENTE LINUX
# 
function _accion_registro_dns {
    Clear-Host
    _mostrar_banner "Registrar Cliente Linux en DNS"
    $dnsScript = Join-Path $SCRIPT_DIR "Register-ClientDNS.ps1"
    if (Test-Path $dnsScript) {
        & "$dnsScript"
    } else {
        aputs_error "Register-ClientDNS.ps1 no encontrado en $SCRIPT_DIR"
        aputs_info  "Ejecute manualmente:"
        Write-Host ""
        $domainFallback = (Get-ADDomain -EA SilentlyContinue).DNSRoot
        Write-Host "  Add-DnsServerResourceRecordA \"
        Write-Host "      -ZoneName '$domainFallback' \"
        Write-Host "      -Name 'NOMBRE_CLIENTE_LINUX' \"
        Write-Host "      -IPv4Address 'IP_CLIENTE_LINUX' \"
        Write-Host "      -TimeToLive 01:00:00"
    }
    pause_menu
}

# 
# PANTALLA DE BIENVENIDA
# Detecta el estado del entorno y decide que mostrar:
#   - Sin AD instalado   -> ofrece instalacion desde cero
#   - AD instalado       -> ofrece el menu interactivo (con opcion de re-instalar)
# 
function _pantalla_bienvenida {
    Clear-Host
    _mostrar_banner "Tarea 08 — AD Governance"

    Write-Host "  Servidor: $env:COMPUTERNAME"
    Write-Host "  Fecha:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host ""
    draw_line

    $adActivo = _estado_ad

    if ($adActivo) {
        # ── AD ya instalado: mostrar resumen y opciones ──────────────────
        $dom = Get-ADDomain -ErrorAction SilentlyContinue

        Write-Host ""
        Write-Host "  ${GREEN}●${NC} Active Directory configurado"
        Write-Host "    Dominio:  ${CYAN}$($dom.DNSRoot)${NC}"
        Write-Host "    NetBIOS:  $($dom.NetBIOSName)"
        Write-Host "    DC:       $($dom.PDCEmulator)"
        Write-Host ""

        # Indicadores rapidos de estado
        Write-Host "  Estado de componentes:"
        Write-Host "    $(_icono_estado (_estado_ous))    OUs y grupos"
        Write-Host "    $(_icono_estado (_estado_usuarios))    Usuarios importados"
        Write-Host "    $(_icono_estado (_estado_logonhours))    LogonHours configurados"
        Write-Host "    $(_icono_estado (_estado_fsrm))    FSRM (cuotas + screening)"
        Write-Host "    $(_icono_estado (_estado_applocker))    AppLocker"
        Write-Host "    $(_icono_estado (_estado_appidsvc))    AppIDSvc"
        Write-Host ""
        draw_line
        Write-Host ""
        Write-Host "  ${BLUE}1)${NC} Ingresar al menu de administracion"
        Write-Host "  ${BLUE}2)${NC} Re-ejecutar instalacion completa"
        Write-Host "       ${YELLOW}(advertencia: el dominio ya esta configurado)${NC}"
        Write-Host "  ${BLUE}0)${NC} Salir"
        Write-Host ""

        $op = Read-Host "  Opcion"
        switch ($op) {
            "1" { main_menu }
            "2" {
                Clear-Host
                _mostrar_banner "Re-ejecutar Instalacion"
                Write-Host ""
                aputs_warning "ADVERTENCIA: El dominio $($dom.DNSRoot) ya esta instalado y configurado."
                aputs_warning "Re-ejecutar la instalacion puede generar conflictos si AD ya esta promovido."
                aputs_info    "Las fases B-E son idempotentes y se pueden re-ejecutar sin problema."
                aputs_info    "La Fase A (instalacion de AD DS) se saltara si ya esta instalada."
                Write-Host ""
                $confirm = Read-MenuInput "Escriba 'CONFIRMAR' para continuar o Enter para cancelar"
                if ($confirm -eq "CONFIRMAR") {
                    # Leer el dominio del estado guardado o del AD activo
                    $storedDomain = Get-StoredDomainName
                    if ($null -eq $storedDomain) { $storedDomain = $dom.DNSRoot }

                    # Retroceder estado a AD_INSTALLED para re-ejecutar fases B-E
                    "AD_INSTALLED"     | Out-File $script:INSTALL_STATE -Encoding UTF8 -Force
                    "DOMAIN=$storedDomain" | Add-Content $script:INSTALL_STATE -Encoding UTF8
                    aputs_info "Estado reiniciado. Ejecutando fases B-E..."
                    pause_menu

                    # Ejecutar fases B a E
                    Invoke-PhaseB -DomainName $storedDomain
                    Invoke-PhaseC -DomainName $storedDomain
                    Invoke-PhaseD
                    Invoke-PhaseE -DomainName $storedDomain

                    aputs_success "Re-ejecucion completada."
                    pause_menu
                    main_menu
                } else {
                    aputs_info "Operacion cancelada."
                    pause_menu
                    _pantalla_bienvenida
                }
            }
            "0" {
                Write-Host ""
                aputs_info "Saliendo..."
                exit 0
            }
            default {
                aputs_error "Opcion invalida"
                Start-Sleep -Seconds 1
                _pantalla_bienvenida
            }
        }

    } else {
        # ── AD no instalado: ofrecer instalacion desde cero ─────────────
        Write-Host ""
        Write-Host "  ${RED}○${NC} Active Directory NO esta instalado en este servidor."
        Write-Host ""
        aputs_info "Este script instalara y configurara:"
        Write-Host "    • Active Directory Domain Services (AD DS)"
        Write-Host "    • DNS Server"
        Write-Host "    • OUs Cuates y NoCuates con 10 usuarios"
        Write-Host "    • LogonHours por grupo"
        Write-Host "    • FSRM con cuotas hard (10MB / 5MB)"
        Write-Host "    • File Screening activo (.mp3 .mp4 .exe .msi)"
        Write-Host "    • AppLocker por hash"
        Write-Host ""
        draw_line
        Write-Host ""

        # Verificar prerequisitos antes de ofrecer la instalacion
        $validationsPassed = Invoke-AllValidations
        Write-Host ""

        if (-not $validationsPassed) {
            aputs_error "Prerequisitos no cumplidos. Corrija los errores y vuelva a ejecutar."
            pause_menu
            exit 1
        }

        Write-Host "  ${BLUE}1)${NC} Iniciar instalacion completa desde cero"
        Write-Host "  ${BLUE}0)${NC} Salir"
        Write-Host ""

        $op = Read-Host "  Opcion"
        switch ($op) {
            "1" {
                # Pedir nombre del dominio
                $domainName = Request-DomainName
                if ($null -eq $domainName) {
                    aputs_warning "Instalacion cancelada."
                    exit 0
                }

                # Confirmacion final
                draw_line
                aputs_warning "Se instalara Active Directory. El servidor se REINICIARA automaticamente."
                aputs_warning "Dominio: $domainName"
                draw_line
                $confirm = Read-MenuInput "Escriba 'SI' para confirmar"
                if ($confirm -eq "SI") {
                    # Invoke-PhaseA maneja el reinicio y la tarea programada
                    Invoke-PhaseA -DomainName $domainName
                } else {
                    aputs_info "Instalacion cancelada."
                    pause_menu
                }
            }
            "0" {
                Write-Host ""
                aputs_info "Saliendo..."
                exit 0
            }
            default {
                aputs_error "Opcion invalida"
                Start-Sleep -Seconds 1
                _pantalla_bienvenida
            }
        }
    }
}

# 
# PUNTO DE ENTRADA
# 

# Verificar privilegios
if (-not (check_privileges)) {
    Write-Host ""
    aputs_error "Este script requiere permisos de Administrador."
    aputs_info  "Haga clic derecho en PowerShell -> Ejecutar como administrador"
    Write-Host ""
    exit 1
}

# Lanzar pantalla de bienvenida inteligente
_pantalla_bienvenida