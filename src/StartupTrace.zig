//! Logs the latency of new surface startup milestones (log scope: startup),
//! relative to the start of core surface init.
const StartupTrace = @This();

const std = @import("std");
const global = @import("global.zig");

const log = std.log.scoped(.startup);

start: std.Io.Timestamp,
first_frame: bool = false,
first_prompt: bool = false,

pub fn init() StartupTrace {
    return .{ .start = .now(global.io(), .awake) };
}

pub fn mark(self: *const StartupTrace, comptime event: []const u8) void {
    log.info(event ++ " t={d}us", .{self.elapsedUs()});
}

/// Mark an event only the first time it is reached.
pub fn markOnce(self: *StartupTrace, comptime field: []const u8) void {
    if (@field(self, field)) return;
    @field(self, field) = true;
    self.mark(field);
}

fn elapsedUs(self: *const StartupTrace) i64 {
    return self.start.untilNow(global.io(), .awake).toMicroseconds();
}
