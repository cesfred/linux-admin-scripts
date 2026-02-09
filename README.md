# Skripte

## secure_erase.sh

Interactive secure-erase helper for Linux. Detects all block devices (HDD, SSD, NVMe, eMMC, USB), categorizes them, and recommends the best erase method per type.

Interaktiver Secure-Erase-Helper fuer Linux. Erkennt alle Block-Devices (HDD, SSD, NVMe, eMMC, USB), kategorisiert sie und empfiehlt das beste Loeschverfahren je Typ.

### Features
- **Device detection / Device-Erkennung**: All block devices with categorization (NVMe/SSD/HDD/eMMC/USB)
- **System disk protection / System-Disk-Schutz**: Root/boot device detected, extra warning + YES confirmation
- **Type-based recommendation / Typ-abhaengige Empfehlung**: NVMe→nvme format, SSD→ATA Secure Erase, HDD→shred, USB/eMMC→blkdiscard/dd
- **Security rating / Sicherheits-Bewertung**: Star rating, forensic recovery assessment, and explanation per method
- **Deferred ATA probe**: `hdparm -I` only runs when the method is selected, not during listing
- **LUKS detection / LUKS-Erkennung**: LUKS erase only offered when header is present (`cryptsetup isLuks`)
- **Post-erase verification / Post-Erase-Verifikation**: Samples random blocks and checks for zeros (dd/shred/blkdiscard)
- **Interactive navigation / Interaktive Navigation**: Number selection, `b` back, `q` quit
- **Pre-flight checks / Vorab-Pruefungen**: Verifies required tools and sudo privileges before starting

### Requirements / Voraussetzungen
- Linux with / mit `lsblk`, `awk`, `findmnt`, `sudo`, `blockdev`, `dd`, `od`, `sed`, `grep`
- Optional: `nvme-cli`, `hdparm`, `util-linux` (blkdiscard), `cryptsetup`

### Usage
```bash
bash secure_erase.sh
```

---

## upgrade_paperless.sh

Interactive upgrade script for Paperless-ngx (Docker Compose).

Interaktives Upgrade-Skript fuer Paperless-ngx (Docker Compose).

### Features
- Checks for new Docker images via `docker compose pull` / Prueft auf neue Docker-Images
- Version comparison (old vs. new) with semantic versioning / Versionsvergleich mit Semantic-Versioning
- Downgrade detection with extra warning / Downgrade-Erkennung mit extra Warnung
- Automatic rollback on failed start / Automatisches Rollback bei fehlgeschlagenem Start
- Optional cleanup of old images / Optionales Cleanup alter Images

