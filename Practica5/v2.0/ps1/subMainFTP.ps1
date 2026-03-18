$script:FTP_ROOT        = "C:\FTP"
$script:FTP_GENERAL     = "$script:FTP_ROOT\LocalUser\Public"
$script:FTP_SITE_NAME   = "FTP Site"
$script:FTP_BANNER      = "Servidor FTP"
$script:FTP_PASV_MIN    = 30000
$script:FTP_PASV_MAX    = 31000
$script:FTP_PORT        = 21

# Grupo local que agrupa a todos los usuarios FTP
$script:FTP_GROUP_ALL   = "ftp_users"

# Archivo de metadatos: usuario:grupo (equivalente a virtual_users_meta)
$script:FTP_META        = "$script:FTP_ROOT\ftp_users_meta.txt"

# Archivo de grupos FTP definidos
$script:FTP_GROUPS_FILE = "$script:FTP_ROOT\ftp_groups.txt"

$script:FTP_GROUPS      = @()

function Read-Input {
    param([string]$prompt)
    msg_input $prompt
    return Read-Host
}

function Read-SecureInput {
    param([string]$prompt)
    msg_input $prompt
    return Read-Host -AsSecureString
}

function Confirm-Action {
    param([string]$prompt)
    $r = Read-Input "$prompt [s/N]: "
    return ($r -match '^[Ss]$')
}


$_LIB_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path


$_LIB_DIR = $PSScriptRoot

. "$_LIB_DIR\FunctionsFTP-D.ps1"
. "$_LIB_DIR\FunctionsFTP-C.ps1"
. "$_LIB_DIR\FunctionsFTP-B.ps1"
. "$_LIB_DIR\FunctionsFTP-A.ps1"

Load-FtpGroups