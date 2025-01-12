#!/usr/bin/env bash

# =============================================================================
# Modul for konfigurasjonshåndtering
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Konfigurasjonskonstanter og globale variabler
# -----------------------------------------------------------------------------

# Konfigurasjonsskjema
# OBS: Husk at declare -a gjør variabelen lokal hvis brukt i en funksjon
CONFIG_SCHEMA=(
    "backup_strategy"
    "system_info.collect"
    "system_info.include"
    "comprehensive_exclude"
    "force_include"
    "include"
    "exclude"
    "incremental"
    "verify_after_backup"
)

# Globale konfigurasjonsvariable
: "${CONFIG_STRATEGY:=""}"
: "${CONFIG_INCREMENTAL:="false"}"
: "${CONFIG_VERIFY:="true"}"
declare -a CONFIG_EXCLUDES=()
declare -a CONFIG_FORCE_INCLUDE=()
declare -a CONFIG_INCLUDES=()
: "${CONFIG_COLLECT_SYSINFO:="true"}"
declare -a CONFIG_SYSINFO_TYPES=()

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

# Valider at påkrevde felter eksisterer
validate_required_fields() {
    local config_file="$1"
    local hostname="$2"
    local missing_fields=()
    
    for field in "${CONFIG_SCHEMA[@]}"; do
        if ! yq e ".hosts.$hostname.$field" "$config_file" >/dev/null 2>&1; then
            missing_fields+=("$field")
        fi
    done
    
    if [[ ${#missing_fields[@]} -gt 0 ]]; then
        error "Manglende påkrevde felt for $hostname:"
        printf '%s\n' "${missing_fields[@]}" >&2
        return 1
    fi
    return 0
}

# Valider backup-strategi
validate_strategy() {
    local config_file="$1"
    local hostname="$2"
    
    local strategy
    strategy=$(yq e ".hosts.$hostname.backup_strategy" "$config_file")
    
    case "$strategy" in
        comprehensive|selective)
            return 0
            ;;
        *)
            error "Ugyldig backup-strategi for $hostname: $strategy"
            error "Må være 'comprehensive' eller 'selective'"
            return 1
            ;;
    esac
}

# Hovedvalideringsfunksjon
validate_config() {
    local config_file="$1"
    local hostname="$2"
    
    debug "Validerer konfigurasjon for $hostname..."
    
    # Sjekk at filen eksisterer
    if [[ ! -f "$config_file" ]]; then
        error "Konfigurasjonsfil mangler: $config_file"
        return 1
    fi
    
    # Valider YAML-syntax
    if ! validate_yaml_syntax "$config_file"; then
        return 1
    fi
    
    # Sjekk at host-konfigurasjon eksisterer
    if ! yq e ".hosts.$hostname" "$config_file" >/dev/null 2>&1; then
        error "Ingen konfigurasjon funnet for $hostname"
        return 1
    fi
    
    # Valider påkrevde felter
    if ! validate_required_fields "$config_file" "$hostname"; then
        return 1
    fi
    
    # Valider backup-strategi
    if ! validate_strategy "$config_file" "$hostname"; then
        return 1
    fi
    
    debug "Konfigurasjon validert OK"
    return 0
}

# -----------------------------------------------------------------------------
# Konfigurasjonslasting
# -----------------------------------------------------------------------------

# Last spesifikk konfigurasjonsdel
get_config() {
    local config_file="$1"
    local hostname="$2"
    local key="$3"
    local default="${4:-}"
    
    local value
    value=$(yq e ".hosts.$hostname.$key // \"$default\"" "$config_file")
    
    echo "$value"
}

# Last array-konfigurasjon
get_config_array() {
    local config_file="$1"
    local hostname="$2"
    local key="$3"
    
    local temp
    temp=$(yq e ".hosts.$hostname.$key[]" "$config_file" 2>/dev/null) || true
    if [[ -n "$temp" ]]; then
        echo "$temp"
    fi
}

# Hovedfunksjon for konfigurasjonslasting
load_config() {
    local config_file="$1"
    local hostname="${2:-$(hostname)}"
    
    debug "Laster konfigurasjon fra $config_file for $hostname..."
    
    # Valider konfigurasjon først
    if ! validate_config "$config_file" "$hostname"; then
        return 1
    fi
    
    # Last hovedkonfigurasjon
    CONFIG_STRATEGY=$(get_config "$config_file" "$hostname" "backup_strategy")
    CONFIG_INCREMENTAL=$(get_config "$config_file" "$hostname" "incremental" "false")
    CONFIG_VERIFY=$(get_config "$config_file" "$hostname" "verify_after_backup" "true")
    
    # Nullstill arrays før lasting
    CONFIG_EXCLUDES=()
    CONFIG_FORCE_INCLUDE=()
    CONFIG_INCLUDES=()
    CONFIG_SYSINFO_TYPES=()
    
    # Last arrays basert på strategi
    if [[ "$CONFIG_STRATEGY" == "comprehensive" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && CONFIG_EXCLUDES+=("$line")
        done < <(get_config_array "$config_file" "$hostname" "comprehensive_exclude")
        
        while IFS= read -r line; do
            [[ -n "$line" ]] && CONFIG_FORCE_INCLUDE+=("$line")
        done < <(get_config_array "$config_file" "$hostname" "force_include")
    else
        while IFS= read -r line; do
            [[ -n "$line" ]] && CONFIG_INCLUDES+=("$line")
        done < <(get_config_array "$config_file" "$hostname" "include")
        
        while IFS= read -r line; do
            [[ -n "$line" ]] && CONFIG_EXCLUDES+=("$line")
        done < <(get_config_array "$config_file" "$hostname" "exclude")
    fi
    
    # Last system_info konfigurasjon
    CONFIG_COLLECT_SYSINFO=$(get_config "$config_file" "$hostname" "system_info.collect" "true")
    if [[ "$CONFIG_COLLECT_SYSINFO" == "true" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && CONFIG_SYSINFO_TYPES+=("$line")
        done < <(get_config_array "$config_file" "$hostname" "system_info.include")
    fi
    
    # Eksporter konfigurasjonsvariablene
    export CONFIG_STRATEGY
    export CONFIG_INCREMENTAL
    export CONFIG_VERIFY
    export CONFIG_COLLECT_SYSINFO
    
    debug "Konfigurasjon lastet"
    return 0
}