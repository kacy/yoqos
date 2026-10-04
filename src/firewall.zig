//! `[firewall]`: nothing comes in but what `allow` lets in, and everything
//! goes out. ufw keeps the rules. yos writes the three files ufw reads its
//! state from, the same way `ufw allow` writes them, so `ufw status` shows
//! yos's rules, and a rule added with `ufw` shows up as a change to a file
//! yos writes. pure, like the planner.
//!
//! a rule is ports and where traffic comes from and goes to:
//!
//!   "22/tcp"                                   a port, over tcp
//!   "53317"                                    over tcp and udp
//!   "6000:6007/tcp", "80,443/tcp"              a range or a list, with a protocol
//!   "53/udp from 172.16.0.0/12 to 172.17.0.1"  only between those addresses
//!   "from 10.0.0.0/8"                          anything from there
//!
//! a rule without addresses holds for ipv4 and ipv6. addresses are ipv4.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const package = "ufw";
pub const unit = "ufw.service";
pub const conf_path = "/etc/ufw/ufw.conf";
pub const rules_path = "/etc/ufw/user.rules";
pub const rules6_path = "/etc/ufw/user6.rules";

/// whether yos writes `path` for `[firewall]`.
pub fn isFile(path: []const u8) bool {
    for ([_][]const u8{ conf_path, rules_path, rules6_path }) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

pub const Rule = struct {
    /// "tcp" or "udp"; null for both, or for a rule without ports.
    proto: ?[]const u8 = null,
    /// "22", "6000:6007", or "80,443".
    ports: ?[]const u8 = null,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,

    fn multi(r: Rule) bool {
        const p = r.ports orelse return false;
        return std.mem.indexOfAny(u8, p, ":,") != null;
    }

    /// a rule with an address holds for ipv4 only.
    fn v4Only(r: Rule) bool {
        return r.from != null or r.to != null;
    }
};

/// a rule, or what's wrong with it and how to write it instead.
pub const Parsed = union(enum) {
    rule: Rule,
    bad: []const u8,
};

pub fn parse(a: Allocator, text: []const u8) !Parsed {
    var r: Rule = .{};
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    var word = words.next() orelse return .{ .bad = "a rule names ports, like \"22/tcp\", or an address, like \"from 10.0.0.0/8\"" };
    if (!std.mem.eql(u8, word, "from") and !std.mem.eql(u8, word, "to")) {
        const slash = std.mem.indexOfScalar(u8, word, '/');
        const ports = word[0 .. slash orelse word.len];
        if (slash) |s| {
            const proto = word[s + 1 ..];
            if (!std.mem.eql(u8, proto, "tcp") and !std.mem.eql(u8, proto, "udp")) return .{ .bad = "the protocol after a port is tcp or udp, like \"22/tcp\"" };
            r.proto = proto;
        }
        if (portsProblem(ports)) |why| return .{ .bad = why };
        r.ports = ports;
        if (r.proto == null and r.multi()) return .{ .bad = "a range or list of ports needs a protocol, like \"6000:6007/tcp\"" };
        word = words.next() orelse return .{ .rule = r };
    }
    while (true) {
        const from = std.mem.eql(u8, word, "from") and r.from == null and r.to == null;
        const to = std.mem.eql(u8, word, "to") and r.to == null;
        if (!from and !to) return .{ .bad = "a rule is ports, then from an address, then to one, each once, like \"53/udp from 172.16.0.0/12 to 172.17.0.1\"" };
        const addr = words.next() orelse return .{ .bad = "an address comes after from or to, like \"from 10.0.0.0/8\"" };
        if (try addressProblem(a, addr)) |why| return .{ .bad = why };
        if (from) r.from = addr else r.to = addr;
        word = words.next() orelse return .{ .rule = r };
    }
}

/// a port, "6000:6007", or "80,443", with at most 15 ports in a list (a
/// range counts as two), as iptables' multiport takes.
fn portsProblem(ports: []const u8) ?[]const u8 {
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, ports, ',');
    while (parts.next()) |part| {
        if (std.mem.indexOfScalar(u8, part, ':')) |c| {
            const lo = port(part[0..c]) orelse return "\"" ++ "a:b\" is a range of ports from 1 to 65535";
            const hi = port(part[c + 1 ..]) orelse return "\"a:b\" is a range of ports from 1 to 65535";
            if (lo >= hi) return "a range of ports goes from the lower one to the higher one, like \"6000:6007\"";
            count += 2;
        } else {
            _ = port(part) orelse return "a port is a number from 1 to 65535";
            count += 1;
        }
    }
    if (count > 15) return "a list holds 15 ports at most, counting a range as two";
    return null;
}

