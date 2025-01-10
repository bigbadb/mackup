#!/usr/bin/env bash

# =============================================================================
# Modul for backup og gjenoppretting av brukerdata
# =============================================================================

# Robust backup-funksjon med nettverkshåndtering
backup_with_retry() {
    local source="$1"
    local target="$2"
    shift 2
    local max_retries=3
    local retry_count=0
    local success=false
    local rsync_opts=("$@")

    while (( retry_count < max_retries )) && [[ "$success" == false ]]; do
        if rsync -ah --progress --timeout=60 "${rsync_opts[@]}" "$source/" "$target/"; then
            success=true
            debug "Vellykket synkronisering av $source til $target"
        else
            retry_count=$((retry_count + 1))
            if (( retry_count < max_retries )); then
                warn "Rsync feilet for $source, forsøker igjen om 30 sekunder (forsøk $retry_count av $max_retries)"
                sleep 30
            fi
        fi
    done

    if [[ "$success" == false ]]; then
        error "Kunne ikke kopiere $source etter $max_retries forsøk"
        return 1
    fi
    
    return 0
}

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