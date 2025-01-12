#!/usr/bin/env bash

# =============================================================================
# Modul for backup av applikasjoner
# =============================================================================

backup_apps() {
    local backup_dir="$1"
    log "INFO" "Starter backup av applikasjoner..."
    
    # Utfør detaljert applikasjonsskanning
    if ! scan_installed_apps "$backup_dir"; then
        warn "Applikasjonsskanning feilet eller var ufullstendig"
    fi

    log "INFO" "Backup av applikasjoner fullført"
    return 0
}

restore_apps() {
    local backup_dir="$1"
    local manifest_file="${backup_dir}/apps_manifest.txt"
    
    if [[ ! -f "$manifest_file" ]]; then
        error "Finner ikke applikasjonsmanifest: $manifest_file"
        return 1
    }
    
    log "INFO" "Starter gjenoppretting av applikasjoner..."
    
    # Installer Homebrew hvis det mangler
    if ! command -v brew >/dev/null; then
        log "INFO" "Installerer Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    
    # Installer mas hvis det mangler
    if ! command -v mas >/dev/null; then
        log "INFO" "Installerer mas..."
        brew install mas
    fi
    
    # Installer Homebrew-pakker
    log "INFO" "Installerer Homebrew-pakker..."
    grep -A9999 "^# Homebrew Formulae" "$manifest_file" | \
    grep -B9999 "^## CASKS" | \
    grep -v "^#" | \
    while read -r formula; do
        [[ -n "$formula" ]] && brew install "$formula"
    done
    
    # Installer Casks
    log "INFO" "Installerer Homebrew Casks..."
    grep -A9999 "^## CASKS" "$manifest_file" | \
    grep -B9999 "^###" | \
    grep -v "^#" | \
    while read -r cask; do
        [[ -n "$cask" ]] && brew install --cask "$cask"
    done
    
    # Installer nye Casks
    log "INFO" "Installerer nye Homebrew Casks..."
    grep -A9999 "^### Nye CASKS" "$manifest_file" | \
    grep -B9999 "^####" | \
    grep -v "^#" | \
    while read -r cask; do
        [[ -n "$cask" ]] && brew install --cask "$cask"
    done
    
    # Informer om manuelle installasjoner
    if grep -q "^##### Manuelle installasjoner" "$manifest_file"; then
        log "WARN" "Følgende applikasjoner må installeres manuelt:"
        grep -A9999 "^##### Manuelle installasjoner" "$manifest_file" | \
        grep -v "^#" | \
        while read -r app; do
            [[ -n "$app" ]] && log "INFO" "- $app"
        done
    fi
    
    log "INFO" "Gjenoppretting av applikasjoner fullført"
    return 0
}