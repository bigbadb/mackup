#!/usr/bin/env bash

# =============================================================================
# Test Suite for Maintenance Module
# =============================================================================

set -euo pipefail

# Globale variabler for testing
readonly TEST_DIR="$(mktemp -d)"
readonly TEST_BACKUP_BASE="${TEST_DIR}/backups"
readonly TEST_LOG_DIR="${TEST_BACKUP_BASE}/logs"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Antall tester og feil
TESTS_RUN=0
TESTS_FAILED=0

# Farger for output
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

# =============================================================================
# Test Utilities
# =============================================================================

setup() {
    echo "Setting up test environment..."
    mkdir -p "${TEST_BACKUP_BASE}/logs"
    
    # Verifiser at nødvendige filer eksisterer
    local required_files=(
        "${SCRIPT_DIR}/modules/maintenance.sh"
        "${SCRIPT_DIR}/modules/utils.sh"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            echo "ERROR: Required file not found: $file"
            exit 1
        fi
    done
    
    # Sett opp testmiljøvariabler
    export BACKUP_BASE_DIR="${TEST_BACKUP_BASE}"
    export LAST_BACKUP_LINK="${TEST_BACKUP_BASE}/last_backup"
    export LOG_FILE="${TEST_LOG_DIR}/test.log"
    
    # Source nødvendige filer
    source "${SCRIPT_DIR}/modules/utils.sh"
    source "${SCRIPT_DIR}/modules/maintenance.sh"
    
    echo "Test environment ready at ${TEST_DIR}"
}

teardown() {
    echo "Cleaning up test environment..."
    rm -rf "${TEST_DIR}"
}

# Test helper funksjoner
assert() {
    local condition=$1
    local message=$2
    ((TESTS_RUN++))
    
    if eval "$condition"; then
        echo -e "${GREEN}✓${NC} $message"
    else
        echo -e "${RED}✗${NC} $message"
        ((TESTS_FAILED++))
    fi
}

create_test_backup() {
    local backup_dir=$1
    local age_days=${2:-0}
    
    mkdir -p "${backup_dir}"
    mkdir -p "${backup_dir}/system"
    echo '{"test": "data"}' > "${backup_dir}/apps.json"
    echo 'test data' > "${backup_dir}/homebrew.txt"
    
    # Sett filenes tidsstempel tilbake i tid hvis spesifisert
    if [[ $age_days -gt 0 ]]; then
        find "$backup_dir" -type f -exec touch -t $(date -v-${age_days}d +%Y%m%d0000) {} \;
        touch -t $(date -v-${age_days}d +%Y%m%d0000) "$backup_dir"
    fi
}

# =============================================================================
# Test Cases
# =============================================================================

test_verify_backup() {
    echo -e "\nTesting backup verifisering..."
    
    # Test 1: Verifiser en gyldig backup
    local valid_backup="${TEST_BACKUP_BASE}/backup-valid"
    create_test_backup "$valid_backup"
    assert "verify_backup '$valid_backup'" "Verifisering av gyldig backup"
    
    # Test 2: Verifiser en backup med manglende filer
    local invalid_backup="${TEST_BACKUP_BASE}/backup-invalid"
    mkdir -p "$invalid_backup"
    assert "! verify_backup '$invalid_backup'" "Verifisering av ugyldig backup"
    
    # Test 3: Verifiser ikke-eksisterende backup
    assert "! verify_backup '${TEST_BACKUP_BASE}/nonexistent'" "Verifisering av ikke-eksisterende backup"
}

test_compress_old_backups() {
    echo -e "\nTesting komprimering av gamle backups..."
    
    # Test 1: Komprimer backup eldre enn COMPRESSION_AGE
    local old_backup="${TEST_BACKUP_BASE}/backup-old"
    create_test_backup "$old_backup" 8  # 8 dager gammel
    compress_old_backups
    assert "[[ -f '${old_backup}.tar.gz' ]]" "Komprimering av gammel backup"
    assert "[[ ! -d '$old_backup' ]]" "Fjerning av original backup etter komprimering"
    
    # Test 2: Ikke komprimer ny backup
    local new_backup="${TEST_BACKUP_BASE}/backup-new"
    create_test_backup "$new_backup" 1  # 1 dag gammel
    compress_old_backups
    assert "[[ ! -f '${new_backup}.tar.gz' ]]" "Ny backup forblir ukomprimert"
    assert "[[ -d '$new_backup' ]]" "Ny backup beholdes intakt"
}

test_rotate_backups() {
    echo -e "\nTesting backup rotasjon..."
    
    # Opprett flere backups
    for i in {1..12}; do
        create_test_backup "${TEST_BACKUP_BASE}/backup-$i" "$i"
    done
    
    # Test rotasjon
    rotate_backups
    
    # Sjekk at vi har maksimalt MAX_BACKUPS backups
    local backup_count=$(find "${TEST_BACKUP_BASE}" -maxdepth 1 -type d -name "backup-*" | wc -l)
    assert "(( backup_count <= MAX_BACKUPS ))" "Antall backups er innenfor grensen"
    
    # Sjekk at de eldste backupene ble fjernet
    assert "[[ ! -d '${TEST_BACKUP_BASE}/backup-12' ]]" "Eldste backup ble fjernet"
    assert "[[ ! -d '${TEST_BACKUP_BASE}/backup-11' ]]" "Nest eldste backup ble fjernet"
}

test_cleanup_failed_backups() {
    echo -e "\nTesting opprydding av feilede backups..."
    
    # Test 1: Opprett en mislykket backup (eldre enn 24 timer)
    local failed_old="${TEST_BACKUP_BASE}/backup-failed-old"
    mkdir -p "$failed_old"
    touch -t $(date -v-2d +%Y%m%d0000) "$failed_old"
    
    # Test 2: Opprett en ny mislykket backup (mindre enn 24 timer)
    local failed_new="${TEST_BACKUP_BASE}/backup-failed-new"
    mkdir -p "$failed_new"
    
    cleanup_failed_backups
    
    assert "[[ ! -d '$failed_old' ]]" "Gammel mislykket backup ble fjernet"
    assert "[[ -d '$failed_new' ]]" "Ny mislykket backup ble beholdt"
}

# =============================================================================
# Main Test Runner
# =============================================================================

main() {
    echo "Starter tester for maintenance.sh..."
    
    # Setup testmiljø
    setup
    
    # Kjør tester
    test_verify_backup
    test_compress_old_backups
    test_rotate_backups
    test_cleanup_failed_backups
    
    # Cleanup
    teardown
    
    # Rapport
    echo -e "\n======================="
    echo "Test Resultater:"
    echo "Kjørte tester: $TESTS_RUN"
    echo "Feilede tester: $TESTS_FAILED"
    echo "======================="
    
    # Exit med feilkode hvis noen tester feilet
    exit $TESTS_FAILED
}

# Kjør testene
main