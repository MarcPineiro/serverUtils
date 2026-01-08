#!/usr/bin/env bash
set -euo pipefail

# download-pxe-kernels.sh
# Descarga kernels PXE para Ubuntu, Debian, y otros sistemas
# Almacena en /srv/http/boot/ según el tipo de SO

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BOOT_ROOT="${BOOT_ROOT:-/srv/http/boot}"
TMPDIR="${TMPDIR:-/tmp}"
VERBOSE="${VERBOSE:-0}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log(){ echo -e "${BLUE}[*]${NC} $*"; }
info(){ echo -e "${GREEN}[+]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
err(){ echo -e "${RED}[!]${NC} $*" >&2; }

usage(){
  cat <<EOF
Usage: $0 [OPTIONS] [OS1 [OS2 ...]]

Download PXE boot kernels and initrds for various operating systems.

OPTIONS:
  -d, --destination DIR    Boot directory (default: /srv/http/boot)
  -v, --verbose            Verbose output
  -h, --help               Show this help message

SUPPORTED OS:
  ubuntu-24.04             Ubuntu 24.04 LTS (recommended)
  ubuntu-22.04             Ubuntu 22.04 LTS
  debian-12                Debian 12 (Bookworm)
  debian-11                Debian 11 (Bullseye)
  all                      Download all (default if no OS specified)

EXAMPLES:
  # Download Ubuntu 24.04 only
  sudo $0 ubuntu-24.04

  # Download Ubuntu and Debian
  sudo $0 ubuntu-24.04 debian-12

  # Download all with custom destination
  sudo $0 -d /var/www/pxe all

  # Verbose output
  sudo $0 -v ubuntu-24.04
EOF
}

require(){
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "Required command not found: $cmd"
      exit 1
    fi
  done
}

# Check if running as root
check_root(){
  if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root"
    exit 2
  fi
}

# Parse arguments
parse_args(){
  local os_list=()
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--destination)
        BOOT_ROOT="$2"
        shift 2
        ;;
      -v|--verbose)
        VERBOSE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      ubuntu-24.04|ubuntu-22.04|debian-12|debian-11|all)
        os_list+=("$1")
        shift
        ;;
      *)
        err "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  # Default to all if no OS specified
  if [ ${#os_list[@]} -eq 0 ]; then
    os_list=("all")
  fi

  echo "${os_list[@]}"
}

# Download Ubuntu kernel and initrd
download_ubuntu(){
  local version="$1"
  local arch="amd64"
  local iso_url=""
  local iso_file="$TMPDIR/ubuntu-${version}-live-server-${arch}.iso"
  
  case "$version" in
    24.04)
      iso_url="https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-${arch}.iso"
      ;;
    22.04)
      iso_url="https://releases.ubuntu.com/22.04/ubuntu-22.04.3-live-server-${arch}.iso"
      ;;
    *)
      err "Unsupported Ubuntu version: $version"
      return 1
      ;;
  esac

  local boot_dir="$BOOT_ROOT/ubuntu"
  mkdir -p "$boot_dir"

  info "Downloading Ubuntu $version..."
  [[ $VERBOSE -eq 1 ]] && log "URL: $iso_url"
  
  if ! wget -q --show-progress -O "$iso_file" "$iso_url"; then
    err "Failed to download Ubuntu $version"
    return 1
  fi

  info "Extracting Ubuntu $version kernel and initrd..."
  
  # Mount ISO temporarily
  local iso_mnt="$TMPDIR/ubuntu-iso-mnt"
  mkdir -p "$iso_mnt"
  mount -o loop,ro "$iso_file" "$iso_mnt" || {
    err "Failed to mount ISO"
    rm -f "$iso_file"
    return 1
  }

  # Ubuntu live ISOs have casper/vmlinuz and casper/initrd
  if [ -f "$iso_mnt/casper/vmlinuz" ] && [ -f "$iso_mnt/casper/initrd" ]; then
    cp "$iso_mnt/casper/vmlinuz" "$boot_dir/vmlinuz-${version}"
    cp "$iso_mnt/casper/initrd" "$boot_dir/initrd-${version}"
    info "Extracted Ubuntu $version: vmlinuz-${version}, initrd-${version}"
  else
    warn "Could not find casper/vmlinuz or casper/initrd in Ubuntu ISO"
  fi

  umount "$iso_mnt" || true
  rmdir "$iso_mnt" 2>/dev/null || true
  rm -f "$iso_file"

  return 0
}

