#!/usr/bin/env bash
set -exuo pipefail

load_persist_env(){
	CANDIDATE_ENV_FILE=""
	if [ -f "$TCE_DIR/ENV/installer.env" ]; then
		CANDIDATE_ENV_FILE="$TCE_DIR/ENV/installer.env"
	elif [ -f "$TCE_DIR/installer.env" ]; then
		CANDIDATE_ENV_FILE="$TCE_DIR/installer.env"
	fi
	if [ -n "$CANDIDATE_ENV_FILE" ]; then
		log "Cargando variables desde $CANDIDATE_ENV_FILE"
		set -o allexport
		# shellcheck disable=SC1090
		. "$CANDIDATE_ENV_FILE"
		set +o allexport
		return 0
	fi
	log "No se encontró installer.env en $TCE_DIR; se usarán valores por defecto/env actuales."
	return 1
}

CHECK_UUID="${CHECK_UUID:-}"
EXCLUDE_UUID="${EXCLUDE_UUID:-}"
SEED_URL="${SEED_URL:-https://raw.githubusercontent.com/MarcPineiro/serverUtils/refs/heads/main/check-so/cloud-init/}"
CONFIG_VERSION="${CONFIG_VERSION:-1}"
RELEASE="${RELEASE:-24.04}"
ARCH="${ARCH:-amd64}"
TCE_DIR="${TCE_DIR:-/etc/sysconfig/tcedir}"

parse_exclude_uuids(){
	EXCLUDE_UUIDS=()
	if [ -n "${EXCLUDE_UUID:-}" ]; then
		IFS=',' read -ra _tmp <<< "${EXCLUDE_UUID}"
		for u in "${_tmp[@]}"; do
			u2=$(echo "$u" | tr -d '[:space:]')
			if [ -n "$u2" ]; then
				EXCLUDE_UUIDS+=("$u2")
			fi
		done
	fi
}

is_excluded_uuid(){
	local id="$1"
	if [ -z "$id" ]; then return 1; fi
	for ex in "${EXCLUDE_UUIDS[@]:-}"; do
		if [ "$ex" = "$id" ]; then
			return 0
		fi
	done
	return 1
}

disk_has_excluded_uuid(){
	local disk="$1"
	[ -b "$disk" ] || return 1
	for part in $(lsblk -nr -o NAME -l "$disk"); do
		p="/dev/$part"
		[ -b "$p" ] || continue
		puuid=$(blkid -s UUID -o value "$p" 2>/dev/null || true)
		ppartuuid=$(blkid -s PARTUUID -o value "$p" 2>/dev/null || true)
		if is_excluded_uuid "$puuid" || is_excluded_uuid "$ppartuuid"; then
			return 0
		fi
	done
	return 1
}

