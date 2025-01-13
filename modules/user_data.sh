#!/usr/bin/env bash
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
    local default_strategy="comprehensive"
    
    if [[ -f "$YAML_FILE" ]]; then
        local strategy
        strategy=$(yq e ".hosts.$HOSTNAME.backup_strategy // \"$default_strategy\"" "$YAML_FILE")
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
        if rsync -ah --progress --timeout=60 "${rsync_opts[@]}" "$source/" "$target/"; then
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
        rsync_params=($(build_rsync_params "$strategy"))
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
        
        if [[ ${#failed_restores[@]} -gt 0 ]]; then
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
    local rsync_params=()
    
    if [[ "$strategy" == "comprehensive" ]]; then
        # Hent comprehensive excludes fra config
        while IFS= read -r exclude_pattern; do
            [[ -n "$exclude_pattern" ]] && rsync_params+=("--exclude=$exclude_pattern")
        done < <(yq e ".hosts.$HOSTNAME.comprehensive_exclude[] // .comprehensive_exclude[]" "$YAML_FILE")
        
        # Legg til force_include hvis definert
        while IFS= read -r force_include; do
            [[ -n "$force_include" ]] && rsync_params+=("--include=$force_include")
        done < <(yq e ".hosts.$HOSTNAME.force_include[] // .force_include[]" "$YAML_FILE")
        
    else  # selective strategi
        # Håndter includes
        while IFS= read -r include_pattern; do
            [[ -n "$include_pattern" ]] && rsync_params+=("--include=$include_pattern")
        done < <(yq e ".hosts.$HOSTNAME.include[]" "$YAML_FILE")
        
        # Håndter excludes
        while IFS= read -r exclude_pattern; do
            [[ -n "$exclude_pattern" ]] && rsync_params+=("--exclude=$exclude_pattern")
        done < <(yq e ".hosts.$HOSTNAME.exclude[]" "$YAML_FILE")
    fi
    
    echo "${rsync_params[@]}"
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
        log "WARN" "Starter opprydding av ufullstendig backup..."
        if [[ -d "$incomplete_dir" ]]; then
            mv "$incomplete_dir" "${incomplete_dir}_incomplete_$(date +%Y%m%d_%H%M%S)"
            log "INFO" "Flyttet ufullstendig backup til ${incomplete_dir}_incomplete"
        fi
    }
    
    # Sett opp trap for å håndtere feil og avbrudd
    trap 'error "Backup avbrutt - starter opprydding"; cleanup_incomplete_backup "$backup_dir"; exit 1' ERR INT TERM
    
    log "INFO" "Starter backup av brukerdata til $backup_dir"
    
    # Bestem backup-strategi
    local strategy
    strategy=$(get_backup_strategy)
    log "INFO" "Bruker backup-strategi: $strategy"
    
    # Opprett backup-katalog
    mkdir -p "$backup_dir" || {
        error "Kunne ikke opprette backup-katalog: $backup_dir"
        return 1
    }
    
    # Bygg rsync-parametre
    local rsync_params
    rsync_params=($(build_rsync_params "$strategy"))
    
    # Legg til standard rsync-parametre
    rsync_params+=(
        "-ah"              # Arkiv-modus og menneskelesbar output
        "--progress"       # Vis fremgang
        "--stats"         # Samle statistikk
        "--delete"         # Slett filer som ikke finnes i kilde
        "--delete-excluded" # Slett ekskluderte filer fra backup
    )
    
    # Håndter dry-run
    [[ "$dry_run" == true ]] && rsync_params+=("--dry-run")
    
    # Håndter inkrementell backup
    if [[ "$incremental" == true && -L "$LAST_BACKUP_LINK" ]]; then
        rsync_params+=("--link-dest=$LAST_BACKUP_LINK")
    fi
    
    # Utfør backup basert på strategi
    local rsync_output
    local rsync_status
    
    if [[ "$strategy" == "comprehensive" ]]; then
        log "INFO" "Utfører comprehensive backup av hjemmekatalog"
        rsync_output=$(backup_with_retry "${HOME}" "${backup_dir}" "${rsync_params[@]}" 2>&1) || {
            rsync_status=$?
            error "Comprehensive backup feilet med status $rsync_status"
            echo "$rsync_output" | log "ERROR"
            error_count=$((error_count + 1))
        }
    else
        log "INFO" "Utfører selective backup basert på include/exclude-lister"
        
        # Håndter spesialtilfeller først
        handle_special_cases "$(hostname)" "$backup_dir" || error_count=$((error_count + 1))
        
        # Backup av spesifiserte mapper
        while IFS= read -r dir; do
            if [[ -n "$dir" ]]; then
                local source="${HOME}/${dir}"
                local target="${backup_dir}/${dir}"
                
                if [[ -e "$source" ]]; then
                    mkdir -p "$(dirname "$target")"
                    rsync_output=$(backup_with_retry "$source" "$target" "${rsync_params[@]}" 2>&1) || {
                        rsync_status=$?
                        warn "Kunne ikke ta backup av $dir (status: $rsync_status)"
                        echo "$rsync_output" | log "WARN"
                        error_count=$((error_count + 1))
                    }
                else
                    debug "Hopper over $dir: ikke funnet"
                fi
            fi
        done < <(yq e ".include[]" "$YAML_FILE")
    fi
    
    # Samle statistikk
    if [[ -n "$rsync_output" ]]; then
        files_processed=$(echo "$rsync_output" | grep "Number of files transferred" | awk '{print $5}')
        bytes_copied=$(echo "$rsync_output" | grep "Total transferred file size" | awk '{print $5}')
    fi
    
    # Regn ut varighet
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Generer rapport
    {
        log "INFO" "Backup fullført med følgende statistikk:"
        log "INFO" "- Filer prosessert: ${files_processed:-0}"
        log "INFO" "- Bytes kopiert: ${bytes_copied:-0}"
        log "INFO" "- Feil oppstått: $error_count"
        log "INFO" "- Varighet: $duration sekunder"
    }
    
    # Fjern trap
    trap - ERR INT TERM
    
    # Returner feilstatus
    return $((error_count > 0))
}

# Funksjon for å liste hvilke filer som vil bli inkludert
preview_backup() {
    local strategy
    strategy=$(get_backup_strategy)
    
    log "INFO" "Forhåndsvisning av backup (strategi: $strategy)"
    
    local rsync_params
    rsync_params=($(build_rsync_params "$strategy"))
    rsync_params+=(
        "-ah"
        "--dry-run"
        "--verbose"
    )
    
    if [[ "$strategy" == "comprehensive" ]]; then
        rsync "${rsync_params[@]}" "${HOME}/" "/dev/null"
    else
        while IFS= read -r dir; do
            [[ -n "$dir" ]] && rsync "${rsync_params[@]}" "${HOME}/${dir}/" "/dev/null"
        done < <(yq e ".hosts.$HOSTNAME.include[]" "$YAML_FILE")
    fi
}