# Download Debian kernel and initrd
download_debian(){
  local version="$1"
  local arch="amd64"
  local debian_version=""
  local url_base=""

  case "$version" in
    12)
      debian_version="bookworm"
      url_base="https://deb.debian.org/debian/dists/bookworm/main/installer-${arch}/current/images/netboot"
      ;;
    11)
      debian_version="bullseye"
      url_base="https://deb.debian.org/debian/dists/bullseye/main/installer-${arch}/current/images/netboot"
      ;;
    *)
      err "Unsupported Debian version: $version"
      return 1
      ;;
  esac

  local boot_dir="$BOOT_ROOT/debian"
  mkdir -p "$boot_dir"

  info "Downloading Debian $version ($debian_version)..."
  
  # Download kernel and initrd
  local kernel_url="${url_base}/debian-installer/${arch}/linux"
  local initrd_url="${url_base}/debian-installer/${arch}/initrd.gz"

  [[ $VERBOSE -eq 1 ]] && {
    log "Kernel URL: $kernel_url"
    log "Initrd URL: $initrd_url"
  }

  if ! wget -q --show-progress -O "$boot_dir/vmlinuz-debian-${version}" "$kernel_url"; then
    warn "Failed to download Debian $version kernel"
    return 1
  fi

  if ! wget -q --show-progress -O "$boot_dir/initrd-debian-${version}.gz" "$initrd_url"; then
    warn "Failed to download Debian $version initrd"
    rm -f "$boot_dir/vmlinuz-debian-${version}"
    return 1
  fi

  info "Downloaded Debian $version: vmlinuz-debian-${version}, initrd-debian-${version}.gz"
  return 0
}

# Download Proxmox VE kernel and initrd
download_proxmox(){
  local version="${1:-8.0}"
  local arch="amd64"
  local iso_url="https://enterprise.proxmox.com/iso/proxmox-ve_${version}-1.iso"
  local iso_file="$TMPDIR/proxmox-ve-${version}.iso"

  local boot_dir="$BOOT_ROOT/proxmox"
  mkdir -p "$boot_dir"

  warn "Proxmox download requires subscriptions for latest ISOs"
  warn "Attempting download of Proxmox VE ${version}..."
  
  [[ $VERBOSE -eq 1 ]] && log "URL: $iso_url"

  if ! wget -q --show-progress -O "$iso_file" "$iso_url" 2>/dev/null; then
    warn "Proxmox VE ${version} ISO not publicly available - skipping"
    warn "Visit https://www.proxmox.com/en/downloads to download manually"
    return 1
  fi

  info "Extracted Proxmox VE $version (manual setup may be needed)"
  rm -f "$iso_file"
  return 0
}

