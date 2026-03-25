#
# Register-ClientDNS.ps1
#
# Responsabilidad: Registrar los registros A (nombre -> IP) de los clientes
#
# El script es idempotente: si el registro ya existe, lo actualiza.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File Register-ClientDNS.ps1
#

#Requires -Version 5.1

. "$PSScriptRoot\utils.ps1"
. "$PSScriptRoot\utilsAD.ps1"

# -------------------------------------------------------------------------
# Clientes a registrar en DNS
# Agregar o modificar segun los clientes del laboratorio
# -------------------------------------------------------------------------
$DNS_CLIENTS = @(
    @{ Name = "workstation1"; IP = "192.168.100.30" }
    # Agregar mas clientes aqui si se incorporan al dominio:
    # @{ Name = "windows-client"; IP = "192.168.100.40" }
)

$DNS_ZONE = "reprobados.local"
$TTL      = "01:00:00"

function Register-DNSRecord {
    param(
        [string]$HostName,
        [string]$IPAddress
    )

    $fqdn = "$HostName.$DNS_ZONE"

    aputs_info "Procesando registro DNS: $fqdn -> $IPAddress"

    # Verificar si ya existe un registro para este nombre
    $existing = Get-DnsServerResourceRecord `
        -ZoneName $DNS_ZONE `
        -Name $HostName `
        -RRType A `
        -ErrorAction SilentlyContinue

    if ($null -ne $existing) {
        $existingIP = $existing.RecordData.IPv4Address.ToString()

        if ($existingIP -eq $IPAddress) {
            aputs_success "Registro ya existe y es correcto: $fqdn -> $IPAddress"
            Write-ADLog "DNS: $fqdn ya registrado con IP correcta $IPAddress" "INFO"
            return $true
        } else {
            # IP diferente: eliminar el registro viejo y crear uno nuevo
            aputs_warning "Registro existe con IP diferente ($existingIP). Actualizando..."
            try {
                Remove-DnsServerResourceRecord `
                    -ZoneName $DNS_ZONE `
                    -Name $HostName `
                    -RRType A `
                    -Force `
                    -ErrorAction Stop
                aputs_info "Registro anterior eliminado"
            } catch {
                aputs_warning "No se pudo eliminar registro anterior: $($_.Exception.Message)"
            }
        }
    }

    # Crear el registro A nuevo
    try {
        Add-DnsServerResourceRecordA `
            -ZoneName   $DNS_ZONE `
            -Name       $HostName `
            -IPv4Address $IPAddress `
            -TimeToLive  $TTL `
            -ErrorAction Stop

        aputs_success "Registro DNS creado: $fqdn -> $IPAddress"
        Write-ADLog "DNS: $fqdn -> $IPAddress registrado" "SUCCESS"
        return $true
    } catch {
        aputs_error "Error al crear registro DNS para $fqdn : $($_.Exception.Message)"
        Write-ADLog "Error DNS $fqdn : $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# -------------------------------------------------------------------------
# Verify-DNSRecord
# Verifica que el registro DNS quedó correctamente registrado y resuelve.
# -------------------------------------------------------------------------
function Verify-DNSRecord {
    param(
        [string]$HostName,
        [string]$ExpectedIP
    )

    $fqdn = "$HostName.$DNS_ZONE"

    try {
        $result = Resolve-DnsName $fqdn -ErrorAction Stop
        $resolvedIP = ($result | Where-Object { $_.Type -eq "A" }).IPAddress

        if ($resolvedIP -eq $ExpectedIP) {
            aputs_success "Verificacion OK: $fqdn resuelve a $resolvedIP"
            return $true
        } else {
            aputs_warning "Verificacion: $fqdn resuelve a $resolvedIP (esperado: $ExpectedIP)"
            return $false
        }
    } catch {
        aputs_error "No se pudo resolver $fqdn : $($_.Exception.Message)"
        return $false
    }
}

draw_header "Register-ClientDNS: Registro de Clientes Linux en DNS del DC"

# Verificar que el modulo DNS esta disponible (requiere rol DNS instalado)
if (-not (Get-Module -ListAvailable -Name DnsServer -ErrorAction SilentlyContinue)) {
    aputs_error "Modulo DnsServer no disponible. Verifique que el rol DNS esta instalado."
    exit 1
}

aputs_info "Zona DNS: $DNS_ZONE"
aputs_info "Clientes a registrar: $($DNS_CLIENTS.Count)"
draw_line

$allOk = $true

foreach ($client in $DNS_CLIENTS) {
    $ok = Register-DNSRecord -HostName $client.Name -IPAddress $client.IP
    if ($ok) {
        Verify-DNSRecord -HostName $client.Name -ExpectedIP $client.IP
    } else {
        $allOk = $false
    }
    Write-Host ""
}

draw_line

if ($allOk) {
    aputs_success "Todos los registros DNS estan configurados correctamente."
    aputs_info    "Ahora puede ejecutar main.sh en el cliente Linux."
    aputs_info    "El error GSSAPI 'Server not found' no deberia ocurrir."
} else {
    aputs_error "Algunos registros DNS no se pudieron crear. Revise los errores arriba."
}

draw_line
aputs_info "Para agregar mas clientes en el futuro, edite la seccion DNS_CLIENTS"
aputs_info "al inicio de este script y vuelva a ejecutarlo."