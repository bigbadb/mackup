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

# Robust backup-funksjon med retry-mekanisme og forbedret logging
backup_with_retry() {
    local source="$1"
    local target="$2"
    shift 2
    local -a rsync_opts=("$@")
    local retry_count=0
    local success=false
    local temp_log="/tmp/rsync_${RANDOM}.log"
    local rsync_exit_code

    log "DEBUG" "====== BACKUP WITH RETRY START ======"
    log "DEBUG" "Kilde: $source"
    log "DEBUG" "Mål: $target"
    log "DEBUG" "Rsync opsjoner: ${(j:\n:)rsync_opts}"

    # Progress tracking
    local total_files=$(find "$source" -type f 2>/dev/null | wc -l)
    init_progress "$total_files" "Backup"

    # Eksisterende sjekker
    if [[ ! -e "$source" ]]; then
        log "DEBUG" "FEIL: Kilde eksisterer ikke: $source"
        return 1
    }
    
    # Verifiser målkatalog
    local target_dir
    if [[ -d "$target" ]]; then
        target_dir="$target"
    else
        target_dir="$(dirname "$target")"
    fi
    
    if [[ ! -d "$target_dir" ]]; then
        log "DEBUG" "Oppretter målkatalog: $target_dir"
        mkdir -p "$target_dir" || {
            log "DEBUG" "FEIL: Kunne ikke opprette målkatalog"
            return 1
        }
    fi

    if [[ ! -w "$target_dir" ]]; then
        log "DEBUG" "FEIL: Mangler skrivetilgang til målkatalog"
        return 1
    }

    # Test rsync med dry-run først
    log "DEBUG" "Tester rsync-kommando med --dry-run..."
    if ! rsync --dry-run -v "${rsync_opts[@]}" "$source" "$target" > "$temp_log" 2>&1; then
        rsync_exit_code=$?
        log "ERROR" "Rsync test feilet med kode $rsync_exit_code. Output:"
        cat "$temp_log" | while IFS= read -r line; do
            log "ERROR" "  $line"
        done
        rm -f "$temp_log"
        return 1
    }

    while (( retry_count < MAX_RETRIES )) && [[ "$success" == "false" ]]; do
        log "DEBUG" "Forsøk $((retry_count + 1)) av $MAX_RETRIES"
        
        if rsync "${rsync_opts[@]}" "$source" "$target" 2>&1 | tee "$temp_log" | while IFS= read -r line; do
            if [[ "$line" =~ ^[0-9]+% ]]; then
                local current_file=$(echo "$line" | grep -o '[^ ]*$')
                update_progress 1 "$current_file"
            fi
        done; then
            rsync_exit_code=$?
            success=true
            RSYNC_OUTPUT=$(cat "$temp_log")
            log "DEBUG" "Vellykket synkronisering (exit code: $rsync_exit_code)"
        else
            rsync_exit_code=$?
            log "ERROR" "Rsync feilet med kode $rsync_exit_code"
            log "ERROR" "Rsync feilmeldinger:"
            cat "$temp_log" | while IFS= read -r line; do
                log "ERROR" "  $line"
            done

            retry_count=$((retry_count + 1))
            if (( retry_count < MAX_RETRIES )); then
                log "DEBUG" "Venter $RETRY_DELAY sekunder før neste forsøk..."
                sleep "$RETRY_DELAY"
            else
                log "ERROR" "Maks antall forsøk nådd ($MAX_RETRIES)"
            fi
        fi
    done

    rm -f "$temp_log"
    log "DEBUG" "====== BACKUP WITH RETRY SLUTT ======"

    [[ "$success" == "true" ]]
    return $?
}

