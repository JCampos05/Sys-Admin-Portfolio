#!/bin/bash
#
# Mount-Perfiles.sh
#
# Uso:
#   bash Mount-Perfiles.sh          # monta la carpeta del usuario actual
#   bash Mount-Perfiles.sh user06   # monta la carpeta de un usuario especifico
#
# El punto de montaje es: /run/user/$(id -u)/perfiles-<usuario>
# Nautilus lo muestra en "Otros sitios" automaticamente.
#
# Para desmontar: bash Mount-Perfiles.sh --umount
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh" 2>/dev/null || {
    # Fallback si se ejecuta fuera del directorio de scripts
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
    aputs_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
    aputs_success() { echo -e "${GREEN}[OK]${NC}   $1"; }
    aputs_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
    aputs_error()   { echo -e "${RED}[ERR]${NC}  $1"; }
}
source "$SCRIPT_DIR/utilsAD.sh" 2>/dev/null || {
    # Detectar DC y dominio si utilsAD no esta disponible
    DC_IP=$(ip -4 route | grep "192.168" | awk '{print $3}' | head -1)
    DC_DOMAIN=$(realm list 2>/dev/null | grep "domain-name" | awk '{print $2}' | head -1)
    NETBIOS_NAME=$(echo "${DC_DOMAIN%%.*}" | tr '[:lower:]' '[:upper:]')
}

# 
# HELPERS
# 

# Punto de montaje en directorio del usuario actual (no requiere root)
# /run/user/UID/ es tmpfs del usuario, ideal para montajes temporales
_get_mount_point() {
    local usuario="$1"
    # Usar el home del usuario real (quien hizo sudo), no /root
    local usuario_real="${SUDO_USER:-$USER}"
    local home_real
    home_real=$(getent passwd "$usuario_real" | cut -d: -f6)
    [[ -z "$home_real" ]] && home_real="$HOME"
    echo "${home_real}/Perfiles-${usuario}"
}

_esta_montado() {
    local mount_point="$1"
    mountpoint -q "$mount_point" 2>/dev/null
}

_listar_montajes() {
    local usuario_real="${SUDO_USER:-$USER}"
    local home_real
    home_real=$(getent passwd "$usuario_real" | cut -d: -f6)
    [[ -z "$home_real" ]] && home_real="$HOME"
    echo ""
    aputs_info "Montajes activos de Perfiles en $home_real:"
    local encontrado=false
    for mp in "${home_real}"/Perfiles-*; do
        [[ -d "$mp" ]] && _esta_montado "$mp" && {
            echo "    $mp"
            encontrado=true
        }
    done
    $encontrado || aputs_info "  Ninguno activo."
    echo ""
}

# 
# DESMONTAR
# 
_desmontar_todos() {
    draw_line
    echo "  Desmontar puntos de montaje de Perfiles"
    draw_line
    echo ""
    local usuario_real="${SUDO_USER:-$USER}"
    local home_real
    home_real=$(getent passwd "$usuario_real" | cut -d: -f6)
    [[ -z "$home_real" ]] && home_real="$HOME"
    local encontrado=false
    for mp in "${home_real}"/Perfiles-*; do
        [[ -d "$mp" ]] || continue
        encontrado=true
        if _esta_montado "$mp"; then
            aputs_info "Desmontando: $mp"
            if sudo umount "$mp" 2>/dev/null; then
                aputs_success "Desmontado: $mp"
                rmdir "$mp" 2>/dev/null
            else
                aputs_error "No se pudo desmontar: $mp"
            fi
        else
            aputs_info "No estaba montado: $mp"
            rmdir "$mp" 2>/dev/null
        fi
    done
    $encontrado || aputs_info "No hay puntos de montaje activos."
}

_desmontar_usuario() {
    local usuario="$1"
    local mp
    mp=$(_get_mount_point "$usuario")
    if _esta_montado "$mp"; then
        sudo umount "$mp" 2>/dev/null && {
            aputs_success "Desmontado: $mp"
            rmdir "$mp" 2>/dev/null
        } || aputs_error "No se pudo desmontar: $mp"
    else
        aputs_warning "No estaba montado: $mp"
        rmdir "$mp" 2>/dev/null
    fi
}

