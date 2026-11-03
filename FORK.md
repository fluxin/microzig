# This is an altered version of MicroZig

This fork (github.com/fluxin/microzig, branch `patches`) is MicroZig with
changes made for a private project. It is not the original MicroZig, is not
maintained or endorsed by the Zig Embedded Group, and its changes are
not submitted upstream. For MicroZig itself, see
https://github.com/ZigEmbeddedGroup/microzig.

The license is unchanged (see LICENSE). Changes on this branch, on top of
the upstream release named in each entry:

| Change | Files | Base |
|---|---|---|
| regz: an array of structs spans every element in the field layout (registers after a cluster array were misplaced; on the nRF52840, USBD EPOUT and everything after EPIN) | `tools/regz/src/gen.zig` | 0.17.30 |
| nrf5x: QSPI flash driver for the nRF52840 (EasyDMA read/program/erase, custom instructions, XIP; start/done halves for cooperative waits) | `port/nordic/nrf5x/src/hal/qspi.zig`, `hal.zig` | 0.17.30 |
| nrf5x: clock starts wait for the clock (clear a stale STARTED event, return if already running); RC calibration clears DONE and is bounded; `time.init_with` for a board's 32.768 kHz crystal (no calibration). An nRF52840 after its UF2 bootloader hung in `time.init` waiting for a calibration DONE that never came | `port/nordic/nrf5x/src/hal/clocks.zig`, `time.zig` | 0.17.30 |
| regz: a cluster listed by dimIndex keeps its addressOffset (its elements were placed from the parent's start) | `tools/regz/src/svd.zig` | 0.17.30 |
| network: `dhcp_coarse_timer_s` build option (lwIP's DHCP lease timer, default 60 s, so short leases lapse); `tcp.Connection.close` detaches lwIP's callbacks before closing | `modules/network/build.zig`, `src/root.zig` | 0.17.30 |
