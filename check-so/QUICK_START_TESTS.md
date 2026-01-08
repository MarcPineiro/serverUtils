# Guía Rápida - Ejecución de Tests y Verificaciones

## Ejecución rápida

### 1. Ejecutar suite de tests completa

```bash
# Requiere root (para loopback disks)
cd /home/mpi/git/personal/serverUtils/check-so
sudo bash test-autoinstall-local.sh
```

**Salida esperada:**
```
╔════════════════════════════════════════════════════════════╗
║  AUTOINSTALL + CLOUD-INIT + ANSIBLE TEST SUITE            ║
╚════════════════════════════════════════════════════════════╝

[*] Using tmpdir: /tmp/...
[*] Scripts: autoinstall=...

=== FASE 1: Autoinstall Ubuntu (simulated) ===
[✓] TEST 1.1: Simulated install completed
[✓] TEST 1.1.1: etc/os-release exists
[✓] TEST 1.1.2: var/lib/autoprov/config_version exists
[✓] TEST 1.2: GRUB repair completed
...

╔════════════════════════════════════════════════════════════╗
║  TEST SUMMARY                                              ║
╠════════════════════════════════════════════════════════════╣
║  Passed: 23
║  Failed: 0
║  Total:  23
╚════════════════════════════════════════════════════════════╝

✓ All tests passed!
```

### 2. Descargar kernels PXE

```bash
# Descargar Ubuntu 24.04 solamente
sudo bash download-pxe-kernels.sh ubuntu-24.04

# Descargar Ubuntu + Debian
sudo bash download-pxe-kernels.sh ubuntu-24.04 debian-12

# Descargar todo (recomendado, ~500MB)
sudo bash download-pxe-kernels.sh all

# Con output verbose
sudo bash download-pxe-kernels.sh -v ubuntu-24.04
```

**Archivos generados:**
```
/srv/http/boot/
├── ubuntu/
│   ├── vmlinuz-24.04
│   ├── initrd-24.04
│   └── ... (más versiones)
├── debian/
│   ├── vmlinuz-debian-12
│   ├── initrd-debian-12.gz
│   └── ... (más versiones)
└── KERNELS_MANIFEST.md
```

### 3. Verificar Ansible syntax (sin ejecutar)

```bash
# Validar sintaxis YAML
cd /home/mpi/git/personal/serverUtils/check-so
ansible-playbook ansible/supervisor.yml --syntax-check

# Ver qué haría (dry-run)
ansible-playbook -i "localhost," \
  -c local \
  ansible/supervisor.yml \
  --check
```

### 4. Verificar cloud-init seeds

```bash
# Verificar que los ficheros existen
ls -la cloud-init/

# Ver contenido
cat cloud-init/user-data | head -20
cat cloud-init/meta-data

# Validar YAML
python3 -m yaml < cloud-init/user-data

# Verificar que sería accesible vía GitHub
curl -I https://raw.githubusercontent.com/MarcPineiro/serverUtils/refs/heads/main/check-so/cloud-init/user-data
```

### 5. Flujo end-to-end simulado (sin modificar discos)

```bash
# Terminal 1: Ejecutar autoinstall en TEST_MODE
export TEST_MODE=1
export TEST_DISK=/dev/loop0  # (solo si tienes loop disponible)
bash autoinstall-ubuntu.sh

# Terminal 2 (en otra ventana): Monitorear
watch -n 1 'cat /var/lib/autoprov/config_version 2>/dev/null || echo "Not ready"'
```

---

## Verificación manual de componentes

### Health check manual de Ansible

```bash
# 1. Syntax
ansible-playbook ansible/supervisor.yml --syntax-check

# 2. Variables y roles
ansible-playbook ansible/supervisor.yml -i "localhost," -c local -e 'ansible_connection=local' -vvv

# 3. Healthchecks específicos
ansible-playbook ansible/supervisor.yml -i "localhost," -c local \
  -t "HEALTHCHECK" \
  -e 'ansible_connection=local' -v
```

### Health check manual de servicios (después de ejecutar Ansible)

```bash
# DNS (dnsmasq en puerto 53)
nslookup supervisor.local 127.0.0.1
dig supervisor.local @127.0.0.1

# HTTP (nginx en puerto 80)
curl -v http://localhost/index.html
curl -I http://localhost/cloud-init/user-data
curl -I http://localhost/boot/menu.ipxe

# TFTP (puerto 69)
tftp localhost -c get pxelinux.cfg/default

# Servicios activos
systemctl status dnsmasq nginx systemd-resolved

# Logs
journalctl -u dnsmasq -u nginx -n 50
```

---

## Interpretación de resultados

### Tests Exitosos
- Verde `[✓]`: El test pasó correctamente
- La línea de salida muestra qué validó
- Contador de `Passed` aumenta

### Tests Fallidos
- Rojo `[✗]`: El test falló
- Mensaje describe por qué falló
- Contador de `Failed` aumenta

### Ejemplo de test exitoso:
```
[✓] TEST 1.1: Simulated install completed
[✓] TEST 1.1.1: etc/os-release exists
[✓] TEST 1.1.2: var/lib/autoprov/config_version exists
```

### Ejemplo de test fallido:
```
[✗] TEST 2.2: user-data missing autoinstall
     (Significa: grep -q "autoinstall:" user-data falló)
```

---

## Troubleshooting

### Error: "losetup: cannot open /dev/loop0: No such file or device"

```bash
# Cargar módulo loop
sudo modprobe loop

# Crear loop devices
sudo mknod /dev/loop0 b 7 0
sudo mknod /dev/loop1 b 7 1

# O recrear todos
sudo losetup -f
```

### Error: "Cannot mount partition"

```bash
# Verificar permisos
ls -la /dev/loop*

# Ejecutar con sudo
sudo bash test-autoinstall-local.sh
```

### Error: "Ansible module not found"

```bash
# Instalar Ansible
sudo apt-get update
sudo apt-get install -y ansible

# O si usas venv
python3 -m pip install ansible
```

---

## CI/CD Integration (opcional)

### GitHub Actions workflow

```yaml
# .github/workflows/test-autoinstall.yml
name: Test Autoinstall Suite

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run autoinstall tests
        run: |
          cd personal/serverUtils/check-so
          sudo bash test-autoinstall-local.sh
      - name: Validate Ansible
        run: |
          ansible-playbook \
            personal/serverUtils/check-so/ansible/supervisor.yml \
            --syntax-check
```

---

## Métricas útiles

```bash
# Tiempo total de tests
time sudo bash test-autoinstall-local.sh

# Espacio en disco de kernels
du -sh /srv/http/boot/

# Número de tests vs passed
grep -c "\[✓\]" test-autoinstall-local.sh.log || true
```

---

## Documentación

- [GUIA_INSTALACION.md](GUIA_INSTALACION.md) - Flujo completo Fase 1→2→3
- [CAMBIOS_VALIDACIONES_TESTS.md](CAMBIOS_VALIDACIONES_TESTS.md) - Detalles técnicos
- [ansible/README.md](ansible/README.md) - Roles Ansible en detalle