# 
# MONTAR
# 
_montar_usuario() {
    local usuario="$1"
    local password="$2"

    # Punto de montaje en el home del usuario real (quien hizo sudo)
    local mp
    mp=$(_get_mount_point "$usuario")
    local usuario_real="${SUDO_USER:-$USER}"

    # Verificar que cifs-utils esta instalado
    if ! rpm -qa | grep -q "^cifs-utils-" 2>/dev/null; then
        aputs_warning "cifs-utils no instalado. Instalando..."
        sudo dnf install -y cifs-utils &>/dev/null || {
            aputs_error "sudo dnf install -y cifs-utils"
            return 1
        }
    fi

    # Si ya esta montado, mostrar info
    if _esta_montado "$mp"; then
        aputs_success "Ya montado: $mp"
        aputs_info    "Contenido:"
        ls -la "$mp" | head -10
        return 0
    fi

    mkdir -p "$mp"
    # Cambiar propietario del punto de montaje al usuario real
    chown "$usuario_real" "$mp" 2>/dev/null

    # Obtener UID y GID del usuario REAL (clientuser), no de root
    # id -u dentro de sudo devuelve 0 — necesitamos el del usuario que hizo sudo
    local uid gid
    uid=$(id -u "$usuario_real" 2>/dev/null || id -u)
    gid=$(id -g "$usuario_real" 2>/dev/null || id -g)

    aputs_info "Montando //$DC_IP/Perfiles\$/$usuario como uid=$uid ($usuario_real)..."

    if sudo mount -t cifs \
        "//${DC_IP}/Perfiles$/${usuario}" \
        "$mp" \
        -o "username=${usuario},password=${password},domain=${NETBIOS_NAME},vers=3.0,uid=${uid},gid=${gid},file_mode=0664,dir_mode=0775" \
        2>/tmp/mount_perfiles_err; then

        aputs_success "Montado: $mp -> \\\\$DC_IP\\Perfiles\$\\$usuario"
        rm -f /tmp/mount_perfiles_err
        echo ""
        aputs_info "Contenido:"
        ls -la "$mp"
        echo ""
        aputs_success "Abre el explorador de archivos — la carpeta esta en:"
        aputs_success "  $mp"
        aputs_info    "O ejecuta: nautilus '$mp' &"
        aputs_info    "Para desmontar: bash Mount-Perfiles.sh --umount $usuario"
        return 0
    else
        aputs_error "No se pudo montar: $(cat /tmp/mount_perfiles_err 2>/dev/null)"
        rm -f /tmp/mount_perfiles_err
        rmdir "$mp" 2>/dev/null
        return 1
    fi
}

