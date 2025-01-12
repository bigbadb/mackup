#!/usr/bin/env bash

# =============================================================================
<<<<<<< HEAD
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
=======
# Modul for backup og gjenoppretting av brukerdata
# =============================================================================

# Robust backup-funksjon med nettverkshåndtering
>>>>>>> origin/main
backup_with_retry() {
    local source="$1"
    local target="$2"
    shift 2
<<<<<<< HEAD
    local rsync_opts=("$@")
    local retry_count=0
    local success=false

    while (( retry_count < MAX_RETRIES )) && [[ "$success" == false ]]; do
=======
    local max_retries=3
    local retry_count=0
    local success=false
    local rsync_opts=("$@")

    while (( retry_count < max_retries )) && [[ "$success" == false ]]; do
>>>>>>> origin/main
        if rsync -ah --progress --timeout=60 "${rsync_opts[@]}" "$source/" "$target/"; then
            success=true
            debug "Vellykket synkronisering av $source til $target"
        else
            retry_count=$((retry_count + 1))
<<<<<<< HEAD
            if (( retry_count < MAX_RETRIES )); then
                warn "Rsync feilet for $source, forsøker igjen om $RETRY_DELAY sekunder (forsøk $retry_count av $MAX_RETRIES)"
                sleep "$RETRY_DELAY"
=======
            if (( retry_count < max_retries )); then
                warn "Rsync feilet for $source, forsøker igjen om 30 sekunder (forsøk $retry_count av $max_retries)"
                sleep 30
>>>>>>> origin/main
            fi
        fi
    done

    if [[ "$success" == false ]]; then
<<<<<<< HEAD
        error "Kunne ikke kopiere $source etter $MAX_RETRIES forsøk"
=======
        error "Kunne ikke kopiere $source etter $max_retries forsøk"
>>>>>>> origin/main
        return 1
    fi
    
    return 0
}

<<<<<<< HEAD
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
=======
# Hovedfunksjon for backup av brukerdata

backup_user_data() {
    local backup_dir="$1"
    shift
    local dry_run=false
    local incremental=false
    local rsync_excludes=()

    # Parse argumenter
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --exclude=*)
                [[ -n "${1#*=}" ]] && rsync_excludes+=("--exclude=${1#*=}")
                ;;
            --dry-run)
                dry_run=true
                ;;
            --incremental)
                incremental=true
                ;;
        esac
        shift
    done

    log "INFO" "Starter backup av brukermapper..."

    # Last mapper fra YAML eller bruk standardverdier
    local directories=()
    if [[ -f "$YAML_FILE" ]]; then
        while IFS= read -r dir; do
            [[ -n "$dir" ]] && directories+=("$dir")
        done < <(yq e ".hosts.$HOSTNAME.include[]" "$YAML_FILE" 2>/dev/null || echo "")
    fi

    # Hvis ingen mapper funnet, bruk standardverdier
    if [[ ${#directories[@]} -eq 0 ]]; then
        directories=(
            "Documents"
            "Downloads"
            "Pictures"
            "Music"
            ".ssh"
            ".config"
        )
        debug "Bruker standardmapper: ${directories[*]}"
    fi

    local success=true
    local processed=0
    local failed=0

    for dir in "${directories[@]}"; do
        local source="${HOME}/${dir}"
        local target="${backup_dir}/${dir}"

        if [[ -e "$source" ]]; then
            debug "Prosesserer $dir..."
            mkdir -p "$target"

            # Forbered rsync kommando
            local rsync_cmd=(rsync -ah --progress)
            
            # Legg til --link-dest hvis inkrementell
            if [[ "$incremental" == true && -L "$LAST_BACKUP_LINK" ]]; then
                rsync_cmd+=(--link-dest="$LAST_BACKUP_LINK/$dir")
            fi
            
            # Legg til exclude-parametre hvis de finnes
            if [[ ${#rsync_excludes[@]} -gt 0 ]]; then
                rsync_cmd+=("${rsync_excludes[@]}")
            fi
            
            if [[ "$dry_run" == true ]]; then
                log "INFO" "[DRY-RUN] Ville tatt backup av $source -> $target"
                ((processed++))
            else
                if "${rsync_cmd[@]}" "$source/" "$target/"; then
                    debug "Backup fullført for $dir"
                    ((processed++))
                else
                    warn "Feil under backup av $dir"
                    success=false
                    ((failed++))
                fi
            fi
        else
            debug "Hopper over $dir: ikke funnet"
        fi
    done

    if [[ "$success" == true ]]; then
        log "INFO" "Backup av brukermapper fullført. Prosessert: $processed"
        return 0
    else
        warn "Backup av brukermapper fullført med feil. Vellykket: $processed, Feilet: $failed"
        return 1
    fi
}

list_user_directories() {
    log "INFO" "Lister brukermapper som skal sikkerhetskopieres:"
    if [[ -f "$YAML_FILE" ]]; then
        yq e ".include[]" "$YAML_FILE" 2>/dev/null
    else
        local directories=(
            "Documents"
            "Downloads"
            "Pictures"
            "Music"
            ".ssh"
            ".config"
        )
        printf "%s\n" "${directories[@]}"
>>>>>>> origin/main
    fi
}

# Funksjon for å gjenopprette brukerdata
restore_user_data() {
    local backup_name="$1"
    local restore_dir="${BACKUP_BASE_DIR}/${backup_name}"

    if [[ ! -d "$restore_dir" ]]; then
        error "Backup-katalogen $restore_dir eksisterer ikke"
        return 1
<<<<<<< HEAD
    }

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
=======
    fi

    log "Starter gjenoppretting av brukermapper fra $restore_dir..."
    
    local directories=()
    if [[ -f "$YAML_FILE" ]]; then
        if ! directories=($(load_yaml_value ".include[]" "$YAML_FILE")); then
            error "Kunne ikke laste mappeliste fra YAML-fil"
            return 1
        fi
    else
        directories=(
            "Documents"
            "Downloads"
            "Pictures"
            "Music"
            "Movies"
            ".ssh"
            ".config"
            ".zshrc"
            ".bashrc"
            ".bash_profile"
            ".gitconfig"
            ".env"
            ".aws"
            "Library/Application Support/Code/User"
        )
    fi

    local failed_restores=()

    for dir in "${directories[@]}"; do
        local source="${restore_dir}/${dir}"
        local target="${HOME}/${dir}"

        if [[ -e "$source" ]]; then
            log "Gjenoppretter $dir..."
            if ! backup_with_retry "$source" "$target"; then
                warn "Kunne ikke gjenopprette $dir"
                failed_restores+=("$dir")
            fi
        else
            warn "Hopper over $dir: ikke funnet i backup"
        fi
    done

    if [[ ${#failed_restores[@]} -eq 0 ]]; then
        log "Gjenoppretting fullført vellykket"
        return 0
    else
        error "Gjenoppretting feilet for følgende mapper: ${failed_restores[*]}"
        return 1
    fi
}
>>>>>>> origin/main
