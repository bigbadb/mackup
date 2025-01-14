#!/usr/bin/env zsh

# =============================================================================
# Wizard-modul for interaktiv konfigurasjon
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Hjelpefunksjoner
# -----------------------------------------------------------------------------

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local response
    
    while true; do
        read -rp "$prompt [Y/n]: " response
        response=${response:-$default}
        case $response in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Vennligst svar 'y' eller 'n'";;
        esac
    done
}

select_from_menu() {
    local title="$1"
    shift
    local options=("$@")
    local choice
    
    echo "$title"
    echo "------------------------"
    for i in "${!options[@]}"; do
        echo "$((i+1))) ${options[$i]}"
    done
    
    while true; do
        read -rp "Velg (1-${#options[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            return "$((choice-1))"
        fi
        echo "Ugyldig valg. Prøv igjen."
    done
}

# -----------------------------------------------------------------------------
# Wizard-funksjoner
# -----------------------------------------------------------------------------

explain_backup_strategies() {
    cat << EOF

Backup-strategier:
-----------------
1. Comprehensive (Omfattende)
   - Tar backup av hele hjemmemappen
   - Bruker exclude-liste for å utelate unødvendige filer
   - Anbefales for de fleste brukere
   - God for å sikre at ingenting viktig går tapt

2. Selective (Selektiv)
   - Tar kun backup av spesifiserte mapper og filer
   - Bruker include-liste for å velge hva som skal tas backup av
   - Anbefales for avanserte brukere
   - Mer kontroll, men krever nøye planlegging

EOF
}

configure_backup_strategy() {
    local config_file="$1"
    local strategy
    
    explain_backup_strategies
    
    if prompt_yes_no "Ønsker du å bruke Comprehensive backup-strategi?"; then
        strategy="comprehensive"
    else
        strategy="selective"
    fi
    
    yq e ".backup_strategy = \"$strategy\"" -i "$config_file"
    return 0
}

configure_patterns() {
    local config_file="$1"
    local current_strategy
    current_strategy=$(yq e ".backup_strategy" "$config_file")
    
    if [[ "$current_strategy" == "comprehensive" ]]; then
        configure_comprehensive_patterns "$config_file"
    else
        configure_selective_patterns "$config_file"
    fi
}

configure_comprehensive_patterns() {
    local config_file="$1"
    local action
    
    while true; do
        echo
        echo "Comprehensive Backup Konfigurasjon"
        echo "--------------------------------"
        echo "1) Vis gjeldende exclude-mønstre"
        echo "2) Legg til exclude-mønster"
        echo "3) Fjern exclude-mønster"
        echo "4) Vis force-include mønstre"
        echo "5) Legg til force-include mønster"
        echo "6) Fjern force-include mønster"
        echo "7) Ferdig"
        
        read -rp "Velg handling (1-7): " action
        
        case $action in
            1) yq e ".comprehensive_exclude[]" "$config_file";;
            2)
                read -rp "Skriv inn nytt exclude-mønster: " pattern
                yq e ".comprehensive_exclude += [\"$pattern\"]" -i "$config_file"
                ;;
            3)
                local -a patterns
                patterns=("${(f)$(yq e '.comprehensive_exclude[]' "$config_file")}")
                select_from_menu "Velg mønster å fjerne:" "${patterns[@]}"
                local index=$?
                yq e "del(.comprehensive_exclude[$index])" -i "$config_file"
                ;;
            4) yq e ".force_include[]" "$config_file";;
            5)
                read -rp "Skriv inn nytt force-include mønster: " pattern
                yq e ".force_include += [\"$pattern\"]" -i "$config_file"
                ;;
            6)
                local patterns
                patterns=("${(f)$(yq e '.force_include[]' "$config_file")}")
                select_from_menu "Velg mønster å fjerne:" "${patterns[@]}"
                local index=$?
                yq e "del(.force_include[$index])" -i "$config_file"
                ;;
            7) break;;
            *) echo "Ugyldig valg";;
        esac
    done
}

