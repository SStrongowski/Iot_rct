#!/bin/sh
# provision-data.sh — jednorazowe przygotowanie zaszyfrowanej partycji danych NA URZĄDZENIU.
#
#  1. LUKS2 z hasłem awaryjnym (slot 0)
#  2. polityka systemd-pcrlock w TPM: dozwolone stany PCR 0+4+7+12 obliczone
#     z komponentów opisujących bieżący, zaufany stan startu
#  3. klucz zapieczętowany w TPM pod tę politykę (slot TPM2, tpm2-pcrlock)
#  4. system plików i montowanie przez systemd (crypttab + data.mount z obrazu)
#
# Klucz wolumenu powstaje tutaj (nigdy na maszynie budującej). Uruchamiać
# w zaufanym, nienaruszonym stanie startu: pomiary z tego startu stają się
# wzorcem. UWAGA: kasuje całą zawartość partycji data.
set -eu

DEV=/dev/disk/by-partlabel/data
TPM=/dev/tpmrm0                       # TPM z łańcuchem measured boot (tpm_tis), nie fTPM
PCRS=0+4+7+12                         # firmware, kod bootloadera i kernela, polityka SB, parametry kernela
P=/usr/lib/systemd/systemd-pcrlock
D=/var/lib/pcrlock.d
POLICY=/var/lib/systemd/pcrlock.json

log() { echo; echo "== $*"; }
die() { echo "BŁĄD: $*" >&2; exit 1; }

# systemd-pcrlock nie pozwala wskazać układu TPM: odłącz fTPM (OP-TEE), jeśli jest.
single_tpm() {
    drv=/sys/bus/tee/drivers/optee-ftpm
    if [ -d "$drv" ]; then
        for d in "$drv"/*; do
            [ -L "$d" ] || continue
            n=$(basename "$d")
            [ "$n" = "module" ] && continue
            echo "$n" > "$drv/unbind" && echo "odłączono fTPM: $n"
        done
    fi
    [ "$(ls /dev/tpmrm* | wc -l | tr -d ' ')" -eq 1 ] || die "w systemie jest więcej niż jeden TPM"
}

# Komponent z rekordów dziennika, których żaden komponent nie opisuje
# (pomiary specyficzne dla U-Boot/systemd-boot). Skróty brane z bieżącego startu.
#   $1 = PCR, $2 = plik .pcrlock
lock_unmatched() {
    digests=$("$P" log 2>/dev/null | awk -v p="$1" '$1==p && $6 ~ /^[0-9a-f]{64}$/ && $8=="-" {print $6}')
    [ -n "$digests" ] || return 0
    mkdir -p "$(dirname "$2")"
    {
        echo '{ "records": ['
        first=1
        for g in $digests; do
            [ $first -eq 1 ] || echo ','
            first=0
            printf '  { "pcr": %s, "digests": [ { "hashAlg": "sha256", "digest": "%s" } ] }' "$1" "$g"
        done
        echo; echo '] }'
    } > "$2"
    echo "utworzono $2 ($(echo "$digests" | wc -l | tr -d ' ') rekord(y) PCR $1)"
}

# kolumna R (wszystkie rekordy PCR opisane komponentami) z podsumowania `pcrlock log`
pcr_recognized() {
    "$P" log 2>/dev/null | awk -v p="$1" '$1==p && ($5=="+"||$5=="-") && ($6=="+"||$6=="-") {print $6}'
}

# czy bieżąca wartość PCR jest wśród przewidzianych
pcr_predicted() {
    # format linii zależy od numeru ("4 : 0x…" / "12: 0x…"), więc bierzemy samą wartość
    cur=$(tpm2_pcrread -T "device:$TPM" "sha256:$1" | grep -o '0x[0-9A-Fa-f]*' | sed 's/^0x//' | tr 'A-F' 'a-f')
    [ -n "$cur" ] || die "nie udało się odczytać PCR $1"
    "$P" predict --pcr="$PCRS" 2>/dev/null | awk -v p="$1" '
        $0 ~ "^Results for PCR "p" " {f=1; next}
        /^Results for PCR/          {f=0}
        f && /sha256:/              {print $2}' | grep -qx "$cur"
}

single_tpm
[ -b "$DEV" ] || die "brak partycji $DEV"
[ -f /boot/Image ] || die "brak kernela /boot/Image (partycja EFI zamontowana w /boot?)"

log "1/5 LUKS2 z hasłem awaryjnym (slot 0)"
cryptsetup luksFormat --type luks2 --label data-luks "$DEV"

log "2/5 komponenty pcrlock opisujące bieżący stan startu"
if [ -d "$D" ] || [ -f "$POLICY" ]; then
    "$P" remove-policy 2>/dev/null || true
    [ -d "$D" ] && mv "$D" "$D.bak.$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$D"
"$P" lock-firmware-code         # PCR 0/2 (+ systemd-boot w PCR 4, mierzony przed separatorem)
"$P" lock-firmware-config       # PCR 1/3
"$P" lock-secureboot-policy     # PCR 7: SecureBoot, PK, KEK, db, dbx
"$P" lock-gpt                   # PCR 5
"$P" lock-kernel-cmdline        # PCR 9 (pomiar kernela)
# kernel w osobnym komponencie z wariantami (aktualizacje: iot-kernel-update.sh).
# Bootloadera NIE blokujemy osobno: obejmuje go już lock-firmware-code
# (podwójny komponent = podwójny pomiar w przewidywaniu).
"$P" lock-pe --pcrlock="$D/650-kernel.pcrlock.d/obecny.pcrlock" /boot/Image
# pomiary nieznane systemd-pcrlock: DeployedMode/AuditMode (U-Boot), parametry kernela z systemd-boot
lock_unmatched 7  "$D/245-secureboot-modes-uboot.pcrlock"
lock_unmatched 12 "$D/660-kernel-cmdline-sdboot.pcrlock.d/obecny.pcrlock"

log "3/5 kontrola i zapis polityki w TPM"
for p in $(echo "$PCRS" | tr + ' '); do
    [ "$(pcr_recognized "$p")" = "+" ] || die "PCR $p zawiera pomiary bez komponentu (systemd-pcrlock log)"
    pcr_predicted "$p" || die "przewidywanie PCR $p nie zawiera bieżącej wartości"
    echo "PCR $p: opisany i przewidziany poprawnie"
done
echo
echo ">>> Zapisz PIN awaryjny polityki (poniżej) POZA repozytorium, obok hasła awaryjnego LUKS. <<<"
"$P" make-policy --pcr="$PCRS" --recovery-pin=show | tee /tmp/make-policy.txt \
    || "$P" make-policy --pcr="$PCRS" | tee /tmp/make-policy.txt
grep -q "PCRs dropped" /tmp/make-policy.txt && die "make-policy pominęło któryś PCR"
rm -f /tmp/make-policy.txt

log "4/5 klucz zapieczętowany w TPM pod politykę pcrlock"
systemd-cryptenroll --tpm2-device="$TPM" --tpm2-pcrlock="$POLICY" --tpm2-pcrs= "$DEV"

log "5/5 odblokowanie przez crypttab (jak przy starcie), system plików, montowanie"
systemctl daemon-reload
systemctl restart systemd-cryptsetup@data.service
udevadm settle
mke2fs -t ext4 -L data /dev/mapper/data
udevadm settle
systemctl start data.mount
df -h /data
cryptsetup luksDump "$DEV" | sed -n '/Tokens:/,/Keyslot:/p'
echo
echo "Gotowe. Test: reboot, potem journalctl -b -u systemd-cryptsetup@data (bez pytania o hasło)."
