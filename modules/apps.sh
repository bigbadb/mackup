#!/usr/bin/env zsh

# =============================================================================
# Modul for backup av applikasjoner
# =============================================================================

. "${MODULES_DIR}/config.sh"

backup_apps() {
    local backup_dir="$1"
    log "INFO" "Starter parallell backup av applikasjoner..."
    typeset -i num_cores
    num_cores=$(sysctl -n hw.ncpu || echo 4)

    # Oppretter midlertidig katalog for parallell prosessering
    TEMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TEMP_DIR"' EXIT

    # Kjør skanninger parallelt
    {
        # Homebrew
        (scan_homebrew) &
        # Mac App Store
        (scan_mas_apps) &
        # Manuelle installasjoner
        (scan_manual_apps) &
        # Vent på at alle prosesser er ferdige
        wait
    } 2>"${TEMP_DIR}/scan_errors.log"

    # Sjekk for feil
    if [[ -s "${TEMP_DIR}/scan_errors.log" ]]; then
        warn "Noen skanninger feilet:"
        cat "${TEMP_DIR}/scan_errors.log" | while read -r line; do
            warn "  $line"
        done
    fi

    # Generer manifest parallelt med xargs
    find "${TEMP_DIR}" -type f -name "*.txt" -print0 | \
    xargs -0 -n 1 -P "$num_cores" cat > "${backup_dir}/apps_manifest.txt"

    log "INFO" "Backup av applikasjoner fullført"
    return 0
}

restore_apps() {
    local backup_dir="$1"
    local manifest_file="${backup_dir}/apps_manifest.txt"
    
    if [[ ! -f "$manifest_file" ]]; then
        error "Finner ikke applikasjonsmanifest: $manifest_file"
        return 1
    fi
    
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
    while IFS='' read -r formula; do
        [[ -n "$formula" ]] && brew install "$formula"
    done
    
    # Installer Casks
    log "INFO" "Installerer Homebrew Casks..."
    grep -A9999 "^## CASKS" "$manifest_file" | \
    grep -B9999 "^###" | \
    grep -v "^#" | \
    while IFS='' read -r cask; do
        [[ -n "$cask" ]] && brew install --cask "$cask"
    done
    
    # Installer nye Casks
    log "INFO" "Installerer nye Homebrew Casks..."
    grep -A9999 "^### Nye CASKS" "$manifest_file" | \
    grep -B9999 "^####" | \
    grep -v "^#" | \
    while IFS='' read -r cask; do
        [[ -n "$cask" ]] && brew install --cask "$cask"
    done
    
    # Informer om manuelle installasjoner
    if grep -q "^##### Manuelle installasjoner" "$manifest_file"; then
        log "WARN" "Følgende applikasjoner må installeres manuelt:"
        grep -A9999 "^##### Manuelle installasjoner" "$manifest_file" | \
        grep -v "^#" | \
        while IFS='' read -r app; do
            [[ -n "$app" ]] && log "INFO" "- $app"
        done
    fi
    
    log "INFO" "Gjenoppretting av applikasjoner fullført"
    return 0
}