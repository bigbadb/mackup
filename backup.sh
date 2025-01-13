#!/usr/bin/env bash

# =============================================================================
# Modulært Backup Script med YAML-konfigurasjon
# =============================================================================

# Strict error handling
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Konstanter og Konfigurasjon
# =============================================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BACKUP_BASE_DIR="${SCRIPT_DIR}/backups"
readonly TIMESTAMP=$(date +%Y%m%d-%H%M%S)
readonly BACKUP_DIR="${BACKUP_BASE_DIR}/backup-${TIMESTAMP}"
readonly LOG_DIR="${BACKUP_BASE_DIR}/logs"
readonly MODULES_DIR="${SCRIPT_DIR}/modules"
readonly YAML_FILE="${SCRIPT_DIR}/config.yaml"
readonly DEFAULT_CONFIG="${SCRIPT_DIR}/default-config.yaml"
readonly LAST_BACKUP_LINK="${BACKUP_BASE_DIR}/last_backup"
readonly REQUIRED_SPACE=2000000  # 2GB i KB

# Opprett loggkatalog
mkdir -p "$LOG_DIR"
readonly TEMP_LOG_FILE="${LOG_DIR}/current.log"
LOG_FILE="$TEMP_LOG_FILE"  # Starter som TEMP_LOG_FILE

# Standardverdier
DRY_RUN=false
HELP_FLAG=false
INCREMENTAL=false
EXCLUDES=()
INCLUDE=()
DEBUG=false
LIST_BACKUPS_FLAG=false
VERIFY_FLAG=false
PREVIEW_FLAG=false
BACKUP_STRATEGY=""

# =============================================================================
# Last nødvendige moduler
# =============================================================================

# Last utils.sh først for loggfunksjonene
if [[ ! -f "${MODULES_DIR}/utils.sh" ]]; then
    echo "KRITISK: utils.sh mangler i ${MODULES_DIR}"
    exit 1
fi
source "${MODULES_DIR}/utils.sh"

# Last resten av modulene
load_modules() {
    local required_modules=(
        "config.sh"
        "user_data.sh"
        "maintenance.sh"
        "scan_apps.sh"
    )
    local optional_modules=(
        "apps.sh"
        "system.sh"
    )
    
    # Last påkrevde moduler
    for module in "${required_modules[@]}"; do
        if [[ ! -f "${MODULES_DIR}/${module}" ]]; then
            error "Påkrevd modul mangler: ${module}"
            return 1
        fi
        debug "Laster påkrevd modul: ${module}"
        source "${MODULES_DIR}/${module}"
    done
    
    # Last valgfrie moduler
    for module in "${optional_modules[@]}"; do
        if [[ -f "${MODULES_DIR}/${module}" ]]; then
            debug "Laster valgfri modul: ${module}"
            source "${MODULES_DIR}/${module}"
        else
            warn "Valgfri modul ikke funnet: ${module}"
        fi
    done
}

# =============================================================================
# Argument Parsing og Hjelp
# =============================================================================
show_help() {
    cat << EOF
Bruk: $(basename "$0") [ALTERNATIVER]

Alternativer:
  --help                 Vis denne hjelpeteksten
  --dry-run             Simuler backup uten å gjøre endringer
  --debug               Aktiver debug-logging
  --exclude=DIR         Ekskluder spesifikke mapper
  --incremental         Utfør inkrementell backup
  --verify              Verifiser siste backup
  --list-backups        List alle tilgjengelige backups
  --restore=NAVN        Gjenopprett en spesifikk backup
  --preview             Forhåndsvis hvilke filer som vil bli kopiert
  --strategy=TYPE       Velg backup-strategi (comprehensive/selective)

Backup-strategier:
  comprehensive        Full backup av hjemmekatalog med unntak
  selective           Backup av spesifikt valgte mapper

Eksempel:
  $(basename "$0") --strategy=comprehensive --incremental
  $(basename "$0") --preview --strategy=selective
EOF
}

# =============================================================================
# Håndter input-parametere
# =============================================================================
parse_arguments() {
    while (( "$#" )); do
        case "$1" in
            --help)
                HELP_FLAG=true
                ;;
            --verify)
                VERIFY_FLAG=true
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --debug)
                DEBUG=true
                ;;
            --preview)
                PREVIEW_FLAG=true
                ;;
            --strategy=*)
                BACKUP_STRATEGY="${1#*=}"
                if [[ "$BACKUP_STRATEGY" != "comprehensive" && "$BACKUP_STRATEGY" != "selective" ]]; then
                    error "Ugyldig backup-strategi: $BACKUP_STRATEGY"
                    show_help
                    exit 1
                fi
                ;;
            --exclude=*)
                [[ -n "${1#*=}" ]] && EXCLUDES+=("${1#*=}")
                ;;
            --incremental)
                INCREMENTAL=true
                ;;
            *)
                error "Ukjent parameter: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done

    [[ "$HELP_FLAG" == true ]] && { show_help; exit 0; }
}

# =============================================================================
# Hovedfunksjon
# =============================================================================

main() {
    # Forbedret error handling
    trap 'error "Feil i linje $LINENO: $BASH_COMMAND"' ERR
    
    # Last moduler først
    debug "Starter modullasting..."
    if ! load_modules; then
        error "Kunne ikke laste nødvendige moduler"
        exit 1
    fi
    
    # Parse argumenter før konfigurasjon for å håndtere --debug og strategy
    parse_arguments "$@"
    
    # Last konfigurasjon
    debug "Laster konfigurasjon..."
    if ! load_config "$YAML_FILE" "$(hostname)"; then
        error "Kunne ikke laste konfigurasjon"
        exit 1
    fi
    
    # Håndter spesielle operasjoner
    if [[ "$LIST_BACKUPS_FLAG" == true ]]; then
        list_backups
        exit 0
    fi
    
    # Utfør backup
    create_backup
    exit $?
}

# =============================================================================
# Backupfunksjoner
# =============================================================================

create_backup() {
    # Fullfør backup
    if [[ $backup_status -eq 0 ]]; then
        if [[ "$DRY_RUN" != true ]]; then
            ln -sfn "$BACKUP_DIR" "$LAST_BACKUP_LINK"
            
            if [[ "$CONFIG_VERIFY" == "true" || "$VERIFY_FLAG" == true ]]; then
                verify_backup "$BACKUP_DIR" || backup_status=$((backup_status + 1))
            fi
            
            maintain_backups
        fi
        
        local backup_size
        backup_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
        log "INFO" "Backup fullført${DRY_RUN:+" (dry-run)"}. Størrelse: $backup_size"
    else
        log "WARN" "Backup fullført med $backup_status feil"
    fi

    # Flytt loggfil til endelig plassering
    if [[ "$DRY_RUN" != true ]]; then
        local final_log="${LOG_DIR}/backup-${TIMESTAMP}.log"
        mv "$LOG_FILE" "$final_log"
        LOG_FILE="$final_log"
    fi

    return $backup_status
}

# Start scriptet hvis det kjøres direkte
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi