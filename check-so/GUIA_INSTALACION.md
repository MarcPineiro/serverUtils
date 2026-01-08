# Guía Completa de Instalación - Supervisor + PXE

## Visión General

```
USB Supervisor → Instalador Ubuntu
     ↓
Cloud-init (NoCloud) 
     ↓
Ansible-pull (GitHub)
     ↓
Supervisor PXE operativo
```

## Flujo de Instalación

### 1. Preparación del USB

1. Obtener `installer.env` con:
   - `SEED_URL=https://raw.githubusercontent.com/MarcPineiro/serverUtils/refs/heads/main/check-so/cloud-init/`
   - `EXCLUDE_UUID=<UUID_del_USB>`
   - `CHECK_UUID=<dejar_vacio>`

2. Copiar en USB:
   - El script `autoinstall-ubuntu.sh`
   - El fichero `installer.env` en `/etc/sysconfig/tcedir/installer.env` (o en `TCE_DIR`)

### 2. Arranque y Fase 1 (Instalación)

```bash
# En el live-USB, ejecutar:
sudo bash /path/to/autoinstall-ubuntu.sh
```

**Acciones automáticas:**
- Detecta disco interno
- Verifica Ubuntu 24.04 + cloud-init NoCloud
- Si no existe: **instala** Ubuntu 24.04 via debootstrap
- Si existe pero falta GRUB: **repara** GRUB + añade `ds=nocloud;s=$SEED_URL`
- Escribe `/var/lib/autoprov/config_version` como marca
- Reinicia automáticamente desde HDD

### 3. Fase 2 (Cloud-init + Bootstrap)

**Al arrancar el HDD desde Ubuntu:**

1. El kernel recibe parámetro: `ds=nocloud;s=https://raw.githubusercontent.com/MarcPineiro/serverUtils/refs/heads/main/check-so/cloud-init/`

2. Cloud-init descarga:
   - `user-data` → configuración de sistema + paquetes
   - `meta-data` → hostname, instance-id

3. Cloud-init ejecuta **runcmd** que:
   - Instala python, git, ansible
   - Clona repositorio de configuración
   - Ejecuta **ansible-pull** con playbook supervisor.yml

4. Ansible configura:
   - **dnsmasq**: DHCP + TFTP + DNS local
   - **nginx**: HTTP para boot, preseed, cloud-init
   - **iPXE**: Menú PXE con detección automática

5. Escribe `/var/lib/autoprov/config_version` ✓

### 4. Fase 3 (PXE Server Operativo)

El supervisor es ahora un servidor PXE completo:

```
Clientes → DHCP/TFTP (dnsmasq)
        → Descarga boot script (iPXE)
        → Menu PXE con timeout
        → Auto-selección por MAC o selección manual
```

## Estructura de Ficheros

### Cloud-init (Fase 2 - Bootstrap)

```
/home/mpi/git/personal/serverUtils/check-so/cloud-init/
├── user-data    # Autoinstall + paquetes + ansible-pull
└── meta-data    # instance-id, hostname
```

**URL raw de GitHub:**
```
https://raw.githubusercontent.com/MarcPineiro/serverUtils/refs/heads/main/check-so/cloud-init/
```

### Ansible (Fase 3 - PXE)

```
/home/mpi/git/personal/serverUtils/check-so/ansible/
├── supervisor.yml             # Playbook principal
├── roles/
│   ├── dnsmasq_pxe/          # DHCP + TFTP + DNS
│   │   ├── tasks/main.yml
│   │   ├── templates/dnsmasq.conf.j2
│   │   └── handlers/main.yml
│   ├── nginx_pxe/            # HTTP (boot, preseed, cloud-init)
│   │   ├── tasks/main.yml
│   │   ├── templates/nginx-pxe.conf.j2
│   │   └── handlers/main.yml
│   └── ipxe_bootloader/      # Menú PXE
│       ├── tasks/main.yml
│       ├── templates/
│       │   ├── boot.ipxe.j2
│       │   ├── menu.ipxe.j2
│       │   └── machine-example-*.ipxe.j2
│       └── handlers/main.yml
└── README.md
```

## Comandos Rápidos

### Verificar cloud-init desde el supervisor

```bash
# Logs de cloud-init
sudo cloud-init status
sudo cat /var/log/cloud-init-output.log

# Verificar servicios PXE
sudo systemctl status dnsmasq nginx

# Verificar marca de convergencia
cat /var/lib/autoprov/config_version
```

### Probar acceso a seeds

```bash
# Desde cualquier máquina con conectividad
curl -I https://raw.githubusercontent.com/MarcPineiro/serverUtils/refs/heads/main/check-so/cloud-init/user-data
curl -I https://raw.githubusercontent.com/MarcPineiro/serverUtils/refs/heads/main/check-so/cloud-init/meta-data
```

