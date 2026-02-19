# 
# Submódulo para listar dominios y registros DNS
# 
function Show-SimpledomainList {
    Clear-Host
    Write-Header "Listado de Dominios"
    
    try {
        $zonas = Get-DnsServerZone -ErrorAction Stop | 
                Where-Object { $_.IsAutoCreated -eq $false -and $_.ZoneName -notlike "_*" -and $_.IsReverseLookupZone -eq $false }
        
        if (-not $zonas -or $zonas.Count -eq 0) {
            Write-InfoMessage "No hay dominios configurados"
            return
        }
        
        Write-InfoMessage "Dominios configurados: $($zonas.Count)"
        Write-Host ""
        
        $contador = 1
        foreach ($zona in $zonas | Sort-Object ZoneName) {
            Write-Host "  $contador) $($zona.ZoneName)"
            $contador++
        }
    }
    catch {
        Write-ErrorMessage "Error al listar dominios: $($_.Exception.Message)"
    }
}

function Show-SummaryDomainList {
    Clear-Host
    Write-Header "Listado de Dominios Resumidos"
    
    try {
        $zonas = Get-DnsServerZone -ErrorAction Stop | 
                Where-Object { $_.IsAutoCreated -eq $false -and $_.ZoneName -notlike "_*" -and $_.IsReverseLookupZone -eq $false }
        
        if (-not $zonas -or $zonas.Count -eq 0) {
            Write-InfoMessage "No hay dominios configurados"
            return
        }
        
        Write-InfoMessage "Total de dominios: $($zonas.Count)"
        Write-Host ""
        Write-SeparatorLine
        Write-Host ""
        
        foreach ($zona in $zonas | Sort-Object ZoneName) {
            Write-Host "Dominio: $($zona.ZoneName)"
            
            # Obtener IP principal (registro @)
            try {
                $recordA = Get-DnsServerResourceRecord -ZoneName $zona.ZoneName -RRType A -ErrorAction SilentlyContinue |
                          Where-Object { $_.HostName -eq "@" } | Select-Object -First 1
                
                if ($recordA) {
                    Write-Host "  IP principal: $($recordA.RecordData.IPv4Address)"
                }
                else {
                    Write-Host "  IP principal: No configurado"
                }
            }
            catch {
                Write-Host "  IP principal: No disponible"
            }
            
            # Contar registros
            try {
                $registros = Get-DnsServerResourceRecord -ZoneName $zona.ZoneName -ErrorAction SilentlyContinue
                Write-Host "  Registros: $($registros.Count)"
            }
            catch {
                Write-Host "  Registros: N/A"
            }
            
            # Tipo de zona
            Write-Host "  Tipo: $($zona.ZoneType)"
            
            # Estado
            Write-Host "  Estado: OK"
            
            Write-Host ""
        }
    }
    catch {
        Write-ErrorMessage "Error al listar dominios: $($_.Exception.Message)"
    }
}

