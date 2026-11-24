# Polityka dystrybucji: bez NvPCR systemd.
# Kotwice nvpcr-init trafiają do PCR 9 zależnie od stanu w systemie plików slotu,
# przez co PCR 9 (parametry kernela w polityce TPM) byłby nieprzewidywalny w układzie A/B.
do_install:append() {
    rm -f ${D}${nonarch_libdir}/nvpcr/*.nvpcr
    install -d ${D}${sysconfdir}/systemd/system
    ln -sf /dev/null ${D}${sysconfdir}/systemd/system/systemd-pcrproduct.service
    ln -sf /dev/null ${D}${sysconfdir}/systemd/system/systemd-pcrnvdone.service
}