choose_disk_by_priority(){
	best=""
	best_score=0
	for dev in /sys/block/*; do
		b=$(basename "$dev")
		case "$b" in
			loop*|ram*|sr*) continue ;;
		esac
		if [ -f "$dev/removable" ] && [ "$(cat $dev/removable)" = "0" ]; then
			disk="/dev/$b"
			if disk_has_excluded_uuid "$disk"; then
				log "Excluyendo disco $disk por EXCLUDE_UUID presente en partición"
				continue
			fi
			tran_file="/sys/block/$b/device/transport"
			tran=$(cat "$tran_file" 2>/dev/null || true)
			rotational_file="/sys/block/$b/queue/rotational"
			rotational=$(cat "$rotational_file" 2>/dev/null || echo 1)
			size=$(lsblk -nb -o SIZE -dn "$disk" 2>/dev/null || echo 0)
			score=$((size+0))
			if [ "$tran" = "nvme" ]; then
				score=$((score + 1000000000000))
			elif [ "$rotational" = "0" ]; then
				score=$((score + 500000000000))
			fi
			if [ "$score" -gt "$best_score" ]; then
				best_score=$score
				best="$disk"
			fi
		fi
	done
	if [ -n "$best" ]; then
		echo "$best"
		return 0
	fi
	return 1
}

detect_internal_disk(){
	if [ -n "${TEST_DISK:-}" ]; then
		if [ -b "${TEST_DISK}" ]; then
			echo "${TEST_DISK}"
			return 0
		fi
	fi
    
	for dev in /sys/block/*; do
		b=$(basename "$dev")
		case "$b" in
			loop*|ram*|sr*) continue ;;
		esac
		if [ -f "$dev/removable" ] && [ "$(cat $dev/removable)" = "0" ]; then
			tran_file="/sys/block/$b/device/transport"
			if [ -e "$tran_file" ]; then
				tran=$(cat "$tran_file" 2>/dev/null || true)
			else
				tran=""
			fi
			echo "/dev/$b"
			return 0
		fi
	done
	return 1
}

find_partition_by_uuid(){
	local uuid="$1"
	if [ -z "$uuid" ]; then return 1; fi
	if dev=$(blkid -U "$uuid" 2>/dev/null); then
		if [ -b "$dev" ]; then
			echo "$dev"
			return 0
		fi
	fi
	return 1
}

find_os_partitions(){
	CANDIDATES=()
	for disk in /sys/block/*; do
		b=$(basename "$disk")
		case "$b" in
			loop*|ram*|sr*) continue ;;
		esac
		if [ -f "$disk/removable" ] && [ "$(cat $disk/removable)" = "0" ]; then
			dev="/dev/$b"
			for part in $(lsblk -nr -o NAME -l "$dev"); do
				p="/dev/$part"
				[ -b "$p" ] || continue
				puuid=$(blkid -s UUID -o value "$p" 2>/dev/null || true)
                if is_excluded_uuid "$puuid"; then
                    continue
                fi
				mnt=/mnt/target
				mkdir -p "$mnt"
				if mount -o ro "$p" "$mnt" 2>/dev/null; then
					if [ -f "$mnt/etc/os-release" ]; then
						CANDIDATES+=("$p")
					fi
					umount "$mnt" || true
				fi
			done
		fi
	done
}

mount_probe_root(){
	local disk="$1"
	local mnt="/mnt/target"
	mkdir -p "$mnt"
	for part in $(lsblk -nr -o NAME -l "$disk"); do
		p="/dev/$part"
		[ -b "$p" ] || continue
		fstype=$(blkid -o value -s TYPE "$p" 2>/dev/null || true)
		if [ -z "$fstype" ]; then
			:
		fi
		rm -rf "$mnt"/* 2>/dev/null || true
		if mount -o ro "$p" "$mnt" 2>/dev/null; then
			if [ -f "$mnt/etc/os-release" ]; then
				echo "$p"
				umount "$mnt" || true
				return 0
			fi
			umount "$mnt" || true
		fi
	done
	return 1
}

check_os_version(){
	local rootp="$1"
	local mnt="/mnt/target"
	mkdir -p "$mnt"
	mount -o ro "$rootp" "$mnt"
	if [ ! -f "$mnt/etc/os-release" ]; then
		umount "$mnt" || true
		return 2
	fi
	. "$mnt/etc/os-release"
	VERSION_ID_STR=${VERSION_ID:-}
	umount "$mnt" || true
	if [ "$VERSION_ID_STR" = "$RELEASE" ]; then
		return 0
	else
		return 1
	fi
}

check_grub_cmdline(){
	local rootp="$1"
	local mnt="/mnt/target"
	mkdir -p "$mnt"
	mount -o ro "$rootp" "$mnt"
	found=1
	if grep -q "ds=nocloud" "$mnt/boot/grub/grub.cfg" 2>/dev/null; then
		found=0
	fi
	if [ $found -ne 0 ] && grep -q "ds=nocloud" "$mnt/etc/default/grub" 2>/dev/null; then
		found=0
	fi
	umount "$mnt" || true
	return $found
}

check_config_version(){
	local rootp="$1"
	local mnt="/mnt/target"
	mkdir -p "$mnt"
	mount -o ro "$rootp" "$mnt"
	if [ -f "$mnt/var/lib/autoprov/config_version" ]; then
		umount "$mnt" || true
		return 0
	fi
	umount "$mnt" || true
	return 1
}

install_with_debootstrap(){
	local disk="$1"
	log "Instalando Ubuntu $RELEASE en $disk (debootstrap) o simulación si TEST_MODE=1)."
	if [ "${TEST_MODE:-0}" = "1" ]; then
		log "TEST_MODE=1: simulando instalación mínima en $disk"
		rootp=$(mount_probe_root "$disk" || true)
		if [ -z "$rootp" ]; then
			part=$(lsblk -nr -o NAME -l "$disk" | awk 'NR==1{print $1}') || true
			rootp="/dev/$part"
		fi
		mnt=/mnt/target
		mkdir -p "$mnt"
		mount "$rootp" "$mnt"
		mkdir -p "$mnt/etc"
		cat > "$mnt/etc/os-release" <<EOF
NAME="Ubuntu"
VERSION="${RELEASE} LTS"
VERSION_ID="${RELEASE}"
EOF
		mkdir -p "$mnt/var/lib/autoprov"
		echo "$CONFIG_VERSION" > "$mnt/var/lib/autoprov/config_version"
		mkdir -p "$mnt/boot/grub"
		echo "set default=0" > "$mnt/boot/grub/grub.cfg"
		echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' > "$mnt/etc/default/grub"
		umount "$mnt" || true
		log "Simulación de instalación terminada en $rootp"
		return 0
	fi

	log "Real installation: this will modify $disk. Proceeding..."
	apt-get update || true
	apt-get install -y debootstrap gdisk dosfstools grub-efi-amd64 shim-signed wget || true

	sgdisk --zap-all "$disk"
	sgdisk -n1:1M:+512M -t1:ef00 -c1:"EFI System" "$disk"
	sgdisk -n2:0:0 -t2:8300 -c2:"linux-root" "$disk"

	partprobe "$disk" || true
	sleep 1
	efi="${disk}1"
	rootp="${disk}2"

	mkfs.vfat -F32 -n EFI "$efi"
	mkfs.ext4 -F -L rootfs "$rootp"

	mnt=/mnt/target
	mkdir -p "$mnt"
	mount "$rootp" "$mnt"
	mkdir -p "$mnt/boot/efi"
	mount "$efi" "$mnt/boot/efi"

	debootstrap --arch=$ARCH --variant=minbase "$RELEASE" "$mnt" http://archive.ubuntu.com/ubuntu/ || true

	ROOT_UUID=$(blkid -s UUID -o value "$rootp") || true
	EFI_UUID=$(blkid -s UUID -o value "$efi") || true
	cat > "$mnt/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 defaults 0 1
UUID=$EFI_UUID /boot/efi vfat umask=0077 0 2
EOF

	for d in dev proc sys run; do mount --bind /$d "$mnt/$d" || true; done

	chroot "$mnt" /bin/bash -eux -c "apt-get update; apt-get install -y systemd-sysv cloud-init openssh-server grub-efi-amd64 shim-signed; mkdir -p /var/lib/autoprov"
	chroot "$mnt" /bin/bash -eux -c "echo $CONFIG_VERSION > /var/lib/autoprov/config_version"
	chroot "$mnt" /bin/bash -eux -c "sed -i '/GRUB_CMDLINE_LINUX_DEFAULT/ s/\"\(.*\)\"/\"\1 ds=nocloud;s=$SEED_URL\"/g' /etc/default/grub || true; update-grub || true"

	if [ -d "$mnt/sys/firmware/efi" ]; then
		chroot "$mnt" /bin/bash -eux -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck || true; update-grub || true"
	else
		chroot "$mnt" /bin/bash -eux -c "grub-install --target=i386-pc $disk || true; update-grub || true"
	fi

	for d in run sys proc dev; do umount "$mnt/$d" || true; done
	umount "$mnt/boot/efi" || true
	umount "$mnt" || true

	log "Instalación completa en $disk. Se ha escrito config_version y kernel cmdline para cloud-init NoCloud."
}

repair_grub_and_cmdline(){
	local rootp="$1"
	local disk="$2"
	mnt=/mnt/target
	mkdir -p "$mnt"
	mount "$rootp" "$mnt"
	# In TEST_MODE avoid running grub-install; only update config files
	if [ "${TEST_MODE:-0}" = "1" ]; then
		log "TEST_MODE=1: actualizando /etc/default/grub en $rootp (sin grub-install)"
		if [ -f "$mnt/etc/default/grub" ]; then
			sed -i '/GRUB_CMDLINE_LINUX_DEFAULT/ s/"\(.*\)"/"\1 ds=nocloud;s=$SEED_URL"/g' "$mnt/etc/default/grub" || true
		else
			echo "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash ds=nocloud;s=$SEED_URL\"" > "$mnt/etc/default/grub"
		fi
		# ensure grub.cfg exists
		mkdir -p "$mnt/boot/grub"
		echo "set default=0" > "$mnt/boot/grub/grub.cfg" || true
		umount "$mnt" || true
		log "GRUB simulado reparado en $rootp"
		return 0
	fi

	if [ -d "$mnt/boot/efi" ]; then
		mount --bind /dev "$mnt/dev"
		mount --bind /proc "$mnt/proc"
		mount --bind /sys "$mnt/sys"
		chroot "$mnt" /bin/bash -eux -c "sed -i '/GRUB_CMDLINE_LINUX_DEFAULT/ s/\"\(.*\)\"/\"\1 ds=nocloud;s=$SEED_URL\"/g' /etc/default/grub || true; update-grub || true; grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu || true"
		umount "$mnt/dev" || true
		umount "$mnt/proc" || true
		umount "$mnt/sys" || true
	else
		chroot "$mnt" /bin/bash -eux -c "sed -i '/GRUB_CMDLINE_LINUX_DEFAULT/ s/\"\(.*\)\"/\"\1 ds=nocloud;s=$SEED_URL\"/g' /etc/default/grub || true; update-grub || true; grub-install --target=i386-pc $disk || true"
	fi
	umount "$mnt" || true
	log "GRUB reparado y cmdline actualizado en $rootp"
}

main(){
	log "Inicio: comprobando CHECK_UUID/EXCLUDE_UUID y detectando particiones con SO..."

	# If CHECK_UUID provided, try to use it (must match a partition UUID)
	if [ -n "$CHECK_UUID" ]; then
		log "CHECK_UUID=$CHECK_UUID especificado: buscando partición..."
		if is_excluded_uuid "$CHECK_UUID"; then
			err "CHECK_UUID está en la lista EXCLUDE_UUID; no se puede usar. Abortando."
			exit 7
		fi
		rootpart=$(find_partition_by_uuid "$CHECK_UUID" || true)
		if [ -z "$rootpart" ]; then
			err "CHECK_UUID=$CHECK_UUID no encontrado en el sistema. Abortando."
			exit 4
		fi
		# determine parent disk
		parent=$(lsblk -no pkname -nr "$rootpart" 2>/dev/null || true)
		if [ -z "$parent" ]; then
			err "No se pudo determinar el disco padre para $rootpart. Abortando."
			exit 5
		fi
		disk="/dev/$parent"
		log "Usando partición $rootpart en disco $disk según CHECK_UUID."
	else
		# discover OS partitions across non-removable disks, excluding EXCLUDE_UUID
		find_os_partitions
		if [ ${#CANDIDATES[@]} -eq 0 ]; then
			log "No se detectaron particiones con /etc/os-release. Seleccionando disco por prioridad."
			disk=$(choose_disk_by_priority || true)
			if [ -z "$disk" ]; then
				log "Fallo al seleccionar por prioridad; usando detector de disco simple."
				disk=$(detect_internal_disk || true)
			fi
			if [ -z "$disk" ]; then
				err "No se detectó ningún disco interno no-removible. Abortando."
				exit 3
			fi
			log "Disco objetivo para instalación: $disk"
			rootpart=""
		elif [ ${#CANDIDATES[@]} -eq 1 ]; then
			rootpart="${CANDIDATES[0]}"
			parent=$(lsblk -no pkname -nr "$rootpart" 2>/dev/null || true)
			disk="/dev/$parent"
			log "Partición raíz detectada: $rootpart en disco $disk"
		else
			err "Se detectaron múltiples particiones con sistemas instalados:"
			for p in "${CANDIDATES[@]}"; do
				uuid=$(blkid -s UUID -o value "$p" 2>/dev/null || true)
				echo "  - $p (UUID=$uuid)"
			done
			err "Establece CHECK_UUID al UUID de la partición que quieres gestionar y vuelve a ejecutar. Abortando."
			exit 6
		fi
	fi

	if check_os_version "$rootpart"; then
		log "Versión Ubuntu $RELEASE detectada."
		if check_grub_cmdline "$rootpart"; then
			log "GRUB/cmdline ya contiene ds=nocloud; comprobando config_version..."
			if check_config_version "$rootpart"; then
				log "config_version presente. Todo correcto. Forzando arranque desde HDD."
				# try to set firmware boot to disk using efibootmgr if available
				if command -v efibootmgr >/dev/null 2>&1; then
					efibootmgr -o $(efibootmgr -v | awk '/Boot[0-9A-Fa-f]+/ {print substr($1,5)}' | head -n1) || true
				fi
				log "Listo. Salga el USB y arranque desde HDD.";
				exit 0
			else
				log "config_version no encontrada. Escribiendo y reparando GRUB.";
				# mount and write config_version then repair grub
				mnt=/mnt/target
				mkdir -p "$mnt"
				mount "$rootpart" "$mnt"
				mkdir -p "$mnt/var/lib/autoprov"
				echo "$CONFIG_VERSION" > "$mnt/var/lib/autoprov/config_version"
				umount "$mnt" || true
				repair_grub_and_cmdline "$rootpart" "$disk"
				log "Acción completada. Forzar arranque desde HDD."; exit 0
			fi
		else
			log "GRUB no tiene ds=nocloud; reparando GRUB/cmdline.";
			repair_grub_and_cmdline "$rootpart" "$disk"
			# Ensure config_version exists so next run treats system as boot-ready
			mnt=/mnt/target
			mkdir -p "$mnt"
			if mount "$rootpart" "$mnt" 2>/dev/null; then
				mkdir -p "$mnt/var/lib/autoprov"
				echo "$CONFIG_VERSION" > "$mnt/var/lib/autoprov/config_version"
				umount "$mnt" || true
				log "Se añadió config_version en $rootpart"
			else
				log "No se pudo montar $rootpart para escribir config_version (modo TEST o inaccesible)."
			fi
			exit 0
		fi
	else
		log "SO detectado pero NO es Ubuntu $RELEASE. Reinstalando.";
		install_with_debootstrap "$disk"
		log "Reiniciando en 5 segundos para arrancar desde HDD.";
		sleep 5; reboot || true
		exit 0
	fi
}

load_persist_env || true
parse_exclude_uuids

if [ "$(id -u)" -ne 0 ]; then
	echo "Este script debe ejecutarse como root." >&2
	exit 2
fi

log(){ echo "[+] $*"; }
err(){ echo "[!] $*" >&2; }
main "$@"

# Testing with QEMU (adjust /dev/sdX to your test disk):
# sudo qemu-system-x86_64 \
#   -enable-kvm \
#   -m 4096 \
#   -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
#   -drive if=pflash,format=raw,file=./OVMF_VARS.fd \
#   -drive file=/dev/sdX,format=raw,media=disk,snapshot=on \
#   -boot menu=on \
#   -serial mon:stdio