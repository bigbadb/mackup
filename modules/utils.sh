#!/usr/bin/env bash

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

# Funksjon for å samle systeminfo
collect_system_info() {
    local info_file="$1"
    
    {
        echo "System Information"
        echo "================="
        echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Hostname: $(scutil --get LocalHostName 2>/dev/null || hostname)"
        echo "OS Version: $(sw_vers -productVersion)"
        echo "Architecture: $(uname -m)"
        echo "User: $USER"
        echo "Home Directory: $HOME"
        echo "Available Space: $(df -h ~ | awk 'NR==2 {print $4}')"
        echo "Total Space: $(df -h ~ | awk 'NR==2 {print $2}')"
        echo "Memory: $(sysctl hw.memsize | awk '{print $2/1024/1024/1024 " GB"}')"
        echo "CPU: $(sysctl -n machdep.cpu.brand_string)"
    } > "$info_file"
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

<<<<<<< HEAD
        echo "CPU: $(sysctl -n machdep.cpu.brand_string)"
    } > "$info_file"
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
        # Beregn størrelse for hele hjemmekatalogen minus excludes
        # Dette er en forenklet versjon - kan forbedres med mer nøyaktig exclude-håndtering
        total_size=$(du -sk "${HOME}" 2>/dev/null | cut -f1)
    else
        # Summer størrelsen av inkluderte mapper
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
=======
>>>>>>> origin/main
    
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
<<<<<<< HEAD
}
=======
}
>>>>>>> origin/main
