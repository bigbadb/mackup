#!/usr/bin/env zsh
. "${MODULES_DIR}/config.sh"
# =============================================================================
# Modul for backup av systemfiler
# =============================================================================

# I system.sh

backup_system() {
    local backup_dir="$1"
    local num_cores=$(sysctl -n hw.ncpu || echo 4)
    local temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT
    
    log "INFO" "Starter parallell backup av systemfiler..."

    # Les systemfiler fra YAML eller bruk defaults
    local -a system_files
    if [[ -f "$YAML_FILE" ]]; then
        while IFS='' read -r file; do
            [[ -n "$file" ]] && system_files+=("$file")
        done < <(yq e ".hosts.$HOSTNAME.system_files[]" "$YAML_FILE" 2>/dev/null || echo "")
    fi

    # Bruk standardverdier hvis ingen konfigurasjon
    if [[ ${#system_files[@]} -eq 0 ]]; then
        system_files=(".zshrc" ".bashrc" ".gitconfig")
    fi

    # Parallell kopiering av systemfiler med xargs
    printf "%s\n" "${system_files[@]}" | \
    xargs -n 1 -P "$num_cores" -I {} bash -c '
        source="${HOME}/$1"
        target="${2}/system/${1}"
        if [[ -f "$source" ]]; then
            mkdir -p "$(dirname "$target")"
            if cp "$source" "$target"; then
                echo "OK: $1" >> "$3/success.log"
            else
                echo "FEIL: Kunne ikke kopiere $1" >> "$3/errors.log"
            fi
        fi
    ' _ {} "$backup_dir" "$temp_dir"

    # Vis resultater
    if [[ -f "${temp_dir}/errors.log" ]]; then
        warn "Noen filer feilet:"
        cat "${temp_dir}/errors.log"
    fi

    if [[ -f "${temp_dir}/success.log" ]]; then
        log "INFO" "Vellykket backup av $(wc -l < "${temp_dir}/success.log") filer"
    fi

    return 0
}