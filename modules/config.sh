#!/usr/bin/env bash

# =============================================================================
# Modul for konfigurasjonshåndtering
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Konfigurasjonskonstanter og globale variabler
# -----------------------------------------------------------------------------

# Grunnleggende konfigurasjonsvariabler
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

# Hovedvalideringsfunksjon
validate_config() {
    local config_file="$1"
    
    debug "Validerer konfigurasjon..."
    
    # Sjekk at filen eksisterer
    if [[ ! -f "$config_file" ]]; then
        error "Konfigurasjonsfil mangler: $config_file"
        return 1
    fi
    
    # Sjekk filrettigheter
    local file_perms
    file_perms=$(stat -f "%Lp" "$config_file")
    if [ "$file_perms" -ne 600 ]; then
        error "Konfigurasjonsfilen har feil rettigheter: $file_perms (skal være 600)"
        error "Kjør: chmod 600 $config_file"
        return 1
    fi
    
    # Valider YAML-syntax
    if ! validate_yaml_syntax "$config_file"; then
        return 1
    fi
    
    # Valider backup-strategi
    local strategy
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
    local config_file="$1"
    
    debug "Laster konfigurasjon fra $config_file..."
    
    # Validering av konfigurasjonsfil
    if ! validate_config "$config_file"; then
        return 1
    fi
    
    # Last hovedkonfigurasjon
    CONFIG_STRATEGY=$(yq e ".backup_strategy" "$config_file")
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
        while IFS= read -r line; do
            [[ -n "$line" ]] && CONFIG_EXCLUDES+=("$line")
        done < <(yq e ".comprehensive_exclude[]" "$config_file")
        
        while IFS= read -r line; do
            [[ -n "$line" ]] && CONFIG_FORCE_INCLUDE+=("$line")
        done < <(yq e ".force_include[]" "$config_file")
    else
        while IFS= read -r line; do
            [[ -n "$line" ]] && CONFIG_INCLUDES+=("$line")
        done < <(yq e ".include[]" "$config_file")
        
        while IFS= read -r line; do
            [[ -n "$line" ]] && CONFIG_EXCLUDES+=("$line")
        done < <(yq e ".exclude[]" "$config_file")
    fi
    
    # Last system_info konfigurasjon
    if [[ "$CONFIG_COLLECT_SYSINFO" == "true" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && CONFIG_SYSINFO_TYPES+=("$line")
        done < <(yq e ".system_info.include[]" "$config_file")
    fi
    
    # Last special cases hvis de finnes
    if yq e ".special_cases" "$config_file" >/dev/null 2>&1; then
        CONFIG_HAS_SPECIAL_CASES="true"
    else
        CONFIG_HAS_SPECIAL_CASES="false"
    fi
    
    # Eksporter konfigurasjonsvariablene
    export CONFIG_STRATEGY
    export CONFIG_INCREMENTAL
    export CONFIG_VERIFY
    export CONFIG_COLLECT_SYSINFO
    export CONFIG_HAS_SPECIAL_CASES
    
    debug "Konfigurasjon lastet"
    return 0
}