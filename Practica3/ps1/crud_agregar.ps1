# ============================================================================
# crud_agregar.ps1
# Submódulo para agregar dominios y registros DNS
# ============================================================================

<#
.SYNOPSIS
    Genera un número serial para zona DNS en formato YYYYMMDDnn
.OUTPUTS
    String - Serial en formato YYYYMMDDnn
#>
function New-DNSSerial {
    $fecha = Get-Date -Format "yyyyMMdd"
    return "${fecha}01"
}

<#
.SYNOPSIS
    Crea un nuevo dominio DNS completo con todos sus registros
.DESCRIPTION
    Guía al usuario a través de la creación de una zona DNS directa completa,
    incluyendo registros A, NS, CNAME (www), MX opcional y zona inversa opcional
#>
function Add-CompleteDNSDomain {
    Clear-Host
    Write-Header "Agregar Nuevo Dominio"
    
    # ========================================================================
    # PARÁMETROS OBLIGATORIOS
    # ========================================================================
    
    $nombreDominio = Read-Host "Nombre del dominio (ej: ejemplo.com)"
    
    if ([string]::IsNullOrWhiteSpace($nombreDominio)) {
        Write-ErrorMessage "El nombre del dominio no puede estar vacío"
        return
    }
    
    # Verificar si ya existe
    try {
        $zonaExistente = Get-DnsServerZone -Name $nombreDominio -ErrorAction SilentlyContinue
        if ($zonaExistente) {
            Write-ErrorMessage "El dominio '$nombreDominio' ya existe"
            return
        }
    }
    catch {
        # El dominio no existe, podemos continuar
    }
    
    $ipPrincipal = Read-Host "IP principal del dominio"
    
    if (-not (Test-DNSIP -IPAddress $ipPrincipal)) {
        Write-ErrorMessage "IP invalida"
        return
    }
    
    Write-Host ""
    Write-SeparatorLine
    Write-Host ""
    
    # ========================================================================
    # PARÁMETROS OPCIONALES
    # ========================================================================
    
    Write-InfoMessage "Configuración adicional (opcional):"
    Write-Host ""
    
    # WWW
    $crearWWW = Read-Host "¿Crear registro www? (S/N) [S]"
    if ([string]::IsNullOrWhiteSpace($crearWWW)) {
        $crearWWW = "S"
    }
    
    $tipoWWW = "CNAME"
    if ($crearWWW -eq 'S' -or $crearWWW -eq 's') {
        $tipoWWWOpcion = Read-Host "  Tipo: (1) CNAME o (2) A [1]"
        if ($tipoWWWOpcion -eq "2") {
            $tipoWWW = "A"
        }
    }
    
    # NS (siempre se crea)
    $nombreNS = Read-Host "Nombre del servidor NS [ns1]"
    if ([string]::IsNullOrWhiteSpace($nombreNS)) {
        $nombreNS = "ns1"
    }
    
    $ipNS = Read-Host "IP del servidor NS [$ipPrincipal]"
    if ([string]::IsNullOrWhiteSpace($ipNS)) {
        $ipNS = $ipPrincipal
    }
    
    if (-not (Test-DNSIP -IPAddress $ipNS)) {
        Write-ErrorMessage "IP del NS invalida"
        return
    }
    
    # MX
    $crearMX = Read-Host "¿Crear registro MX (correo)? (S/N) [N]"
    if ([string]::IsNullOrWhiteSpace($crearMX)) {
        $crearMX = "N"
    }
    
    $nombreMail = "mail"
    $ipMail = ""
    $prioridadMX = "10"
    
    if ($crearMX -eq 'S' -or $crearMX -eq 's') {
        $nombreMail = Read-Host "  Nombre del servidor de correo [mail]"
        if ([string]::IsNullOrWhiteSpace($nombreMail)) {
            $nombreMail = "mail"
        }
        
        $ipMail = Read-Host "  IP del servidor de correo"
        if (-not (Test-DNSIP -IPAddress $ipMail)) {
            Write-ErrorMessage "IP del servidor de correo invalida"
            return
        }
        
        $prioridadMX = Read-Host "  Prioridad MX [10]"
        if ([string]::IsNullOrWhiteSpace($prioridadMX)) {
            $prioridadMX = "10"
        }
    }
    
    # TTL
    $ttl = Read-Host "TTL para la zona (segundos) [3600]"
    if ([string]::IsNullOrWhiteSpace($ttl)) {
        $ttl = "3600"
    }
    
    # Zona inversa
    $crearZonaInversa = Read-Host "¿Crear zona inversa? (S/N) [S]"
    if ([string]::IsNullOrWhiteSpace($crearZonaInversa)) {
        $crearZonaInversa = "S"
    }
    
    Write-Host ""
    Write-SeparatorLine
    Write-Host ""
    
    # ========================================================================
    # RESUMEN
    # ========================================================================
    
    Write-InfoMessage "Resumen de Configuración:"
    Write-Host ""
    Write-Host "  Dominio: $nombreDominio"
    Write-Host "  IP principal: $ipPrincipal"
    Write-Host "  Crear www: $crearWWW ($tipoWWW)"
    Write-Host "  Servidor NS: ${nombreNS}.${nombreDominio} ($ipNS)"
    Write-Host "  Crear MX: $crearMX"
    if ($crearMX -eq 'S' -or $crearMX -eq 's') {
        Write-Host "    Mail: ${nombreMail}.${nombreDominio} ($ipMail, prioridad: $prioridadMX)"
    }
    Write-Host "  TTL: $ttl"
    Write-Host "  Zona inversa: $crearZonaInversa"
    Write-Host ""
    
    $confirmar = Read-Host "¿Desea crear el dominio con esta configuración? (S/N)"
    
    if ($confirmar -ne 'S' -and $confirmar -ne 's') {
        Write-InfoMessage "Creación cancelada"
        return
    }
    
    Write-Host ""
    Write-SeparatorLine
    Write-Host ""
    
    # ========================================================================
    # PASO 1: CREAR ZONA DNS
    # ========================================================================
    
    Write-InfoMessage "PASO 1: Creando zona DNS '$nombreDominio'..."
    
    try {
        # Crear zona DNS principal (basada en archivos)
        Add-DnsServerPrimaryZone -Name $nombreDominio `
                                -ZoneFile "${nombreDominio}.dns" `
                                -DynamicUpdate None `
                                -ErrorAction Stop
        
        Write-SuccessMessage "Zona DNS creada correctamente"
    }
    catch {
        Write-ErrorMessage "Error al crear zona DNS: $($_.Exception.Message)"
        return
    }
    
    Write-Host ""
    Write-SeparatorLine
    Write-Host ""
    
    # ========================================================================
    # PASO 2: CONFIGURAR REGISTROS SOA Y NS
    # ========================================================================
    
    Write-InfoMessage "PASO 2: Configurando registros SOA y NS..."
    
    try {
        # El registro SOA se crea automáticamente, solo necesitamos ajustarlo si es necesario
        
        # Crear registro NS
        Add-DnsServerResourceRecord -ZoneName $nombreDominio `
                                   -NS `
                                   -Name "@" `
                                   -NameServer "${nombreNS}.${nombreDominio}." `
                                   -ErrorAction Stop
        
        # Crear registro A para el servidor NS
        Add-DnsServerResourceRecordA -ZoneName $nombreDominio `
                                    -Name $nombreNS `
                                    -IPv4Address $ipNS `
                                    -TimeToLive (New-TimeSpan -Seconds ([int]$ttl)) `
                                    -ErrorAction Stop
        
        Write-SuccessMessage "Registros SOA y NS configurados"
    }
    catch {
        Write-ErrorMessage "Error al configurar SOA/NS: $($_.Exception.Message)"
        # Intentar limpiar la zona creada
        Remove-DnsServerZone -Name $nombreDominio -Force -ErrorAction SilentlyContinue
        return
    }
    
    Write-Host ""
    
    # ========================================================================
    # PASO 3: AGREGAR REGISTRO A PRINCIPAL
    # ========================================================================
    
    Write-InfoMessage "PASO 3: Agregando registro A principal..."
    
    try {
        Add-DnsServerResourceRecordA -ZoneName $nombreDominio `
                                    -Name "@" `
                                    -IPv4Address $ipPrincipal `
                                    -TimeToLive (New-TimeSpan -Seconds ([int]$ttl)) `
                                    -ErrorAction Stop
        
        Write-SuccessMessage "Registro A principal creado: $nombreDominio -> $ipPrincipal"
    }
    catch {
        Write-ErrorMessage "Error al crear registro A principal: $($_.Exception.Message)"
    }
    
    Write-Host ""
    
    # ========================================================================
    # PASO 4: AGREGAR WWW SI SE SOLICITÓ
    # ========================================================================
    
    if ($crearWWW -eq 'S' -or $crearWWW -eq 's') {
        Write-InfoMessage "PASO 4: Agregando registro www..."
        
        try {
            if ($tipoWWW -eq "CNAME") {
                Add-DnsServerResourceRecordCName -ZoneName $nombreDominio `
                                                -Name "www" `
                                                -HostNameAlias "$nombreDominio." `
                                                -TimeToLive (New-TimeSpan -Seconds ([int]$ttl)) `
                                                -ErrorAction Stop
                Write-SuccessMessage "Registro CNAME www creado: www -> $nombreDominio"
            }
            else {
                Add-DnsServerResourceRecordA -ZoneName $nombreDominio `
                                            -Name "www" `
                                            -IPv4Address $ipPrincipal `
                                            -TimeToLive (New-TimeSpan -Seconds ([int]$ttl)) `
                                            -ErrorAction Stop
                Write-SuccessMessage "Registro A www creado: www -> $ipPrincipal"
            }
        }
        catch {
            Write-WarningCustom "Error al crear registro www: $($_.Exception.Message)"
        }
        
        Write-Host ""
    }
    
    # ========================================================================
    # PASO 5: AGREGAR MX SI SE SOLICITÓ
    # ========================================================================
    
    if ($crearMX -eq 'S' -or $crearMX -eq 's') {
        Write-InfoMessage "PASO 5: Agregando registros MX..."
        
        try {
            # Crear registro A para el servidor de correo
            Add-DnsServerResourceRecordA -ZoneName $nombreDominio `
                                        -Name $nombreMail `
                                        -IPv4Address $ipMail `
                                        -TimeToLive (New-TimeSpan -Seconds ([int]$ttl)) `
                                        -ErrorAction Stop
            
            # Crear registro MX
            Add-DnsServerResourceRecordMX -ZoneName $nombreDominio `
                                         -Name "@" `
                                         -MailExchange "${nombreMail}.${nombreDominio}" `
                                         -Preference ([int]$prioridadMX) `
                                         -TimeToLive (New-TimeSpan -Seconds ([int]$ttl)) `
                                         -ErrorAction Stop
            
            Write-SuccessMessage "Registros MX creados: ${nombreMail}.${nombreDominio} (prioridad: $prioridadMX)"
        }
        catch {
            Write-WarningCustom "Error al crear registros MX: $($_.Exception.Message)"
        }
        
        Write-Host ""
    }
    
    # ========================================================================
    # PASO 6: CREAR ZONA INVERSA SI SE SOLICITÓ
    # ========================================================================
    
    if ($crearZonaInversa -eq 'S' -or $crearZonaInversa -eq 's') {
        Write-InfoMessage "PASO 6: Creando zona inversa..."
        
        try {
            # Extraer octetos de la IP
            $octetos = $ipPrincipal -split '\.'
            $networkId = "$($octetos[0]).$($octetos[1]).$($octetos[2])"
            
            # Crear zona inversa (basada en archivos)
            $zonaInversaNombre = "$($octetos[2]).$($octetos[1]).$($octetos[0]).in-addr.arpa"
            Add-DnsServerPrimaryZone -NetworkId "${networkId}.0/24" `
                                    -ZoneFile "${zonaInversaNombre}" `
                                    -DynamicUpdate None `
                                    -ErrorAction Stop
            
            # Agregar registros PTR
            $zonaInversa = "$($octetos[2]).$($octetos[1]).$($octetos[0]).in-addr.arpa"
            
            Add-DnsServerResourceRecordPtr -ZoneName $zonaInversa `
                                          -Name $octetos[3] `
                                          -PtrDomainName "$nombreDominio." `
                                          -TimeToLive (New-TimeSpan -Seconds ([int]$ttl)) `
                                          -ErrorAction Stop
            
            Add-DnsServerResourceRecordPtr -ZoneName $zonaInversa `
                                          -Name $octetos[3] `
                                          -PtrDomainName "${nombreNS}.${nombreDominio}." `
                                          -TimeToLive (New-TimeSpan -Seconds ([int]$ttl)) `
                                          -ErrorAction SilentlyContinue
            
            Write-SuccessMessage "Zona inversa creada: $zonaInversa"
        }
        catch {
            Write-WarningCustom "Error al crear zona inversa: $($_.Exception.Message)"
            Write-Host "  La zona inversa puede existir ya o no tener permisos"
        }
        
        Write-Host ""
    }
    
    Write-SeparatorLine
    Write-Host ""
    
    # ========================================================================
    # VALIDACIÓN FINAL
    # ========================================================================
    
    Write-InfoMessage "Validando zona creada..."
    
    try {
        $zona = Get-DnsServerZone -Name $nombreDominio -ErrorAction Stop
        $registros = Get-DnsServerResourceRecord -ZoneName $nombreDominio -ErrorAction Stop
        
        Write-SuccessMessage "Zona validada correctamente"
        Write-Host "  Total de registros: $($registros.Count)"
    }
    catch {
        Write-ErrorMessage "Error al validar zona: $($_.Exception.Message)"
    }
    
    Write-Host ""
    Write-SeparatorLine
    Write-Host ""
    
    # ========================================================================
    # REINICIAR SERVICIO
    # ========================================================================
    
    Write-WarningCustom "Se recomienda reiniciar el servicio DNS"
    $reiniciar = Read-Host "¿Reiniciar servicio DNS ahora? (S/N)"
    
    if ($reiniciar -eq 'S' -or $reiniciar -eq 's') {
        Write-InfoMessage "Reiniciando servicio..."
        
        try {
            Restart-Service -Name DNS -Force -ErrorAction Stop
            Start-Sleep -Seconds 2
            
            if (Test-ServiceActive -ServiceName "DNS") {
                Write-SuccessMessage "Servicio reiniciado correctamente"
            }
            else {
                Write-ErrorMessage "El servicio no se inició correctamente"
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
    
    Write-SuccessMessage "Dominio creado exitosamente"
    Write-Host ""
    Write-InfoMessage "Puede probar la resolución con:"
    Write-Host "  nslookup $nombreDominio localhost"
    Write-Host "  nslookup www.$nombreDominio localhost"
    Write-Host ""
}

function Add-RecordToExistingDomain {
    Clear-Host
    Write-Header "Agregar registro a Dominio Existente"
    
    # Listar dominios disponibles
    Write-InfoMessage "Dominios disponibles:"
    Write-Host ""
    
    try {
        $zonas = Get-DnsServerZone -ErrorAction Stop | 
                Where-Object { $_.IsAutoCreated -eq $false -and $_.ZoneName -notlike "_*" -and $_.IsReverseLookupZone -eq $false }
        
        if (-not $zonas -or $zonas.Count -eq 0) {
            Write-Host ""
            Write-WarningCustom "No hay dominios configurados"
            Write-InfoMessage "Cree un dominio primero con la opción '2) Agregar nuevo dominio'"
            return
        }
        
        foreach ($zona in $zonas | Sort-Object ZoneName) {
            Write-Host "  - $($zona.ZoneName)"
        }
        
        Write-Host ""
        
        $dominioDestino = Read-Host "Dominio destino"
        
        if ([string]::IsNullOrWhiteSpace($dominioDestino)) {
            Write-ErrorMessage "Debe especificar un dominio"
            return
        }
        
        # Verificar que el dominio existe
        $zonaEncontrada = $zonas | Where-Object { $_.ZoneName -eq $dominioDestino }
        
        if (-not $zonaEncontrada) {
            Write-ErrorMessage "El dominio '$dominioDestino' no existe"
            return
        }
        
        Write-Host ""
        Write-InfoMessage "Tipos de registro disponibles:"
        Write-Host ""
        Write-InfoMessage "1) A (IPv4)"
        Write-InfoMessage "2) AAAA (IPv6)"
        Write-InfoMessage "3) CNAME (Alias)"
        Write-InfoMessage "4) MX (Mail)"
        Write-InfoMessage "5) TXT (Texto)"
        Write-InfoMessage "6) NS (Name Server)"
        Write-Host ""
        
        $tipoRegistro = Read-Host "Tipo de registro"
        
        switch ($tipoRegistro) {
            "1" {
                Add-ARecord -ZoneName $dominioDestino
            }
            "2" {
                Add-AAAARecord -ZoneName $dominioDestino
            }
            "3" {
                Add-CNAMERecord -ZoneName $dominioDestino
            }
            "4" {
                Add-MXRecord -ZoneName $dominioDestino
            }
            "5" {
                Add-TXTRecord -ZoneName $dominioDestino
            }
            "6" {
                Add-NSRecord -ZoneName $dominioDestino
            }
            default {
                Write-ErrorMessage "Tipo de registro inválido"
            }
        }
    }
    catch {
        Write-ErrorMessage "Error: $($_.Exception.Message)"
    }
}

function Add-ARecord {
    param([string]$ZoneName)
    
    Write-Host ""
    Write-InfoMessage "Agregar registro A (IPv4)"
    Write-Host ""
    
    $nombreHost = Read-Host "Nombre del host (ej: ftp, servidor1)"
    
    if ([string]::IsNullOrWhiteSpace($nombreHost)) {
        Write-ErrorMessage "El nombre no puede estar vacío"
        return
    }
    
    $ipHost = Read-Host "Dirección IPv4"
    
    if (-not (Test-IPv4Address -IPAddress $ipHost)) {
        Write-ErrorMessage "IP inválida"
        return
    }
    
    try {
        Add-DnsServerResourceRecordA -ZoneName $ZoneName `
                                    -Name $nombreHost `
                                    -IPv4Address $ipHost `
                                    -ErrorAction Stop
        
        Write-SuccessMessage "Registro A agregado correctamente: $nombreHost -> $ipHost"
    }
    catch {
        Write-ErrorMessage "Error al agregar registro: $($_.Exception.Message)"
    }
}

