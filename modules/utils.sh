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
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="${LOG_FILE:-/tmp/backup.log}"
    
    # Roter loggfiler hvis større enn 100MB
    if [[ -f "$log_file" ]] && (( $(stat -f%z "$log_file") > 104857600 )); then
        mv "$log_file" "${log_file}.1"
    fi
    
    printf "[%s] [%-5s] %s\n" "$timestamp" "$level" "$message" | tee -a "$log_file"
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
    local percent=${1:-0}
    local eta=${2:-0}
    local current_file="${3:-}"
    local width=$PROGRESS_WIDTH
    local completed=$((width * percent / 100))
    local remaining=$((width - completed))
    
    echo -ne "\033[u\033[K"  # Gå tilbake og clear linje
    echo -ne "\r["
    
    echo -ne "\033[32m"
    echo -n "${(l:completed::=:):-}"
    echo -ne "\033[33m"
    (( completed < width )) && echo -n ">"
    echo -ne "\033[37m"
    echo -n "${(l:remaining:: :):-}"
    echo -ne "\033[0m"
    
    printf "] %3d%% " "$percent"
    echo -n "[$CURRENT_PHASE] "
    [[ -n "$eta" ]] && echo -n "ETA: $(format_time "$eta") "
    [[ -n "$current_file" ]] && echo -n "Fil: ${current_file:t}"
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
    local num_cores=$(sysctl -n hw.ncpu || echo 4)
    local temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    mkdir -p "$info_dir"
    log "INFO" "Samler systeminformasjon parallelt..."

    # Verifiser konfigurasjon
    local collect_info=true
    if [[ -f "$YAML_FILE" ]]; then
        collect_info=$(yq e ".system_info.collect // true" "$YAML_FILE")
    fi

    [[ "$collect_info" != "true" ]] && return 0

    # Kjør innsamlinger parallelt
    {
        # Grunnleggende info
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
        } > "${temp_dir}/system_basic.txt" &

        # Hardware info
        {
            echo "Hardware Information"
            echo "==================="
            echo "CPU: $(sysctl -n machdep.cpu.brand_string)"
            echo "CPU Cores: $(sysctl -n hw.ncpu)"
            echo "Memory: $(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 )) GB"
            system_profiler SPHardwareDataType
        } > "${temp_dir}/hardware_info.txt" &

        # Disk info
        {
            echo "Disk Usage Information"
            echo "====================="
            df -h
            echo -e "\nMounted Volumes:"
            mount
        } > "${temp_dir}/disk_info.txt" &

        # Nettverksinfo
        {
            echo "Network Configuration"
            echo "====================="
            echo "Network Interfaces:"
            ifconfig
            echo -e "\nRouting Table:"
            netstat -rn
            echo -e "\nDNS Configuration:"
            scutil --dns
        } > "${temp_dir}/network_info.txt" &

        # Installed apps
        {
            echo "Installed Applications"
            echo "====================="
            echo "App Store Applications:"
            mas list 2>/dev/null || echo "mas not installed"
            echo -e "\nHomebrew Applications:"
            brew list 2>/dev/null || echo "brew not installed"
            echo -e "\nApplications Directory:"
            ls -la "/Applications"
        } > "${temp_dir}/installed_apps.txt" &

        wait
    }

    # Flytt filer parallelt til endelig destinasjon
    find "$temp_dir" -type f -name "*.txt" -print0 | \
    xargs -0 -n 1 -P "$num_cores" -I {} cp {} "$info_dir/"

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
    local exclude_patterns=()
    
    printf "Sjekker om '$path' er ekskludert (strategi: $strategy)\n"
    
    if [[ "$strategy" == "comprehensive" ]]; then
        mapfile -t exclude_patterns < <(yq e ".comprehensive_exclude[]" "$YAML_FILE" 2>/dev/null)
    else
        mapfile -t exclude_patterns < <(yq e ".exclude[]" "$YAML_FILE" 2>/dev/null)
    fi
    
    debug "Exclude mønstre: ${exclude_patterns[*]}"
    
    for pattern in "${exclude_patterns[@]}"; do
        if [[ -z "$pattern" ]]; then continue; fi
        
        # Bruk bash's utvidede mønstersammenlikning
        if [[ "$path" == *"$pattern"* || "$path" == "$pattern"* || "$path" == *"$pattern" ]]; then
            debug "Ekskludert av mønster: $pattern"
            return 0
        fi
    done
    
    debug "Ikke ekskludert: $path"
    return 1
}

# -----------------------------------------------------------------------------
# Hjelpefunksjoner
# -----------------------------------------------------------------------------

# Join array elementer med spesifisert skilletegn
join_by() {
    typeset d=${1-} f=${2-}
    if (( $# > 2 )); then
        shift 2
        print -n -- "$f" "${(@)^@/#/$d}"
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
    local verify_type="${2:-basic}"
    local verify_status=0

    # Grunnleggende sjekker
    if [[ ! -f "$file" ]]; then
        return 1
    fi

    if [[ ! -r "$file" ]]; then
        return 1
    fi

    # Sjekk filstørrelse
    local file_size
    file_size=$(stat -f %z "$file")
    if [[ $file_size -eq 0 ]]; then
        return 1
    fi

    # Full verifisering for kritiske filer
    if [[ "$verify_type" == "full" ]]; then
        # Prøv å lese filen
        if ! dd if="$file" of=/dev/null bs=1M 2>/dev/null; then
            return 1
        fi

        # Sjekk filtillatelser
        local perms
        perms=$(stat -f "%Lp" "$file")
        if [[ "$perms" =~ [0-7][0-7][7][0-7] ]]; then
            return 1
        fi
    fi

    return $verify_status
}

verify_metadata() {
    local backup_dir="$1"
    local metadata_file="${backup_dir}/${METADATA_FILE}"
    typeset -i verified=1  # Start med 1 (false i shell)

    if [[ ! -f "$metadata_file" ]]; then
        error "Metadata-fil mangler: ${metadata_file}"
        return 1
    fi

    # Verifiser påkrevde felt
    local -a required_fields=(
        "backup_version"
        "strategy"
        "timestamp"
    )
    
    local missing_fields=0
    for field in "${required_fields[@]}"; do
        if ! grep -q "^${field}=" "$metadata_file"; then
            error "Påkrevd metadatafelt mangler: $field"
            ((missing_fields++))
        fi
    done

    if ((missing_fields == 0)); then
        verified=0  # Sett til 0 (true i shell) hvis ingen mangler
    fi

    # Valider metadata-verdier hvis grunnleggende validering var vellykket
    if ((verified == 0)); then
        local version
        version=$(grep '^backup_version=' "$metadata_file" | cut -d= -f2)
        if [[ "$version" != "${METADATA_VERSION}" ]]; then
            warn "Metadata-versjon ($version) matcher ikke gjeldende versjon (${METADATA_VERSION})"
        fi
    fi

    return $verified
}