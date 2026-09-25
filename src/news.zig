//! arch's news feed. news is how arch announces updates that need a hand,
//! so `os update` shows what was posted between the old lock's date and
//! the new one.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const feed_url = "https://archlinux.org/feeds/news/";

pub const Item = struct {
    /// yyyy-mm-dd
    date: []const u8,
    title: []const u8,
    link: []const u8,
};

/// the items in an rss feed, newest first as arch lists them.
pub fn parse(a: Allocator, xml: []const u8) ![]const Item {
    var out: std.ArrayList(Item) = .empty;
    var rest = xml;
    while (std.mem.indexOf(u8, rest, "<item>")) |start| {
        const end = std.mem.indexOfPos(u8, rest, start, "</item>") orelse break;
        const item = rest[start..end];
        rest = rest[end..];
        const date = dateOf(a, tag(item, "pubDate") orelse continue) orelse continue;
        try out.append(a, .{
            .date = date,
            .title = try unescape(a, tag(item, "title") orelse continue),
            .link = try unescape(a, tag(item, "link") orelse continue),
        });
    }
    return out.items;
}

/// the items posted after `after` and up to `upto`, both yyyy-mm-dd.
pub fn between(a: Allocator, items: []const Item, after: []const u8, upto: []const u8) ![]const Item {
    var out: std.ArrayList(Item) = .empty;
    for (items) |it| {
        if (std.mem.order(u8, it.date, after) == .gt and std.mem.order(u8, it.date, upto) != .gt) try out.append(a, it);
    }
    return out.items;
}

fn tag(xml: []const u8, comptime name: []const u8) ?[]const u8 {
    const open = "<" ++ name ++ ">";
    const start = (std.mem.indexOf(u8, xml, open) orelse return null) + open.len;
    const end = std.mem.indexOfPos(u8, xml, start, "</" ++ name ++ ">") orelse return null;
    return xml[start..end];
}

/// "Tue, 22 Sep 2026 09:09:27 +0000" as "2026-09-22".
fn dateOf(a: Allocator, rfc822: []const u8) ?[]const u8 {
    var parts = std.mem.tokenizeAny(u8, rfc822, ", ");
    _ = parts.next() orelse return null;
    const day = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
    const month_name = parts.next() orelse return null;
    const year = std.fmt.parseInt(u16, parts.next() orelse return null, 10) catch return null;
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const month = for (months, 1..) |m, i| {
        if (std.mem.eql(u8, m, month_name)) break i;
    } else return null;
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch null;
}

fn unescape(a: Allocator, text: []const u8) ![]const u8 {
    var out: []const u8 = text;
    for ([_][2][]const u8{ .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&#39;", "'" }, .{ "&amp;", "&" } }) |e| {
        out = try std.mem.replaceOwned(u8, a, out, e[0], e[1]);
    }
    return out;
}

test "items from the feed, and the ones between two dates" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try parse(a,
        \\<rss><channel><title>Arch Linux: Recent news updates</title>
        \\<item><title>Mkinitcpio &gt;=42 requires manual intervention</title><link>https://archlinux.org/news/mkinitcpio-42/</link><description>&lt;p&gt;...</description><pubDate>Tue, 22 Sep 2026 09:09:27 +0000</pubDate></item>
        \\<item><title>Older news</title><link>https://archlinux.org/news/older/</link><pubDate>Mon, 1 Sep 2026 10:00:00 +0000</pubDate></item>
        \\</channel></rss>
    );
    try std.testing.expectEqual(2, items.len);
    try std.testing.expectEqualStrings("2026-09-22", items[0].date);
    try std.testing.expectEqualStrings("Mkinitcpio >=42 requires manual intervention", items[0].title);
    try std.testing.expectEqualStrings("2026-09-01", items[1].date);

    const since = try between(a, items, "2026-09-18", "2026-09-25");
    try std.testing.expectEqual(1, since.len);
    try std.testing.expectEqualStrings("https://archlinux.org/news/mkinitcpio-42/", since[0].link);
    try std.testing.expectEqual(0, (try between(a, items, "2026-09-22", "2026-09-25")).len);
}
