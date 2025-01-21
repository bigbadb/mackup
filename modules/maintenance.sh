#!/usr/bin/env zsh

# =============================================================================
# Vedlikeholdsmodul for backup-system
# =============================================================================

source "${MODULES_DIR}/config.sh"

readonly METADATA_VERSION="1.1"
readonly METADATA_FILE="backup-metadata"
readonly CHECKSUM_FILE="checksums.md5"

# =============================================================================
# Metadatahåndtering
# =============================================================================

# Lagre utvidet metadata for en backup
save_backup_metadata() {
    local backup_dir="$1"
    local strategy="$2"
    local start_time="${3:-$(date +%s)}"
    local end_time="${4:-$(date +%s)}"
    local duration=$((end_time - start_time))
    
    if [[ "$DRY_RUN" != true ]]; then
        # Samle systeminfo
        local total_size
        total_size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
        local disk_free
        disk_free=$(df -h "$backup_dir" | awk 'NR==2 {print $4}')
        
        # Opprett metadata-fil
        cat > "${backup_dir}/${METADATA_FILE}" << EOF
# Backup Metadata v${METADATA_VERSION}
# Generert: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================================

[Grunnleggende Info]
strategy=$strategy
timestamp=${TIMESTAMP}
hostname=$(hostname)
backup_version=${METADATA_VERSION}
user=$USER

[Timing]
start_time=$(date -r $start_time '+%Y-%m-%d %H:%M:%S')
end_time=$(date -r $end_time '+%Y-%m-%d %H:%M:%S')
duration_seconds=$duration

[Systeminfo]
total_size=$total_size
available_space=$disk_free
os_version=$(sw_vers -productVersion)
architecture=$(uname -m)

[Backup Konfigurasjon]
incremental=${INCREMENTAL}
verify=${CONFIG_VERIFY}
EOF
        
        # Legg til strategi-spesifikk info
        case "$strategy" in
            comprehensive)
                {
                    echo -e "\n[Comprehensive Konfigurasjon]"
                    echo "exclude_count=${#CONFIG_EXCLUDES[@]}"
                    echo "force_include_count=${#CONFIG_FORCE_INCLUDE[@]}"
                    echo -e "\nExclude Patterns:"
                    printf '%s\n' "${CONFIG_EXCLUDES[@]}" | sed 's/^/- /'
                    echo -e "\nForce Include Patterns:"
                    printf '%s\n' "${CONFIG_FORCE_INCLUDE[@]}" | sed 's/^/- /'
                } >> "${backup_dir}/${METADATA_FILE}"
                ;;
            selective)
                {
                    echo -e "\n[Selective Konfigurasjon]"
                    echo "include_count=${#CONFIG_INCLUDES[@]}"
                    echo "exclude_count=${#CONFIG_EXCLUDES[@]}"
                    echo -e "\nInclude Patterns:"
                    printf '%s\n' "${CONFIG_INCLUDES[@]}" | sed 's/^/- /'
                    echo -e "\nExclude Patterns:"
                    printf '%s\n' "${CONFIG_EXCLUDES[@]}" | sed 's/^/- /'
                } >> "${backup_dir}/${METADATA_FILE}"
                ;;
        esac
        
        # Sett riktige tilganger
        chmod 600 "${backup_dir}/${METADATA_FILE}"
    fi
}