fn port(s: []const u8) ?u16 {
    if (s.len == 0 or s[0] == '0') return null;
    const n = std.fmt.parseInt(u16, s, 10) catch return null;
    return if (n == 0) null else n;
}

/// an ipv4 address, or a network written the way ufw writes it: no host
/// bits, and no /32.
fn addressProblem(a: Allocator, addr: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, addr, ':') != null) return "addresses here are ipv4; a rule without addresses covers ipv6 too";
    const slash = std.mem.indexOfScalar(u8, addr, '/');
    const ip = ipv4(addr[0 .. slash orelse addr.len]) orelse return "an address looks like 172.17.0.1, or a network like 172.16.0.0/12";
    const s = slash orelse return null;
    const bits = std.fmt.parseInt(u6, addr[s + 1 ..], 10) catch return "a network's prefix is a number from 1 to 31, like /12";
    if (bits == 0 or bits > 31 or addr[s + 1] == '0') {
        if (bits == 32) return try std.fmt.allocPrint(a, "write {s} without /32", .{addr[0..s]});
        return "a network's prefix is a number from 1 to 31, like /12; leave out from or to for any address";
    }
    const mask = ~@as(u32, 0) << @intCast(32 - @as(u32, bits));
    if (ip & ~mask != 0) {
        const net = ip & mask;
        return try std.fmt.allocPrint(a, "write it as {d}.{d}.{d}.{d}/{d}", .{ net >> 24, (net >> 16) & 255, (net >> 8) & 255, net & 255, bits });
    }
    return null;
}

/// four numbers from 0 to 255, without leading zeros.
fn ipv4(s: []const u8) ?u32 {
    var out: u32 = 0;
    var n: usize = 0;
    var parts = std.mem.splitScalar(u8, s, '.');
    while (parts.next()) |p| : (n += 1) {
        if (n == 4 or p.len == 0 or (p.len > 1 and p[0] == '0')) return null;
        out = (out << 8) | (std.fmt.parseInt(u8, p, 10) catch return null);
    }
    return if (n == 4) out else null;
}

/// ufw.conf: on at boot, and logging blocked packets at the low level the
/// rules files are written for.
pub const conf =
    \\# written by yos from [firewall] in the config. edits here are overwritten.
    \\ENABLED=yes
    \\LOGLEVEL=low
    \\
;

pub const Family = enum { v4, v6 };

/// user.rules or user6.rules for `rules`, which parsed.
pub fn rulesFile(a: Allocator, rules: []const Rule, family: Family) ![]const u8 {
    const chain = if (family == .v4) "ufw" else "ufw6";
    const any = if (family == .v4) "0.0.0.0/0" else "::/0";
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "*filter\n");
    for (chains) |c| try out.print(a, ":{s}-{s} - [0:0]\n", .{ chain, c });
    try out.appendSlice(a, "### RULES ###\n");
    for (rules) |r| {
        if (family == .v6 and r.v4Only()) continue;
        try out.print(a, "\n### tuple ### allow {s} {s} {s} any {s} in\n", .{ r.proto orelse "any", r.ports orelse "any", r.to orelse any, r.from orelse any });
        // a port without a protocol is a rule for each.
        const protos: []const ?[]const u8 = if (r.proto) |p| &.{p} else if (r.ports != null) &.{ "tcp", "udp" } else &.{null};
        for (protos) |p| {
            try out.print(a, "-A {s}-user-input", .{chain});
            if (p) |name| try out.print(a, " -p {s}", .{name});
            if (r.multi()) try out.print(a, " -m multiport --dports {s}", .{r.ports.?});
            if (r.to) |to| try out.print(a, " -d {s}", .{to});
            if (!r.multi()) if (r.ports) |ports| try out.print(a, " --dport {s}", .{ports});
            if (r.from) |from| try out.print(a, " -s {s}", .{from});
            try out.appendSlice(a, " -j ACCEPT\n");
        }
    }
    try out.appendSlice(a, "\n### END RULES ###\n\n### LOGGING ###\n");
    inline for (logging) |l| try out.print(a, l ++ "\n", .{chain});
    try out.appendSlice(a, "### END LOGGING ###\n\n### RATE LIMITING ###\n");
    inline for (limiting) |l| try out.print(a, l ++ "\n", .{chain});
    try out.appendSlice(a, "### END RATE LIMITING ###\nCOMMIT\n");
    return out.items;
}

const chains = [_][]const u8{
    "user-input",           "user-output",           "user-forward",
    "before-logging-input", "before-logging-output", "before-logging-forward",
    "user-logging-input",   "user-logging-output",   "user-logging-forward",
    "after-logging-input",  "after-logging-output",  "after-logging-forward",
    "logging-deny",         "logging-allow",         "user-limit",
    "user-limit-accept",
};

const logging = [_][]const u8{
    "-A {s}-after-logging-input -j LOG --log-prefix \"[UFW BLOCK] \" -m limit --limit 3/min --limit-burst 10",
    "-A {s}-after-logging-forward -j LOG --log-prefix \"[UFW BLOCK] \" -m limit --limit 3/min --limit-burst 10",
    "-I {s}-logging-deny -m conntrack --ctstate INVALID -j RETURN -m limit --limit 3/min --limit-burst 10",
    "-A {s}-logging-deny -j LOG --log-prefix \"[UFW BLOCK] \" -m limit --limit 3/min --limit-burst 10",
    "-A {s}-logging-allow -j LOG --log-prefix \"[UFW ALLOW] \" -m limit --limit 3/min --limit-burst 10",
};

const limiting = [_][]const u8{
    "-A {s}-user-limit -m limit --limit 3/minute -j LOG --log-prefix \"[UFW LIMIT BLOCK] \"",
    "-A {s}-user-limit -j REJECT",
    "-A {s}-user-limit-accept -j ACCEPT",
};

// -- tests --

const testing = std.testing;

fn parsed(text: []const u8) !Rule {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    return switch (try parse(arena.allocator(), text)) {
        .rule => |r| r,
        .bad => |why| {
            std.debug.print("{s}: {s}\n", .{ text, why });
            return error.TestUnexpectedResult;
        },
    };
}

fn expectBad(text: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    switch (try parse(arena.allocator(), text)) {
        .rule => return error.TestUnexpectedResult,
        .bad => |why| try testing.expectEqualStrings(want, why),
    }
}

test "rules parse" {
    const r = try parsed("53/udp from 172.16.0.0/12 to 172.17.0.1");
    try testing.expectEqualStrings("udp", r.proto.?);
    try testing.expectEqualStrings("53", r.ports.?);
    try testing.expectEqualStrings("172.16.0.0/12", r.from.?);
    try testing.expectEqualStrings("172.17.0.1", r.to.?);
    _ = try parsed("22");
    _ = try parsed("6000:6007/tcp");
    _ = try parsed("80,443/tcp");
    _ = try parsed("from 10.0.0.0/8");
    _ = try parsed("to 10.0.0.1");
    _ = try parsed("from 10.0.0.0/8 to 10.0.0.5");
}

test "bad rules say how to write them" {
    try expectBad("", "a rule names ports, like \"22/tcp\", or an address, like \"from 10.0.0.0/8\"");
    try expectBad("22/icmp", "the protocol after a port is tcp or udp, like \"22/tcp\"");
    try expectBad("0", "a port is a number from 1 to 65535");
    try expectBad("65536/tcp", "a port is a number from 1 to 65535");
    try expectBad("6000:6007", "a range or list of ports needs a protocol, like \"6000:6007/tcp\"");
    try expectBad("7:6/tcp", "a range of ports goes from the lower one to the higher one, like \"6000:6007\"");
    try expectBad("from 10.1.2.3/8", "write it as 10.0.0.0/8");
    try expectBad("from 1.2.3.4/32", "write 1.2.3.4 without /32");
    try expectBad("from ::1", "addresses here are ipv4; a rule without addresses covers ipv6 too");
    try expectBad("from 10.0.0.01", "an address looks like 172.17.0.1, or a network like 172.16.0.0/12");
    try expectBad("22 from", "an address comes after from or to, like \"from 10.0.0.0/8\"");
    try expectBad("22 to 10.0.0.1 from 10.0.0.0/8", "a rule is ports, then from an address, then to one, each once, like \"53/udp from 172.16.0.0/12 to 172.17.0.1\"");
    try expectBad("22 22", "a rule is ports, then from an address, then to one, each once, like \"53/udp from 172.16.0.0/12 to 172.17.0.1\"");
}

