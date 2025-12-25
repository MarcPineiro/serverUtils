# Alpine AutoProvision ISO (ultraligera)

Este proyecto genera una ISO de Alpine Linux muy ligera con:
- Autorun en boot (OpenRC / local.d)
- Descarga y ejecución de un script desde GitHub
- Fallback offline embebido en la ISO
- Paquetes APK descargados dentro de la ISO para poder instalar sin red (opcional)
- Preparación de USB con 3 particiones: ISO + ENV + PERSIST

## Estructura relevante

- `overlay/` se empaqueta como `apkovl` y se copia en la raíz de la ISO:
  - `overlay/etc/local.d/00-mount.start` monta particiones `ENV` y `PERSIST`
  - `overlay/etc/local.d/autorun.start` ejecuta el autorun
  - `overlay/opt/autorun/default.env` variables por defecto dentro de la ISO
  - `overlay/opt/autorun/bootstrap.fallback.sh` fallback si no hay red o falla GitHub

- `alpine/pkgs.txt` lista de paquetes para incluir offline (si `apk` existe en el builder)
- `alpine/repositories.txt` repositorios para `apk fetch`
- `alpine/iso/alpine.iso.url` URL de la ISO base

## Variables de configuración (ENV)

El autorun busca un fichero de variables en este orden:
1) USB: `/mnt/env/env/autorun.env` (partición con label `ENV`)
2) ISO: `/opt/autorun/default.env`
3) Defaults hardcoded en `autorun.start`

Ejemplo de `autorun.env`:

```sh
GITHUB_BOOTSTRAP_URL="https://github.com/MarcPineiro/serverUtils/blob/b425c59aa10453a10c1603573fccd69b91c76b2b/check-so/bootstrap.sh"
BOOTSTRAP_TIMEOUT_SEC="15"
BOOTSTRAP_DEST="/opt/autorun/bootstrap.sh"
