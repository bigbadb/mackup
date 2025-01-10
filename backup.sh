#!/usr/bin/env bash

# =============================================================================
# Modulært Backup Script med YAML-konfigurasjon
# =============================================================================

# Strict error handling
set -euo pipefail
IFS=$'\n\t'

# Variabler for error tracking
declare current_command=""
declare last_command=""

# =============================================================================
# Konstanter og Konfigurasjon
# =============================================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BACKUP_BASE_DIR="${SCRIPT_DIR}/backups"
readonly TIMESTAMP=$(date +%Y%m%d-%H%M%S)
readonly BACKUP_DIR="${BACKUP_BASE_DIR}/backup-${TIMESTAMP}"
readonly LOG_DIR="${BACKUP_BASE_DIR}/logs"
mkdir -p "$LOG_DIR"
readonly TEMP_LOG_FILE="${LOG_DIR}/current.log"
LOG_FILE="$TEMP_LOG_FILE"  # Loggfila starter som TEMP_LOG_FILE
readonly MODULES_DIR="${SCRIPT_DIR}/modules"
readonly YAML_FILE="${SCRIPT_DIR}/config.yaml"
readonly HOSTNAME=$(scutil --get LocalHostName || echo "UnknownHost")
readonly DEFAULT_CONFIG="${SCRIPT_DIR}/default-config.yaml"
readonly LAST_BACKUP_LINK="${BACKUP_BASE_DIR}/last_backup"
readonly REQUIRED_SPACE=1000000  # 1GB i KB

# Standardverdier
DRY_RUN=false
INCREMENTAL=false
EXCLUDES=()
INCLUDE=()
DEBUG=false

# =============================================================================
# Last nødvendige moduler først
# =============================================================================

# Last utils.sh først for å få tilgang til logging-funksjoner
if [[ ! -f "${MODULES_DIR}/utils.sh" ]]; then
    echo "KRITISK: utils.sh mangler i ${MODULES_DIR}"
    exit 1
fi
source "${MODULES_DIR}/utils.sh"

# Last resten av modulene
load_modules() {
    local required_modules=("user_data.sh" "maintenance.sh")
    local optional_modules=("apps.sh" "system.sh")
    
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
# Sjekk avhengigheter
# =============================================================================
check_dependencies() {
    log "INFO" "Sjekker avhengigheter..."
    local dependencies=("yq" "rsync" "mas" "brew")
    local missing_deps=()

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        else
            debug "$dep er installert"
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        error "Følgende avhengigheter mangler: ${missing_deps[*]}"
        return 1
    fi

    debug "Alle avhengigheter er tilfredsstilt"
    return 0
}

# =============================================================================
# Last config fra YAML-fil
# =============================================================================
load_yaml_config() {
    if ! command -v yq >/dev/null 2>&1; then
        error "yq er påkrevd for YAML-parsing. Installer med 'brew install yq'"
        return 1
    fi

    if [[ -f "$YAML_FILE" ]]; then
        debug "Laster konfigurasjon for $HOSTNAME fra $YAML_FILE"
        INCLUDE=($(yq e ".hosts.$HOSTNAME.include[]" "$YAML_FILE"))
        EXCLUDES=($(yq e ".hosts.$HOSTNAME.exclude[]" "$YAML_FILE"))
        INCREMENTAL=$(yq e ".hosts.$HOSTNAME.incremental" "$YAML_FILE")
    elif [[ -f "$DEFAULT_CONFIG" ]]; then
        debug "Laster standardkonfigurasjon fra $DEFAULT_CONFIG"
        INCLUDE=($(yq e ".include[]" "$DEFAULT_CONFIG"))
        EXCLUDES=($(yq e ".exclude[]" "$DEFAULT_CONFIG"))
        INCREMENTAL=$(yq e ".incremental" "$DEFAULT_CONFIG")
    else
        warn "Ingen konfigurasjonsfil funnet. Starter interaktivt oppsett."
        interactive_config_setup
    fi
}

# =============================================================================
# Argument Parsing og Hjelp
# =============================================================================
parse_arguments() {
    HELP_FLAG=false
    LIST_BACKUPS_FLAG=false
    RESTORE_FLAG=false
    VERIFY_FLAG=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                HELP_FLAG=true
                ;;
            --list-backups)
                LIST_BACKUPS_FLAG=true
                ;;
            --restore=*)
                RESTORE_FLAG=true
                restore_backup "${1#*=}"
                exit 0
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
            --exclude=*)
                if [[ -n "${1#*=}" ]]; then
                    EXCLUDES+=("${1#*=}")
                else
                    warn "Tomt exclude-parameter ignorert"
                fi
                ;;
            --incremental)
                INCREMENTAL=true
                ;;
            -*)
                error "Ukjent parameter: $1"
                show_help
                exit 1
                ;;
            "")
                continue
                ;;
            *)
                error "Ukjent parameter: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
}

