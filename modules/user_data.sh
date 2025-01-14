#!/usr/bin/env zsh
source "${MODULES_DIR}/config.sh"

# =============================================================================
# Konstanter
# =============================================================================
readonly MAX_RETRIES=3
readonly RETRY_DELAY=30

# =============================================================================
# Modul for backup og gjenoppretting av brukerdata
# =============================================================================

# Funksjon for å hente backup-strategi fra config
get_backup_strategy() {
    # Sjekk først om strategi er satt via kommandolinje
    if [[ -n "${CONFIG_STRATEGY:-}" ]]; then
        echo "$CONFIG_STRATEGY"
        return 0
    fi
    
    # Hvis ikke, hent fra config
    local default_strategy="comprehensive"
    
    if [[ -f "$YAML_FILE" ]]; then
        local strategy
        strategy=$(yq e ".backup_strategy // \"$default_strategy\"" "$YAML_FILE")
        echo "$strategy"
    else
        echo "$default_strategy"
    fi
}

# Robust backup-funksjon med retry-mekanisme
backup_with_retry() {
    local source="$1"
    local target="$2"
    shift 2
    local rsync_opts=("$@")
    local retry_count=0
    local success=false

    while (( retry_count < MAX_RETRIES )) && [[ "$success" == false ]]; do
        if rsync -ah --progress --timeout=60 "${rsync_opts[@]}" "$source/" "$target/" 2>&1 | \
            while read -r line; do
                if [[ "$line" =~ ^[0-9]+% ]]; then
                    local percent=${line%\%*}
                    update_progress "$((percent - CURRENT_PROGRESS))"
                fi
            done
        then
            success=true
            debug "Vellykket synkronisering av $source til $target"
        else
            retry_count=$((retry_count + 1))
            if (( retry_count < MAX_RETRIES )); then
                warn "Rsync feilet for $source, forsøker igjen om $RETRY_DELAY sekunder (forsøk $retry_count av $MAX_RETRIES)"
                sleep "$RETRY_DELAY"
            fi
        fi
    done

    if [[ "$success" == false ]]; then
        error "Kunne ikke kopiere $source etter $MAX_RETRIES forsøk"
        return 1
    fi
    
    return 0
}

# Liste ut brukermapper som vil bli sikkerhetskopiert
list_user_directories() {
    local strategy
    strategy=$(get_backup_strategy)
    
    log "INFO" "Lister brukermapper som vil sikkerhetskopieres (strategi: $strategy)"
    
    if [[ "$strategy" == "comprehensive" ]]; then
        log "INFO" "Comprehensive backup - hele hjemmekatalogen vil bli kopiert med følgende unntak:"
        yq e ".hosts.$HOSTNAME.comprehensive_exclude[] // .comprehensive_exclude[]" "$YAML_FILE" 2>/dev/null
        
        log "INFO" "Følgende vil alltid bli inkludert:"
        yq e ".hosts.$HOSTNAME.force_include[] // .force_include[]" "$YAML_FILE" 2>/dev/null
    else
        log "INFO" "Selective backup - følgende mapper vil bli kopiert:"
        yq e ".hosts.$HOSTNAME.include[]" "$YAML_FILE" 2>/dev/null || {
            echo "Documents"
            echo "Downloads"
            echo "Pictures"
            echo "Music"
            echo ".ssh"
            echo ".config"
        }
    fi
}

