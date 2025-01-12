#!/usr/bin/env bash

# =============================================================================
# Utvidet Test Suite for Backup System
# =============================================================================

set -euo pipefail

# Globale variabler for testing
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MODULES_DIR="${SCRIPT_DIR}/modules"
readonly TEST_DIR="$(mktemp -d)"
readonly TEST_BACKUP_BASE="${TEST_DIR}/backups"
readonly TEST_LOG_DIR="${TEST_BACKUP_BASE}/logs"
readonly TEST_HOSTNAME="$(scutil --get LocalHostName 2>/dev/null || hostname)"

# Test statistikk
declare -i TESTS_RUN=0
declare -i TESTS_FAILED=0
declare -i TESTS_SKIPPED=0

# Farger for output
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# =============================================================================
# Test Utilities
# =============================================================================

setup() {
    echo "Setter opp testmiljø..."
    mkdir -p "${TEST_BACKUP_BASE}/logs"
    
    # Sørg for at vi har et rent testmiljø
    rm -f "${TEST_DIR}"/*.yaml
    
    # Verifiser at nødvendige filer eksisterer
    local required_files=(
        "${MODULES_DIR}/maintenance.sh"
        "${MODULES_DIR}/utils.sh"
        "${MODULES_DIR}/config.sh"
    )
    
    local missing_files=0
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            echo "ERROR: Påkrevd fil mangler: $file"
            missing_files=$((missing_files + 1))
        fi
    done

    if ((missing_files > 0)); then
        echo "Fant $missing_files manglende filer. Avslutter."
        exit 1
    fi
    
    # Sett opp testmiljøvariabler
    export BACKUP_BASE_DIR="${TEST_BACKUP_BASE}"
    export LAST_BACKUP_LINK="${TEST_BACKUP_BASE}/last_backup"
    export LOG_FILE="${TEST_LOG_DIR}/test.log"
    export DEBUG=false
    export YAML_FILE="${TEST_DIR}/config.yaml"
    export DEFAULT_CONFIG="${TEST_DIR}/default-config.yaml"
    
    # Source nødvendige filer
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/modules/utils.sh"
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/modules/maintenance.sh"
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/modules/config.sh"
    
    echo "Testmiljø klart i ${TEST_DIR}"
}

teardown() {
    echo "Rydder opp testmiljø..."
    rm -rf "${TEST_DIR}"
}

# Forbedrede test helper funksjoner
assert() {
    local condition="$1"
    local message="$2"
    local skip="${3:-false}"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
if [[ "$skip" == "true" ]]; then
    echo -e "${YELLOW}⚠${NC} $message (SKIPPED)"
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    return 2 
fi
    
    if eval "$condition"; then
        echo -e "${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Opprett test backup med spesifiserte egenskaper
create_test_backup() {
    local backup_dir="$1"
    local age_days="${2:-0}"
    local incomplete="${3:-false}"
    
    mkdir -p "${backup_dir}"
    
    if [[ "$incomplete" == "false" ]]; then
        mkdir -p "${backup_dir}/system"
        echo '{"test": "data"}' > "${backup_dir}/apps.json"
        echo 'test data' > "${backup_dir}/homebrew.txt"
        
        # Legg til systeminfo
        mkdir -p "${backup_dir}/system_info"
        echo "Test System Info" > "${backup_dir}/system_info/system.txt"
    fi
    
    # Sett filenes tidsstempel tilbake i tid hvis spesifisert
    if ((age_days > 0)); then
        find "$backup_dir" -type f -exec touch -t "$(date -v-"${age_days}"d +%Y%m%d0000)" {} \;
        touch -t "$(date -v-"${age_days}"d +%Y%m%d0000)" "$backup_dir"
    fi
}

# Opprett test konfigurasjonsfil
create_test_config() {
    local config_file="$1"
    local strategy="${2:-comprehensive}"
    
    cat > "$config_file" << EOF
hosts:
  $(hostname):
    backup_strategy: $strategy
    system_info:
      collect: true
      include:
        - os_version
        - hardware_info
    comprehensive_exclude:
      - "Library/Caches"
      - ".Trash"
    force_include:
      - ".ssh/**"
    include:
      - Documents
      - Pictures
    exclude:
      - Library
    incremental: false
    verify_after_backup: true
EOF
}

# =============================================================================
# Test Cases
# =============================================================================

test_config_handling() {
    echo -e "\nTester konfigurasjonshåndtering..."
    
    # Test 1: Last gyldig konfigurasjon med full struktur
    local test_config="${TEST_DIR}/test_config.yaml"
    cat > "$test_config" << EOF
hosts:
  ${TEST_HOSTNAME}:
    backup_strategy: comprehensive
    system_info:
      collect: true
      include:
        - os_version
        - hardware_info
    comprehensive_exclude:
      - "Library/Caches"
      - ".Trash"
    force_include:
      - ".ssh/**"
    include:
      - Documents
      - Pictures
    exclude:
      - Library
    incremental: false
    verify_after_backup: true
EOF
    
    debug "Tester konfigurasjon for host: ${TEST_HOSTNAME}"
    assert "load_config '$test_config' '${TEST_HOSTNAME}'" \
        "Lasting av gyldig konfigurasjon"
    
    # Test 2: Valider at korrekt strategi ble lastet
    assert "[[ '$CONFIG_STRATEGY' == 'comprehensive' ]]" \
        "Korrekt backup-strategi ble lastet"
    
    # Test 3: Sjekk at arrays ble lastet
    assert "[[ \${#CONFIG_EXCLUDES[@]} -gt 0 ]]" \
        "Config excludes ble lastet"
    
    # Test 4: Test selective strategi
    cat > "$test_config" << EOF
hosts:
  ${TEST_HOSTNAME}:
    backup_strategy: selective
    system_info:
      collect: true
      include:
        - os_version
    include:
      - Documents
      - Pictures
    exclude:
      - Library
    incremental: false
    verify_after_backup: true
EOF
    
    assert "load_config '$test_config' '${TEST_HOSTNAME}'" \
        "Lasting av selective konfigurasjon"
    
    # Test 5: Håndtering av ugyldig konfigurasjon
    echo "# Tester håndtering av ugyldig konfigurasjon..."
    echo "invalid: yaml: format" > "$test_config"
    assert "! load_config '$test_config' '${TEST_HOSTNAME}'" \
        "Avvisning av ugyldig konfigurasjon"
    
    # Test 6: Manglende konfigurasjonsfil
    assert "! load_config '/nonexistent/config.yaml' '${TEST_HOSTNAME}'" \
        "Håndtering av manglende konfigurasjonsfil"
    
    # Test 7: Ugyldig strategi
    cat > "$test_config" << EOF
hosts:
  ${TEST_HOSTNAME}:
    backup_strategy: invalid_strategy
    system_info:
      collect: true
EOF
    
    assert "! load_config '$test_config' '${TEST_HOSTNAME}'" \
        "Avvisning av ugyldig backup-strategi"
}

test_verify_backup() {
    echo -e "\nTester backup verifisering..."
    
    # Test 1: Verifiser en gyldig backup
    local valid_backup="${TEST_BACKUP_BASE}/backup-valid"
    create_test_backup "$valid_backup"
    assert "verify_backup '$valid_backup'" \
        "Verifisering av gyldig backup"
    
    # Test 2: Verifiser en ufullstendig backup
    local incomplete_backup="${TEST_BACKUP_BASE}/backup-incomplete"
    create_test_backup "$incomplete_backup" 0 true
    assert "! verify_backup '$incomplete_backup'" \
        "Verifisering av ufullstendig backup"
    
    # Test 3: Verifiser ikke-eksisterende backup
    assert "! verify_backup '${TEST_BACKUP_BASE}/nonexistent'" \
        "Verifisering av ikke-eksisterende backup"
}

test_compress_old_backups() {
    echo -e "\nTester komprimering av gamle backups..."
    
    # Test 1: Komprimer backup eldre enn COMPRESSION_AGE
    local old_backup="${TEST_BACKUP_BASE}/backup-old"
    create_test_backup "$old_backup" 8
    compress_old_backups
    assert "[[ -f '${old_backup}.tar.gz' ]]" \
        "Komprimering av gammel backup"
    assert "[[ ! -d '$old_backup' ]]" \
        "Fjerning av original backup etter komprimering"
    
    # Test 2: Ikke komprimer ny backup
    local new_backup="${TEST_BACKUP_BASE}/backup-new"
    create_test_backup "$new_backup" 1
    compress_old_backups
    assert "[[ ! -f '${new_backup}.tar.gz' ]]" \
        "Ny backup forblir ukomprimert"
    assert "[[ -d '$new_backup' ]]" \
        "Ny backup beholdes intakt"
}

test_rotate_backups() {
    echo -e "\nTester backup rotasjon..."
    
    # Opprett flere backups
    for i in {1..12}; do
        create_test_backup "${TEST_BACKUP_BASE}/backup-$i" "$i"
    done
    
    # Test rotasjon
    rotate_backups
    
    # Sjekk at vi har maksimalt MAX_BACKUPS backups
    local backup_count
    backup_count=$(find "${TEST_BACKUP_BASE}" -maxdepth 1 -type d -name "backup-*" | wc -l)
    assert "(( backup_count <= MAX_BACKUPS ))" \
        "Antall backups er innenfor grensen"
    
    # Sjekk at de eldste backupene ble fjernet
    assert "[[ ! -d '${TEST_BACKUP_BASE}/backup-12' ]]" \
        "Eldste backup ble fjernet"
    assert "[[ ! -d '${TEST_BACKUP_BASE}/backup-11' ]]" \
        "Nest eldste backup ble fjernet"
}

test_cleanup_failed_backups() {
    echo -e "\nTester opprydding av feilede backups..."
    
    # Test 1: Opprett en mislykket backup (eldre enn 24 timer)
    local failed_old="${TEST_BACKUP_BASE}/backup-failed-old"
    mkdir -p "$failed_old"
    touch -t "$(date -v-2d +%Y%m%d0000)" "$failed_old"
    
    # Test 2: Opprett en ny mislykket backup (mindre enn 24 timer)
    local failed_new="${TEST_BACKUP_BASE}/backup-failed-new"
    mkdir -p "$failed_new"
    
    cleanup_failed_backups
    
    assert "[[ ! -d '$failed_old' ]]" \
        "Gammel mislykket backup ble fjernet"
    assert "[[ -d '$failed_new' ]]" \
        "Ny mislykket backup ble beholdt"
}

test_system_info() {
    echo -e "\nTester systeminfo-innsamling..."
    
    local test_backup="${TEST_BACKUP_BASE}/backup-sysinfo"
    create_test_backup "$test_backup"
    
    # Test systeminfo-innsamling
    collect_system_info "${test_backup}/system_info"
    
    assert "[[ -f '${test_backup}/system_info/system_basic.txt' ]]" \
        "Grunnleggende systeminfo ble samlet"
    
    # Test at hardware_info ble samlet når konfigurert
    if [[ " ${CONFIG_SYSINFO_TYPES[*]} " =~ " hardware_info " ]]; then
        assert "[[ -f '${test_backup}/system_info/hardware_info.txt' ]]" \
            "Hardware info ble samlet"
    fi
}

# =============================================================================
# Main Test Runner
# =============================================================================

main() {
    echo "Starter utvidet testsuite..."
    
    # Setup testmiljø
    setup
    
    # Kjør tester
    test_config_handling
    test_verify_backup
    test_compress_old_backups
    test_rotate_backups
    test_cleanup_failed_backups
    test_system_info
    
    # Cleanup
    teardown
    
    # Rapport
    echo -e "\n======================="
    echo "Test Resultater:"
    echo "Kjørte tester: $TESTS_RUN"
    echo "Vellykkede: $((TESTS_RUN - TESTS_FAILED - TESTS_SKIPPED))"
    echo "Feilede: $TESTS_FAILED"
    echo "Skipped: $TESTS_SKIPPED"
    echo "======================="
    
    # Exit med feilkode hvis noen tester feilet
    exit "$TESTS_FAILED"
}

# Kjør testene hvis skriptet kjøres direkte
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi