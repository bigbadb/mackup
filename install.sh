#!/usr/bin/env bash

# =============================================================================
# Installasjonsskript for Fleskeponniens Backup-System
# =============================================================================

set -euo pipefail

# Konstanter
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REQUIRED_DIRS=("modules" "backups" "backups/logs")
readonly REQUIRED_DEPS=("yq" "rsync" "mas")

# Loggingfunksjon
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf "[%s] [%-5s] %s\n" "$timestamp" "$level" "$message"
}

# Sjekk og installer avhengigheter via Homebrew
check_dependencies() {
    log "INFO" "Sjekker avhengigheter..."
    
    # Sjekk om Homebrew er installert
    if ! command -v brew >/dev/null; then
        log "ERROR" "Homebrew er ikke installert. Installer fra https://brew.sh"
        exit 1
    fi

    local missing_deps=()
    for dep in "${REQUIRED_DEPS[@]}"; do
        if ! command -v "$dep" >/dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "INFO" "Installerer manglende avhengigheter: ${missing_deps[*]}"
        for dep in "${missing_deps[@]}"; do
            log "INFO" "Installerer $dep..."
            brew install "$dep"
        done
    fi

    log "INFO" "Alle avhengigheter er på plass"
}

# Opprett nødvendige kataloger
setup_directories() {
    log "INFO" "Oppretter nødvendige kataloger..."
    
    for dir in "${REQUIRED_DIRS[@]}"; do
        local target_dir="${SCRIPT_DIR}/${dir}"
        if [[ ! -d "$target_dir" ]]; then
            mkdir -p "$target_dir"
            log "INFO" "Opprettet katalog: $target_dir"
        fi
    done
}

# Kopier moduler til riktig plassering
setup_modules() {
    log "INFO" "Setter opp backup-moduler..."
    
    local module_files=(
        "user_data.sh"
        "apps.sh"
        "system.sh"
        "utils.sh"
        "maintenance.sh"
    )

    for module in "${module_files[@]}"; do
        if [[ -f "${SCRIPT_DIR}/${module}" ]]; then
            cp "${SCRIPT_DIR}/${module}" "${SCRIPT_DIR}/modules/"
            chmod +x "${SCRIPT_DIR}/modules/${module}"
            log "INFO" "Installerte modul: $module"
        else
            log "ERROR" "Finner ikke modul: $module"
            exit 1
        fi
    done
}

# Sett opp konfigurasjon
setup_config() {
    log "INFO" "Setter opp konfigurasjon..."
    
    if [[ ! -f "${SCRIPT_DIR}/config.yaml" ]]; then
        if [[ -f "${SCRIPT_DIR}/default-config.yaml" ]]; then
            # Spør om backup-strategi
            local strategy
            while true; do
                read -rp "Velg backup-strategi (comprehensive/selective) [comprehensive]: " strategy
                strategy=${strategy:-comprehensive}
                if [[ "$strategy" == "comprehensive" || "$strategy" == "selective" ]]; then
                    break
                fi
                echo "Ugyldig valg. Vennligst velg 'comprehensive' eller 'selective'."
            done
            
            # Kopier default config
            cp "${SCRIPT_DIR}/default-config.yaml" "${SCRIPT_DIR}/config.yaml"
            
            # Oppdater med valgt strategi og hostname
            local hostname
            hostname=$(scutil --get LocalHostName || hostname)
            
            # Opprett host-spesifikk konfigurasjon
            yq e ".hosts.$hostname.backup_strategy = \"$strategy\"" -i "${SCRIPT_DIR}/config.yaml"
            
            if [[ "$strategy" == "selective" ]]; then
                # Kopier standard include/exclude lister
                yq e ".include[]" "${SCRIPT_DIR}/default-config.yaml" | \
                    yq e ".hosts.$hostname.include += [.]" -i "${SCRIPT_DIR}/config.yaml"
                yq e ".exclude[]" "${SCRIPT_DIR}/default-config.yaml" | \
                    yq e ".hosts.$hostname.exclude += [.]" -i "${SCRIPT_DIR}/config.yaml"
            else
                # Kopier comprehensive excludes
                yq e ".comprehensive_exclude[]" "${SCRIPT_DIR}/default-config.yaml" | \
                    yq e ".hosts.$hostname.comprehensive_exclude += [.]" -i "${SCRIPT_DIR}/config.yaml"
            fi
            
            log "INFO" "Opprettet config.yaml med $strategy backup-strategi"
        else
            error "default-config.yaml mangler"
            return 1
        fi
    fi

    # Sett riktige tilganger
    chmod 600 "${SCRIPT_DIR}/config.yaml" 2>/dev/null || true
}

# Verifiser installasjon
verify_installation() {
    log "INFO" "Verifiserer installasjon..."
    
    local verification_failed=false

    # Sjekk at alle moduler er på plass og kjørbare
    for module in "${SCRIPT_DIR}/modules"/*.sh; do
        if [[ ! -x "$module" ]]; then
            log "ERROR" "Modul er ikke kjørbar: $module"
            verification_failed=true
        fi
    done

    # Sjekk at backup.sh er kjørbar
    if [[ ! -x "${SCRIPT_DIR}/backup.sh" ]]; then
        log "ERROR" "backup.sh er ikke kjørbar"
        verification_failed=true
    fi

    # Sjekk konfigurasjon
    if [[ ! -f "${SCRIPT_DIR}/config.yaml" ]]; then
        log "ERROR" "config.yaml mangler"
        verification_failed=true
    fi

    if [[ "$verification_failed" == true ]]; then
        log "ERROR" "Installasjonverifisering feilet"
        return 1
    fi

    log "INFO" "Installasjon verifisert OK"
}

# Hovedfunksjon
main() {
    log "INFO" "Starter installasjon av backup-system..."

    check_dependencies
    setup_directories
    setup_modules
    setup_config
    
    # Gjør backup.sh kjørbar
    chmod +x "${SCRIPT_DIR}/backup.sh"

    if verify_installation; then
        log "INFO" "Installasjon fullført!"
        log "INFO" "Du kan nå kjøre: ./backup.sh --help for å se tilgjengelige kommandoer"
    else
        log "ERROR" "Installasjon feilet - se feilmeldinger over"
        exit 1
    fi
}

# Kjør hovedfunksjonen
main
