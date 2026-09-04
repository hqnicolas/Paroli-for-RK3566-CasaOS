dmesg | grep -i rknpu
[    7.025640] rknpu: loading out-of-tree module taints kernel.
[    7.034768] RKNPU fde40000.npu: RKNPU: rknpu iommu device-tree entry not found!, using non-iommu mode
[    7.040897] [drm] Initialized rknpu 0.9.8 for fde40000.npu on minor 1
[    7.045165] RKNPU fde40000.npu: RKNPU: devfreq enabled, initial freq: 594000000 Hz, volt: 900000 uV
[  105.708245] RKNPU: job: 0000000027ea22d2, mask: 0x1, job iommu domain id: 0, dev iommu domain id: 0, wait_count: 1, continue wait: 0, commit elapse time: 6226455us, wait time: 6226457us, timeout: 6000000us
[  105.708333] RKNPU: failed to wait job, task counter: 0, flags: 0x5, ret = 0, elapsed time: 6226553us
[  105.812210] RKNPU: job timeout, flags: 0x0:
[  105.812262] RKNPU: 	core 0 irq status: 0x0, raw status: 0x0, require mask: 0x300, task counter: 0x0, elapsed time: 6330485us
[  105.916209] RKNPU: soft reset, num: 2
[  114.924064] RKNPU: job: 00000000f13896e6, mask: 0x1, job iommu domain id: 0, dev iommu domain id: 0, wait_count: 1, continue wait: 0, commit elapse time: 6085473us, wait time: 6085474us, timeout: 6000000us

uname -a
Linux h96-tvbox-3566 7.2.2-edge-rockchip64 #1 SMP PREEMPT Fri Aug 28 06:25:22 UTC 2026 aarch64 GNU/Linux


cat /proc/meminfo | grep CmaTotal
CmaTotal:        1048576 kB


 ls -la /dev/rknpu
ls: cannot access '/dev/rknpu': No such file or directory

dmesg | grep -i -E "npu|rknpu|cma"
[    0.000000] cma: Reserved 1024 MiB at 0x00000000ab400000
[    0.000000] Kernel command line: root=UUID=40fe58b1-becf-4953-9a4c-e9cd9e2a70b9 rootwait rootfstype=ext4 splash=verbose console=ttyS2,1500000 console=tty1 consoleblank=0 loglevel=1 ubootpart=2c4c8e7b-4386-4169-8426-cfafdabfa17e usb-storage.quirks=0x2537:0x1066:u,0x2537:0x1068:u cma=1024M  cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory
[    0.022207] Memory: 6783432K/8124416K available (18944K kernel code, 3062K rwdata, 12408K rodata, 3008K init, 684K bss, 285048K reserved, 1048576K cma-reserved)
[    2.190011] rk_gmac-dwmac fe010000.ethernet: clock input or output? (input).
[    2.190080] rk_gmac-dwmac fe010000.ethernet: clock input from PHY
[    7.025640] rknpu: loading out-of-tree module taints kernel.
[    7.034768] RKNPU fde40000.npu: RKNPU: rknpu iommu device-tree entry not found!, using non-iommu mode
[    7.040897] [drm] Initialized rknpu 0.9.8 for fde40000.npu on minor 1
[    7.045165] RKNPU fde40000.npu: RKNPU: devfreq enabled, initial freq: 594000000 Hz, volt: 900000 uV
[    7.219136] input: rk805 pwrkey as /devices/platform/fdd40000.i2c/i2c-0/0-0020/rk805-pwrkey.5.auto/input/input0
[    7.819715] input: gpio_ir_recv as /devices/platform/ir-receiver/rc/rc0/input1
[  105.708245] RKNPU: job: 0000000027ea22d2, mask: 0x1, job iommu domain id: 0, dev iommu domain id: 0, wait_count: 1, continue wait: 0, commit elapse time: 6226455us, wait time: 6226457us, timeout: 6000000us
