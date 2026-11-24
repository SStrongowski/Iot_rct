#!/bin/sh
# provision-data.sh — jednorazowe przygotowanie zaszyfrowanej partycji danych (układ A/B).
#
#  1. LUKS2 z hasłem awaryjnym (slot 0)
#  2. komponenty systemd-pcrlock opisujące zaufany start OBU slotów:
#       PCR 0  firmware (U-Boot)            — z dziennika zdarzeń
#       PCR 4  kernel slotu A i slotu B     — warianty (300-kernel.pcrlock.d/A, B)
#       PCR 7  polityka secure boot         — lock-secureboot-policy + z dziennika
#       PCR 9  parametry kernela A i B      — warianty (710-kernel-cmdline.pcrlock.d/A, B)
#  3. polityka w TPM (indeks NV), klucz zapieczętowany pod nią (slot TPM2)
#  4. system plików i montowanie przez crypttab/data.mount
#
# Stan pcrlock (komponenty + opis polityki) leży na partycji persist, wspólnej
# dla slotów — przeżywa aktualizacje. Uruchamiać w zaufanym stanie startu
# i NIE przy pierwszym starcie z danym TPM (pomiary nvpcr-init w PCR 9).
# UWAGA: kasuje całą zawartość partycji data.
set -eu

DEV=/dev/disk/by-partlabel/data
TPM=/dev/tpmrm0
PCRS=0+4+7+9
P=/usr/lib/systemd/systemd-pcrlock
STATE=/persist/pcrlock
COMP=$STATE/pcrlock.d
POLICY=$STATE/pcrlock.json
MNT=/mnt/slot-provision

log() { echo; echo "== $*"; }
die() { echo "BŁĄD: $*" >&2; exit 1; }
pcrlock() { "$P" --components="$COMP" "$@"; }

