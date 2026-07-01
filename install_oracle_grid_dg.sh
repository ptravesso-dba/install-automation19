#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
VARS_FILE="${SCRIPT_DIR}/oracle_grid_dg_vars.conf"
LOG_DIR="${SCRIPT_DIR}/logs"
STATUS_DIR="${SCRIPT_DIR}/status"
mkdir -p "$LOG_DIR" "$STATUS_DIR"
STATUS_FILE="${STATUS_DIR}/oracle_grid_dg_install.status"
CHECKPOINT_FILE="${STATUS_DIR}/oracle_grid_dg_install.checkpoint"
TMUX_SESSION_NAME="oracle_grid_dg_install"
LOG_FILE="${LOG_DIR}/oracle_grid_dg_install_$(date +%Y%m%d_%H%M%S).log"
START_TIME="$(date '+%F %T %Z')"
CHECK_MODE=0
DISCOVER_MODE=0
ASSUME_YES=0
SHOW_STATUS=0
CLEAR_CHECKPOINTS=0
ADOPT_STATE=0
RESET_ASM_DATA_LABELS=0
CURRENT_STEP=0
CURRENT_PHASE="initializing"
TOTAL_STEPS=22
LAST_SUCCESSFUL_STEP="none"
NEXT_EXPECTED_STEP="pre-checks"
OS_DISK=""
U01_DISK_NORM=""
U02_DISK_NORM=""
RECO_DISK_NORM=""
DATA_DISKS_NORM=""
CREATE_U01_DECISION="unknown"
CREATE_U02_DECISION="unknown"

GRID_ZIP="LINUX.X64_193000_grid_home.zip"
DB_ZIP="LINUX.X64_193000_db_home.zip"
OPATCH_ZIP="Opatch_p6880880_190000_Linux-x86-64-12.2.0.1.42-Abr2024.zip"
RU_ZIP="p35642822_190000_19.21.0.0.0_Grid_Linux-x86-64.zip"
RU_DIR="/home/oracle/35642822"

usage() {
  cat <<'EOF'
Usage:
  /root/script/install/install_oracle_grid_dg.sh --discover
  /root/script/install/install_oracle_grid_dg.sh --check
  /root/script/install/install_oracle_grid_dg.sh --status
  /root/script/install/install_oracle_grid_dg.sh --clear-checkpoints
  /root/script/install/install_oracle_grid_dg.sh --adopt-current-state
  /root/script/install/install_oracle_grid_dg.sh --reset-asm-data-labels --yes
  /root/script/install/install_oracle_grid_dg.sh [--yes]

Options:
  --discover  Read-only disk, mount, LVM, filesystem, and installer discovery.
  --check     Read-only validation. No installation or destructive actions.
  --status    Show current status file and latest log path.
  --clear-checkpoints
              Remove only the resume checkpoint file. Does not change Oracle files.
  --adopt-current-state
              Detect completed work and write resume checkpoints only.
  --reset-asm-data-labels
              Destructively clear expected DATA oracleasm labels from DATA_DISKS only.
  --yes       Assume yes for prompts. Required for detached tmux runs.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --discover) DISCOVER_MODE=1 ;;
    --check) CHECK_MODE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --status) SHOW_STATUS=1 ;;
    --clear-checkpoints) CLEAR_CHECKPOINTS=1 ;;
    --adopt-current-state) ADOPT_STATE=1 ;;
    --reset-asm-data-labels) RESET_ASM_DATA_LABELS=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

show_status() {
  if [[ -f "$STATUS_FILE" ]]; then
    cat "$STATUS_FILE"
  else
    echo "No status file found at $STATUS_FILE"
  fi
  echo
  echo "Checkpoint file:"
  if [[ -f "$CHECKPOINT_FILE" ]]; then
    cat "$CHECKPOINT_FILE"
  else
    echo "No checkpoint file found at $CHECKPOINT_FILE"
  fi
  echo
  echo "Latest log:"
  ls -1t "$LOG_DIR"/oracle_grid_dg_install_*.log 2>/dev/null | head -1 || true
}

if [[ "$CLEAR_CHECKPOINTS" -eq 1 ]]; then
  rm -f "$CHECKPOINT_FILE"
  echo "Removed checkpoint file: $CHECKPOINT_FILE"
  exit 0
fi

if [[ "$SHOW_STATUS" -eq 1 ]]; then
  show_status
  exit 0
fi

exec > >(tee -a "$LOG_FILE") 2>&1

