//! QSPI flash interface (nRF52840): reads, page programs and erases over
//! EasyDMA, custom instructions, and the memory-mapped (XIP) view of the
//! flash at `xip_base`. Flash-chip specifics (enabling quad mode, the
//! status register layout beyond the WIP bit) belong to the caller.
//!
//! Programs and erases take milliseconds to seconds, so they come in two
//! halves: `start_write`/`start_erase` return at once and `done` tells when
//! the flash has finished, for callers that wait in their own scheduler
//! (an `std.Io` sleep, an RTOS yield). `write` and `erase` spin instead.
const std = @import("std");
const microzig = @import("microzig");
const compatibility = @import("compatibility.zig");
const gpio = @import("gpio.zig");

const QSPI = switch (compatibility.chip) {
    .nrf52840 => microzig.chip.peripherals.QSPI,
    else => compatibility.unsupported_chip("QSPI"),
};

/// Where the flash appears in the address space once activated.
pub const xip_base: usize = 0x1200_0000;

pub const ReadMode = enum { fastread, read2o, read2io, read4o, read4io };
pub const WriteMode = enum { pp, pp2o, pp4o, pp4io };

pub const Config = struct {
    sck: gpio.Pin,
    csn: gpio.Pin,
    io: [4]gpio.Pin,
    read_mode: ReadMode = .read4io,
    write_mode: WriteMode = .pp4o,
    /// SCK = 32 MHz / (divider + 1), so 0 is 32 MHz and 15 is 2 MHz.
    sck_divider: u4 = 1,
    /// SPI mode 0 (CPOL=0, CPHA=0) or 3.
    spi_mode: enum { mode0, mode3 } = .mode0,
    /// Delay between CSN and the first SCK edge, in 62.5 ns steps.
    sck_delay: u8 = 1,
};

pub const Error = error{ Unaligned, TooLong };

/// The flash's status register write-in-progress bit (JEDEC).
const status_wip: u8 = 0x01;
const opcode_rdsr: u8 = 0x05;

/// Configure the pins and interface, enable the peripheral and activate it
/// (the flash is then readable through `xip_base`).
pub fn init(config: Config) void {
    // High drive, as Nordic's QSPI driver configures its pins.
    for ([_]gpio.Pin{ config.sck, config.csn } ++ config.io) |pin| pin.set_drive_strength(.HOH1);
    QSPI.PSEL.SCK.write_raw(psel(config.sck));
    QSPI.PSEL.CSN.write_raw(psel(config.csn));
    QSPI.PSEL.IO0.write_raw(psel(config.io[0]));
    QSPI.PSEL.IO1.write_raw(psel(config.io[1]));
    QSPI.PSEL.IO2.write_raw(psel(config.io[2]));
    QSPI.PSEL.IO3.write_raw(psel(config.io[3]));
    QSPI.XIPOFFSET.write_raw(0);
    QSPI.IFCONFIG0.write(.{
        .READOC = switch (config.read_mode) {
            .fastread => .FASTREAD,
            .read2o => .READ2O,
            .read2io => .READ2IO,
            .read4o => .READ4O,
            .read4io => .READ4IO,
        },
        .WRITEOC = switch (config.write_mode) {
            .pp => .PP,
            .pp2o => .PP2O,
            .pp4o => .PP4O,
            .pp4io => .PP4IO,
        },
        .ADDRMODE = .@"24BIT",
        .DPMENABLE = .Disable,
        .PPSIZE = .@"256Bytes",
    });
    QSPI.IFCONFIG1.write(.{
        .SCKDELAY = config.sck_delay,
        .DPMEN = .Exit,
        .SPIMODE = switch (config.spi_mode) {
            .mode0 => .MODE0,
            .mode3 => .MODE3,
        },
        .SCKFREQ = config.sck_divider,
    });
    QSPI.ENABLE.write(.{ .ENABLE = .Enabled });
    QSPI.EVENTS_READY.write_raw(0);
    QSPI.TASKS_ACTIVATE.write_raw(1);
    waitReady();
}

/// Deactivate and disable the peripheral (the XIP view goes away).
pub fn deinit() void {
    QSPI.EVENTS_READY.write_raw(0);
    QSPI.TASKS_DEACTIVATE.write_raw(1);
    QSPI.ENABLE.write(.{ .ENABLE = .Disabled });
}

/// A PSEL value: pin and port in bits 0-5, CONNECT (bit 31) 0 = connected.
fn psel(pin: gpio.Pin) u32 {
    return @backingInt(pin);
}

fn waitReady() void {
    while (QSPI.EVENTS_READY.raw == 0) {}
    QSPI.EVENTS_READY.write_raw(0);
}

