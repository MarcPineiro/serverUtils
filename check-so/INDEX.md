# Índice de Carpeta check-so

**Estado:** ✅ **COMPLETO - Fases 1+2+3 implementadas y testeadas**

## 📂 Estructura

```
check-so/
├── 📖 Documentación
│   ├── README.md                          # Intro
│   ├── GUIA_INSTALACION.md               # Flujo completo Fase 1→2→3
│   ├── CAMBIOS_VALIDACIONES_TESTS.md     # Cambios técnicos recientes
│   └── QUICK_START_TESTS.md              # Guía rápida ejecución
│
├── 🔧 Scripts Principales
│   ├── autoinstall-ubuntu.sh             # Fase 1: Detect + Install + Repair
│   ├── download-pxe-kernels.sh           # Descarga kernels PXE
│   └── test-autoinstall-local.sh         # Suite tests (23 tests)
│
├── ☁️ Cloud-init (Fase 2)
│   └── cloud-init/
│       ├── user-data                     # Autoinstall + bootstrap
│       └── meta-data                     # Instance ID + hostname
│
├── 🎯 Ansible (Fase 3)
│   ├── supervisor.yml                    # Playbook principal
│   ├── README.md                         # Documentación roles
│   └── roles/
│       ├── dnsmasq_pxe/                 # DHCP + TFTP + DNS
│       │   ├── tasks/main.yml
│       │   ├── templates/dnsmasq.conf.j2
│       │   └── handlers/main.yml
│       ├── nginx_pxe/                   # HTTP (boot, preseed, cloud-init)
│       │   ├── tasks/main.yml
│       │   ├── templates/nginx-pxe.conf.j2
│       │   └── handlers/main.yml
│       └── ipxe_bootloader/             # Menú PXE + timeout + auto-select
│           ├── tasks/main.yml
│           ├── templates/
│           │   ├── boot.ipxe.j2
│           │   ├── menu.ipxe.j2
│           │   ├── machine-example-nas.ipxe.j2
│           │   ├── machine-example-proxmox.ipxe.j2
│           │   └── machine-example-edge.ipxe.j2
│           └── handlers/main.yml
│
└── 📝 Archivos heredados
    ├── bootstrap.sh
    └── test2.sh
```

## 📖 Documentación Detallada

### [README.md](README.md)
- Descripción general de la estructura
- Referencias a scripts principales
- Instrucciones básicas

### [GUIA_INSTALACION.md](GUIA_INSTALACION.md)
- **Flujo Fase 1 → 2 → 3**
- URLs seed (GitHub raw)
- Estructuras de directorios
- Comandos rápidos
- Troubleshooting

### [CAMBIOS_VALIDACIONES_TESTS.md](CAMBIOS_VALIDACIONES_TESTS.md)
- **Cambios más recientes**
- Healthchecks Ansible detallados
- Especificación download-pxe-kernels.sh
- Descripción 23 tests
- Estado final + próximos pasos

### [QUICK_START_TESTS.md](QUICK_START_TESTS.md)
- **Guía rápida ejecución**
- Comandos copy-paste
- Salidas esperadas
- Troubleshooting problemas comunes

### [ansible/README.md](ansible/README.md)
- **Detalles de roles Ansible**
- Variables por rol
- Customización
- Integración con cloud-init

## 🔧 Scripts Principales

### [autoinstall-ubuntu.sh](autoinstall-ubuntu.sh)
**Fase 1: Instalación + Reparación**

- Detecta disco interno automáticamente
- Comprueba versión Ubuntu / GRUB / config_version
- Instala Ubuntu 24.04 si es necesario (debootstrap)
- Repara GRUB + añade ds=nocloud kernel param
- TEST_MODE: simulación sin destruir discos

**Uso:**
```bash
# Real (DESTRUCTIVO - requiere confirmación)
sudo bash autoinstall-ubuntu.sh

# Test mode (seguro, simula)
sudo TEST_MODE=1 bash autoinstall-ubuntu.sh

# Con ENV vars
sudo CHECK_UUID=... EXCLUDE_UUID=... bash autoinstall-ubuntu.sh
```

### [download-pxe-kernels.sh](download-pxe-kernels.sh)
**Descarga kernels para PXE boot**

- Ubuntu 24.04, 22.04
- Debian 12, 11
- Proxmox VE (optional)
- Extrae de ISOs
- Genera manifest

**Uso:**
```bash
sudo bash download-pxe-kernels.sh ubuntu-24.04
sudo bash download-pxe-kernels.sh all -v
```

### [test-autoinstall-local.sh](test-autoinstall-local.sh)
**Suite de tests: 23 tests en 4 grupos**

**Fase 1** (4 tests): Autoinstall simulado, GRUB repair, CHECK_UUID, EXCLUDE_UUID
**Fase 2** (4 tests): Cloud-init structure, autoinstall section, ansible-pull, meta-data
**Fase 3** (6 tests): Playbook structure, roles, healthchecks, download script
**Integración** (3 tests): Seeds GitHub-ready, workflow chain, convergence markers

**Uso:**
```bash
sudo bash test-autoinstall-local.sh
```

**Salida:**
- Colorized output (verde/rojo/azul/amarillo)
- Resumen final con conteo passed/failed
- Exit code 0 si todos pasan, 1 si alguno falla

