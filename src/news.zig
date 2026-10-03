//! arch's news feed. news is how arch announces updates that need a hand,
//! so `yos update` shows what was posted between the old lock's date and
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
            .title = try plain(a, try unescape(a, tag(item, "title") orelse continue)),
            .link = try plain(a, try unescape(a, tag(item, "link") orelse continue)),
        });
    }
    return out.items;
}

/// the items posted on `from` or after, up to `upto`, both yyyy-mm-dd.
/// a lock's date is a day, and an item posted later on the day of the
/// old lock came after it, so that day counts. an item from before the
/// old lock that day shows up twice, which beats never.
pub fn between(a: Allocator, items: []const Item, from: []const u8, upto: []const u8) ![]const Item {
    var out: std.ArrayList(Item) = .empty;
    for (items) |it| {
        if (std.mem.order(u8, it.date, from) != .lt and std.mem.order(u8, it.date, upto) != .gt) try out.append(a, it);
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
    // the date is compared as text with lock dates, so it has to come out
    // as yyyy-mm-dd.
    if (day < 1 or day > 31 or year > 9999) return null;
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch null;
}

fn unescape(a: Allocator, text: []const u8) ![]const u8 {
    var out: []const u8 = text;
    for ([_][2][]const u8{ .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&#39;", "'" }, .{ "&amp;", "&" } }) |e| {
        out = try std.mem.replaceOwned(u8, a, out, e[0], e[1]);
    }
    return out;
}

/// `text` without control characters, so a title can't move the cursor or
/// change colors when it's printed: escape sequences go whole, and other
/// controls become spaces. commit subjects from a config's history go
/// through it too, since a cloned repository can hold anything.
pub fn plain(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == 0x1b) {
            // a csi sequence, like ESC [ 31 m, runs to its final byte.
            if (i + 1 < text.len and text[i + 1] == '[') {
                i += 2;
                while (i < text.len and (text[i] < 0x40 or text[i] > 0x7e)) i += 1;
            }
        } else if (ch == 0xc2 and i + 1 < text.len and text[i + 1] >= 0x80 and text[i + 1] <= 0x9f) {
            // the utf-8 form of a c1 control, which some terminals act on.
            i += 1;
        } else try out.append(a, if (ch < 0x20 or ch == 0x7f) ' ' else ch);
    }
    return out.items;
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
    // posted on the old lock's day, maybe after it.
    try std.testing.expectEqual(1, (try between(a, items, "2026-09-22", "2026-09-25")).len);
    try std.testing.expectEqual(0, (try between(a, items, "2026-09-23", "2026-09-25")).len);
}

test "titles lose control characters and escape sequences" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try parse(a, "<item><title>\x1b[31mred\x1b[0m\x07 news\nhere \xc2\x9b2J\xc3\xa9</title><link>https://archlinux.org/news/x/\x1b]0;hi\x07</link><pubDate>Tue, 22 Sep 2026 09:09:27 +0000</pubDate></item>");
    try std.testing.expectEqual(1, items.len);
    try std.testing.expectEqualStrings("red  news here 2J\xc3\xa9", items[0].title);
    try std.testing.expectEqualStrings("https://archlinux.org/news/x/]0;hi ", items[0].link);
}

test "items with a date out of range are skipped" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const items = try parse(arena.allocator(),
        \\<item><title>t</title><link>l</link><pubDate>Tue, 99 Sep 20266 00:00:00 +0000</pubDate></item>
        \\<item><title>t</title><link>l</link><pubDate>Tue, 0 Sep 2026 00:00:00 +0000</pubDate></item>
        \\<item><title>t</title><link>l</link><pubDate>Tue, 31 Sep 2026 00:00:00 +0000</pubDate></item>
    );
    try std.testing.expectEqual(1, items.len);
    try std.testing.expectEqualStrings("2026-09-31", items[0].date);
}