/// One instruction outside the read/write/erase paths: `opcode`, then the
/// bytes of `tx` (at most 8), then as many bytes as `rx` holds (at most 8,
/// together with `tx`). `wren` sends WREN first.
pub fn custom(opcode: u8, tx: []const u8, rx: []u8, wren: bool) Error!void {
    const n = @max(tx.len, rx.len);
    if (n > 8) return error.TooLong;
    var data: [8]u8 = @splat(0);
    @memcpy(data[0..tx.len], tx);
    QSPI.CINSTRDAT0.write_raw(std.mem.readInt(u32, data[0..4], .little));
    QSPI.CINSTRDAT1.write_raw(std.mem.readInt(u32, data[4..8], .little));
    QSPI.EVENTS_READY.write_raw(0);
    QSPI.CINSTRCONF.write(.{
        .OPCODE = opcode,
        .LENGTH = @enumFromInt(1 + n),
        .LIO2 = 1,
        .LIO3 = 1,
        .WIPWAIT = .Disable,
        .WREN = if (wren) .Enable else .Disable,
        .LFEN = .Disable,
        .LFSTOP = .Stop,
    });
    waitReady();
    std.mem.writeInt(u32, data[0..4], QSPI.CINSTRDAT0.raw, .little);
    std.mem.writeInt(u32, data[4..8], QSPI.CINSTRDAT1.raw, .little);
    @memcpy(rx, data[0..rx.len]);
}

/// The flash's status register (RDSR, 05h).
pub fn status() u8 {
    var sr: [1]u8 = undefined;
    custom(opcode_rdsr, &.{}, &sr, false) catch unreachable;
    return sr[0];
}

/// Read `dst.len` bytes from flash address `addr` into RAM. EasyDMA:
/// `addr`, `dst` and its length are word-aligned.
pub fn read(addr: u24, dst: []u8) Error!void {
    if (addr % 4 != 0 or @intFromPtr(dst.ptr) % 4 != 0 or dst.len % 4 != 0) return error.Unaligned;
    if (dst.len >= 1 << 18) return error.TooLong;
    QSPI.READ.SRC.write_raw(addr);
    QSPI.READ.DST.write_raw(@intFromPtr(dst.ptr));
    QSPI.READ.CNT.write_raw(@intCast(dst.len));
    QSPI.EVENTS_READY.write_raw(0);
    QSPI.TASKS_READSTART.write_raw(1);
    waitReady();
}

/// A program or erase was started and its EasyDMA/command phase has not
/// been seen to end yet.
var command_pending = false;

/// Start programming `src` (from RAM, kept alive until `done`) at flash
/// address `addr`, which the caller has erased. The peripheral splits it
/// into pages and sends WREN for each. EasyDMA: `addr`, `src` and its
/// length are word-aligned.
pub fn start_write(addr: u24, src: []const u8) Error!void {
    if (addr % 4 != 0 or @intFromPtr(src.ptr) % 4 != 0 or src.len % 4 != 0) return error.Unaligned;
    if (src.len >= 1 << 18) return error.TooLong;
    QSPI.WRITE.DST.write_raw(addr);
    QSPI.WRITE.SRC.write_raw(@intFromPtr(src.ptr));
    QSPI.WRITE.CNT.write_raw(@intCast(src.len));
    QSPI.EVENTS_READY.write_raw(0);
    QSPI.TASKS_WRITESTART.write_raw(1);
    command_pending = true;
}

pub const EraseSize = enum { sector_4k, block_64k, chip };

/// Start erasing the sector or block holding `addr` (or the whole chip).
pub fn start_erase(addr: u24, size: EraseSize) void {
    QSPI.ERASE.PTR.write_raw(addr);
    QSPI.ERASE.LEN.write(.{ .LEN = switch (size) {
        .sector_4k => .@"4KB",
        .block_64k => .@"64KB",
        .chip => .All,
    } });
    QSPI.EVENTS_READY.write_raw(0);
    QSPI.TASKS_ERASESTART.write_raw(1);
    command_pending = true;
}

/// Whether the last `start_write` or `start_erase` has finished: the
/// peripheral's command and the flash's own program or erase (WIP clear).
pub fn done() bool {
    if (command_pending) {
        if (QSPI.EVENTS_READY.raw == 0) return false;
        QSPI.EVENTS_READY.write_raw(0);
        command_pending = false;
    }
    return status() & status_wip == 0;
}

/// `start_write`, then spin until `done`.
pub fn write(addr: u24, src: []const u8) Error!void {
    try start_write(addr, src);
    while (!done()) {}
}

/// `start_erase`, then spin until `done`.
pub fn erase(addr: u24, size: EraseSize) void {
    start_erase(addr, size);
    while (!done()) {}
}

/// The flash as memory (after `init`), `len` bytes from `addr`.
pub fn mapped(addr: usize, len: usize) []const u8 {
    return @as([*]const u8, @ptrFromInt(xip_base + addr))[0..len];
}
