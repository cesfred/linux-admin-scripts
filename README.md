# Skripte

## secure_erase.sh

Interactive secure-erase helper for Linux. Detects all block devices (HDD, SSD, NVMe, eMMC, USB), categorizes them, and recommends the best erase method per type.

Interaktiver Secure-Erase-Helper fuer Linux. Erkennt alle Block-Devices (HDD, SSD, NVMe, eMMC, USB), kategorisiert sie und empfiehlt das beste Loeschverfahren je Typ.

### Modi / Modes

**[1] List Devices** – alle erkannten Disks und Partitionen anzeigen
**[2] Secure Erase** – gesamte Disk unwiederbringlich loeschen
**[3] Wipe Free Space** – nur freie Bloecke einer Partition bereinigen (Dateien bleiben erhalten)

### Features – Secure Erase
- **Device detection**: Alle Block-Devices mit Kategorisierung (NVMe/SSD/HDD/eMMC/USB), inkl. Modell/Serial
- **System disk protection**: Root/Boot-Device erkannt, extra Warnung + YES-Bestaetigung
- **Type-based recommendation**: NVMe→nvme format --ses=1 (dazu --ses=2 Crypto Erase und nvme sanitize), SSD→ATA Secure Erase, HDD→shred, USB/eMMC→blkdiscard/dd
- **ATA-Passwort-Recovery**: Schlaegt der Erase nach gesetztem Passwort fehl, wird `--security-disable` automatisch versucht (Disk bleibt sonst gesperrt)
- **Audit-Log**: START/DONE/FAIL mit Geraet, Modell, Seriennummer, Methode → `~/secure_erase_audit.log`
- **badblocks fallback**: Bei defekten Disks `badblocks -wsv` als zusaetzliche Methode (ueberspringt bad sectors, bricht nicht ab)
- **Security rating**: Sterne-Bewertung, Forensik-Einschaetzung und Erklaerung pro Methode
- **Deferred ATA probe**: `hdparm -I` laeuft erst bei Methodenauswahl (`__DEFERRED_ATA__` Platzhalter)
- **LUKS detection**: LUKS-Erase nur angeboten wenn Header vorhanden (`cryptsetup isLuks`)
- **Post-erase verification**: Stichproben zufaelliger Bloecke auf Nullen (dd/shred/blkdiscard)
- **Rescan**: `d` in der Device-Liste loeest erneuten Scan aus (z.B. nach Hot-Plug)

### Features – Wipe Free Space
- **Partition listing**: Alle Partitionen mit FS, Typ (SSD/HDD/NVMe…), Status (mounted/unmounted), `[SYSTEM]`-Marker
- **System partition protection**: Erkennung ueber Mountpoint (`/`, `/boot`, `/usr`…) und Parent-Disk; YES-Bestaetigung erforderlich
- **Methoden nach Typ und Zustand**:
  - Gemountet, NVMe/SSD: `fstrim` [RECOMMENDED] → dd → sfill
  - Gemountet, HDD: dd [RECOMMENDED] → sfill
  - Gemountet, ext2/3/4: zusaetzlich `zerofree` (remount ro → zerofree → remount rw)
  - Gemountet, NTFS: Hinweis auf MFT-Luecke + Option "Unmount & rescan fuer ntfswipe"
  - Ungemountet, ext2/3/4: `zerofree` [RECOMMENDED] + Mount-Option
  - Ungemountet, NTFS: `ntfswipe -a` [RECOMMENDED] (MFT + Cluster + Slack + Log) + Mount-Option
  - Ungemountet, LUKS: Unlock (cryptsetup open + mount) → Rescan
  - Ungemountet, BitLocker: Unlock via `dislocker -u` (Passwort-Prompt) → Rescan
  - Ungemountet, sonstige FS: Mount → Rescan
  - APFS/HFS+/HFSX: keine Methode, nur Hinweis auf macOS `diskutil secureErase freespace` (Linux-rw-Zugriff unzuverlaessig/riskant)
- **Mount/Unlock-Flow**: Script-geoeffnete Volumes werden getrackt; am Ende Cleanup-Angebot (umount + cryptsetup close)
- **EXIT-Trap**: Cleanup laeuft auch bei Abbruch (Ctrl+C)
- **sfill-Hinweis**: Wenn nicht installiert: `sudo apt install secure-delete`

### Requirements / Voraussetzungen
- Linux mit `lsblk`, `awk`, `findmnt`, `sudo`, `blockdev`, `dd`, `od`, `sed`, `grep`
- Optional Secure Erase: `nvme-cli`, `hdparm`, `util-linux` (blkdiscard), `cryptsetup`, `badblocks` (e2fsprogs)
- Optional Wipe Free Space: `fstrim`, `sfill` (secure-delete), `zerofree`, `ntfswipe` (ntfs-3g), `dislocker`

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