# Håndterer spesialtilfeller definert i config.yaml
handle_special_cases() {
    local hostname="$1"
    local backup_dir="$2"
    
    log "INFO" "Sjekker etter spesialtilfeller for $hostname..."
    
    # Les special_cases fra config
    local cases
    cases=$(yq e ".hosts.$hostname.special_cases" "$YAML_FILE" 2>/dev/null)
    
    if [[ "$cases" == "null" || -z "$cases" ]]; then
        debug "Ingen spesialtilfeller funnet"
        return 0
    fi
    
    # Prosesser hvert spesialtilfelle
    while IFS= read -r case_name; do
        [[ -z "$case_name" ]] && continue
        
        local source
        local destination
        local only_latest
        
        source=$(yq e ".hosts.$hostname.special_cases.$case_name.source" "$YAML_FILE")
        destination=$(yq e ".hosts.$hostname.special_cases.$case_name.destination" "$YAML_FILE")
        only_latest=$(yq e ".hosts.$hostname.special_cases.$case_name.only_latest // false" "$YAML_FILE")
        
        # Ekspander ~/ til full path
        source="${source/#\~/$HOME}"
        destination="${destination/#\~/$HOME}"
        
        if [[ ! -d "$source" ]]; then
            warn "Kildekatalog for $case_name eksisterer ikke: $source"
            continue
        fi
        
        log "INFO" "Håndterer spesialtilfelle: $case_name"
        debug "Kilde: $source"
        debug "Mål: $destination"
        
        if [[ "$only_latest" == "true" ]]; then
            # Kopier kun siste backup hvis only_latest er satt
            local latest
            latest=$(find "$source" -type f -print0 | xargs -0 ls -t | head -n1)
            if [[ -n "$latest" ]]; then
                mkdir -p "$destination"
                cp "$latest" "$destination/"
                log "INFO" "Kopierte siste backup for $case_name"
            fi
        else
            # Kopier hele katalogen
            mkdir -p "$destination"
            cp -R "$source/"* "$destination/"
            log "INFO" "Kopierte alle filer for $case_name"
        fi
    done < <(yq e ".hosts.$hostname.special_cases | keys | .[]" "$YAML_FILE" 2>/dev/null)
}

