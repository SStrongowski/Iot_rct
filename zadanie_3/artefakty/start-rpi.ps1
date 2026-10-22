param([string]$Dtb = "")

$qemuArgs = @(
  "-machine", "virt", "-cpu", "cortex-a76", "-smp", "4", "-m", "2G",
  "-kernel", "..\..\zadanie_2\qemu-rpi\Image",
  "-append", "root=PARTUUID=b6ea08ae-02 rw rootwait console=ttyAMA0",
  "-drive", "file=..\..\zadanie_2\qemu-rpi\gentoo-arm64.img,format=raw,if=virtio",
  "-netdev", "user,id=net0,hostfwd=tcp::2223-:22",
  "-device", "virtio-net-pci,netdev=net0",
  "-device", "qemu-xhci,id=xhci",
  "-device", "usb-kbd",
  "-drive", "if=none,id=usbstick,format=raw,file=..\..\zadanie_2\qemu-rpi\usb.img",
  "-device", "usb-storage,drive=usbstick",
  "-nographic"
)
if ($Dtb) { $qemuArgs += @("-dtb", $Dtb) }

& qemu-system-aarch64 @qemuArgs