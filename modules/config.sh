#!/usr/bin/env zsh

# =============================================================================
# Modul for konfigurasjonshåndtering
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Konfigurasjonskonstanter og globale variabler
# -----------------------------------------------------------------------------

# Grunnleggende konfigurasjonsvariabler
typeset -gA CONFIG
: ${CONFIG_STRATEGY:=""}
: ${CONFIG_INCREMENTAL:="false"}
: ${CONFIG_VERIFY:="true"}
typeset -ga CONFIG_EXCLUDES
typeset -ga CONFIG_FORCE_INCLUDE
typeset -ga CONFIG_INCLUDES
: ${CONFIG_COLLECT_SYSINFO:="true"}
typeset -ga CONFIG_SYSINFO_TYPES


# Vedlikeholdskonfigurasjonsvariabler
: ${CHECKSUM_FILE:="checksums.md5"}
: ${METADATA_FILE="backup-metadata"}
: ${METADATA_VERSION="1.1"}

# -----------------------------------------------------------------------------
# Valideringsfunksjoner
# -----------------------------------------------------------------------------

# Valider at en YAML-fil har gyldig syntax
validate_yaml_syntax() {
    local config_file="$1"
    
    if ! yq e '.' "$config_file" >/dev/null 2>&1; then
        error "Ugyldig YAML-syntax i $config_file"
        return 1
    fi
    return 0
}

# Hovedvalideringsfunksjon
validate_config_values() {
    local config_file="$1"
    
    # Sjekk kritiske verdier
    local retention
    retention=$(yq e ".backup_retention" "$config_file")
    if (( retention < 1 || retention > 365 )); then
        error "Ugyldig backup_retention: Må være mellom 1 og 365 dager"
        return 1
    fi
    
    local compression_age
    compression_age=$(yq e ".compress_after_days" "$config_file")
    if (( compression_age < 1 || compression_age > retention )); then
        error "compress_after_days må være mellom 1 og backup_retention"
        return 1
    fi
    
    return 0
}

validate_config() {
    typeset config_file="$1"
    
    debug "Validerer konfigurasjon..."
    
    # Sjekk at filen eksisterer
    if [[ ! -f "$config_file" ]]; then
        error "Konfigurasjonsfil mangler: $config_file"
        return 1
    fi
    
    # Sjekk filrettigheter
    typeset file_perms
    file_perms=$(stat -f "%Lp" "$config_file")
    if (( file_perms != 600 )); then
        error "Konfigurasjonsfilen har feil rettigheter: $file_perms (skal være 600)"
        error "Kjør: chmod 600 $config_file"
        return 1
    fi
    
    # Valider YAML-syntax
    if ! validate_yaml_syntax "$config_file"; then
        return 1
    fi
    
    # Valider backup-strategi
    typeset strategy
    strategy=$(yq e ".backup_strategy" "$config_file")
    
    if [[ -z "$strategy" ]]; then
        error "backup_strategy er ikke definert i konfigurasjon"
        return 1
    fi
    
    case "$strategy" in
        comprehensive)
            # Sjekk påkrevde felt for comprehensive backup
            if ! yq e ".comprehensive_exclude" "$config_file" >/dev/null 2>&1; then
                error "comprehensive_exclude mangler for comprehensive backup"
                return 1
            fi
            if ! yq e ".force_include" "$config_file" >/dev/null 2>&1; then
                error "force_include mangler for comprehensive backup"
                return 1
            fi
            ;;
        selective)
            # Sjekk påkrevde felt for selective backup
            if ! yq e ".include" "$config_file" >/dev/null 2>&1; then
                error "include mangler for selective backup"
                return 1
            fi
            if ! yq e ".exclude" "$config_file" >/dev/null 2>&1; then
                error "exclude mangler for selective backup"
                return 1
            fi
            ;;
        *)
            error "Ugyldig backup-strategi: $strategy"
            error "Må være 'comprehensive' eller 'selective'"
            return 1
            ;;
    esac
    
    debug "Konfigurasjon validert OK"
    return 0
}

# -----------------------------------------------------------------------------
# Konfigurasjonslasting
# -----------------------------------------------------------------------------

# Hovedfunksjon for konfigurasjonslasting
load_config() {
    typeset config_file="$1"
    
    debug "Laster konfigurasjon fra $config_file..."
    
    # Validering av konfigurasjonsfil
    if ! validate_config "$config_file"; then
        return 1
    fi
    
    # Last hovedkonfigurasjon - respekter kommandolinje-argumenter
    if [[ -z "$CONFIG_STRATEGY" ]]; then
        CONFIG_STRATEGY=$(yq e ".backup_strategy" "$config_file")
        debug "Hentet strategi fra config: $CONFIG_STRATEGY"
    else
        debug "Bruker kommandolinje-strategi: $CONFIG_STRATEGY"
    fi
    
    CONFIG_INCREMENTAL=$(yq e ".incremental // false" "$config_file")
    CONFIG_VERIFY=$(yq e ".verify_after_backup // true" "$config_file")
    CONFIG_COLLECT_SYSINFO=$(yq e ".system_info.collect // true" "$config_file")
    
    # Nullstill arrays før lasting
    CONFIG_EXCLUDES=()
    CONFIG_FORCE_INCLUDE=()
    CONFIG_INCLUDES=()
    CONFIG_SYSINFO_TYPES=()
    
    # Last arrays basert på strategi
    if [[ "$CONFIG_STRATEGY" == "comprehensive" ]]; then
        while IFS='' read -r line; do
            [[ -n "$line" ]] && CONFIG_EXCLUDES+=("$line")
        done < <(yq e ".comprehensive_exclude[]" "$config_file")
        
        while IFS='' read -r line; do
            [[ -n "$line" ]] && CONFIG_FORCE_INCLUDE+=("$line")
        done < <(yq e ".force_include[]" "$config_file")
    else
        while IFS='' read -r line; do
            [[ -n "$line" ]] && CONFIG_INCLUDES+=("$line")
        done < <(yq e ".include[]" "$config_file")
        
        while IFS='' read -r line; do
            [[ -n "$line" ]] && CONFIG_EXCLUDES+=("$line")
        done < <(yq e ".exclude[]" "$config_file")
    fi
    
    # Last system_info konfigurasjon
    if [[ "$CONFIG_COLLECT_SYSINFO" == "true" ]]; then
        while IFS='' read -r line; do
            [[ -n "$line" ]] && CONFIG_SYSINFO_TYPES+=("$line")
        done < <(yq e ".system_info.include[]" "$config_file")
    fi
    
    # Last backup-vedlikeholdsinnstillinger
    export CONFIG_MAX_BACKUPS=$(yq e ".max_backups // 10" "$config_file")
    export CONFIG_COMPRESSION_AGE=$(yq e ".compress_after_days // 7" "$config_file")
    export CONFIG_BACKUP_RETENTION=$(yq e ".backup_retention // 30" "$config_file")
    
    # Eksporter konfigurasjonsvariablene
    export CONFIG_STRATEGY
    export CONFIG_INCREMENTAL
    export CONFIG_VERIFY
    export CONFIG_COLLECT_SYSINFO

    debug "Konfigurasjon lastet"

    validate_config_values()
    return 0
}