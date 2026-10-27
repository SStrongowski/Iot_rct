#!/bin/sh
# iot-kernel-update.sh — aktualizacja kernela z ponownym "pieczętowaniem" klucza LUKS.
#
# Klucz partycji danych jest zapieczętowany w TPM pod politykę systemd-pcrlock
# (indeks NV z listą dozwolonych stanów PCR). Aktualizacja w dwóch etapach:
#
#   stage <nowy_kernel>  PRZED restartem: nowy kernel dopisany do polityki jako
#                        dodatkowy wariant (dozwolony stary I nowy), instalacja
#   finalize             PO restarcie: kontrola, że zmierzony kernel to ten
#                        zapowiedziany, usunięcie starego wariantu (ochrona
#                        przed powrotem do starego kernela, rollback)
#
# Slot LUKS nie jest zmieniany — zmienia się tylko zawartość polityki w TPM.
# W żadnym momencie polityka nie dopuszcza nieznanego kernela.
# Dowody zapisywane w /root/dowody-aktualizacja/<data>/.
set -eu

P=/usr/lib/systemd/systemd-pcrlock
PCRS=0+4+7+12                 # firmware, kod bootloadera i kernela, polityka SB, parametry kernela
PCRL=0,4,7,12
TPM=/dev/tpmrm0               # TPM z łańcuchem measured boot (tpm_tis)
KDIR=/var/lib/pcrlock.d/650-kernel.pcrlock.d
STATE=/var/lib/iot-update
KERNEL=/boot/Image

log() { echo "== $*"; }
die() { echo "BŁĄD: $*" >&2; exit 1; }
count() { wc -l < "$1" | tr -d ' '; }

