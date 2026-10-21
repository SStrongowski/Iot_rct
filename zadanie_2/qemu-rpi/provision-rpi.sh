#!/bin/bash
# provision-rpi.sh — konfiguracja płytki Gentoo ARM64 (zadanie 2)
#
# Odtwarza wszystko, co po pierwszym starcie obrazu było robione ręcznie:
# sieć, czas, dziennik, locale, repozytorium z fabryki, binhost, sudo,
# konto nie-root i zabezpieczenie SSH.
#
# Uruchamiać NA PŁYTCE jako root:   bash provision-rpi.sh
# Wymagania po stronie Gentoo VM (fabryki):
#   - działający serwer binhosta:  cd <PKGDIR> && python3 -m http.server 8080
#   - przekierowania portów VirtualBox: 2222 -> 22 (SSH) i 8080 -> 8080 (binhost)
#
# Skrypt można bezpiecznie uruchomić ponownie (kroki sprawdzają stan przed zmianą).

set -euo pipefail

USER_NAME="gentoo_test_rpi"      # konto nie-root na płytce
VM_LOGIN="gentoo_test"           # konto na Gentoo VM (fabryce)
VM_HOST="10.0.2.2"               # komputer z Windows widziany z sieci QEMU
VM_SSH_PORT="2222"               # przekierowanie SSH do Gentoo VM
BINHOST_URL="http://10.0.2.2:8080"

step() { echo; echo "=== $* ==="; }

# ---------------------------------------------------------------------------
step "1/7 Sieć: stały DNS QEMU, bez autokonfiguracji IPv6"
# W sieci QEMU serwer DNS dla IPv6 bywa niestabilny (błąd "Name or service
# not known" przy binhoście), dlatego wskazujemy wbudowany DNS dla IPv4.
cat > /etc/systemd/network/50-dhcp.network << 'EOF'
[Match]
Name=en*

[Network]
DHCP=yes
DNS=10.0.2.3
IPv6AcceptRA=no
EOF
networkctl reload

echo "Czekam na działający DNS..."
for _ in $(seq 1 30); do
    getent hosts distfiles.gentoo.org > /dev/null && break
    sleep 2
done
getent hosts distfiles.gentoo.org || { echo "BŁĄD: DNS nie działa"; exit 1; }

# ---------------------------------------------------------------------------
step "2/7 Czas i dziennik systemowy"
# RPi 5 bez baterii RTC traci czas po odłączeniu zasilania.
systemctl enable --now systemd-timesyncd

# Ograniczenie zapisów na kartę SD.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-size.conf << 'EOF'
[Journal]
SystemMaxUse=50M
EOF
systemctl restart systemd-journald

# ---------------------------------------------------------------------------
step "3/7 Locale"
for loc in "en_US.UTF-8 UTF-8" "pl_PL.UTF-8 UTF-8"; do
    grep -qx "$loc" /etc/locale.gen || echo "$loc" >> /etc/locale.gen
done
locale-gen
localectl set-locale LANG=en_US.UTF-8

# ---------------------------------------------------------------------------
step "4/7 Portage: repozytorium z fabryki i binhosty"
mkdir -p /etc/portage/repos.conf /etc/portage/binrepos.conf /etc/portage/package.use

# Serwer kluczy OpenPGP nieosiągalny z sieci QEMU; podpis snapshotu jest
# nadal weryfikowany, pomijane jest tylko sprawdzanie unieważnienia klucza.
cat > /etc/portage/repos.conf/gentoo.conf << 'EOF'
[gentoo]
sync-openpgp-key-refresh = no
EOF

# Repozytorium kopiowane z fabryki: paczki z binhosta są przypięte do wersji
# ebuildów, więc płytka musi mieć dokładnie to samo drzewo co fabryka.
echo "Kopiuję repozytorium z Gentoo VM (zapyta o hasło konta ${VM_LOGIN})..."
mkdir -p /var/db/repos/gentoo
rsync -a --delete --info=progress2 \
    -e "ssh -p ${VM_SSH_PORT} -o StrictHostKeyChecking=accept-new" \
    "${VM_LOGIN}@${VM_HOST}:/var/db/repos/gentoo/" /var/db/repos/gentoo/