function Add-AAAARecord {
    param([string]$ZoneName)
    
    Write-InfoMessage "Registro AAAA (IPv6) - Funcionalidad en desarrollo"
    Write-Host ""
    Write-InfoMessage "Para agregar manualmente:"
    Write-Host "  Add-DnsServerResourceRecordAAAA -ZoneName $ZoneName -Name <nombre> -IPv6Address <ipv6>"
}

function Add-CNAMERecord {
    param([string]$ZoneName)
    
    Write-Host ""
    Write-InfoMessage "Agregar registro CNAME (Alias)"
    Write-Host ""
    
    $nombreAlias = Read-Host "Nombre del alias (ej: blog, tienda)"
    
    if ([string]::IsNullOrWhiteSpace($nombreAlias)) {
        Write-ErrorMessage "El nombre no puede estar vacío"
        return
    }
    
    $destinoAlias = Read-Host "Destino (a qué apunta, ej: www)"
    
    if ([string]::IsNullOrWhiteSpace($destinoAlias)) {
        Write-ErrorMessage "El destino no puede estar vacío"
        return
    }
    
    try {
        Add-DnsServerResourceRecordCName -ZoneName $ZoneName `
                                        -Name $nombreAlias `
                                        -HostNameAlias "${destinoAlias}.${ZoneName}." `
                                        -ErrorAction Stop
        
        Write-SuccessMessage "Registro CNAME agregado correctamente: $nombreAlias -> ${destinoAlias}.${ZoneName}"
    }
    catch {
        Write-ErrorMessage "Error al agregar registro: $($_.Exception.Message)"
    }
}

function Add-MXRecord {
    param([string]$ZoneName)
    
    Write-Host ""
    Write-InfoMessage "Agregar registro MX (Mail Exchange)"
    Write-Host ""
    
    $servidorMail = Read-Host "Nombre del servidor de correo (ej: mail2)"
    
    if ([string]::IsNullOrWhiteSpace($servidorMail)) {
        Write-ErrorMessage "El nombre no puede estar vacío"
        return
    }
    
    $prioridad = Read-Host "Prioridad [20]"
    if ([string]::IsNullOrWhiteSpace($prioridad)) {
        $prioridad = "20"
    }
    
    $ipMail = Read-Host "IP del servidor de correo"
    
    if (-not (Test-IPv4Address -IPAddress $ipMail)) {
        Write-ErrorMessage "IP inválida"
        return
    }
    
    try {
        # Crear registro A para el servidor de correo
        Add-DnsServerResourceRecordA -ZoneName $ZoneName `
                                    -Name $servidorMail `
                                    -IPv4Address $ipMail `
                                    -ErrorAction Stop
        
        # Crear registro MX
        Add-DnsServerResourceRecordMX -ZoneName $ZoneName `
                                     -Name "@" `
                                     -MailExchange "${servidorMail}.${ZoneName}" `
                                     -Preference ([int]$prioridad) `
                                     -ErrorAction Stop
        
        Write-SuccessMessage "Registros MX agregados correctamente: ${servidorMail}.${ZoneName} (prioridad: $prioridad)"
    }
    catch {
        Write-ErrorMessage "Error al agregar registros: $($_.Exception.Message)"
    }
}