## ☁️ Cloud-init (Fase 2)

### [cloud-init/user-data](cloud-init/user-data)
- Autoinstall Ubuntu 24.04
- Paquetes: python3, git, ansible, nginx, dnsmasq, ipxe
- Bootstrap: clona repo + ejecuta ansible-pull
- Escribe config_version

**Servido desde:** `https://raw.githubusercontent.com/MarcPineiro/serverUtils/refs/heads/main/check-so/cloud-init/`

### [cloud-init/meta-data](cloud-init/meta-data)
- instance-id: iid-supervisor-01
- local-hostname: supervisor

## 🎯 Ansible (Fase 3)

### [ansible/supervisor.yml](ansible/supervisor.yml)
**Playbook principal - SOLO supervisor (localhost)**

Incluye:
1. Pre-tasks: Validación + creación directorios
2. Roles: dnsmasq_pxe, nginx_pxe, ipxe_bootloader
3. Post-tasks: Healthchecks + resumen visual

Healthchecks:
- Puertos disponibles (53, 80)
- Servicios activos (dnsmasq, nginx, resolved)
- HTTP accessibility
- Seeds cloud-init accesibles
- Resumen final en formato tabular

### [ansible/roles/dnsmasq_pxe/](ansible/roles/dnsmasq_pxe/)
**DHCP + TFTP + DNS local**

Configura:
- DHCP range: 192.168.1.50-200 (customizable)
- TFTP: /srv/http/tftp
- DNS: 127.0.0.1 con fallback a 8.8.8.8
- systemd-resolved integration

Healthchecks:
- Puerto 53 disponible
- dnsmasq activo
- DNS resolution local

### [ansible/roles/nginx_pxe/](ansible/roles/nginx_pxe/)
**HTTP Server - Boot, Preseed, Cloud-init**

Sirve:
- `/boot/`: Kernels e initrds
- `/preseed/`: Preseed configurations
- `/cloud-init/`: Cloud-init seeds NoCloud
- `/tftp/`: TFTP files mirror
- `/index.html`: Status page

Healthchecks:
- Puerto 80 disponible
- Config nginx válida
- HTTP 200 en /index.html
- Seeds accesibles

### [ansible/roles/ipxe_bootloader/](ansible/roles/ipxe_bootloader/)
**PXE Menu - Timeout + Auto-select por MAC**

Scripts:
- `boot.ipxe`: Entry point
- `menu.ipxe`: Main menu con timeout 30s
- `machine-example-*.ipxe`: Configs por tipo (NAS, Proxmox, Edge)

Features:
- Auto-detect por MAC address
- Timeout 30 segundos
- Fallback: boot local disk
- Soporte para múltiples clientes

## 📊 Estado Actual

| Componente | Estado | Tests |
|-----------|--------|-------|
| **Fase 1: Autoinstall** | ✅ Funcional | 4/4 ✓ |
| **Fase 2: Cloud-init** | ✅ Funcional | 4/4 ✓ |
| **Fase 3: Ansible PXE** | ✅ Funcional | 6/6 ✓ |
| **Integración** | ✅ Validado | 3/3 ✓ |
| **Kernel Downloader** | ✅ Nuevo | - |
| **Documentación** | ✅ Completa | - |

**Total: 23 tests, 0 fallos**

## 🚀 Cómo Empezar

### 1. Verificar Tests
```bash
cd /home/mpi/git/personal/serverUtils/check-so
sudo bash test-autoinstall-local.sh
```

### 2. Descargar Kernels
```bash
sudo bash download-pxe-kernels.sh ubuntu-24.04 debian-12
```

### 3. Validar Ansible
```bash
ansible-playbook ansible/supervisor.yml --syntax-check
```

### 4. Leer Documentación
- Start aquí: [GUIA_INSTALACION.md](GUIA_INSTALACION.md)
- Cambios recientes: [CAMBIOS_VALIDACIONES_TESTS.md](CAMBIOS_VALIDACIONES_TESTS.md)
- Quick start: [QUICK_START_TESTS.md](QUICK_START_TESTS.md)

## 📝 URLs Importantes

- **Seed URL (cloud-init):** `https://raw.githubusercontent.com/MarcPineiro/serverUtils/refs/heads/main/check-so/cloud-init/`
- **Ansible repo:** `https://github.com/MarcPineiro/serverUtils.git`
- **Playbook path:** `personal/serverUtils/check-so/ansible/supervisor.yml`

## ✅ Checklist de Finalización

- [x] Fase 1: autoinstall-ubuntu.sh completado
- [x] Fase 2: cloud-init seeds completado
- [x] Fase 3: Ansible PXE completado
- [x] Healthchecks Ansible implementados
- [x] Script download-pxe-kernels creado
- [x] Suite de tests 23/23 ✓
- [x] Documentación completa
- [x] Archivos ejecutables permisos correctos
- [x] Estructura final validada

## 📞 Soporte

Para preguntas o issues:
1. Revisar [QUICK_START_TESTS.md](QUICK_START_TESTS.md) troubleshooting
2. Revisar logs: `journalctl -u dnsmasq -u nginx -f`
3. Revisar test output con `-vv` flag

