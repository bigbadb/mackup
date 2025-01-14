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
RESTORE_NAME=""

# Opprett loggkatalog
mkdir -p "$LOG_DIR"
readonly TEMP_LOG_FILE="${LOG_DIR}/current.log"
LOG_FILE="$TEMP_LOG_FILE"

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
  -h, --help              Vis denne hjelpeteksten
  -s                      Velg backup-strategi interaktivt
  -sc                     Bruk comprehensive backup-strategi
  -ss                     Bruk selective backup-strategi
  -e, --exclude DIR       Ekskluder spesifikke mapper (kan brukes flere ganger)
  -i, --incremental       Utfør inkrementell backup
  -l, --list-backups      List alle tilgjengelige backups
  -r, --restore NAVN      Gjenopprett en spesifikk backup
  -p, --preview           Forhåndsvis hvilke filer som vil bli kopiert
  -v, --verify            Verifiser siste backup
      --dry-run           Simuler backup uten å gjøre endringer
      --debug             Aktiver debug-logging

Backup-strategier:
  comprehensive        Full backup av hjemmekatalog med unntak
  selective            Backup av spesifikt valgte mapper

Eksempler:
  $(basename "$0") -sc -i              # Kjør comprehensive inkrementell backup
  $(basename "$0") -ss -e Downloads    # Kjør selective backup, ekskluder Downloads
  $(basename "$0") -s                  # Velg strategi interaktivt
  $(basename "$0") -r backup-20250113  # Gjenopprett spesifikk backup
  $(basename "$0") -p -ss              # Forhåndsvis selective backup

Multiple excludes:
  $(basename "$0") -ss -e Downloads -e Documents -e Pictures
EOF
}

# Funksjon for å velge strategi interaktivt
prompt_strategy() {
    local strategy=""
    while [[ -z "$strategy" ]]; do
        read -rp "Velg backup-strategi - (c)omprehensive eller (s)elective: " choice
        case "${choice,,}" in
            c|comprehensive)
                strategy="comprehensive"
                ;;
            s|selective)
                strategy="selective"
                ;;
            *)
                echo "Ugyldig valg. Vennligst velg 'c' eller 's'"
                ;;
        esac
    done
    echo "$strategy"
}

handle_strategy_change() {
    local current_strategy="$1"
    local last_backup="${LAST_BACKUP_LINK}"
    
    if [[ ! -L "$last_backup" ]]; then
        return 0  # Ingen tidligere backup
    fi
    
    local previous_strategy
    previous_strategy=$(get_backup_strategy_from_path "$last_backup")
    
    if [[ "$previous_strategy" == "$current_strategy" ]]; then
        return 0  # Ingen strategi-endring
    fi
    
    warn "MERK: Strategi-endring oppdaget"
    log "INFO" "Forrige backup: $previous_strategy"
    log "INFO" "Valgt strategi: $current_strategy"
    log "INFO" ""
    log "INFO" "Du har følgende valg:"
    log "INFO" "1: Fortsett med $current_strategy"
    log "INFO" "2: Bytt tilbake til $previous_strategy"
    log "INFO" "3: Avbryt backup"
    
    local choice
    while true; do
        read -rp "Velg alternativ (1-3): " choice
        case "$choice" in
            1)
                log "INFO" "Fortsetter med $current_strategy backup"
                return 0
                ;;
            2)
                log "INFO" "Bytter til $previous_strategy backup"
                BACKUP_STRATEGY="$previous_strategy"
                export CONFIG_STRATEGY="$previous_strategy"
                return 0
                ;;
            3)
                log "INFO" "Backup avbrutt av bruker"
                exit 0
                ;;
            *)
                echo "Ugyldig valg. Velg 1, 2 eller 3."
                ;;
        esac
    done
}
# =============================================================================
# Håndter input-parametere
# =============================================================================
parse_arguments() {
    while (( "$#" )); do
        case "$1" in
            -h|--help)
                HELP_FLAG=true
                ;;
            -s)
                BACKUP_STRATEGY=$(prompt_strategy)
                if [[ -z "$BACKUP_STRATEGY" ]]; then
                    error "Ingen strategi valgt"
                    exit 1
                fi
                export CONFIG_STRATEGY="$BACKUP_STRATEGY"
                ;;
            -sc|--strategy=comprehensive)
                BACKUP_STRATEGY="comprehensive"
                export CONFIG_STRATEGY="$BACKUP_STRATEGY"
                ;;
            -ss|--strategy=selective)
                BACKUP_STRATEGY="selective"
                export CONFIG_STRATEGY="$BACKUP_STRATEGY"
                ;;
            -e|--exclude)
                shift
                if [[ -n "$1" ]]; then
                    EXCLUDES+=("$1")
                else
                    error "Mangler verdi for exclude"
                    show_help
                    exit 1
                fi
                ;;
            --exclude=*)
                [[ -n "${1#*=}" ]] && EXCLUDES+=("${1#*=}")
                ;;
            -i|--incremental)
                INCREMENTAL=true
                ;;
            -l|--list-backups)
                LIST_BACKUPS_FLAG=true
                ;;
            -r|--restore)
                shift
                if [[ -n "$1" ]]; then
                    RESTORE_NAME="$1"
                else
                    error "Mangler navn på backup som skal gjenopprettes"
                    show_help
                    exit 1
                fi
                ;;
            --restore=*)
                RESTORE_NAME="${1#*=}"
                ;;
            -p|--preview)
                PREVIEW_FLAG=true
                ;;
            -v|--verify)
                VERIFY_FLAG=true
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --debug)
                DEBUG=true
                ;;
            *)
                error "Ukjent parameter: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done

    if [[ "$HELP_FLAG" == true ]]; then
        show_help
        exit 0
    fi
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
    local backup_status=0

    # Sjekk tilgjengelig diskplass før vi starter
    if ! check_disk_space "$REQUIRED_SPACE"; then
        error "Ikke nok diskplass tilgjengelig"
        return 1
    fi

    # Opprett backup-katalog
    if [[ "$DRY_RUN" != true ]]; then
        mkdir -p "$BACKUP_DIR" || {
            error "Kunne ikke opprette backup-katalog: $BACKUP_DIR"
            return 1
        }
    fi

    # Sett opp argumenter for backup_user_data
    local backup_args=()
    [[ "$DRY_RUN" == true ]] && backup_args+=("--dry-run")
    [[ "$INCREMENTAL" == true ]] && backup_args+=("--incremental")

    # Utfør selve backup-operasjonen
    if ! backup_user_data "$BACKUP_DIR" "${backup_args[@]}"; then
        backup_status=$((backup_status + 1))
        error "Feil under backup av brukerdata"
    fi

    # Lagre systeminfo hvis konfigurert
    if [[ "$CONFIG_COLLECT_SYSINFO" == true ]]; then
        if ! collect_system_info "$BACKUP_DIR"; then
            backup_status=$((backup_status + 1))
            error "Feil under innsamling av systeminfo"
        fi
    fi

    # Backup av applikasjoner
    if ! backup_apps "$BACKUP_DIR"; then
        backup_status=$((backup_status + 1))
        error "Feil under backup av applikasjoner"
    fi

    # Fullfør backup
    if [[ $backup_status -eq 0 ]]; then
        if [[ "$DRY_RUN" != true ]]; then
            ln -sfn "$BACKUP_DIR" "$LAST_BACKUP_LINK"
            
            if [[ "$CONFIG_VERIFY" == true || "$VERIFY_FLAG" == true ]]; then
                if ! verify_backup "$BACKUP_DIR"; then
                    backup_status=$((backup_status + 1))
                fi
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