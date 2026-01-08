# Pruebas y verificación para `autoinstall-ubuntu.sh`

Este README explica cómo probar localmente (sin dañar discos reales) y cómo verificar/reparar GRUB y cloud-init tras ejecutar `autoinstall-ubuntu.sh`.

Archivos relevantes:
- `autoinstall-ubuntu.sh` — script principal de fase 1.
- `test-autoinstall-local.sh` — crea un disco loopback y ejecuta el script en `TEST_MODE=1`.

Pruebas locales (seguras)

1. Ejecuta el test como root:

```bash
cd personal/serverUtils/check-so
sudo bash test-autoinstall-local.sh correct-noconfig
```

Casos disponibles: `none`, `wrong`, `correct-noconfig`, `correct-config`, `grub-no-ds`.

Qué hace el test:
- Crea una imagen loopback de 512MiB.
- Crea particiones (EFI + root) y forma sistemas de archivos.
- Población mínima de `/etc/os-release` y (opcional) `/var/lib/autoprov/config_version`.
- Ejecuta `autoinstall-ubuntu.sh` con `TEST_MODE=1 TEST_DISK=<loop>`.

Verificaciones manuales (tras ejecutar en vivo)

- Comprobar `os-release`:

```bash
mount /dev/sdXY /mnt
cat /mnt/etc/os-release
umount /mnt
```

- Comprobar `config_version`:

```bash
mount /dev/sdXY /mnt
cat /mnt/var/lib/autoprov/config_version || true
umount /mnt
```

- Verificar que GRUB contiene `ds=nocloud` (kernel cmdline):

```bash
mount /dev/sdXY /mnt
grep -R "ds=nocloud" /mnt/boot/grub/grub.cfg /mnt/etc/default/grub || true
umount /mnt
```

- Revisar logs de cloud-init (después del primer arranque):

```bash
journalctl -u cloud-init -b
tail -n 200 /var/log/cloud-init.log
```

Reparación manual de GRUB y cmdline (si no quieres usar el script)

1. Arranca desde live-USB y monta la partición raíz del HDD:

```bash
sudo mount /dev/sdXY /mnt
sudo mount --bind /dev /mnt/dev
sudo mount --bind /proc /mnt/proc
sudo mount --bind /sys /mnt/sys
sudo chroot /mnt /bin/bash
```

2. Añade `ds=nocloud;s=<SEED_URL>` a `/etc/default/grub` en la variable `GRUB_CMDLINE_LINUX_DEFAULT` y ejecuta:

```bash
update-grub
```

3. Reinstala GRUB en EFI (si corresponde):

```bash
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu
update-grub
```

4. Sal del chroot y desmonta:

```bash
exit
umount /mnt/dev /mnt/proc /mnt/sys /mnt
```

Notas y recomendaciones
- En modo real (sin `TEST_MODE`) el script usa `sgdisk` y `debootstrap` y es destructivo: haz backup antes.
- Ajusta `SEED_URL` en `autoinstall-ubuntu.sh` a la URL real de NoCloud.
- Para pruebas rápidas en máquinas reales, puedes exportar `TEST_MODE=1` para evitar modificar el disco.



Ejemplo `installer.env` colocado en la partición `TINYDATA` bajo `ENV/installer.env`:

```
EXCLUDE_UUID=2EC5-FD8C,965f1e37-340a-4c1f-852f-ee53a6ab396d
CHECK_UUID=
SEED_URL=https://config.tudominio/supervisor/24.04/
CONFIG_VERSION=1
```
```
EXCLUDE_UUID=2EC5-FD8C,965f1e37-340a-4c1f-852f-ee53a6ab396d
CHECK_UUID=
SEED_URL=https://config.tudominio/supervisor/24.04/
CONFIG_VERSION=1
```

Selección automática de disco (cuando `CHECK_UUID` no está definido)
- El script selecciona un disco no-removible según esta prioridad:
	1. NVMe (transport = nvme)
	2. SSD (no-rotational)
	3. Discos rotacionales
	Dentro de cada clase, se prefiere el disco con mayor tamaño.
- Si un disco tiene alguna partición cuyo `UUID` o `PARTUUID` esté en `EXCLUDE_UUID`, ese disco se excluye de la selección.
- El instalador borrará la tabla de particiones del disco elegido (`sgdisk --zap-all`) antes de crear nuevas particiones, por lo que todos los datos y particiones actuales en ese disco se perderán.


Comportamiento cuando hay múltiples sistemas instalados
- Si el script detecta más de una partición con `/etc/os-release` y `CHECK_UUID` no está establecido, se detendrá y listará las particiones encontradas con sus UUIDs. Establece `CHECK_UUID=<UUID>` y vuelve a ejecutar para seleccionar la partición a gestionar.

Ejemplo: ejecutar comprobación forzada sobre una partición concreta (sin modificar disco en modo prueba):

```bash
sudo CHECK_UUID=xxxx-xxxx TEST_MODE=1 bash personal/serverUtils/check-so/autoinstall-ubuntu.sh
```