# 
# MENU INTERACTIVO
# 
_menu_principal() {
    local usuario_real="${SUDO_USER:-$USER}"
    local home_real
    home_real=$(getent passwd "$usuario_real" | cut -d: -f6)
    [[ -z "$home_real" ]] && home_real="$HOME"

    while true; do
        clear
        draw_line
        echo "  Mount-Perfiles.sh — Tarea 08"
        draw_line
        echo "  DC:      $DC_IP"
        echo "  Dominio: $DC_DOMAIN"
        echo "  Usuario: $usuario_real (home: $home_real)"
        echo ""

        _listar_montajes

        # Mostrar usuarios disponibles del dominio
        local grupos
        grupos=$(getent group 2>/dev/null | grep "@${DC_DOMAIN}" | \
            awk -F: '$4!="" {print $1}' | sort 2>/dev/null)
        if [[ -n "$grupos" ]]; then
            aputs_info "Usuarios del dominio:"
            for g in $grupos; do
                local lista
                lista=$(getent group "$g" 2>/dev/null | cut -d: -f4 | \
                    tr ',' ' ' | sed "s/@${DC_DOMAIN}//g" | xargs)
                aputs_info "  ${g%%@*}: $lista"
            done
            echo ""
        fi

        draw_line
        echo "  1) Montar carpeta de un usuario"
        echo "  2) Desmontar todos los montajes de Perfiles"
        echo "  3) Ver contenido del montaje activo"
        echo "  4) Abrir en Nautilus (explorador grafico)"
        echo "  0) Salir"
        echo ""

        read -rp "  Opcion: " op
        echo ""

        case "$op" in
            1)
                echo -ne "${CYAN}[INPUT]${NC} Usuario a montar (ej: user06): "
                read -r usuario
                [[ -z "$usuario" ]] && { aputs_error "Usuario vacio."; sleep 1; continue; }

                echo -ne "${CYAN}[INPUT]${NC} Password de $usuario: "
                read -rs password
                echo ""
                echo ""

                _montar_usuario "$usuario" "$password"
                password=""
                echo ""
                read -rp "  Presiona Enter para continuar..."
                ;;

            2)
                _desmontar_todos
                echo ""
                read -rp "  Presiona Enter para continuar..."
                ;;

            3)
                local montajes=()
                for mp in "${home_real}"/Perfiles-*; do
                    [[ -d "$mp" ]] && _esta_montado "$mp" && montajes+=("$mp")
                done
                if [[ ${#montajes[@]} -eq 0 ]]; then
                    aputs_warning "No hay montajes activos."
                else
                    for mp in "${montajes[@]}"; do
                        echo ""
                        aputs_info "Contenido: $mp"
                        draw_line
                        ls -lah "$mp"
                        echo ""
                        du -sh "$mp" 2>/dev/null
                    done
                fi
                echo ""
                read -rp "  Presiona Enter para continuar..."
                ;;

            4)
                local montajes=()
                for mp in "${home_real}"/Perfiles-*; do
                    [[ -d "$mp" ]] && _esta_montado "$mp" && montajes+=("$mp")
                done
                if [[ ${#montajes[@]} -eq 0 ]]; then
                    aputs_warning "No hay montajes activos. Monte primero con opcion 1."
                else
                    # Detectar el usuario real de la sesion grafica
                    # (el que ejecuto sudo, no root)
                    local usuario_real="${SUDO_USER:-$USER}"
                    for mp in "${montajes[@]}"; do
                        aputs_info "Abriendo en Nautilus como $usuario_real: $mp"
                        # Ejecutar nautilus como el usuario de la sesion grafica
                        sudo -u "$usuario_real" \
                            DISPLAY="${DISPLAY:-:0}" \
                            DBUS_SESSION_BUS_ADDRESS="$(
                                sudo -u "$usuario_real" \
                                    env | grep DBUS_SESSION_BUS_ADDRESS | cut -d= -f2-
                            )" \
                            nautilus "$mp" &>/dev/null &
                        # Si falla con DBUS, intentar xdg-open como fallback
                        sleep 1
                        if ! pgrep -u "$usuario_real" nautilus &>/dev/null; then
                            sudo -u "$usuario_real" \
                                DISPLAY="${DISPLAY:-:0}" \
                                xdg-open "$mp" &>/dev/null 2>&1 &
                        fi
                    done
                    aputs_success "Nautilus lanzado como $usuario_real"
                    aputs_info    "Si no abre, ejecuta manualmente en tu terminal:"
                    for mp in "${montajes[@]}"; do
                        aputs_info "  nautilus '$mp' &"
                    done
                fi
                echo ""
                read -rp "  Presiona Enter para continuar..."
                ;;

            0)
                aputs_info "Saliendo..."
                exit 0
                ;;

            *)
                aputs_error "Opcion invalida"
                sleep 1
                ;;
        esac
    done
}

# 
# PUNTO DE ENTRADA
# 
clear
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  Mount-Perfiles.sh — Tarea 08                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Montar carpeta de perfil via CIFS            ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# Procesar argumentos de linea de comandos
case "${1:-}" in
    --umount|-u)
        if [[ -n "${2:-}" ]]; then
            _desmontar_usuario "$2"
        else
            _desmontar_todos
        fi
        exit $?
        ;;
    --list|-l)
        _listar_montajes
        exit 0
        ;;
    --help|-h)
        echo "Uso:"
        echo "  bash Mount-Perfiles.sh                  # Menu interactivo"
        echo "  bash Mount-Perfiles.sh user06           # Montar carpeta de user06"
        echo "  bash Mount-Perfiles.sh --umount         # Desmontar todos"
        echo "  bash Mount-Perfiles.sh --umount user06  # Desmontar user06"
        echo "  bash Mount-Perfiles.sh --list           # Listar montajes activos"
        exit 0
        ;;
    "")
        # Sin argumentos: menu interactivo
        _menu_principal
        ;;
    *)
        # Argumento = nombre de usuario: montar directamente
        usuario="$1"
        echo -ne "${CYAN}[INPUT]${NC} Password de $usuario: "
        read -rs password
        echo ""
        echo ""
        _montar_usuario "$usuario" "$password"
        password=""
        exit $?
        ;;
esac