# Start A/B (zadanie 6): uruchamia slot wskazany przez zmienną "slot"
if test -z "${slot}"; then setenv slot A; saveenv; fi
if test "${slot}" = "B"; then setenv rootpart 3; else setenv rootpart 2; fi
echo "=== Start slotu ${slot} (partycja ${rootpart}), bootcount=${bootcount} ==="

part uuid virtio 0:${rootpart} rootuuid
setenv bootargs "root=PARTUUID=${rootuuid} rw rootwait console=ttyAMA0 panic=10"
load virtio 0:${rootpart} ${kernel_addr_r} /boot/Image
bootefi ${kernel_addr_r} ${fdtcontroladdr}

# Tu dochodzimy tylko, gdy start się nie udał: restart podbije licznik
echo "=== Start slotu ${slot} nieudany, restart ==="
reset
