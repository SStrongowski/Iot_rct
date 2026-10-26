SUMMARY = "Konfiguracja środowiska dla narzędzi TPM 2.0 i PKCS#11"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://tpm2-pkcs11.sh"
S = "${UNPACKDIR}"

inherit allarch

do_install() {
    install -d ${D}${sysconfdir}/profile.d
    install -m 0644 ${UNPACKDIR}/tpm2-pkcs11.sh ${D}${sysconfdir}/profile.d/
    install -d -m 0700 ${D}${localstatedir}/lib/tpm2-pkcs11
}

FILES:${PN} = "${sysconfdir}/profile.d/tpm2-pkcs11.sh ${localstatedir}/lib/tpm2-pkcs11"
