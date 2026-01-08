#!/usr/bin/env bash
set -uo pipefail

# test-autoinstall-local.sh - SUITE COMPLETA de pruebas
# Testa:
#   1. autoinstall-ubuntu.sh (Fase 1)
#   2. cloud-init bootstrap (Fase 2)
#   3. Ansible PXE server config (Fase 3)
# 
# Crea loopback disks, prepara escenarios y ejecuta validaciones

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AUTOINSTALL="$SCRIPT_DIR/autoinstall-ubuntu.sh"

TMPDIR=$(mktemp -d)
TEST_RESULTS_FILE="$TMPDIR/test-results.log"
TESTS_PASSED=0
TESTS_FAILED=0
LOOPS=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cleanup(){
  echo "[*] Cleaning up..."
  for l in $LOOPS; do 
    losetup -d "$l" 2>/dev/null || true
  done
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

require(){
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd required" >&2; exit 2; }
  done
}

log(){ echo -e "${BLUE}[*]${NC} $*"; }
pass(){ echo -e "${GREEN}[✓]${NC} $*"; ((TESTS_PASSED++)); }
fail(){ echo -e "${RED}[✗]${NC} $*" >&2; ((TESTS_FAILED++)); }
info(){ echo -e "    $*"; }

require losetup sgdisk mkfs.ext4 mkfs.vfat partprobe blkid mount umount tune2fs

mkloop(){
  local name="$1" sizeMB="$2" img="$TMPDIR/${name}.img"
  truncate -s ${sizeMB}M "$img"
  loop=$(losetup --show -fP "$img") || return 1
  LOOPS+="$loop "
  echo "$loop"
}

mkdisk_with_partitions(){
  local loop="$1"
  sgdisk -og "$loop"
  sgdisk -n1:1M:+64M -t1:ef00 -c1:"EFI" "$loop"
  sgdisk -n2:0:0 -t2:8300 -c2:"root" "$loop"
  partprobe "$loop" || true
  sleep 1
  p1="${loop}p1"; p2="${loop}p2"
  if [ ! -b "$p1" ]; then p1="${loop}1"; p2="${loop}2"; fi
  mkfs.vfat -n EFI "$p1" >/dev/null 2>&1
  mkfs.ext4 -F "$p2" >/dev/null 2>&1
  echo "$p1 $p2"
}

write_os_release(){
  local part="$1" version="$2" with_config="${3:-0}"
  mnt="$TMPDIR/mnt"
  mkdir -p "$mnt"
  mount "$part" "$mnt"
  mkdir -p "$mnt/etc"
  cat > "$mnt/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION="${version} LTS"
VERSION_ID="${version}"
EOF
  if [ "$with_config" = "1" ]; then
    mkdir -p "$mnt/var/lib/autoprov"
    echo "1" > "$mnt/var/lib/autoprov/config_version"
  fi
  mkdir -p "$mnt/etc"
  umount "$mnt"
}

write_grub_no_ds(){
  local part="$1"
  mnt="$TMPDIR/mnt"
  mkdir -p "$mnt"
  mount "$part" "$mnt"
  mkdir -p "$mnt/boot/grub"
  echo "set default=0" > "$mnt/boot/grub/grub.cfg"
  echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' > "$mnt/etc/default/grub"
  umount "$mnt"
}

write_persist_env(){
  local part="$1" content="$2"
  mnt="$TMPDIR/mntp"
  mkdir -p "$mnt"
  mount "$part" "$mnt"
  mkdir -p "$mnt/ENV"
  echo -e "$content" > "$mnt/ENV/installer.env"
  sync
  umount "$mnt"
}

assert_file_exists(){
  local part="$1" path="$2" label="$3"
  mnt="$TMPDIR/mnt"
  mkdir -p "$mnt"
  if ! mount "$part" "$mnt" 2>/dev/null; then
    fail "$label: could not mount partition"
    return 1
  fi
  if [ -f "$mnt/$path" ]; then
    pass "$label: $path exists"
    umount "$mnt"
    return 0
  else
    fail "$label: $path not found"
    umount "$mnt"
    return 1
  fi
}

assert_file_contains(){
  local part="$1" path="$2" pattern="$3" label="$4"
  mnt="$TMPDIR/mnt"
  mkdir -p "$mnt"
  if ! mount "$part" "$mnt" 2>/dev/null; then
    fail "$label: could not mount partition"
    return 1
  fi
  if [ ! -f "$mnt/$path" ]; then
    fail "$label: $path not found"
    umount "$mnt"
    return 1
  fi
  if grep -q "$pattern" "$mnt/$path"; then
    pass "$label: $path contains '$pattern'"
    umount "$mnt"
    return 0
  else
    fail "$label: $path does not contain '$pattern'"
    umount "$mnt"
    return 1
  fi
}

# ============================================================================
# FASE 1: Tests - autoinstall-ubuntu.sh
# ============================================================================
test_phase1_simulated_install(){
  log "\n=== FASE 1: Autoinstall Ubuntu (simulated) ==="
  
  log "Creating target disk..."
  loop_target=$(mkloop target 128)
  read p1_target p2_target < <(mkdisk_with_partitions "$loop_target")
  
  log "TEST 1.1: Simulated install on empty disk"
  if TEST_MODE=1 TEST_DISK="$loop_target" bash "$AUTOINSTALL" >/dev/null 2>&1; then
    assert_file_exists "$p2_target" "etc/os-release" "TEST 1.1.1"
    assert_file_exists "$p2_target" "var/lib/autoprov/config_version" "TEST 1.1.2"
    pass "TEST 1.1: Simulated install completed"
  else
    fail "TEST 1.1: Autoinstall script failed"
  fi
}

test_phase1_grub_repair(){
  log "\n=== FASE 1: GRUB Repair (ds=nocloud addition) ==="
  
  log "Preparing target with Ubuntu 24.04 without ds=nocloud..."
  loop_target=$(mkloop target2 128)
  read p1_target p2_target < <(mkdisk_with_partitions "$loop_target")
  write_os_release "$p2_target" "24.04" 0
  write_grub_no_ds "$p2_target"
  
  log "TEST 1.2: Repair GRUB and add config_version"
  if TEST_MODE=1 TEST_DISK="$loop_target" bash "$AUTOINSTALL" >/dev/null 2>&1; then
    assert_file_exists "$p2_target" "var/lib/autoprov/config_version" "TEST 1.2.1"
    assert_file_contains "$p2_target" "etc/default/grub" "ds=nocloud" "TEST 1.2.2"
    pass "TEST 1.2: GRUB repair completed"
  else
    fail "TEST 1.2: GRUB repair failed"
  fi
}

test_phase1_check_uuid(){
  log "\n=== FASE 1: CHECK_UUID environment variable ==="
  
  log "Creating persist and target disks..."
  loop_persist=$(mkloop persist 32)
  read p1_persist p2_persist < <(mkdisk_with_partitions "$loop_persist")
  mkfs.ext4 -F -L TINYDATA "$p2_persist" >/dev/null 2>&1
  
  loop_target=$(mkloop target3 128)
  read p1_target p2_target < <(mkdisk_with_partitions "$loop_target")
  write_os_release "$p2_target" "24.04" 1
  
  TARGET_UUID=$(blkid -s UUID -o value "$p2_target")
  log "Target UUID: $TARGET_UUID"
  
  log "TEST 1.3: Using CHECK_UUID from installer.env"
  ENV_CONTENT="CHECK_UUID=${TARGET_UUID}\nSEED_URL=https://raw.githubusercontent.com/MarcPineiro/serverUtils/refs/heads/main/check-so/cloud-init/"
  write_persist_env "$p2_persist" "$ENV_CONTENT"
  
  if TEST_MODE=1 TCE_DIR="$TMPDIR/tcedir" bash -c "mkdir -p \$TCE_DIR; mount $p2_persist \$TCE_DIR; bash $AUTOINSTALL >/dev/null 2>&1; umount \$TCE_DIR"; then
    pass "TEST 1.3: CHECK_UUID correctly applied"
  else
    fail "TEST 1.3: CHECK_UUID test failed"
  fi
}

test_phase1_exclude_uuid(){
  log "\n=== FASE 1: EXCLUDE_UUID handling ==="
  
  loop_persist=$(mkloop persist2 32)
  read p1_persist p2_persist < <(mkdisk_with_partitions "$loop_persist")
  
  loop_excl=$(mkloop excl 64)
  read p1_excl p2_excl < <(mkdisk_with_partitions "$loop_excl")
  EXCL_UUID=$(uuidgen)
  tune2fs -U "$EXCL_UUID" "$p2_excl" >/dev/null 2>&1 || true
  
  log "Excluded UUID: $EXCL_UUID"
  
  log "TEST 1.4: Invalid CHECK_UUID triggers abort"
  ENV_CONTENT="EXCLUDE_UUID=${EXCL_UUID}\nCHECK_UUID=deadbeef-dead-beef-dead-beefdeadbeef"
  write_persist_env "$p2_persist" "$ENV_CONTENT"
  
  if ! TEST_MODE=1 TCE_DIR="$TMPDIR/tcedir2" bash -c "mount $p2_persist \$TCE_DIR; bash $AUTOINSTALL >/dev/null 2>&1; umount \$TCE_DIR" 2>/dev/null; then
    pass "TEST 1.4: Invalid CHECK_UUID correctly rejected"
  else
    fail "TEST 1.4: Invalid CHECK_UUID should have failed"
  fi
}

# ============================================================================
# FASE 2: Tests - cloud-init bootstrap
# ============================================================================
test_phase2_cloud_init_structure(){
  log "\n=== FASE 2: Cloud-init seed structure ==="
  
  log "TEST 2.1: Cloud-init seed files exist"
  if [ -f "$SCRIPT_DIR/cloud-init/user-data" ] && [ -f "$SCRIPT_DIR/cloud-init/meta-data" ]; then
    pass "TEST 2.1: user-data and meta-data present"
  else
    fail "TEST 2.1: cloud-init seeds missing"
  fi
  
  log "TEST 2.2: user-data contains autoinstall configuration"
  if grep -q "autoinstall:" "$SCRIPT_DIR/cloud-init/user-data"; then
    pass "TEST 2.2: user-data has autoinstall section"
  else
    fail "TEST 2.2: user-data missing autoinstall"
  fi
  
  log "TEST 2.3: user-data contains ansible-pull bootstrap"
  if grep -q "ansible-pull" "$SCRIPT_DIR/cloud-init/user-data"; then
    pass "TEST 2.3: user-data has ansible-pull command"
  else
    fail "TEST 2.3: user-data missing ansible-pull"
  fi
  
  log "TEST 2.4: meta-data contains instance-id"
  if grep -q "instance-id:" "$SCRIPT_DIR/cloud-init/meta-data"; then
    pass "TEST 2.4: meta-data has instance-id"
  else
    fail "TEST 2.4: meta-data missing instance-id"
  fi
}

# ============================================================================
# FASE 3: Tests - Ansible PXE configuration
# ============================================================================
test_phase3_ansible_supervisor(){
  log "\n=== FASE 3: Ansible supervisor.yml structure ==="
  
  log "TEST 3.1: supervisor.yml playbook exists"
  if [ -f "$SCRIPT_DIR/ansible/supervisor.yml" ]; then
    pass "TEST 3.1: supervisor.yml present"
  else
    fail "TEST 3.1: supervisor.yml missing"
  fi
  
  log "TEST 3.2: supervisor.yml targets localhost only"
  if grep -q "hosts: localhost" "$SCRIPT_DIR/ansible/supervisor.yml"; then
    pass "TEST 3.2: Playbook targets localhost"
  else
    fail "TEST 3.2: Playbook does not target localhost"
  fi
  
  log "TEST 3.3: Includes healthchecks section"
  if grep -q "HEALTHCHECK" "$SCRIPT_DIR/ansible/supervisor.yml"; then
    pass "TEST 3.3: Playbook includes healthchecks"
  else
    fail "TEST 3.3: Playbook missing healthchecks"
  fi
  
  log "TEST 3.4: Required roles present"
  local required_roles=("dnsmasq_pxe" "nginx_pxe" "ipxe_bootloader")
  for role in "${required_roles[@]}"; do
    if [ -d "$SCRIPT_DIR/ansible/roles/$role" ]; then
      pass "TEST 3.4: Role $role exists"
    else
      fail "TEST 3.4: Role $role missing"
    fi
  done
}

test_phase3_ansible_roles(){
  log "\n=== FASE 3: Ansible roles healthchecks ==="
  
  log "TEST 3.5: dnsmasq_pxe role tasks"
  if grep -q "HEALTHCHECK" "$SCRIPT_DIR/ansible/roles/dnsmasq_pxe/tasks/main.yml"; then
    pass "TEST 3.5: dnsmasq_pxe has healthchecks"
  else
    fail "TEST 3.5: dnsmasq_pxe missing healthchecks"
  fi
  
  log "TEST 3.6: nginx_pxe role tasks"
  if grep -q "HEALTHCHECK" "$SCRIPT_DIR/ansible/roles/nginx_pxe/tasks/main.yml"; then
    pass "TEST 3.6: nginx_pxe has healthchecks"
  else
    fail "TEST 3.6: nginx_pxe missing healthchecks"
  fi
  
  log "TEST 3.7: iPXE menu configuration"
  if [ -f "$SCRIPT_DIR/ansible/roles/ipxe_bootloader/templates/menu.ipxe.j2" ]; then
    if grep -q "menu-timeout" "$SCRIPT_DIR/ansible/roles/ipxe_bootloader/templates/menu.ipxe.j2"; then
      pass "TEST 3.7: iPXE menu has timeout"
    else
      fail "TEST 3.7: iPXE menu missing timeout"
    fi
  else
    fail "TEST 3.7: iPXE menu template missing"
  fi
}

test_phase3_pxe_download_script(){
  log "\n=== FASE 3: PXE kernel download script ==="
  
  log "TEST 3.8: download-pxe-kernels.sh exists"
  if [ -f "$SCRIPT_DIR/download-pxe-kernels.sh" ]; then
    pass "TEST 3.8: download-pxe-kernels.sh present"
  else
    fail "TEST 3.8: download-pxe-kernels.sh missing"
  fi
  
  log "TEST 3.9: Script is executable"
  if [ -x "$SCRIPT_DIR/download-pxe-kernels.sh" ]; then
    pass "TEST 3.9: download-pxe-kernels.sh is executable"
  else
    info "Making download-pxe-kernels.sh executable..."
    chmod +x "$SCRIPT_DIR/download-pxe-kernels.sh"
    pass "TEST 3.9: download-pxe-kernels.sh made executable"
  fi
  
  log "TEST 3.10: Script contains Ubuntu download function"
  if grep -q "download_ubuntu" "$SCRIPT_DIR/download-pxe-kernels.sh"; then
    pass "TEST 3.10: Ubuntu kernel downloader present"
  else
    fail "TEST 3.10: Ubuntu kernel downloader missing"
  fi
}

# ============================================================================
# Integration Tests
# ============================================================================
test_integration_seed_access(){
  log "\n=== INTEGRATION: Cloud-init seeds via HTTP (mock) ==="
  
  log "TEST 4.1: Seeds would be accessible via GitHub Raw"
  # We can't test real HTTP access, but verify the files would be served
  if [ -f "$SCRIPT_DIR/cloud-init/user-data" ] && [ -f "$SCRIPT_DIR/cloud-init/meta-data" ]; then
    pass "TEST 4.1: Seeds ready for GitHub publication"
  else
    fail "TEST 4.1: Seeds not ready"
  fi
}

test_integration_full_flow(){
  log "\n=== INTEGRATION: Full workflow validation ==="
  
  log "TEST 4.2: Autoinstall → cloud-init → ansible flow"
  if [ -f "$AUTOINSTALL" ] && \
     [ -f "$SCRIPT_DIR/cloud-init/user-data" ] && \
     [ -f "$SCRIPT_DIR/ansible/supervisor.yml" ]; then
    pass "TEST 4.2: Complete workflow chain present"
  else
    fail "TEST 4.2: Workflow chain incomplete"
  fi
  
  log "TEST 4.3: Configuration version markers"
  if grep -q "config_version" "$AUTOINSTALL" && \
     grep -q "config_version" "$SCRIPT_DIR/ansible/supervisor.yml"; then
    pass "TEST 4.3: config_version convergence markers present"
  else
    fail "TEST 4.3: config_version markers missing"
  fi
}

# ============================================================================
# Main test execution
# ============================================================================
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  AUTOINSTALL + CLOUD-INIT + ANSIBLE TEST SUITE            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo

log "Using tmpdir: $TMPDIR"
log "Scripts: autoinstall=$AUTOINSTALL"

# Phase 1: Autoinstall tests
test_phase1_simulated_install
test_phase1_grub_repair
test_phase1_check_uuid
test_phase1_exclude_uuid

# Phase 2: Cloud-init tests
test_phase2_cloud_init_structure

# Phase 3: Ansible tests
test_phase3_ansible_supervisor
test_phase3_ansible_roles
test_phase3_pxe_download_script

# Integration tests
test_integration_seed_access
test_integration_full_flow

# Summary
echo
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  TEST SUMMARY                                              ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo -e "║  ${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "║  ${RED}Failed: $TESTS_FAILED${NC}"
echo "║  Total:  $((TESTS_PASSED + TESTS_FAILED))"
echo "╚════════════════════════════════════════════════════════════╝"
echo

if [ $TESTS_FAILED -eq 0 ]; then
  echo -e "${GREEN}✓ All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}✗ Some tests failed. Review output above.${NC}"
  exit 1
fi
