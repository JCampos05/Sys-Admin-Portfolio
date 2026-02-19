# 
# Submódulo para eliminar dominios y registros DNS
# 
function Remove-SpecificDNSRecord {
    Clear-Host
    Write-Header "Eliminar Registro Específico"
    
    # Listar dominios disponibles
    Write-InfoMessage "Dominios disponibles:"
    Write-Host ""
    
    try {
        $zonas = Get-DnsServerZone -ErrorAction Stop | 
                Where-Object { $_.IsAutoCreated -eq $false -and $_.ZoneName -notlike "_*" -and $_.IsReverseLookupZone -eq $false }
        
        if (-not $zonas -or $zonas.Count -eq 0) {
            Write-Host ""
            Write-WarningCustom "No hay dominios configurados"
            return
        }
        
        foreach ($zona in $zonas | Sort-Object ZoneName) {
            Write-Host "  - $($zona.ZoneName)"
        }
        
        Write-Host ""
        
        $dominio = Read-Host "Dominio"
        
        if ([string]::IsNullOrWhiteSpace($dominio)) {
            Write-ErrorMessage "Debe especificar un dominio"
            return
        }
        
        # Verificar que el dominio existe
        $zonaEncontrada = $zonas | Where-Object { $_.ZoneName -eq $dominio }
        
        if (-not $zonaEncontrada) {
            Write-ErrorMessage "El dominio '$dominio' no existe"
            return
        }
        
        Write-Host ""
        Write-InfoMessage "Registros del dominio $dominio`:"
        Write-Host ""
        
        # Mostrar registros (excluyendo SOA)
        $registros = Get-DnsServerResourceRecord -ZoneName $dominio -ErrorAction Stop | 
                    Where-Object { $_.RecordType -ne "SOA" }
        
        if (-not $registros -or $registros.Count -eq 0) {
            Write-WarningCustom "No hay registros eliminables en este dominio"
            return
        }
        
        $contador = 1
        $listaRegistros = @()
        
        foreach ($record in $registros) {
            $hostname = if ($record.HostName -eq "@") { "@" } else { $record.HostName }
            $listaRegistros += $record
            
            switch ($record.RecordType) {
                "A" {
                    Write-Host "$contador) $hostname IN A $($record.RecordData.IPv4Address)"
                }
                "AAAA" {
                    Write-Host "$contador) $hostname IN AAAA $($record.RecordData.IPv6Address)"
                }
                "CNAME" {
                    Write-Host "$contador) $hostname IN CNAME $($record.RecordData.HostNameAlias)"
                }
                "MX" {
                    Write-Host "$contador) $hostname IN MX $($record.RecordData.Preference) $($record.RecordData.MailExchange)"
                }
                "NS" {
                    Write-Host "$contador) $hostname IN NS $($record.RecordData.NameServer)"
                }
                "TXT" {
                    Write-Host "$contador) $hostname IN TXT `"$($record.RecordData.DescriptiveText)`""
                }
                default {
                    Write-Host "$contador) $hostname IN $($record.RecordType)"
                }
            }
            $contador++
        }
        
        Write-Host ""
        
        $numeroRegistro = Read-Host "Número del registro a eliminar"
        
        if ([string]::IsNullOrWhiteSpace($numeroRegistro) -or $numeroRegistro -notmatch '^\d+$') {
            Write-ErrorMessage "Debe especificar un número válido"
            return
        }
        
        $indice = [int]$numeroRegistro - 1
        
        if ($indice -lt 0 -or $indice -ge $listaRegistros.Count) {
            Write-ErrorMessage "Número de registro inválido"
            return
        }
        
        $registroAEliminar = $listaRegistros[$indice]
        
        Write-Host ""
        Write-WarningCustom "¿Está seguro de eliminar el registro seleccionado?"
        $confirmar = Read-Host "Escriba 'CONFIRMAR' para proceder"
        
        if ($confirmar -ne "CONFIRMAR") {
            Write-InfoMessage "Eliminación cancelada"
            return
        }
        
        Write-Host ""
        
        # Eliminar registro
        try {
            Remove-DnsServerResourceRecord -ZoneName $dominio `
                                          -InputObject $registroAEliminar `
                                          -Force `
                                          -ErrorAction Stop
            
            Write-SuccessMessage "Registro eliminado correctamente"
            
            # Preguntar si reiniciar
            Write-Host ""
            $reiniciar = Read-Host "¿Reiniciar servicio DNS? (S/N)"
            
            if ($reiniciar -eq 'S' -or $reiniciar -eq 's') {
                try {
                    Restart-Service -Name DNS -Force -ErrorAction Stop
                    Write-SuccessMessage "Servicio reiniciado"
                }
                catch {
                    Write-ErrorMessage "Error al reiniciar servicio: $($_.Exception.Message)"
                }
            }
        }
        catch {
            Write-ErrorMessage "Error al eliminar registro: $($_.Exception.Message)"
        }
    }
    catch {
        Write-ErrorMessage "Error: $($_.Exception.Message)"
    }
}

function Remove-CompleteDomain {
    Clear-Host
    Write-Header "Eliminar Dominio Completo"
    
    Write-WarningCustom "ADVERTENCIA: Esta acción eliminará el dominio y TODOS sus registros"
    Write-Host ""
    
    # Listar dominios disponibles
    Write-InfoMessage "Dominios disponibles:"
    Write-Host ""
    
    try {
        $zonas = Get-DnsServerZone -ErrorAction Stop | 
                Where-Object { $_.IsAutoCreated -eq $false -and $_.ZoneName -notlike "_*" -and $_.IsReverseLookupZone -eq $false }
        
        if (-not $zonas -or $zonas.Count -eq 0) {
            Write-Host ""
            Write-WarningCustom "No hay dominios configurados"
            return
        }
        
        foreach ($zona in $zonas | Sort-Object ZoneName) {
            Write-Host "  - $($zona.ZoneName)"
        }
        
        Write-Host ""
        
        $dominioEliminar = Read-Host "Nombre del dominio a eliminar"
        
        if ([string]::IsNullOrWhiteSpace($dominioEliminar)) {
            Write-ErrorMessage "Debe especificar un dominio"
            return
        }
        
        # Verificar que el dominio existe
        $zonaEncontrada = $zonas | Where-Object { $_.ZoneName -eq $dominioEliminar }
        
        if (-not $zonaEncontrada) {
            Write-ErrorMessage "El dominio '$dominioEliminar' no existe"
            return
        }
        
        Write-Host ""
        
        # Preguntar por zona inversa
        $eliminarZonaInversa = Read-Host "¿Eliminar también zona inversa? (S/N) [S]"
        if ([string]::IsNullOrWhiteSpace($eliminarZonaInversa)) {
            $eliminarZonaInversa = "S"
        }
        
        # Preguntar por backup
        $hacerBackup = Read-Host "¿Hacer backup antes de eliminar? (S/N) [S]"
        if ([string]::IsNullOrWhiteSpace($hacerBackup)) {
            $hacerBackup = "S"
        }
        
        Write-Host ""
        Write-WarningCustom "¿Está seguro de eliminar el dominio '$dominioEliminar' y TODOS sus registros?"
        $confirmar = Read-Host "Escriba el nombre completo del dominio para confirmar"
        
        if ($confirmar -ne $dominioEliminar) {
            Write-InfoMessage "Eliminación cancelada"
            return
        }
        
        Write-Host ""
        Write-SeparatorLine
        Write-Host ""
        
        # Hacer backup si se solicitó
        if ($hacerBackup -eq 'S' -or $hacerBackup -eq 's') {
            $backupDir = Join-Path $env:USERPROFILE "dns_backups\dominio_${dominioEliminar}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            
            try {
                New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
                
                Write-InfoMessage "Creando backup..."
                
                # Exportar zona a archivo
                $backupFile = Join-Path $backupDir "${dominioEliminar}_backup.txt"
                Get-DnsServerResourceRecord -ZoneName $dominioEliminar | 
                    Out-File -FilePath $backupFile -ErrorAction Stop
                
                Write-SuccessMessage "Backup creado en: $backupDir"
                Write-Host ""
            }
            catch {
                Write-WarningCustom "No se pudo crear backup completo: $($_.Exception.Message)"
                Write-Host ""
            }
        }
        
        # Eliminar zona directa
        Write-InfoMessage "Eliminando zona directa..."
        try {
            Remove-DnsServerZone -Name $dominioEliminar -Force -ErrorAction Stop
            Write-SuccessMessage "Zona directa eliminada: $dominioEliminar"
        }
        catch {
            Write-ErrorMessage "Error al eliminar zona directa: $($_.Exception.Message)"
            return
        }
        
        # Eliminar zona inversa si existe y se solicitó
        if ($eliminarZonaInversa -eq 'S' -or $eliminarZonaInversa -eq 's') {
            Write-InfoMessage "Buscando zonas inversas relacionadas..."
            
            try {
                $zonasInversas = Get-DnsServerZone -ErrorAction SilentlyContinue | 
                                Where-Object { $_.IsReverseLookupZone -eq $true }
                
                foreach ($zonaInversa in $zonasInversas) {
                    # Verificar si tiene registros PTR que apuntan al dominio eliminado
                    $recordsPTR = Get-DnsServerResourceRecord -ZoneName $zonaInversa.ZoneName -RRType PTR -ErrorAction SilentlyContinue |
                                 Where-Object { $_.RecordData.PtrDomainName -like "*$dominioEliminar*" }
                    
                    if ($recordsPTR) {
                        Write-InfoMessage "Eliminando zona inversa: $($zonaInversa.ZoneName)..."
                        Remove-DnsServerZone -Name $zonaInversa.ZoneName -Force -ErrorAction SilentlyContinue
                        Write-SuccessMessage "Zona inversa eliminada: $($zonaInversa.ZoneName)"
                    }
                }
            }
            catch {
                Write-WarningCustom "No se pudo eliminar zona inversa: $($_.Exception.Message)"
            }
        }
        
        Write-Host ""
        Write-SeparatorLine
        Write-Host ""
        
        # Reiniciar servicio
        Write-WarningCustom "Se requiere reiniciar el servicio para aplicar cambios"
        $reiniciar = Read-Host "¿Reiniciar servicio DNS ahora? (S/N)"
        
        if ($reiniciar -eq 'S' -or $reiniciar -eq 's') {
            Write-InfoMessage "Reiniciando servicio..."
            
            try {
                Restart-Service -Name DNS -Force -ErrorAction Stop
                Start-Sleep -Seconds 2
                
                $service = Get-Service -Name DNS
                if (Test-ServiceActive -ServiceName "DNS") {
                    Write-SuccessMessage "Servicio reiniciado correctamente"
                }
                else {
                    Write-ErrorMessage "El servicio no se inicio correctamente"
                }
            }
            catch {
                Write-ErrorMessage "Error al reiniciar servicio: $($_.Exception.Message)"
            }
        }
        else {
            Write-InfoMessage "Recuerde reiniciar el servicio manualmente"
        }
        
        Write-Host ""
        Write-SeparatorLine
        Write-Host ""
        
        Write-SuccessMessage "Dominio eliminado exitosamente"
        Write-Host ""
    }
    catch {
        Write-ErrorMessage "Error: $($_.Exception.Message)"
    }
}

function Show-DeleteMenu {
    Clear-Host
    Write-Header "Eliminar"
    
    Write-WarningCustom "Esta operación es irreversible"
    Write-Host ""
    Write-InfoMessage "¿Qué desea eliminar?"
    Write-Host ""
    Write-InfoMessage "1) Eliminar un registro específico"
    Write-InfoMessage "2) Eliminar dominio completo"
    Write-Host ""
    
    $elimType = Read-Host "Opción"
    
    switch ($elimType) {
        "1" {
            Remove-SpecificDNSRecord
        }
        "2" {
            Remove-CompleteDomain
        }
        default {
            Write-ErrorMessage "Opción inválida"
        }
    }
}