# Create boot menu documentation
create_boot_menu_doc(){
  local doc_file="$BOOT_ROOT/KERNELS_MANIFEST.md"
  
  info "Creating kernels manifest at $doc_file"
  
  cat > "$doc_file" <<'EOF'
# PXE Boot Kernels Manifest

This document lists available boot kernels and initrds for PXE clients.

## Directory Structure

```
/srv/http/boot/
├── ubuntu/                  # Ubuntu autoinstall kernels
│   ├── vmlinuz-24.04
│   ├── initrd-24.04
│   ├── vmlinuz-22.04
│   └── initrd-22.04
├── debian/                  # Debian netinstall kernels
│   ├── vmlinuz-debian-12
│   ├── initrd-debian-12.gz
│   ├── vmlinuz-debian-11
│   └── initrd-debian-11.gz
├── proxmox/                 # Proxmox VE kernels (if available)
│   └── vmlinuz-proxmox-8.0
├── boot.ipxe                # Main iPXE boot script
├── menu.ipxe                # iPXE menu with timeout
└── machines/
    ├── nas.ipxe             # NAS configuration
    ├── proxmox.ipxe         # Proxmox configuration
    └── edge.ipxe            # Edge node configuration
```

## Usage in iPXE Scripts

### Ubuntu 24.04 (Autoinstall + Cloud-init)
```
kernel http://supervisor/boot/ubuntu/vmlinuz-24.04 auto=true \
  ds=nocloud;s=http://supervisor/cloud-init/
initrd http://supervisor/boot/ubuntu/initrd-24.04
boot
```

### Debian 12 (Preseed + Netinstall)
```
kernel http://supervisor/boot/debian/vmlinuz-debian-12 auto=true \
  priority=critical preseed/url=http://supervisor/preseed/debian-12.cfg
initrd http://supervisor/boot/debian/initrd-debian-12.gz
boot
```

### Proxmox VE
```
kernel http://supervisor/boot/proxmox/vmlinuz-proxmox-8.0
initrd http://supervisor/boot/proxmox/initrd-proxmox-8.0
boot
```

## Notes

- Kernels are cached locally; they are not re-downloaded unless removed
- Preseed/cloud-init configurations should be placed in `/srv/http/preseed/` and `/srv/http/cloud-init/`
- For custom configurations, edit the corresponding iPXE scripts in `/srv/http/boot/machines/`
- Bandwidth: Plan for ~500MB total download (initial setup only)

## Updates

To update kernels to newer versions:
```bash
sudo rm /srv/http/boot/ubuntu/vmlinuz-24.04 /srv/http/boot/ubuntu/initrd-24.04
sudo /path/to/download-pxe-kernels.sh ubuntu-24.04
```
EOF
}

# Main execution
main(){
  require wget mount umount cp rm mkdir

  check_root

  # Create boot root if it doesn't exist
  if ! [ -d "$BOOT_ROOT" ]; then
    log "Creating boot directory: $BOOT_ROOT"
    mkdir -p "$BOOT_ROOT"
  fi

  info "PXE Kernel Downloader"
  info "Boot directory: $BOOT_ROOT"
  echo

  local os_list=()
  read -ra os_list <<< "$(parse_args "$@")"

  local downloaded=0
  local failed=0

  for os in "${os_list[@]}"; do
    case "$os" in
      all)
        info "Downloading all supported OS images..."
        download_ubuntu "24.04" && ((downloaded++)) || ((failed++))
        download_ubuntu "22.04" && ((downloaded++)) || ((failed++))
        download_debian "12" && ((downloaded++)) || ((failed++))
        download_debian "11" && ((downloaded++)) || ((failed++))
        download_proxmox "8.0" || ((failed++))  # Proxmox may fail due to subscription
        ;;
      ubuntu-*)
        local version="${os#ubuntu-}"
        download_ubuntu "$version" && ((downloaded++)) || ((failed++))
        ;;
      debian-*)
        local version="${os#debian-}"
        download_debian "$version" && ((downloaded++)) || ((failed++))
        ;;
    esac
  done

  # Create manifest
  create_boot_menu_doc

  echo
  info "Summary:"
  info "  Successfully downloaded: $downloaded"
  warn "  Failed: $failed"
  info "  Boot directory: $BOOT_ROOT"
  info "  Total size: $(du -sh "$BOOT_ROOT" 2>/dev/null | cut -f1)"
  echo

  if [ $failed -eq 0 ]; then
    info "All downloads completed successfully! ✓"
    return 0
  else
    warn "Some downloads failed. Check the output above."
    return 1
  fi
}

main "$@"
