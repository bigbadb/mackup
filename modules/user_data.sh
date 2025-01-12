#!/usr/bin/env bash

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
    
    log "INFO" "Starter backup av brukerdata..."
    
    # Bestem backup-strategi
    local strategy
    strategy=$(get_backup_strategy)
    log "INFO" "Bruker backup-strategi: $strategy"
    
    # Bygg rsync-parametre basert på strategi
    local rsync_params
    rsync_params=($(build_rsync_params "$strategy"))
    
    # Legg til standard rsync-parametre
    rsync_params+=(
        "-ah"              # Arkiv-modus og menneskelesbar output
        "--progress"       # Vis fremgang
        "--delete"         # Slett filer som ikke finnes i kilde
        "--delete-excluded" # Slett ekskluderte filer fra backup
    )
    
    # Legg til --dry-run hvis aktivert
    [[ "$dry_run" == true ]] && rsync_params+=("--dry-run")
    
    # Håndter inkrementell backup
    if [[ "$incremental" == true && -L "$LAST_BACKUP_LINK" ]]; then
        rsync_params+=("--link-dest=$LAST_BACKUP_LINK")
    fi
    
    # Utfør backup basert på strategi
    if [[ "$strategy" == "comprehensive" ]]; then
        log "INFO" "Utfører comprehensive backup av hjemmekatalog"
        if ! backup_with_retry "${HOME}" "${backup_dir}" "${rsync_params[@]}"; then
            error "Comprehensive backup feilet"
            return 1
        fi
    else
        log "INFO" "Utfører selective backup basert på include/exclude-lister"
        local success=true
        
        # Hent inkluderte mapper fra config
        while IFS= read -r dir; do
            if [[ -n "$dir" ]]; then
                local source="${HOME}/${dir}"
                local target="${backup_dir}/${dir}"
                
                if [[ -e "$source" ]]; then
                    mkdir -p "$(dirname "$target")"
                    if ! backup_with_retry "$source" "$target" "${rsync_params[@]}"; then
                        warn "Kunne ikke ta backup av $dir"
                        success=false
                    fi
                else
                    debug "Hopper over $dir: ikke funnet"
                fi
            fi
        done < <(yq e ".hosts.$HOSTNAME.include[]" "$YAML_FILE")
        
        [[ "$success" != true ]] && return 1
    fi
    
    log "INFO" "Backup av brukerdata fullført"
    return 0
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