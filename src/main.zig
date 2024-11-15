const std = @import("std");
const c = @cImport({
    @cInclude("locale.h");
    @cInclude("ncurses.h");
});
const expect = std.testing.expect;

const Pos = struct {
    x: i8,
    y: i8,

    pub fn eq(self: Pos, other: Pos) bool {
        return self.x == other.x and self.y == other.y;
    }

    pub fn add(self: Pos, other: Pos) Pos {
        return Pos{
            .x = self.x + other.x,
            .y = self.y + other.y,
        };
    }

    pub fn div(self: Pos, k: i8) Pos {
        return Pos{
            .x = @divFloor(self.x, k),
            .y = @divFloor(self.y, k),
        };
    }

    pub fn random(rng: std.Random) Pos {
        return Pos{
            .x = std.rand.intRangeLessThan(rng, i8, 0, Screen.x),
            .y = std.rand.intRangeLessThan(rng, i8, 0, Screen.y),
        };
    }
};

const PosList = std.DoublyLinkedList(Pos);
const Screen = Pos{ .x = 20, .y = 20 };

const Player = struct {
    pos: PosList,
    dir: struct { id: u2, off: Pos },
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !Player {
        const head = Screen.div(2);
        const node = try alloc.create(PosList.Node);
        node.data = head;
        node.next = null;
        node.prev = null;
        return Player{
            .pos = PosList{ .len = 1, .first = node, .last = node },
            .dir = .{ .id = 1, .off = Pos{ .x = 1, .y = 0 } },
            .alloc = alloc,
        };
    }

    pub fn getPos(self: *Player) Pos {
        return self.pos.first.?.data;
    }

    pub fn updateInput(self: *Player, dir: u2) void {
        if (dir == self.dir.id or dir == self.dir.id ^ 0b10) {
            return;
        }
        self.dir.id = dir;
        switch (dir) {
            0 => self.dir.off = Pos{ .x = 0, .y = -1 }, // up
            1 => self.dir.off = Pos{ .x = 1, .y = 0 }, // right
            2 => self.dir.off = Pos{ .x = 0, .y = 1 }, // down
            3 => self.dir.off = Pos{ .x = -1, .y = 0 }, // left
        }
    }

    const UpdateResult = enum {
        apple,
        none,
        death,
    };

    pub fn update(self: *Player, apple: Pos) !UpdateResult {
        // TODO: reuse the node

        const node = try self.alloc.create(PosList.Node);
        node.* = PosList.Node{
            .data = self.pos.first.?.data.add(self.dir.off),
            .next = null,
            .prev = null,
        };
        self.pos.prepend(node);
        if (node.data.eq(apple)) {
            return UpdateResult.apple;
        }

        defer self.alloc.destroy(self.pos.pop().?);
        // _ = self.pos.pop();

        if (self.getPos().x < 0 or self.getPos().x >= Screen.x or self.getPos().y < 0 or self.getPos().y >= Screen.y) {
            return UpdateResult.death;
        }

        return UpdateResult.none;
    }

    pub fn draw(self: *Player, win: *c.WINDOW) void {
        var ppos: ?*PosList.Node = self.pos.first;
        while (ppos) |pos| {
            _ = c.mvwaddstr(win, pos.data.y + 1, pos.data.x * 2 + 1, "██");
            ppos = pos.next;
        }
    }

    pub fn deinit(self: *Player) void {
        while (self.pos.pop()) |node| {
            _ = self.alloc.destroy(node);
        }
    }
};

fn applePos(rng: std.Random, player: *Player) Pos {
    while (true) {
        const p = Pos.random(rng);
        var ppos: ?*PosList.Node = player.pos.first;
        while (ppos) |pos| {
            if (p.eq(pos.data)) {
                break;
            }

            ppos = pos.next;
        }

        if (ppos == null) {
            return p;
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer if (gpa.deinit() != std.heap.Check.ok) {
        std.debug.print("Memory leak detected.\n", .{});
        std.process.exit(1);
    };

    const ui = true;

    if (ui) {
        _ = c.setlocale(c.LC_ALL, "");
        _ = c.initscr();
        _ = c.cbreak();
        _ = c.noecho();
    }

    var score: u32 = 0;
    defer {
        _ = c.endwin();
        std.debug.print("Game over, score: {d}\n", .{score});
    }

    const win = c.newwin(Screen.y + 2, Screen.x * 2 + 2, 0, 0);
    try expect(win != null);
    _ = c.nodelay(win, true);
    _ = c.keypad(win, true);
    _ = c.curs_set(0);

    var prng = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const rng = prng.random();

    var player = try Player.init(alloc);
    defer player.deinit();

    var apple = applePos(rng, &player);

    const Time = struct {
        const speed = 200;

        pub fn getFrame() i64 {
            return @divFloor(std.time.milliTimestamp(), speed);
        }
    };

    var frame = Time.getFrame();

    while (true) {
        _ = c.wclear(win);
        _ = c.box(win, '*', '*');

        player.draw(win);
        _ = c.mvwaddstr(win, apple.y + 1, apple.x * 2 + 1, "@@");

        switch (c.wgetch(win)) {
            'q' => break,
            c.KEY_UP, 'w' => player.updateInput(0), // up
            c.KEY_RIGHT, 'd' => player.updateInput(1), // right
            c.KEY_DOWN, 's' => player.updateInput(2), // down
            c.KEY_LEFT, 'a' => player.updateInput(3), // left
            else => {},
        }

        {
            var buf: [100:0]u8 = undefined;
            const written = (try std.fmt.bufPrint(&buf, "Score: {d}", .{score}));
            _ = c.mvwaddnstr(win, 0, 0, @ptrCast(written), @intCast(written.len));
        }

        _ = c.wrefresh(win);

        switch (try player.update(apple)) {
            Player.UpdateResult.apple => {
                score += 1;
                apple = applePos(rng, &player);
            },
            Player.UpdateResult.death => break,
            Player.UpdateResult.none => {},
        }

        while (Time.getFrame() == frame) {
            std.time.sleep(@divFloor(Time.speed, 2));
        }

        frame = Time.getFrame();
    }
}
