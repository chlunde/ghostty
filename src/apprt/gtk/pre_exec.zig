const std = @import("std");

const log = std.log.scoped(.gtk_pre_exec);

const configpkg = @import("../../config.zig");
const global = @import("../../global.zig");

const internal_os = @import("../../os/main.zig");
const Command = @import("../../Command.zig");
const cgroup = @import("./cgroup.zig");

pub const PreExecInfo = struct {
    gtk_single_instance: configpkg.Config.GtkSingleInstance,
    linux_cgroup: configpkg.Config.LinuxCgroup,
    linux_cgroup_hard_fail: bool,

    pub fn init(cfg: *const configpkg.Config) PreExecInfo {
        return .{
            .gtk_single_instance = cfg.@"gtk-single-instance",
            .linux_cgroup = cfg.@"linux-cgroup",
            .linux_cgroup_hard_fail = cfg.@"linux-cgroup-hard-fail",
        };
    }
};

/// The child no longer waits for the cgroup transition before exec;
/// see postFork.
pub fn preExec(cmd: *Command) ?u8 {
    _ = cmd;
    return null;
}