# Funksjon for å gjenopprette brukerdata
restore_user_data() {
    local backup_name="$1"
    local restore_dir="${BACKUP_BASE_DIR}/${backup_name}"

    if [[ ! -d "$restore_dir" ]]; then
        error "Backup-katalogen $restore_dir eksisterer ikke"
        return 1
    fi

    log "INFO" "Starter gjenoppretting av brukerdata fra $restore_dir..."
    
    local strategy
    strategy=$(get_backup_strategy)
    
    if [[ "$strategy" == "comprehensive" ]]; then
        log "INFO" "Gjenoppretter med comprehensive strategi..."
        local rsync_params
        rsync_params=("${(@f)$(build_rsync_params "$strategy")}")
        rsync_params+=("--backup" "--backup-dir=${HOME}/.backup_$(date +%Y%m%d_%H%M%S)")
        
        if ! backup_with_retry "$restore_dir" "$HOME" "${rsync_params[@]}"; then
            error "Gjenoppretting feilet"
            return 1
        fi
    else
        log "INFO" "Gjenoppretter med selective strategi..."
        local failed_restores=()
        
        while IFS= read -r dir; do
            if [[ -n "$dir" ]]; then
                local source="${restore_dir}/${dir}"
                local target="${HOME}/${dir}"
                
                if [[ -e "$source" ]]; then
                    log "INFO" "Gjenoppretter $dir..."
                    mkdir -p "$(dirname "$target")"
                    if ! backup_with_retry "$source" "$target"; then
                        warn "Kunne ikke gjenopprette $dir"
                        failed_restores+=("$dir")
                    fi
                else
                    warn "Hopper over $dir: ikke funnet i backup"
                fi
            fi
        done < <(yq e ".hosts.$HOSTNAME.include[]" "$YAML_FILE" 2>/dev/null)
        
        if (( ${#failed_restores[@]} > 0 )); then
            error "Gjenoppretting feilet for følgende mapper: ${failed_restores[*]}"
            return 1
        fi
    fi
    
    log "INFO" "Gjenoppretting fullført"
    return 0
}

# Funksjon for å bygge rsync exclude/include parametre
build_rsync_params() {
    local strategy="$1"
    local params=()

    if [[ "$strategy" == "comprehensive" ]]; then
        # Legg til exclude-mønstre
        while IFS= read -r pattern; do
            [[ -n "$pattern" ]] && params+=("--exclude=$pattern")
        done < <(yq e ".comprehensive_exclude[]" "$YAML_FILE" 2>/dev/null)
        
        # Legg til force-include mønstre
        while IFS= read -r pattern; do
            [[ -n "$pattern" ]] && params+=("--include=$pattern")
        done < <(yq e ".force_include[]" "$YAML_FILE" 2>/dev/null)
    else
        # For selective backup, bruk include/exclude lister
        while IFS= read -r pattern; do
            [[ -n "$pattern" ]] && params+=("--include=$pattern")
        done < <(yq e ".include[]" "$YAML_FILE" 2>/dev/null)
        
        while IFS= read -r pattern; do
            [[ -n "$pattern" ]] && params+=("--exclude=$pattern")
        done < <(yq e ".exclude[]" "$YAML_FILE" 2>/dev/null)
    fi

    echo "${params[@]}"
}

calculate_total_files() {
    local source="${1:-${HOME}}"  # Bruk HOME som default hvis ikke argument er gitt
    local total=0
    local strategy
    strategy=$(get_backup_strategy)
    
    if [[ "$strategy" == "comprehensive" ]]; then
        total=$(find "$source" -type f 2>/dev/null | wc -l)
    else
        while IFS= read -r dir; do
            [[ -n "$dir" ]] && total=$((total + $(find "${source}/${dir}" -type f 2>/dev/null | wc -l)))
        done < <(yq e ".include[]" "$YAML_FILE")
    fi
    
    echo "$total"
}

# Hovedfunksjon for backup av brukerdata
backup_user_data() {
    local backup_dir="$1"
    shift
    local dry_run=false
    local incremental=false
    local error_count=0
    local files_processed=0
    local bytes_copied=0
    local start_time
    start_time=$(date +%s)
    local total_files
    total_files=$(calculate_total_files)
    init_progress "$total_files" "Kopierer filer"
    
    # Parse argumenter
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=true
                ;;
            --incremental)
                incremental=true
                ;;
        esac
        shift
    done
    
    # Sett opp feilhåndtering
    cleanup_incomplete_backup() {
        local incomplete_dir="$1"
        local reason="${2:-Ukjent årsak}"
        log "WARN" "Starter opprydding av ufullstendig backup ($reason)..."
        if [[ -d "$incomplete_dir" ]]; then
            mv "$incomplete_dir" "${incomplete_dir}_incomplete_$(date +%Y%m%d_%H%M%S)"
            log "INFO" "Flyttet ufullstendig backup"
        fi
    }
    # Sett opp trap for å håndtere feil og avbrudd
trap 'error "Backup avbrutt - starter opprydding"; cleanup_incomplete_backup "$backup_dir" "Avbrutt av bruker"; exit 1' INT TERM

log "INFO" "Starter backup av brukerdata til $backup_dir"

# Bestem backup-strategi
local strategy
strategy=$(get_backup_strategy)
log "INFO" "Bruker backup-strategi: $strategy"

# Sjekk strategi-endring hvis inkrementell backup
if [[ "$incremental" == true ]]; then
    handle_strategy_change "$strategy"
    strategy="$BACKUP_STRATEGY"  # Oppdater strategi i tilfelle den ble endret
fi

# Opprett backup-katalog
if [[ "$dry_run" != true ]]; then
    mkdir -p "$backup_dir" || {
        error "Kunne ikke opprette backup-katalog: $backup_dir"
        return 1
    }
fi

# Bygg rsync-parametre
local rsync_params
rsync_params=("${(@f)$(build_rsync_params "$strategy")}")
rsync_params+=(
    "--dry-run"       # Bare vis hva som ville skjedd
    "--itemize-changes"  # Vis detaljerte endringer
    "-v"             # Verbose output
)

# Legg til standard rsync-parametre
rsync_params+=(
    "-ah"              # Arkiv-modus og menneskelesbar output
    "--progress"       # Vis fremgang
    "--stats"          # Samle statistikk
    "--delete"         # Slett filer som ikke finnes i kilde
    "--delete-excluded" # Slett ekskluderte filer fra backup
    "--info=progress2"
)

# Håndter dry-run
[[ "$dry_run" == true ]] && rsync_params+=("--dry-run")

local rsync_output
local rsync_status

if [[ "$incremental" == true ]]; then
    if [[ -L "$LAST_BACKUP_LINK" ]]; then
        local previous_strategy
        previous_strategy=$(get_backup_strategy_from_path "$LAST_BACKUP_LINK")

        if [[ "$strategy" == "comprehensive" && "$previous_strategy" == "selective" ]]; then
            log "INFO" "Utfører hybrid backup (selective->comprehensive)"

            local selective_params=("${rsync_params[@]}")
            selective_params+=("--link-dest=$LAST_BACKUP_LINK")

            while IFS= read -r dir; do
                if [[ -n "$dir" ]]; then
                    local source="${HOME}/${dir}"
                    local target="${backup_dir}/${dir}"

                    if [[ -e "$source" ]]; then
                        if [[ "$dry_run" != true ]]; then
                            mkdir -p "$(dirname "$target")"
                        fi
                        rsync_output=$(backup_with_retry "$source" "$target" "${selective_params[@]}" 2>&1) || {
                            rsync_status=$?
                            warn "Feil ved backup av $dir (status: $rsync_status)"
                            echo "$rsync_output" | log "WARN"
                            error_count=$((error_count + 1))
                        }
                    fi
                fi
            done < <(yq e ".include[]" "$YAML_FILE")

            log "INFO" "Tar full backup av gjenværende filer..."
            local comprehensive_params=("${rsync_params[@]}")
            while IFS= read -r dir; do
                if [[ -n "$dir" ]]; then
                    comprehensive_params+=("--exclude=${dir}")
                fi
            done < <(yq e ".include[]" "$YAML_FILE")

            rsync_output=$(backup_with_retry "${HOME}" "${backup_dir}" "${comprehensive_params[@]}" 2>&1) || {
                rsync_status=$?
                error "Comprehensive del av hybrid backup feilet (status: $rsync_status)"
                echo "$rsync_output" | log "ERROR"
                error_count=$((error_count + 1))
            }
        else
            rsync_params+=("--link-dest=$LAST_BACKUP_LINK")
            if [[ "$strategy" == "comprehensive" ]]; then
                rsync_output=$(backup_with_retry "${HOME}" "${backup_dir}" "${rsync_params[@]}" 2>&1) || {
                    rsync_status=$?
                    error "Comprehensive backup feilet (status: $rsync_status)"
                    echo "$rsync_output" | log "ERROR"
                    error_count=$((error_count + 1))
                }
            else
                while IFS= read -r dir; do
                    if [[ -n "$dir" ]]; then
                        local source="${HOME}/${dir}"
                        local target="${backup_dir}/${dir}"

                        if [[ -e "$source" ]]; then
                            if [[ "$dry_run" != true ]]; then
                                mkdir -p "$(dirname "$target")"
                            fi
                            rsync_output=$(backup_with_retry "$source" "$target" "${rsync_params[@]}" 2>&1) || {
                                rsync_status=$?
                                warn "Feil ved backup av $dir (status: $rsync_status)"
                                echo "$rsync_output" | log "WARN"
                                error_count=$((error_count + 1))
                            }
                        fi
                    fi
                done < <(yq e ".include[]" "$YAML_FILE")
            fi
        fi
    else
        warn "Inkrementell backup forespurt, men ingen tidligere backup funnet"
        log "INFO" "Utfører full backup i stedet"
    fi
else
    if [[ "$strategy" == "comprehensive" ]]; then
        rsync_output=$(backup_with_retry "${HOME}" "${backup_dir}" "${rsync_params[@]}" 2>&1) || {
            rsync_status=$?
            error "Comprehensive backup feilet (status: $rsync_status)"
            echo "$rsync_output" | log "ERROR"
            error_count=$((error_count + 1))
        }
    else
        while IFS= read -r dir; do
            if [[ -n "$dir" ]]; then
                local source="${HOME}/${dir}"
                local target="${backup_dir}/${dir}"

                if [[ -e "$source" ]]; then
                    if [[ "$dry_run" != true ]]; then
                        mkdir -p "$(dirname "$target")"
                    fi
                    rsync_output=$(backup_with_retry "$source" "$target" "${rsync_params[@]}" 2>&1) || {
                        rsync_status=$?
                        warn "Feil ved backup av $dir (status: $rsync_status)"
                        echo "$rsync_output" | log "WARN"
                        error_count=$((error_count + 1))
                    }
                fi
            fi
        done < <(yq e ".include[]" "$YAML_FILE")
    fi
fi

if [[ -n "$rsync_output" ]]; then
    files_processed=$(echo "$rsync_output" | grep "Number of files transferred" | awk '{print $5}')
    bytes_copied=$(echo "$rsync_output" | grep "Total transferred file size" | awk '{print $5}')
fi

if [[ "$dry_run" != true ]]; then
    save_backup_metadata "$backup_dir" "$strategy"
fi

local end_time
end_time=$(date +%s)
local duration=$((end_time - start_time))
local formatted_duration
formatted_duration=$(format_time "$duration")

{
    log "INFO" "Backup fullført med følgende statistikk:"
    log "INFO" "- Filer prosessert: ${files_processed:-0}"
    log "INFO" "- Bytes kopiert: ${bytes_copied:-0}"
    log "INFO" "- Feil oppstått: $error_count"
    log "INFO" "- Varighet: $duration sekunder"
}

show_summary "Backup Fullført" \
    "Tid brukt: $formatted_duration" \
    "Filer prosessert: ${files_processed:-0}" \
    "Bytes kopiert: ${bytes_copied:-0}" \
    "Total størrelse: $(du -sh "$backup_dir" | cut -f1)"

trap - ERR INT TERM

return $((error_count > 0))
}

# Hjelpefunksjon for å utføre selve backupen
perform_backup() {
    local incremental="$1"
    local strategy="$2"
    local backup_dir="$3"
    shift 3
    local -a rsync_params=("$@")

    if [[ "$incremental" == true && -L "$LAST_BACKUP_LINK" ]]; then
        rsync_params+=("--link-dest=$LAST_BACKUP_LINK")
    fi

    if [[ "$strategy" == "comprehensive" ]]; then
        RSYNC_OUTPUT=$(backup_with_retry "${HOME}" "${backup_dir}" "${rsync_params[@]}" 2>&1) || return 1
    else
        local failed=false
        while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue
            local source="${HOME}/${dir}"
            local target="${backup_dir}/${dir}"

            if [[ -e "$source" ]]; then
                mkdir -p "$(dirname "$target")" || continue
                if ! RSYNC_OUTPUT=$(backup_with_retry "$source" "$target" "${rsync_params[@]}" 2>&1); then
                    warn "Feil ved backup av $dir"
                    failed=true
                fi
            fi
        done < <(yq e ".include[]" "$YAML_FILE")
        [[ "$failed" == true ]] && return 1
    fi
    return 0
}

# Hjelpefunksjon for backup-oppsummering
show_backup_summary() {
    local duration="$1"
    local files_processed="$2"
    local bytes_copied="$3"
    local error_count="$4"
    local backup_dir="$5"

    log "INFO" "Backup fullført med følgende statistikk:"
    log "INFO" "- Filer prosessert: ${files_processed:-0}"
    log "INFO" "- Bytes kopiert: ${bytes_copied:-0}"
    log "INFO" "- Feil oppstått: $error_count"
    log "INFO" "- Varighet: $duration sekunder"

    show_summary "Backup Fullført" \
        "Tid brukt: $(format_time "$duration")" \
        "Filer prosessert: ${files_processed:-0}" \
        "Bytes kopiert: ${bytes_copied:-0}" \
        "Total størrelse: $(du -sh "$backup_dir" 2>/dev/null | cut -f1)"
}

# Funksjon for å liste hvilke filer som vil bli inkludert
preview_backup() {
    local strategy
    strategy=$(get_backup_strategy)
    local incremental="${INCREMENTAL:-false}"

    log "Previewing backup (strategy: $strategy, incremental: $incremental)"

    local -a rsync_params=(
        "-ah"
        "--dry-run"
        "--list-only"
        "--human-readable"
        "--dirs-only"
        "--max-depth=2"
    )

    if [[ "$incremental" == true && -L "$LAST_BACKUP_LINK" ]]; then
        rsync_params+=("--link-dest=$(readlink -f "$LAST_BACKUP_LINK")")
    fi

    if [[ "$strategy" == "comprehensive" ]]; then
        perform_rsync rsync_params "${HOME}/" "/dev/null"
    else
        for directory in $(get_included_directories); do
            perform_rsync rsync_params "${HOME}/${directory}" "/dev/null"
        done
    fi
}