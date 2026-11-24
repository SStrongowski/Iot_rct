# iot-pcrlock.sh — wspólne funkcje: polityka TPM (systemd-pcrlock) w układzie A/B.
# Dołączane przez iot-update i iot-boot-ok:  . /usr/lib/iot/iot-pcrlock.sh
#
# Stan polityki leży na partycji persist (wspólnej dla slotów):
#   /persist/pcrlock/pcrlock.d/300-kernel.pcrlock.d/{A,B}.pcrlock          kernel slotu (PCR 4)
#   /persist/pcrlock/pcrlock.d/710-kernel-cmdline.pcrlock.d/{A,B}.pcrlock  parametry slotu (PCR 9)
#   /persist/pcrlock/pcrlock.json                                          opis polityki (indeks NV)

P=/usr/lib/systemd/systemd-pcrlock
PCRS=0+4+7+9
TPM=/dev/tpmrm0
STATE=/persist/pcrlock
COMP=$STATE/pcrlock.d
POLICY=$STATE/pcrlock.json

pcrlock() { "$P" --components="$COMP" "$@"; }

# czy urządzenie ma politykę (provisioning wykonany)
policy_present() { [ -f "$POLICY" ]; }

# systemd-pcrlock nie pozwala wskazać układu TPM: odłącz fTPM (OP-TEE), jeśli jest
single_tpm() {
    drv=/sys/bus/tee/drivers/optee-ftpm
    if [ -d "$drv" ]; then
        for d in "$drv"/*; do
            [ -L "$d" ] || continue
            n=$(basename "$d"); [ "$n" = "module" ] && continue
            echo "$n" > "$drv/unbind" 2>/dev/null || true
        done
    fi
    [ "$(ls /dev/tpmrm* | wc -l | tr -d ' ')" -eq 1 ]
}

# PARTUUID partycji o danej etykiecie
partuuid_of() {
    target=$(readlink -f "/dev/disk/by-partlabel/$1")
    for l in /dev/disk/by-partuuid/*; do
        [ "$(readlink -f "$l")" = "$target" ] && { basename "$l"; return 0; }
    done
    return 1
}

# dla każdego PCR polityki: czy bieżąca wartość jest wśród przewidzianych
policy_check_current() {
    for p in $(echo "$PCRS" | tr + ' '); do
        cur=$(tpm2_pcrread -T "device:$TPM" "sha256:$p" | grep -o '0x[0-9A-Fa-f]*' | sed 's/^0x//' | tr 'A-F' 'a-f')
        [ -n "$cur" ] || return 1
        pcrlock predict --pcr="$PCRS" 2>/dev/null | awk -v p="$p" '
            $0 ~ "^Results for PCR "p" " {f=1; next}
            /^Results for PCR/          {f=0}
            f && /sha256:/              {print $2}' | grep -qx "$cur" || {
            echo "PCR $p: bieżąca wartość poza przewidywaniem" >&2; return 1; }
    done
}

# zapis polityki do TPM; błąd, jeśli któryś PCR wypadł z maski
policy_write() {
    pcrlock make-policy --policy="$POLICY" --pcr="$PCRS" > /tmp/iot-make-policy.log 2>&1 || return 1
    ! grep -q "PCRs dropped" /tmp/iot-make-policy.log
}

# warianty kernela i parametrów dla slotu $1 (system już zapisany na partycji)
policy_add_slot() {
    s=$1; mnt=/mnt/iot-slot-$s
    mkdir -p "$mnt"
    mount -o ro "/dev/disk/by-partlabel/rootfs$s" "$mnt" || return 1
    pcrlock lock-pe --pcrlock="$COMP/300-kernel.pcrlock.d/$s.pcrlock" "$mnt/boot/Image" >/dev/null
    rc=$?
    umount "$mnt"
    [ $rc -eq 0 ] || return 1

    # parametry = bieżące z PARTUUID slotu $1 (boot.scr różni się między slotami tylko tym)
    u=$(partuuid_of "rootfs$s") || return 1
    cmd=$(cat /proc/cmdline)
    printf '%s' "$cmd" | sed "s/root=PARTUUID=[^ ]*/root=PARTUUID=$u/" > "/tmp/iot-cmdline-$s"
    pcrlock lock-kernel-cmdline --pcrlock="$COMP/710-kernel-cmdline.pcrlock.d/$s.pcrlock" \
        "/tmp/iot-cmdline-$s" >/dev/null
}

# usunięcie wariantów slotu $1 — przeniesienie na bok, żeby dało się je przywrócić
policy_remove_slot() {
    mkdir -p "$STATE/removed"
    mv "$COMP/300-kernel.pcrlock.d/$1.pcrlock"         "$STATE/removed/kernel-$1.pcrlock"  || return 1
    mv "$COMP/710-kernel-cmdline.pcrlock.d/$1.pcrlock" "$STATE/removed/cmdline-$1.pcrlock" || return 1
}

# przywrócenie wariantów slotu $1 (gdy zapis polityki się nie udał)
policy_restore_slot() {
    mv "$STATE/removed/kernel-$1.pcrlock"  "$COMP/300-kernel.pcrlock.d/$1.pcrlock"         2>/dev/null || true
    mv "$STATE/removed/cmdline-$1.pcrlock" "$COMP/710-kernel-cmdline.pcrlock.d/$1.pcrlock" 2>/dev/null || true
}

# po udanym zapisie: usunięte warianty nie są już potrzebne
policy_drop_removed() { rm -rf "$STATE/removed"; }
