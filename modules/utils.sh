#!/usr/bin/env bash
source "${MODULES_DIR}/config.sh"
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
    declare -a info_types=()
    
    if [[ -f "$YAML_FILE" ]]; then
        collect_info=$(yq e ".system_info.collect // true" "$YAML_FILE")
        # Erstatt mapfile med while-loop for bedre macOS-kompatibilitet
        while IFS= read -r type; do
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
    if [[ " ${info_types[*]:-} " =~ " hardware_info " ]]; then
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
    if [[ " ${info_types[*]:-} " =~ " disk_usage " ]]; then
        {
            echo "Disk Usage Information"
            echo "====================="
            df -h
            echo -e "\nMounted Volumes:"
            mount
        } > "${info_dir}/disk_info.txt"
    fi

    # Nettverksinfo
    if [[ " ${info_types[*]:-} " =~ " network_config " ]]; then
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
    if [[ " ${info_types[*]:-} " =~ " installed_apps " ]]; then
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

    # Systeminnstillinger og defaults
    {
        echo "System Settings and Defaults"
        echo "==========================="
        echo "Security Settings:"
        system_profiler SPSecureElementDataType SPFirewallDataType
        echo -e "\nTime Zone Settings:"
        systemsetup -gettimezone
        echo -e "\nPower Management Settings:"
        pmset -g
    } > "${info_dir}/system_settings.txt"

    # Lag en komplett systemrapport med begrenset detaljnivå
    system_profiler -detailLevel mini > "${info_dir}/full_system_report.txt"

    log "INFO" "Systeminfo samlet i ${info_dir}"
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
        while IFS= read -r dir; do
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
        while IFS= read -r pattern; do
            if [[ -n "$pattern" && "$path" == *"$pattern"* ]]; then
                return 0  # Path matches exclude pattern
            fi
        done < <(yq e ".hosts.$HOSTNAME.comprehensive_exclude[]" "$YAML_FILE" 2>/dev/null)
    else
        while IFS= read -r pattern; do
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