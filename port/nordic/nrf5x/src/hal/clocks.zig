const std = @import("std");
const microzig = @import("microzig");
const CLOCK = microzig.chip.peripherals.CLOCK;

const compatibility = microzig.hal.compatibility;

const version: enum {
    nrf51,
    nrf52,
} = switch (compatibility.chip) {
    .nrf51 => .nrf51,
    .nrf52, .nrf52833, .nrf52840 => .nrf52,
    else => compatibility.unsupported_chip("clocks"),
};

pub const hfxo = struct {
    /// Start the crystal and wait until it runs. A bootloader may leave the
    /// crystal running, or HFCLKSTARTED set from its own start (the event
    /// survives a reset), so on the nRF52 this returns at once if the
    /// crystal runs and otherwise clears the event before waiting for it.
    pub fn start() void {
        switch (version) {
            .nrf51 => {
                CLOCK.TASKS_HFCLKSTART = 1;
                while (CLOCK.EVENTS_HFCLKSTARTED == 0) {}
            },
            .nrf52 => {
                if (is_running()) return;
                CLOCK.EVENTS_HFCLKSTARTED.write_raw(0);
                CLOCK.TASKS_HFCLKSTART.write_raw(1);
                while (CLOCK.EVENTS_HFCLKSTARTED.raw == 0) {}
                CLOCK.EVENTS_HFCLKSTARTED.write_raw(0);
            },
        }
    }

    /// Whether the high-frequency clock runs from the crystal (nRF52).
    pub fn is_running() bool {
        const stat = CLOCK.HFCLKSTAT.read();
        return stat.STATE == .Running and stat.SRC == .Xtal;
    }

    pub fn stop() void {
        switch (version) {
            .nrf51 => {
                CLOCK.TASKS_HFCLKSTOP = 1;
            },
            .nrf52 => {
                CLOCK.TASKS_HFCLKSTOP.write_raw(1);
            },
        }
    }
};

pub const lfclk = struct {
    pub const Source = union(enum(u2)) {
        RC = 0,
        Xtal: struct {
            external: bool,
            bypass: bool,
        } = 1,
        Synth = 2,
        fn validate(self: @This()) !void {
            // Valid settings:
            // SRC RC, External disabled, Bypass disabled
            // SRC Xtal, External disabled, Bypass disabled
            // SRC Xtal, External enabled, Bypass disabled
            // SRC Xtal, External enabled, Bypass enabled
            // SRC Synth, External disabled, Bypass disabled
            return switch (self) {
                .RC, .Synth => return,
                .Xtal => |v| if (v.bypass and !v.external) error.InvalidSource,
            };
        }
    };

    /// Calibrate the RC oscillator against the crystal. On the nRF52 the
    /// crystal runs for the duration, DONE is cleared first (it survives a
    /// reset, so a stale one would end the wait at once), and the wait is
    /// bounded: false if DONE did not come, the oscillator then runs
    /// uncalibrated. Seen on an nRF52840 after its UF2 bootloader: DONE never
    /// came, and an unbounded wait hung start-up.
    pub fn calibrate() bool {
        switch (version) {
            .nrf51 => {
                CLOCK.TASKS_CAL = 1;
                while (CLOCK.EVENTS_DONE == 0) {}
                return true;
            },
            .nrf52 => {
                const hfxo_was_running = hfxo.is_running();
                hfxo.start();
                defer if (!hfxo_was_running) hfxo.stop();
                CLOCK.EVENTS_DONE.write_raw(0);
                CLOCK.TASKS_CAL.write_raw(1);
                // A calibration takes milliseconds; about 0.5 s of polling.
                var polls: u32 = 0;
                while (CLOCK.EVENTS_DONE.raw == 0) : (polls += 1) {
                    if (polls == 10_000_000) return false;
                }
                CLOCK.EVENTS_DONE.write_raw(0);
                return true;
            },
        }
    }

    pub fn set_source(comptime source: Source) void {
        switch (version) {
            .nrf51 => {
                CLOCK.LFCLKSRC.write(.{
                    .SRC = @fromBackingInt(@backingInt(source)),
                });
            },
            .nrf52 => {
                comptime source.validate() catch {
                    @compileError("Invalid clock source");
                };
                // LFCLKSRC may only change while the clock is stopped, and a
                // bootloader may have left it running.
                if (CLOCK.LFCLKSTAT.read().STATE == .Running) {
                    if (std.meta.eql(get_source(), source)) return;
                    stop();
                }
                switch (source) {
                    .RC => CLOCK.LFCLKSRC.write(
                        .{ .SRC = .RC, .BYPASS = .Disabled, .EXTERNAL = .Disabled },
                    ),
                    .Xtal => |x| {
                        CLOCK.LFCLKSRC.write(.{
                            .SRC = .Xtal,
                            .BYPASS = @fromBackingInt(@intFromBool(x.bypass)),
                            .EXTERNAL = @fromBackingInt(@intFromBool(x.external)),
                        });
                    },
                    .Synth => CLOCK.LFCLKSRC.write(
                        .{ .SRC = .Synth, .BYPASS = .Disabled, .EXTERNAL = .Disabled },
                    ),
                }
            },
        }
    }

    pub fn get_source() Source {
        const source = CLOCK.LFCLKSRC.read();
        switch (version) {
            .nrf51 => {
                return switch (source.SRC) {
                    .RC => .RC,
                    .Xtal => .{ .Xtal = .{ .bypass = false, .external = false } },
                    .Synth => .Synth,
                    else => unreachable,
                };
            },
            .nrf52 => {
                return switch (source.SRC) {
                    .RC => .RC,
                    .Xtal => .{ .Xtal = .{
                        .bypass = if (source.BYPASS == .Enabled) true else false,
                        .external = if (source.EXTERNAL == .Enabled) true else false,
                    } },
                    .Synth => .Synth,
                    else => unreachable,
                };
            },
        }
    }

    pub fn start() void {
        switch (version) {
            .nrf51 => {
                CLOCK.TASKS_LFCLKSTART = 1;
                while (CLOCK.EVENTS_LFCLKSTARTED == 0) {}
            },
            .nrf52 => {
                // Running already (left by a bootloader): nothing to do.
                // Otherwise clear LFCLKSTARTED first: it survives a reset.
                if (CLOCK.LFCLKSTAT.read().STATE == .Running) return;
                CLOCK.EVENTS_LFCLKSTARTED.write_raw(0);
                CLOCK.TASKS_LFCLKSTART.write_raw(1);
                while (CLOCK.EVENTS_LFCLKSTARTED.raw == 0) {}
                CLOCK.EVENTS_LFCLKSTARTED.write_raw(0);
            },
        }
    }

    /// Stop the clock; on the nRF52, wait until it has stopped.
    pub fn stop() void {
        switch (version) {
            .nrf51 => {
                CLOCK.TASKS_LFCLKSTOP = 1;
            },
            .nrf52 => {
                CLOCK.TASKS_LFCLKSTOP.write_raw(1);
                while (CLOCK.LFCLKSTAT.read().STATE == .Running) {}
            },
        }
    }
};