show_help() {
    cat << EOF
Bruk: $(basename "$0") [ALTERNATIVER]

Alternativer:
  --help                 Vis denne hjelpeteksten og avslutt
  --dry-run              Simuler backup uten å gjøre endringer
  --debug                Aktiver debug-logging
  --exclude=DIR          Ekskluder spesifikke mapper fra backup
  --incremental          Utfør inkrementell backup
  --verify               Verifiser siste backup
  --list-backups         List alle tilgjengelige backups
  --restore=NAVN         Gjenopprett en spesifikk backup

Eksempel:
  $(basename "$0") --incremental --exclude=Downloads
EOF
    exit 0
}

# =============================================================================
# Main Backup-funksjon
# =============================================================================
backup() {
    local exit_status=0
    log "INFO" "Starter backupprosess..."

    # Sjekk diskplass
    if ! check_disk_space "$REQUIRED_SPACE"; then
        error "Ikke nok diskplass for backup"
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "Dry-run modus aktivert. Ingen endringer vil bli gjort."
        mkdir -p "$BACKUP_DIR"
        debug "Simulerer opprettelse av backup-katalog: $BACKUP_DIR"
    else
        mkdir -p "$BACKUP_DIR"
        debug "Backup-katalog opprettet: $BACKUP_DIR"

        # Flytt loggfila til endelig plassering
        local final_log="${LOG_DIR}/backup-${TIMESTAMP}.log"
        mv "$TEMP_LOG_FILE" "$final_log"
        LOG_FILE="$final_log"
        readonly LOG_FILE
    fi

    # Utfør backup
    local backup_user_status=0
    local backup_apps_status=0
    local backup_system_status=0

    # Backup brukerdata
    backup_user_data "$BACKUP_DIR" "${EXCLUDES[@]+"${EXCLUDES[@]}"}" "$DRY_RUN" "$INCREMENTAL" || backup_user_status=$?
    [[ $backup_user_status -ne 0 ]] && warn "Feil oppstod under backup av brukerdata"

    # Backup applikasjoner
    backup_apps "$BACKUP_DIR" || backup_apps_status=$?
    [[ $backup_apps_status -ne 0 ]] && warn "Feil oppstod under backup av applikasjoner"

    # Backup systemfiler
    backup_system "$BACKUP_DIR" || backup_system_status=$?
    [[ $backup_system_status -ne 0 ]] && warn "Feil oppstod under backup av systemfiler"

    # Samlet status
    exit_status=$((backup_user_status + backup_apps_status + backup_system_status))

    if [[ "$DRY_RUN" != true && $exit_status -eq 0 ]]; then
        ln -sfn "$BACKUP_DIR" "$LAST_BACKUP_LINK"
        
        # Kjør vedlikehold
        if ! maintain_backups; then
            warn "Feil oppstod under vedlikehold av backups"
            exit_status=$((exit_status + 1))
        fi

        # Verifiser hvis spesifisert
        if [[ "$VERIFY_FLAG" == true ]]; then
            if ! verify_backup "$BACKUP_DIR"; then
                warn "Backup-verifisering feilet"
                exit_status=$((exit_status + 1))
            fi
        fi
    fi

    if [[ $exit_status -eq 0 ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log "INFO" "Dry-run fullført. Ingen endringer ble gjort."
        else
            log "INFO" "Backup fullført vellykket"
        fi
    else
        if [[ "$DRY_RUN" == true ]]; then
            log "WARN" "Dry-run fullført med advarsler"
        else
            log "WARN" "Backup fullført med advarsler"
        fi
    fi

    return $exit_status
}

# =============================================================================
# Main-funksjon
# =============================================================================
main() {
    # Sett opp forbedret error trap
    trap 'error "Uventet feil i kommando \"${BASH_COMMAND}\" på linje $LINENO. Exit status: $?"' ERR

    parse_arguments "$@"

    if [[ "$HELP_FLAG" == true ]]; then
        show_help
        exit 0
    fi

    debug "Starter modulopplasting..."
    if ! load_modules; then
        error "Kunne ikke laste nødvendige moduler"
        exit 1
    fi
    debug "Moduler lastet OK"

    debug "Sjekker avhengigheter..."
    if ! check_dependencies; then
        error "Avhengighetssjekk feilet"
        exit 1
    fi
    debug "Avhengigheter OK"

    debug "Laster konfigurasjon..."
    if ! load_yaml_config; then
        error "Kunne ikke laste konfigurasjon"
        exit 1
    fi
    debug "Konfigurasjon lastet OK"

    if [[ "$LIST_BACKUPS_FLAG" == true ]]; then
        debug "Lister backups..."
        list_backups
        exit 0
    fi

    debug "Starter backup-prosess..."
    backup
    exit $?
}

# Kjør hovedfunksjonen med alle argumenter
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi