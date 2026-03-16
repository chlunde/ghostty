const std = @import("std");

const gio = @import("gio");
const glib = @import("glib");

const log = std.log.scoped(.gtk_post_fork);

const configpkg = @import("../../config.zig");
const internal_os = @import("../../os/main.zig");
const Command = @import("../../Command.zig");
const cgroup = @import("./cgroup.zig");

const Application = @import("class/application.zig").Application;

pub const PostForkInfo = struct {
    gtk_single_instance: configpkg.Config.GtkSingleInstance,
    linux_cgroup: configpkg.Config.LinuxCgroup,
    linux_cgroup_hard_fail: bool,
    linux_cgroup_memory_limit: ?u64,
    linux_cgroup_processes_limit: ?u64,

    pub fn init(cfg: *const configpkg.Config) PostForkInfo {
        return .{
            .gtk_single_instance = cfg.@"gtk-single-instance",
            .linux_cgroup = cfg.@"linux-cgroup",
            .linux_cgroup_hard_fail = cfg.@"linux-cgroup-hard-fail",
            .linux_cgroup_memory_limit = cfg.@"linux-cgroup-memory-limit",
            .linux_cgroup_processes_limit = cfg.@"linux-cgroup-processes-limit",
        };
    }
};

/// Tell systemd to move the child PID into a transient scope.
/// This is now fire-and-forget: we issue the D-Bus createScope call
/// but do NOT poll for the transition to complete. The createScope
/// call is synchronous with systemd accepting the request, and
/// systemd will move the process asynchronously (typically within
/// a few ms). Skipping the poll loop saves ~10-16ms per tab.
pub fn postFork(cmd: *Command) Command.PostForkError!void {
    const post_fork_start = std.time.Instant.now() catch null;

    switch (cmd.rt_post_fork_info.linux_cgroup) {
        .always => {},
        .never => {
            log.info("postFork: cgroups disabled (never), returning", .{});
            return;
        },
        .@"single-instance" => switch (cmd.rt_post_fork_info.gtk_single_instance) {
            .true => {},
            .false => return,
            .detect => {
                log.err("gtk-single-instance is set to detect which should be impossible!", .{});
                return error.PostForkError;
            },
        },
    }

    const pid: u32 = @intCast(cmd.pid orelse {
        log.err("PID of child not known!", .{});
        return error.PostForkError;
    });

    var expected_cgroup_buf: [256]u8 = undefined;
    const expected_cgroup = cgroup.fmtScope(&expected_cgroup_buf, pid);

    log.debug("beginning transition to transient systemd scope {s}", .{expected_cgroup});

    const app = Application.default();

    const dbus = app.as(gio.Application).getDbusConnection() orelse {
        if (cmd.rt_post_fork_info.linux_cgroup_hard_fail) {
            log.err("dbus connection required for cgroup isolation, exiting", .{});
            return error.PostForkError;
        }
        return;
    };

    cgroup.createScope(
        dbus,
        pid,
        .{
            .memory_high = cmd.rt_post_fork_info.linux_cgroup_memory_limit,
            .tasks_max = cmd.rt_post_fork_info.linux_cgroup_processes_limit,
        },
    ) catch |err| {
        if (cmd.rt_post_fork_info.linux_cgroup_hard_fail) {
            log.err("unable to create transient systemd scope {s}: {t}", .{ expected_cgroup, err });
            return error.PostForkError;
        }
        log.warn("unable to create transient systemd scope {s}: {t}", .{ expected_cgroup, err });
        return;
    };

    if (post_fork_start) |pf_start| {
        if (std.time.Instant.now()) |now| {
            log.info("postFork: createScope done (fire-and-forget) elapsed={}us", .{now.since(pf_start) / 1000});
        } else |_| {}
    }

    // No polling — systemd will move the process asynchronously.
    // The createScope D-Bus call is synchronous with systemd accepting
    // the request, so the scope will be created.
}
