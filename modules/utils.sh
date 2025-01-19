#!/usr/bin/env zsh
setopt extendedglob
setopt NO_nomatch
setopt NULL_GLOB

. "${MODULES_DIR}/config.sh"
# =============================================================================
# Modul for generelle hjelpefunksjoner
# =============================================================================

# -----------------------------------------------------------------------------
# Logg-funksjoner
# -----------------------------------------------------------------------------

# Hovedloggingfunksjon
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf "[%s] [%-5s] %s\n" "$timestamp" "$level" "$message" | tee -a "${LOG_FILE:-/tmp/backup.log}"
}

# Logg errormeldinger
error() {
    log "ERROR" "$*" >&2
    return 1
}

# Logg advarsler
warn() {
    log "WARN" "$*"
}

# Logg debugmeldinger hvis DEBUG er aktivert
debug() {
    local debug_enabled
    debug_enabled=${DEBUG:-false}
    if [ "$debug_enabled" = "true" ]; then
        log "DEBUG" "$*"
    fi
}

# =============================================================================
# Progress-indikatorer og statusvisning
# =============================================================================

# Konstanter for progress
readonly PROGRESS_WIDTH=50  # Bredden på progress bar
typeset -r SPINNER_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

# Status for progress
typeset -i CURRENT_PROGRESS=0
typeset -i TOTAL_FILES=0
typeset -i PROCESSED_FILES=0
typeset CURRENT_PHASE=""
typeset PROGRESS_START_TIME
typeset PROGRESS_ENABLED=true

# Initialiserer progress tracking
init_progress() {
    local total="$1"
    local phase="$2"
    CURRENT_PROGRESS=0
    TOTAL_FILES=$total
    PROCESSED_FILES=0
    CURRENT_PHASE="$phase"
    PROGRESS_START_TIME=$(date +%s)
    
    # Vis initial progress bar
    if [[ "$PROGRESS_ENABLED" == true ]]; then
        echo -ne "\033[s"  # Lagre cursor posisjon
        draw_progress_bar 0
    fi
}

# Tegner en progress bar
draw_progress_bar() {
    local percent=$1
    local eta=$2
    local current_file="${3:-}"
    local width=$PROGRESS_WIDTH
    local completed=$((width * percent / 100))
    local remaining=$((width - completed))
    
    # Tegn progress bar
    echo -ne "\033[u\033[K"  # Gå tilbake og clear linje
    echo -ne "\r["
    echo -ne "\033[32m"  # Grønn for fullført
    for ((i=0; i<completed; i++)); do echo -n "="; done
    echo -ne "\033[33m"  # Gul for cursor
    [[ $completed -lt $width ]] && echo -n ">"
    echo -ne "\033[37m"  # Hvit for gjenværende
    for ((i=completed+1; i<width; i++)); do echo -n " "; done
    echo -ne "\033[0m"  # Reset farge
    echo -n "] "
    printf "%3d%% " "$percent"
    echo -n "[$CURRENT_PHASE] "
    echo -n "ETA: $(format_time "$eta") "
    [[ -n "$current_file" ]] && echo -n "Fil: ${current_file##*/}"
}

# Oppdaterer framdrift
update_progress() {
    local increment="${1:-1}"
    local current_file="$2"
    PROCESSED_FILES=$((PROCESSED_FILES + increment))
    
    if [[ $TOTAL_FILES -gt 0 ]]; then
        local new_progress=$((PROCESSED_FILES * 100 / TOTAL_FILES))
        if [[ $new_progress != "$CURRENT_PROGRESS" ]]; then
            CURRENT_PROGRESS=$new_progress
            local elapsed=$(($(date +%s) - PROGRESS_START_TIME))
            local eta="?"
            if ((PROCESSED_FILES > 0)); then
                eta=$((elapsed * (TOTAL_FILES - PROCESSED_FILES) / PROCESSED_FILES))
            fi
            draw_progress_bar "$new_progress" "$eta" "$current_file"
        fi
    fi
}

# Formaterer tid i sekunder til lesbar format
format_time() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    
    if [[ $hours -gt 0 ]]; then
        printf "%dh%dm%ds" "$hours" "$minutes" "$secs"
    elif [[ $minutes -gt 0 ]]; then
        printf "%dm%ds" "$minutes" "$secs"
    else
        printf "%ds" "$secs"
    fi
}

