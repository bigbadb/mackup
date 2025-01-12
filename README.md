# Modulært Backup-System for macOS

Et robust og konfigurerbart backup-system for macOS med støtte for både comprehensive og selective backup-strategier, inkrementelle backups, backup-rotasjon og omfattende feilhåndtering.

## Funksjoner

### Kjernefunksjonalitet
- To backup-strategier:
  - Comprehensive: Backup av hele hjemmekatalogen med definerte unntak
  - Selective: Backup av spesifikt valgte mapper og filer
- YAML-basert konfigurasjon per maskin
- Inkrementelle backups
- Automatisk backup-rotasjon og vedlikehold
- Robust feilhåndtering med retry-logikk
- Detaljert logging med ulike loggnivåer
- Dry-run og preview modus for testing

### Vedlikehold og Sikkerhet
- Automatisk verifisering av backups
- Komprimering av gamle backups
- Intelligent backup-rotasjon
- Opprydding av feilede backups
- Checksumverifisering
- Robust feilhåndtering ved nettverksproblemer
- Force-include for kritiske filer

## Installasjon

1. Klon repositoriet
2. Kjør installasjonsskriptet:
   ```bash
   ./install.sh
   ```

Installasjonsskriptet vil:
- Sjekke og installere nødvendige avhengigheter
- Sette opp katalogstrukturen
- Installere moduler
- Guide deg gjennom valg av backup-strategi
- Opprette tilpasset konfigurasjon

## Avhengigheter

- rsync
- yq (for YAML-parsing)
- mas (for App Store backup)

## Konfigurasjon

Systemet bruker to konfigurasjonsfiler:
- `config.yaml`: Hovedkonfigurasjon
- `default-config.yaml`: Standardverdier

### Eksempel på konfigurasjon:

```yaml

# Standard backup-konfigurasjon

# Grunnleggende konfigurasjon
backup_strategy: "comprehensive"  # 'comprehensive' eller 'selective'

# System info som skal samles ved backup
system_info:
  collect: true
  include:
    - os_version
    - hardware_info
    - installed_apps
    - network_config
    - disk_usage
    - mounted_volumes

# Konfigurasjon for comprehensive backup
comprehensive_exclude:
  # Systemmapper
  - "Library/Caches"
  - "Library/Logs"
  - ".Trash"
  - ".cache"
  - ".local/share/Trash"
  
  # Utviklingsmiljø
  - "node_modules"
  - ".npm"
  - ".maven"
  - ".gradle"
  - "**/venv"
  - "**/env"
  - "**/.venv"
  - "**/build"
  - "**/dist"
  
  # Temporære filer
  - "**/*.tmp"
  - "**/*.temp"
  - "**/*.swp"
  - "**/*~"
  
  # Store applikasjonsmapper
  - "Library/Application Support/Steam"
  - "Library/Developer/Xcode/iOS DeviceSupport"
  - "Library/Developer/Xcode/DerivedData"

# Filer som alltid skal inkluderes
force_include:
  - ".ssh/**"
  - ".gitconfig"
  - ".zshrc"
  - ".bashrc"
  - ".bash_profile"
  - "Documents/viktige_dokumenter/**"

# Konfigurasjon for selective backup
include:
  - Documents
  - Downloads
  - Pictures
  - Music
  - .ssh
  - .config
  - .zshrc
  - .bashrc
  - .bash_profile
  - .gitconfig
  - .env
  - Library/Application Support/Code/User

exclude:
  - Library
  - .zsh_sessions
  - Applications
  - Desktop
  - Public

# Backup-innstillinger
incremental: false
verify_after_backup: true
compress_after_days: 7
max_backups: 10
```

## Bruk

### Grunnleggende bruk:
```bash
./backup.sh                           # Kjør backup med standardinnstillinger
./backup.sh --strategy=comprehensive  # Bruk comprehensive backup
./backup.sh --strategy=selective      # Bruk selective backup
./backup.sh --preview                # Forhåndsvis hvilke filer som vil bli kopiert
./backup.sh --dry-run                # Simuler backup uten å gjøre endringer
```

### Andre kommandoer:
```bash
./backup.sh --help            # Vis hjelpetekst
./backup.sh --list-backups    # List alle tilgjengelige backups
./backup.sh --verify          # Verifiser siste backup
./backup.sh --restore=NAVN    # Gjenopprett en spesifikk backup
./backup.sh --debug          # Kjør med detaljert debugging output
```

### Flagg:
- `--strategy=TYPE`: Velg backup-strategi (comprehensive/selective)
- `--preview`: Forhåndsvis backup uten å gjøre endringer
- `--dry-run`: Simuler backup uten å gjøre endringer
- `--debug`: Aktiver debug-logging
- `--exclude=DIR`: Ekskluder spesifikke mapper
- `--incremental`: Utfør inkrementell backup
- `--verify`: Verifiser backup etter fullføring

## Backup-strategier

### Comprehensive Backup
- Tar backup av hele hjemmekatalogen
- Bruker en definert liste med excludes
- Støtter force-include for kritiske filer
- Mer robust mot glemte filer
- Krever mer diskplass

### Selective Backup
- Tar kun backup av spesifiserte mapper
- Mer kontroll over hva som inkluderes
- Mindre diskplass
- Krever nøyere konfigurasjon

## Automatisk Vedlikehold

Systemet utfører automatisk følgende vedlikeholdsoppgaver:

### Backup Verifisering
- Sjekker integritet av alle kritiske filer
- Verifiserer checksums
- Rapporterer eventuelle mangler eller korrupsjoner

### Backup Rotasjon
- Beholder maksimalt 10 backups
- Fjerner gamle backups basert på alder og antall
- Intelligent håndtering av inkrementelle backups

### Komprimering
- Komprimerer backups eldre enn 7 dager
- Automatisk verifisering etter komprimering
- Plassbesparende arkivering

### Opprydding
- Identifiserer og håndterer feilede backups
- Fjerner ufullstendige backups eldre enn 24 timer
- Detaljert logging av alle oppryddingsoperasjoner

## Katalogstruktur

```
.
├── backup.sh           # Hovedskript
├── config.yaml         # Konfigurasjon
├── install.sh          # Installasjonsskript
├── modules/           
│   ├── apps.sh        # Backup av applikasjoner
│   ├── maintenance.sh # Vedlikehold og rotasjon
│   ├── system.sh      # Systemfiler
│   ├── user_data.sh   # Brukerdata
│   └── utils.sh       # Hjelpefunksjoner
└── backups/           # Backup-katalog
    └── logs/          # Loggfiler
```

## Logging

Systemet logger til `backups/logs/` med følgende nivåer:
- ERROR: Kritiske feil
- WARN: Advarsler
- INFO: Generell informasjon
- DEBUG: Detaljert debuginformasjon

## Testing

Systemet kommer med et omfattende testsett:
```bash
./test_maintenance.sh   # Kjør tester for vedlikeholdsmodulen
```

Testene verifiserer:
- Backup verifisering
- Komprimering av gamle backups
- Backup rotasjon
- Opprydding av feilede backups

## Feilsøking

1. Sjekk loggfilene i `backups/logs/`
2. Bruk `--debug` flagget for mer detaljert output
3. Kjør med `--dry-run` for å simulere operasjoner
4. Verifiser backup med `--verify` flagget
5. Sjekk diskplass og tilganger hvis operasjoner feiler

## Lisens

MIT License
