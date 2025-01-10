Fleskeponniens # mackup
Backup av Macintosh EDB-maskinene

# Modulært Backup-System for macOS

Et robust og konfigurerbart backup-system for macOS med støtte for inkrementelle backups, backup-rotasjon og omfattende feilhåndtering.

## Funksjoner

### Kjernefunksjonalitet
- YAML-basert konfigurasjon per maskin
- Inkrementelle backups
- Automatisk backup-rotasjon og vedlikehold
- Robust feilhåndtering med retry-logikk
- Detaljert logging med ulike loggnivåer
- Dry-run modus for testing

### Vedlikehold og Sikkerhet
- Automatisk verifisering av backups
- Komprimering av gamle backups
- Intelligent backup-rotasjon
- Opprydding av feilede backups
- Checksumverifisering
- Robust feilhåndtering ved nettverksproblemer

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
- Opprette standardkonfigurasjon hvis nødvendig

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
hosts:
  Min-Mac:
    include:
      - Documents
      - Pictures
      - .ssh
    exclude:
      - Library
      - .Trash
    incremental: true
```

## Bruk

### Grunnleggende bruk:
```bash
./backup.sh                    # Kjør backup med standardinnstillinger
./backup.sh --dry-run         # Simuler backup uten å gjøre endringer
./backup.sh --incremental     # Kjør inkrementell backup
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
- `--dry-run`: Simuler backup uten å gjøre endringer
- `--debug`: Aktiver debug-logging
- `--exclude=DIR`: Ekskluder spesifikke mapper
- `--incremental`: Utfør inkrementell backup
- `--verify`: Verifiser backup etter fullføring

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
