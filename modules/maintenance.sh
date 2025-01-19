#!/usr/bin/env zsh

# =============================================================================
# Vedlikeholdsmodul for backup-system
# =============================================================================

source "${MODULES_DIR}/config.sh"

# Konstanter for vedlikehold
readonly MAX_BACKUPS="${CONFIG_MAX_BACKUPS:-10}"  # Maksimalt antall backups å beholde
readonly COMPRESSION_AGE="${CONFIG_COMPRESSION_AGE:-7}"  # Antall dager før komprimering
readonly BACKUP_RETENTION="${CONFIG_BACKUP_RETENTION:-30}"  # Antall dager å beholde backups
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
    local backup_dir="$1"
    local metadata_file="${backup_dir}/${METADATA_FILE}"

    if [[ ! -r "$metadata_file" ]]; then
        error "Kan ikke lese metadata-fil: $metadata_file"
        return 1
    fi
    
    # Sjekk metadata-versjon
    local version
    version=$(grep '^backup_version=' "$metadata_file" | cut -d= -f2)
    if [[ -z "$version" ]]; then
        warn "Ingen versjonsinformasjon funnet i metadata"
        return 1
    fi
    
    # Parse og returner metadata som et assosiativt array
    typeset -A metadata
    while IFS='=' IFS='' read -r key value; do
        # Ignorer kommentarer og tomme linjer
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        
        # Fjern whitespace og lagre i array
        key=$(echo "$key" | tr -d '[:space:]')
        metadata["$key"]="$value"
    done < "$metadata_file"
    
    # Eksporter metadata til miljøvariabler
    for key in "${!metadata[@]}"; do
        export "BACKUP_${key^^}"="${metadata[$key]}"
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
    local backup_dir="$1"
    local verified=true
    local checksum_file="${backup_dir}/${CHECKSUM_FILE:-checksums.md5}"

    log "INFO" "Starter verifikasjon av backup i ${backup_dir}..."

    # Sjekk at backup-katalogen eksisterer
    if [[ ! -d "$backup_dir" ]]; then
        error "Backup-katalogen eksisterer ikke: ${backup_dir}"
        return 1
    fi

    # Verifiser integritet av hver fil
    find "$backup_dir" -type f ! -name "$CHECKSUM_FILE" ! -name "$METADATA_FILE" | while IFS='' read -r filename; do
        if ! verify_file_integrity "$filename" "full"; then
            warn "Integritetssjekk feilet for: $filename"
            verified=false
        fi
    done
    
    # Generer checksums hvis de ikke finnes
    if [[ ! -f "$checksum_file" ]]; then
        log "INFO" "Genererer checksums for backup..."
        find "$backup_dir" -type f ! -name "$CHECKSUM_FILE" ! -name "$METADATA_FILE" -exec md5sum {} \; > "$checksum_file"
    fi
    
    # Verifiser checksums
    if ! (cd "$backup_dir" && md5sum -c "$checksum_file" > "${backup_dir}/verify_result.log" 2>&1); then
        verified=false
        warn "Noen filer feilet checksumverifisering. Se ${backup_dir}/verify_result.log"
    fi
    
    # Sjekk kritiske filer/mapper
    local -a required_items=("system" "apps.json" "homebrew.txt")
    for item in "${required_items[@]}"; do
        if [[ ! -e "${backup_dir}/${item}" ]]; then
            error "Kritisk element mangler: ${item}"
            verified=false
        fi
    done
    
    # Oppdater metadata med verifikasjonsresultat
    if [[ -f "${backup_dir}/${METADATA_FILE}" ]]; then
        update_backup_metadata "$backup_dir" "last_verified" "$(date '+%Y-%m-%d %H:%M:%S')"
        update_backup_metadata "$backup_dir" "verification_status" "$verified"
    fi
    
    if [[ "$verified" == true ]]; then
        log "INFO" "Backup verifisert OK: ${backup_dir}"
        return 0
    else
        error "Backup verifikasjon feilet for ${backup_dir}"
        return 1
    fi
}

# =============================================================================
# Komprimering og Rotasjon
# =============================================================================

# Komprimerer eldre backups for å spare diskplass
compress_old_backups() {
    log "INFO" "Leter etter gamle backups å komprimere..."
    
    find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup-*" -mtime +"${COMPRESSION_AGE}" | while read -r backup_dir; do
        if [[ ! -f "${backup_dir}.tar.gz" ]]; then
            log "INFO" "Komprimerer ${backup_dir}..."
            
            # Les metadata før komprimering
            if ! read_backup_metadata "$backup_dir"; then
                warn "Kunne ikke lese metadata før komprimering av ${backup_dir}"
            fi
            
            if tar -czf "${backup_dir}.tar.gz" -C "$(dirname "$backup_dir")" "$(basename "$backup_dir")"; then
                log "INFO" "Vellykket komprimering av ${backup_dir}"
                
                # Verifiser komprimert fil
                if tar -tzf "${backup_dir}.tar.gz" >/dev/null 2>&1; then
                    rm -rf "$backup_dir"
                    log "INFO" "Slettet original backup etter vellykket komprimering"
                else
                    error "Verifisering av komprimert backup feilet: ${backup_dir}.tar.gz"
                    rm -f "${backup_dir}.tar.gz"
                fi
            else
                error "Komprimering feilet for ${backup_dir}"
            fi
        fi
    done
}

