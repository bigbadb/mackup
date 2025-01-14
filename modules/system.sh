#!/usr/bin/env zsh
. "${MODULES_DIR}/config.sh"
# =============================================================================
# Modul for backup av systemfiler
# =============================================================================

backup_system() {
    local backup_dir="$1"
    log "INFO" "Starter backup av systemfiler..."

    # Initialiser system_files array
    local system_files=()
    
    # Last system files fra YAML eller bruk defaults
    if [[ -f "$YAML_FILE" ]]; then
        # macOS-kompatibel versjon av array-populering
        while IFS='' read -r file; do
            [[ -n "$file" ]] && system_files+=("$file")
        done < <(yq e ".hosts.$HOSTNAME.system_files[]" "$YAML_FILE" 2>/dev/null || echo "")
    fi
    
    # Hvis ingen konfigurasjon funnet, bruk standardverdier
    if [[ ${#system_files[@]} -eq 0 ]]; then
        system_files=(".zshrc" ".bashrc" ".gitconfig")
        debug "Bruker standard systemfiler: ${system_files[*]}"
    fi

    for file in "${system_files[@]}"; do
        local source_file="${HOME}/${file}"
        local target_file="${backup_dir}/system/${file}"

        if [[ -f "$source_file" ]]; then
            debug "Backup av ${source_file} til ${target_file}"
            mkdir -p "$(dirname "$target_file")"
            if cp "$source_file" "$target_file"; then
                log "INFO" "Vellykket backup av ${file}"
            else
                warn "Kunne ikke kopiere ${file}"
            fi
        else
            debug "Hopper over ${file}: ikke funnet"
        fi
    done

    log "INFO" "Backup av systemfiler fullført"
    return 0
}