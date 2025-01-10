#!/usr/bin/env bash

# =============================================================================
# Modul for backup av applikasjoner
# =============================================================================

backup_apps() {
    local backup_dir="$1"
    log "INFO" "Starter backup av applikasjoner..."

    local apps_file="${backup_dir}/apps.json"
    local brew_file="${backup_dir}/homebrew.txt"

    # Backup App Store applications
    if command -v mas >/dev/null; then
        log "INFO" "Henter App Store applikasjoner..."
        if mas list > "$apps_file"; then
            debug "App Store liste lagret til $apps_file"
        else
            warn "Kunne ikke hente App Store liste"
        fi
    else
        debug "MAS er ikke installert. Hopper over App Store backup"
    fi

    # Backup Homebrew packages
    if command -v brew >/dev/null; then
        log "INFO" "Henter Homebrew pakker..."
        if brew list > "$brew_file"; then
            debug "Homebrew liste lagret til $brew_file"
        else
            warn "Kunne ikke hente Homebrew liste"
        fi
    else
        debug "Brew er ikke installert. Hopper over Homebrew backup"
    fi

    log "INFO" "Backup av applikasjoner fullført"
    return 0
}