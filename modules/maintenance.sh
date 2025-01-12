#!/usr/bin/env bash

# =============================================================================
# Vedlikeholdsmodul for backup
# =============================================================================

source "${MODULES_DIR}/config.sh"

# Konstanter for vedlikehold
readonly MAX_BACKUPS=10  # Maksimalt antall backups å beholde
readonly COMPRESSION_AGE=7  # Antall dager før komprimering
readonly BACKUP_RETENTION=30  # Antall dager å beholde backups

# Verifiserer backup ved å sjekke integritet og tilstedeværelse av kritiske filer
verify_backup() {
    local backup_dir="$1"
    local verified=true
    local checksum_file="${backup_dir}/checksums.md5"
    
    log "INFO" "Starter verifikasjon av backup i ${backup_dir}..."
    
    # Sjekk at backup-katalogen eksisterer
    if [[ ! -d "$backup_dir" ]]; then
        error "Backup-katalogen eksisterer ikke: ${backup_dir}"
        return 1
    fi
    
    # Generer checksums hvis de ikke finnes
    if [[ ! -f "$checksum_file" ]]; then
        log "INFO" "Genererer checksums for backup..."
        find "$backup_dir" -type f ! -name "checksums.md5" -exec md5sum {} \; > "$checksum_file"
    fi
    
    # Verifiser checksums
    if ! md5sum -c "$checksum_file" > "${backup_dir}/verify_result.log" 2>&1; then
        verified=false
        warn "Noen filer feilet checksumverifisering. Se ${backup_dir}/verify_result.log"
    fi
    
    # Sjekk kritiske filer/mapper
    local required_items=("system" "apps.json" "homebrew.txt")
    for item in "${required_items[@]}"; do
        if [[ ! -e "${backup_dir}/${item}" ]]; then
            error "Kritisk element mangler: ${item}"
            verified=false
        fi
    done
    
    if [[ "$verified" == true ]]; then
        log "INFO" "Backup verifisert OK: ${backup_dir}"
        return 0
    else
        error "Backup verifikasjon feilet for ${backup_dir}"
        return 1
    fi
}

# Komprimerer eldre backups for å spare diskplass
compress_old_backups() {
    log "INFO" "Leter etter gamle backups å komprimere..."
    
    find "${BACKUP_BASE_DIR}" -maxdepth 1 -type d -name "backup-*" -mtime +"${COMPRESSION_AGE}" | while read -r backup_dir; do
        if [[ ! -f "${backup_dir}.tar.gz" ]]; then
            log "INFO" "Komprimerer ${backup_dir}..."
            if tar -czf "${backup_dir}.tar.gz" -C "$(dirname "$backup_dir")" "$(basename "$backup_dir")"; then
                log "INFO" "Vellykket komprimering av ${backup_dir}"
                rm -rf "$backup_dir"
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
        while IFS= read -r old_backup; do
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

# Funksjon for å rydde opp i feilede eller ufullstendige backups
cleanup_failed_backups() {
    log "INFO" "Leter etter problematiske backups..."
    
    # Definer påkrevde filer og mapper
    local required_items=("system" "apps.json" "homebrew.txt")
    local delete_count=0
    local problem_count=0
    local keep_count=0
    
    while IFS= read -r backup_dir; do
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