# Roterer gamle backups basert på alder og antall
rotate_backups() {
    log "INFO" "Starter backup-rotasjon..."
    
    # Slett gamle komprimerte backups først
    find "${BACKUP_BASE_DIR}" -maxdepth 1 -type f -name "backup-*.tar.gz" -mtime +"${BACKUP_RETENTION}" -delete
    
    # Funksjon for å telle aktive backups
    count_active_backups() {
        find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup-*" | wc -l
    }

    # Funksjon for å finne de N eldste backups
    get_oldest_backups() {
        local count=$1
        find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup-*" | while read -r backup; do
            echo "$(stat -f "%m" "$backup") $backup"
        done | sort -n | head -n "$count" | cut -d' ' -f2-
    }
    
    # Tell aktive backups
    local backup_count
    backup_count=$(count_active_backups)
    
    if (( backup_count > MAX_BACKUPS )); then
        local excess=$((backup_count - MAX_BACKUPS))
        log "INFO" "For mange backups (${backup_count}/${MAX_BACKUPS}), skal fjerne ${excess} backup(s)..."
        
        # Hent liste over de eldste backupene vi skal fjerne
        while IFS='' read -r backup; do
            if [[ -d "$old_backup" ]]; then
                log "INFO" "Sletter gammel backup: ${old_backup}"
                if rm -rf "$old_backup"; then
                    local new_count
                    new_count=$(count_active_backups)
                    log "INFO" "Antall gjenværende backups: ${new_count}"
                else
                    error "Kunne ikke slette backup: ${old_backup}"
                fi
            fi
        done < <(get_oldest_backups "$excess")
        
# Verifiser at vi nå er under grensen
        local final_count
        final_count=$(count_active_backups)
        if (( final_count > MAX_BACKUPS )); then
            warn "Har fortsatt for mange backups (${final_count}/${MAX_BACKUPS})"
        else
            log "INFO" "Backup-antall er nå innenfor grensen (${final_count}/${MAX_BACKUPS})"
        fi
    else
        log "INFO" "Antall backups (${backup_count}) er innenfor grensen på ${MAX_BACKUPS}"
    fi
}

# =============================================================================
# Opprydding og Vedlikehold
# =============================================================================

# Funksjon for å rydde opp i feilede eller ufullstendige backups
cleanup_failed_backups() {
    log "INFO" "Leter etter problematiske backups..."
    
    # Definer påkrevde filer og mapper
   typeset -a required_items=("system" "apps.json" "homebrew.txt")
    local delete_count=0
    local problem_count=0
    local keep_count=0
    
    while IFS='' read -r backup_dir; do
        local problems=()
        local is_empty=true
        local missing_files=()
        
        # Sjekk om backup-katalogen er tom
        if [[ -n "$(ls -A "$backup_dir" 2>/dev/null)" ]]; then
            is_empty=false
            
            # Sjekk etter manglende påkrevde filer
            for item in "${required_items[@]}"; do
                if [[ ! -e "${backup_dir}/${item}" ]]; then
                    missing_files+=("$item")
                fi
            done

            # Sjekk metadata-integritet
            if [[ -f "${backup_dir}/${METADATA_FILE}" ]]; then
                if ! read_backup_metadata "$backup_dir"; then
                    problems+=("Ugyldig metadata")
                fi
            else
                problems+=("Mangler metadata")
            fi
        fi
        
        # Kategoriser problemer
        if [[ "$is_empty" == true ]]; then
            problems+=("Tom backup-katalog")
        elif [[ ${#missing_files[@]} -gt 0 ]]; then
            problems+=("Mangler filer: ${missing_files[*]}")
        fi
        
        # Hvis vi fant problemer, sjekk alder og logg
        if [[ ${#problems[@]} -gt 0 ]]; then
            ((problem_count++))
            local backup_name
            backup_name=$(basename "$backup_dir")
            
            if find "$backup_dir" -maxdepth 0 -mtime +1 | grep -q .; then
                log "WARN" "Fant problematisk backup ($backup_name):"
                for problem in "${problems[@]}"; do
                    log "INFO" "      - $problem"
                done
                log "INFO" "Sletter backup eldre enn 24 timer: $backup_name"
                rm -rf "$backup_dir"
                ((delete_count++))
            else
                log "INFO" "Fant ny problematisk backup ($backup_name):"
                for problem in "${problems[@]}"; do
                    log "INFO" "      - $problem"
                done
                log "INFO" "Beholder ny backup for feilsøking"
                ((keep_count++))
            fi
        fi
    done < <(find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup-*")
    
    # Oppsummering
    if [[ $problem_count -eq 0 ]]; then
        log "INFO" "Ingen problematiske backups funnet"
    else
        log "INFO" "Oppsummering av problematiske backups:"
        log "INFO" "- Totalt funnet: $problem_count"
        log "INFO" "- Slettet: $delete_count"
        log "INFO" "- Beholdt for feilsøking: $keep_count"
    fi
}

# Funksjon for å validere backup-integritet
validate_backup_integrity() {
    local backup_dir="$1"
    local validation_level="${2:-basic}"  # basic eller full
    local status=0
    
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