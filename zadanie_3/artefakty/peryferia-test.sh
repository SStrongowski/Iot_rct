#!/bin/bash
# peryferia-test.sh — lista peryferiów płytki z dowodem działania
#
# Dla każdego urządzenia pokazuje: sterownik, pochodzenie (węzeł device tree
# albo wykrycie na magistrali PCI/USB) i wynik prostego testu.
#
# Uruchamiać na płytce:   sudo bash peryferia-test.sh | tee peryferia.txt
#
# UWAGA: test USB zapisuje dane na początek pendrive'a — używać wyłącznie
# z testowym obrazem (usb.img w QEMU), nigdy z nośnikiem z danymi.

OK="[ OK ]"; FAIL="[FAIL]"

section() { echo; echo "================ $* ================"; }

# Nazwa sterownika urządzenia albo BRAK, gdy żaden się nie podłączył
drvname() {
    if [ -L "$1/driver" ]; then
        basename "$(readlink -f "$1/driver")"
    else
        echo "BRAK"
    fi
}

# Sterownik i pochodzenie urządzenia na podstawie /sys
show_dev() {
    local dev="$1" node
    echo "urządzenie: ${dev#/sys/devices/}"
    echo "sterownik:  $(drvname "$dev")"
    if [ -L "$dev/of_node" ]; then
        node=$(readlink -f "$dev/of_node")
        echo "węzeł DT:   ${node#/sys/firmware/devicetree/base}"
    else
        echo "węzeł DT:   brak (urządzenie wykryte na magistrali)"
    fi
}

result() { if [ "$1" -eq 0 ]; then echo "$OK $2"; else echo "$FAIL $2"; fi; }

echo "Raport peryferiów: $(hostname), $(uname -r), $(date '+%F %T')"
echo "Płytka: $(tr -d '\0' < /proc/device-tree/compatible)"

# ---------------------------------------------------------------------------
section "1. UART (port szeregowy PL011)"
show_dev "$(readlink -f /sys/class/tty/ttyAMA0/device)"
echo ">>> test UART: ten napis powinien pojawić się w konsoli QEMU <<<" > /dev/ttyAMA0
result $? "zapis do /dev/ttyAMA0 (sprawdź okno konsoli QEMU)"

# ---------------------------------------------------------------------------
section "2. RTC (zegar czasu rzeczywistego PL031)"
if [ -e /sys/class/rtc/rtc0 ]; then
    show_dev "$(readlink -f /sys/class/rtc/rtc0/device)"
    echo "czas z RTC: $(cat /sys/class/rtc/rtc0/date) $(cat /sys/class/rtc/rtc0/time) UTC"
    hwclock -r > /dev/null 2>&1
    result $? "odczyt RTC (hwclock -r)"
else
    echo "$FAIL brak /sys/class/rtc/rtc0 (RTC wyłączony w DT?)"
fi

# ---------------------------------------------------------------------------
section "3. GPIO (kontroler PL061)"
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
for chip in /sys/bus/gpio/devices/gpiochip*; do
    [ -e "$chip" ] || continue
    show_dev "$(readlink -f "$chip/..")"
done
echo "--- linie GPIO (debugfs) ---"
cat /sys/kernel/debug/gpio
grep -q 'GPIO Key Poweroff' /sys/kernel/debug/gpio
result $? "linia GPIO zajęta przez przycisk zasilania"

# ---------------------------------------------------------------------------
section "4. Przycisk zasilania (gpio-keys, korzysta z GPIO PL061)"
show_dev /sys/bus/platform/devices/gpio-keys
grep -B1 -A4 'Name="gpio-keys"' /proc/bus/input/devices
grep -q 'Name="gpio-keys"' /proc/bus/input/devices
result $? "urządzenie wejściowe gpio-keys zarejestrowane"
echo "test ręczny: monitor QEMU (Ctrl+A, C) -> system_powerdown -> płytka się wyłącza"