# Hjelpefunksjon for selective backup
perform_selective_backup() {
    local backup_dir="$1"
    shift
    local -a rsync_params=("$@")
    local error_count=0

    log "DEBUG" "Starter selective backup til $backup_dir"
    log "DEBUG" "Grunnleggende rsync parametre: ${(j: :)rsync_params}"

    # Lag backup-katalogen først
    if [[ ! -d "$backup_dir" ]]; then
        log "DEBUG" "Oppretter hovedbackup-katalog: $backup_dir"
        mkdir -p "$backup_dir" || {
            error "Kunne ikke opprette backup-katalog"
            return 1
        }
    fi

    # Les inkluderte mapper fra config
    while IFS='' read -r item; do
        if [[ -z "$item" ]]; then
            continue
        fi

        log "DEBUG" "Prosesserer: $item"
        local source="${HOME}/${item}"
        local target="${backup_dir}/${item}"

        # Sjekk om det er en fil eller katalog
        if [[ -f "$source" ]]; then
            log "DEBUG" "Behandler fil: $item"
            # For filer, opprett målkatalogen og kopier filen
            mkdir -p "$(dirname "$target")" || {
                error "Kunne ikke opprette katalogstruktur for $item"
                ((error_count++))
                continue
            }
            cp -p "$source" "$target" || {
                error "Kunne ikke kopiere fil: $item"
                ((error_count++))
                continue
            }
            log "DEBUG" "Fil kopiert: $item"
        elif [[ -d "$source" ]]; then
            log "DEBUG" "Behandler katalog: $item"
            # For kataloger, bruk rsync
            if ! backup_with_retry "$source/" "$target/" "${rsync_params[@]}"; then
                warn "Feil ved backup av katalog: $item"
                ((error_count++))
            else
                log "DEBUG" "Katalog synkronisert: $item"
            fi
        else
            log "DEBUG" "Hopper over $item - eksisterer ikke"
        fi
    done < <(yq e ".include[]" "$YAML_FILE" 2>/dev/null)

    return $error_count
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
            if [[ -n "$pattern" ]]; then
                # Håndter relative stier og wildcards
                pattern="${pattern/#\~/$HOME}"
                # Sørg for at **/ fungerer korrekt med rsync
                pattern="${pattern/#\*\*\//\*\*}"
                params+=("--exclude=$pattern")
            fi
        done < <(yq e ".comprehensive_exclude[]" "$YAML_FILE" 2>/dev/null)
        
        # Legg til force-include mønstre
        while IFS= read -r pattern; do
            if [[ -n "$pattern" ]]; then
                pattern="${pattern/#\~/$HOME}"
                params+=("--include=$pattern")
            fi
        done < <(yq e ".force_include[]" "$YAML_FILE" 2>/dev/null)
    else
        # For selective backup, bruk include/exclude lister
        while IFS= read -r pattern; do
            if [[ -n "$pattern" ]]; then
                pattern="${pattern/#\~/$HOME}"
                params+=("--include=$pattern")
            fi
        done < <(yq e ".include[]" "$YAML_FILE" 2>/dev/null)
        
        while IFS= read -r pattern; do
            if [[ -n "$pattern" ]]; then
                pattern="${pattern/#\~/$HOME}"
                params+=("--exclude=$pattern")
            fi
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
    local excluded_count=0
    local excluded_size=0
    local bytes_copied=0
    local files_processed=0
    local start_time=$(date +%s)


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
    
    # Initialiser rsync parametre som array
    local -a rsync_params
    rsync_params=(
        "-ah"              # Arkiv-modus og menneskelesbar output
        "--progress"       # Vis fremgang
        "--stats"         # Samle statistikk
        "--delete"        # Slett filer som ikke finnes i kilde
        "--delete-excluded" # Slett ekskluderte filer fra backup
        "--info=progress2,skip2"
    )

    # Legg til dry-run hvis spesifisert
    if [[ "$dry_run" == true ]]; then
        rsync_params+=("--stats" "--info=skip2")
    fi


    # Håndter inkrementell backup
    if [[ "$incremental" == "true" && -L "$LAST_BACKUP_LINK" ]]; then
        log "DEBUG" "Legger til link-dest for inkrementell backup"
        rsync_params+=("--link-dest=$(readlink -f "$LAST_BACKUP_LINK")")
    fi

    # Bestem backup-strategi og utfør backup
    local strategy
    strategy=$(get_backup_strategy)
    log "DEBUG" "Bruker backup-strategi: $strategy"

    log "INFO" "Starter backup av brukerdata til $backup_dir"
    log "INFO" "Bruker backup-strategi: $strategy"

    if [[ "$dry_run" != "true" ]]; then
        mkdir -p "$backup_dir" || {
            error "Kunne ikke opprette backup-katalog: $backup_dir"
            return 1
        }
    fi

    # Utfør backup basert på strategi
    if [[ "$strategy" == "comprehensive" ]]; then
        # Legg til exclude/include mønstre for comprehensive backup
        while IFS='' read -r pattern; do
            [[ -n "$pattern" ]] && rsync_params+=("--exclude=$pattern")
        done < <(yq e ".comprehensive_exclude[]" "$YAML_FILE" 2>/dev/null)
        
        while IFS='' read -r pattern; do
            [[ -n "$pattern" ]] && rsync_params+=("--include=$pattern")
        done < <(yq e ".force_include[]" "$YAML_FILE" 2>/dev/null)

        # Utfør comprehensive backup
        log "DEBUG" "Starter comprehensive backup med parametre: ${(j: :)rsync_params}"
        if ! backup_with_retry "${HOME}/" "${backup_dir}/" "${rsync_params[@]}"; then
            error_count=$((error_count + 1))
        fi
    else
        # Utfør selective backup med den nye funksjonen
        log "DEBUG" "Starter selective backup"
        if ! perform_selective_backup "$backup_dir" "${rsync_params[@]}"; then
            error_count=$((error_count + 1))
        fi
    fi

    # Håndter spesialtilfeller hvis konfigurert
    if [[ "${CONFIG_HAS_SPECIAL_CASES:-false}" == "true" ]]; then
        log "DEBUG" "Håndterer spesialtilfeller"
        if ! handle_special_cases "$HOSTNAME" "$backup_dir"; then 
            error_count=$((error_count + 1))
        fi
    fi

    if [[ -n "$RSYNC_OUTPUT" ]]; then
        excluded_count=$(echo "$RSYNC_OUTPUT" | grep "Number of files excluded:" | awk '{print $5}')
        excluded_size=$(echo "$RSYNC_OUTPUT" | grep "Total transferred file size:" | awk '{print $5}')
        files_processed=$(echo "$RSYNC_OUTPUT" | grep "Number of files transferred:" | awk '{print $5}')
        bytes_copied=$(echo "$RSYNC_OUTPUT" | grep "Total bytes sent:" | awk '{print $4}')
    fi

    # Lagre metadata hvis ikke dry-run
    if [[ "$dry_run" != "true" ]]; then
        save_backup_metadata "$backup_dir" "$strategy" "$start_time" "$(date +%s)"
    fi

    # Samle statistikk og vis oppsummering
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [[ -n "$RSYNC_OUTPUT" ]]; then
        files_processed=$(echo "$RSYNC_OUTPUT" | grep "Number of files transferred" | awk '{print $5}')
        bytes_copied=$(echo "$RSYNC_OUTPUT" | grep "Total transferred file size" | awk '{print $5}')
    fi

    show_backup_summary "$(date +%s)" "$files_processed" "$bytes_copied" "$error_count" "$excluded_count" "$excluded_size" "$backup_dir"

    return $((error_count > 0))
}