function Show-DetailedDomainList {
    Clear-Host
    Write-Header "Listado de Dominios Detallado"
    
    try {
        $zonas = Get-DnsServerZone -ErrorAction Stop | 
                Where-Object { $_.IsAutoCreated -eq $false -and $_.ZoneName -notlike "_*" -and $_.IsReverseLookupZone -eq $false }
        
        if (-not $zonas -or $zonas.Count -eq 0) {
            Write-InfoMessage "No hay dominios configurados"
            return
        }
        
        foreach ($zona in $zonas | Sort-Object ZoneName) {
            Write-Host ""
            Write-SeparatorLine
            Write-SuccessMessage "DOMINIO: $($zona.ZoneName)"
            Write-SeparatorLine
            Write-Host ""
            
            # Mostrar registro SOA
            Write-InfoMessage "Registro SOA:"
            try {
                $soa = Get-DnsServerResourceRecord -ZoneName $zona.ZoneName -RRType SOA -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($soa) {
                    Write-Host "  Servidor primario: $($soa.RecordData.PrimaryServer)"
                    Write-Host "  Responsable: $($soa.RecordData.ResponsiblePerson)"
                    Write-Host "  Serial: $($soa.RecordData.SerialNumber)"
                    Write-Host "  Refresh: $($soa.RecordData.RefreshInterval)"
                    Write-Host "  Retry: $($soa.RecordData.RetryDelay)"
                    Write-Host "  Expire: $($soa.RecordData.ExpireLimit)"
                    Write-Host "  Minimum TTL: $($soa.RecordData.MinimumTimeToLive)"
                }
            }
            catch {
                Write-Host "  No disponible"
            }
            Write-Host ""
            
            # Mostrar registros NS
            Write-InfoMessage "Servidores de Nombres (NS):"
            try {
                $ns = Get-DnsServerResourceRecord -ZoneName $zona.ZoneName -RRType NS -ErrorAction SilentlyContinue
                if ($ns) {
                    foreach ($record in $ns) {
                        Write-Host "  $($record.HostName) IN NS $($record.RecordData.NameServer)"
                    }
                }
                else {
                    Write-Host "  Ninguno"
                }
            }
            catch {
                Write-Host "  Error al obtener registros NS"
            }
            Write-Host ""
            
            # Mostrar registros A
            Write-InfoMessage "Registros A (IPv4):"
            try {
                $aRecords = Get-DnsServerResourceRecord -ZoneName $zona.ZoneName -RRType A -ErrorAction SilentlyContinue
                if ($aRecords) {
                    foreach ($record in $aRecords) {
                        $hostname = if ($record.HostName -eq "@") { "@" } else { $record.HostName }
                        Write-Host "  $hostname IN A $($record.RecordData.IPv4Address)"
                    }
                }
                else {
                    Write-Host "  Ninguno"
                }
            }
            catch {
                Write-Host "  Error al obtener registros A"
            }
            Write-Host ""
            
            # Mostrar registros CNAME
            try {
                $cnames = Get-DnsServerResourceRecord -ZoneName $zona.ZoneName -RRType CNAME -ErrorAction SilentlyContinue
                if ($cnames) {
                    Write-InfoMessage "Registros CNAME (Alias):"
                    foreach ($record in $cnames) {
                        Write-Host "  $($record.HostName) IN CNAME $($record.RecordData.HostNameAlias)"
                    }
                    Write-Host ""
                }
            }
            catch {
                # No se muestran registros CNAME si no existen o hay error
            }
            
            # Mostrar registros MX
            Write-InfoMessage "Registros MX (Correo):"
            try {
                $mx = Get-DnsServerResourceRecord -ZoneName $zona.ZoneName -RRType MX -ErrorAction SilentlyContinue
                if ($mx) {
                    foreach ($record in $mx) {
                        $hostname = if ($record.HostName -eq "@") { "@" } else { $record.HostName }
                        Write-Host "  $hostname IN MX $($record.RecordData.Preference) $($record.RecordData.MailExchange)"
                    }
                }
                else {
                    Write-Host "  Ninguno"
                }
            }
            catch {
                Write-Host "  Ninguno"
            }
            Write-Host ""
            
            # Mostrar registros TXT
            Write-InfoMessage "Registros TXT:"
            try {
                $txt = Get-DnsServerResourceRecord -ZoneName $zona.ZoneName -RRType TXT -ErrorAction SilentlyContinue
                if ($txt) {
                    foreach ($record in $txt) {
                        $hostname = if ($record.HostName -eq "@") { "@" } else { $record.HostName }
                        Write-Host "  $hostname IN TXT `"$($record.RecordData.DescriptiveText)`""
                    }
                }
                else {
                    Write-Host "  Ninguno"
                }
            }
            catch {
                Write-Host "  Ninguno"
            }
            Write-Host ""
        }
    }
    catch {
        Write-ErrorMessage "Error al listar dominios detallados: $($_.Exception.Message)"
    }
}

function Show-SpecificDomain {
    Clear-Host
    Write-Header "Listar Dominio Específico"
    
    # Primero mostrar dominios disponibles
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
        
        $dominioBuscar = Read-Host "Ingrese el dominio a consultar"
        
        if ([string]::IsNullOrWhiteSpace($dominioBuscar)) {
            Write-WarningCustom "No se ingresó ningún dominio"
            return
        }
        
        # Verificar que el dominio existe
        $zonaEncontrada = $zonas | Where-Object { $_.ZoneName -eq $dominioBuscar }
        
        if (-not $zonaEncontrada) {
            Write-ErrorMessage "El dominio '$dominioBuscar' no existe"
            return
        }
        
        Clear-Host
        Write-Header "DOMINIO: $dominioBuscar"
        
        # Tipo y estado
        Write-InfoMessage "Tipo de zona: $($zonaEncontrada.ZoneType)"
        Write-SuccessMessage "Estado: VÁLIDO"
        
        Write-Host ""
        Write-SeparatorLine
        Write-Host ""
        
        # Mostrar contenido completo
        Write-InfoMessage "Registros del dominio:"
        Write-Host ""
        
        $todosRegistros = Get-DnsServerResourceRecord -ZoneName $dominioBuscar -ErrorAction SilentlyContinue
        
        if ($todosRegistros) {
            foreach ($record in $todosRegistros) {
                $hostname = if ($record.HostName -eq "@") { "@" } else { $record.HostName }
                
                switch ($record.RecordType) {
                    "A" {
                        Write-Host "$hostname IN A $($record.RecordData.IPv4Address)"
                    }
                    "AAAA" {
                        Write-Host "$hostname IN AAAA $($record.RecordData.IPv6Address)"
                    }
                    "CNAME" {
                        Write-Host "$hostname IN CNAME $($record.RecordData.HostNameAlias)"
                    }
                    "MX" {
                        Write-Host "$hostname IN MX $($record.RecordData.Preference) $($record.RecordData.MailExchange)"
                    }
                    "NS" {
                        Write-Host "$hostname IN NS $($record.RecordData.NameServer)"
                    }
                    "SOA" {
                        Write-Host "$hostname IN SOA $($record.RecordData.PrimaryServer) $($record.RecordData.ResponsiblePerson)"
                        Write-Host "        Serial: $($record.RecordData.SerialNumber)"
                    }
                    "TXT" {
                        Write-Host "$hostname IN TXT `"$($record.RecordData.DescriptiveText)`""
                    }
                    default {
                        Write-Host "$hostname IN $($record.RecordType) (datos no mostrados)"
                    }
                }
            }
        }
        else {
            Write-InfoMessage "No hay registros para mostrar"
        }
    }
    catch {
        Write-ErrorMessage "Error al consultar el dominio: $($_.Exception.Message)"
    }
}

function Show-ListMenu {
    Clear-Host
    Write-Header "Listar Dominios"
    Write-Host ""
    Write-InfoMessage "Tipo de listado:"
    Write-Host ""
    Write-InfoMessage "1) Solo nombres de dominios"
    Write-InfoMessage "2) Resumen (dominio + IP + registros)"
    Write-InfoMessage "3) Detallado (todos los registros)"
    Write-InfoMessage "4) Filtrar por dominio específico"
    Write-Host ""
    
    $listType = Read-Host "Opción"
    
    switch ($listType) {
        "1" {
            Show-SimpleDomainList
        }
        "2" {
            Show-SummaryDomainList
        }
        "3" {
            Show-DetailedDomainList
        }
        "4" {
            Show-SpecificDomain
        }
        default {
            Write-ErrorMessage "Opción inválida"
        }
    }
}