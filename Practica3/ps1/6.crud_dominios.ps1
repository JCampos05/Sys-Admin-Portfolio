#
# Módulo principal para gestión de dominios DNS ABC
#

# Cargar submódulos ABC
. (Join-Path $PSScriptRoot "crud_listar.ps1")
. (Join-Path $PSScriptRoot "crud_agregar.ps1")
. (Join-Path $PSScriptRoot "crud_eliminar.ps1")

function Show-CRUDDomainsMenu {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-InfoMessage "┌────────────────────────────────────┐"
        Write-InfoMessage "|---|  Gestión de Dominios DNS   |---|"
        Write-InfoMessage "└────────────────────────────────────┘"
        
        Write-Host ""
        Write-InfoMessage "Seleccione una operación:"
        Write-Host ""
        Write-InfoMessage "1) Listar dominios y registros"
        Write-InfoMessage "2) Agregar nuevo dominio"
        Write-InfoMessage "3) Agregar registro a dominio existente"
        Write-InfoMessage "4) Eliminar registro o dominio"
        Write-InfoMessage "5) Volver al menú principal"
        Write-Host ""
        
        $crudOp = Read-Host "Opción"
        
        switch ($crudOp) {
            "1" {
                Show-ListMenu
            }
            "2" {
                Add-CompleteDNSDomain
            }
            "3" {
                Add-RecordToExistingDomain
            }
            "4" {
                Show-DeleteMenu
            }
            "5" {
                return
            }
            default {
                Write-ErrorMessage "Opción inválida"
                Start-Sleep -Seconds 1
                continue
            }
        }
        
        if ($crudOp -ne "5") {
            Write-Host ""
            Invoke-Pause
        }
    }
}

function Invoke-CrudDominios {
    # Verificar privilegios
    if (-not (Test-AdminPrivileges)) {
        return
    }
    
    # Verificar que DNS esté instalado
    if (-not (Test-WindowsFeatureInstalled -FeatureName "DNS")) {
        Clear-Host
        Write-Header "CRUD DOMINIOS"
        Write-ErrorMessage "Rol DNS no está instalado"
        Write-Host ""
        Write-InfoMessage "Ejecute primero la opción '2) Instalar/config servicio DNS'"
        return
    }
    
    # Verificar que el servicio DNS esté funcionando
    if (-not (Test-ServiceActive -ServiceName "DNS")) {
        Clear-Host
        Write-Header "CRUD DOMINIOS"
        Write-WarningCustom "El servicio DNS no está activo"
        Write-Host ""
        
        $respuesta = Read-Host "¿Desea iniciar el servicio DNS? (S/N)"
        
        if ($respuesta -eq 'S' -or $respuesta -eq 's') {
            try {
                Start-Service -Name DNS -ErrorAction Stop
                Write-SuccessMessage "Servicio DNS iniciado correctamente"
                Start-Sleep -Seconds 2
            }
            catch {
                Write-ErrorMessage "No se pudo iniciar el servicio: $($_.Exception.Message)"
                Write-Host ""
                Write-InfoMessage "Inicie el servicio manualmente antes de continuar"
                return
            }
        }
        else {
            Write-InfoMessage "El servicio DNS debe estar activo para gestionar dominios"
            return
        }
    }
    
    # Mostrar menú principal
    Show-CRUDDomainsMenu
}

# Ejecutar si se llama directamente
if ($MyInvocation.InvocationName -ne '.') {
    # Cargar utilidades si no están cargadas
    if (-not (Get-Command Write-InfoMessage -ErrorAction SilentlyContinue)) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        . (Join-Path $scriptDir "utils.ps1")
    }
    
    Invoke-CrudDominios
}