# Hjelpefunksjon for selective backup
perform_selective_backup() {
    emulate -L zsh
    setopt LOCAL_OPTIONS PIPE_FAIL

    local backup_dir="$1"
    shift
    typeset -a rsync_params
    rsync_params=("$@")
    local error_count=0

    debug "Starter selective backup til $backup_dir"
    debug "Grunnleggende rsync parametre: ${(j: :)rsync_params}"

    # Lag backup-katalogen først
    if [[ ! -d "$backup_dir" ]]; then
        debug "Oppretter hovedbackup-katalog: $backup_dir"
        mkdir -p "$backup_dir" || {
            error "Kunne ikke opprette backup-katalog"
            return 1
        }
    fi

    # Les inkluderte mapper fra config
    while IFS='' read -r dir; do
        if [[ -z "$dir" ]]; then
            continue
        fi

        debug "Prosesserer katalog: $dir"
        local source="${HOME}/${dir}"
        local target="${backup_dir}/${dir}"

        # Sjekk om kilden eksisterer
        if [[ ! -e "$source" ]]; then
            debug "Hopper over $dir - eksisterer ikke"
            continue
        fi

        # Opprett målkatalogstruktur
        if [[ ! -d "$(dirname "$target")" ]]; then
            debug "Oppretter målkatalogstruktur for: $dir"
            mkdir -p "$(dirname "$target")" || {
                error "Kunne ikke opprette katalogstruktur for $dir"
                continue
            }
        fi

        # Utfør backup av denne katalogen
        debug "Starter backup av $dir"
        if ! backup_with_retry "$source" "$target" "${rsync_params[@]}"; then
            warn "Feil ved backup av $dir"
            ((error_count++))
        else
            debug "Vellykket backup av $dir"
        fi
    done < <(yq e ".include[]" "$YAML_FILE" 2>/dev/null)

    return $error_count
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
    local excluded_count="$5"
    local excluded_size="$6"
    local backup_dir="$7"

    log "INFO" "Backup fullført med følgende statistikk:"
    log "INFO" "- Filer prosessert: ${files_processed:-0}"
    log "INFO" "- Bytes kopiert: ${bytes_copied:-0}"
    log "INFO" "- Filer ekskludert: ${excluded_count:-0}"
    log "INFO" "- Ekskludert størrelse: ${excluded_size:-0}"
    log "INFO" "- Feil oppstått: $error_count"
    log "INFO" "- Varighet: $duration sekunder"

    show_summary "Backup Fullført" \
        "Tid brukt: $(format_time "$duration")" \
        "Filer prosessert: ${files_processed:-0}" \
        "Bytes kopiert: ${bytes_copied:-0}" \
        "Filer ekskludert: ${excluded_count:-0}" \
        "Total størrelse: $(du -sh "$backup_dir" 2>/dev/null | cut -f1)"
}