// the rules files ufw 0.36.2 wrote for the same rules, added in this order
// with `ufw allow`, and logging left at low.
test "rules files match ufw's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const texts = [_][]const u8{
        "53317/udp",      "6000:6007/tcp",                           "from 10.0.0.0/8", "to 172.17.0.1",
        "22",             "53/udp from 172.16.0.0/12 to 172.17.0.1", "80,443/tcp",      "3000 to 10.0.0.1",
        "9 from 1.2.3.4",
    };
    var rules: [texts.len]Rule = undefined;
    for (texts, &rules) |t, *r| r.* = try parsed(t);
    try testing.expectEqualStrings(
        \\*filter
        \\:ufw-user-input - [0:0]
        \\:ufw-user-output - [0:0]
        \\:ufw-user-forward - [0:0]
        \\:ufw-before-logging-input - [0:0]
        \\:ufw-before-logging-output - [0:0]
        \\:ufw-before-logging-forward - [0:0]
        \\:ufw-user-logging-input - [0:0]
        \\:ufw-user-logging-output - [0:0]
        \\:ufw-user-logging-forward - [0:0]
        \\:ufw-after-logging-input - [0:0]
        \\:ufw-after-logging-output - [0:0]
        \\:ufw-after-logging-forward - [0:0]
        \\:ufw-logging-deny - [0:0]
        \\:ufw-logging-allow - [0:0]
        \\:ufw-user-limit - [0:0]
        \\:ufw-user-limit-accept - [0:0]
        \\### RULES ###
        \\
        \\### tuple ### allow udp 53317 0.0.0.0/0 any 0.0.0.0/0 in
        \\-A ufw-user-input -p udp --dport 53317 -j ACCEPT
        \\
        \\### tuple ### allow tcp 6000:6007 0.0.0.0/0 any 0.0.0.0/0 in
        \\-A ufw-user-input -p tcp -m multiport --dports 6000:6007 -j ACCEPT
        \\
        \\### tuple ### allow any any 0.0.0.0/0 any 10.0.0.0/8 in
        \\-A ufw-user-input -s 10.0.0.0/8 -j ACCEPT
        \\
        \\### tuple ### allow any any 172.17.0.1 any 0.0.0.0/0 in
        \\-A ufw-user-input -d 172.17.0.1 -j ACCEPT
        \\
        \\### tuple ### allow any 22 0.0.0.0/0 any 0.0.0.0/0 in
        \\-A ufw-user-input -p tcp --dport 22 -j ACCEPT
        \\-A ufw-user-input -p udp --dport 22 -j ACCEPT
        \\
        \\### tuple ### allow udp 53 172.17.0.1 any 172.16.0.0/12 in
        \\-A ufw-user-input -p udp -d 172.17.0.1 --dport 53 -s 172.16.0.0/12 -j ACCEPT
        \\
        \\### tuple ### allow tcp 80,443 0.0.0.0/0 any 0.0.0.0/0 in
        \\-A ufw-user-input -p tcp -m multiport --dports 80,443 -j ACCEPT
        \\
        \\### tuple ### allow any 3000 10.0.0.1 any 0.0.0.0/0 in
        \\-A ufw-user-input -p tcp -d 10.0.0.1 --dport 3000 -j ACCEPT
        \\-A ufw-user-input -p udp -d 10.0.0.1 --dport 3000 -j ACCEPT
        \\
        \\### tuple ### allow any 9 0.0.0.0/0 any 1.2.3.4 in
        \\-A ufw-user-input -p tcp --dport 9 -s 1.2.3.4 -j ACCEPT
        \\-A ufw-user-input -p udp --dport 9 -s 1.2.3.4 -j ACCEPT
        \\
        \\### END RULES ###
        \\
        \\### LOGGING ###
        \\-A ufw-after-logging-input -j LOG --log-prefix "[UFW BLOCK] " -m limit --limit 3/min --limit-burst 10
        \\-A ufw-after-logging-forward -j LOG --log-prefix "[UFW BLOCK] " -m limit --limit 3/min --limit-burst 10
        \\-I ufw-logging-deny -m conntrack --ctstate INVALID -j RETURN -m limit --limit 3/min --limit-burst 10
        \\-A ufw-logging-deny -j LOG --log-prefix "[UFW BLOCK] " -m limit --limit 3/min --limit-burst 10
        \\-A ufw-logging-allow -j LOG --log-prefix "[UFW ALLOW] " -m limit --limit 3/min --limit-burst 10
        \\### END LOGGING ###
        \\
        \\### RATE LIMITING ###
        \\-A ufw-user-limit -m limit --limit 3/minute -j LOG --log-prefix "[UFW LIMIT BLOCK] "
        \\-A ufw-user-limit -j REJECT
        \\-A ufw-user-limit-accept -j ACCEPT
        \\### END RATE LIMITING ###
        \\COMMIT
        \\
    , try rulesFile(a, &rules, .v4));
    try testing.expectEqualStrings(
        \\*filter
        \\:ufw6-user-input - [0:0]
        \\:ufw6-user-output - [0:0]
        \\:ufw6-user-forward - [0:0]
        \\:ufw6-before-logging-input - [0:0]
        \\:ufw6-before-logging-output - [0:0]
        \\:ufw6-before-logging-forward - [0:0]
        \\:ufw6-user-logging-input - [0:0]
        \\:ufw6-user-logging-output - [0:0]
        \\:ufw6-user-logging-forward - [0:0]
        \\:ufw6-after-logging-input - [0:0]
        \\:ufw6-after-logging-output - [0:0]
        \\:ufw6-after-logging-forward - [0:0]
        \\:ufw6-logging-deny - [0:0]
        \\:ufw6-logging-allow - [0:0]
        \\:ufw6-user-limit - [0:0]
        \\:ufw6-user-limit-accept - [0:0]
        \\### RULES ###
        \\
        \\### tuple ### allow udp 53317 ::/0 any ::/0 in
        \\-A ufw6-user-input -p udp --dport 53317 -j ACCEPT
        \\
        \\### tuple ### allow tcp 6000:6007 ::/0 any ::/0 in
        \\-A ufw6-user-input -p tcp -m multiport --dports 6000:6007 -j ACCEPT
        \\
        \\### tuple ### allow any 22 ::/0 any ::/0 in
        \\-A ufw6-user-input -p tcp --dport 22 -j ACCEPT
        \\-A ufw6-user-input -p udp --dport 22 -j ACCEPT
        \\
        \\### tuple ### allow tcp 80,443 ::/0 any ::/0 in
        \\-A ufw6-user-input -p tcp -m multiport --dports 80,443 -j ACCEPT
        \\
        \\### END RULES ###
        \\
        \\### LOGGING ###
        \\-A ufw6-after-logging-input -j LOG --log-prefix "[UFW BLOCK] " -m limit --limit 3/min --limit-burst 10
        \\-A ufw6-after-logging-forward -j LOG --log-prefix "[UFW BLOCK] " -m limit --limit 3/min --limit-burst 10
        \\-I ufw6-logging-deny -m conntrack --ctstate INVALID -j RETURN -m limit --limit 3/min --limit-burst 10
        \\-A ufw6-logging-deny -j LOG --log-prefix "[UFW BLOCK] " -m limit --limit 3/min --limit-burst 10
        \\-A ufw6-logging-allow -j LOG --log-prefix "[UFW ALLOW] " -m limit --limit 3/min --limit-burst 10
        \\### END LOGGING ###
        \\
        \\### RATE LIMITING ###
        \\-A ufw6-user-limit -m limit --limit 3/minute -j LOG --log-prefix "[UFW LIMIT BLOCK] "
        \\-A ufw6-user-limit -j REJECT
        \\-A ufw6-user-limit-accept -j ACCEPT
        \\### END RATE LIMITING ###
        \\COMMIT
        \\
    , try rulesFile(a, &rules, .v6));
}