configure_selective_patterns() {
    local config_file="$1"
    local action
    
    while true; do
        echo
        echo "Selective Backup Konfigurasjon"
        echo "-----------------------------"
        echo "1) Vis gjeldende include-mønstre"
        echo "2) Legg til include-mønster"
        echo "3) Fjern include-mønster"
        echo "4) Vis exclude-mønstre"
        echo "5) Legg til exclude-mønster"
        echo "6) Fjern exclude-mønster"
        echo "7) Ferdig"
        
        read -rp "Velg handling (1-7): " action
        
        case $action in
            1) yq e ".include[]" "$config_file";;
            2)
                read -rp "Skriv inn nytt include-mønster: " pattern
                yq e ".include += [\"$pattern\"]" -i "$config_file"
                ;;
            3)
                local patterns
                patterns=("${(f)$(yq e '.exclude[]' "$config_file")}")
                select_from_menu "Velg mønster å fjerne:" "${patterns[@]}"
                local index=$?
                yq e "del(.include[$index])" -i "$config_file"
                ;;
            4) yq e ".exclude[]" "$config_file";;
            5)
                read -rp "Skriv inn nytt exclude-mønster: " pattern
                yq e ".exclude += [\"$pattern\"]" -i "$config_file"
                ;;
            6)
                local patterns
                patterns=("${(f)$(yq e '.exclude[]' "$config_file")}")
                select_from_menu "Velg mønster å fjerne:" "${patterns[@]}"
                local index=$?
                yq e "del(.exclude[$index])" -i "$config_file"
                ;;
            7) break;;
            *) echo "Ugyldig valg";;
        esac
    done
}

# -----------------------------------------------------------------------------
# Hovedfunksjoner
# -----------------------------------------------------------------------------

run_first_time_wizard() {
    local config_file="$1"
    
    echo "Velkommen til førstegangsoppsett av backup-systemet!"
    echo "===================================================="
    echo
    
    # Konfigurer backup-strategi
    configure_backup_strategy "$config_file"
    
    # Konfigurer patterns
    if prompt_yes_no "Ønsker du å tilpasse backup-mønstre?"; then
        configure_patterns "$config_file"
    fi
    
    # Konfigurer systeminnstillinger
    echo
    echo "Systeminnstillinger"
    echo "------------------"
    
    if prompt_yes_no "Ønsker du å aktivere inkrementell backup?"; then
        yq e ".incremental = true" -i "$config_file"
    else
        yq e ".incremental = false" -i "$config_file"
    fi
    
    if prompt_yes_no "Ønsker du å verifisere backup etter fullføring?"; then
        yq e ".verify_after_backup = true" -i "$config_file"
    else
        yq e ".verify_after_backup = false" -i "$config_file"
    fi
    
    echo
    echo "Oppsett fullført! Du kan alltid kjøre wizarden igjen med --config"
}

run_config_wizard() {
    local config_file="$1"
    local action
    
    while true; do
        echo
        echo "Backup Konfigurasjon"
        echo "-------------------"
        echo "1) Endre backup-strategi"
        echo "2) Konfigurer backup-mønstre"
        echo "3) Endre systeminnstillinger"
        echo "4) Avslutt"
        
        read -rp "Velg handling (1-4): " action
        
        case $action in
            1) configure_backup_strategy "$config_file";;
            2) configure_patterns "$config_file";;
            3)
                echo "Systeminnstillinger:"
                if prompt_yes_no "Aktiver inkrementell backup?"; then
                    yq e ".incremental = true" -i "$config_file"
                else
                    yq e ".incremental = false" -i "$config_file"
                fi
                
                if prompt_yes_no "Aktiver backup-verifisering?"; then
                    yq e ".verify_after_backup = true" -i "$config_file"
                else
                    yq e ".verify_after_backup = false" -i "$config_file"
                fi
                ;;
            4) break;;
            *) echo "Ugyldig valg";;
        esac
    done
}