# Własny binhost ma wyższy priorytet niż oficjalny binhost Gentoo (9999).
# Paczki z fabryki nie są (jeszcze) podpisane GPG, więc wymóg podpisu
# wyłączamy TYLKO dla tego binhosta; oficjalne paczki są nadal weryfikowane.
cat > /etc/portage/binrepos.conf/gentoo-vm.conf << EOF
[gentoo-vm]
priority = 10000
sync-uri = ${BINHOST_URL}
verify-signature = false
EOF

grep -q '^FEATURES=.*getbinpkg' /etc/portage/make.conf \
    || echo 'FEATURES="getbinpkg"' >> /etc/portage/make.conf

# Decyzja z zadania 2: sudo bez wysyłania poczty (bez serwera pocztowego).
echo "app-admin/sudo -sendmail" > /etc/portage/package.use/sudo

# ---------------------------------------------------------------------------
step "5/7 sudo z własnego binhosta"
# Kontrola, czy binhost na fabryce odpowiada (serwer HTTP + przekierowanie 8080).
wget -q -O /dev/null "${BINHOST_URL}/Packages" \
    || { echo "BŁĄD: binhost ${BINHOST_URL} nie odpowiada"; exit 1; }

# --getbinpkgonly: tylko gotowe paczki; jeśli binhost nie ma pasującej,
# emerge zakończy się błędem zamiast kompilować na płytce.
emerge --noreplace --getbinpkgonly app-admin/sudo

# Reguła dla grupy wheel w osobnym pliku zamiast edycji /etc/sudoers.
# Paczka sudo w Gentoo nie tworzy katalogu /etc/sudoers.d, więc robimy to
# sami i upewniamy się, że /etc/sudoers go wczytuje. Uwaga: "#includedir"
# w sudoers to dyrektywa (stara składnia), a nie komentarz.
install -d -m 750 /etc/sudoers.d
grep -qE '^[@#]includedir /etc/sudoers.d' /etc/sudoers \
    || echo '@includedir /etc/sudoers.d' >> /etc/sudoers
cat > /etc/sudoers.d/10-wheel << 'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 440 /etc/sudoers.d/10-wheel
# Sprawdzenie składni całej konfiguracji sudo (główny plik + katalog).
visudo -c

# ---------------------------------------------------------------------------
step "6/7 Konto nie-root: ${USER_NAME}"
if ! id "$USER_NAME" > /dev/null 2>&1; then
    useradd -m -G wheel -s /bin/bash "$USER_NAME"
fi
echo "Ustaw hasło dla ${USER_NAME} (najlepiej tylko znaki ASCII):"
passwd "$USER_NAME"
faillock --user "$USER_NAME" --reset 2> /dev/null || true

install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "/home/${USER_NAME}/.ssh"
install -m 600 -o "$USER_NAME" -g "$USER_NAME" \
    /root/.ssh/authorized_keys "/home/${USER_NAME}/.ssh/authorized_keys"

# ---------------------------------------------------------------------------
step "7/7 Zabezpieczenie SSH"
grep -qiE '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config \
    || echo "UWAGA: sshd_config nie wczytuje katalogu sshd_config.d"
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-hardening.conf << 'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sshd -t
systemctl restart sshd

# ---------------------------------------------------------------------------
step "Podsumowanie"
uname -a
id "$USER_NAME"
timedatectl | grep -i 'synchronized' || true
systemctl --failed --no-legend || true
echo
echo "Gotowe. NIE zamykaj tej sesji, dopóki w drugim oknie nie sprawdzisz:"
echo "  ssh -p 2223 ${USER_NAME}@127.0.0.1    (ma działać)"
echo "  ssh -p 2223 root@127.0.0.1            (ma być odrzucone)"
echo "  sudo whoami                           (ma zwrócić root)"