# systemd-pcrlock nie pozwala wskazać układu TPM: odłącz fTPM (OP-TEE), jeśli jest
single_tpm() {
    drv=/sys/bus/tee/drivers/optee-ftpm
    if [ -d "$drv" ]; then
        for d in "$drv"/*; do
            [ -L "$d" ] || continue
            n=$(basename "$d"); [ "$n" = "module" ] && continue
            echo "$n" > "$drv/unbind" && echo "odłączono fTPM: $n"
        done
    fi
    [ "$(ls /dev/tpmrm* | wc -l | tr -d ' ')" -eq 1 ] || die "w systemie jest więcej niż jeden TPM"
}

getenv() { fw_printenv "$1" 2>/dev/null | cut -d= -f2-; }

# PARTUUID partycji o danej etykiecie (z dowiązań udev)
partuuid_of() {
    target=$(readlink -f "/dev/disk/by-partlabel/$1")
    for l in /dev/disk/by-partuuid/*; do
        [ "$(readlink -f "$l")" = "$target" ] && { basename "$l"; return 0; }
    done
    return 1
}

# Komponent z rekordów dziennika, których żaden komponent nie opisuje. $1=PCR $2=plik
lock_unmatched() {
    digests=$(pcrlock log 2>/dev/null | awk -v p="$1" '$1==p && $6 ~ /^[0-9a-f]+$/ && length($6)==64 && $8=="-" {print $6}')
    [ -n "$digests" ] || return 0
    mkdir -p "$(dirname "$2")"
    { echo '{ "records": ['; first=1
      for g in $digests; do
          [ $first -eq 1 ] || echo ','; first=0
          printf '  { "pcr": %s, "digests": [ { "hashAlg": "sha256", "digest": "%s" } ] }' "$1" "$g"
      done
      echo; echo '] }'; } > "$2"
    echo "utworzono $2"
}

pcr_recognized() {
    pcrlock log 2>/dev/null | awk -v p="$1" '$1==p && ($5=="+"||$5=="-") && ($6=="+"||$6=="-") {print $6}'
}

pcr_predicted() {
    cur=$(tpm2_pcrread -T "device:$TPM" "sha256:$1" | grep -o '0x[0-9A-Fa-f]*' | sed 's/^0x//' | tr 'A-F' 'a-f')
    [ -n "$cur" ] || die "nie udało się odczytać PCR $1"
    pcrlock predict --pcr="$PCRS" 2>/dev/null | awk -v p="$1" '
        $0 ~ "^Results for PCR "p" " {f=1; next}
        /^Results for PCR/          {f=0}
        f && /sha256:/              {print $2}' | grep -qx "$cur"
}

# ---------------------------------------------------------------------------
single_tpm
[ -b "$DEV" ] || die "brak partycji $DEV"
mountpoint -q /persist || die "/persist nie jest zamontowane"
CUR=$(getenv slot); case "$CUR" in A|B) ;; *) die "nieznany bieżący slot '$CUR'";; esac
OTHER=$([ "$CUR" = A ] && echo B || echo A)
"$P" log 2>/dev/null | grep -q 'nvpcr-init' \
    && die "w dzienniku są pomiary nvpcr-init (pierwszy start z tym TPM): zrestartuj i uruchom ponownie"

log "1/5 LUKS2 z hasłem awaryjnym (slot 0)"
cryptsetup luksFormat --type luks2 --label data-luks "$DEV"

log "2/5 komponenty pcrlock w $COMP (bieżący slot: $CUR)"
[ -f "$POLICY" ] && { "$P" remove-policy --policy="$POLICY" 2>/dev/null || true; }
[ -d "$STATE" ] && mv "$STATE" "$STATE.bak.$(date +%Y%m%d-%H%M%S)"
mkdir -p "$COMP"
# komponenty standardowe systemd (separatory, akcje EFI) — kopia, żeby stan był samowystarczalny
cp -a /usr/lib/pcrlock.d/. "$COMP/"

lock_unmatched 0 "$COMP/240-firmware-code.pcrlock"                       # wersja U-Boota
pcrlock lock-secureboot-policy --pcrlock="$COMP/240-secureboot-policy.pcrlock"
lock_unmatched 7 "$COMP/245-secureboot-modes-uboot.pcrlock"              # DeployedMode, AuditMode

mkdir -p "$COMP/300-kernel.pcrlock.d" "$COMP/710-kernel-cmdline.pcrlock.d" "$MNT"
CMDLINE=$(cat /proc/cmdline)
for s in A B; do
    if [ "$s" = "$CUR" ]; then
        KERNEL=/boot/Image
    else
        mount -o ro "/dev/disk/by-partlabel/rootfs$s" "$MNT"
        KERNEL=$MNT/boot/Image
    fi
    pcrlock lock-pe --pcrlock="$COMP/300-kernel.pcrlock.d/$s.pcrlock" "$KERNEL"
    [ "$s" = "$CUR" ] || umount "$MNT"

    # parametry kernela slotu = bieżące z podmienionym PARTUUID (boot.scr różni się tylko tym)
    U=$(partuuid_of "rootfs$s") || die "brak PARTUUID dla rootfs$s"
    printf '%s' "$CMDLINE" | sed "s/root=PARTUUID=[^ ]*/root=PARTUUID=$U/" > "/tmp/cmdline-$s"
    pcrlock lock-kernel-cmdline --pcrlock="$COMP/710-kernel-cmdline.pcrlock.d/$s.pcrlock" "/tmp/cmdline-$s"
    echo "slot $s: kernel + parametry ($(cat "/tmp/cmdline-$s"))"
done

log "3/5 kontrola i zapis polityki w TPM"
for p in $(echo "$PCRS" | tr + ' '); do
    [ "$(pcr_recognized "$p")" = "+" ] || die "PCR $p zawiera pomiary bez komponentu (systemd-pcrlock log --components=$COMP)"
    pcr_predicted "$p" || die "przewidywanie PCR $p nie zawiera bieżącej wartości"
    echo "PCR $p: opisany i przewidziany poprawnie"
done
echo
echo ">>> Zapisz PIN awaryjny polityki (poniżej) POZA repozytorium, obok hasła awaryjnego LUKS. <<<"
pcrlock make-policy --policy="$POLICY" --pcr="$PCRS" --recovery-pin=show | tee /tmp/make-policy.txt
grep -q "PCRs dropped" /tmp/make-policy.txt && die "make-policy pominęło któryś PCR"

log "4/5 klucz zapieczętowany w TPM pod politykę pcrlock"
systemd-cryptenroll --tpm2-device="$TPM" --tpm2-pcrlock="$POLICY" --tpm2-pcrs= "$DEV"

log "5/5 odblokowanie przez crypttab, system plików, montowanie"
systemctl daemon-reload
systemctl restart systemd-cryptsetup@data.service
udevadm settle
mke2fs -t ext4 -L data /dev/mapper/data
udevadm settle
systemctl start data.mount
df -h /data
echo
echo "Gotowe. Test: reboot (bez hasła), potem fw_setenv slot $OTHER + reboot (też bez hasła)."