on_error() {
  local line="$1"
  local cmd="$2"
  local exit_code="$3"
  echo
  echo "ERROR: installation failed"
  echo "Failed step: ${CURRENT_STEP}/${TOTAL_STEPS} - ${CURRENT_PHASE}"
  echo "Line: $line"
  echo "Command/function: $cmd"
  echo "Exit code: $exit_code"
  echo "Log file: $LOG_FILE"
  echo "Suggested tmux reattach:"
  echo "  tmux attach -t $TMUX_SESSION_NAME"
  echo "Inspect last log lines:"
  echo "  tail -100 $LOG_FILE"
  update_status "$CURRENT_STEP" "$CURRENT_PHASE" "$(( CURRENT_STEP * 100 / TOTAL_STEPS ))" "$LAST_SUCCESSFUL_STEP" "$NEXT_EXPECTED_STEP" "failed"
  exit "$exit_code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND" "$?"' ERR

if [[ ! -r "$VARS_FILE" ]]; then
  echo "Variables file not found or unreadable: $VARS_FILE" >&2
  exit 1
fi
# shellcheck source=/root/script/install/oracle_grid_dg_vars.conf
source "$VARS_FILE"

HOST_ALIAS="${HOST_ALIAS:-dg01}"
IS_STANDBY="${IS_STANDBY:-no}"
PRIMARY_HOST_IP="${PRIMARY_HOST_IP:-192.168.3.65}"
PRIMARY_HOSTNAME_SHORT="${PRIMARY_HOSTNAME_SHORT:-oracle-dg01}"
PRIMARY_HOSTNAME_FQDN="${PRIMARY_HOSTNAME_FQDN:-oracle-dg01.localdomain}"
PRIMARY_HOST_ALIAS="${PRIMARY_HOST_ALIAS:-dg01}"

update_status() {
  local step="$1"
  local phase="$2"
  local pct="$3"
  local last_ok="$4"
  local next_step="$5"
  local state="${6:-running}"
  {
    echo "state=$state"
    echo "current_phase=$phase"
    echo "current_step=$step"
    echo "percentage=$pct"
    echo "start_time=$START_TIME"
    echo "last_update_time=$(date '+%F %T %Z')"
    echo "log_file=$LOG_FILE"
    echo "last_successful_step=$last_ok"
    echo "next_expected_step=$next_step"
  } > "$STATUS_FILE"
}

checkpoint_key() {
  printf 'step_%02d' "$1"
}

checkpoint_done() {
  local key="$1"
  [[ -f "$CHECKPOINT_FILE" ]] && grep -qE "^${key}\\|done\\|" "$CHECKPOINT_FILE"
}

mark_checkpoint() {
  local key="$1"
  local description="$2"
  local tmp="${CHECKPOINT_FILE}.tmp"
  mkdir -p "$STATUS_DIR"
  if [[ -f "$CHECKPOINT_FILE" ]]; then
    grep -vE "^${key}\\|" "$CHECKPOINT_FILE" > "$tmp" || true
  else
    : > "$tmp"
  fi
  printf '%s|done|%s|%s\n' "$key" "$(date '+%F %T %Z')" "$description" >> "$tmp"
  sort -V "$tmp" > "$CHECKPOINT_FILE"
  rm -f "$tmp"
}

unmark_checkpoint() {
  local key="$1"
  local tmp="${CHECKPOINT_FILE}.tmp"
  [[ -f "$CHECKPOINT_FILE" ]] || return 0
  grep -vE "^${key}\\|" "$CHECKPOINT_FILE" > "$tmp" || true
  mv "$tmp" "$CHECKPOINT_FILE"
}

phase() {
  local step="$1"
  local title="$2"
  local next="${3:-}"
  CURRENT_STEP="$step"
  CURRENT_PHASE="$title"
  NEXT_EXPECTED_STEP="$next"
  local pct=$(( step * 100 / TOTAL_STEPS ))
  printf '\n[%02d/%02d - %02d%%] %s\n' "$step" "$TOTAL_STEPS" "$pct" "$title"
  update_status "$step" "$title" "$pct" "$LAST_SUCCESSFUL_STEP" "$NEXT_EXPECTED_STEP"
}

complete_phase() {
  LAST_SUCCESSFUL_STEP="${CURRENT_STEP}/${TOTAL_STEPS} - ${CURRENT_PHASE}"
  update_status "$CURRENT_STEP" "$CURRENT_PHASE" "$(( CURRENT_STEP * 100 / TOTAL_STEPS ))" "$LAST_SUCCESSFUL_STEP" "$NEXT_EXPECTED_STEP"
  if [[ "$CHECK_MODE" -eq 0 && "$DISCOVER_MODE" -eq 0 && "$CURRENT_STEP" -gt 0 ]]; then
    mark_checkpoint "$(checkpoint_key "$CURRENT_STEP")" "$CURRENT_PHASE"
  fi
}

run_install_phase() {
  local step="$1"
  local function_name="$2"
  local title="$3"
  local next="${4:-}"
  local key
  key="$(checkpoint_key "$step")"
  if checkpoint_done "$key"; then
    CURRENT_STEP="$step"
    CURRENT_PHASE="$title"
    NEXT_EXPECTED_STEP="$next"
    LAST_SUCCESSFUL_STEP="${step}/${TOTAL_STEPS} - ${title}"
    printf '\n[%02d/%02d - %02d%%] %s\n' "$step" "$TOTAL_STEPS" "$(( step * 100 / TOTAL_STEPS ))" "$title"
    echo "Checkpoint $key is done. Skipping this phase."
    update_status "$step" "$title" "$(( step * 100 / TOTAL_STEPS ))" "$LAST_SUCCESSFUL_STEP" "$NEXT_EXPECTED_STEP" "skipped"
    return 0
  fi
  "$function_name"
}

run_cmd() {
  echo "+ $*"
  "$@"
}

run_cmd_ok() {
  echo "+ $*"
  "$@" || true
}

run_bash() {
  local cmd="$1"
  echo "+ bash -lc $cmd"
  bash -lc "$cmd"
}

run_afd_asmcmd() {
  local args="$1"
  run_bash "export ORACLE_BASE='$ORACLE_BASE'; export ORACLE_HOME='$GRID_HOME'; export PATH='$GRID_HOME/bin':\$PATH; '$GRID_HOME/bin/asmcmd' $args"
}

afd_label_exists() {
  local label="$1"
  blkid -s TYPE -s LABEL -o export 2>/dev/null | awk -F= -v label="$label" '
    $1 == "LABEL" && $2 == label {found_label=1}
    $1 == "TYPE" && $2 == "oracleasm" && found_label {found_type=1}
    found_label && found_type {exit 0}
    END {exit !(found_label && found_type)}
  '
}

run_as_oracle() {
  local cmd="$1"
  local escaped
  escaped=${cmd//\'/\'\\\'\'}
  echo "+ su - oracle -c bash -lc '$cmd'"
  su - oracle -c "bash -lc '$escaped'"
}

run_as_oracle_allow_rc() {
  local cmd="$1"
  shift
  local allowed_codes=("$@")
  local escaped rc allowed
  escaped=${cmd//\'/\'\\\'\'}
  echo "+ su - oracle -c bash -lc '$cmd'"
  if su - oracle -c "bash -lc '$escaped'"; then
    rc=0
  else
    rc=$?
  fi
  for allowed in "${allowed_codes[@]}"; do
    if [[ "$rc" -eq "$allowed" ]]; then
      if [[ "$rc" -ne 0 ]]; then
        echo "Command completed with accepted Oracle installer warning exit code $rc."
      fi
      return 0
    fi
  done
  return "$rc"
}

run_sqlplus_sysasm() {
  local sql="$1"
  run_as_oracle "export ORACLE_HOME='$GRID_HOME'; export ORACLE_SID=+ASM; export PATH='$GRID_HOME/bin':\$PATH; sqlplus -s / as sysasm <<'SQL'
whenever sqlerror exit sql.sqlcode
$sql
exit
SQL"
}

run_sqlplus_sysdba() {
  local sql="$1"
  run_as_oracle "export ORACLE_SID='$ORACLE_SID'; export ORAENV_ASK=NO; . /usr/local/bin/oraenv >/dev/null; sqlplus -s / as sysdba <<'SQL'
whenever sqlerror exit sql.sqlcode
$sql
exit
SQL"
}

run_rman() {
  local rman_cmds="$1"
  run_as_oracle "export ORACLE_SID='$ORACLE_SID'; export ORAENV_ASK=NO; . /usr/local/bin/oraenv >/dev/null; rman target / <<'RMAN'
$rman_cmds
EXIT;
RMAN"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARNING: $*" >&2
}

is_standby_mode() {
  [[ "${IS_STANDBY,,}" == "yes" ]]
}

installation_mode_label() {
  if is_standby_mode; then
    echo "STANDBY PREPARATION"
  else
    echo "PRIMARY"
  fi
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "This script must be executed as root."
}

require_ol8() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found."
  # shellcheck source=/etc/os-release
  source /etc/os-release
  [[ "${ID:-}" == "ol" ]] || die "This host is not Oracle Linux. ID=${ID:-unknown}"
  [[ "${VERSION_ID:-}" == 8* ]] || die "This host is not Oracle Linux 8 compatible. VERSION_ID=${VERSION_ID:-unknown}"
}

print_target_identity() {
  echo "Target safety validation"
  echo "Current user: $(id -un)"
  echo "Current hostname: $(hostnamectl --static 2>/dev/null || hostname)"
  echo "Current FQDN: $(hostname -f 2>/dev/null || true)"
  echo "Current IP addresses:"
  ip -4 -o addr show | awk '{print "  "$2" "$4}'
  echo "/etc/os-release:"
  cat /etc/os-release
  echo "lsblk:"
  lsblk
}

validate_expected_target() {
  print_target_identity
  ip -4 -o addr show | awk '{print $4}' | grep -qE "^${HOST_IP}/" || die "Expected target IP $HOST_IP is not configured on this host."
}

print_installation_mode_summary() {
  echo "Installation mode: $(installation_mode_label)"
  echo "Target host: $HOST_IP"
  if is_standby_mode; then
    echo "DBCA creation: SKIPPED"
    echo "ARCHIVELOG/FORCE LOGGING local database step: SKIPPED"
    echo "RMAN backup step: SKIPPED"
    echo "Stop point: before 1.17.12.1 Criando a instância de Produção"
  else
    echo "DBCA creation: ENABLED"
    echo "ARCHIVELOG/FORCE LOGGING step: ENABLED"
    echo "RMAN backup step: ENABLED"
  fi
}

normalize_disk() {
  local disk="$1"
  if [[ "$disk" == /dev/* ]]; then
    echo "$disk"
  else
    echo "/dev/$disk"
  fi
}

normalize_all_disks() {
  U01_DISK_NORM="$(normalize_disk "$U01_DISK")"
  U02_DISK_NORM="$(normalize_disk "$U02_DISK")"
  RECO_DISK_NORM="$(normalize_disk "$RECO_DISK")"
  local disk normalized=()
  for disk in $DATA_DISKS; do
    normalized+=("$(normalize_disk "$disk")")
  done
  DATA_DISKS_NORM="${normalized[*]}"
}

detect_os_disk() {
  local root_source pk
  root_source="$(findmnt -n -o SOURCE /)"
  pk="$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -1 || true)"
  if [[ -n "$pk" ]]; then
    echo "/dev/$pk"
  else
    lsblk -ndo NAME,TYPE | awk '$2 == "disk" {print "/dev/"$1; exit}'
  fi
}

backing_disk_for_mount() {
  local mount_point="$1"
  local source source_base disk
  source="$(findmnt -n -o SOURCE "$mount_point" 2>/dev/null || true)"
  [[ -n "$source" ]] || return 0
  source_base="$(basename "$source")"
  for disk in /dev/sd*; do
    [[ -b "$disk" ]] || continue
    if lsblk -nr -o NAME "$disk" | grep -qx "$source_base"; then
      echo "$disk"
      return 0
    fi
  done
  echo "$source"
}

mount_is_active() {
  local mount_point="$1"
  findmnt -rn "$mount_point" >/dev/null 2>&1
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "Required file not found: $path"
}

check_installers() {
  require_file "$INSTALLER_SOURCE_DIR/$GRID_ZIP"
  require_file "$INSTALLER_SOURCE_DIR/$DB_ZIP"
  require_file "$INSTALLER_SOURCE_DIR/$OPATCH_ZIP"
  require_file "$INSTALLER_SOURCE_DIR/$RU_ZIP"
}

is_whole_disk() {
  local disk="$1"
  [[ -b "$disk" ]] || return 1
  [[ "$(lsblk -dn -o TYPE "$disk" 2>/dev/null)" == "disk" ]]
}

disk_has_children() {
  local disk="$1"
  [[ "$(lsblk -n -r -o NAME "$disk" | wc -l)" -gt 1 ]]
}

disk_has_mountpoint() {
  local disk="$1"
  if lsblk -nr -o MOUNTPOINT "$disk" | awk 'NF {found=1} END {exit !found}'; then
    return 0
  fi
  return 1
}

disk_has_signature() {
  local disk="$1"
  if blkid "$disk" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

disk_is_pv() {
  local disk="$1"
  local pvs_output
  pvs_output="$(pvs --noheadings -o pv_name 2>/dev/null | awk '{$1=$1};1' || true)"
  if grep -qx "$disk" <<< "$pvs_output"; then
    return 0
  fi
  return 1
}

validate_safe_raw_disk() {
  local disk="$1"
  local role="$2"
  [[ -n "$OS_DISK" ]] || OS_DISK="$(detect_os_disk)"
  [[ "$disk" != "$OS_DISK" ]] || die "$role points to OS disk $OS_DISK. Refusing."
  [[ "$disk" == /dev/sd* ]] || die "$role disk $disk is not a /dev/sd* device. This environment must use /dev/sd* only."
  is_whole_disk "$disk" || die "$role disk $disk does not exist or is not a whole disk."
  disk_has_children "$disk" && die "$role disk $disk already has partitions or child devices."
  disk_has_mountpoint "$disk" && die "$role disk $disk has a mountpoint."
  disk_has_signature "$disk" && die "$role disk $disk already has a filesystem/LVM/signature."
  disk_is_pv "$disk" && die "$role disk $disk is already an LVM PV."
  return 0
}

disk_has_expected_afd_label() {
  local disk="$1"
  local expected_label="$2"
  local label type
  label="$(blkid -s LABEL -o value "$disk" 2>/dev/null || true)"
  type="$(blkid -s TYPE -o value "$disk" 2>/dev/null || true)"
  [[ "$label" == "$expected_label" && "$type" == "oracleasm" ]]
}

validate_safe_raw_or_expected_afd() {
  local disk="$1"
  local role="$2"
  local expected_label="$3"
  if disk_has_expected_afd_label "$disk" "$expected_label"; then
    echo "$role disk $disk already has expected AFD label $expected_label. Treating as resume-safe."
    return 0
  fi
  validate_safe_raw_disk "$disk" "$role"
}

print_disk_plan() {
  cat <<EOF
Disk plan:
  $OS_DISK -> OS disk, will not be touched
  /dev/sdb -> ASM DATA01
  /dev/sdc -> ASM DATA02
  /dev/sdd -> ASM RECO01
  /dev/sde -> unused by default
  /dev/sdf -> /u02, skip creation if already mounted
  /dev/sdg -> /u01, skip creation if already mounted
EOF
}

validate_no_vd_references() {
  local bad_pattern="/dev/v""d"
  if grep -R "$bad_pattern" "$SCRIPT_DIR" >/tmp/oracle_grid_dg_vd_refs.$$ 2>/dev/null; then
    cat /tmp/oracle_grid_dg_vd_refs.$$
    rm -f /tmp/oracle_grid_dg_vd_refs.$$
    die "Forbidden virtio-disk reference found under $SCRIPT_DIR. This environment must use /dev/sd* only."
  fi
  rm -f /tmp/oracle_grid_dg_vd_refs.$$
}

mount_backing_matches_config() {
  local mount_point="$1"
  local configured_disk="$2"
  local backing source source_base
  backing="$(backing_disk_for_mount "$mount_point")"
  [[ "$backing" == "$configured_disk" ]] && return 0
  source="$(findmnt -n -o SOURCE "$mount_point" 2>/dev/null || true)"
  source_base="$(basename "$source")"
  lsblk -nr -o NAME "$configured_disk" 2>/dev/null | grep -qx "$source_base"
}

decide_mount_action() {
  local mount_point="$1"
  local configured_disk="$2"
  local create_if_missing="$3"
  local label="$4"
  if mount_is_active "$mount_point"; then
    if mount_backing_matches_config "$mount_point" "$configured_disk"; then
      echo "$label is already mounted from $configured_disk. Filesystem creation will be skipped."
    else
      warn "$label is mounted, but backing device is $(backing_disk_for_mount "$mount_point"), not configured disk $configured_disk."
      warn "No filesystem creation will be attempted while $label is mounted."
    fi
    if [[ "$label" == "U01" ]]; then
      CREATE_U01_DECISION="skip-mounted"
    elif [[ "$label" == "U02" ]]; then
      CREATE_U02_DECISION="skip-mounted"
    fi
  else
    if [[ "$create_if_missing" == "yes" ]]; then
      echo "$label is not mounted. It will be created from $configured_disk after safe raw disk validation."
      validate_safe_raw_disk "$configured_disk" "${label}_DISK"
      if [[ "$label" == "U01" ]]; then
        CREATE_U01_DECISION="create"
      elif [[ "$label" == "U02" ]]; then
        CREATE_U02_DECISION="create"
      fi
    else
      die "$label mount $mount_point is missing and CREATE_${label}_IF_MISSING is not yes."
    fi
  fi
}

validate_mount_plan() {
  decide_mount_action "$U01_MOUNT_POINT" "$U01_DISK_NORM" "$CREATE_U01_IF_MISSING" "U01"
  decide_mount_action "$U02_MOUNT_POINT" "$U02_DISK_NORM" "$CREATE_U02_IF_MISSING" "U02"
}

discover_mounts_and_disks() {
  normalize_all_disks
  OS_DISK="$(detect_os_disk)"
  print_target_identity
  print_disk_plan
  echo "lsblk -f:"
  lsblk -f
  echo "findmnt $U01_MOUNT_POINT:"
  findmnt "$U01_MOUNT_POINT" || true
  echo "findmnt $U02_MOUNT_POINT:"
  findmnt "$U02_MOUNT_POINT" || true
  echo "blkid:"
  blkid || true
  echo "pvs:"
  pvs || true
  echo "vgs:"
  vgs || true
  echo "lvs:"
  lvs || true
  echo "df -h $U01_MOUNT_POINT $U02_MOUNT_POINT:"
  df -h "$U01_MOUNT_POINT" "$U02_MOUNT_POINT" 2>/dev/null || true
  echo "Detected OS disk: $OS_DISK"
  echo "Detected $U01_MOUNT_POINT backing device: $(backing_disk_for_mount "$U01_MOUNT_POINT")"
  echo "Detected $U02_MOUNT_POINT backing device: $(backing_disk_for_mount "$U02_MOUNT_POINT")"
  echo "Configured U01_DISK: $U01_DISK_NORM"
  echo "Configured U02_DISK: $U02_DISK_NORM"
  validate_mount_plan
  echo "Mount decision for $U01_MOUNT_POINT: $CREATE_U01_DECISION"
  echo "Mount decision for $U02_MOUNT_POINT: $CREATE_U02_DECISION"
  echo "Installer zips in $INSTALLER_SOURCE_DIR:"
  ls -lh "$INSTALLER_SOURCE_DIR"/*.zip 2>/dev/null || true
  validate_no_vd_references
}

validate_disks_for_install() {
  echo "Validating destructive disk targets. This VM uses /dev/sd* disks, matching the source procedure."
  normalize_all_disks
  OS_DISK="$(detect_os_disk)"
  validate_mount_plan
  local disk
  local index=1 label
  for disk in $DATA_DISKS_NORM; do
    label="$(printf 'DATA%02d' "$index")"
    if prelabel_data_afd_enabled; then
      validate_safe_raw_or_expected_afd "$disk" "DATA_DISKS" "$label"
    else
      validate_safe_raw_disk "$disk" "DATA_DISKS"
    fi
    index=$((index + 1))
  done
  validate_safe_raw_or_expected_afd "$RECO_DISK_NORM" "RECO_DISK" "RECO01"
  for disk in $DATA_DISKS_NORM "$RECO_DISK_NORM" "$U01_DISK_NORM" "$U02_DISK_NORM"; do
    [[ "$disk" == /dev/sd* ]] || die "Disk $disk is not a /dev/sd* device for this VM."
  done
  [[ "$AFD_DISKSTRING" != "/dev/v""d"* ]] || die "AFD_DISKSTRING must not use virtio-style devices."
  [[ "$AFD_DISKSTRING" == "/dev/sd*" ]] || warn "AFD_DISKSTRING is $AFD_DISKSTRING. This VM was validated with /dev/sd*."
  validate_no_vd_references
}

check_package_state() {
  local pkgs=(
    net-tools rsync bc wget vim traceroute unzip mlocate telnet tuned
    openssh-clients policycoreutils-python-utils tuned-profiles-oracle
    procps-ng screen rlwrap terminator dos2unix oracle-database-preinstall-19c
    p7zip tmux lvm2 xfsprogs firewalld
  )
  local missing=()
  local pkg
  for pkg in "${pkgs[@]}"; do
    rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    warn "Packages not currently installed: ${missing[*]}"
    warn "The real install will attempt to install them during the OS prerequisites phase."
  else
    echo "All prerequisite RPM checks are already satisfied."
  fi
}

all_required_groups_exist() {
  local group
  for group in oinstall dbaoper dba asmadmin asmoper asmdba; do
    getent group "$group" >/dev/null || return 1
  done
  id oracle >/dev/null 2>&1
}

all_required_home_zips_exist() {
  local zip
  for zip in "$GRID_ZIP" "$DB_ZIP" "$OPATCH_ZIP" "$RU_ZIP"; do
    [[ -f "/home/oracle/$zip" ]] || return 1
  done
}

data_afd_labels_ready() {
  local index=1 disk label
  normalize_all_disks
  for disk in $DATA_DISKS_NORM; do
    label="$(printf 'DATA%02d' "$index")"
    disk_has_expected_afd_label "$disk" "$label" || return 1
    index=$((index + 1))
  done
}

prelabel_data_afd_enabled() {
  [[ "${PRELABEL_DATA_AFD:-no}" == "yes" ]]
}

grid_has_online() {
  if [[ -x "$GRID_HOME/bin/crsctl" ]] && "$GRID_HOME/bin/crsctl" check has >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

grid_rootconfig_sw_only() {
  [[ -f "$GRID_HOME/crs/config/rootconfig.sh" ]] && grep -q '^SW_ONLY=true' "$GRID_HOME/crs/config/rootconfig.sh"
}

grid_config_ready() {
  [[ -x "$GRID_HOME/bin/crsctl" ]] || return 1
  [[ -x "$GRID_HOME/bin/sqlplus" && -s "$GRID_HOME/bin/sqlplus" ]] || return 1
  grid_has_online
}

oracle_can_write_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  su - oracle -c "test -w '$dir'" >/dev/null 2>&1
}

seed_resume_checkpoints() {
  [[ "$CHECK_MODE" -eq 0 && "$DISCOVER_MODE" -eq 0 ]] || return 0
  echo "Seeding resume checkpoints from current host state where possible."
  all_required_groups_exist && mark_checkpoint "step_02" "Creating users and groups"
  rpm -q oracle-database-preinstall-19c tuned-profiles-oracle p7zip unzip rlwrap tmux >/dev/null 2>&1 && mark_checkpoint "step_03" "Installing OS prerequisites"
  firewall-cmd --permanent --zone=public --list-ports 2>/dev/null | grep -qw "1521/tcp" && mark_checkpoint "step_04" "Configuring SELinux and firewall"
  [[ "$(hostnamectl --static 2>/dev/null || true)" == "$HOSTNAME_FQDN" ]] && mark_checkpoint "step_05" "Configuring hostname and /etc/hosts"
  mount_is_active "$U01_MOUNT_POINT" && mount_is_active "$U02_MOUNT_POINT" && mark_checkpoint "step_06" "Configuring /u01 and /u02"
  all_required_home_zips_exist && mark_checkpoint "step_07" "Copying installers to oracle home"
  [[ -f /home/oracle/.bash_profile ]] && grep -q "ORACLE_BASE=$ORACLE_BASE" /home/oracle/.bash_profile && mark_checkpoint "step_08" "Configuring oracle password and .bash_profile"
  if oracle_can_write_dir "$GRID_HOME" && oracle_can_write_dir "$ORACLE_HOME" && oracle_can_write_dir "$INVENTORY_LOCATION"; then
    mark_checkpoint "step_09" "Creating Oracle directories"
  fi
  [[ -x "$GRID_HOME/gridSetup.sh" && -d "$GRID_HOME/OPatch" && -d "$RU_DIR" ]] && mark_checkpoint "step_10" "Preparing Grid home and RU"
  rpm -q cvuqdisk >/dev/null 2>&1 && mark_checkpoint "step_11" "Installing cvuqdisk"
  if prelabel_data_afd_enabled; then
    data_afd_labels_ready && mark_checkpoint "step_12" "Configuring ASM Filter Driver DATA disks"
  else
    if [[ -x "$GRID_HOME/bin/asmcmd" && -f /etc/oracleafd.conf ]] && grep -q "afd_diskstring='$AFD_DISKSTRING'" /etc/oracleafd.conf; then
      mark_checkpoint "step_12" "Configuring ASM Filter Driver DATA disks"
    fi
  fi
  # Do not seed step_13 from file existence alone. A stale response file can
  # contain duplicate template keys and produce a software-only Grid config.
  [[ -x "$INVENTORY_LOCATION/orainstRoot.sh" && -x "$GRID_HOME/root.sh" ]] && mark_checkpoint "grid_software_setup" "Grid software setup generated root scripts"
  grid_has_online && mark_checkpoint "grid_orainst_root" "orainstRoot.sh completed" && mark_checkpoint "grid_root_sh" "Grid root.sh completed"
  return 0
}

validate_vars() {
  local required=(
    HOSTNAME_FQDN HOSTNAME_SHORT HOST_ALIAS HOST_IP ORACLE_SID ORACLE_UNQNAME PDB_NAME
    ORACLE_BASE ORACLE_HOME GRID_HOME INVENTORY_LOCATION INSTALLER_SOURCE_DIR
    ORACLE_USER_PASSWORD SYS_PASSWORD SYSTEM_PASSWORD PDB_ADMIN_PASSWORD
    ASM_SYSASM_PASSWORD ASM_MONITOR_PASSWORD U01_DISK U02_DISK DATA_DISKS RECO_DISK
    U01_MOUNT_POINT U01_VG_NAME U01_LV_NAME U02_MOUNT_POINT U02_VG_NAME U02_LV_NAME
    CREATE_U01_IF_MISSING CREATE_U02_IF_MISSING
    AFD_DISKSTRING DB_CHARACTERSET SGA_TARGET PGA_AGGREGATE_TARGET
    DB_RECOVERY_FILE_DEST_SIZE REDO_LOG_FILE_SIZE_MB
  )
  local var
  for var in "${required[@]}"; do
    [[ -n "${!var:-}" ]] || die "Required variable $var is empty."
  done
  [[ "${IS_STANDBY,,}" == "yes" || "${IS_STANDBY,,}" == "no" ]] || die "IS_STANDBY must be yes or no."
  if is_standby_mode; then
    [[ -n "${PRIMARY_HOST_IP:-}" && -n "${PRIMARY_HOSTNAME_SHORT:-}" && -n "${PRIMARY_HOSTNAME_FQDN:-}" && -n "${PRIMARY_HOST_ALIAS:-}" ]] || die "PRIMARY_HOST_* variables are required when IS_STANDBY=yes."
  fi
  normalize_all_disks
  [[ "$AFD_DISKSTRING" != "/dev/v""d"* ]] || die "AFD_DISKSTRING must not use virtio-style devices."
  [[ "$AFD_DISKSTRING" == "/dev/sd*" ]] || warn "AFD_DISKSTRING is $AFD_DISKSTRING. This VM was validated with /dev/sd*."
  [[ "$RECO_DISK_NORM" != "/dev/sdb" && "$RECO_DISK_NORM" != "/dev/sdc" ]] || die "RECO_DISK must not overlap DATA disks."
  [[ "$RECO_DISK_NORM" != "$U01_DISK_NORM" && "$RECO_DISK_NORM" != "$U02_DISK_NORM" ]] || die "RECO_DISK must not use /u01 or /u02 disks."
  local disk
  for disk in $DATA_DISKS_NORM; do
    [[ "$disk" != "$U01_DISK_NORM" && "$disk" != "$U02_DISK_NORM" ]] || die "DATA disk $disk must not use /u01 or /u02 disks."
  done
  [[ "${PRELABEL_DATA_AFD:-no}" == "yes" || "${PRELABEL_DATA_AFD:-no}" == "no" ]] || die "PRELABEL_DATA_AFD must be yes or no."
}

reset_asm_data_labels() {
  require_root
  require_ol8
  validate_vars
  validate_expected_target
  normalize_all_disks
  echo "This will destructively clear expected oracleasm DATA labels from DATA_DISKS only:"
  local disk index=1 expected label type
  for disk in $DATA_DISKS_NORM; do
    expected="$(printf 'DATA%02d' "$index")"
    label="$(blkid -s LABEL -o value "$disk" 2>/dev/null || true)"
    type="$(blkid -s TYPE -o value "$disk" 2>/dev/null || true)"
    echo "  $disk current LABEL=${label:-none} TYPE=${type:-none} expected=$expected"
    if [[ "$label" != "$expected" || "$type" != "oracleasm" ]]; then
      die "Refusing to reset $disk because it does not have expected label $expected and TYPE=oracleasm."
    fi
    index=$((index + 1))
  done
  if [[ "$ASSUME_YES" -ne 1 ]]; then
    read -r -p "Type YES to wipe expected DATA labels from DATA disks: " answer
    [[ "$answer" == "YES" ]] || die "Cancelled DATA label reset."
  fi
  if lsmod | awk '{print $1}' | grep -qx oracleafd; then
    echo "oracleafd kernel module is loaded. Stopping stale OHAS/AFD services so disk writes can succeed."
    run_cmd_ok systemctl stop oracle-ohasd
    run_cmd_ok systemctl stop ohasd
    run_cmd_ok /etc/init.d/ohasd stop
    run_cmd_ok systemctl stop afd
    run_cmd_ok /etc/init.d/afd stop
    run_cmd_ok rmmod oracleafd
  fi
  for disk in $DATA_DISKS_NORM; do
    run_cmd wipefs -a "$disk"
    run_cmd dd if=/dev/zero of="$disk" bs=1M count=100 conv=fsync
    run_cmd blockdev --rereadpt "$disk"
  done
  run_cmd udevadm settle
  rm -f "$CHECKPOINT_FILE"
  echo "Cleared DATA labels and removed checkpoint file: $CHECKPOINT_FILE"
  echo "Run --check before restarting the installation."
}

prechecks() {
  phase 1 "Pre-checks and safety validation" "Discovering disks and mounts"
  require_root
  require_ol8
  validate_vars
  print_installation_mode_summary
  validate_expected_target
  check_installers
  discover_mounts_and_disks
  validate_disks_for_install
  check_package_state
  complete_phase
}

confirm_real_install_context() {
  [[ "$CHECK_MODE" -eq 0 ]] || return 0
  if [[ -z "${TMUX:-}" ]]; then
    warn "The real installation is not running inside tmux."
    echo "Recommended:"
    echo "  tmux new -s $TMUX_SESSION_NAME"
    echo "  $SCRIPT_PATH --yes"
    if [[ "$ASSUME_YES" -ne 1 ]]; then
      read -r -p "Continue outside tmux? Type YES to continue: " answer
      [[ "$answer" == "YES" ]] || die "Cancelled."
    fi
  fi
}

confirm_destructive_actions() {
  [[ "$CHECK_MODE" -eq 0 ]] || return 0
  echo "The next phases will write to block devices:"
  print_disk_plan
  echo "  U01_DISK=$U01_DISK_NORM decision=$CREATE_U01_DECISION"
  echo "  U02_DISK=$U02_DISK_NORM decision=$CREATE_U02_DECISION"
  echo "  DATA_DISKS=$DATA_DISKS_NORM"
  echo "  RECO_DISK=$RECO_DISK_NORM"
  echo "Destructive commands include pvcreate, mkfs.xfs, and asmcmd afd_label."
  if [[ "$ASSUME_YES" -ne 1 ]]; then
    read -r -p "Type YES to continue with destructive disk operations: " answer
    [[ "$answer" == "YES" ]] || die "Cancelled before destructive operations."
  fi
}

create_group_if_needed() {
  local group="$1"
  local gid="$2"
  if getent group "$group" >/dev/null; then
    echo "Group $group already exists."
  elif getent group "$gid" >/dev/null; then
    warn "GID $gid already exists. Creating $group with the next available GID."
    run_cmd groupadd "$group"
  else
    run_cmd groupadd -g "$gid" "$group"
  fi
}

create_users_groups() {
  phase 2 "Creating users and groups" "Installing OS prerequisites"
  create_group_if_needed oinstall 1001
  create_group_if_needed dbaoper 1002
  create_group_if_needed dba 1003
  create_group_if_needed asmadmin 1004
  create_group_if_needed asmoper 1005
  create_group_if_needed asmdba 1006
  if id oracle >/dev/null 2>&1; then
    echo "User oracle already exists."
  elif getent passwd 101 >/dev/null; then
    warn "UID 101 already exists. Creating oracle with the next available UID."
    run_cmd useradd -g oinstall -G dba,dbaoper oracle
  else
    run_cmd useradd -u 101 -g oinstall -G dba,dbaoper oracle
  fi
  run_cmd usermod -g oinstall -G dba,dbaoper,asmadmin,asmdba,asmoper oracle
  complete_phase
}

install_os_prereqs() {
  phase 3 "Installing OS prerequisites" "Configuring SELinux and firewall"
  local base_pkgs=(net-tools rsync bc wget vim traceroute unzip mlocate telnet tuned openssh-clients policycoreutils-python-utils tmux lvm2 xfsprogs firewalld)
  local oracle_pkgs=(tuned-profiles-oracle procps-ng screen rlwrap terminator dos2unix oracle-database-preinstall-19c p7zip)
  run_cmd dnf install -y "${base_pkgs[@]}"
  run_cmd dnf install -y tuned-profiles-oracle
  run_cmd tuned-adm profile oracle
  run_cmd tuned-adm active
  if ! dnf install -y "${oracle_pkgs[@]}"; then
    warn "Some packages were not available from enabled repositories. Trying EPEL as in the document."
    if ! rpm -q epel-release >/dev/null 2>&1; then
      run_cmd dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
    fi
    run_cmd dnf install -y "${oracle_pkgs[@]}"
  fi
  complete_phase
}

configure_selinux_firewall() {
  phase 4 "Configuring SELinux and firewall" "Configuring hostname and hosts"
  if [[ -f /etc/selinux/config ]]; then
    run_cmd sed -i 's/^SELINUX=enforcing/SELINUX=permissive/i; s/^SELINUX=disabled/SELINUX=permissive/i' /etc/selinux/config
  fi
  if command -v setenforce >/dev/null 2>&1; then
    setenforce 0 || true
  fi
  run_cmd systemctl enable --now firewalld
  firewall-cmd --permanent --zone=public --list-ports || true
  run_cmd firewall-cmd --permanent --zone=public --add-port=1521/tcp
  run_cmd firewall-cmd --reload
  firewall-cmd --permanent --zone=public --list-ports || true
  complete_phase
}

configure_hostname_hosts() {
  phase 5 "Configuring hostname and /etc/hosts" "Configuring /u01 and /u02"
  run_cmd hostnamectl set-hostname "$HOSTNAME_FQDN"
  cp -p /etc/hosts "/etc/hosts.oracle_grid_dg_$(date +%Y%m%d_%H%M%S).bak"
  local managed_line="$HOST_IP $HOSTNAME_SHORT $HOSTNAME_FQDN $HOST_ALIAS"
  local primary_line="$PRIMARY_HOST_IP $PRIMARY_HOSTNAME_SHORT $PRIMARY_HOSTNAME_FQDN $PRIMARY_HOST_ALIAS"
  awk \
    -v ip="$HOST_IP" \
    -v short="$HOSTNAME_SHORT" \
    -v fqdn="$HOSTNAME_FQDN" \
    -v alias="$HOST_ALIAS" \
    -v primary_ip="$PRIMARY_HOST_IP" \
    -v primary_short="$PRIMARY_HOSTNAME_SHORT" \
    -v primary_fqdn="$PRIMARY_HOSTNAME_FQDN" \
    -v primary_alias="$PRIMARY_HOST_ALIAS" '
    $1 == ip {next}
    $1 == primary_ip {next}
    index($0, short) || index($0, fqdn) || index($0, alias) {next}
    index($0, primary_short) || index($0, primary_fqdn) || index($0, primary_alias) {next}
    {print}
  ' /etc/hosts > /etc/hosts.oracle_grid_dg.tmp
  echo "$managed_line" >> /etc/hosts.oracle_grid_dg.tmp
  if is_standby_mode; then
    echo "$primary_line" >> /etc/hosts.oracle_grid_dg.tmp
  fi
  run_cmd install -m 0644 /etc/hosts.oracle_grid_dg.tmp /etc/hosts
  rm -f /etc/hosts.oracle_grid_dg.tmp
  getent hosts "$HOSTNAME_SHORT" "$HOSTNAME_FQDN" || true
  if is_standby_mode; then
    getent hosts "$PRIMARY_HOSTNAME_SHORT" "$PRIMARY_HOSTNAME_FQDN" || true
  fi
  complete_phase
}

create_or_validate_mount() {
  local label="$1"
  local mount_point="$2"
  local disk="$3"
  local vg_name="$4"
  local lv_name="$5"
  local create_if_missing="$6"
  local lv_path="/dev/mapper/${vg_name}-${lv_name}"

  if findmnt -rn "$mount_point" >/dev/null 2>&1; then
    echo "$mount_point is already mounted. Filesystem creation is skipped."
    echo "$mount_point source: $(findmnt -n -o SOURCE "$mount_point")"
    if [[ "$label" == "U01" ]]; then
      run_cmd chown -R oracle:oinstall "$mount_point"
    else
      if id oracle >/dev/null 2>&1 && getent group oinstall >/dev/null; then
        run_cmd chown oracle:oinstall "$mount_point"
      fi
    fi
  else
    [[ "$create_if_missing" == "yes" ]] || die "$mount_point is not mounted and CREATE_${label}_IF_MISSING is not yes."
    validate_safe_raw_disk "$disk" "${label}_DISK"
    confirm_destructive_actions
    if ! pvs "$disk" >/dev/null 2>&1; then
      run_cmd pvcreate "$disk"
    fi
    if ! vgs "$vg_name" >/dev/null 2>&1; then
      run_cmd vgcreate "$vg_name" "$disk"
    elif ! pvs --noheadings -o pv_name,vg_name | awk '{$1=$1};1' | grep -qx "$disk $vg_name"; then
      die "VG $vg_name already exists but is not backed by $disk. Refusing to overwrite."
    fi
    if ! lvs "/dev/$vg_name/$lv_name" >/dev/null 2>&1; then
      run_cmd lvcreate -l +100%free -n "$lv_name" "$vg_name"
    fi
    if ! blkid "$lv_path" >/dev/null 2>&1; then
      run_cmd mkfs.xfs "$lv_path"
    fi
    run_cmd mkdir -p "$mount_point"
    local uuid
    uuid="$(blkid -s UUID -o value "$lv_path")"
    grep -qE "[[:space:]]${mount_point}[[:space:]]" /etc/fstab || echo "UUID=$uuid $mount_point xfs defaults 0 0" >> /etc/fstab
    run_cmd mount -a
    run_cmd systemctl daemon-reload
    if [[ "$label" == "U01" ]]; then
      run_cmd chown -R oracle:oinstall "$mount_point"
    fi
  fi
  df -h "$mount_point"
}

configure_filesystems() {
  phase 6 "Configuring /u01 and /u02" "Moving installers"
  normalize_all_disks
  OS_DISK="$(detect_os_disk)"
  validate_mount_plan
  create_or_validate_mount "U01" "$U01_MOUNT_POINT" "$U01_DISK_NORM" "$U01_VG_NAME" "$U01_LV_NAME" "$CREATE_U01_IF_MISSING"
  create_or_validate_mount "U02" "$U02_MOUNT_POINT" "$U02_DISK_NORM" "$U02_VG_NAME" "$U02_LV_NAME" "$CREATE_U02_IF_MISSING"
  complete_phase
}

move_installers() {
  phase 7 "Copying installers to oracle home" "Configuring oracle password and profile"
  run_cmd mkdir -p /home/oracle
  local zip
  for zip in "$GRID_ZIP" "$DB_ZIP" "$OPATCH_ZIP" "$RU_ZIP"; do
    require_file "$INSTALLER_SOURCE_DIR/$zip"
    if [[ -f "/home/oracle/$zip" ]] && cmp -s "$INSTALLER_SOURCE_DIR/$zip" "/home/oracle/$zip"; then
      echo "/home/oracle/$zip already exists and matches source."
    else
      run_cmd cp -p "$INSTALLER_SOURCE_DIR/$zip" /home/oracle/
    fi
  done
  run_cmd chown oracle:oinstall /home/oracle/*.zip
  complete_phase
}

configure_oracle_profile() {
  phase 8 "Configuring oracle password and .bash_profile" "Creating Oracle directories"
  echo "oracle:${ORACLE_USER_PASSWORD}" | chpasswd
  run_cmd install -o oracle -g oinstall -m 0644 /dev/null /home/oracle/.bash_profile
  cat > /home/oracle/.bash_profile <<EOF
# Alias
alias mv='mv -i'
alias cp='cp -i'
alias rm='rm -i'
alias sql='rlwrap sqlplus / as sysdba'
alias start_oratop='\$ORACLE_HOME/suptools/oratop/oratop -f -i3 / AS SYSDBA'
alias start_oratop_novo='\$ORACLE_HOME/suptools/oratop/oratop_19.21 -f -i3 / AS SYSDBA'

# Oracle Variaveis 19c
export ORACLE_BASE=$ORACLE_BASE
export ORACLE_HOME=$ORACLE_HOME
export GRID_HOME=$GRID_HOME
export CRS_HOME=\$GRID_HOME
export ORACLE_SID=$ORACLE_SID
export ORACLE_UNQNAME=$ORACLE_UNQNAME
export TMP=/tmp
export TMPDIR=\$TMP
export ORACLE_TERM=xterm
export PATH=/usr/sbin:\$PATH
export PATH=\$ORACLE_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib
export CLASSPATH=\$ORACLE_HOME/jlib:\$ORACLE_HOME/rdbms/jlib
export PATH
EOF
  run_cmd chown oracle:oinstall /home/oracle/.bash_profile
  run_cmd chmod 0644 /home/oracle/.bash_profile
  complete_phase
}

create_oracle_dirs() {
  phase 9 "Creating Oracle directories" "Preparing Grid home and RU"
  run_cmd mkdir -p "$GRID_HOME" "$ORACLE_HOME" "$INVENTORY_LOCATION"
  run_cmd chown -R oracle:oinstall /u01/app /home/oracle
  run_cmd chmod -R u+rwX,g+rwX /u01/app
  run_cmd chown oracle:oinstall "$GRID_HOME" "$ORACLE_HOME" "$INVENTORY_LOCATION"
  run_cmd chmod u+rwx,g+rwx "$GRID_HOME" "$ORACLE_HOME" "$INVENTORY_LOCATION"
  complete_phase
}

prepare_grid_home() {
  phase 10 "Preparing Grid home and RU" "Installing cvuqdisk"
  if [[ ! -x "$GRID_HOME/gridSetup.sh" ]]; then
    run_as_oracle "source /home/oracle/.bash_profile; unzip -q -d '$GRID_HOME' '/home/oracle/$GRID_ZIP'"
  else
    echo "Grid home already appears unzipped at $GRID_HOME."
  fi
  if [[ -d "$GRID_HOME/OPatch" && ! -d "$GRID_HOME/OPatch_old" ]]; then
    run_as_oracle "mv '$GRID_HOME/OPatch' '$GRID_HOME/OPatch_old'"
  elif [[ -d "$GRID_HOME/OPatch" ]]; then
    run_as_oracle "rm -rf '$GRID_HOME/OPatch'"
  fi
  run_as_oracle "unzip -q -d '$GRID_HOME' '/home/oracle/$OPATCH_ZIP'"
  if [[ ! -d "$RU_DIR" ]]; then
    run_as_oracle "cd /home/oracle && unzip -q '$RU_ZIP'"
  else
    echo "RU directory $RU_DIR already exists."
  fi
  complete_phase
}

install_cvuqdisk() {
  phase 11 "Installing cvuqdisk" "Configuring ASM Filter Driver DATA disks"
  local rpm_path="$GRID_HOME/cv/rpm/cvuqdisk-1.0.10-1.rpm"
  require_file "$rpm_path"
  if rpm -q cvuqdisk >/dev/null 2>&1; then
    echo "cvuqdisk already installed."
  else
    run_cmd rpm -ivh "$rpm_path"
  fi
  complete_phase
}

repair_generated_grid_home_paths() {
  local wrong_home="/u01/app/19.0.0/grid"
  local file list_file
  [[ -d "$GRID_HOME" ]] || return 0
  list_file="$(mktemp)"
  grep -RIl "$wrong_home" "$GRID_HOME" 2>/dev/null > "$list_file" || true
  if [[ -s "$list_file" ]]; then
    echo "Repairing generated Grid files from $wrong_home to $GRID_HOME."
    echo "Files to repair:"
    sed 's/^/  /' "$list_file"
    while IFS= read -r file; do
      local owner_group mode
      [[ -f "$file" ]] || continue
      owner_group="$(stat -c '%u:%g' "$file")"
      mode="$(stat -c '%a' "$file")"
      run_cmd sed -i "s|$wrong_home|$GRID_HOME|g" "$file"
      run_cmd chown "$owner_group" "$file"
      run_cmd chmod "$mode" "$file"
    done < "$list_file"
  fi
  rm -f "$list_file"
}

configure_afd_data() {
  phase 12 "Configuring ASM Filter Driver DATA disks" "Generating Grid response file"
  normalize_all_disks
  local disk_count
  disk_count="$(wc -w <<< "$DATA_DISKS_NORM")"
  local disk label index=1
  for disk in $DATA_DISKS_NORM; do
    label="$(printf 'DATA%02d' "$index")"
    if prelabel_data_afd_enabled; then
      validate_safe_raw_or_expected_afd "$disk" "DATA disk before AFD label" "$label"
    else
      validate_safe_raw_disk "$disk" "DATA disk before Grid-managed AFD label"
    fi
    index=$((index + 1))
  done
  confirm_destructive_actions
  cat > /etc/oracleafd.conf <<EOF
afd_diskstring='$AFD_DISKSTRING'
afd_dev_count=$disk_count
EOF
  index=1
  for disk in $DATA_DISKS_NORM; do
    run_cmd chown oracle:asmadmin "$disk"
  done
  run_afd_asmcmd "afd_refresh"
  run_afd_asmcmd "afd_scan"
  run_afd_asmcmd "afd_state"
  for disk in $DATA_DISKS_NORM; do
    label="$(printf 'DATA%02d' "$index")"
    if ! prelabel_data_afd_enabled; then
      echo "PRELABEL_DATA_AFD=no. Leaving $disk unlabeled so Grid executeConfigTools can provision DATA."
    elif afd_label_exists "$label"; then
      echo "AFD label $label already exists. Skipping label creation for $disk."
    else
      run_afd_asmcmd "afd_label '$label' '$disk' --init"
    fi
    index=$((index + 1))
  done
  if prelabel_data_afd_enabled; then
    run_afd_asmcmd "afd_lslbl"
  else
    echo "PRELABEL_DATA_AFD=no. Skipping afd_lslbl until Grid executeConfigTools configures AFD labels."
  fi
  rm -rf /u01/app/oracle/diag/
  complete_phase
}

csv_from_words() {
  local out="" item
  for item in "$@"; do
    out="${out:+$out,}$item"
  done
  echo "$out"
}

fg_names_from_words() {
  local out="" item
  for item in "$@"; do
    out="${out:+$out,}${item},"
  done
  echo "$out"
}

strip_grid_response_managed_keys() {
  local rsp="$1"
  local tmp
  tmp="$(mktemp)"
  awk -F= '
    BEGIN {
      split("INVENTORY_LOCATION oracle.install.option ORACLE_BASE oracle.install.asm.OSDBA oracle.install.asm.OSOPER oracle.install.asm.OSASM oracle.install.crs.config.scanType oracle.install.crs.config.ClusterConfiguration oracle.install.crs.config.configureAsExtendedCluster oracle.install.crs.config.gpnp.configureGNS oracle.install.crs.config.autoConfigureClusterNodeVIP oracle.install.crs.config.gpnp.gnsOption oracle.install.crs.configureGIMR oracle.install.asm.configureGIMRDataDG oracle.install.crs.config.useIPMI oracle.install.asm.diskGroup.name oracle.install.asm.diskGroup.redundancy oracle.install.asm.diskGroup.AUSize oracle.install.asm.gimrDG.AUSize oracle.install.asm.configureAFD oracle.install.crs.configureRHPS oracle.install.crs.config.ignoreDownNodes oracle.install.config.managementOption oracle.install.config.omsPort oracle.install.crs.rootconfig.executeRootScript oracle.install.asm.diskGroup.disksWithFailureGroupNames oracle.install.asm.diskGroup.disks oracle.install.asm.diskGroup.diskDiscoveryString oracle.install.asm.SYSASMPassword oracle.install.asm.monitorPassword", keys, " ")
      for (i in keys) managed[keys[i]]=1
    }
    !($1 in managed) { print }
  ' "$rsp" > "$tmp"
  cat "$tmp" > "$rsp"
  rm -f "$tmp"
}

generate_grid_response() {
  phase 13 "Generating Grid response file" "Running silent Grid installation"
  local disks_array data_disks_csv failure_groups
  normalize_all_disks
  read -r -a disks_array <<< "$DATA_DISKS_NORM"
  data_disks_csv="$(csv_from_words "${disks_array[@]}")"
  failure_groups="$(fg_names_from_words "${disks_array[@]}")"
  run_as_oracle "cp '$GRID_HOME/install/response/gridsetup.rsp' /home/oracle/gridsetup.rsp"
  strip_grid_response_managed_keys /home/oracle/gridsetup.rsp
  cat >> /home/oracle/gridsetup.rsp <<EOF
#### CONFIG PERSONALIZADA
INVENTORY_LOCATION=$INVENTORY_LOCATION
oracle.install.option=HA_CONFIG
ORACLE_BASE=$ORACLE_BASE
oracle.install.asm.OSDBA=asmdba
oracle.install.asm.OSOPER=asmoper
oracle.install.asm.OSASM=asmadmin
oracle.install.crs.config.scanType=LOCAL_SCAN
oracle.install.crs.config.ClusterConfiguration=STANDALONE
oracle.install.crs.config.configureAsExtendedCluster=false
oracle.install.crs.config.gpnp.configureGNS=false
oracle.install.crs.config.autoConfigureClusterNodeVIP=false
oracle.install.crs.config.gpnp.gnsOption=CREATE_NEW_GNS
oracle.install.crs.configureGIMR=false
oracle.install.asm.configureGIMRDataDG=false
oracle.install.crs.config.useIPMI=false
oracle.install.asm.diskGroup.name=DATA
oracle.install.asm.diskGroup.redundancy=EXTERNAL
oracle.install.asm.diskGroup.AUSize=4
oracle.install.asm.gimrDG.AUSize=1
oracle.install.asm.configureAFD=true
oracle.install.crs.configureRHPS=false
oracle.install.crs.config.ignoreDownNodes=false
oracle.install.config.managementOption=NONE
oracle.install.config.omsPort=0
oracle.install.crs.rootconfig.executeRootScript=false
oracle.install.asm.diskGroup.disksWithFailureGroupNames=$failure_groups
oracle.install.asm.diskGroup.disks=$data_disks_csv
oracle.install.asm.diskGroup.diskDiscoveryString=$AFD_DISKSTRING
oracle.install.asm.SYSASMPassword=$ASM_SYSASM_PASSWORD
oracle.install.asm.monitorPassword=$ASM_MONITOR_PASSWORD
EOF
  run_cmd chown oracle:oinstall /home/oracle/gridsetup.rsp
  run_cmd chmod 0600 /home/oracle/gridsetup.rsp
  complete_phase
}

silent_grid_install() {
  phase 14 "Running silent Grid installation" "Adjusting AFD init dependencies"
  if checkpoint_done "grid_software_setup"; then
    echo "Checkpoint grid_software_setup is done. Skipping initial gridSetup.sh software step."
  elif [[ -x "$INVENTORY_LOCATION/orainstRoot.sh" && -x "$GRID_HOME/root.sh" ]]; then
    echo "Grid software setup already produced root scripts. Skipping initial gridSetup.sh software step."
    mark_checkpoint "grid_software_setup" "Grid software setup generated root scripts"
  else
    run_as_oracle_allow_rc "source /home/oracle/.bash_profile; export ORACLE_HOME='$GRID_HOME'; export PATH='$GRID_HOME/bin':\$PATH; export LD_LIBRARY_PATH='$GRID_HOME/lib':/lib:/usr/lib; cd '$GRID_HOME' && ./gridSetup.sh -silent -responseFile /home/oracle/gridsetup.rsp -applyRU '$RU_DIR'" 0 6
    mark_checkpoint "grid_software_setup" "Grid software setup generated root scripts"
  fi
  repair_generated_grid_home_paths

  if grid_rootconfig_sw_only; then
    echo "Grid root scripts are still software-only. Running Grid configuration wizard with the response file."
    unmark_checkpoint "grid_root_sh"
    unmark_checkpoint "grid_execute_config_tools"
    run_as_oracle_allow_rc "source /home/oracle/.bash_profile; export ORACLE_HOME='$GRID_HOME'; export PATH='$GRID_HOME/bin':\$PATH; export LD_LIBRARY_PATH='$GRID_HOME/lib':/lib:/usr/lib; cd '$GRID_HOME' && ./gridSetup.sh -silent -responseFile /home/oracle/gridsetup.rsp" 0 6
    repair_generated_grid_home_paths
  fi

  if checkpoint_done "grid_orainst_root"; then
    echo "Checkpoint grid_orainst_root is done. Skipping $INVENTORY_LOCATION/orainstRoot.sh."
  else
    run_cmd "$INVENTORY_LOCATION/orainstRoot.sh"
    mark_checkpoint "grid_orainst_root" "orainstRoot.sh completed"
  fi
  if checkpoint_done "grid_root_sh"; then
    if grid_config_ready; then
      echo "Checkpoint grid_root_sh is done and Grid is online. Skipping $GRID_HOME/root.sh."
    else
      echo "Checkpoint grid_root_sh is stale because Grid is not online. Re-running $GRID_HOME/root.sh."
      unmark_checkpoint "grid_root_sh"
      run_cmd "$GRID_HOME/root.sh"
      repair_generated_grid_home_paths
      grid_rootconfig_sw_only && die "Grid root script is still software-only after configuration wizard. Check /home/oracle/gridsetup.rsp and Grid setup logs."
      mark_checkpoint "grid_root_sh" "Grid root.sh completed"
    fi
  elif grid_has_online; then
    echo "Oracle High Availability Services is already online. Treating $GRID_HOME/root.sh as completed."
    mark_checkpoint "grid_root_sh" "Grid root.sh completed"
  else
    run_cmd "$GRID_HOME/root.sh"
    repair_generated_grid_home_paths
    grid_rootconfig_sw_only && die "Grid root script is still software-only after root.sh. Check /home/oracle/gridsetup.rsp and Grid setup logs."
    mark_checkpoint "grid_root_sh" "Grid root.sh completed"
  fi
  if checkpoint_done "grid_execute_config_tools"; then
    if grid_config_ready; then
      echo "Checkpoint grid_execute_config_tools is done and Grid is online. Skipping Grid executeConfigTools."
    else
      echo "Checkpoint grid_execute_config_tools is stale because Grid is not online. Re-running Grid executeConfigTools."
      unmark_checkpoint "grid_execute_config_tools"
      run_as_oracle "'$GRID_HOME/gridSetup.sh' -executeConfigTools -responseFile /home/oracle/gridsetup.rsp -silent"
      grid_config_ready || die "Grid executeConfigTools finished, but Grid is not online or sqlplus is not executable. Check the latest GridSetupActions log."
      mark_checkpoint "grid_execute_config_tools" "Grid executeConfigTools completed"
    fi
  else
    run_as_oracle "'$GRID_HOME/gridSetup.sh' -executeConfigTools -responseFile /home/oracle/gridsetup.rsp -silent"
    grid_config_ready || die "Grid executeConfigTools finished, but Grid is not online or sqlplus is not executable. Check the latest GridSetupActions log."
    mark_checkpoint "grid_execute_config_tools" "Grid executeConfigTools completed"
  fi
  complete_phase
}

adjust_afd_init() {
  phase 15 "Adjusting AFD init dependencies" "Creating Grid alert links and glogin"
  if [[ -f /etc/init.d/afd ]]; then
    run_cmd cp -p /etc/init.d/afd /root/afd.org-backup
    run_cmd sed -i '/\# Required-Start/ s~\:.*$~\: \$network \$syslog \$remote_fs~' /etc/init.d/afd
    run_cmd sed -i '/\# Should-Start/ s~\:.*$~\: open_iscsi~' /etc/init.d/afd
    run_cmd sed -i '/\# Required-Stop/ s~\:.*$~\: \$network \$syslog \$remote_fs~' /etc/init.d/afd
    run_cmd sed -i '/\# Should-Stop/ s~\:.*$~\: open_iscsi ohasd~' /etc/init.d/afd
    diff /root/afd.org-backup /etc/init.d/afd | tee /root/afd.diff || true
  else
    die "/etc/init.d/afd not found after Grid root.sh."
  fi
  complete_phase
}

write_glogin() {
  local target="$1"
  cat > "$target" <<'EOF'
SET PAGESIZE 1000
SET LINESIZE 220
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
DEFINE _EDITOR = /usr/bin/vim
COLUMN segment_name FORMAT A30 WORD_WRAP
COLUMN object_name FORMAT A30 WORD_WRAP
SET TIMING ON
SET TIME ON
SET SQLPROMPT "_USER'@'_CONNECT_IDENTIFIER > "
COL DISK_GROUP_NAME FORMAT A30
COL DISK_FILE_PATH FORMAT A30
COL DISK_FILE_NAME FORMAT A30
COL DISK_FILE_FAIL_GROUP FORMAT A30
COL DATAFILE FORMAT A70;
COL USERNAME FORMAT A10;
COL MACHINE FORMAT A20;
COL OSUSER FORMAT A15;
COL SPID FORMAT A8;
COL PROGRAM FORMAT A15;
col job_name format a20;
Col STATE format a10;
col start_date format a40;
col NEXT_RUN_DATE format a40;
EOF
  chown oracle:oinstall "$target"
}

grid_links_glogin_cleanup() {
  phase 16 "Creating Grid alert links and glogin" "Creating RECO diskgroup"
  local crs_host
  crs_host="$(hostname -s)"
  run_as_oracle "ln -sfn /u01/app/oracle/diag/asm/+asm/+ASM/trace/alert_+ASM.log /home/oracle/alert_+ASM.log"
  run_as_oracle "ln -sfn '/u01/app/oracle/diag/crs/$crs_host/crs/trace/alert.log' /home/oracle/alert_crs.log"
  write_glogin "$GRID_HOME/sqlplus/admin/glogin.sql"
  run_as_oracle "sed -i '/SYSASMPassword/d' /home/oracle/gridsetup.rsp; sed -i '/monitorPassword/d' /home/oracle/gridsetup.rsp"
  complete_phase
}

create_reco_diskgroup() {
  phase 17 "Creating RECO diskgroup" "Installing Oracle Database software"
  normalize_all_disks
  validate_safe_raw_or_expected_afd "$RECO_DISK_NORM" "RECO_DISK before AFD label" "RECO01"
  [[ "$RECO_DISK_NORM" != "/dev/sdb" && "$RECO_DISK_NORM" != "/dev/sdc" ]] || die "Refusing to use a DATA disk for RECO."
  [[ "$RECO_DISK_NORM" != "$U01_DISK_NORM" && "$RECO_DISK_NORM" != "$U02_DISK_NORM" ]] || die "Refusing to use /u01 or /u02 disk for RECO."
  confirm_destructive_actions
  run_cmd chown oracle:asmadmin "$RECO_DISK_NORM"
  if afd_label_exists "RECO01"; then
    echo "AFD label RECO01 already exists. Skipping label creation for $RECO_DISK_NORM."
  else
    run_afd_asmcmd "afd_label RECO01 '$RECO_DISK_NORM'"
  fi
  run_afd_asmcmd "afd_lslbl"
  run_sqlplus_sysasm "SELECT NAME, TOTAL_MB, FREE_MB, USABLE_FILE_MB FROM V\$ASM_DISKGROUP;
CREATE DISKGROUP RECO EXTERNAL REDUNDANCY DISK 'AFD:RECO01';
SELECT NAME, TOTAL_MB, FREE_MB, USABLE_FILE_MB FROM V\$ASM_DISKGROUP;"
  complete_phase
}

install_db_software() {
  phase 18 "Installing Oracle Database software" "Creating Oracle glogin"
  if [[ ! -x "$ORACLE_HOME/runInstaller" ]]; then
    run_as_oracle "source /home/oracle/.bash_profile; unzip -q -d '$ORACLE_HOME' '/home/oracle/$DB_ZIP'"
  else
    echo "Oracle DB home already appears unzipped at $ORACLE_HOME."
  fi
  if [[ -d "$ORACLE_HOME/OPatch" && ! -d "$ORACLE_HOME/OPatch_old" ]]; then
    run_as_oracle "mv '$ORACLE_HOME/OPatch' '$ORACLE_HOME/OPatch_old'"
  elif [[ -d "$ORACLE_HOME/OPatch" ]]; then
    run_as_oracle "rm -rf '$ORACLE_HOME/OPatch'"
  fi
  run_as_oracle "unzip -q -d '$ORACLE_HOME' '/home/oracle/$OPATCH_ZIP'"
  run_as_oracle "cp '$ORACLE_HOME/install/response/db_install.rsp' /home/oracle/db_install.rsp"
  cat >> /home/oracle/db_install.rsp <<EOF
#### CONFIG PERSONALIZADA
oracle.install.option=INSTALL_DB_SWONLY
UNIX_GROUP_NAME=oinstall
INVENTORY_LOCATION=$INVENTORY_LOCATION
ORACLE_HOME=$ORACLE_HOME
ORACLE_BASE=$ORACLE_BASE
oracle.install.db.InstallEdition=EE
oracle.install.db.OSDBA_GROUP=dba
oracle.install.db.OSOPER_GROUP=dba
oracle.install.db.OSBACKUPDBA_GROUP=dba
oracle.install.db.OSDGDBA_GROUP=dba
oracle.install.db.OSKMDBA_GROUP=dba
oracle.install.db.OSRACDBA_GROUP=dba
EOF
  run_cmd chown oracle:oinstall /home/oracle/db_install.rsp
  run_cmd chmod 0600 /home/oracle/db_install.rsp
  run_as_oracle_allow_rc "source /home/oracle/.bash_profile; cd '$ORACLE_HOME' && export CV_ASSUME_DISTID=OEL7.8 && ./runInstaller -silent -responseFile /home/oracle/db_install.rsp -applyRU '$RU_DIR'" 0 6
  run_cmd "$ORACLE_HOME/root.sh"
  complete_phase
}

oracle_glogin() {
  phase 19 "Creating Oracle glogin" "Creating database with DBCA"
  write_glogin "$ORACLE_HOME/sqlplus/admin/glogin.sql"
  complete_phase
}

standby_preparation_summary() {
  echo
  echo "Standby server preparation completed successfully."
  echo "The next phase is Data Guard standby creation / RMAN duplicate from the primary database."
  echo
  echo "Skipped by standby preparation mode:"
  echo "  DBCA creation"
  echo "  ARCHIVELOG/FORCE LOGGING local database step"
  echo "  RMAN backup step"
  update_status 19 "Standby server preparation completed" 86 "$LAST_SUCCESSFUL_STEP" "Data Guard standby creation / RMAN duplicate from primary" "complete"
}

create_database_dbca() {
  phase 20 "Creating database with DBCA" "Creating DB alert link and enabling ARCHIVELOG"
  run_as_oracle "source /home/oracle/.bash_profile; time dbca -silent -createDatabase \
-templateName General_Purpose.dbc \
-gdbName '$ORACLE_SID' \
-sid '$ORACLE_SID' \
-sysPassword '$SYS_PASSWORD' \
-systemPassword '$SYSTEM_PASSWORD' \
-storageType ASM \
-recoveryAreaDestination +RECO \
-createAsContainerDatabase true \
-numberOfPDBs 1 \
-pdbAdminPassword '$PDB_ADMIN_PASSWORD' \
-pdbName '$PDB_NAME' \
-characterSet '$DB_CHARACTERSET' \
-automaticMemoryManagement false \
-redoLogFileSize '$REDO_LOG_FILE_SIZE_MB' \
-useOMF true \
-datafileDestination +DATA \
-initParams 'db_unique_name=$ORACLE_UNQNAME,sga_target=$SGA_TARGET,pga_aggregate_target=$PGA_AGGREGATE_TARGET,db_recovery_file_dest_size=$DB_RECOVERY_FILE_DEST_SIZE'"
  complete_phase
}

db_alert_archivelog() {
  phase 21 "Creating DB alert link and enabling ARCHIVELOG" "Running full RMAN backup"
  local lower_unq
  lower_unq="$(tr '[:upper:]' '[:lower:]' <<< "$ORACLE_UNQNAME")"
  run_as_oracle "ln -sfn '$ORACLE_BASE/diag/rdbms/$lower_unq/$ORACLE_SID/trace/alert_${ORACLE_SID}.log' /home/oracle/alert_${ORACLE_SID}.log"
  run_sqlplus_sysdba "SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
ALTER DATABASE FORCE LOGGING;
SELECT LOG_MODE FROM V\$DATABASE;
SELECT FORCE_LOGGING FROM V\$DATABASE;"
  complete_phase
}

rman_backup_and_summary() {
  phase 22 "Running full RMAN backup and final summary" "complete"
  run_rman "BACKUP DATABASE;"
  echo
  echo "Final summary"
  echo "Hostname:"
  hostnamectl --static || hostname
  echo "/u01 mount:"
  findmnt "$U01_MOUNT_POINT" || true
  echo "/u02 mount:"
  findmnt "$U02_MOUNT_POINT" || true
  echo "ASM labels:"
  ORACLE_BASE="$ORACLE_BASE" ORACLE_HOME="$GRID_HOME" "$GRID_HOME/bin/asmcmd" afd_lslbl || true
  echo "ASM diskgroups:"
  run_sqlplus_sysasm "SELECT NAME, TOTAL_MB, FREE_MB, USABLE_FILE_MB FROM V\$ASM_DISKGROUP;" || true
  echo "Grid status:"
  "$GRID_HOME/bin/crsctl" stat res -t || true
  echo "Listener status:"
  run_as_oracle "source /home/oracle/.bash_profile; lsnrctl status" || true
  echo "Database status:"
  run_sqlplus_sysdba "SELECT INSTANCE_NAME, STATUS FROM V\$INSTANCE;" || true
  echo "Archive log mode:"
  run_sqlplus_sysdba "SELECT LOG_MODE FROM V\$DATABASE;" || true
  echo "RMAN backup command completed. Review RMAN output in $LOG_FILE."
  complete_phase
  update_status "$CURRENT_STEP" "$CURRENT_PHASE" 100 "$LAST_SUCCESSFUL_STEP" "none" "complete"
}

main() {
  echo "Log file: $LOG_FILE"
  echo "Status file: $STATUS_FILE"
  if [[ "$RESET_ASM_DATA_LABELS" -eq 1 ]]; then
    reset_asm_data_labels
    update_status 0 "Reset ASM DATA labels" 0 "$LAST_SUCCESSFUL_STEP" "run --check before reinstall" "reset-data-labels"
    exit 0
  fi
  if [[ "$ADOPT_STATE" -eq 1 ]]; then
    require_root
    require_ol8
    validate_vars
    validate_expected_target
    check_installers
    validate_disks_for_install
    seed_resume_checkpoints
    update_status 0 "Adopted current host state" 0 "$LAST_SUCCESSFUL_STEP" "resume real installation after review" "adopted"
    echo
    echo "Adopted current host state into checkpoint file:"
    echo "  $CHECKPOINT_FILE"
    echo "No Oracle installation commands or destructive disk operations were executed."
    show_status
    exit 0
  fi
  if [[ "$DISCOVER_MODE" -eq 1 ]]; then
    require_root
    require_ol8
    validate_vars
    validate_expected_target
    discover_mounts_and_disks
    update_status 0 "Discovery only" 0 "$LAST_SUCCESSFUL_STEP" "run --check after review" "discover-complete"
    echo
    echo "Discovery mode completed. No installation steps or destructive operations were executed."
    exit 0
  fi
  prechecks
  if [[ "$CHECK_MODE" -eq 1 ]]; then
    echo
    echo "Check mode completed. No installation steps or destructive operations were executed."
    update_status "$CURRENT_STEP" "$CURRENT_PHASE" "$(( CURRENT_STEP * 100 / TOTAL_STEPS ))" "$LAST_SUCCESSFUL_STEP" "real installation after user validation" "check-complete"
    exit 0
  fi
  seed_resume_checkpoints
  confirm_real_install_context
  run_install_phase 2 create_users_groups "Creating users and groups" "Installing OS prerequisites"
  run_install_phase 3 install_os_prereqs "Installing OS prerequisites" "Configuring SELinux and firewall"
  run_install_phase 4 configure_selinux_firewall "Configuring SELinux and firewall" "Configuring hostname and /etc/hosts"
  run_install_phase 5 configure_hostname_hosts "Configuring hostname and /etc/hosts" "Configuring /u01 and /u02"
  run_install_phase 6 configure_filesystems "Configuring /u01 and /u02" "Moving installers"
  run_install_phase 7 move_installers "Copying installers to oracle home" "Configuring oracle password and profile"
  run_install_phase 8 configure_oracle_profile "Configuring oracle password and .bash_profile" "Creating Oracle directories"
  run_install_phase 9 create_oracle_dirs "Creating Oracle directories" "Preparing Grid home and RU"
  run_install_phase 10 prepare_grid_home "Preparing Grid home and RU" "Installing cvuqdisk"
  run_install_phase 11 install_cvuqdisk "Installing cvuqdisk" "Configuring ASM Filter Driver DATA disks"
  run_install_phase 12 configure_afd_data "Configuring ASM Filter Driver DATA disks" "Generating Grid response file"
  run_install_phase 13 generate_grid_response "Generating Grid response file" "Running silent Grid installation"
  run_install_phase 14 silent_grid_install "Running silent Grid installation" "Adjusting AFD init dependencies"
  run_install_phase 15 adjust_afd_init "Adjusting AFD init dependencies" "Creating Grid alert links and glogin"
  run_install_phase 16 grid_links_glogin_cleanup "Creating Grid alert links and glogin" "Creating RECO diskgroup"
  run_install_phase 17 create_reco_diskgroup "Creating RECO diskgroup" "Installing Oracle Database software"
  run_install_phase 18 install_db_software "Installing Oracle Database software" "Creating Oracle glogin"
  run_install_phase 19 oracle_glogin "Creating Oracle glogin" "Creating database with DBCA"
  if is_standby_mode; then
    standby_preparation_summary
    exit 0
  fi
  run_install_phase 20 create_database_dbca "Creating database with DBCA" "Creating DB alert link and enabling ARCHIVELOG"
  run_install_phase 21 db_alert_archivelog "Creating DB alert link and enabling ARCHIVELOG" "Running full RMAN backup"
  run_install_phase 22 rman_backup_and_summary "Running full RMAN backup and final summary" "complete"
}

main "$@"