function Add-TXTRecord {
    param([string]$ZoneName)
    
    Write-Host ""
    Write-InfoMessage "Agregar registro TXT"
    Write-Host ""
    
    $nombreTXT = Read-Host "Nombre (@ para raíz)"
    
    if ([string]::IsNullOrWhiteSpace($nombreTXT)) {
        $nombreTXT = "@"
    }
    
    $contenidoTXT = Read-Host "Contenido del registro TXT"
    
    if ([string]::IsNullOrWhiteSpace($contenidoTXT)) {
        Write-ErrorMessage "El contenido no puede estar vacío"
        return
    }
    
    try {
        Add-DnsServerResourceRecord -ZoneName $ZoneName `
                                   -TXT `
                                   -Name $nombreTXT `
                                   -DescriptiveText $contenidoTXT `
                                   -ErrorAction Stop
        
        Write-SuccessMessage "Registro TXT agregado correctamente"
    }
    catch {
        Write-ErrorMessage "Error al agregar registro: $($_.Exception.Message)"
    }
}

#Agrega un registro NS (name server) a una zona DNS
function Add-NSRecord {
    param([string]$ZoneName)
    
    Write-InfoMessage "Registro NS (Name Server) - Funcionalidad en desarrollo"
    Write-Host ""
    Write-InfoMessage "Para agregar manualmente:"
    Write-Host "  Add-DnsServerResourceRecord -ZoneName $ZoneName -NS -Name <nombre> -NameServer <servidor_ns>"
}