# SystemRescue TestBench
A comprehensive automated hardware verification environment based on SystemRescue 12.03.

## Overview
SystemRescue TestBench is a customized ISO designed to boot any PC or server and automatically perform a complete suite of hardware diagnostics, including:

- System inventory  
- Sensor readings  
- CPU stress tests  
- RAM stress tests  
- Non-destructive disk tests (FIO)  
- Optional destructive disk verification to detect fake or defective drives  
- Automatic log generation inside `/run/archiso/bootmnt/testbench/logs/<hostname>/<timestamp>/`

Boot modes:
- **AUTO**: runs all tests automatically  
- **INTERACTIVE MENU**: shown if a key is pressed within the first 30 seconds  

---

## Project Structure

```
build_iso.sh                 # Generates the custom ISO
overlay/
  etc/systemd/system/testbench.service   # Launches run.sh on boot
  opt/testbench/
      run.sh                 # AUTO mode
      menu.sh                # Interactive menu
      lib/
         common.sh           # Shared helpers
         tests.sh            # All test logic
         config.env          # TestBench configuration
```

---

## 1. Building the Custom ISO

The main script is `build_iso.sh`.

### Requirements

- Linux host  
- `xorriso`, `unsquashfs`, `mksquashfs`, `rsync`  
- Internet access (only required during ISO build)  
- Base ISO: `systemrescue-12.03-amd64.iso`

### Usage

```bash
./build_iso.sh systemrescue-12.03-amd64.iso systemrescue-testbench.iso overlay/
```

### Build Steps

1. Extract original ISO  
2. Locate `airootfs.sfs`  
3. Detect compression type  
4. Unsquash the filesystem  
5. Apply overlay into rootfs  
6. Install tools (fio + optional stressapptest)  
7. Recompress rootfs  
8. Rebuild ISO with the same boot parameters  
9. Generate `.sha256` checksum  

---

## 2. Boot Process

On boot:

1. `testbench.service` starts automatically  
2. It runs `run.sh`  
3. The script shows:  
   *“Press any key in 30s to open the menu”*  
4. If pressed → MENU  
5. If not → AUTO mode  

---

## 3. Configuration (config.env)

| Variable | Description |
|---------|-------------|
| `TEST_LEVEL` | quick / normal / extended |
| `CPU_MINUTES` | CPU stress duration |
| `RAM_MINUTES` | RAM test duration |
| `DISK_FIO_SIZE` | FIO test file size |
| `DISK_FIO_MINUTES` | FIO test duration |
| `EXCLUDE_DISKS` | Disks to exclude (`sda nvme0n1`) |
| `ALLOW_DESTRUCTIVE` | Enables destructive tests |
| `AUTO_DESTRUCTIVE_CONFIRM` | Auto-run destructive tests without prompt |
| `TAIL_VERIFY_MIB` | Tail size to overwrite |
| `RANDOM_TAIL_SAMPLES` | Random destructive samples |
| `RANDOM_TAIL_PERCENT` | Tail % for sampling |

---

## 4. AUTO Mode (run.sh)

Runs:

1. Inventory  
2. Sensors  
3. Disk reports  
4. CPU stress  
5. RAM stress  
6. FIO safe test  
7. Destructive test (optional)  
8. `summary.txt` generation  

Logs stored inside:  
`/run/archiso/bootmnt/testbench/logs/<host>/<timestamp>/`

---

## 5. Interactive Menu

Options:

1. Inventory + Sensors  
2. Disk: real size + firmware + SMART  
3. CPU stress  
4. RAM stress  
5. Disk FIO safe test  
6. Full test  
7. **Destructive disk capacity verification**  
0. Exit  

If `ALLOW_DESTRUCTIVE=0`, option 7 is hidden.

---

## 6. Test Details and Interpretation

### 6.1 System Inventory
File: `system_inventory.txt`

Includes OS, lscpu, lsblk, PCI devices, and last 200 dmesg lines.

**Look for:**
- MCE errors  
- I/O or NVMe resets  
- PCIe faults  

---

### 6.2 Sensors
File: `sensors.txt`

Shows temperature, fan speeds, voltage.

**Normal ranges:**
- CPU under load: 60–90°C  
- Chipset/SoC: 40–70°C  

---

### 6.3 Disk Identity Reports (Non-Destructive)
File: `disk_<dev>_identity.txt`

Includes:
- Kernel-reported size  
- Firmware identity  
- SMART  
- NVMe logs (`id-ctrl`, `id-ns`, `smart-log`)  

**Flag if:**
- Size mismatch  
- Reallocated/Pending sectors  
- NVMe timeouts  
- SMART errors  

---

### 6.4 CPU Stress Test
File: `cpu_stress.txt`

Tools:
- `stress-ng --cpu N --cpu-method matrixprod`
- Fallback: `y-cruncher`

**Failures may indicate:**
- CPU instability  
- VRM issues  
- Faulty RAM  
- Cooling problems  

---

### 6.5 RAM Stress Test
Files:
- `ram_stressapptest.txt`
- or `ram_stressng_vm.txt`

Tools:
- `stressapptest` (preferred)  
- or `stress-ng --vm --verify`

**Any error = unstable RAM**

---

### 6.6 FIO Disk Test (Safe)
File: `disk_fio_randrw.txt`

Random read/write mixed workload.

Flags:
- I/O errors  
- severely low performance  

---

### 6.7 Destructive Capacity Verification (Optional)
⚠ **Destroys data**

Checks for fake drives by:

1. Reading last sector  
2. Overwriting last `TAIL_VERIFY_MIB` MiB  
3. Reading back and hashing  
4. Optional random samples in last %  

**Fake drive signs:**
- Cannot read last sector  
- Overwrite fails  
- Hash mismatch (“wraparound”)  
- dmesg I/O errors  

---

## 7. Summary Report: summary.txt

Contains:

- dmesg critical errors  
- Disk list  
- Key findings  

---

## 8. Disk Exclusion

Set in `config.env`:

```
EXCLUDE_DISKS="sda nvme0n1"
```

All destructive tests skip excluded devices.

---

## 9. Recommended Usage Patterns

### New PC burn-in
AUTO mode → review summary.

### Second-hand disk validation
```
ALLOW_DESTRUCTIVE=1
AUTO_DESTRUCTIVE_CONFIRM=1
```

### Quick diagnostic
Use menu options 1–4.

---

## Conclusion

SystemRescue TestBench provides a robust, automated, and extensible environment for hardware validation, detecting:

- Fake NVMe/SATA drives  
- CPU instability  
- RAM errors  
- Disk failures  
- Sensor anomalies  

It is ideal for homelabs, refurbishing, second-hand hardware validation, or automated provisioning environments.