### Re-ejecutar Ansible manualmente

```bash
# En el supervisor
sudo ansible-pull -U https://github.com/MarcPineiro/serverUtils.git \
  -d ~/serverUtils \
  -C main \
  -i "localhost," \
  personal/serverUtils/check-so/ansible/supervisor.yml \
  -e "ansible_connection=local supervisor_role=pxe_server"
```

## Customización

### Cambiar usuario de bootstrap

En `cloud-init/user-data`, editar:

```yaml
users:
  - name: autoprov        # ← Cambiar nombre
    ...
```

Y en `supervisor.yml`:

```yaml
become_user: autoprov     # ← Cambiar usuario
```

### Cambiar rango DHCP

En `ansible/roles/dnsmasq_pxe/templates/dnsmasq.conf.j2`:

```
dhcp-range=<INICIO>,<FIN>,255.255.255.0,12h
```

### Agregar nueva máquina al menú PXE

1. Editar `ansible/roles/ipxe_bootloader/templates/menu.ipxe.j2`:
   - Agregar MAC a "Known machines"
   - Agregar entrada en el menú

2. Crear nuevo script `machine-example-NEWROLE.ipxe.j2`:
   - Copiar desde ejemplo existente
   - Adaptar kernel/initrd

3. En `ansible/roles/ipxe_bootloader/tasks/main.yml`:
   ```yaml
   - name: Create machine config (New Role)
     template:
       src: machine-example-newrole.ipxe.j2
       dest: "{{ boot_dir }}/machines/newrole.ipxe"
   ```

## Troubleshooting

### Autoinstall no detecta disco

```bash
# Revisar discos disponibles
lsblk -o NAME,UUID,FSTYPE,LABEL

# Excluir USB correctamente en installer.env
EXCLUDE_UUID=<UUID_del_USB>
```

### Cloud-init no ejecuta ansible-pull

```bash
# Ver logs
sudo tail -f /var/log/cloud-init-output.log

# Re-ejecutar manualmente
sudo ansible-pull -vvv -U https://github.com/MarcPineiro/serverUtils.git ...
```

### PXE clientes no reciben DHCP

```bash
# Verificar dnsmasq
sudo systemctl status dnsmasq
sudo journalctl -u dnsmasq -f

# Verificar configuración
sudo cat /etc/dnsmasq.d/pxe.conf
```

### PXE clientes descargan boot pero falla el menú

```bash
# Verificar nginx
sudo systemctl status nginx
sudo tail -f /var/log/nginx/pxe-access.log

# Verificar que boot.ipxe existe
curl http://supervisor/boot/boot.ipxe
curl http://supervisor/boot/menu.ipxe
```

## Archivos Modificados

- ✅ `/home/mpi/git/personal/serverUtils/autoinstall-usb/bootstrap/installer.env`
  - Actualizado `SEED_URL` a GitHub

- ✅ `/home/mpi/git/personal/serverUtils/check-so/autoinstall-ubuntu.sh`
  - Actualizado `SEED_URL` por defecto a GitHub

- ✅ Creados nuevos:
  - `cloud-init/user-data` y `cloud-init/meta-data`
  - `ansible/supervisor.yml`
  - `ansible/roles/dnsmasq_pxe/*`
  - `ansible/roles/nginx_pxe/*`
  - `ansible/roles/ipxe_bootloader/*`
  - `ansible/README.md`

## Próximos Pasos

1. **Pushear cambios a GitHub:**
   ```bash
   cd /home/mpi/git
   git add personal/serverUtils/check-so/
   git commit -m "Fase 2+3: Cloud-init + Ansible PXE server"
   git push
   ```

2. **Descargar kernels PXE:**
   - Ubuntu 24.04: `vmlinuz-generic`, `initrd.img-generic` → `/srv/http/boot/ubuntu/`
   - Debian: kernels netinstall → `/srv/http/boot/debian/`
   - Proxmox: kernels → `/srv/http/boot/proxmox/`

3. **Crear preseed configs:**
   - NAS (Debian): `preseed/nas.cfg`
   - Otros: `preseed/edge.cfg`, `preseed/backup.cfg`

4. **Probar en laboratorio:**
   - Arrancar USB supervisor → instalar Ubuntu
   - Verificar que cloud-init ejecuta Ansible
   - Probar PXE con máquina cliente

5. **Configuración en producción:**
   - Usar HTTPS en nginx
   - Configurar SSH keys en cloud-init
   - Agregar logging centralizado
   - Configurar ansible-pull timer (periodicidad)