# systemd-pcrlock nie pozwala wskazać układu TPM: odłącz fTPM (OP-TEE), jeśli jest.
# (Docelowo fTPM wyłączony w kernelu przez warstwę BSP.)
single_tpm() {
    drv=/sys/bus/tee/drivers/optee-ftpm
    if [ -d "$drv" ]; then
        for d in "$drv"/*; do
            [ -L "$d" ] || continue
            n=$(basename "$d")
            [ "$n" = "module" ] && continue
            echo "$n" > "$drv/unbind" && log "odłączono fTPM: $n"
        done
    fi
    [ "$(ls /dev/tpmrm* | wc -l | tr -d ' ')" -eq 1 ] || die "w systemie jest więcej niż jeden TPM"
}

# bieżąca wartość PCR 4 (małe litery, bez 0x)
pcr4() {
    # format linii zależy od numeru PCR ("4 : 0x…" / "12: 0x…"), więc bierzemy samą wartość
    tpm2_pcrread -T "device:$TPM" sha256:4 | grep -o '0x[0-9A-Fa-f]*' | sed 's/^0x//' | tr 'A-F' 'a-f'
}

# wartości PCR 4 dopuszczane przez komponenty (wynik predict)
predict_pcr4() {
    "$P" predict --pcr="$PCRS" 2>/dev/null | awk '
        /^Results for PCR 4 / {f=1; next}
        /^Results for PCR/    {f=0}
        f && /sha256:/        {print $2}'
}

stage() {
    NEW=${1:-}
    [ -f "$NEW" ] || die "podaj plik nowego kernela"
    [ -e "$STATE/pending" ] && die "poprzednia aktualizacja niedokończona (uruchom: $0 finalize)"
    single_tpm

    EV=/root/dowody-aktualizacja/$(date +%Y%m%d-%H%M%S)
    mkdir -p "$EV" "$STATE"

    log "1/5 stan przed aktualizacją"
    uname -a > "$EV/01-uname-przed.txt"
    tpm2_pcrread -T "device:$TPM" "sha256:$PCRL" > "$EV/02-pcr-przed.txt"
    sha256sum "$KERNEL" "$NEW" > "$EV/03-kernele.txt"
    CUR=$(pcr4)
    predict_pcr4 > "$EV/04-predict-przed.txt"
    grep -qx "$CUR" "$EV/04-predict-przed.txt" \
        || die "bieżący PCR 4 nie pasuje do obecnej polityki — polityki nie da się zaktualizować"

    log "2/5 zapowiedź nowego kernela w polityce (wariant 'nowy')"
    "$P" lock-pe --pcrlock="$KDIR/nowy.pcrlock" "$NEW"
    predict_pcr4 > "$EV/05-predict-2-warianty.txt"
    # inne komponenty (np. firmware) też mogą mieć warianty, więc nie liczymy
    # wartości bezwzględnie: nowy wariant musi DODAĆ dozwolone stany PCR 4
    [ "$(count "$EV/05-predict-2-warianty.txt")" -gt "$(count "$EV/04-predict-przed.txt")" ] \
        || die "nowy wariant nie dodał stanów PCR 4 (nowy kernel taki sam jak stary?)"
    grep -qx "$CUR" "$EV/05-predict-2-warianty.txt" \
        || die "po dodaniu wariantu bieżący stan przestał pasować — przerwij"

    log "3/5 zapis polityki w TPM (dozwolony stary i nowy kernel)"
    "$P" make-policy --pcr="$PCRS" > "$EV/06-make-policy.txt" 2>&1 \
        || die "make-policy nie powiodło się (zob. $EV/06-make-policy.txt)"
    grep -q "PCRs dropped" "$EV/06-make-policy.txt" \
        && die "make-policy pominęło któryś PCR (zob. $EV/06-make-policy.txt)"

    log "4/5 instalacja nowego kernela (kopia poprzedniego: /root/Image.poprzedni)"
    cp "$KERNEL" /root/Image.poprzedni
    cp "$NEW" "$KERNEL"
    sync
    sha256sum "$KERNEL" | cut -d' ' -f1 > "$STATE/new-kernel.sha256"
    echo "$EV" > "$STATE/pending"

    log "5/5 gotowe — zrestartuj (reboot), a po starcie uruchom: $0 finalize"
}

finalize() {
    [ -e "$STATE/pending" ] || die "brak aktualizacji w toku"
    EV=$(cat "$STATE/pending")
    single_tpm

    log "1/4 stan po restarcie"
    uname -a > "$EV/07-uname-po.txt"
    journalctl -b -u systemd-cryptsetup@data --no-pager > "$EV/08-cryptsetup.log"
    tpm2_pcrread -T "device:$TPM" "sha256:$PCRL" > "$EV/09-pcr-po.txt"
    diff "$EV/02-pcr-przed.txt" "$EV/09-pcr-po.txt" > "$EV/10-pcr-diff.txt" || true
    "$P" log 2>/dev/null | awk '$1=="4"' > "$EV/11-pcr4-zdarzenia.txt"

    log "2/4 kontrole"
    [ "$(sha256sum "$KERNEL" | cut -d' ' -f1)" = "$(cat "$STATE/new-kernel.sha256")" ] \
        || die "na partycji EFI jest inny kernel niż zainstalowany w etapie stage"
    DIG=$(awk '$4=="efi-boot-services-application" && /\\Image/ {print $6}' "$EV/11-pcr4-zdarzenia.txt")
    [ -n "$DIG" ] || die "kernel nie został zmierzony w tym starcie — stary wariant zostaje"
    grep -q "$DIG" "$KDIR/nowy.pcrlock" \
        || die "zmierzony kernel ($DIG) nie jest zapowiedzianym wariantem — stary wariant zostaje"
    grep -q "does not match" "$EV/08-cryptsetup.log" \
        && die "partycja nie odblokowała się przez TPM w tym starcie — stary wariant zostaje"
    echo "$DIG" > "$EV/12-zmierzony-kernel.txt"

    log "3/4 usunięcie starego wariantu (ochrona przed powrotem do starego kernela)"
    mv "$KDIR/nowy.pcrlock" "$KDIR/obecny.pcrlock"
    CUR=$(pcr4)
    predict_pcr4 > "$EV/13-predict-po.txt"
    # bieżący stan musi być dozwolony...
    grep -qx "$CUR" "$EV/13-predict-po.txt" \
        || die "predict po zmianie nie zawiera bieżącego PCR 4 — nie zapisuję polityki"
    # ...a żaden stan sprzed aktualizacji (stary kernel) już nie: ochrona przed rollbackiem
    grep -qxf "$EV/04-predict-przed.txt" "$EV/13-predict-po.txt" \
        && die "polityka nadal dopuszcza stan ze starym kernelem — nie zapisuję polityki"
    "$P" make-policy --pcr="$PCRS" > "$EV/14-make-policy-po.txt" 2>&1 \
        || die "make-policy nie powiodło się (zob. $EV/14-make-policy-po.txt)"

    rm -f "$STATE/pending" "$STATE/new-kernel.sha256"
    log "4/4 aktualizacja zakończona; dowody: $EV"
}

case "${1:-}" in
    stage)    shift; stage "$@" ;;
    finalize) finalize ;;
    *)        echo "użycie: $0 stage <nowy_kernel> | $0 finalize"; exit 2 ;;
esac