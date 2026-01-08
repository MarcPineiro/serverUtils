# Configuración Ansible - PXE Server

Estructura de roles Ansible para configurar el **supervisor** como servidor PXE completo.

## Estructura

```
ansible/
├── supervisor.yml                 # Playbook principal
└── roles/
    ├── dnsmasq_pxe/              # DHCP + TFTP + DNS local
    │   ├── tasks/
    │   │   └── main.yml
    │   ├── templates/
    │   │   └── dnsmasq.conf.j2
    │   └── handlers/
    │       └── main.yml
    ├── nginx_pxe/                # HTTP server (boot, preseed, cloud-init)
    │   ├── tasks/
    │   │   └── main.yml
    │   ├── templates/
    │   │   └── nginx-pxe.conf.j2
    │   └── handlers/
    │       └── main.yml
    └── ipxe_bootloader/          # iPXE menu y configuración
        ├── tasks/
        │   └── main.yml
        ├── templates/
        │   ├── boot.ipxe.j2
        │   ├── menu.ipxe.j2
        │   ├── machine-example-nas.ipxe.j2
        │   ├── machine-example-proxmox.ipxe.j2
        │   └── machine-example-edge.ipxe.j2
        └── handlers/
            └── main.yml
```

## Roles

### `dnsmasq_pxe`

Configura **dnsmasq** para proporcionar:
- DHCP con rango configurable
- TFTP para servir archivos PXE
- DNS local con fallback a Google DNS
- Resolución de `supervisor.local`

**Variables principales:**
- `pxe_server_ip`: IP del supervisor (default: 192.168.1.1)
- `pxe_dhcp_range_start`: Inicio del rango DHCP (default: 192.168.1.50)
- `pxe_dhcp_range_end`: Fin del rango DHCP (default: 192.168.1.200)
- `tftp_root`: Raíz TFTP (default: /srv/http/tftp)

### `nginx_pxe`

Configura **nginx** como servidor HTTP para servir:
- Kernels e initrds (`/boot/`)
- Configuraciones preseed (`/preseed/`)
- Seeds cloud-init NoCloud (`/cloud-init/`)
- Archivos TFTP como mirror (`/tftp/`)

Incluye:
- Configuración de caché apropiada
- Listados automáticos de directorios
- Tipos MIME correctos

### `ipxe_bootloader`

Proporciona:
- Scripts iPXE para menú PXE interactivo
- Detección automática de máquinas por MAC
- Timeout configurable (30s por defecto) para auto-boot
- Ejemplos de configuración per-máquina:
  - NAS (Debian + OMV)
  - Proxmox Server
  - Edge Node (Ubuntu)

**Archivos principales:**
- `boot.ipxe`: Entry point (sirve como primera cadena)
- `menu.ipxe`: Menú principal con lógica de auto-selección y timeout
- `machine-example-*.ipxe`: Configuraciones específicas por rol

## Instalación y uso

### Ejecución con Ansible Pull (desde cloud-init)

El `cloud-init/user-data` ejecuta automáticamente:

```bash
ansible-pull -U https://github.com/MarcPineiro/serverUtils.git \
  -d /home/autoprov/serverUtils \
  -C main \
  -i "localhost," \
  personal/serverUtils/check-so/ansible/supervisor.yml \
  -e "ansible_connection=local supervisor_role=pxe_server"
```

### Ejecución manual con Ansible Push

```bash
git clone https://github.com/MarcPineiro/serverUtils.git
cd serverUtils

# Ejecutar en el supervisor (localhost)
ansible-playbook personal/serverUtils/check-so/ansible/supervisor.yml \
  -i "localhost," \
  -c local \
  -b  # become/sudo

# O en una máquina remota
ansible-playbook personal/serverUtils/check-so/ansible/supervisor.yml \
  -i supervisor_ip_or_hostname, \
  -b
```

## Customización

### Cambiar rango DHCP

Edita `roles/dnsmasq_pxe/templates/dnsmasq.conf.j2` o pasa variables a ansible-playbook:

```bash
ansible-playbook supervisor.yml \
  -e "pxe_server_ip=192.168.2.1" \
  -e "pxe_dhcp_range_start=192.168.2.50" \
  -e "pxe_dhcp_range_end=192.168.2.200"
```

### Añadir máquinas al menú PXE

1. Edita `roles/ipxe_bootloader/templates/menu.ipxe.j2`
2. Añade nueva entrada en la sección "Known machines"
3. Crea nuevo script en `roles/ipxe_bootloader/templates/machine-example-NEWROLE.ipxe.j2`
4. Copia tarea correspondiente en `roles/ipxe_bootloader/tasks/main.yml`

Ejemplo (agregar "backup"):

```j2
isset ${machine_backup_mac} || set machine_backup_mac 08:00:27:00:00:04
```

Y en el menú:
```j2
iseq ${machine_mac} ${machine_backup_mac} && goto backup_boot
```

### Cambiar timeouts del menú

En `roles/ipxe_bootloader/templates/menu.ipxe.j2`, busca `menu-timeout`:

```j2
set menu-timeout 30000  # 30 segundos en milisegundos
```

Para 60 segundos: `60000`

## Verificación y Troubleshooting

### Verificar que nginx sirve archivos

```bash
curl http://supervisor:80/cloud-init/user-data
curl http://supervisor:80/boot/menu.ipxe
```

### Verificar DHCP/TFTP

```bash
sudo systemctl status dnsmasq
sudo journalctl -u dnsmasq -f
```

### Verificar logs iPXE

Los clientes PXE mostrarán mensajes en pantalla. Si hay problemas:

1. Verificar que dnsmasq entrega iPXE como primera cadena:
   ```bash
   sudo tail -f /var/log/dnsmasq.log
   ```

2. Verificar que nginx devuelve boot scripts:
   ```bash
   sudo tail -f /var/log/nginx/pxe-access.log
   ```

3. Probar conectividad de red y DHCP desde cliente

## Variables de Entrada (cloud-init / ansible-pull)

En `cloud-init/user-data`, se pasan via `-e`:

- `ansible_connection=local`: Ejecutar localmente sin SSH
- `supervisor_role=pxe_server`: Activar roles PXE

Puedes añadir más variables como `custom_seed_url`, `custom_dns_servers`, etc.

## Integración con cloud-init

El playbook se ejecuta automáticamente durante el primer boot via cloud-init:

1. Cloud-init descarga este playbook de GitHub
2. Ejecuta `ansible-pull` con configuración local
3. Escribe `/var/lib/autoprov/config_version` como marca de convergencia
4. Servicios dnsmasq y nginx se inician automáticamente

## Próximos pasos

1. **Agregar preseed para Debian/NAS**: Crear `preseed/nas.cfg`
2. **Agregar kernels PXE**: Descargar y colocar en `/srv/http/boot/debian/`, `/srv/http/boot/ubuntu/`, etc.
3. **Configurar HTTPS**: Usar Let's Encrypt + nginx SSL
4. **Ansible-pull timer**: Agregar systemd timer para convergencia periódica
5. **Logging centralizado**: Integrar con ELK stack o similares

