#!/usr/bin/env bash
# secure-erase.sh
#
# Interactive secure-erase helper for Linux:
#  - Lists ALL block devices (HDD, SSD, NVMe, eMMC, USB flash)
#  - Categorizes each device and suggests the best erase method
#  - Shows structured security ratings per method
#  - Protects against accidentally erasing the system disk
#  - Optionally verifies erasure afterwards
#
# Usage:
#   bash secure_erase.sh
#
# Optional deps: nvme-cli, hdparm, util-linux (blkdiscard), cryptsetup

set -Eeuo pipefail

# ---------- UI printing goes to STDERR so command substitutions don't swallow it ----------
ui()       { printf "%s\n" "$*" >&2; }
uiprintf() { printf "$@" >&2; }

# ---------- Colors (only if STDERR is a TTY) ----------
if [[ -t 2 ]]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; CYA=$'\e[36m'; RST=$'\e[0m'
else
  BOLD=""; DIM=""; RED=""; YEL=""; GRN=""; CYA=""; RST=""
fi

die()     { ui "${RED}Error:${RST} $*"; exit 1; }
need()    { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Recursively send a signal to a PID and all its descendants.
# Needed because `bash -c "sudo cmd"` puts cmd two levels deep; killing the
# wrapping bash alone leaves sudo/cmd orphaned. Also: some tools (sfill)
# ignore SIGINT but honor SIGTERM.
kill_tree() {
  local pid="$1" sig="${2:-TERM}"
  local kids="" k
  if command -v pgrep >/dev/null 2>&1; then
    kids=$(pgrep -P "$pid" 2>/dev/null || true)
  elif command -v ps >/dev/null 2>&1; then
    kids=$(ps -o pid= --ppid "$pid" 2>/dev/null || true)
  fi
  for k in $kids; do kill_tree "$k" "$sig"; done
  kill -"$sig" "$pid" 2>/dev/null || true
}

# Remove leftover temp files from a cancelled free-space wipe.
# sfill normally cleans up on SIGTERM, but if SIGKILL was needed (or sfill
# crashed) its multi-pass scratch file stays behind in the mountpoint.
post_cancel_cleanup() {
  local mid="$1" mp="$2"
  [[ -n "$mp" ]] || return 0
  case "$mid" in
    sfill)
      ui ""
      ui "${YEL}Cleaning up sfill scratch files in $mp ...${RST}"
      local f
      for f in oooooooo.ooo 00000000.000 nnnnnnnn.nnn iiiiiiii.iii ffffffff.fff; do
        sudo rm -f "$mp/$f" 2>/dev/null || true
      done
      ui "${DIM}If other temp files remain (e.g. random names), check '$mp' manually.${RST}"
      ;;
    dd_freespace)
      ui ""
      ui "${YEL}Cleaning up dd temp file in $mp ...${RST}"
      sudo rm -f "$mp/.wipe_free.tmp" 2>/dev/null || true
      ;;
  esac
}

# Required tools
need lsblk
need awk
need findmnt
need sudo
need blockdev
need dd
need od
need sed
need grep

# sudo check (only relevant for non-root users)
if ((EUID != 0)); then
  if ! sudo -v 2>/dev/null; then
    die "No sudo privileges or wrong password."
  fi
fi

devpath() { echo "/dev/$1"; }

