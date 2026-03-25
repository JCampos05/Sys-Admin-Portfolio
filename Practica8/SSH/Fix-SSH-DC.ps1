#
# Fix-SSH-DC.ps1
#
#   1. Verifica que el servicio sshd este corriendo
#   2. Hace un backup del sshd_config actual
#   3. Corrige la linea AllowUsers para apuntar al usuario de dominio
#   4. Se asegura que PasswordAuthentication este activo
#   5. Reinicia el servicio sshd
#   6. Verifica que el puerto 22 quedo en escucha
#

#Requires -Version 5.1

. "$PSScriptRoot\utils.ps1"

# -------------------------------------------------------------------------
# Datos del entorno
# El NetBIOS del dominio se detecta automaticamente desde el sistema.
# Si el servidor aun no es DC, se usa el nombre del equipo como fallback.
# -------------------------------------------------------------------------
$ADMIN_USER  = "Administrador"
$SSHD_CONFIG = "C:\ProgramData\ssh\sshd_config"
$SSHD_BACKUP = "C:\ProgramData\ssh\sshd_config.bak"

# Detectar el NetBIOS del dominio automaticamente
try {
    $domainInfo     = Get-ADDomain -ErrorAction Stop
    $DOMAIN_NETBIOS = $domainInfo.NetBIOSName
    aputs_info "Dominio detectado automaticamente: $DOMAIN_NETBIOS"
} catch {
    # Si AD no responde (snapshot pre-DC o AD no instalado), usar nombre del equipo
    $DOMAIN_NETBIOS = $env:COMPUTERNAME
    aputs_warning "No se pudo detectar el dominio AD. Usando nombre de equipo: $DOMAIN_NETBIOS"
}

# -------------------------------------------------------------------------
# Invoke-SSHFix
# Funcion principal que ejecuta todos los pasos de reparacion.
# -------------------------------------------------------------------------
function Invoke-SSHFix {
    draw_header "Fix-SSH-DC: Reconfiguracion de SSH para Domain Controller"

    # Verificar privilegios
    if (-not (check_privileges)) {
        aputs_error "Este script requiere privilegios de Administrador."
        exit 1
    }

    # Paso 1: Verificar que OpenSSH esta instalado
    aputs_info "Paso 1/5: Verificando servicio sshd..."
    $sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($null -eq $sshd) {
        aputs_error "El servicio sshd no existe. OpenSSH no esta instalado."
        aputs_info  "Instale OpenSSH desde: Configuracion > Aplicaciones > Caracteristicas opcionales"
        exit 1
    }
    aputs_success "Servicio sshd encontrado. Estado: $($sshd.Status)"

    # Verificar que el archivo de configuracion existe
    if (-not (Test-Path $SSHD_CONFIG)) {
        aputs_error "Archivo sshd_config no encontrado en: $SSHD_CONFIG"
        exit 1
    }

    # Paso 2: Backup del config actual
    aputs_info "Paso 2/5: Creando backup del sshd_config actual..."
    try {
        Copy-Item -Path $SSHD_CONFIG -Destination $SSHD_BACKUP -Force
        aputs_success "Backup creado en: $SSHD_BACKUP"
    } catch {
        aputs_warning "No se pudo crear backup: $($_.Exception.Message)"
        aputs_warning "Continuando sin backup..."
    }

    # Paso 3: Leer y corregir el sshd_config
    aputs_info "Paso 3/5: Corrigiendo sshd_config para entorno de DC..."

    $config = Get-Content $SSHD_CONFIG -Encoding UTF8

    # Mostrar el estado actual de las lineas criticas
    aputs_info "Estado actual de lineas criticas:"
    $config | Select-String "AllowUsers|PasswordAuthentication|Match Group" |
              ForEach-Object { Write-Host "  $_" }

    $targetAllowUsers = "AllowUsers $DOMAIN_NETBIOS\$ADMIN_USER"

    $config = $config | ForEach-Object {
        if ($_ -match "^AllowUsers\s+") {
            # Reemplazar cualquier variante de AllowUsers por la correcta
            $targetAllowUsers
        } else {
            $_
        }
    }

    $hasPwdAuth = $config | Where-Object { $_ -match "^PasswordAuthentication\s+yes" }
    if ($null -eq $hasPwdAuth) {
        # Buscar si hay una linea comentada y reemplazarla
        $config = $config | ForEach-Object {
            if ($_ -match "^#\s*PasswordAuthentication") {
                "PasswordAuthentication yes"
            } else {
                $_
            }
        }

        # Si no habia ninguna (ni comentada), agregarla al final
        $stillMissing = $config | Where-Object { $_ -match "^PasswordAuthentication" }
        if ($null -eq $stillMissing) {
            $config += "PasswordAuthentication yes"
        }
    }

    # Guardar el config corregido
    try {
        $config | Set-Content $SSHD_CONFIG -Encoding UTF8 -Force
        aputs_success "sshd_config actualizado correctamente"
    } catch {
        aputs_error "Error al guardar sshd_config: $($_.Exception.Message)"
        aputs_info  "Restaurando backup..."
        Copy-Item -Path $SSHD_BACKUP -Destination $SSHD_CONFIG -Force
        exit 1
    }

    # Mostrar el estado final de las lineas criticas para confirmar
    aputs_info "Estado FINAL de lineas criticas:"
    Get-Content $SSHD_CONFIG | Select-String "AllowUsers|PasswordAuthentication|Match Group" |
        ForEach-Object { Write-Host "  $_" }

    # Paso 4: Reiniciar sshd
    aputs_info "Paso 4/5: Reiniciando servicio sshd..."
    try {
        Restart-Service sshd -Force -ErrorAction Stop
        aputs_success "Servicio sshd reiniciado."
    } catch {
        aputs_error "Error al reiniciar sshd: $($_.Exception.Message)"
        exit 1
    }

    # Paso 5: Verificar que el puerto 22 quedo en escucha
    aputs_info "Paso 5/5: Verificando que el puerto 22 esta en escucha..."
    Start-Sleep -Seconds 2

    $port22 = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
    if ($null -ne $port22) {
        aputs_success "Puerto 22 en escucha. SSH listo para conexiones."
    } else {
        aputs_error "Puerto 22 no esta en escucha. Revise el log de eventos."
        aputs_info  "Ejecute: Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 5"
    }

    draw_line
    aputs_success "Reconfiguracion SSH completada."
    aputs_info    "Conectese desde la maquina fisica con:"
    Write-Host    "  ssh $DOMAIN_NETBIOS\$ADMIN_USER@192.168.75.128"
    draw_line
}

# Punto de entrada
Invoke-SSHFix

#powershell -ExecutionPolicy Bypass -File "C:\Users\Administrador\Documents\Scripts\P8\Fix-SSH-DC.ps1"