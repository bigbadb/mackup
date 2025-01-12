#!/usr/bin/env bash

# =============================================================================
# Modul for skanning av applikasjoner
# Del av backup-systemet
# =============================================================================

# Strikte kjøringsmoduser for bedre feilhåndtering
set -euo pipefail

# ============================================================================
# Variabler (blir satt av hovedskriptet)
# ============================================================================
# SCRIPT_DIR, LOG_FILE og andre variabler arves fra backup.sh
TEMP_DIR="/tmp/app_scan_$$"

# ============================================================================
# Hjelpefunksjoner
# ============================================================================
no_alternatives=()

scan_homebrew() {
    debug "Skanner Homebrew-installasjoner..."
    local formula_count=0
    local cask_count=0
    
    formula_count=$(brew list --formula | wc -l | tr -d ' ')
    cask_count=$(brew list --cask | wc -l | tr -d ' ')
    
    {
        echo "# Homebrew Formulae"
        brew list --formula || error "Feil ved listing av formulae"
        echo -e "\n## CASKS"
        brew list --cask || error "Feil ved listing av casks"
    } > "$TEMP_DIR/homebrew.txt"
    
    debug "Fant $formula_count formulae og $cask_count casks"
}

scan_mas_apps() {
    debug "Skanner Mac App Store-installasjoner..."
    
    {
        echo "#### Mac App Store Apps"
        mas list | awk '{$1=""; print substr($0,2)}' || error "Feil ved listing av MAS apps"
    } > "$TEMP_DIR/mas.txt"
    
    local app_count=$(mas list | wc -l | tr -d ' ')
    debug "Fant $app_count App Store-apper"
}

normalize_name() {
    local name="$1"
    echo "$name" | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/sed 's/ /-/g' | /usr/bin/sed 's/.app$//'
}

scan_manual_apps() {
    debug "Skanner manuelt installerte applikasjoner..."
    
    local brew_apps=$(brew list --cask | while read -r app; do normalize_name "$app"; done)
    local mas_apps=$(mas list | awk '{$1=""; print substr($0,2)}' | while read -r app; do normalize_name "$app"; done)
    
    {
        echo "# Manually Installed Apps"
        system_profiler SPApplicationsDataType -json | \
        jq -r '.SPApplicationsDataType[] | 
        select(
            (.obtained_from == "identified_developer") and
            (.path | startswith("/Applications")) and
            ((.path | contains("/System/") | not) and
             (.path | contains("/Library/") | not))
        ) | .path' | \
        while IFS= read -r path; do
            app_name=$(normalize_name "$(/usr/bin/basename "$path")")
            
            if echo "$brew_apps" | /usr/bin/grep -qw "$app_name" || echo "$mas_apps" | /usr/bin/grep -qw "$app_name"; then
                continue
            else
                echo "$app_name"
            fi
        done | sort -u
    } > "$TEMP_DIR/manual.txt"
    
    local manual_count=$(grep -v '^#' "$TEMP_DIR/manual.txt" | wc -l | tr -d ' ')
    debug "Fant $manual_count manuelt installerte apper"
}

check_homebrew_alternatives() {
    debug "Søker etter Homebrew-alternativer..."
    
    local all_casks=$(mktemp)
    brew search --casks '' > "$all_casks"
    
    typeset -A found_alternatives
    local no_alternatives=()
    local new_casks=()
    local total_checked=0
    local total_found=0
    local ms_office_found=false
    
    local total_apps=$(grep -v '^#' "$TEMP_DIR/manual.txt" | wc -l | tr -d ' ')
    
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        
        total_checked=$((total_checked + 1))
        normalized_line=$(normalize_name "$line")
        
        if [[ "$normalized_line" =~ ^microsoft-(word|excel|powerpoint|outlook|onenote)$ ]] && [ "$ms_office_found" = false ]; then
            found_alternatives["$line"]=1
            new_casks+=("microsoft-office")
            ms_office_found=true
            total_found=$((total_found + 1))
            continue
        elif [[ "$normalized_line" =~ ^microsoft-(word|excel|powerpoint|outlook|onenote)$ ]]; then
            found_alternatives["$line"]=1
            continue
        fi
        
        if grep -iq "^$normalized_line$" "$all_casks"; then
            found_alternatives["$line"]=1
            new_casks+=("$line")
            total_found=$((total_found + 1))
        else
            if [[ -z "${found_alternatives[$line]:-}" ]]; then
                no_alternatives+=("$line")
            fi
        fi
    done < "$TEMP_DIR/manual.txt"
    
    debug "Fant $total_found nye casks"
    
    if [[ ${#new_casks[@]} -gt 0 ]]; then
        {
            echo "### Nye CASKS"
            printf '%s\n' "${new_casks[@]}"
        } > "$TEMP_DIR/alternatives.txt"
    fi

    if [[ ${#no_alternatives[@]} -gt 0 ]]; then
        {
            echo "##### Manuelle installasjoner"
            printf '%s\n' "${no_alternatives[@]}"
        } > "$TEMP_DIR/test_no_alternatives.txt"
    fi
}

generate_apps_manifest() {
    local output_file="$1"
    debug "Genererer applikasjonsmanifest..."

    {
        echo "# ============================================================================"
        echo "# Installasjonsmanifest generert $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# ============================================================================"
        echo
        
        # Legger til innholdet av homebrew.txt hvis filen eksisterer og ikke er tom
        if [ -s "$TEMP_DIR/homebrew.txt" ]; then
            cat "$TEMP_DIR/homebrew.txt"
        fi
        echo

        # Legger til innholdet av alternatives.txt hvis filen eksisterer
        if [ -f "$TEMP_DIR/alternatives.txt" ]; then
            cat "$TEMP_DIR/alternatives.txt"
        fi
        echo

        # Legger til innholdet av mas.txt hvis filen eksisterer og ikke er tom
        if [ -s "$TEMP_DIR/mas.txt" ]; then
            cat "$TEMP_DIR/mas.txt"
        fi
        echo

        # Legger til innholdet av test_no_alternatives.txt hvis filen eksisterer og ikke er tom
        if [ -s "$TEMP_DIR/test_no_alternatives.txt" ]; then
            cat "$TEMP_DIR/test_no_alternatives.txt"
        fi
    } > "$output_file"
}

# ============================================================================
# Hovedfunksjon for applikasjonsskanning
# ============================================================================

scan_installed_apps() {
    local output_dir="$1"
    local apps_manifest="${output_dir}/apps_manifest.txt"
    
    mkdir -p "$TEMP_DIR"
    trap 'rm -rf "$TEMP_DIR"' EXIT
    
    log "INFO" "Starter skanning av installasjoner..."
    
    scan_homebrew
    scan_mas_apps
    scan_manual_apps
    check_homebrew_alternatives
    generate_apps_manifest "$apps_manifest"
    
    log "INFO" "Applikasjonsskanning fullført"
    log "INFO" "Manifest lagret i: $apps_manifest"
    
    return 0
}