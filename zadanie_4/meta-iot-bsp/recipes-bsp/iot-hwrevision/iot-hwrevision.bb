SUMMARY = "Tożsamość sprzętu dla SWUpdate (/etc/hwrevision)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Rewizja płytki: aktualizacja instaluje się tylko, gdy jej sw-description ją wymienia
HW_REVISION ?= "1.0"

inherit allarch
S = "${UNPACKDIR}"

do_install() {
    install -d ${D}${sysconfdir}
    echo "${MACHINE} ${HW_REVISION}" > ${D}${sysconfdir}/hwrevision
}
FILES:${PN} = "${sysconfdir}/hwrevision"
PACKAGE_ARCH = "${MACHINE_ARCH}"
