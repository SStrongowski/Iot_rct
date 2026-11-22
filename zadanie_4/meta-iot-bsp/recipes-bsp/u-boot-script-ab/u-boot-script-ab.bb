SUMMARY = "Skrypt startowy U-Boota dla układu A/B"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

DEPENDS = "u-boot-tools-native"
SRC_URI = "file://boot.cmd"

inherit deploy nopackages

do_compile() {
    mkimage -A arm64 -O linux -T script -C none -n "boot A/B" \
        -d ${UNPACKDIR}/boot.cmd ${B}/boot.scr
}

do_deploy() {
    install -m 0644 ${B}/boot.scr ${DEPLOYDIR}/boot.scr
}
addtask deploy after do_compile before do_build