# Extract KEY="VALUE" from lsblk -P line (no eval)
kv() {
  local line="$1" key="$2"
  [[ "$line" =~ $key=\"([^\"]*)\" ]] && printf '%s' "${BASH_REMATCH[1]}"
}

# ---------- Device helpers ----------
supports_discard() {
  local dev="$1" sys="/sys/block/$dev/queue/discard_max_bytes"
  [[ -r "$sys" ]] || return 1
  local v; v="$(<"$sys")"
  [[ "${v:-0}" -gt 0 ]]
}

is_nvme() { [[ "$1" == nvme* ]]; }

# Walk up the block-device tree to the top-level disk.
# Needed because lsblk only reports TRAN on the disk row, so partitions and
# nested devices (e.g. bitlk-* on sdc2 on sdc) must look up the parent disk
# to be categorized correctly (USB vs HDD/SSD).
top_level_disk() {
  local cur="$1" parent
  while true; do
    parent="$(lsblk -no PKNAME "/dev/$cur" 2>/dev/null | awk 'NF{print; exit}')"
    [[ -z "$parent" || "$parent" == "$cur" ]] && break
    cur="$parent"
  done
  printf '%s\n' "$cur"
}

device_has_mounts() {
  local dev="$1"
  lsblk -nr -o MOUNTPOINT "$(devpath "$dev")" 2>/dev/null | awk 'NF{exit 0} END{exit 1}'
}

print_device_mounts() {
  local dev="$1"
  ui "${BOLD}Block tree / mounts under $(devpath "$dev"):${RST}"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$(devpath "$dev")" >&2 || true
}

unmount_device_tree() {
  local dev="$1"
  local targets=()

  while IFS= read -r mp; do
    [[ -n "$mp" ]] && targets+=("$mp")
  done < <(lsblk -nr -o MOUNTPOINT "$(devpath "$dev")" | awk 'NF{print $0}' | sort -r)

  if ((${#targets[@]}==0)); then
    ui "${DIM}No mountpoints found to unmount.${RST}"
    return 0
  fi

  ui "${YEL}Attempting to unmount (deepest first):${RST}"
  for mp in "${targets[@]}"; do
    ui "  sudo umount --lazy -- \"$mp\""
    sudo umount --lazy -- "$mp"
  done
}

# ---------- Device categorization ----------
# Returns: NVMe, SSD, HDD, eMMC, USB, Unknown
categorize_device() {
  local name="$1" tran="$2" rota="$3" rm="$4"

  if [[ "$name" == nvme* ]]; then
    echo "NVMe"
  elif [[ "$name" == mmcblk* ]]; then
    echo "eMMC"
  elif [[ "${tran:-}" == "usb" ]]; then
    echo "USB"
  elif [[ "${rota:-1}" == "0" ]]; then
    echo "SSD"
  elif [[ "${rota:-}" == "1" ]]; then
    echo "HDD"
  else
    echo "Unknown"
  fi
}

# ---------- System disk detection ----------
# Returns the base block device name (e.g. "sda") for a mountpoint
get_base_device_for_mount() {
  local mp="$1"
  local src
  src="$(findmnt -n -o SOURCE "$mp" 2>/dev/null)" || return 1
  [[ -z "$src" ]] && return 1

  # Strip /dev/ prefix
  src="${src#/dev/}"

  # Resolve to parent disk (e.g. sda1 -> sda, nvme0n1p2 -> nvme0n1)
  local parent
  parent="$(lsblk -no PKNAME "$(devpath "$src")" 2>/dev/null | head -1)" || true
  if [[ -n "$parent" ]]; then
    echo "$parent"
  else
    echo "$src"
  fi
}

SYSTEM_DEVICES=()

# ---------- Bus / device rescan ----------
# Forces the kernel to re-enumerate block devices so freshly attached disks
# (USB, SCSI/SAS LUNs, hot-plugged drives) become visible to lsblk.
bus_rescan() {
  if has_cmd udevadm; then
    sudo udevadm trigger --subsystem-match=block 2>/dev/null || true
  fi

  local h
  for h in /sys/class/scsi_host/host*/scan; do
    [[ -e "$h" ]] || continue
    echo "- - -" | sudo tee "$h" >/dev/null 2>&1 || true
  done

  if has_cmd udevadm; then
    sudo udevadm settle --timeout=5 2>/dev/null || true
  fi

  if has_cmd partprobe; then
    sudo partprobe -s >/dev/null 2>&1 || true
  fi
}

detect_system_devices() {
  SYSTEM_DEVICES=()
  local mp dev d found

  # Scan all mounts and collect parent disks for any mountpoint that matches
  # the same critical-path regex used by is_system_partition. Keeps disk-level
  # and partition-level [SYSTEM] markers consistent (e.g. /boot/efi on nvme1n1p1
  # must also mark nvme1n1 as system).
  while IFS= read -r mp; do
    [[ -z "$mp" ]] && continue
    [[ "$mp" =~ ^(/|/boot|/usr|/var|/etc|/lib|/lib64|/bin|/sbin)(/|$) ]] || continue
    dev="$(get_base_device_for_mount "$mp" 2>/dev/null)" || true
    [[ -z "$dev" ]] && continue

    found=false
    if (( ${#SYSTEM_DEVICES[@]} > 0 )); then
      for d in "${SYSTEM_DEVICES[@]}"; do
        [[ "$d" == "$dev" ]] && found=true
      done
    fi
    [[ "$found" == "false" ]] && SYSTEM_DEVICES+=("$dev")
  done < <(findmnt -rn -o TARGET 2>/dev/null)
}

is_system_device() {
  local dev="$1"
  for d in "${SYSTEM_DEVICES[@]}"; do
    [[ "$d" == "$dev" ]] && return 0
  done
  return 1
}

is_system_partition() {
  local mp="$1" parent="$2"
  # Mounted on a critical path?
  [[ "$mp" =~ ^(/|/boot|/usr|/var|/etc|/lib|/lib64|/bin|/sbin)(/|$) ]] && return 0
  # Parent disk is a system disk?
  [[ -n "$parent" && "$parent" != "-" ]] && is_system_device "$parent" && return 0
  return 1
}

# ---------- List all block devices ----------
# Stores device info in parallel arrays for structured access
declare -a DEV_NAMES DEV_SIZES DEV_CATEGORIES DEV_TRANS DEV_MODELS DEV_SERIALS
declare -a PART_NAMES PART_SIZES PART_FSTYPES PART_MOUNTS PART_PARENTS PART_TYPES
declare -a SCRIPT_LUKS_MAPPERS SCRIPT_MOUNTPOINTS
SCRIPT_LUKS_MAPPERS=()
SCRIPT_MOUNTPOINTS=()
KEEP_MOUNTS=false

list_block_devices() {
  DEV_NAMES=(); DEV_SIZES=(); DEV_CATEGORIES=(); DEV_TRANS=(); DEV_MODELS=(); DEV_SERIALS=()

  local line NAME TYPE TRAN ROTA RM SIZE MODEL SERIAL
  while IFS= read -r line; do
    NAME="$(kv "$line" NAME)"
    TYPE="$(kv "$line" TYPE)"
    TRAN="$(kv "$line" TRAN)"
    ROTA="$(kv "$line" ROTA)"
    RM="$(kv "$line" RM)"
    SIZE="$(kv "$line" SIZE)"
    MODEL="$(kv "$line" MODEL)"
    SERIAL="$(kv "$line" SERIAL)"

    [[ "${TYPE:-}" == "disk" ]] || continue

    local cat
    cat="$(categorize_device "$NAME" "$TRAN" "$ROTA" "$RM")"

    DEV_NAMES+=("$NAME")
    DEV_SIZES+=("$SIZE")
    DEV_CATEGORIES+=("$cat")
    DEV_TRANS+=("${TRAN:-"-"}")
    DEV_MODELS+=("${MODEL:-"-"}")
    DEV_SERIALS+=("${SERIAL:-"-"}")
  done < <(lsblk -dn -P -o NAME,TYPE,TRAN,ROTA,RM,SIZE,MODEL,SERIAL)
}

# ---------- Methods ----------
declare -a METHOD_ID METHOD_LABEL METHOD_REC METHOD_CMDS METHOD_NOTES METHOD_SECURITY

add_method() {
  METHOD_ID+=("$1")
  METHOD_LABEL+=("$2")
  METHOD_REC+=("$3")
  METHOD_CMDS+=("$4")
  METHOD_NOTES+=("$5")
  METHOD_SECURITY+=("$6")
}

build_methods_for_device() {
  local dev="$1" category="$2"
  METHOD_ID=(); METHOD_LABEL=(); METHOD_REC=(); METHOD_CMDS=(); METHOD_NOTES=(); METHOD_SECURITY=()

  case "$category" in
    NVMe)
      # NVMe: controller-native format is best
      if has_cmd nvme; then
        add_method \
          "nvme_format" \
          "NVMe Format (controller-native)" \
          "yes" \
          "sudo nvme format -f $(devpath "$dev")" \
          "Controller wipes all flash cells including spare area." \
          "★★★|practically impossible|Controller-internal command, covers entire flash incl. over-provisioning"
      else
        add_method \
          "nvme_format" \
          "NVMe Format (nvme-cli not installed)" \
          "yes" \
          "# sudo apt install nvme-cli\nsudo nvme format -f $(devpath "$dev")" \
          "Recommended for NVMe, but nvme-cli is missing." \
          "★★★|practically impossible|Controller-internal command, covers entire flash incl. over-provisioning"
      fi

      if supports_discard "$dev" && has_cmd blkdiscard; then
        add_method \
          "blkdiscard" \
          "Discard/TRIM (whole device)" \
          "no" \
          "sudo blkdiscard -f $(devpath "$dev")" \
          "Fast, marks all blocks as free." \
          "★★☆|possible with special equipment|TRIM marks blocks as free, physical erasure depends on controller"
      fi

      add_method \
        "dd_zero" \
        "Overwrite with zeros (dd, slow)" \
        "no" \
        "sudo dd if=/dev/zero of=$(devpath "$dev") bs=16M status=progress oflag=direct\nsudo sync" \
        "Wear-leveling may leave old data in spare area." \
        "★☆☆|possible with software|Wear-leveling/remapping bypasses overwrite, spare area remains untouched"
      ;;

    SSD)
      # SATA SSD: ATA Secure Erase best, then blkdiscard, then overwrite
      if has_cmd hdparm; then
        add_method \
          "ata_secure_erase" \
          "ATA Secure Erase (checked on selection)" \
          "yes" \
          "__DEFERRED_ATA__" \
          "Controller-native erase command. Details checked on selection." \
          "★★★|practically impossible|Controller-internal, covers remapped sectors and spare area"
      fi

      if supports_discard "$dev" && has_cmd blkdiscard; then
        local rec="no"
        [[ "${#METHOD_ID[@]}" -eq 0 ]] && rec="yes"
        add_method \
          "blkdiscard" \
          "Discard/TRIM (whole device)" \
          "$rec" \
          "sudo blkdiscard -f $(devpath "$dev")" \
          "Fast, marks all blocks as free." \
          "★★☆|possible with special equipment|TRIM marks blocks as free, physical erasure depends on controller"
      fi

      add_method \
        "dd_zero" \
        "Overwrite with zeros (dd, slow, unreliable on SSDs)" \
        "no" \
        "sudo dd if=/dev/zero of=$(devpath "$dev") bs=16M status=progress oflag=direct\nsudo sync" \
        "Wear-leveling may leave old data in spare area." \
        "★☆☆|possible with software|Wear-leveling/remapping bypasses overwrite, spare area remains untouched"
      ;;

    HDD)
      # HDD: shred is best, then dd, then ATA SE if available
      add_method \
        "shred" \
        "shred (1x overwrite + zeros)" \
        "yes" \
        "sudo shred -v -n 1 -z $(devpath "$dev")" \
        "Overwrites every sector, fully reliable on HDDs." \
        "★★★|practically impossible|Overwrites every physical sector, no hidden areas on HDD"

      add_method \
        "dd_zero" \
        "Overwrite with zeros, dd" \
        "no" \
        "sudo dd if=/dev/zero of=$(devpath "$dev") bs=16M status=progress oflag=direct\nsudo sync" \
        "Single pass with zeros, faster than shred." \
        "★★☆|possible with special equipment|Single pass sufficient per NIST 800-88, residual magnetism theoretically measurable"

      if has_cmd badblocks; then
        add_method \
          "badblocks_wipe" \
          "badblocks -w (defective disk, skips bad sectors)" \
          "no" \
          "sudo badblocks -wsv -b 4096 $(devpath "$dev")" \
          "Writes 4 patterns incl. zeros, skips unwritable sectors. Use when dd aborts with I/O errors." \
          "★★★|practically impossible|Covers all writable sectors; bad sectors are skipped and logged"
      fi

      if has_cmd hdparm; then
        add_method \
          "ata_secure_erase" \
          "ATA Secure Erase (checked on selection)" \
          "no" \
          "__DEFERRED_ATA__" \
          "Controller-native erase command. Details checked on selection." \
          "★★★|practically impossible|Controller-internal, covers remapped sectors"
      fi
      ;;

    USB|eMMC)
      # USB/eMMC: blkdiscard if supported, then dd, then shred
      if supports_discard "$dev" && has_cmd blkdiscard; then
        add_method \
          "blkdiscard" \
          "Discard/TRIM (whole device)" \
          "yes" \
          "sudo blkdiscard -f $(devpath "$dev")" \
          "Fast, if supported by the controller." \
          "★★☆|possible with special equipment|TRIM marks blocks as free, physical erasure depends on controller"
      fi

      local rec_dd="no"
      [[ "${#METHOD_ID[@]}" -eq 0 ]] && rec_dd="yes"
      add_method \
        "dd_zero" \
        "Overwrite with zeros, dd" \
        "$rec_dd" \
        "sudo dd if=/dev/zero of=$(devpath "$dev") bs=16M status=progress oflag=direct\nsudo sync" \
        "Slow but reliable for simple flash controllers." \
        "★★☆|possible with special equipment|Simple flash controllers often lack wear-leveling, overwrite usually complete"

      add_method \
        "shred" \
        "shred (1x overwrite + zeros)" \
        "no" \
        "sudo shred -v -n 1 -z $(devpath "$dev")" \
        "Like dd, but with additional random pass." \
        "★★☆|possible with special equipment|Simple controllers: usually complete. Complex controllers: wear-leveling possible"

      if has_cmd badblocks; then
        add_method \
          "badblocks_wipe" \
          "badblocks -w (defective disk, skips bad sectors)" \
          "no" \
          "sudo badblocks -wsv -b 4096 $(devpath "$dev")" \
          "Writes 4 patterns incl. zeros, skips unwritable sectors. Use when dd aborts with I/O errors." \
          "★★☆|possible with special equipment|Covers all writable sectors; bad sectors skipped"
      fi
      ;;

    *)
      # Unknown: offer generic methods
      add_method \
        "dd_zero" \
        "Overwrite with zeros, dd" \
        "yes" \
        "sudo dd if=/dev/zero of=$(devpath "$dev") bs=16M status=progress oflag=direct\nsudo sync" \
        "Generic method, works with any block device." \
        "★★☆|depends on device type|Effectiveness depends on controller and device type"

      add_method \
        "shred" \
        "shred (1x overwrite + zeros)" \
        "no" \
        "sudo shred -v -n 1 -z $(devpath "$dev")" \
        "Overwrites with random data + zeros." \
        "★★☆|depends on device type|Effectiveness depends on controller and device type"

      if has_cmd badblocks; then
        add_method \
          "badblocks_wipe" \
          "badblocks -w (defective disk, skips bad sectors)" \
          "no" \
          "sudo badblocks -wsv -b 4096 $(devpath "$dev")" \
          "Writes 4 patterns incl. zeros, skips unwritable sectors. Use when dd aborts with I/O errors." \
          "★★☆|depends on device type|Covers all writable sectors; bad sectors skipped"
      fi
      ;;
  esac

  # LUKS: only if device actually has a LUKS header
  if has_cmd cryptsetup; then
    if sudo cryptsetup isLuks "$(devpath "$dev")" 2>/dev/null; then
      add_method \
        "luks_erase" \
        "Destroy LUKS header (key destruction)" \
        "no" \
        "sudo cryptsetup luksErase $(devpath "$dev")" \
        "Destroys LUKS header only. Data remains encrypted without key." \
        "★★★|practically impossible|Without key, AES-encrypted data is unrecoverable"
    fi
  fi
}

# ---------- Deferred ATA Secure Erase ----------
resolve_ata_secure_erase() {
  local dev="$1"

  ui ""
  ui "${DIM}Checking ATA Security features...${RST}"

  local sec frozen enhanced
  sec="$(sudo hdparm -I "$(devpath "$dev")" 2>/dev/null | sed -n '/Security:/,/Logical Unit/p' || true)"

  if [[ -z "$sec" ]] || ! echo "$sec" | grep -qi "supported"; then
    ui "${YEL}ATA Secure Erase is not supported by this device.${RST}"
    ui "${DIM}(USB bridges often don't pass through ATA security commands.)${RST}"
    return 1
  fi

  frozen="no"; enhanced="no"
  if echo "$sec" | grep -qi "frozen" && ! echo "$sec" | grep -qi "not.*frozen"; then
    frozen="yes"
  fi
  echo "$sec" | grep -qi "enhanced erase" && enhanced="yes"

  if [[ "$frozen" == "yes" ]]; then
    ui "${YEL}Device is 'frozen'. ATA Secure Erase not possible.${RST}"
    ui "${DIM}Fix: Suspend/resume or disconnect/reconnect the device, then try again.${RST}"
    return 1
  fi

  local erase_cmd
  if [[ "$enhanced" == "yes" ]]; then
    ui "${GRN}Enhanced Secure Erase available.${RST}"
    erase_cmd="sudo hdparm --user-master u --security-set-pass p $(devpath "$dev")"$'\n'"sudo hdparm --user-master u --security-erase-enhanced p $(devpath "$dev")"
  else
    ui "${GRN}Standard Secure Erase available.${RST}"
    erase_cmd="sudo hdparm --user-master u --security-set-pass p $(devpath "$dev")"$'\n'"sudo hdparm --user-master u --security-erase p $(devpath "$dev")"
  fi

  ui "${DIM}Temporary password: 'p'${RST}"

  # Replace the deferred command with the real one
  for i in "${!METHOD_ID[@]}"; do
    if [[ "${METHOD_ID[$i]}" == "ata_secure_erase" ]]; then
      METHOD_CMDS[$i]="$erase_cmd"
      if [[ "$enhanced" == "yes" ]]; then
        METHOD_LABEL[$i]="ATA Enhanced Secure Erase (hdparm)"
      else
        METHOD_LABEL[$i]="ATA Secure Erase (hdparm)"
      fi
      break
    fi
  done

  return 0
}

# ---------- Security rating display ----------
print_security_rating() {
  local rating="$1"
  local stars forensic detail
  IFS='|' read -r stars forensic detail <<< "$rating"

  ui ""
  ui "${BOLD}Security rating:${RST}"
  ui "  Data security:      ${BOLD}${stars}${RST}"
  ui "  Forensic recovery:  ${forensic}"
  ui "  ${DIM}${detail}${RST}"
}

# ---------- Post-erase verification ----------
verify_erase() {
  local dev="$1"

  ui ""
  read -r -p "Run verification (checks if blocks are empty)? [y/N]: " ans >&2
  [[ "$ans" =~ ^[Yy]$ ]] || return 0

  ui "${DIM}Reading sample blocks...${RST}"

  local dev_path
  dev_path="$(devpath "$dev")"
  local dev_size_bytes
  dev_size_bytes="$(sudo blockdev --getsize64 "$dev_path" 2>/dev/null)" || {
    ui "${YEL}Could not determine device size.${RST}"
    return 0
  }

  local block_size=4096
  local total_blocks=$((dev_size_bytes / block_size))
  local all_zero=true

  # Check first block, last block, and 3 random positions
  local positions=("0")
  ((total_blocks > 1)) && positions+=("$((total_blocks - 1))")
  for _ in 1 2 3; do
    ((total_blocks > 2)) && positions+=("$((RANDOM % total_blocks))")
  done

  for pos in "${positions[@]}"; do
    local data
    data="$(sudo dd if="$dev_path" bs=$block_size skip="$pos" count=1 2>/dev/null | od -v -A n -t x1 | tr -d ' \n')"
    # Check if all zeros
    local cleaned
    cleaned="$(echo "$data" | tr -d '0')"
    if [[ -n "$cleaned" ]]; then
      all_zero=false
      break
    fi
  done

  ui ""
  if [[ "$all_zero" == "true" ]]; then
    ui "${GRN}All checked blocks are empty (zeros).${RST}"
  else
    ui "${YEL}Non-zero data found. Possible causes:${RST}"
    ui "${DIM}  - Controller erase does not necessarily write zeros${RST}"
    ui "${DIM}  - Erase not yet complete (some controllers work asynchronously)${RST}"
    ui "${DIM}  - Partition table / metadata remnants${RST}"
  fi
}

# ---------- Cleanup: script-opened volumes ----------
cleanup_script_mounts() {
  [[ "$KEEP_MOUNTS" == "true" ]] && return 0
  local mp mapper
  set +u  # empty arrays trigger nounset in some bash versions
  for mp in "${SCRIPT_MOUNTPOINTS[@]}"; do
    [[ -z "$mp" ]] && continue
    sudo umount "$mp" 2>/dev/null || true
    sudo rmdir  "$mp" 2>/dev/null || true
  done
  for mapper in "${SCRIPT_LUKS_MAPPERS[@]}"; do
    [[ -z "$mapper" ]] && continue
    sudo cryptsetup close "$mapper" 2>/dev/null || true
  done
  set -u
  SCRIPT_LUKS_MAPPERS=(); SCRIPT_MOUNTPOINTS=()
}
trap cleanup_script_mounts EXIT

# ---------- Free-space wipe ----------
list_partitions_with_fs() {
  PART_NAMES=(); PART_SIZES=(); PART_FSTYPES=(); PART_MOUNTS=(); PART_PARENTS=(); PART_TYPES=()

  local line NAME TYPE FSTYPE MOUNTPOINT SIZE PKNAME TRAN ROTA RM
  while IFS= read -r line; do
    NAME="$(kv "$line" NAME)"
    TYPE="$(kv "$line" TYPE)"
    FSTYPE="$(kv "$line" FSTYPE)"
    MOUNTPOINT="$(kv "$line" MOUNTPOINT)"
    SIZE="$(kv "$line" SIZE)"
    PKNAME="$(kv "$line" PKNAME)"
    TRAN="$(kv "$line" TRAN)"
    ROTA="$(kv "$line" ROTA)"
    RM="$(kv "$line" RM)"

    [[ "${TYPE:-}" =~ ^(part|crypt)$ ]] || continue
    [[ -n "${FSTYPE:-}" ]] || continue

    local cat top parent_info
    top="$(top_level_disk "$NAME")"
    parent_info="$(lsblk -dn -P -o TRAN,ROTA,RM "/dev/$top" 2>/dev/null || true)"
    if [[ -n "$parent_info" ]]; then
      TRAN="$(kv "$parent_info" TRAN)"
      ROTA="$(kv "$parent_info" ROTA)"
      RM="$(kv "$parent_info" RM)"
    fi
    cat="$(categorize_device "$top" "$TRAN" "$ROTA" "$RM")"

    PART_NAMES+=("$NAME")
    PART_SIZES+=("$SIZE")
    PART_FSTYPES+=("${FSTYPE:-"-"}")
    PART_MOUNTS+=("${MOUNTPOINT:-""}")
    PART_PARENTS+=("${PKNAME:-"-"}")
    PART_TYPES+=("$cat")
  done < <(lsblk -P -o NAME,TYPE,FSTYPE,MOUNTPOINT,SIZE,PKNAME,TRAN,ROTA,RM)
}

select_partition_for_wipe() {
  if ((${#PART_NAMES[@]} == 0)); then
    ui "${YEL}No partitions with a filesystem found.${RST}"
    return 1
  fi

  ui ""
  ui "${BOLD}Partitions available for free-space wipe:${RST}"
  ui ""
  uiprintf "  ${DIM}%-4s %-12s %6s  %-7s %-10s %-18b %-20s${RST}\n" "#" "DEVICE" "SIZE" "TYPE" "FSTYPE" "STATUS" "MOUNTPOINT"

  local i
  for i in "${!PART_NAMES[@]}"; do
    local status mp="${PART_MOUNTS[$i]}" marker=""
    if [[ -n "$mp" ]]; then
      status="${GRN}mounted${RST}"
    else
      status="${YEL}unmounted${RST}"
      mp="-"
    fi
    is_system_partition "${PART_MOUNTS[$i]}" "${PART_PARENTS[$i]}" && marker=" ${RED}[SYSTEM]${RST}"
    uiprintf "  ${BOLD}[%d]${RST} %-12s %6s  %-7s %-10s %-26b %-20s%b\n" \
      "$((i+1))" \
      "${PART_NAMES[$i]}" \
      "${PART_SIZES[$i]}" \
      "${PART_TYPES[$i]}" \
      "${PART_FSTYPES[$i]}" \
      "$status" \
      "$mp" \
      "$marker"
  done

  ui ""
  local choice
  while true; do
    read -r -p "Select partition (number, 'b' back, 'q' quit): " choice >&2
    [[ "$choice" == "q" || "$choice" == "Q" ]] && { printf "%s\n" "QUIT"; return 0; }
    [[ "$choice" == "b" || "$choice" == "B" ]] && { printf "%s\n" "BACK"; return 0; }
    [[ "$choice" =~ ^[0-9]+$ ]] || { ui "${YEL}Invalid input '${choice}' – enter a number, 'b' or 'q'.${RST}"; continue; }
    (( choice >= 1 && choice <= ${#PART_NAMES[@]} )) || { ui "${YEL}No such partition: ${choice} (valid: 1–${#PART_NAMES[@]}).${RST}"; continue; }
    printf "%d\n" "$((choice-1))"
    return 0
  done
}

build_freespace_methods_for_partition() {
  local name="$1" fstype="$2" mountpoint="$3" parent="$4" devtype="${5:-Unknown}"
  METHOD_ID=(); METHOD_LABEL=(); METHOD_REC=(); METHOD_CMDS=(); METHOD_NOTES=(); METHOD_SECURITY=()

  local dev
  dev="$(devpath "$name")"

  if [[ -n "$mountpoint" ]]; then
    local is_flash=false
    if has_cmd fstrim; then
      if [[ "$devtype" =~ ^(NVMe|SSD)$ ]]; then
        is_flash=true
      elif [[ -n "$parent" && "$parent" != "-" ]] && supports_discard "$parent"; then
        is_flash=true
      fi
    fi

    if [[ "${fstype:-}" == "ntfs" ]]; then
      ui "${YEL}Note:${RST} ${DIM}MFT records of deleted files are NOT covered by dd/sfill/fstrim."
      ui "      Unmount the partition and use ntfswipe for full coverage (sudo apt install ntfs-3g).${RST}"
    fi

    if [[ "$is_flash" == "true" ]]; then
      add_method \
        "fstrim" \
        "fstrim (TRIM free blocks)" \
        "yes" \
        "sudo fstrim -v \"$mountpoint\"" \
        "Sends TRIM to all free blocks. Fast, effective on SSD/NVMe." \
        "★★☆|possible with special equipment|TRIM marks blocks as free; physical erasure depends on controller"
    fi

    local dd_rec="no"
    [[ "$is_flash" == "false" ]] && dd_rec="yes"
    add_method \
      "dd_freespace" \
      "Fill free space with zeros (dd)" \
      "$dd_rec" \
      "sudo dd if=/dev/zero of=\"${mountpoint}/.wipe_free.tmp\" bs=16M status=progress || true\nsync\nsudo rm -f \"${mountpoint}/.wipe_free.tmp\"" \
      "Fills all free data blocks with zeros. Inode/dentry slack not covered." \
      "★★☆|possible|Free data blocks zeroed; inode/dentry slack not covered"

    if has_cmd sfill; then
      add_method \
        "sfill" \
        "sfill (secure-delete)" \
        "no" \
        "sudo sfill -v -z -l -f \"$mountpoint\"" \
        "Wipes free blocks plus inode and directory entry slack space." \
        "★★★|practically impossible|Covers data blocks and filesystem metadata slack"
    else
      ui "${DIM}Tip: sudo apt install secure-delete  →  enables sfill (wipes inode/dentry slack too)${RST}"
    fi

    if [[ "${fstype:-}" =~ ^ext[234]$ ]] && has_cmd zerofree; then
      add_method \
        "zerofree_remount" \
        "zerofree (remount ro → zerofree → remount rw)" \
        "no" \
        "sudo mount -o remount,ro \"$mountpoint\"\nsudo zerofree -v $dev\nsudo mount -o remount,rw \"$mountpoint\"" \
        "Remounts read-only, zeroes free ext blocks, remounts read-write. Do NOT use on active system partitions." \
        "★★☆|possible|Free blocks zeroed per superblock; slack areas may remain"
    fi

    if [[ "${fstype:-}" == "ntfs" ]]; then
      add_method \
        "unmount_for_ntfswipe" \
        "Unmount & rescan (then use ntfswipe for MFT coverage)" \
        "no" \
        "sudo umount \"$mountpoint\"" \
        "Unmounts the partition so ntfswipe can be used in the next step (covers MFT + unused clusters + slack)." \
        "-|-|Unmount only – run ntfswipe in the next step"
    fi
  else
    case "${fstype:-}" in
      ext2|ext3|ext4)
        if has_cmd zerofree; then
          add_method \
            "zerofree" \
            "zerofree (ext2/3/4)" \
            "yes" \
            "sudo zerofree -v $dev" \
            "Writes zeros to all free ext blocks. Requires unmounted or read-only device." \
            "★★☆|possible|Free blocks zeroed per superblock; slack areas may remain"
        else
          add_method \
            "zerofree_missing" \
            "zerofree (not installed)" \
            "yes" \
            "# sudo apt install zerofree\nsudo zerofree -v $dev" \
            "Requires zerofree package (sudo apt install zerofree)." \
            "★★☆|possible|Free blocks zeroed per superblock; slack areas may remain"
        fi
        ;;

      crypto_LUKS)
        local mapper="swipe_${name//[^a-zA-Z0-9_-]/_}"
        local mntpoint="/tmp/${mapper}"
        add_method \
          "unlock_luks" \
          "Unlock LUKS & mount (then rescan)" \
          "yes" \
          "sudo cryptsetup open $dev ${mapper}\nsudo mkdir -p ${mntpoint}\nsudo mount /dev/mapper/${mapper} ${mntpoint}" \
          "Prompts for LUKS passphrase, mounts under ${mntpoint}. Device appears in list after rescan." \
          "-|-|Mount only – wipe free space in the next step"
        ;;

      ntfs)
        if has_cmd ntfswipe; then
          add_method \
            "ntfswipe" \
            "ntfswipe --all (unused + MFT + slack + log)" \
            "yes" \
            "sudo ntfswipe -a $dev" \
            "Wipes unused clusters, MFT records of deleted files, file tails and NTFS log. Requires unmounted device." \
            "★★★|practically impossible|Covers data clusters, MFT entries, file tails and NTFS journal"
        else
          add_method \
            "ntfswipe_missing" \
            "ntfswipe (not installed)" \
            "yes" \
            "# sudo apt install ntfs-3g\nsudo ntfswipe -a $dev" \
            "Requires ntfs-3g package: sudo apt install ntfs-3g" \
            "★★★|practically impossible|Covers data clusters, MFT entries, file tails and NTFS journal"
        fi
        ;;

      BitLocker|bitlocker)
        local mntpoint="/tmp/swipe_${name//[^a-zA-Z0-9_-]/_}"
        if has_cmd dislocker; then
          local dlpath="${mntpoint}_dl"
          add_method \
            "unlock_bitlocker" \
            "Unlock BitLocker & mount (dislocker)" \
            "yes" \
            "sudo mkdir -p ${dlpath} ${mntpoint}\nsudo dislocker $dev -- ${dlpath}\nsudo mount -o loop ${dlpath}/dislocker-file ${mntpoint}" \
            "Prompts for BitLocker password, mounts under ${mntpoint}. Device appears in list after rescan." \
            "-|-|Mount only – wipe free space in the next step"
        else
          add_method \
            "unlock_bitlocker_missing" \
            "Unlock BitLocker (dislocker not installed)" \
            "yes" \
            "# sudo apt install dislocker" \
            "Install dislocker first: sudo apt install dislocker" \
            "-|-|-"
        fi
        ;;

    esac

    # Offer generic mount for all unmounted non-encrypted partitions
    case "${fstype:-}" in
      crypto_LUKS|BitLocker|bitlocker) ;;
      *)
        local mntpoint="/tmp/swipe_${name//[^a-zA-Z0-9_-]/_}"
        local mount_rec="no"
        ((${#METHOD_ID[@]} == 0)) && mount_rec="yes"
        add_method \
          "mount_generic" \
          "Mount partition (then rescan)" \
          "$mount_rec" \
          "sudo mkdir -p ${mntpoint}\nsudo mount $dev ${mntpoint}" \
          "Mounts the partition under ${mntpoint}. After rescan it appears as mounted in the list." \
          "-|-|Mount only – wipe free space in the next step"
        ;;
    esac
  fi
}

run_freespace_wipe() {
  local idx="$1"
  local name="${PART_NAMES[$idx]}"
  local fstype="${PART_FSTYPES[$idx]}"
  local mountpoint="${PART_MOUNTS[$idx]}"
  local parent="${PART_PARENTS[$idx]}"
  local devtype="${PART_TYPES[$idx]}"

  if is_system_partition "$mountpoint" "$parent"; then
    ui ""
    ui "${RED}${BOLD}WARNING: $(devpath "$name") is a SYSTEM PARTITION (mounted: ${mountpoint:-unmounted})${RST}"
    ui "${RED}Wiping free space on system partitions can cause data loss or an unbootable system.${RST}"
    ui ""
    read -r -p "Type 'YES' to continue anyway: " typed >&2
    [[ "$typed" == "YES" ]] || { ui "${CYA}Aborted.${RST}"; return 1; }
  fi

  build_freespace_methods_for_partition "$name" "$fstype" "$mountpoint" "$parent" "$devtype"

  if ((${#METHOD_ID[@]} == 0)); then
    ui ""
    ui "${YEL}No free-space wipe methods available for this partition.${RST}"
    [[ -z "$mountpoint" ]] && ui "${DIM}Hint: mount the partition first, or use zerofree for ext2/3/4.${RST}"
    return 0
  fi

  local method_choice
  method_choice="$(select_method "$name")" || return 1
  [[ "$method_choice" == "QUIT" ]] && exit 0
  [[ "$method_choice" == "BACK" ]] && return 11

  local i=$((method_choice-1))

  if [[ "${METHOD_ID[$i]}" == "ntfswipe" ]]; then
    local dev_path
    dev_path="$(devpath "$name")"
    local -a opt_flag=("-u" "-i" "-t" "-l" "-d" "-p")
    local -a opt_label=(
      "unused clusters (free space)"
      "MFT records of deleted files"
      "file tails (slack of existing files; content preserved)"
      "NTFS log"
      "directory entries"
      "pagefile.sys CONTENT (existing file — bytes will be zeroed)"
    )
    local -a opt_on=(1 1 1 1 1 0)

    while true; do
      ui ""
      ui "${BOLD}ntfswipe options — toggle by number, Enter to accept:${RST}"
      local k
      for k in 0 1 2 3 4 5; do
        local mark="[ ]"
        ((opt_on[k])) && mark="[${GRN}x${RST}]"
        local extra=""
        ((k == 5)) && extra=" ${RED}(modifies existing file)${RST}"
        ui "  [$((k+1))] ${mark} ${opt_flag[k]}  ${opt_label[k]}${extra}"
      done
      local sel
      read -r -p "Toggle [1-6], Enter=accept, 'b' back, 'q' quit: " sel >&2
      [[ -z "$sel" ]] && break
      [[ "$sel" == "q" || "$sel" == "Q" ]] && exit 0
      [[ "$sel" == "b" || "$sel" == "B" ]] && return 11
      if [[ "$sel" =~ ^[1-6]$ ]]; then
        local tidx=$((sel-1))
        opt_on[tidx]=$(( 1 - opt_on[tidx] ))
      else
        ui "${YEL}Invalid input.${RST}"
      fi
    done

    local flags=""
    for k in 0 1 2 3 4 5; do
      ((opt_on[k])) && flags+=" ${opt_flag[k]}"
    done
    if [[ -z "$flags" ]]; then
      ui "${CYA}No options selected. Aborted.${RST}"
      return 0
    fi
    METHOD_CMDS[$i]="sudo ntfswipe${flags} ${dev_path}"
  fi

  ui ""
  ui "${BOLD}Method:${RST} ${METHOD_LABEL[$i]}"
  ui "${BOLD}Note:${RST} ${METHOD_NOTES[$i]}"
  print_security_rating "${METHOD_SECURITY[$i]}"

  ui ""
  ui "${BOLD}Command(s):${RST}"
  ui "------------------------------------------------------------"
  uiprintf "$(printf "%b\n" "${METHOD_CMDS[$i]}")\n"
  ui "------------------------------------------------------------"
  ui ""

  read -r -p "EXECUTE now? [y/N]: " ans >&2
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    ui "${CYA}Not executed.${RST} Copy/paste the command(s) above when ready."
    return 0
  fi

  ui ""
  ui "${YEL}Executing...${RST}"
  ui ""

  local cmd_block="${METHOD_CMDS[$i]}"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    ui "${DIM}>>${RST} $line"
    local rc=0 child_pid
    bash -c "$line" &
    child_pid=$!
    trap 'ui ""; ui "${YEL}Cancel requested — sending SIGTERM (SIGKILL in 3s)...${RST}"; kill_tree '"$child_pid"' TERM; ( sleep 3; kill_tree '"$child_pid"' KILL ) >/dev/null 2>&1 &' INT
    wait "$child_pid"
    rc=$?
    # wait returns 128+sig when interrupted by our trap; keep waiting until
    # the child is actually gone so cleanup doesn't race with a dying tool.
    while kill -0 "$child_pid" 2>/dev/null; do
      wait "$child_pid" 2>/dev/null
      rc=$?
    done
    trap - INT
    if (( rc != 0 )); then
      post_cancel_cleanup "${METHOD_ID[$i]}" "$mountpoint"
      ui ""
      ui "${RED}Command failed or cancelled (exit code ${rc}). Aborting.${RST}"
      return 2
    fi
  done < <(printf '%b\n' "$cmd_block")

  ui ""
  ui "${GRN}Done.${RST}"

  # Unlock methods: track opened volumes and signal rescan
  local mid="${METHOD_ID[$i]}"
  if [[ "$mid" == "unlock_luks" ]]; then
    local mapper="swipe_${name//[^a-zA-Z0-9_-]/_}"
    local mntpoint="/tmp/${mapper}"
    SCRIPT_LUKS_MAPPERS+=("$mapper")
    SCRIPT_MOUNTPOINTS+=("$mntpoint")
    ui "${CYA}Volume mounted. Rescanning partition list...${RST}"
    return 10
  fi
  if [[ "$mid" == "unlock_bitlocker" ]]; then
    local mntpoint="/tmp/swipe_${name//[^a-zA-Z0-9_-]/_}"
    local dlpath="${mntpoint}_dl"
    SCRIPT_MOUNTPOINTS+=("$mntpoint" "$dlpath")
    ui "${CYA}Volume mounted. Rescanning partition list...${RST}"
    return 10
  fi
  if [[ "$mid" == "mount_generic" ]]; then
    local mntpoint="/tmp/swipe_${name//[^a-zA-Z0-9_-]/_}"
    SCRIPT_MOUNTPOINTS+=("$mntpoint")
    ui "${CYA}Partition mounted. Rescanning partition list...${RST}"
    return 10
  fi
  if [[ "$mid" == "unmount_for_ntfswipe" ]]; then
    # Remove the mountpoint from tracking – it was already unmounted above
    local new_mounts=()
    set +u
    for mp in "${SCRIPT_MOUNTPOINTS[@]}"; do
      [[ -z "$mp" || "$mp" == "$mountpoint" ]] || new_mounts+=("$mp")
    done
    SCRIPT_MOUNTPOINTS=("${new_mounts[@]}")
    set -u
    sudo rmdir "$mountpoint" 2>/dev/null || true
    ui "${CYA}Partition unmounted. Rescanning partition list...${RST}"
    return 10
  fi
}

freespace_wipe_flow() {
  while true; do
    list_partitions_with_fs
    local idx
    idx="$(select_partition_for_wipe)" || break
    [[ "$idx" == "QUIT" ]] && exit 0
    [[ "$idx" == "BACK" ]] && break

    local rc=0
    run_freespace_wipe "$idx" || rc=$?

    if ((rc == 10)); then
      bus_rescan
      continue  # rescan: loop calls list_partitions_with_fs again
    fi

    if ((rc == 11)); then
      continue  # BACK from method menu -> re-show partition list
    fi

    ui ""
    read -r -p "Wipe another partition? [y/N]: " again >&2
    [[ "$again" =~ ^[Yy]$ ]] || break
  done

  if [[ ${#SCRIPT_MOUNTPOINTS[@]} -gt 0 ]]; then
    ui ""
    ui "${YEL}This session mounted the following volumes:${RST}"
    local mp
    for mp in "${SCRIPT_MOUNTPOINTS[@]}"; do
      ui "  $mp"
    done
    read -r -p "Unmount and close them now? [Y/n]: " ans >&2
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
      cleanup_script_mounts
      ui "${GRN}Cleanup done.${RST}"
    else
      KEEP_MOUNTS=true
      ui "${YEL}Mounts kept open. Unmount manually when done:${RST}"
      for mp in "${SCRIPT_MOUNTPOINTS[@]}"; do
        ui "  sudo umount \"$mp\""
      done
      for mapper in "${SCRIPT_LUKS_MAPPERS[@]}"; do
        ui "  sudo cryptsetup close \"$mapper\""
      done
    fi
  fi
}

# ---------- Interactive UI ----------
print_header() {
  ui "${BOLD}Secure-Erase Helper${RST}"
  ui "${DIM}Detects all storage devices, recommends the best erase method per type.${RST}"
  ui ""
  ui "${YEL}WARNING:${RST} Any erase operation is irreversible. Double-check the selected device!"
}

select_device() {
  list_block_devices

  ((${#DEV_NAMES[@]} > 0)) || die "No block devices found."

  ui ""
  ui "${BOLD}Detected storage devices:${RST}"
  ui ""

  # Table header
  uiprintf "  ${DIM}%-4s %-12s %6s  %-6s %-5s %-20s${RST}\n" "#" "DEVICE" "SIZE" "TYPE" "TRAN" "MODEL"

  local i
  for i in "${!DEV_NAMES[@]}"; do
    local marker=""
    if is_system_device "${DEV_NAMES[$i]}"; then
      marker=" ${RED}[SYSTEM]${RST}"
    fi
    uiprintf "  ${BOLD}[%d]${RST} %-12s %6s  %-6s %-5s %-20s%s\n" \
      "$((i+1))" \
      "${DEV_NAMES[$i]}" \
      "${DEV_SIZES[$i]}" \
      "${DEV_CATEGORIES[$i]}" \
      "${DEV_TRANS[$i]}" \
      "${DEV_MODELS[$i]}" \
      "$marker"
  done

  ui ""
  local choice
  while true; do
    read -r -p "Select device (number, 'd' rescan, 'b' back, 'q' quit): " choice >&2
    [[ "$choice" == "q" || "$choice" == "Q" ]] && { printf "%s\n" "QUIT"; return 0; }
    [[ "$choice" == "b" || "$choice" == "B" ]] && { printf "%s\n" "BACK"; return 0; }
    [[ "$choice" == "d" || "$choice" == "D" ]] && { printf "%s\n" "RESCAN"; return 0; }
    [[ "$choice" =~ ^[0-9]+$ ]] || { ui "${YEL}Invalid input '${choice}' – enter a number, 'd', 'b' or 'q'.${RST}"; continue; }
    (( choice >= 1 && choice <= ${#DEV_NAMES[@]} )) || { ui "${YEL}No such device: ${choice} (valid: 1–${#DEV_NAMES[@]}).${RST}"; continue; }

    local idx=$((choice-1))
    # Return "name|category" on STDOUT
    printf "%s|%s\n" "${DEV_NAMES[$idx]}" "${DEV_CATEGORIES[$idx]}"
    return 0
  done
}

show_device_summary() {
  local dev="$1" category="$2"
  ui ""
  ui "${BOLD}Selected:${RST} $(devpath "$dev") (${category})"
  lsblk -o NAME,SIZE,TYPE,TRAN,ROTA,RM,MODEL,SERIAL,FSTYPE,MOUNTPOINT "$(devpath "$dev")" >&2 || true
  ui ""
  if supports_discard "$dev"; then
    ui "${GRN}Discard/TRIM:${RST} yes (discard_max_bytes=$(<"/sys/block/$dev/queue/discard_max_bytes"))"
  else
    ui "${YEL}Discard/TRIM:${RST} no"
  fi
}

confirm_system_disk() {
  local dev="$1"
  is_system_device "$dev" || return 0

  ui ""
  ui "${RED}${BOLD}!!! WARNING: $(devpath "$dev") is a SYSTEM DEVICE !!!${RST}"
  ui "${RED}This device contains the root filesystem or /boot.${RST}"
  ui "${RED}Erasing it will make the system unbootable!${RST}"
  ui ""
  read -r -p "Type 'YES' to continue anyway: " typed >&2
  [[ "$typed" == "YES" ]] || die "Aborted."
}

confirm_safe_state() {
  local dev="$1"
  ui ""
  print_device_mounts "$dev"
  ui ""

  if device_has_mounts "$dev"; then
    ui "${YEL}Warning:${RST} Some partitions are mounted."
    read -r -p "Unmount everything under $(devpath "$dev")? [y/N]: " ans >&2
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      unmount_device_tree "$dev" || die "Unmount failed. Please unmount manually."
      ui "${GRN}Unmount complete.${RST}"
    else
      die "Aborted: mounts still active."
    fi
  else
    ui "${GRN}No mountpoints under $(devpath "$dev").${RST}"
  fi
}

select_method() {
  local dev="$1"
  ui ""
  ui "${BOLD}Available erase methods for $(devpath "$dev"):${RST}"
  ui ""

  local rec_index=-1
  for i in "${!METHOD_ID[@]}"; do
    local tag=""
    if [[ "${METHOD_REC[$i]}" == "yes" ]]; then
      tag=" ${GRN}[RECOMMENDED]${RST}"
      rec_index=$((i+1))
    fi
    ui "  [$((i+1))] ${METHOD_LABEL[$i]}$tag"
    ui "      ${DIM}${METHOD_NOTES[$i]}${RST}"
  done

  ui ""
  if ((rec_index > 0)); then
    ui "${DIM}Recommended: option #$rec_index${RST}"
  fi

  local choice prompt
  if ((rec_index > 0)); then
    prompt="Select method [Enter=${rec_index}] (number, 'b' back, 'q' quit): "
  else
    prompt="Select method (number, 'b' back, 'q' quit): "
  fi
  while true; do
    read -r -p "$prompt" choice >&2
    if [[ -z "$choice" && rec_index -gt 0 ]]; then
      choice="$rec_index"
    fi
    [[ "$choice" == "q" || "$choice" == "Q" ]] && { printf "%s\n" "QUIT"; return 0; }
    [[ "$choice" == "b" || "$choice" == "B" ]] && { printf "%s\n" "BACK"; return 0; }
    [[ "$choice" =~ ^[0-9]+$ ]] || { ui "${YEL}Invalid input '${choice}' – enter a number, 'b' or 'q'.${RST}"; continue; }
    (( choice >= 1 && choice <= ${#METHOD_ID[@]} )) || { ui "${YEL}No such method: ${choice} (valid: 1–${#METHOD_ID[@]}).${RST}"; continue; }
    printf "%s\n" "$choice"
    return 0
  done
}

double_confirm_device() {
  local dev="$1"
  ui ""
  ui "${RED}${BOLD}FINAL SAFETY CHECK${RST}"
  ui "Device: ${BOLD}$(devpath "$dev")${RST}"
  read -r -p "Type the device name to confirm (e.g., '$dev'): " typed >&2
  [[ "$typed" == "$dev" ]] || die "Confirmation failed. Aborting."
}

has_real_command_lines() {
  local block="$1"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    return 0
  done <<<"$block"
  return 1
}

run_or_print() {
  local dev="$1" category="$2" method_index="$3"
  local i=$((method_index-1))

  # Handle deferred ATA Secure Erase
  if [[ "${METHOD_CMDS[$i]}" == "__DEFERRED_ATA__" ]]; then
    if ! resolve_ata_secure_erase "$dev"; then
      ui ""
      ui "${CYA}Returning to method selection.${RST}"
      return 1
    fi
  fi

  ui ""
  ui "${BOLD}Method:${RST} ${METHOD_LABEL[$i]}"
  ui "${BOLD}Note:${RST} ${METHOD_NOTES[$i]}"

  print_security_rating "${METHOD_SECURITY[$i]}"

  ui ""
  ui "${BOLD}Command(s):${RST}"
  ui "------------------------------------------------------------"
  uiprintf "$(printf "%b\n" "${METHOD_CMDS[$i]}")\n"
  ui "------------------------------------------------------------"
  ui ""

  read -r -p "EXECUTE now? [y/N]: " ans >&2
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    ui "${CYA}Not executed.${RST} Copy/paste the command(s) above when ready."
    return 0
  fi

  has_cmd sudo || die "sudo not found."

  double_confirm_device "$dev"

  local cmd_block="${METHOD_CMDS[$i]}"

  if ! has_real_command_lines "$cmd_block"; then
    die "No executable commands (missing tools?)."
  fi

  ui ""
  ui "${YEL}Executing...${RST}"
  ui ""

  local mid="${METHOD_ID[$i]}"
  local err_log
  err_log="$(mktemp)"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    ui "${DIM}>>${RST} $line"

    : > "$err_log"
    local rc=0 child_pid
    bash -c "$line" 2> >(tee -a "$err_log" >&2) &
    child_pid=$!
    trap 'ui ""; ui "${YEL}Cancel requested — sending SIGTERM (SIGKILL in 3s)...${RST}"; kill_tree '"$child_pid"' TERM; ( sleep 3; kill_tree '"$child_pid"' KILL ) >/dev/null 2>&1 &' INT
    wait "$child_pid"
    rc=$?
    trap - INT

    if (( rc != 0 )); then
      # dd zero-fill on a whole device: ENOSPC is the expected completion
      # signal (device is full = fully overwritten), not a real error.
      if [[ "$mid" == "dd_zero" ]] && grep -q "No space left on device" "$err_log" 2>/dev/null; then
        ui "${DIM}(dd finished successfully.)${RST}"
        continue
      fi
      rm -f "$err_log"
      ui ""
      ui "${RED}Command failed (exit code ${rc}). Aborting.${RST}"
      return 2
    fi
  done < <(printf '%b\n' "$cmd_block")

  rm -f "$err_log"

  ui ""
  ui "${GRN}Done.${RST}"

  # Offer verification for methods where it makes sense
  if [[ "$mid" == "dd_zero" || "$mid" == "shred" || "$mid" == "blkdiscard" ]]; then
    verify_erase "$dev"
  else
    ui "${DIM}(Verification not meaningful for controller-level erase.)${RST}"
  fi
}

# ---------- Mode selection ----------
select_mode() {
  ui ""
  ui "${BOLD}What do you want to do?${RST}"
  ui ""
  ui "  ${BOLD}[1]${RST} List Devices    – show all detected disks and partitions"
  ui "  ${BOLD}[2]${RST} Secure Erase    – wipe entire disk (HDD/SSD/NVMe/USB)"
  ui "  ${BOLD}[3]${RST} Wipe Free Space – zero free blocks on a mounted/unmounted partition"
  ui ""

  local choice
  while true; do
    read -r -p "Select mode (1/2/3, 'q' quit): " choice >&2
    [[ "$choice" == "q" || "$choice" == "Q" ]] && { printf "%s\n" "QUIT"; return 0; }
    [[ "$choice" == "1" ]] && { printf "%s\n" "LIST"; return 0; }
    [[ "$choice" == "2" ]] && { printf "%s\n" "ERASE"; return 0; }
    [[ "$choice" == "3" ]] && { printf "%s\n" "FREESPACE"; return 0; }
    ui "${YEL}Invalid input '${choice}' – enter 1, 2 or 3.${RST}"
  done
}

list_devices_flow() {
  bus_rescan
  detect_system_devices
  list_block_devices

  ui ""
  ui "${BOLD}Detected storage devices:${RST}"
  ui ""
  uiprintf "  ${DIM}%-12s %6s  %-6s %-5s %-20s${RST}\n" "DEVICE" "SIZE" "TYPE" "TRAN" "MODEL"

  if ((${#DEV_NAMES[@]} == 0)); then
    ui "  ${YEL}No block devices found.${RST}"
  else
    local i
    for i in "${!DEV_NAMES[@]}"; do
      local marker=""
      is_system_device "${DEV_NAMES[$i]}" && marker=" ${RED}[SYSTEM]${RST}"
      uiprintf "  %-12s %6s  %-6s %-5s %-20s%b\n" \
        "${DEV_NAMES[$i]}" \
        "${DEV_SIZES[$i]}" \
        "${DEV_CATEGORIES[$i]}" \
        "${DEV_TRANS[$i]}" \
        "${DEV_MODELS[$i]}" \
        "$marker"
    done
  fi

  list_partitions_with_fs
  ui ""
  ui "${BOLD}Partitions with filesystem:${RST}"
  ui ""
  uiprintf "  ${DIM}%-12s %6s  %-7s %-10s %-18b %-20s${RST}\n" "DEVICE" "SIZE" "TYPE" "FSTYPE" "STATUS" "MOUNTPOINT"

  if ((${#PART_NAMES[@]} == 0)); then
    ui "  ${DIM}none${RST}"
  else
    local i
    for i in "${!PART_NAMES[@]}"; do
      local status mp="${PART_MOUNTS[$i]}" marker=""
      if [[ -n "$mp" ]]; then
        status="${GRN}mounted${RST}"
      else
        status="${YEL}unmounted${RST}"
        mp="-"
      fi
      is_system_partition "${PART_MOUNTS[$i]}" "${PART_PARENTS[$i]}" && marker=" ${RED}[SYSTEM]${RST}"
      uiprintf "  %-12s %6s  %-7s %-10s %-26b %-20s%b\n" \
        "${PART_NAMES[$i]}" \
        "${PART_SIZES[$i]}" \
        "${PART_TYPES[$i]}" \
        "${PART_FSTYPES[$i]}" \
        "$status" \
        "$mp" \
        "$marker"
    done
  fi

  ui ""
  read -r -p "Press Enter to return to the main menu... " _ >&2
}

secure_erase_flow() {
  while true; do
    local selection dev category
    selection="$(select_device)" || return 0
    [[ "$selection" == "QUIT" ]] && exit 0

    if [[ "$selection" == "BACK" ]]; then
      return 0
    fi

    if [[ "$selection" == "RESCAN" ]]; then
      ui ""
      ui "${CYA}Rescanning devices...${RST}"
      bus_rescan
      detect_system_devices
      continue
    fi

    dev="${selection%%|*}"
    category="${selection##*|}"

    show_device_summary "$dev" "$category"
    confirm_system_disk "$dev"
    confirm_safe_state "$dev"
    build_methods_for_device "$dev" "$category"

    local go_back=false
    while true; do
      local method_choice
      method_choice="$(select_method "$dev")" || return 0
      [[ "$method_choice" == "QUIT" ]] && exit 0

      if [[ "$method_choice" == "BACK" ]]; then
        go_back=true
        break
      fi

      if [[ -z "$method_choice" ]]; then
        die "Internal error: empty method selection."
      fi

      run_or_print "$dev" "$category" "$method_choice" || continue

      ui ""
      read -r -p "Choose another method for the same device? [y/N]: " again >&2
      [[ "$again" =~ ^[Yy]$ ]] || break
    done

    [[ "$go_back" == "true" ]] && continue

    ui ""
    read -r -p "Select another device? [y/N]: " another >&2
    [[ "$another" =~ ^[Yy]$ ]] || return 0
  done
}

# ---------- Main ----------
main() {
  print_header
  detect_system_devices

  while true; do
    local mode
    mode="$(select_mode)" || exit 0
    [[ "$mode" == "QUIT" ]] && exit 0

    case "$mode" in
      LIST)      list_devices_flow ;;
      ERASE)     secure_erase_flow ;;
      FREESPACE) freespace_wipe_flow ;;
    esac
  done
}

main "$@"