# ---------------------------------------------------------------------------
section "5. PCIe (kontroler i urządzenia)"
for host in /sys/bus/platform/devices/*pcie*; do
    [ -e "$host" ] && show_dev "$(readlink -f "$host")"
done
echo "--- urządzenia na magistrali PCI ---"
for d in /sys/bus/pci/devices/*; do
    printf "%s  vendor=%s device=%s class=%s  sterownik=%s\n" \
        "$(basename "$d")" "$(cat "$d/vendor")" "$(cat "$d/device")" \
        "$(cat "$d/class")" "$(drvname "$d")"
done
[ -n "$(ls /sys/bus/pci/devices/)" ]
result $? "wykryto urządzenia PCI"

# ---------------------------------------------------------------------------
section "6. Ethernet"
for i in /sys/class/net/en*; do
    [ -e "$i" ] || continue
    echo "interfejs:  $(basename "$i")"
    show_dev "$(readlink -f "$i/device")"
done
ip -br address show
getent hosts distfiles.gentoo.org
result $? "DNS: rozwiązanie nazwy distfiles.gentoo.org"
wget --spider --timeout=30 --tries=2 https://distfiles.gentoo.org/ 2>&1 | tail -n 3
result "${PIPESTATUS[0]}" "połączenie HTTPS z distfiles.gentoo.org"

# ---------------------------------------------------------------------------
section "7. Dysk systemowy (virtio-blk)"
show_dev "$(readlink -f /sys/block/vda/device)"
lsblk /dev/vda
findmnt / > /dev/null
result $? "system plików root zamontowany"

# ---------------------------------------------------------------------------
section "8. USB"
for hcd in /sys/bus/usb/devices/usb*; do
    [ -e "$hcd" ] || continue
    echo "--- kontroler ($(basename "$hcd")) ---"
    show_dev "$(readlink -f "$hcd/..")"
done
echo "--- urządzenia USB ---"
for d in /sys/bus/usb/devices/[0-9]*-*; do
    [ -f "$d/product" ] || continue
    printf "%s  %s:%s  %s\n" "$(basename "$d")" \
        "$(cat "$d/idVendor")" "$(cat "$d/idProduct")" "$(cat "$d/product")"
done
echo "--- interfejsy USB i ich sterowniki ---"
for i in /sys/bus/usb/devices/*:*; do
    echo "$(basename "$i")  sterownik=$(drvname "$i")"
done

grep -q 'Name="QEMU QEMU USB Keyboard"' /proc/bus/input/devices
result $? "klawiatura USB zarejestrowana jako urządzenie wejściowe"

usbdisk=""
for b in /sys/block/sd*; do
    [ -e "$b" ] || continue
    readlink -f "$b" | grep -q '/usb' && usbdisk="/dev/$(basename "$b")"
done
if [ -n "$usbdisk" ]; then
    echo "pendrive USB: $usbdisk"
    lsblk "$usbdisk"
    dd if=/dev/urandom of=/tmp/usb-w bs=1M count=1 status=none
    dd if=/tmp/usb-w of="$usbdisk" bs=1M count=1 conv=fsync status=none
    dd if="$usbdisk" of=/tmp/usb-r bs=1M count=1 iflag=direct status=none
    cmp -s /tmp/usb-w /tmp/usb-r
    result $? "zapis i odczyt 1 MB na pendrive USB (sumy się zgadzają)"
    rm -f /tmp/usb-w /tmp/usb-r
else
    echo "$FAIL nie znaleziono pendrive'a USB"
fi

# ---------------------------------------------------------------------------
section "9. Urządzenia platformowe bez sterownika"
none=1
for d in /sys/bus/platform/devices/* /sys/bus/amba/devices/*; do
    [ -e "$d" ] || continue
    if [ ! -e "$d/driver" ]; then echo "bez sterownika: $(basename "$d")"; none=0; fi
done
[ "$none" -eq 1 ] && echo "wszystkie urządzenia z device tree mają sterownik"

# ---------------------------------------------------------------------------
section "Nieobecne na płytce QEMU virt (wymagają Raspberry Pi 5)"
echo "WiFi 2.4/5 GHz, I2C, SPI, audio, HDMI"