# Funksjon for å liste hvilke filer som vil bli inkludert i backup
preview_backup() {
    local strategy
    strategy=$(get_backup_strategy)
    local incremental="${INCREMENTAL:-false}"

    log "INFO" "Forhåndsviser backup (strategi: $strategy, inkrementell: $incremental)"

    # Basis rsync-parametre for preview
    local -a rsync_params=(
        "-ahn"             # -a for arkiv, -h for human-readable, -n for dry-run
        "--itemize-changes" # Vis detaljerte endringer
        "--list-only"      # Bare list filer, ikke prøv å kopiere
    )

    echo "====================== BACKUP PREVIEW ======================"
    if [[ "$strategy" == "comprehensive" ]]; then
        log "INFO" "Viser filer som vil bli inkludert (comprehensive backup)"
        rsync "${rsync_params[@]}" "${HOME}/" .
    else
        log "INFO" "Viser filer som vil bli inkludert (selective backup)"
        while IFS='' read -r item; do
            if [[ -z "$item" ]]; then
                continue
            fi

            local source="${HOME}/${item}"
            echo "=== Innhold i $item ==="

            if [[ -f "$source" ]]; then
                # For filer, vis bare filinfo
                ls -lh "$source"
            elif [[ -d "$source" ]]; then
                # For kataloger, bruk rsync med --list-only
                rsync "${rsync_params[@]}" "${source}/" .
            else
                echo "Finnes ikke: $item"
            fi
            echo
        done < <(yq e ".include[]" "$YAML_FILE" 2>/dev/null)
    fi
    echo "========================================================="
}