if [ -f /mnt/persist/state/bootstrapped.ok ]; then
  echo "Ya provisionado, saliendo"
  exit 0
fi

mkdir -p /mnt/persist/state
touch /mnt/persist/state/bootstrapped.ok