# Les og valider metadata fra en backup
read_backup_metadata() {
    typeset backup_dir="$1"
    typeset metadata_file="${backup_dir}/${METADATA_FILE}"

    if [[ ! -r "$metadata_file" ]]; then
        error "Kan ikke lese metadata-fil: $metadata_file"
        return 1
    fi
    
    # Sjekk metadata-versjon
    typeset version
    version=$(grep '^backup_version=' "$metadata_file" | cut -d= -f2)
    if [[ -z "$version" ]]; then
        warn "Ingen versjonsinformasjon funnet i metadata"
        return 1
    fi
    
    # Parse og returner metadata som et assosiativt array
    typeset -A metadata
    while IFS='=' read -r key value; do
        # Ignorer kommentarer og tomme linjer
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        
        key=${key//[[:space:]]/}
        metadata[$key]=$value
    done < "$metadata_file"
    
    # Eksporter metadata til miljøvariabler
    for key in ${(k)metadata}; do
        export "BACKUP_${key:u}"="${metadata[$key]}"
    done
    
    return 0
}

# Oppdater metadata for en eksisterende backup
update_backup_metadata() {
    local backup_dir="$1"
    local key="$2"
    local value="$3"
    local metadata_file="${backup_dir}/${METADATA_FILE}"
    
    if [[ ! -f "$metadata_file" ]]; then
        error "Kan ikke oppdatere metadata: Fil mangler"
        return 1
    fi
    
    # Sikkerhetskopi av original metadata
    cp "$metadata_file" "${metadata_file}.bak"
    
    # Oppdater metadata
    if grep -q "^${key}=" "$metadata_file"; then
        sed -i '' "s|^${key}=.*|${key}=${value}|" "$metadata_file"
    else
        echo "${key}=${value}" >> "$metadata_file"
    fi
    
    # Verifiser oppdatering
    if ! grep -q "^${key}=${value}$" "$metadata_file"; then
        warn "Kunne ikke verifisere metadata-oppdatering"
        mv "${metadata_file}.bak" "$metadata_file"
        return 1
    fi
    
    rm "${metadata_file}.bak"
    return 0
}

# Generer rapport basert på metadata
generate_metadata_report() {
    local backup_dir="$1"
    local output_file="${backup_dir}/backup-report.txt"
    
    if ! read_backup_metadata "$backup_dir"; then
        error "Kunne ikke lese metadata for rapport"
        return 1
    fi
    
    {
        echo "===== Backup Rapport ====="
        echo "Generert: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "------------------------"
        echo "Backup ID: $(basename "$backup_dir")"
        echo "Strategi: $BACKUP_STRATEGY"
        echo "Opprettet: $BACKUP_TIMESTAMP"
        echo "Varighet: $BACKUP_DURATION_SECONDS sekunder"
        echo "Total størrelse: $BACKUP_TOTAL_SIZE"
        echo "------------------------"
    } > "$output_file"
    
    return 0
}

# Hent backup-strategi fra en backup
get_backup_strategy_from_path() {
    local backup_path="$1"
    if [[ -f "${backup_path}/${METADATA_FILE}" ]]; then
        grep '^strategy=' "${backup_path}/${METADATA_FILE}" | cut -d= -f2
    else
        echo "comprehensive"  # Default hvis ikke funnet
    fi
}

# =============================================================================
# Verifisering og Integritet
# =============================================================================

# Verifiserer backup ved å sjekke integritet og tilstedeværelse av kritiske filer
verify_backup() {
    typeset backup_dir="$1"
    typeset verified=true
    typeset checksum_file="${backup_dir}/${CHECKSUM_FILE}"
    typeset metadata_file="${backup_dir}/${METADATA_FILE}"
    typeset -i num_cores
    num_cores=$(sysctl -n hw.ncpu || echo 4)
    typeset verify_log="${LOG_DIR}/verify_${TIMESTAMP}.log"

    log "INFO" "Starter verifikasjon med $num_cores tråder"
    
    # Grunnleggende katalogsjekk
    if [[ ! -d "$backup_dir" ]]; then
        error "Backup-katalogen eksisterer ikke: ${backup_dir}"
        return 1
    fi

    # Verifiser metadata først
    if ! verify_metadata "$backup_dir"; then
        error "Metadata-verifisering feilet"
        verified=false
    fi

    # Parallell filverifisering med xargs
    {
        find "$backup_dir" -type f -not -name "${CHECKSUM_FILE##*/}" \
            -not -name "${METADATA_FILE##*/}" -print0 | \
        xargs -0 -n 1 -P "$num_cores" -I {} bash -c '
            source "'${MODULES_DIR}'/utils.sh"
            if ! verify_file_integrity "$1" basic; then
                echo "FEIL: Verifisering feilet for: $1" >&2
                exit 1
            fi
        ' _ {} 2>> "$verify_log"
    } || verified=false

    # Generer nye checksums hvis de mangler
    if [[ ! -f "$checksum_file" ]]; then
        log "INFO" "Genererer nye checksums..."
        (cd "$backup_dir" && \
         find . -type f ! -name "${CHECKSUM_FILE##*/}" ! -name "${METADATA_FILE##*/}" -print0 | \
         xargs -0 -n 1 -P "$num_cores" md5 -r > "$checksum_file")
    else
        log "INFO" "Verifiserer eksisterende checksums..."
        if ! (cd "$backup_dir" && md5 -c "$checksum_file" > "$verify_log" 2>&1); then
            error "Checksum-verifisering feilet"
            verified=false
        fi
    fi

    # Oppdater metadata
    if [[ -f "$metadata_file" ]]; then
        update_backup_metadata "$backup_dir" "last_verified" "$(date '+%Y-%m-%d %H:%M:%S')"
        update_backup_metadata "$backup_dir" "verification_status" "$verified"
    fi

    if [[ "$verified" == true ]]; then
        log "INFO" "Verifikasjon fullført uten feil"
    else
        error "Verifikasjon fullført med feil. Se $verify_log for detaljer."
    fi

    return $(( ! verified ))
}

# =============================================================================
# Komprimering og Rotasjon
# =============================================================================

# Komprimerer eldre backups for å spare diskplass
compress_old_backups() {
    local num_cores=$(sysctl -n hw.ncpu || echo 4)
    local temp_dir=$(mktemp -d)
    set_current_operation "komprimering av gamle backups"
    register_cleanup "rm -rf $temp_dir"
    trap 'rm -rf "$temp_dir"' EXIT

    log "INFO" "Starter parallell komprimering av gamle backups..."

    # Finn gamle backups som skal komprimeres
    find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup-*" -mtime +"${CONFIG_COMPRESSION_AGE}" -print0 | \
    xargs -0 -n 1 -P "$num_cores" bash -c '
        backup_dir="$1"
        temp_dir="$2"
        
        # Verifiser backup før komprimering
        if verify_backup "$backup_dir"; then
            # Bruk pigz (parallell gzip) hvis tilgjengelig
            if command -v pigz >/dev/null; then
                tar -I pigz -cf "${backup_dir}.tar.gz" -C "$(dirname "$backup_dir")" "$(basename "$backup_dir")"
            else
                tar -czf "${backup_dir}.tar.gz" -C "$(dirname "$backup_dir")" "$(basename "$backup_dir")"
            fi
            
            # Verifiser komprimert fil
            if tar -tzf "${backup_dir}.tar.gz" >/dev/null 2>&1; then
                rm -rf "$backup_dir"
                echo "${backup_dir##*/}" >> "$temp_dir/compressed.log"
            else
                echo "${backup_dir##*/}: Komprimering feilet" >> "$temp_dir/errors.log"
            fi
        else
            echo "${backup_dir##*/}: Verifisering feilet" >> "$temp_dir/errors.log"
        fi
    ' _ {} "$temp_dir"

    # Vis resultater
    local success_count=0
    local fail_count=0
    [[ -f "${temp_dir}/compressed.log" ]] && success_count=$(wc -l < "${temp_dir}/compressed.log")
    [[ -f "${temp_dir}/errors.log" ]] && fail_count=$(wc -l < "${temp_dir}/errors.log")

    log "INFO" "Komprimering fullført: $success_count OK, $fail_count feilet"
    [[ -f "${temp_dir}/errors.log" ]] && cat "${temp_dir}/errors.log" | while read -r line; do
        warn "$line"
    done
}

# Roterer gamle backups basert på alder og antall
rotate_backups() {
    local num_cores=$(sysctl -n hw.ncpu || echo 4)
    local temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    log "INFO" "Starter parallell backup-rotasjon..."

    # Slett gamle komprimerte backups parallelt
    find "${BACKUP_BASE_DIR}" -maxdepth 1 -type f -name "backup-*.tar.gz" -mtime +"${CONFIG_BACKUP_RETENTION}" -print0 | \
    xargs -0 -n 1 -P "$num_cores" rm -f

    # Tell aktive backups
    local backup_count=$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup-*" | wc -l)
    
    if (( backup_count > CONFIG_MAX_BACKUPS )); then
        local excess=$((backup_count - CONFIG_MAX_BACKUPS))
        log "INFO" "Fjerner ${excess} gamle backup(s)..."

        # Finn eldste backups og lagre i temp-fil
        find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup-*" -print0 | \
        xargs -0 stat -f "%m %N" | \
        sort -n | \
        head -n "$excess" | \
        cut -d' ' -f2- > "${temp_dir}/to_delete"

        # Slett parallelt
        xargs -n 1 -P "$num_cores" rm -rf < "${temp_dir}/to_delete"

        # Verifiser resultat
        local final_count=$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup-*" | wc -l)
        if (( final_count > CONFIG_MAX_BACKUPS )); then
            warn "Har fortsatt for mange backups (${final_count}/${CONFIG_MAX_BACKUPS})"
        else
            log "INFO" "Backup-antall redusert til ${final_count}"
        fi
    fi

    # Komprimer gamle backups parallelt
    find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup-*" -mtime +"${CONFIG_COMPRESSION_AGE}" -print0 | \
    xargs -0 -n 1 -P "$num_cores" bash -c '
        backup_dir="$1"
        if verify_backup "$backup_dir" && \
           tar -czf "${backup_dir}.tar.gz" -C "$(dirname "$backup_dir")" "$(basename "$backup_dir")" && \
           tar -tzf "${backup_dir}.tar.gz" >/dev/null 2>&1; then
            rm -rf "$backup_dir"
            echo "${backup_dir##*/}" >> "$2/compressed.log"
        else
            echo "${backup_dir##*/}" >> "$2/compress_failed.log"
        fi
    ' _ {} "$temp_dir"

    # Vis resultater
    if [[ -f "${temp_dir}/compressed.log" ]]; then
        log "INFO" "Komprimerte $(wc -l < "${temp_dir}/compressed.log") backups"
    fi
    if [[ -f "${temp_dir}/compress_failed.log" ]]; then
        warn "Komprimering feilet for $(wc -l < "${temp_dir}/compress_failed.log") backups"
    fi
}

# =============================================================================
# Opprydding og Vedlikehold
# =============================================================================

# Funksjon for å rydde opp i feilede eller ufullstendige backups

cleanup_failed_backups() {
    local num_cores=$(sysctl -n hw.ncpu || echo 4)
    local temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT

    log "INFO" "Starter parallell opprydding av problematiske backups..."

    # Finn alle backup-kataloger parallelt
    find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup-*" -print0 | \
    xargs -0 -n 1 -P "$num_cores" -I {} bash -c '
        backup_dir="$1"
        temp_dir="$2"
        problems=()
        
        # Sjekk backup-katalogen
        if [[ ! -s "$backup_dir" ]]; then
            echo "$backup_dir: Tom backup" >> "$temp_dir/problems.log"
            exit 0
        fi

        # Sjekk påkrevde filer
        for item in "system" "apps.json" "homebrew.txt"; do
            if [[ ! -e "${backup_dir}/${item}" ]]; then
                echo "$backup_dir: Mangler ${item}" >> "$temp_dir/problems.log"
            fi
        done

        # Sjekk metadata
        if [[ ! -f "${backup_dir}/backup-metadata" ]]; then
            echo "$backup_dir: Mangler metadata" >> "$temp_dir/problems.log"
        elif ! verify_metadata "$backup_dir"; then
            echo "$backup_dir: Ugyldig metadata" >> "$temp_dir/problems.log"
        fi

        # Hvis backup er eldre enn 24 timer og har problemer, merk for sletting
        if find "$backup_dir" -maxdepth 0 -mtime +1 | grep -q . && \
           grep -q "^$backup_dir:" "$temp_dir/problems.log"; then
            echo "$backup_dir" >> "$temp_dir/to_delete.log"
        fi
    ' _ {} "$temp_dir"

    # Håndter problemrapporter
    local problem_count=0
    local delete_count=0
    local keep_count=0

    if [[ -f "${temp_dir}/problems.log" ]]; then
        problem_count=$(wc -l < "${temp_dir}/problems.log")
        while IFS=: read -r backup_dir problem; do
            log "WARN" "Problem i backup ${backup_dir##*/}: ${problem}"
        done < "${temp_dir}/problems.log"
    fi

    # Slett gamle problematiske backups parallelt
    if [[ -f "${temp_dir}/to_delete.log" ]]; then
        xargs -n 1 -P "$num_cores" rm -rf < "${temp_dir}/to_delete.log"
        delete_count=$(wc -l < "${temp_dir}/to_delete.log")
    fi

    # Oppsummering
    keep_count=$((problem_count - delete_count))
    log "INFO" "Oppsummering av problematiske backups:"
    log "INFO" "- Totalt funnet: $problem_count"
    log "INFO" "- Slettet: $delete_count"
    log "INFO" "- Beholdt for feilsøking: $keep_count"
}

# Funksjon for å validere backup-integritet
validate_backup_integrity() {
    local backup_dir="$1"
    local validation_level="${2:-basic}"  # basic eller full
    typeset status=0
    
    log "INFO" "Starter integritetsvalidering av ${backup_dir} (nivå: ${validation_level})"
    
    # Grunnleggende validering
    if [[ ! -d "$backup_dir" ]]; then
        error "Backup-katalog mangler: ${backup_dir}"
        return 1
    fi
    
    # Sjekk metadata
    if ! read_backup_metadata "$backup_dir"; then
        error "Metadata-validering feilet"
        status=1
    fi
    
    # Full validering inkluderer mer omfattende sjekker
    if [[ "$validation_level" == "full" ]]; then
        # Sjekk checksums
        if [[ -f "${backup_dir}/${CHECKSUM_FILE}" ]]; then
            if ! md5sum -c "${backup_dir}/${CHECKSUM_FILE}" >/dev/null 2>&1; then
                error "Checksum-validering feilet"
                status=1
            fi
        else
            warn "Checksum-fil mangler, kan ikke validere filintegritet"
            status=1
        fi
        
        # Sjekk etter korrupte filer
        while IFS='' read -r line; do
            if ! verify_file_integrity "$file" "full"; then
                error "Filintegritetssjekk feilet for: $file"
                status=1
            fi
        done < <(find "$backup_dir" -type f ! -name "$CHECKSUM_FILE" ! -name "$METADATA_FILE")
    fi
    
    # Oppdater metadata med valideringsresultat
    if [[ "$status" -eq 0 ]]; then
        update_backup_metadata "$backup_dir" "last_validation" "$(date '+%Y-%m-%d %H:%M:%S')"
        update_backup_metadata "$backup_dir" "validation_status" "ok"
        log "INFO" "Validering fullført uten feil"
    else
        update_backup_metadata "$backup_dir" "last_validation" "$(date '+%Y-%m-%d %H:%M:%S')"
        update_backup_metadata "$backup_dir" "validation_status" "failed"
        error "Validering fullført med feil"
    fi
    
    return $status
}

# Hovedfunksjon for vedlikehold
maintain_backups() {
    log "INFO" "Starter backup-vedlikehold..."
    
    # Verifiser siste backup hvis den finnes
    if [[ -L "$LAST_BACKUP_LINK" ]]; then
        verify_backup "$(readlink "$LAST_BACKUP_LINK")"
    fi
    
    # Utfør vedlikehold
    cleanup_failed_backups
    compress_old_backups
    rotate_backups
    
    log "INFO" "Backup-vedlikehold fullført"
}