# Viser spinner for prosesser uten kjent lengde
show_spinner() {
    local pid=$1
    local message="${2:-Arbeider...}"
    local i=0
    local spin_len=${#SPINNER_CHARS}
    
    while kill -0 "$pid" 2>/dev/null; do
        local char="${SPINNER_CHARS:i++%spin_len:1}"
        echo -ne "\r$char $message"
        sleep 0.1
    done
    echo -ne "\r\033[K"  # Clear linje
}

# Vis fase-overskrift
show_phase() {
    local phase="$1"
    local description="$2"
    
    echo -e "\n\033[1;34m=== $phase ===\033[0m"
    [[ -n "$description" ]] && echo "$description"
    echo
}

# Vis suksess-melding
show_success() {
    local message="$1"
    echo -e "\033[1;32m✓ $message\033[0m"
}

# Vis feil-melding
show_error() {
    local message="$1"
    echo -e "\033[1;31m✗ $message\033[0m"
}

# Vis advarsel
show_warning() {
    local message="$1"
    echo -e "\033[1;33m⚠ $message\033[0m"
}

# Vis oppsummering av operasjon
show_summary() {
    local title="$1"
    shift
    local details=("$@")
    
    echo -e "\n\033[1;36m=== $title ===\033[0m"
    for detail in "${details[@]}"; do
        echo "• $detail"
    done
    echo
}

# Toggle progress visning
toggle_progress() {
    PROGRESS_ENABLED="$1"
}

# Eksempel på bruk:
# init_progress 100 "Kopierer filer"
# for ((i=0; i<100; i++)); do
#     update_progress
#     sleep 0.1
# done
# echo  # Ny linje etter fullført progress

# -----------------------------------------------------------------------------
# Funksjoner for systemsjekk
# -----------------------------------------------------------------------------

collect_system_info() {
    local backup_dir="$1"
    local info_dir="${backup_dir}/system_info"
    mkdir -p "$info_dir"
    
    log "INFO" "Samler systeminformasjon..."

    # Hent konfigurerte info-typer
    local collect_info=true
    typeset -a info_types
    info_types=()
    
    if [[ -f "$YAML_FILE" ]]; then
        collect_info=$(yq e ".system_info.collect // true" "$YAML_FILE")
        while IFS='' read -r type; do
            [[ -n "$type" ]] && info_types+=("$type")
        done < <(yq e ".system_info.include[]" "$YAML_FILE" 2>/dev/null || echo "")
    fi

    if [[ "$collect_info" != "true" ]]; then
        log "INFO" "Systeminfo-innsamling er deaktivert i konfigurasjon"
        return 0
    fi

    # Grunnleggende systeminfo (samles alltid)
    {
        echo "System Information"
        echo "================="
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Hostname: $(scutil --get LocalHostName 2>/dev/null || hostname)"
        echo "OS Version: $(sw_vers -productVersion)"
        echo "Build Version: $(sw_vers -buildVersion)"
        echo "Architecture: $(uname -m)"
        echo "User: $USER"
        echo "Home Directory: $HOME"
    } > "${info_dir}/system_basic.txt"

    # Hardware info
    if [[ " ${info_types[@]:-} " =~ " hardware_info " ]]; then
        {
            echo "Hardware Information"
            echo "==================="
            echo "CPU: $(sysctl -n machdep.cpu.brand_string)"
            echo "CPU Cores: $(sysctl -n hw.ncpu)"
            echo "Memory: $(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 )) GB"
            system_profiler SPHardwareDataType
        } > "${info_dir}/hardware_info.txt"
    fi

    # Disk og lagringsinfo
    if [[ " ${info_types[@]:-} " =~ " disk_usage " ]]; then
        {
            echo "Disk Usage Information"
            echo "====================="
            df -h
            echo -e "\nMounted Volumes:"
            mount
        } > "${info_dir}/disk_info.txt"
    fi

    # Nettverksinfo
    if [[ " ${info_types[@]:-} " =~ " network_config " ]]; then
        {
            echo "Network Configuration"
            echo "====================="
            echo "Network Interfaces:"
            ifconfig
            echo -e "\nRouting Table:"
            netstat -rn
            echo -e "\nDNS Configuration:"
            scutil --dns
        } > "${info_dir}/network_info.txt"
    fi

    # Installerte applikasjoner
    if [[ " ${info_types[@]:-} " =~ " installed_apps " ]]; then
        {
            echo "Installed Applications"
            echo "====================="
            echo "App Store Applications:"
            mas list 2>/dev/null || echo "mas not installed"
            echo -e "\nHomebrew Applications:"
            brew list 2>/dev/null || echo "brew not installed"
            echo -e "\nApplications Directory:"
            ls -la "/Applications"
        } > "${info_dir}/installed_apps.txt"
    fi

    log "INFO" "Systeminfo samlet i ${info_dir}"
    return 0
}

check_network_path() {
    local path="$1"
    if [[ "$path" =~ ^// || "$path" =~ ^smb:// ]]; then
        if ! ping -c1 -W2 "$(echo "$path" | cut -d'/' -f3)" &>/dev/null; then
            warn "Nettverkssti $path er ikke tilgjengelig"
            return 1
        fi
    fi
    return 0
}

# Sjekk tilgjengelig diskplass
check_disk_space() {
    local required_space="$1"
    local available_space
    available_space=$(df -Pk "$BACKUP_BASE_DIR" | awk 'NR==2 {print $4}')
    
    if (( available_space < required_space )); then
        error "Ikke nok diskplass. Påkrevd: $((required_space / 1024)) MB, Tilgjengelig: $((available_space / 1024)) MB"
        return 1
    fi
    
    debug "Tilstrekkelig diskplass tilgjengelig: $((available_space / 1024)) MB"
    return 0
}

# Valider backup-strategi
validate_backup_strategy() {
    local strategy="$1"
    case "$strategy" in
        comprehensive|selective)
            return 0
            ;;
        *)
            error "Ugyldig backup-strategi: $strategy. Må være 'comprehensive' eller 'selective'"
            return 1
            ;;
    esac
}

# Beregn estimert backup-størrelse
calculate_backup_size() {
    local strategy="$1"
    local total_size=0
    
    if [[ "$strategy" == "comprehensive" ]]; then
        total_size=$(du -sk "${HOME}" 2>/dev/null | cut -f1)
    else
        while IFS=''read -r dir; do
            if [[ -n "$dir" && -e "${HOME}/${dir}" ]]; then
                local dir_size
                dir_size=$(du -sk "${HOME}/${dir}" 2>/dev/null | cut -f1)
                total_size=$((total_size + dir_size))
            fi
        done < <(yq e ".hosts.$HOSTNAME.include[]" "$YAML_FILE" 2>/dev/null)
    fi
    
    echo "$total_size"
}

# Sjekk om en mappe er ekskludert
is_excluded() {
    local path="$1"
    local strategy="$2"
    
    if [[ "$strategy" == "comprehensive" ]]; then
        while IFS=''read -r pattern; do
            if [[ -n "$pattern" && "$path" == *"$pattern"* ]]; then
                return 0  # Path matches exclude pattern
            fi
        done < <(yq e ".hosts.$HOSTNAME.comprehensive_exclude[]" "$YAML_FILE" 2>/dev/null)
    else
        while IFS=''read -r pattern; do
            if [[ -n "$pattern" && "$path" == *"$pattern"* ]]; then
                return 0  # Path matches exclude pattern
            fi
        done < <(yq e ".hosts.$HOSTNAME.exclude[]" "$YAML_FILE" 2>/dev/null)
    fi
    
    return 1  # Path is not excluded
}

# -----------------------------------------------------------------------------
# Hjelpefunksjoner
# -----------------------------------------------------------------------------

# Join array elementer med spesifisert skilletegn
join_by() {
    local d=${1-} f=${2-}
    if shift 2; then
        printf %s "$f" "${@/#/$d}"
    fi
}

# Sjekk om en variabel er satt
is_set() {
    local var_name="$1"
    [[ -n "${!var_name+x}" ]]
}

# Sjekk om en variabel er tom
is_empty() {
    local var_name="$1"
    [[ -z "${!var_name}" ]]
}

# Sjekk om en kommando eksisterer
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Hjelpefunksjoner for filverifisering
verify_file_integrity() {
    local file="$1"
    local verify_type="${2:-basic}"  # 'basic' eller 'full'
    local status=0

    debug "Verifiserer filintegritet: $file (type: $verify_type)"

    # Grunnleggende sjekker
    if [[ ! -f "$file" ]]; then
        error "Fil eksisterer ikke: $file"
        return 1
    fi

    if [[ ! -r "$file" ]]; then
        error "Kan ikke lese fil: $file"
        return 1
    fi

    # Sjekk filstørrelse
    local file_size
    file_size=$(stat -f %z "$file")
    if [[ $file_size -eq 0 ]]; then
        warn "Fil er tom: $file"
        status=1
    fi

    # Full verifisering inkluderer flere sjekker
    if [[ "$verify_type" == "full" ]]; then
        # Prøv å lese filen for å sjekke om den er korrupt
        if ! dd if="$file" of=/dev/null bs=1M 2>/dev/null; then
            error "Kunne ikke lese fil: $file"
            status=1
        fi

        # Sjekk filtillatelser
        local perms
        perms=$(stat -f "%Lp" "$file")
        if [[ "$perms" =~ [0-7][0-7][7][0-7] ]]; then
            warn "Fil har uvanlige tillatelser: $file ($perms)"
            status=1
        fi
    fi

    return $status
}

# Sikker sletting av filer
safe_delete() {
    local path="$1"
    if [[ -e "$path" ]]; then
        rm -rf "$path"
        debug "Slettet: $path"
        return 0
    else
        debug "Ingenting å slette: $path"
        return 0
    fi
}