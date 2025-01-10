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
}