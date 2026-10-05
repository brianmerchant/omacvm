# Kbuild sets KERNELRELEASE and takes the first branch (DKMS too, see
# dkms.conf). By hand: make [KVER=<kernel release>].
ifneq ($(KERNELRELEASE),)
obj-m := omacvm_vdec.o
omacvm_vdec-y := omacvm-vdec.o
else
KVER ?= $(shell uname -r)
KDIR ?= /usr/lib/modules/$(KVER)/build

.PHONY: modules clean

modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
endif
