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
  elif [[ "${tran:-}" == "usb" && "${rm:-0}" == "1" ]]; then
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

detect_system_devices() {
  SYSTEM_DEVICES=()
  local dev

  dev="$(get_base_device_for_mount / 2>/dev/null)" || true
  [[ -n "$dev" ]] && SYSTEM_DEVICES+=("$dev")

  dev="$(get_base_device_for_mount /boot 2>/dev/null)" || true
  if [[ -n "$dev" ]]; then
    # Avoid duplicates
    local found=false
    for d in "${SYSTEM_DEVICES[@]}"; do
      [[ "$d" == "$dev" ]] && found=true
    done
    [[ "$found" == "false" ]] && SYSTEM_DEVICES+=("$dev")
  fi
}

is_system_device() {
  local dev="$1"
  for d in "${SYSTEM_DEVICES[@]}"; do
    [[ "$d" == "$dev" ]] && return 0
  done
  return 1
}

# ---------- List all block devices ----------
# Stores device info in parallel arrays for structured access
declare -a DEV_NAMES DEV_SIZES DEV_CATEGORIES DEV_TRANS DEV_MODELS DEV_SERIALS

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
        "Overwrite with zeros (slow)" \
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
        "Overwrite with zeros (slow, unreliable on SSDs)" \
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
        "Overwrite with zeros" \
        "no" \
        "sudo dd if=/dev/zero of=$(devpath "$dev") bs=16M status=progress oflag=direct\nsudo sync" \
        "Single pass with zeros, faster than shred." \
        "★★☆|possible with special equipment|Single pass sufficient per NIST 800-88, residual magnetism theoretically measurable"

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
        "Overwrite with zeros" \
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
      ;;

    *)
      # Unknown: offer generic methods
      add_method \
        "dd_zero" \
        "Overwrite with zeros" \
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
    data="$(sudo dd if="$dev_path" bs=$block_size skip="$pos" count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')"
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
    read -r -p "Select device (number, 'd' rescan, 'q' quit): " choice >&2
    [[ "$choice" == "q" || "$choice" == "Q" ]] && return 1
    [[ "$choice" == "d" || "$choice" == "D" ]] && { printf "%s\n" "RESCAN"; return 0; }
    [[ "$choice" =~ ^[0-9]+$ ]] || { ui "Please enter a number."; continue; }
    (( choice >= 1 && choice <= ${#DEV_NAMES[@]} )) || { ui "Out of range."; continue; }

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

  local choice
  while true; do
    read -r -p "Select method (number, 'b' back, 'q' quit): " choice >&2
    [[ "$choice" == "q" || "$choice" == "Q" ]] && return 1
    [[ "$choice" == "b" || "$choice" == "B" ]] && { printf "%s\n" "BACK"; return 0; }
    [[ "$choice" =~ ^[0-9]+$ ]] || { ui "Please enter a number."; continue; }
    (( choice >= 1 && choice <= ${#METHOD_ID[@]} )) || { ui "Out of range."; continue; }
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

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    ui "${DIM}>>${RST} $line"
    if ! bash -c "$line"; then
      ui ""
      ui "${RED}Command failed (exit code $?). Aborting.${RST}"
      return 2
    fi
  done < <(printf '%b\n' "$cmd_block")

  ui ""
  ui "${GRN}Done.${RST}"

  # Offer verification for methods where it makes sense
  local mid="${METHOD_ID[$i]}"
  if [[ "$mid" == "dd_zero" || "$mid" == "shred" || "$mid" == "blkdiscard" ]]; then
    verify_erase "$dev"
  else
    ui "${DIM}(Verification not meaningful for controller-level erase.)${RST}"
  fi
}

# ---------- Main ----------
main() {
  print_header
  detect_system_devices

  while true; do
    local selection dev category
    selection="$(select_device)" || exit 0

    if [[ "$selection" == "RESCAN" ]]; then
      ui ""
      ui "${CYA}Rescanning devices...${RST}"
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
      method_choice="$(select_method "$dev")" || exit 0

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

    if [[ "$go_back" == "true" ]]; then
      continue
    fi

    ui ""
    read -r -p "Select another device? [y/N]: " another >&2
    [[ "$another" =~ ^[Yy]$ ]] || exit 0
  done
}

main "$@"
