const std = @import("std");
const rl = @import("raylib");

// ---------------------------------------------------------------------------
// Clone Game — a 2D puzzle-platformer. The player walks and falls; there is no
// jump. Height comes only from the clone mechanic: pressing Enter duplicates the
// cube being looked at, placing the copy flush in front of the player, or flush
// underneath (lifting the player onto it) when there's no room ahead. Only one
// clone exists at a time. Placement is free, not grid-aligned.
//
// ARCHITECTURE
// Pixels are authoritative: bodies live on whole-pixel coordinates, collision is
// exact integer AABB. The tile grid is an authoring convenience only (LevelDoc +
// editor); it's quantized away when a level becomes a World.
//
// Identity is stored, not inferred: every Entity carries a `kind` fixed at spawn.
// Physics flags (solid, dynamic, pushable, clonable, see_through) are DERIVED
// from kind via flagsFor; systems branch on the flags but kind is the truth, and
// serialization reads it directly.
//
// Layers:
//   LevelDoc — authored data: Pieces (kind + cell + gate params) + start cell.
//              Edited by the editor, serialized to assets/level.dat, no runtime state.
//   World    — runtime: EntityStore, player, clone, look target. Built by World.build.
//   Systems  — physics, interactives, look, clone, draw: iterate the entity list.
//
// All collision goes through one predicate (`overlaps`, strict-touch integer
// AABB) and one query helper (`querySolids`). Graphics come from one atlas.
// ---------------------------------------------------------------------------

// Cube/player size in px, matching the 16px atlas cells (1:1 draw).
const tile: f32 = 16;

// The game renders at a fixed virtual resolution, then integer-scales to the
// window (letterboxed) so pixels stay crisp. 256x192 is 4:3 and exactly 16x12 cells.
const virtual_w = 256;
const virtual_h = 192;

// Initial window size (3x); the window is resizable.
const window_w = virtual_w * 3;
const window_h = virtual_h * 3;

// Motion/look in tile units, so changing `tile` rescales the world without
// altering how it plays.
const gravity: f32 = 40.0 * tile; // tiles/s^2
const move_speed: f32 = 4.0 * tile; // tiles/s
const push_speed_mult: f32 = 0.6; // fraction of move_speed while shoving a cart
const max_fall: f32 = 40.0 * tile; // terminal velocity, tiles/s
const max_dt: f32 = 0.05; // clamp frame time so a hitch can't tunnel the player
const look_dist: f32 = 64.0 * tile; // clone reach

// Max pushable cubes a horizontal shove propagates through in one pixel-step
// before the push is refused. Bounds the push recursion; far above any real row.
const push_max_depth: u8 = 64;

// Horizontal overlap (px) a STATIC floor must share with a body to count as
// support (dynamic floors and all other checks stay strict). Lets a body drop
// into a same-width gap instead of snagging a one-pixel lip: with strict
// collision a 16px body over a 16px gap is unsupported at exactly one position,
// which it walks across before sub-pixel gravity drops it. Requiring a few px of
// support makes it leave the ground early enough to commit to the fall. Also
// sets the descend-window width (~2*support_min-1 px), which must exceed the
// per-frame step. Keep small so bodies don't fall off ledges they stand on.
const support_min: f32 = 2;

// Cap on dynamic bodies sorted per physics frame (fixed-size buffer). Extras
// keep their order.
const max_bodies = 256;

// ---------------------------------------------------------------------------
// Particle system tuning. Cosmetic only: a fixed array on the World (cleared
// free on level rebuild), never collide, drawn as one tinted pixel of the white
// atlas cell at whole-pixel positions.
// ---------------------------------------------------------------------------
const max_particles = 512; // fixed pool; full pool overwrites its oldest
const particle_gravity: f32 = 18.0 * tile; // tiles/s^2 (lighter than body gravity)

// The solid-white 16x16 atlas cell at (col 4, row 0). We sample a 1x1 sub-rect
// of it so a particle is one tinted pixel; the cell being solid white means the
// tint shows through unmodified.
const sprite_white: Sprite = .{ .col = 0, .row = 0 };

// A 1x1 source rectangle inside the white cell, in atlas pixels — one opaque
// white texel that `tint` colors.
fn whitePixelSrc() rl.Rectangle {
    return .{
        .x = @as(f32, @floatFromInt(sprite_white.col)) * atlas_cell + 1,
        .y = @as(f32, @floatFromInt(sprite_white.row)) * atlas_cell + 1,
        .width = 1,
        .height = 1,
    };
}

// Cosmetic particle. pos/vel are sub-pixel f32; only the draw position rounds to
// whole pixels. `life` counts down; `life0` is the start value, for alpha fade.
const Particle = struct {
    pos: rl.Vector2,
    vel: rl.Vector2,
    life: f32, // seconds remaining; <= 0 = dead
    life0: f32, // initial life, for fade
    size: f32, // square side in px
    tint: rl.Color,
    gravity: bool, // debris (true) vs floating sparks (false)
};

// Foreground dust: persistent slow motes in screen space, drawn over everything,
// wrapping the screen edges. Independent of the world camera.
const max_dust = 12;
const dust_drift_x: f32 = 0.4 * tile; // tiles/s
const dust_drift_y: f32 = 0.25 * tile; // tiles/s

// One dust mote. Position is in virtual-resolution (screen) pixels, wrapping.
const Dust = struct {
    pos: rl.Vector2,
    vel: rl.Vector2,
    size: f32,
    phase: f32, // twinkle phase offset
    color: rl.Color, // sampled from the background texture at seed time
};

// CRT post-process uniform defaults (mild: subtle curvature, light bloom, gentle
// vignette).
const crt_curvature: f32 = 0.06;
const crt_vignette_width: f32 = 0.55;
const crt_vignette_fade: f32 = 0.5;
const crt_chrom_ab: f32 = 1.0;
const crt_mask_intensity: f32 = 0.25;
const crt_corner_shape: f32 = 8.0;
const crt_edge_width: f32 = 0.02;
const crt_edge_fade: f32 = 0.02;
const crt_glow_intensity: f32 = 0.05;
const crt_glow_radius: f32 = 1.5;

// Player death sequence (physics + input paused throughout): HOLD freezes the
// world with the camera on the death spot; COVER fills the screen with a
// pixelated wipe and teleports the player to the start cell at full cover;
// REVEAL clears the wipe on the respawn.
const DeathPhase = enum { none, hold, cover, reveal };
const death_hold_time: f32 = 0.5;
const death_cover_time: f32 = 0.25;
const death_reveal_time: f32 = 0.25;
const death_wipe_cell: f32 = 4; // wipe square size in virtual px (bigger = chunkier)

// Atlas: a 128x128 PNG of 16x16 cells, embedded at compile time. (atlas_cell
// happens to equal `tile` but is a distinct concept.)
const atlas_png = @embedFile("assets/atlas.png");
const atlas_cell: f32 = 16; // px per atlas cell

// CRT post-process shaders (assets/crt.vs, crt.fs). Applied full-screen at the
// present blit, at WINDOW resolution so the mask/curvature/bloom resolve at
// output scale, not the 256x192 virtual size.
const crt_vs = @embedFile("assets/crt.vs");
const crt_fs = @embedFile("assets/crt.fs");

const Sprite = struct {
    col: u16,
    row: u16,
    span_w: u16 = 1,
    span_h: u16 = 1,

    // Source rectangle within the atlas, in atlas pixels.
    fn src(self: Sprite) rl.Rectangle {
        return .{
            .x = @as(f32, @floatFromInt(self.col)) * atlas_cell,
            .y = @as(f32, @floatFromInt(self.row)) * atlas_cell,
            .width = @as(f32, @floatFromInt(self.span_w)) * atlas_cell,
            .height = @as(f32, @floatFromInt(self.span_h)) * atlas_cell,
        };
    }
};

// Named sprite cells (col, row). Player walk is row 1, (0,1)..(3,1); the first
// frame doubles as the idle pose.
const player_walk_frames = [_]Sprite{
    .{ .col = 0, .row = 1 },
    .{ .col = 1, .row = 1 },
    .{ .col = 2, .row = 1 },
    .{ .col = 3, .row = 1 },
};
// Brick (formerly "block"): a 16-tile nine-slice at cols 0-3, rows 4-7,
// auto-selected by neighbours. The default below is the fully-isolated tile
// (all four edges exposed); instantiate overrides it per placement.
const sprite_brick: Sprite = .{ .col = 3, .row = 4 }; // brick_tblr
const sprite_cart: Sprite = .{ .col = 0, .row = 2 }; // (formerly "box"); idle = first frame
// Cart roll animation: 3 frames (0,2)..(2,2). Advances only while the cart is
// moving (it's only ever pushed); when it stops it holds the frame it's on.
const cart_anim_frames = [_]Sprite{
    .{ .col = 0, .row = 2 },
    .{ .col = 1, .row = 2 },
    .{ .col = 2, .row = 2 },
};
const cart_anim_frame_time: f32 = 0.08; // s/frame while rolling
const sprite_window: Sprite = .{ .col = 7, .row = 2 }; // solid, but the clone ray sees through it
const sprite_background: Sprite = .{ .col = 1, .row = 0 };
const sprite_flower: Sprite = .{ .col = 5, .row = 2 }; // decorative, walk-through, cloneable
const sprite_spike: Sprite = .{ .col = 6, .row = 2 }; // lethal, walk-through, cloneable; rotation is visual-only

// Player push animation: two frames at (6,1)-(7,1), played while shoving a cart.
const player_push_frames = [_]Sprite{
    .{ .col = 6, .row = 1 },
    .{ .col = 7, .row = 1 },
};
const push_frame_time: f32 = 0.22; // s/frame while pushing

// Book (formerly "checkpoint"): deactivated/idle sprite at (0,3); walking onto
// it makes it the respawn point. Activating plays the 5-frame "opening"
// animation (0,3)..(4,3) once, then rests on its last frame (4,3) to read as
// "active". The book also has a 4-frame "flick" idle at (4,3)..(7,3), wired up
// separately later.
const sprite_checkpoint: Sprite = .{ .col = 0, .row = 3 };
const checkpoint_anim_frames = [_]Sprite{
    .{ .col = 0, .row = 3 },
    .{ .col = 1, .row = 3 },
    .{ .col = 2, .row = 3 },
    .{ .col = 3, .row = 3 },
    .{ .col = 4, .row = 3 },
};
const checkpoint_anim_frame_time: f32 = 0.07; // s/frame for the activation flourish

// Button: unpressed/pressed. Pressed while a body rests on it.
const sprite_button_up: Sprite = .{ .col = 3, .row = 2 };
const sprite_button_down: Sprite = .{ .col = 4, .row = 2 };

// Gate cell sprites, named by which EDGES the cell exposes to the outside of its
// gate rectangle (T/B/L/R). Covers all 16 combinations so any gate size tiles
// correctly. Occupies the 4x4 block at cols 4-7, rows 4-7.
const gate_none: Sprite = .{ .col = 5, .row = 5 };
const gate_t: Sprite = .{ .col = 5, .row = 4 };
const gate_b: Sprite = .{ .col = 5, .row = 6 };
const gate_l: Sprite = .{ .col = 4, .row = 5 };
const gate_r: Sprite = .{ .col = 6, .row = 5 };
const gate_tl: Sprite = .{ .col = 4, .row = 4 };
const gate_tr: Sprite = .{ .col = 6, .row = 4 };
const gate_bl: Sprite = .{ .col = 4, .row = 6 };
const gate_br: Sprite = .{ .col = 6, .row = 6 };
const gate_tb: Sprite = .{ .col = 5, .row = 7 };
const gate_lr: Sprite = .{ .col = 7, .row = 6 };
const gate_tlr: Sprite = .{ .col = 7, .row = 5 };
const gate_blr: Sprite = .{ .col = 7, .row = 7 };
const gate_tbl: Sprite = .{ .col = 4, .row = 7 };
const gate_tbr: Sprite = .{ .col = 6, .row = 7 };
// All four edges. Also a 1x1 gate (exposes every side); an open gate slides this
// off and clips, so no separate "open" sprite is needed.
const gate_tblr: Sprite = .{ .col = 7, .row = 4 };
const sprite_gate_single: Sprite = gate_tblr;

// Direction a gate retracts when it opens.
const GateDir = enum { up, down, left, right };

// const gate_open_time: f32 = 0.15; // open/close slide duration
const gate_open_time: f32 = 0.25; // open/close slide duration
const gate_stick_out: f32 = 4; // px left visible at the frame edge when fully open

const walk_frame_time: f32 = 0.12; // s/frame while moving
const cast_frame_time: f32 = 0.3; // s/frame while casting

// Cast animation (briefly on clone): two cells (4,1)-(5,1), once, cancelled by
// movement.
const player_cast_frames = [_]Sprite{
    .{ .col = 4, .row = 1 },
    .{ .col = 5, .row = 1 },
};

// Clone spawn mask: a 4-frame black/white mask (row 0, cols 2-5) multiplied into
// the clone's alpha by a shader — white keeps, black hides. Scales to any sprite.
const clone_mask_frames = [_]Sprite{
    .{ .col = 2, .row = 0 },
    .{ .col = 3, .row = 0 },
    .{ .col = 4, .row = 0 },
    .{ .col = 5, .row = 0 },
};
const clone_mask_frame_time: f32 = 0.06; // materialize
const clone_vanish_frame_time: f32 = 0.035; // dematerialize (faster)

// Clone spawn-mask shader: samples the atlas for both sprite and mask cell;
// mask luminance multiplies sprite alpha. Uniforms sprite_rect/mask_rect are
// (x,y,w,h) in normalized UVs.
const clone_mask_fs = @embedFile("assets/clone_mask.fs");

// Materialized-clone shader: semi-transparent sprite with a moving diagonal
// shine band (the "ghostly" look). `time` animates it, `tint_alpha` sets
// transparency; recovers per-sprite local UVs from sprite_rect like the mask.
const clone_ripple_fs = @embedFile("assets/clone_ripple.fs");

// ===========================================================================
// Identity: Kind, and the flags derived from it. Kind is the single source of
// truth for what a cube IS — stored per Entity at spawn, read by serialization.
// Flags are a derived view (flagsFor); systems branch on flags, never on kind.
// To add a type: add a Kind + a flagsFor/spriteFor row + (if authorable) a
// Palette entry.
//
// Numeric values are on-disk tags and MUST stay stable. gate_single (cloneable
// 1x1) and gate_multi (larger, not cloneable) are distinct kinds sharing gate
// behavior; editor/loader pick by size.
// ===========================================================================
const Kind = enum(u8) {
    brick = 0,
    cart = 1,
    window = 2,
    button = 3,
    gate_single = 4,
    flower = 5,
    gate_multi = 6,
    spike = 7,
    book = 8,

    pub fn isGate(self: Kind) bool {
        return self == .gate_single or self == .gate_multi;
    }
};

// Physics capabilities for a kind, copied onto the Entity at spawn so hot paths
// read a field:
//   solid:       collides; bodies rest against it.
//   dynamic:     affected by gravity.
//   pushable:    slides when shoved horizontally.
//   clonable:    can be targeted and duplicated.
//   see_through: solid for movement, but the clone ray passes through it.
const Flags = struct {
    solid: bool,
    dynamic: bool,
    pushable: bool,
    clonable: bool,
    see_through: bool,
};

// The one place each kind's capabilities are defined. Gate solidity here is the
// CLOSED state; the interactive system toggles Entity.solid as a gate opens.
fn flagsFor(kind: Kind) Flags {
    return switch (kind) {
        .brick => .{ .solid = true, .dynamic = false, .pushable = false, .clonable = true, .see_through = false },
        .cart => .{ .solid = true, .dynamic = true, .pushable = true, .clonable = true, .see_through = false },
        .window => .{ .solid = true, .dynamic = false, .pushable = false, .clonable = false, .see_through = true },
        .button => .{ .solid = false, .dynamic = false, .pushable = false, .clonable = true, .see_through = false },
        .flower => .{ .solid = false, .dynamic = false, .pushable = false, .clonable = true, .see_through = false },
        .spike => .{ .solid = false, .dynamic = false, .pushable = false, .clonable = true, .see_through = false },
        .book => .{ .solid = false, .dynamic = false, .pushable = false, .clonable = true, .see_through = false },
        .gate_single => .{ .solid = true, .dynamic = false, .pushable = false, .clonable = true, .see_through = false },
        .gate_multi => .{ .solid = true, .dynamic = false, .pushable = false, .clonable = false, .see_through = false },
    };
}

// Default sprite for a kind. Buttons (by pressed-state) and multi-cell gates (by
// exposed edges) override this at draw time.
fn spriteFor(kind: Kind) Sprite {
    return switch (kind) {
        .brick => sprite_brick,
        .cart => sprite_cart,
        .window => sprite_window,
        .button => sprite_button_up,
        .flower => sprite_flower,
        .spike => sprite_spike,
        .book => sprite_checkpoint,
        .gate_single, .gate_multi => sprite_gate_single,
    };
}

// Interactive role, derived from kind. Plain cubes are .none.
const Role = enum { none, button, gate };
fn roleFor(kind: Kind) Role {
    return switch (kind) {
        .button => .button,
        .gate_single, .gate_multi => .gate,
        else => .none,
    };
}

const MaskPhase = enum { none, spawning, vanishing };

// A cube in the world. `kind` is identity; the flag fields are a derived
// snapshot of flagsFor(kind), filled at spawn — don't set them directly. The
// only flags mutated after spawn are `solid` (gate open/close, clone vanish).
const Entity = struct {
    kind: Kind,
    rect: rl.Rectangle,
    // Zero value = "unset"; applyKind fills the kind's default sprite. A caller
    // needing per-cell art (multi-cell gate edge tile) sets it, and it's kept.
    sprite: Sprite = .{ .col = 0, .row = 0 },
    tint: rl.Color = .white,
    vel: rl.Vector2 = .{ .x = 0, .y = 0 },
    // Sub-pixel accumulator: rect.x/y stay whole-pixel; fractional vel*dt banks
    // here until it sums to a pixel. Integer positions keep collision exact and
    // sprites from shimmering.
    rem: rl.Vector2 = .{ .x = 0, .y = 0 },
    on_ground: bool = false,
    is_clone: bool = false,
    // Spawn position; boxes snap back here on room change. Set by spawn().
    spawn_pos: rl.Vector2 = .{ .x = 0, .y = 0 },

    // Derived from kind at spawn (flagsFor).
    solid: bool = true,
    dynamic: bool = false,
    pushable: bool = false,
    clonable: bool = true,
    see_through: bool = false,
    role: Role = .none, // derived from kind at spawn (roleFor)

    pressed: bool = false, // button: weight resting on it
    // Cart roll animation: advances while the cart moves, holds frame when it
    // stops. `cart_rolled` is set per-frame by physics when the cart's x changed.
    cart_frame: usize = 0,
    cart_anim_time: f32 = 0,
    cart_rolled: bool = false,
    cart_roll_dir: f32 = 1, // sign of last x-change: +1 rolled right, -1 left
    // Gate openness: 0 = closed (solid), 1 = open (passable). Lerps toward
    // target; the closed sprite slides off in `dir`.
    open_amount: f32 = 0,
    // open_amount from the previous update, so eviction can detect a CLOSING gate
    // (shrinking) vs opening/settled. Only closing gates eject bodies.
    prev_open_amount: f32 = 0,
    // General-purpose 4-way direction, meaning depends on kind: a gate's open
    // direction, a spike's visual rotation, a checkpoint's facing (left/right).
    dir: GateDir = .up,
    // Bounding rect of the whole gate (this cell's own rect for a 1x1). Lets a
    // multi-cell gate slide as one unit and clip at the shared frame edge.
    gate_rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    // Spawn/vanish mask: `spawning` plays forward, `vanishing` plays in reverse
    // then self-removes. mask_frame indexes clone_mask_frames.
    mask_phase: MaskPhase = .none,
    mask_frame: usize = 0,
    mask_time: f32 = 0,

    // Checkpoint state. `cp_active` marks the checkpoint the player will respawn
    // at (only one is active at a time; it rests on the last anim frame).
    // `cp_anim_playing` runs the one-shot activation/deactivation flourish;
    // `cp_anim_reverse` plays it backwards (last→first) for deactivation.
    // `cp_origin` is the cell of the original a clone was made from (null on an
    // original); it pairs a clone with its original even though spawn_pos is
    // overwritten at spawn. See checkpointOrigin / checkpointTwins.
    cp_active: bool = false,
    cp_anim_playing: bool = false,
    cp_anim_reverse: bool = false,
    cp_anim_frame: usize = 0,
    cp_origin: ?[2]i32 = null,
    cp_anim_time: f32 = 0,
};

// Stable entity reference. `gen` disambiguates slot reuse: on free, the slot's
// gen is bumped, so a stale handle resolves to null instead of a different cube.
const Handle = struct { index: u32, gen: u32 };

// A storage slot, reused after removal; `gen` bumped on removal to stale old handles.
const Slot = struct {
    entity: Entity,
    gen: u32 = 0,
    alive: bool = false,
};

// Slot-map entity store. Slots never move, so handles stay valid across frames
// and removals. Simple (linear scans); the handle API hides that for later opt.
const EntityStore = struct {
    slots: std.ArrayList(Slot) = .empty,
    free: std.ArrayList(u32) = .empty, // dead slot indices, ready to reuse

    fn deinit(self: *EntityStore, gpa: std.mem.Allocator) void {
        self.slots.deinit(gpa);
        self.free.deinit(gpa);
    }

    // Spawn an entity. Caller supplies kind/rect/per-instance state; this derives
    // sprite/flags/role from the kind (via applyKind) so they can't drift, and
    // records spawn_pos.
    fn spawn(self: *EntityStore, gpa: std.mem.Allocator, e: Entity) !Handle {
        var ent = e;
        applyKind(&ent);
        ent.spawn_pos = .{ .x = ent.rect.x, .y = ent.rect.y };
        if (self.free.pop()) |idx| {
            const s = &self.slots.items[idx];
            s.entity = ent;
            s.alive = true;
            return .{ .index = idx, .gen = s.gen };
        }
        const idx: u32 = @intCast(self.slots.items.len);
        try self.slots.append(gpa, .{ .entity = ent, .gen = 0, .alive = true });
        return .{ .index = idx, .gen = 0 };
    }

    fn remove(self: *EntityStore, gpa: std.mem.Allocator, h: Handle) void {
        if (!self.valid(h)) return;
        const s = &self.slots.items[h.index];
        s.alive = false;
        s.gen +%= 1; // stale old handles
        self.free.append(gpa, h.index) catch {}; // on OOM the slot just isn't reused
    }

    fn valid(self: *const EntityStore, h: Handle) bool {
        return h.index < self.slots.items.len and
            self.slots.items[h.index].alive and
            self.slots.items[h.index].gen == h.gen;
    }

    // Resolve a handle to a live entity, or null if stale. Pointers are valid
    // only until the next spawn (which may grow the array) — hold handles, not pointers.
    fn get(self: *EntityStore, h: Handle) ?*Entity {
        if (!self.valid(h)) return null;
        return &self.slots.items[h.index].entity;
    }

    fn handleAt(self: *const EntityStore, index: u32) Handle {
        std.debug.assert(self.slots.items[index].alive);
        return .{ .index = index, .gen = self.slots.items[index].gen };
    }
};

// Fill an entity's derived fields (sprite, flags, role) from its kind — the one
// chokepoint tying behavior to identity. A caller-supplied non-default sprite
// (per-cell gate art) is kept; otherwise the kind's default is applied.
fn applyKind(e: *Entity) void {
    const f = flagsFor(e.kind);
    e.solid = f.solid;
    e.dynamic = f.dynamic;
    e.pushable = f.pushable;
    e.clonable = f.clonable;
    e.see_through = f.see_through;
    e.role = roleFor(e.kind);
    // Zero-value Sprite = "unset"; apply the default. (col==0,row==0 is a player
    // frame, never a cube default.)
    if (e.sprite.col == 0 and e.sprite.row == 0 and e.sprite.span_w == 1 and e.sprite.span_h == 1) {
        e.sprite = spriteFor(e.kind);
    }
}

// Gate cell sprite for cell (i,j) in a w x h gate, by which edges face the
// rectangle's outside (top row exposes top, etc.). Covers any size/shape.
fn gateSliceSprite(i: i32, j: i32, w: i32, h: i32) Sprite {
    const top = j == 0;
    const bottom = j == h - 1;
    const left = i == 0;
    const right = i == w - 1;
    // Pack the four edges into a 4-bit set and switch on it: T=8 B=4 L=2 R=1.
    const edges: u4 = (@as(u4, @intFromBool(top)) << 3) |
        (@as(u4, @intFromBool(bottom)) << 2) |
        (@as(u4, @intFromBool(left)) << 1) |
        @as(u4, @intFromBool(right));
    return switch (edges) {
        0b0000 => gate_none,
        0b1000 => gate_t,
        0b0100 => gate_b,
        0b0010 => gate_l,
        0b0001 => gate_r,
        0b1010 => gate_tl,
        0b1001 => gate_tr,
        0b0110 => gate_bl,
        0b0101 => gate_br,
        0b1100 => gate_tb,
        0b0011 => gate_lr,
        0b1011 => gate_tlr,
        0b0111 => gate_blr,
        0b1110 => gate_tbl,
        0b1101 => gate_tbr,
        0b1111 => gate_tblr,
    };
}

// World-space rectangle for a grid cell.
fn cellRect(gx: i32, gy: i32) rl.Rectangle {
    return .{
        .x = @as(f32, @floatFromInt(gx)) * tile,
        .y = @as(f32, @floatFromInt(gy)) * tile,
        .width = tile,
        .height = tile,
    };
}

// ===========================================================================
// LevelDoc — authored level data: a list of Pieces + the player start cell, no
// runtime state. The editor mutates it; saving serializes it; building a World
// instantiates entities from it. Since the doc is never discarded, "save" =
// write the doc and "reset level" = rebuild the World from it.
// ===========================================================================

// One authored placement. Non-gate kinds use w=h=1, dir ignored. A gate carries
// its full w x h and open direction; w==h==1 is a cloneable single-cell gate.
const Piece = struct {
    kind: Kind,
    gx: i32,
    gy: i32,
    w: i32 = 1,
    h: i32 = 1,
    dir: GateDir = .up,
};

const default_start_gx: i32 = 1;
const default_start_gy: i32 = 11;

const LevelDoc = struct {
    pieces: std.ArrayList(Piece) = .empty,
    start_cell: [2]i32 = .{ default_start_gx, default_start_gy },

    pub fn deinit(self: *LevelDoc, gpa: std.mem.Allocator) void {
        self.pieces.deinit(gpa);
    }

    pub fn add(self: *LevelDoc, gpa: std.mem.Allocator, p: Piece) !void {
        try self.pieces.append(gpa, p);
    }

    // Deep-copy into a new owned LevelDoc (pieces duplicated). Used to snapshot
    // the doc for single-step undo.
    pub fn clone(self: *const LevelDoc, gpa: std.mem.Allocator) !LevelDoc {
        var pieces: std.ArrayList(Piece) = .empty;
        errdefer pieces.deinit(gpa);
        try pieces.appendSlice(gpa, self.pieces.items);
        return .{ .pieces = pieces, .start_cell = self.start_cell };
    }

    // Remove every piece overlapping the grid rect [gx,gx+w) x [gy,gy+h). Used by
    // the editor to clear before placing and to erase. Any overlap with a gate
    // removes the whole gate.
    pub fn clearRect(self: *LevelDoc, gx: i32, gy: i32, w: i32, h: i32) void {
        const ax0 = gx;
        const ay0 = gy;
        const ax1 = gx + w;
        const ay1 = gy + h;
        var i: usize = 0;
        while (i < self.pieces.items.len) {
            const p = self.pieces.items[i];
            const px1 = p.gx + p.w;
            const py1 = p.gy + p.h;
            const hit = p.gx < ax1 and ax0 < px1 and p.gy < ay1 and ay0 < py1;
            if (hit) {
                _ = self.pieces.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// World — runtime state built from a LevelDoc: the EntityStore, the player, and
// transient bookkeeping. World.build(doc) produces one; rebuilding from the same
// doc resets boxes/gates/clones (level-reset and edit→play).
// ---------------------------------------------------------------------------
const World = struct {
    entities: EntityStore = .{},
    player: Player,
    clone: ?Handle = null, // current clone, or null; cloning again replaces it
    look_target: ?Handle = null, // cube the player is looking at, or null
    // Room (screen-cell) origin the player was in last frame. On change, boxes
    // reset. Sentinel forces a (harmless) mismatch on frame 1.
    current_room: rl.Vector2 = .{ .x = std.math.floatMax(f32), .y = std.math.floatMax(f32) },

    // Cosmetic particle pool. Inline + fixed-size: no allocation, cleared free on
    // World rebuild. [0, particle_count) live; a full pool overwrites oldest via
    // the cursor. Not in the EntityStore — particles never collide.
    particles: [max_particles]Particle = undefined,
    particle_count: usize = 0,
    particle_cursor: usize = 0,
    rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15),

    // Foreground dust, lazily seeded on first update.
    dust: [max_dust]Dust = undefined,
    dust_seeded: bool = false,

    // Death sequence state (see DeathPhase). While active, physics/input pause,
    // the camera locks to death_cam, and death_timer drives the wipe.
    death_phase: DeathPhase = .none,
    death_timer: f32 = 0,
    death_cam: rl.Vector2 = .{ .x = 0, .y = 0 },

    // Active checkpoint cell, or null to fall back to the level's start cell.
    // Set when the player walks onto a checkpoint; respawn reads it.
    respawn_cell: ?[2]i32 = null,

    fn deinit(self: *World, gpa: std.mem.Allocator) void {
        self.entities.deinit(gpa);
    }

    // Build a fresh World from a doc: spawn entities per piece, place the player
    // at the start cell.
    fn build(gpa: std.mem.Allocator, doc: *const LevelDoc) !World {
        var w = World{ .player = .{ .rect = cellRect(doc.start_cell[0], doc.start_cell[1]) } };
        errdefer w.entities.deinit(gpa);
        for (doc.pieces.items) |p| {
            try instantiatePiece(&w, gpa, doc, p);
        }
        return w;
    }
};

// True if the doc has a brick piece occupying cell (gx,gy). Used for brick
// auto-tiling: a brick exposes an edge wherever it has no brick neighbour.
fn brickAt(doc: *const LevelDoc, gx: i32, gy: i32) bool {
    for (doc.pieces.items) |p| {
        if (p.kind == .brick and p.gx == gx and p.gy == gy) return true;
    }
    return false;
}

// Pick the nine-slice brick tile for cell (gx,gy): an edge is EXPOSED when no
// brick neighbour sits on that side. Mirrors gateSliceSprite's edge packing
// (T=8 B=4 L=2 R=1) but over neighbour presence instead of rectangle bounds.
fn brickSliceSprite(doc: *const LevelDoc, gx: i32, gy: i32) Sprite {
    const top = !brickAt(doc, gx, gy - 1);
    const bottom = !brickAt(doc, gx, gy + 1);
    const left = !brickAt(doc, gx - 1, gy);
    const right = !brickAt(doc, gx + 1, gy);
    const edges: u4 = (@as(u4, @intFromBool(top)) << 3) |
        (@as(u4, @intFromBool(bottom)) << 2) |
        (@as(u4, @intFromBool(left)) << 1) |
        @as(u4, @intFromBool(right));
    return switch (edges) {
        0b0000 => .{ .col = 1, .row = 5 }, // brick_none
        0b1000 => .{ .col = 1, .row = 4 }, // brick_t
        0b0100 => .{ .col = 1, .row = 6 }, // brick_b
        0b0010 => .{ .col = 0, .row = 5 }, // brick_l
        0b0001 => .{ .col = 2, .row = 5 }, // brick_r
        0b1010 => .{ .col = 0, .row = 4 }, // brick_tl
        0b1001 => .{ .col = 2, .row = 4 }, // brick_tr
        0b0110 => .{ .col = 0, .row = 6 }, // brick_bl
        0b0101 => .{ .col = 2, .row = 6 }, // brick_br
        0b1100 => .{ .col = 1, .row = 7 }, // brick_tb
        0b0011 => .{ .col = 3, .row = 6 }, // brick_lr
        0b1011 => .{ .col = 3, .row = 5 }, // brick_tlr
        0b0111 => .{ .col = 3, .row = 7 }, // brick_blr
        0b1110 => .{ .col = 0, .row = 7 }, // brick_tbl
        0b1101 => .{ .col = 2, .row = 7 }, // brick_tbr
        0b1111 => .{ .col = 3, .row = 4 }, // brick_tblr
    };
}

// Turn one Piece into live entities — the ONLY place a Piece becomes runtime
// state. A multi-cell gate spawns one entity per cell with edge-correct art and
// a shared gate_rect (so it slides as one unit). Bricks auto-tile against their
// brick neighbours in the doc.
fn instantiatePiece(world: *World, gpa: std.mem.Allocator, doc: *const LevelDoc, p: Piece) !void {
    switch (p.kind) {
        .brick => {
            _ = try world.entities.spawn(gpa, .{
                .kind = .brick,
                .rect = cellRect(p.gx, p.gy),
                .sprite = brickSliceSprite(doc, p.gx, p.gy),
            });
        },
        .cart, .window, .button, .flower => {
            _ = try world.entities.spawn(gpa, .{ .kind = p.kind, .rect = cellRect(p.gx, p.gy) });
        },
        .book => {
            // Checkpoints carry a facing in `dir` (left/right); right flips art.
            _ = try world.entities.spawn(gpa, .{
                .kind = .book,
                .rect = cellRect(p.gx, p.gy),
                .dir = p.dir,
            });
        },
        .spike => {
            // Spikes reuse `dir` purely as a visual rotation (see drawEntity).
            _ = try world.entities.spawn(gpa, .{
                .kind = .spike,
                .rect = cellRect(p.gx, p.gy),
                .dir = p.dir,
            });
        },
        .gate_single => {
            const r = cellRect(p.gx, p.gy);
            _ = try world.entities.spawn(gpa, .{
                .kind = .gate_single,
                .rect = r,
                .dir = p.dir,
                .gate_rect = r,
            });
        },
        .gate_multi => {
            // Guard a degenerate 1x1 "multi" gate (editor/loader never emit one).
            if (p.w <= 1 and p.h <= 1) {
                const r = cellRect(p.gx, p.gy);
                _ = try world.entities.spawn(gpa, .{
                    .kind = .gate_single,
                    .rect = r,
                    .dir = p.dir,
                    .gate_rect = r,
                });
                return;
            }
            // Whole-gate bounding rect, shared by every cell.
            const frame = rl.Rectangle{
                .x = @as(f32, @floatFromInt(p.gx)) * tile,
                .y = @as(f32, @floatFromInt(p.gy)) * tile,
                .width = @as(f32, @floatFromInt(p.w)) * tile,
                .height = @as(f32, @floatFromInt(p.h)) * tile,
            };
            var j: i32 = 0;
            while (j < p.h) : (j += 1) {
                var i: i32 = 0;
                while (i < p.w) : (i += 1) {
                    _ = try world.entities.spawn(gpa, .{
                        .kind = .gate_multi,
                        .rect = cellRect(p.gx + i, p.gy + j),
                        .sprite = gateSliceSprite(i, j, p.w, p.h),
                        .dir = p.dir,
                        .gate_rect = frame,
                    });
                }
            }
        },
    }
}

// The gate Kind for a placed rectangle: 1x1 → cloneable single, larger → multi.
fn gateKindForSize(w: i32, h: i32) Kind {
    return if (w <= 1 and h <= 1) .gate_single else .gate_multi;
}

const Player = struct {
    rect: rl.Rectangle,
    vel: rl.Vector2 = .{ .x = 0, .y = 0 },
    rem: rl.Vector2 = .{ .x = 0, .y = 0 }, // sub-pixel accumulator; see Entity.rem
    on_ground: bool = false,
    facing: f32 = 1.0, // -1 left, +1 right
    // Move key held this frame. Tracks intent, not velocity, so the walk anim
    // keeps playing even when vel.x is zeroed by pushing into something.
    moving: bool = false,
    anim_frame: usize = 0,
    anim_time: f32 = 0,
    // Cast animation (on clone): overrides walk frames; cancelled by movement.
    casting: bool = false,
    cast_frame: usize = 0,
    cast_time: f32 = 0,
    // Set by stepX each frame the player successfully shoves a pushable cart;
    // reset at the top of applyPhysics. Drives the push animation.
    pushing: bool = false,
    push_frame: usize = 0,
    push_time: f32 = 0,
};

// Editor placement vocabulary, cycled with number keys / scroll. Maps to Kind
// via paletteKind; `gate` resolves to single/multi by size; start/eraser aren't kinds.
const Palette = enum { brick, cart, window, button, gate, flower, start, eraser, spike, book, select };

fn paletteKind(p: Palette) ?Kind {
    return switch (p) {
        .brick => .brick,
        .cart => .cart,
        .window => .window,
        .button => .button,
        .flower => .flower,
        .spike => .spike,
        .book => .book,
        .gate => .gate_single, // placeholder; real kind chosen by size at placement
        .start, .eraser, .select => null,
    };
}

const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io, // 0.16 I/O backend for filesystem ops; from init.io
    atlas: rl.Texture2D,
    // CPU copy of the atlas, for sampling sprite colors at runtime (particle
    // tints). Set in main(); the test harness leaves it undefined.
    atlas_img: rl.Image = undefined,
    // Clone spawn-mask shader + cached uniform locations.
    mask_shader: rl.Shader,
    loc_sprite_rect: i32,
    loc_mask_rect: i32,
    // Clone ripple shader (materialized clones: transparent + shine).
    ripple_shader: rl.Shader = .{ .id = 0, .locs = null },
    loc_ripple_sprite_rect: i32 = 0,
    loc_ripple_time: i32 = 0,
    loc_ripple_alpha: i32 = 0,
    loc_ripple_mask_rect: i32 = 0,
    loc_ripple_use_mask: i32 = 0,
    // CRT post-process shader + uniform location.
    crt_shader: rl.Shader = .{ .id = 0, .locs = null },
    loc_crt_resolution: i32 = 0,

    // Authored doc (layout truth) and the runtime World built from it. Editor
    // mutates doc; entering play rebuilds world; saving serializes doc.
    doc: LevelDoc = .{},
    world: World,

    // Edit mode: physics/clone paused, mouse places/removes pieces. `palette` is
    // the next placement type.
    edit_mode: bool = false,
    palette: Palette = .brick,
    drag_start: ?[2]i32 = null, // rect-drag start cell, or null
    edit_gate_dir: GateDir = .up, // next placed gate's open dir (cycled with R)
    // Last cell a single-cell paint hit, so drag-painting doesn't re-add a cell
    // every frame. Null when not painting.
    last_paint_cell: ?[2]i32 = null,

    // Selection rectangle in grid cells [x, y, w, h], set in `.select` mode by
    // dragging; null when nothing is selected. Drives copy/cut and is drawn as a
    // cyan box.
    selection: ?[4]i32 = null,
    // Clipboard: pieces from the last copy/cut, with gx/gy stored RELATIVE to the
    // copied region's top-left (so paste can stamp them at any anchor cell).
    // clip_w/clip_h are the copied region's size, for the paste preview.
    clipboard: std.ArrayList(Piece) = .empty,
    clip_w: i32 = 0,
    clip_h: i32 = 0,

    // Single-step undo: a snapshot of the doc taken just before the current edit
    // gesture began, or null if there's nothing to undo. Ctrl+Z restores it.
    undo_doc: ?LevelDoc = null,

    fn entities(self: *State) *EntityStore {
        return &self.world.entities;
    }
    fn player(self: *State) *Player {
        return &self.world.player;
    }
};

// ---------------------------------------------------------------------------
// Level serialization. A LevelDoc is saved as a compact little-endian blob
// (assets/level.dat), @embedFile'd by a shipped build (falling back to a
// hardcoded default doc if absent/invalid). Workflow: edit in-game, F5 to write
// level.dat next to the exe, copy into assets/, recompile.
//
// File layout (little-endian):
//   v1 header: magic "CLVL", version u8, reserved u8, count u16          (8 bytes)
//   v2 header: v1 header + start_gx i16, start_gy i16                    (12 bytes)
//   record (8 bytes): kind u8, gx i16, gy i16, w u8, h u8, dir u8
// Non-gate records use w/h=1, dir=0; v1 files load with the default start cell.
//
// Disk kind tags equal the Kind values, EXCEPT both gate kinds store as tag 4
// (gate_single's value), distinguished by w/h — the format predates the split.
// ---------------------------------------------------------------------------

const level_magic = [4]u8{ 'C', 'L', 'V', 'L' };
const level_version: u8 = 2;
const level_path = "level.dat"; // written next to the executable

const gate_disk_tag: u8 = @intFromEnum(Kind.gate_single); // both gate kinds → 4 on disk

fn gateDirByte(d: GateDir) u8 {
    return switch (d) {
        .up => 0,
        .down => 1,
        .left => 2,
        .right => 3,
    };
}

fn gateDirFromByte(b: u8) GateDir {
    return switch (b) {
        1 => .down,
        2 => .left,
        3 => .right,
        else => .up,
    };
}

// Serialize a LevelDoc to a caller-owned, gpa-allocated buffer. Gates emit the
// disk gate tag + full rectangle.
fn serializeDoc(doc: *const LevelDoc, gpa: std.mem.Allocator) ![]u8 {
    const count: u16 = @intCast(doc.pieces.items.len);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &level_magic);
    try out.append(gpa, level_version);
    try out.append(gpa, 0); // reserved
    try out.appendSlice(gpa, &std.mem.toBytes(count));
    try out.appendSlice(gpa, &std.mem.toBytes(@as(i16, @intCast(doc.start_cell[0]))));
    try out.appendSlice(gpa, &std.mem.toBytes(@as(i16, @intCast(doc.start_cell[1]))));
    for (doc.pieces.items) |p| {
        const tag: u8 = if (p.kind.isGate()) gate_disk_tag else @intFromEnum(p.kind);
        const w: u8 = if (p.kind.isGate()) @intCast(p.w) else 1;
        const h: u8 = if (p.kind.isGate()) @intCast(p.h) else 1;
        // Gates store their open dir; spikes store their visual rotation in the
        // same byte; everything else writes 0.
        const dir: u8 = if (p.kind.isGate() or p.kind == .spike or p.kind == .book) gateDirByte(p.dir) else 0;
        try writeRecord(&out, gpa, tag, p.gx, p.gy, w, h, dir);
    }
    return out.toOwnedSlice(gpa);
}

// Append one 8-byte little-endian record, field by field so the format is
// independent of struct packing/endianness.
fn writeRecord(out: *std.ArrayList(u8), gpa: std.mem.Allocator, kind: u8, gx: i32, gy: i32, w: u8, h: u8, dir: u8) !void {
    try out.append(gpa, kind);
    try out.appendSlice(gpa, &std.mem.toBytes(@as(i16, @intCast(gx))));
    try out.appendSlice(gpa, &std.mem.toBytes(@as(i16, @intCast(gy))));
    try out.append(gpa, w);
    try out.append(gpa, h);
    try out.append(gpa, dir);
}

// Write the doc to level_path next to the exe. Errors returned (caller logs); a
// failed save mustn't crash the editor.
fn saveLevel(state: *State) !void {
    const bytes = try serializeDoc(&state.doc, state.gpa);
    defer state.gpa.free(bytes);
    const file = try std.Io.Dir.cwd().createFile(state.io, level_path, .{});
    defer file.close(state.io);
    try file.writePositionalAll(state.io, bytes, 0);
}

// Parse a blob into a fresh LevelDoc (caller owns + frees), or null if invalid
// (so the caller falls back to the default level). v1 files use the default start.
fn parseDoc(gpa: std.mem.Allocator, bytes: []const u8) !?LevelDoc {
    if (bytes.len < 8) return null;
    if (!std.mem.eql(u8, bytes[0..4], &level_magic)) return null;
    const version = bytes[4];
    if (version != 1 and version != 2) return null;
    const count = std.mem.readInt(u16, bytes[6..8], .little);

    var off: usize = 8;
    var start_gx: i32 = default_start_gx;
    var start_gy: i32 = default_start_gy;
    if (version >= 2) {
        if (bytes.len < 12) return null;
        start_gx = std.mem.readInt(i16, bytes[8..10], .little);
        start_gy = std.mem.readInt(i16, bytes[10..12], .little);
        off = 12;
    }

    var doc = LevelDoc{ .start_cell = .{ start_gx, start_gy } };
    errdefer doc.deinit(gpa);

    var i: u16 = 0;
    while (i < count) : (i += 1) {
        // errdefer only runs on an ERROR return, not `return null`, so free
        // explicitly before bailing on a truncated/invalid blob.
        if (off + 8 > bytes.len) {
            doc.deinit(gpa);
            return null;
        }
        const tag = bytes[off];
        const gx = std.mem.readInt(i16, bytes[off + 1 ..][0..2], .little);
        const gy = std.mem.readInt(i16, bytes[off + 3 ..][0..2], .little);
        const w = bytes[off + 5];
        const h = bytes[off + 6];
        const dir = bytes[off + 7];
        off += 8;

        const piece: Piece = switch (tag) {
            @intFromEnum(Kind.brick) => .{ .kind = .brick, .gx = gx, .gy = gy },
            @intFromEnum(Kind.cart) => .{ .kind = .cart, .gx = gx, .gy = gy },
            @intFromEnum(Kind.window) => .{ .kind = .window, .gx = gx, .gy = gy },
            @intFromEnum(Kind.button) => .{ .kind = .button, .gx = gx, .gy = gy },
            @intFromEnum(Kind.flower) => .{ .kind = .flower, .gx = gx, .gy = gy },
            @intFromEnum(Kind.spike) => .{ .kind = .spike, .gx = gx, .gy = gy, .dir = gateDirFromByte(dir) },
            @intFromEnum(Kind.book) => .{ .kind = .book, .gx = gx, .gy = gy, .dir = gateDirFromByte(dir) },
            gate_disk_tag => blk: {
                const gw: i32 = if (w == 0) 1 else w;
                const gh: i32 = if (h == 0) 1 else h;
                break :blk .{
                    .kind = gateKindForSize(gw, gh),
                    .gx = gx,
                    .gy = gy,
                    .w = gw,
                    .h = gh,
                    .dir = gateDirFromByte(dir),
                };
            },
            else => {
                doc.deinit(gpa); // free pieces parsed so far (errdefer won't run on `return null`)
                return null; // unknown kind tag → treat blob as invalid
            },
        };
        try doc.add(gpa, piece);
    }
    return doc;
}

// ---------------------------------------------------------------------------
// Hardcoded fallback level as authored DATA (a LevelDoc), used when no blob is
// embedded or it's invalid. Built into a World via the same path as a loaded one.
// ---------------------------------------------------------------------------

// A run of blocks: `count` tiles from (gx,gy), horizontal/vertical.
const Run = struct {
    gx: i32,
    gy: i32,
    count: i32,
    dir: enum { horizontal, vertical },
};

const default_runs = [_]Run{
    .{ .gx = 0, .gy = 12, .count = 48, .dir = .horizontal }, // ground, two rooms wide
    .{ .gx = 3, .gy = 9, .count = 4, .dir = .horizontal },
    .{ .gx = 11, .gy = 7, .count = 4, .dir = .horizontal },
    .{ .gx = 18, .gy = 5, .count = 4, .dir = .horizontal },
    .{ .gx = 15, .gy = 9, .count = 3, .dir = .vertical }, // wall
    .{ .gx = 7, .gy = 4, .count = 1, .dir = .horizontal },
    .{ .gx = 28, .gy = 9, .count = 5, .dir = .horizontal }, // room 2 platform
    .{ .gx = 34, .gy = 11, .count = 2, .dir = .vertical }, // step
};

const default_cart_spawns = [_][2]i32{
    .{ 9, 11 }, .{ 10, 11 }, .{ 21, 11 }, .{ 12, 6 },
};

// Build the fallback doc — pure data, no entities.
fn buildDefaultDoc(gpa: std.mem.Allocator) !LevelDoc {
    var doc = LevelDoc{ .start_cell = .{ default_start_gx, default_start_gy } };
    errdefer doc.deinit(gpa);

    for (default_runs) |r| {
        var n: i32 = 0;
        while (n < r.count) : (n += 1) {
            const gx = if (r.dir == .horizontal) r.gx + n else r.gx;
            const gy = if (r.dir == .vertical) r.gy + n else r.gy;
            try doc.add(gpa, .{ .kind = .brick, .gx = gx, .gy = gy });
        }
    }
    for (default_cart_spawns) |c| {
        try doc.add(gpa, .{ .kind = .cart, .gx = c[0], .gy = c[1] });
    }

    // Interactive test pieces: button + single-cell gate + 2x3 multi-cell gate.
    try doc.add(gpa, .{ .kind = .button, .gx = 5, .gy = 11 });
    try doc.add(gpa, .{ .kind = .gate_single, .gx = 13, .gy = 11, .dir = .up });
    try doc.add(gpa, .{ .kind = .gate_multi, .gx = 22, .gy = 9, .w = 2, .h = 3, .dir = .up });

    // Window test: see-through window with a block behind it (clone right through it).
    try doc.add(gpa, .{ .kind = .window, .gx = 8, .gy = 11 });
    try doc.add(gpa, .{ .kind = .brick, .gx = 9, .gy = 11 });

    // Decorative flower (walk-through, cloneable, no button effect).
    try doc.add(gpa, .{ .kind = .flower, .gx = 3, .gy = 11 });

    // Checkpoint test piece: walk onto it to set the respawn point.
    try doc.add(gpa, .{ .kind = .book, .gx = 30, .gy = 11 });

    return doc;
}

// Baked-in level. @embedFile resolves at compile time, so assets/level.dat must
// exist. Delete this and the embedded_level use below to fall back to buildDefaultDoc.
const embedded_level: ?[]const u8 = @embedFile("assets/level.dat");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(window_w, window_h, "Clone Game");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    // Off-screen target at virtual resolution; the whole game draws here, then
    // scales to the window.
    const target = try rl.loadRenderTexture(virtual_w, virtual_h);
    defer rl.unloadRenderTexture(target);
    rl.setTextureFilter(target.texture, .point);

    // Decode the embedded PNG and upload to the GPU (needs the GL context, so
    // after initWindow).
    const atlas_img = try rl.loadImageFromMemory(".png", atlas_png);
    const atlas = try rl.loadTextureFromImage(atlas_img);
    defer rl.unloadImage(atlas_img); // kept alive for CPU-side pixel sampling
    defer rl.unloadTexture(atlas);
    rl.setTextureFilter(atlas, .point);

    const mask_shader = try rl.loadShaderFromMemory(null, clone_mask_fs);
    defer rl.unloadShader(mask_shader);

    const ripple_shader = try rl.loadShaderFromMemory(null, clone_ripple_fs);
    defer rl.unloadShader(ripple_shader);

    const crt_shader = try rl.loadShaderFromMemory(crt_vs, crt_fs);
    defer rl.unloadShader(crt_shader);
    // Static CRT uniforms (only `resolution` changes per frame).
    setShaderFloat(crt_shader, "_Curvature", crt_curvature);
    setShaderFloat(crt_shader, "_VignetteWidth", crt_vignette_width);
    setShaderFloat(crt_shader, "_VignetteFadeIntensity", crt_vignette_fade);
    setShaderFloat(crt_shader, "_ChromAbAmount", crt_chrom_ab);
    setShaderFloat(crt_shader, "_MaskIntensity", crt_mask_intensity);
    setShaderFloat(crt_shader, "_CornerShape", crt_corner_shape);
    setShaderFloat(crt_shader, "_EdgeWidth", crt_edge_width);
    setShaderFloat(crt_shader, "_EdgeFade", crt_edge_fade);
    setShaderFloat(crt_shader, "_GlowIntensity", crt_glow_intensity);
    setShaderFloat(crt_shader, "_GlowRadius", crt_glow_radius);
    const loc_crt_resolution = rl.getShaderLocation(crt_shader, "resolution");

    // Prefer the embedded blob (if it parses); else the hardcoded default. A bad
    // embed falls back, so it can't ship an empty world.
    var doc: LevelDoc = blk: {
        if (embedded_level) |bytes| {
            if (parseDoc(gpa, bytes) catch null) |d| break :blk d;
        }
        break :blk try buildDefaultDoc(gpa);
    };
    // `.doc = doc` below MOVES ownership of doc.pieces into state.doc (a LevelDoc
    // is a shallow value — the copy aliases the same buffer). The editor
    // reallocates state.doc, leaving the local stale, so we empty the local after
    // the move; state.doc is then the sole owner, freed once at shutdown.
    errdefer doc.deinit(gpa); // covers failure BEFORE the move; no-op after (emptied)

    var world = try World.build(gpa, &doc);
    errdefer world.deinit(gpa);

    var state = State{
        .gpa = gpa,
        .io = io,
        .atlas = atlas,
        .atlas_img = atlas_img,
        .mask_shader = mask_shader,
        .loc_sprite_rect = rl.getShaderLocation(mask_shader, "sprite_rect"),
        .loc_mask_rect = rl.getShaderLocation(mask_shader, "mask_rect"),
        .ripple_shader = ripple_shader,
        .loc_ripple_sprite_rect = rl.getShaderLocation(ripple_shader, "sprite_rect"),
        .loc_ripple_time = rl.getShaderLocation(ripple_shader, "time"),
        .loc_ripple_alpha = rl.getShaderLocation(ripple_shader, "tint_alpha"),
        .loc_ripple_mask_rect = rl.getShaderLocation(ripple_shader, "mask_rect"),
        .loc_ripple_use_mask = rl.getShaderLocation(ripple_shader, "use_mask"),
        .crt_shader = crt_shader,
        .loc_crt_resolution = loc_crt_resolution,
        .doc = doc, // ownership of doc.pieces moves here
        .world = world,
    };
    doc = .{}; // moved-from husk; its deinit/errdefer is now a no-op
    world = .{ .player = state.world.player }; // ditto
    defer state.world.deinit(gpa);
    defer state.doc.deinit(gpa);
    defer state.clipboard.deinit(gpa);
    defer if (state.undo_doc) |*u| u.deinit(gpa);

    // Warn (don't move) if the start cell is buried in a solid — the author may
    // intend a tight spot.
    if (!areaFree(&state, state.player().rect, null)) {
        std.log.warn("player start ({d},{d}) overlaps a solid cube", .{ state.doc.start_cell[0], state.doc.start_cell[1] });
    }

    while (!rl.windowShouldClose()) {
        const dt = @min(rl.getFrameTime(), max_dt);
        try update(&state, dt);

        rl.beginTextureMode(target);
        draw(&state);
        rl.endTextureMode();

        // Scale to the window through the CRT post-process. `resolution` is the
        // scaled output size so the mask/curvature/bloom resolve at output scale.
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.black);
        const vp = viewport();
        const res = [2]f32{ virtual_w * vp.scale, virtual_h * vp.scale };
        rl.setShaderValue(state.crt_shader, state.loc_crt_resolution, &res, .vec2);
        rl.beginShaderMode(state.crt_shader);
        presentScaled(target);
        rl.endShaderMode();
        rl.drawFPS(0, 0); // on top, outside the CRT effect
    }
}

// Set a float uniform by name (resolves the location each call; init-only).
fn setShaderFloat(shader: rl.Shader, name: [:0]const u8, value: f32) void {
    const loc = rl.getShaderLocation(shader, name);
    const v = value;
    rl.setShaderValue(shader, loc, &v, .float);
}

// Letterbox transform from virtual to window pixels: largest integer scale that
// fits + centering offset. Shared by the present blit and mouseWorld.
const Viewport = struct { scale: f32, off_x: f32, off_y: f32 };

fn viewport() Viewport {
    const win_w: f32 = @floatFromInt(rl.getScreenWidth());
    const win_h: f32 = @floatFromInt(rl.getScreenHeight());
    var scale: f32 = @min(win_w / virtual_w, win_h / virtual_h);
    scale = @max(1, @floor(scale));
    return .{
        .scale = scale,
        .off_x = (win_w - virtual_w * scale) / 2,
        .off_y = (win_h - virtual_h * scale) / 2,
    };
}

// Top-left world coords of the room containing (cx,cy). The camera snaps here
// and mouseWorld adds it back, so they must agree — computed in one place.
fn roomOrigin(cx: f32, cy: f32) rl.Vector2 {
    return .{
        .x = @floor(cx / virtual_w) * virtual_w,
        .y = @floor(cy / virtual_h) * virtual_h,
    };
}

// Blit the target to the window at the largest integer scale, centered, with
// letterbox bars. Integer scaling keeps every source pixel an exact NxN block.
fn presentScaled(target: rl.RenderTexture2D) void {
    const vp = viewport();
    const dest_w = virtual_w * vp.scale;
    const dest_h = virtual_h * vp.scale;

    // Source height negated: render textures are stored flipped in OpenGL.
    const source = rl.Rectangle{ .x = 0, .y = 0, .width = virtual_w, .height = -virtual_h };
    const dest = rl.Rectangle{ .x = vp.off_x, .y = vp.off_y, .width = dest_w, .height = dest_h };
    rl.drawTexturePro(target.texture, source, dest, .{ .x = 0, .y = 0 }, 0, .white);
}

fn update(state: *State, dt: f32) !void {
    if (rl.isKeyPressed(.tab)) {
        const leaving_edit = state.edit_mode;
        state.edit_mode = !state.edit_mode;
        // Abandon any in-flight death sequence on a mode switch.
        state.world.death_phase = .none;
        state.world.death_timer = 0;

        if (leaving_edit) {
            // Edit → play: rebuild the World fresh from the doc. The player keeps
            // its roam position (drop into play where you were looking), zeroed
            // and whole-pixel; if that spot is buried in a solid, revert to start.
            const roam = state.player().rect;
            const fresh = try World.build(state.gpa, &state.doc);
            const landing = rl.Rectangle{
                .x = @round(roam.x),
                .y = @round(roam.y),
                .width = fresh.player.rect.width,
                .height = fresh.player.rect.height,
            };
            // areaFree needs the live state, so swap the fresh world in first.
            state.world.deinit(state.gpa);
            state.world = fresh;
            const start = state.player().rect; // authored start from build
            state.player().rect = landing;
            state.player().vel = .{ .x = 0, .y = 0 };
            state.player().rem = .{ .x = 0, .y = 0 };
            state.player().on_ground = false;
            if (!areaFree(state, landing, null)) {
                state.player().rect = start; // buried: revert
            }
        } else {
            // Play → edit: clear velocity and snap the player onto whole pixels so
            // the editor grid stays aligned.
            const p = state.player();
            p.vel = .{ .x = 0, .y = 0 };
            p.on_ground = false;
            p.rect.x = @round(p.rect.x);
            p.rect.y = @round(p.rect.y);
            p.rem = .{ .x = 0, .y = 0 };
        }
    }

    if (state.edit_mode) {
        try updateEdit(state, dt);
        return;
    }

    // Death sequence: world/input frozen, only cosmetics + the timer advance.
    if (state.world.death_phase != .none) {
        advanceDeathSeq(state, dt);
        animateSpawnMasks(state, dt); // let any clone vanish finish
        animateCheckpoints(state, dt); // let an in-flight checkpoint flourish finish
        updateParticles(state, dt); // death burst keeps flying during the hold
        updateDust(state, dt);
        return;
    }

    handleInput(state);
    // Clone resolves BEFORE interactives: if the player clones a cube under
    // itself the same frame a closing gate would push it, the clone happens first
    // and the gate then pushes the post-clone world. findLookTarget feeds tryClone.
    findLookTarget(state);
    try handleActions(state);
    updateInteractives(state, dt);
    applyPhysics(state, dt);
    checkSpikeDeath(state);
    checkCheckpoints(state);
    checkRoomChange(state);
    animatePlayer(state, dt);
    animateCarts(state, dt);
    animateCheckpoints(state, dt);
    animateSpawnMasks(state, dt);
    updateParticles(state, dt);
    updateDust(state, dt);
}

// Advance the death sequence: hold → cover → reveal → none. The respawn teleport
// is at the cover→reveal boundary (full cover), hiding the cut. Camera stays on
// death_cam (see draw).
fn advanceDeathSeq(state: *State, dt: f32) void {
    const w = &state.world;
    w.death_timer += dt;
    switch (w.death_phase) {
        .none => {},
        .hold => {
            if (w.death_timer >= death_hold_time) {
                w.death_phase = .cover;
                w.death_timer = 0;
            }
        },
        .cover => {
            if (w.death_timer >= death_cover_time) {
                // Fully covered: respawn the player, hidden behind the wipe, at the
                // active checkpoint if one exists, else the level start.
                const p = state.player();
                const cell = respawnCell(state);
                p.rect = cellRect(cell[0], cell[1]);
                p.vel = .{ .x = 0, .y = 0 };
                p.rem = .{ .x = 0, .y = 0 };
                p.on_ground = false;
                // Reseat the room so reveal shows the respawn room, and reset boxes
                // so the retry starts clean.
                w.current_room = .{ .x = std.math.floatMax(f32), .y = std.math.floatMax(f32) };
                checkRoomChange(state);
                resetCarts(state);
                w.death_phase = .reveal;
                w.death_timer = 0;
            }
        },
        .reveal => {
            if (w.death_timer >= death_reveal_time) {
                w.death_phase = .none;
                w.death_timer = 0;
            }
        },
    }
}

// On a room transition (player center crossed into a new screen-cell), update the
// tracked room. Box resets are NO LONGER tied to room changes — boxes reset only
// when a checkpoint is activated (see checkCheckpoints). The camera and death
// sequence still rely on current_room, so the tracking itself stays.
fn checkRoomChange(state: *State) void {
    const p = state.player();
    const room = roomOrigin(p.rect.x + p.rect.width / 2, p.rect.y + p.rect.height / 2);
    if (room.x == state.world.current_room.x and room.y == state.world.current_room.y) return;
    state.world.current_room = room;
}

// The cell the player should respawn at. Computed live from active checkpoints:
// an active checkpoint CLONE wins (so dying with an activated clone returns you
// to the clone), else the active original checkpoint, else the remembered cell,
// else the level start. Because this reads `cp_active` off live entities, a
// removed clone falls back to its still-active original automatically.
fn respawnCell(state: *State) [2]i32 {
    var original: ?[2]i32 = null;
    for (state.entities().slots.items) |s| {
        if (!s.alive or s.entity.kind != .book or !s.entity.cp_active) continue;
        const cell = [2]i32{
            @intFromFloat(@round(s.entity.rect.x / tile)),
            @intFromFloat(@round(s.entity.rect.y / tile)),
        };
        if (s.entity.is_clone) return cell; // a clone takes priority
        original = cell;
    }
    if (original) |c| return c;
    return state.world.respawn_cell orelse state.doc.start_cell;
}

// Reset every box (dynamic, non-clone cube) to its spawn position and clear its
// motion. Called when a checkpoint is activated so each checkpoint is a clean
// restart state.
fn resetCarts(state: *State) void {
    for (state.entities().slots.items) |*s| {
        if (!s.alive) continue;
        const e = &s.entity;
        if (!e.dynamic or e.is_clone) continue; // boxes only
        e.rect.x = e.spawn_pos.x;
        e.rect.y = e.spawn_pos.y;
        e.vel = .{ .x = 0, .y = 0 };
        e.on_ground = false;
        e.cart_frame = 0;
        e.cart_anim_time = 0;
        e.cart_rolled = false;
        e.cart_roll_dir = 1;
    }
}

// Kill the player the moment they touch any spike (placed or cloned). Spikes are
// non-solid, so the player walks freely into them; contact alone is lethal. Runs
// after physics so it tests the settled position. Already-running death does
// nothing (destroyBody guards re-entry).
fn checkSpikeDeath(state: *State) void {
    if (state.world.death_phase != .none) return;
    const pr = state.player().rect;
    for (state.entities().slots.items) |s| {
        if (!s.alive or s.entity.kind != .spike) continue;
        // A materializing or vanishing spike-clone isn't lethal yet/anymore: it's
        // mid-transition, so contact during the spawn/vanish mask is harmless.
        if (s.entity.is_clone and s.entity.mask_phase != .none) continue;
        if (overlaps(pr, s.entity.rect)) {
            destroyBody(state, .player);
            return;
        }
    }
}

// The identity cell of a checkpoint: a clone reports the original it descends
// from (cp_origin); an original reports its own grid cell. Two checkpoints are
// twins iff these match — pairing an original with any clone made from it.
fn checkpointOrigin(e: Entity) [2]i32 {
    return e.cp_origin orelse .{
        @intFromFloat(@round(e.rect.x / tile)),
        @intFromFloat(@round(e.rect.y / tile)),
    };
}

fn checkpointTwins(a: Entity, b: Entity) bool {
    if (a.kind != .book or b.kind != .book) return false;
    const oa = checkpointOrigin(a);
    const ob = checkpointOrigin(b);
    return oa[0] == ob[0] and oa[1] == ob[1];
}

// Begin a checkpoint's activation flourish (forward) and mark it active.
fn cpActivate(e: *Entity) void {
    e.cp_active = true;
    e.cp_anim_playing = true;
    e.cp_anim_reverse = false;
    e.cp_anim_frame = 0;
    e.cp_anim_time = 0;
}

// Begin a checkpoint's deactivation flourish (reverse) and mark it inactive.
fn cpDeactivate(e: *Entity) void {
    e.cp_active = false;
    e.cp_anim_playing = true;
    e.cp_anim_reverse = true;
    e.cp_anim_frame = checkpoint_anim_frames.len - 1;
    e.cp_anim_time = 0;
}

// Activate a checkpoint when the player walks onto it. The touched checkpoint AND
// its twin (an original and any clone of it) both activate, so stepping on a
// cloned checkpoint lights up the original too. Any unrelated active checkpoints
// deactivate. Respawn position is derived later (respawnCell), preferring a clone.
// Re-touching an already-active checkpoint does nothing.
fn checkCheckpoints(state: *State) void {
    if (state.world.death_phase != .none) return;
    const pr = state.player().rect;

    // Find the checkpoint the player is standing on, if any.
    var touched: ?usize = null;
    for (state.entities().slots.items, 0..) |s, i| {
        if (!s.alive or s.entity.kind != .book) continue;
        if (overlaps(pr, s.entity.rect)) {
            touched = i;
            break;
        }
    }
    const idx = touched orelse return;
    const hit = state.entities().slots.items[idx].entity;
    if (hit.cp_active) return; // already current (twin would be too)

    // Deactivate every active checkpoint that is NOT the touched one or its twin.
    for (state.entities().slots.items, 0..) |*s, i| {
        if (!s.alive or s.entity.kind != .book or i == idx) continue;
        const o = &s.entity;
        if (o.cp_active and !checkpointTwins(o.*, hit)) cpDeactivate(o);
    }

    // Activate the touched checkpoint and any twin (original <-> clone).
    for (state.entities().slots.items, 0..) |*s, i| {
        if (!s.alive or s.entity.kind != .book) continue;
        const o = &s.entity;
        if (i == idx or checkpointTwins(o.*, hit)) {
            if (!o.cp_active) cpActivate(o);
        }
    }

    // Remember the original's cell as a stable fallback (used if every active
    // checkpoint entity later disappears). The origin cell IS the original's cell.
    state.world.respawn_cell = checkpointOrigin(hit);
    resetCarts(state);
}

// Advance any playing checkpoint animation. Activation plays forward (first→last)
// and rests on the last frame; deactivation plays reverse (last→first) and rests
// on the first (idle) frame. Plays once either way.
fn animateCheckpoints(state: *State, dt: f32) void {
    for (state.entities().slots.items) |*s| {
        if (!s.alive or s.entity.kind != .book) continue;
        const e = &s.entity;
        if (!e.cp_anim_playing) continue;
        e.cp_anim_time += dt;
        while (e.cp_anim_time >= checkpoint_anim_frame_time) {
            e.cp_anim_time -= checkpoint_anim_frame_time;
            if (e.cp_anim_reverse) {
                if (e.cp_anim_frame == 0) {
                    e.cp_anim_playing = false; // rest on the idle (first) frame
                    break;
                }
                e.cp_anim_frame -= 1;
            } else {
                if (e.cp_anim_frame + 1 >= checkpoint_anim_frames.len) {
                    e.cp_anim_playing = false; // rest on the final (active) frame
                    break;
                }
                e.cp_anim_frame += 1;
            }
        }
    }
}

fn mouseWorld(state: *State) rl.Vector2 {
    const m = rl.getMousePosition();
    const vp = viewport();
    const vx = (m.x - vp.off_x) / vp.scale;
    const vy = (m.y - vp.off_y) / vp.scale;
    const p = state.player();
    const origin = roomOrigin(p.rect.x + p.rect.width / 2, p.rect.y + p.rect.height / 2);
    return .{ .x = vx + origin.x, .y = vy + origin.y };
}

// Rebuild the World from the doc, keeping the player's roam position (the editor
// uses the player as a free camera). Called after any doc edit.
fn rebuildWorld(state: *State) !void {
    const roam = state.player().rect;
    var fresh = try World.build(state.gpa, &state.doc);
    fresh.player.rect = roam;
    state.world.deinit(state.gpa);
    state.world = fresh;
}

// Snapshot the current doc for single-step undo, replacing any previous snapshot.
// Call this once at the START of each edit gesture (before the doc is mutated).
// A failed snapshot just leaves undo unavailable for this edit (not fatal).
fn pushUndo(state: *State) void {
    const snap = state.doc.clone(state.gpa) catch {
        // Couldn't snapshot: drop any stale one so a later undo can't restore an
        // out-of-date doc. Undo is simply unavailable for this edit.
        if (state.undo_doc) |*u| u.deinit(state.gpa);
        state.undo_doc = null;
        return;
    };
    if (state.undo_doc) |*u| u.deinit(state.gpa);
    state.undo_doc = snap;
}

// Restore the last snapshot, swapping it into place as the live doc and freeing
// the superseded one. Single step only: the snapshot is consumed (cleared), so a
// second undo does nothing until another edit snapshots again.
fn performUndo(state: *State) !void {
    const snap = state.undo_doc orelse return;
    state.undo_doc = null;
    state.doc.deinit(state.gpa);
    state.doc = snap;
    // The snapshot may have removed pieces the selection pointed at; drop it to
    // avoid a dangling region.
    state.selection = null;
    state.drag_start = null;
    state.last_paint_cell = null;
    try rebuildWorld(state);
}

// Copy every piece overlapping the current selection into the clipboard, storing
// each piece's position RELATIVE to the selection's top-left so paste can stamp
// it at any anchor. A gate that straddles the selection edge is copied whole
// (its origin may land slightly outside the selection — paste preserves shape).
// No selection, or an empty result, leaves the clipboard unchanged.
fn copySelection(state: *State) !void {
    const sel = state.selection orelse return;
    const sx = sel[0];
    const sy = sel[1];
    const sw = sel[2];
    const sh = sel[3];

    var clip: std.ArrayList(Piece) = .empty;
    errdefer clip.deinit(state.gpa);
    for (state.doc.pieces.items) |p| {
        // Overlap test against the selection rect (same predicate as clearRect).
        const px1 = p.gx + p.w;
        const py1 = p.gy + p.h;
        const hit = p.gx < sx + sw and sx < px1 and p.gy < sy + sh and sy < py1;
        if (!hit) continue;
        var rel = p;
        rel.gx = p.gx - sx; // store relative to selection origin
        rel.gy = p.gy - sy;
        try clip.append(state.gpa, rel);
    }
    if (clip.items.len == 0) {
        clip.deinit(state.gpa);
        return; // nothing to copy; keep any existing clipboard
    }

    state.clipboard.deinit(state.gpa); // replace previous clipboard
    state.clipboard = clip;
    state.clip_w = sw;
    state.clip_h = sh;
}

// Cut = copy, then erase the selected region from the doc.
fn cutSelection(state: *State) !void {
    const sel = state.selection orelse return;
    try copySelection(state);
    if (state.clipboard.items.len == 0) return; // copy found nothing
    pushUndo(state); // snapshot before the erase
    state.doc.clearRect(sel[0], sel[1], sel[2], sel[3]);
    try rebuildWorld(state);
}

// Paste the clipboard with its top-left at (gx, gy). Each pasted footprint is
// cleared first so paste replaces, mirroring single-cell placement. After paste,
// the selection is moved to the pasted region for chained edits.
fn pasteClipboard(state: *State, gx: i32, gy: i32) !void {
    if (state.clipboard.items.len == 0) return;
    pushUndo(state); // snapshot before stamping
    for (state.clipboard.items) |c| {
        var p = c;
        p.gx = c.gx + gx;
        p.gy = c.gy + gy;
        state.doc.clearRect(p.gx, p.gy, p.w, p.h);
        try state.doc.add(state.gpa, p);
    }
    state.selection = .{ gx, gy, state.clip_w, state.clip_h };
    try rebuildWorld(state);
}

// Edit mode: number keys pick a type, left-click places (replacing), right-click
// or eraser removes, WASD/arrows roam (Shift jumps a screen). Edits mutate the
// doc, then rebuildWorld reflects them.
fn updateEdit(state: *State, dt: f32) !void {
    if (rl.isKeyPressed(.one)) state.palette = .brick;
    if (rl.isKeyPressed(.two)) state.palette = .cart;
    if (rl.isKeyPressed(.three)) state.palette = .window;
    if (rl.isKeyPressed(.four)) state.palette = .button;
    if (rl.isKeyPressed(.five)) state.palette = .gate;
    if (rl.isKeyPressed(.six)) state.palette = .start;
    if (rl.isKeyPressed(.seven)) state.palette = .flower;
    if (rl.isKeyPressed(.eight)) state.palette = .spike;
    if (rl.isKeyPressed(.nine)) state.palette = .book;
    if (rl.isKeyPressed(.zero)) state.palette = .eraser;
    // Q enters/leaves selection mode (drag a rectangle, then copy/cut/paste).
    if (rl.isKeyPressed(.q)) {
        state.palette = if (state.palette == .select) .brick else .select;
        state.drag_start = null;
    }

    // R cycles the next gate's open direction.
    if (rl.isKeyPressed(.r)) {
        state.edit_gate_dir = switch (state.edit_gate_dir) {
            .up => .down,
            .down => .left,
            .left => .right,
            .right => .up,
        };
    }

    // Clipboard: Ctrl+C copy, Ctrl+X cut (both need a selection), Ctrl+V paste
    // with its top-left at the hovered cell. These work from any palette.
    const ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
    if (ctrl) {
        const cursor = mouseWorld(state);
        const cgx: i32 = @intFromFloat(@floor(cursor.x / tile));
        const cgy: i32 = @intFromFloat(@floor(cursor.y / tile));
        if (rl.isKeyPressed(.c)) try copySelection(state);
        if (rl.isKeyPressed(.x)) try cutSelection(state);
        if (rl.isKeyPressed(.v)) try pasteClipboard(state, cgx, cgy);
        if (rl.isKeyPressed(.z)) try performUndo(state);
    }

    // F5 saves to level.dat (failure logged, not fatal).
    if (rl.isKeyPressed(.f5)) {
        if (saveLevel(state)) {
            std.log.info("saved level to {s}", .{level_path});
        } else |err| {
            std.log.err("level save failed: {s}", .{@errorName(err)});
        }
    }
    const wheel = rl.getMouseWheelMove();
    if (wheel != 0) {
        const n = @typeInfo(Palette).@"enum".fields.len;
        const cur: i32 = @intCast(@intFromEnum(state.palette));
        const next = @mod(cur + (if (wheel > 0) @as(i32, 1) else -1), @as(i32, n));
        state.palette = @enumFromInt(@as(usize, @intCast(next)));
    }

    // Roam (no physics) to pan between rooms.
    handleInput(state);
    const p = state.player();

    // Shift + direction jumps one screen.
    const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
    var jumped = false;
    if (shift) {
        if (rl.isKeyPressed(.a) or rl.isKeyPressed(.left)) {
            p.rect.x -= virtual_w;
            jumped = true;
        }
        if (rl.isKeyPressed(.d) or rl.isKeyPressed(.right)) {
            p.rect.x += virtual_w;
            jumped = true;
        }
        if (rl.isKeyPressed(.w) or rl.isKeyPressed(.up)) {
            p.rect.y -= virtual_h;
            jumped = true;
        }
        if (rl.isKeyPressed(.s) or rl.isKeyPressed(.down)) {
            p.rect.y += virtual_h;
            jumped = true;
        }
    }

    if (!jumped) {
        // Roam in whole pixels so the anchor stays grid-aligned.
        p.rect.x += @round(p.vel.x * dt);
        if (rl.isKeyDown(.up) or rl.isKeyDown(.w)) p.rect.y -= @round(move_speed * dt);
        if (rl.isKeyDown(.down) or rl.isKeyDown(.s)) p.rect.y += @round(move_speed * dt);
    }

    const world = mouseWorld(state);
    const gx: i32 = @intFromFloat(@floor(world.x / tile));
    const gy: i32 = @intFromFloat(@floor(world.y / tile));

    // `start` records the player spawn cell.
    if (state.palette == .start) {
        if (rl.isMouseButtonPressed(.left)) pushUndo(state);
        if (rl.isMouseButtonDown(.left)) {
            state.doc.start_cell = .{ gx, gy };
        }
        return;
    }

    // Selection mode: left-drag defines a rectangle (used by copy/cut); a plain
    // left-click without dragging clears the selection. No doc edits happen here —
    // copy/cut/paste act on the selection via the Ctrl shortcuts above.
    if (state.palette == .select) {
        if (rl.isMouseButtonPressed(.left)) {
            state.drag_start = .{ gx, gy };
        }
        if (rl.isMouseButtonReleased(.left)) {
            if (state.drag_start) |ds| {
                const x0 = @min(ds[0], gx);
                const y0 = @min(ds[1], gy);
                const w: i32 = @intCast(@abs(gx - ds[0]) + 1);
                const h: i32 = @intCast(@abs(gy - ds[1]) + 1);
                // A 1x1 "selection" from a bare click clears instead, so clicking
                // empty space deselects.
                state.selection = if (w == 1 and h == 1) null else .{ x0, y0, w, h };
                state.drag_start = null;
            }
        }
        return;
    }

    // Block and gate drag-fill a rectangle (gate → one multi-cell gate);
    // right-drag erases it. Other types paint one cell per hovered cell.
    const rectangular = state.palette == .brick or state.palette == .gate;

    if (rectangular) {
        if (rl.isMouseButtonPressed(.left) or rl.isMouseButtonPressed(.right)) {
            state.drag_start = .{ gx, gy };
        }

        const released_left = rl.isMouseButtonReleased(.left);
        const released_right = rl.isMouseButtonReleased(.right);
        if (released_left or released_right) {
            if (state.drag_start) |ds| {
                const x0 = @min(ds[0], gx);
                const y0 = @min(ds[1], gy);
                const w: i32 = @intCast(@abs(gx - ds[0]) + 1);
                const h: i32 = @intCast(@abs(gy - ds[1]) + 1);
                pushUndo(state); // snapshot before this place/erase
                // Clear first (this IS the erase for right-drag).
                state.doc.clearRect(x0, y0, w, h);
                if (released_left) {
                    if (state.palette == .gate) {
                        try state.doc.add(state.gpa, .{
                            .kind = gateKindForSize(w, h),
                            .gx = x0,
                            .gy = y0,
                            .w = w,
                            .h = h,
                            .dir = state.edit_gate_dir,
                        });
                    } else {
                        var j: i32 = 0;
                        while (j < h) : (j += 1) {
                            var i: i32 = 0;
                            while (i < w) : (i += 1) {
                                try state.doc.add(state.gpa, .{ .kind = .brick, .gx = x0 + i, .gy = y0 + j });
                            }
                        }
                    }
                }
                state.drag_start = null;
                try rebuildWorld(state);
            }
        }
        return;
    }

    // Single-cell types and the eraser. Drag-paint: act once per distinct
    // hovered cell so sweeping fills a line without re-adding every frame.
    const place = rl.isMouseButtonDown(.left) and state.palette != .eraser;
    const erase = rl.isMouseButtonDown(.right) or
        (rl.isMouseButtonDown(.left) and state.palette == .eraser);

    if (place or erase) {
        const cell = [2]i32{ gx, gy };
        const moved = state.last_paint_cell == null or
            state.last_paint_cell.?[0] != gx or state.last_paint_cell.?[1] != gy;
        if (moved) {
            // First cell of a stroke: snapshot the pre-stroke doc so one undo
            // reverts the whole sweep, not just the last cell.
            if (state.last_paint_cell == null) pushUndo(state);
            state.doc.clearRect(gx, gy, 1, 1);
            if (place) {
                if (paletteKind(state.palette)) |kind| {
                    // Spikes carry the editor's current rotation (R cycles it) in
                    // `dir`; checkpoints carry a left/right facing (right flips
                    // their art). Both reuse edit_gate_dir.
                    const dir: GateDir = switch (kind) {
                        .spike => state.edit_gate_dir,
                        // Collapse the 4-way editor dir to a checkpoint facing:
                        // only `.right` flips; anything else faces left (normal).
                        .book => if (state.edit_gate_dir == .right) .right else .left,
                        else => .up,
                    };
                    try state.doc.add(state.gpa, .{ .kind = kind, .gx = gx, .gy = gy, .dir = dir });
                }
            }
            state.last_paint_cell = cell;
            try rebuildWorld(state);
        }
    } else {
        state.last_paint_cell = null; // button released: next paint starts fresh
    }
}

// Buttons and gates. The NUMBER of pressed buttons sets a size cap
// (gateCapForButtons); every gate whose cell count is within the cap opens.
// Runs before physics, reading last frame's press state (one-frame lag).
fn updateInteractives(state: *State, dt: f32) void {
    // The one-frame press lag is only safe while a gate can't fully open within
    // one frame (else it could be solid over a body and eject it).
    std.debug.assert(gate_open_time > max_dt);

    var pressed_count: u32 = 0;
    for (state.entities().slots.items) |*s| {
        if (!s.alive or s.entity.role != .button) continue;
        s.entity.pressed = cellOccupied(state, s.entity.rect);
        if (s.entity.pressed) pressed_count += 1;
    }
    const cap = gateCapForButtons(pressed_count);

    const step = dt / gate_open_time;
    for (state.entities().slots.items) |*s| {
        if (!s.alive or s.entity.role != .gate) continue;
        s.entity.prev_open_amount = s.entity.open_amount; // for the closing test
        // Gate size in cells (whole rect, so all cells open together).
        const cells_w = @round(s.entity.gate_rect.width / tile);
        const cells_h = @round(s.entity.gate_rect.height / tile);
        const size: u32 = @intFromFloat(@max(1, cells_w * cells_h));
        const target: f32 = if (cap > 0 and size <= cap) 1 else 0;
        if (s.entity.open_amount < target) {
            s.entity.open_amount = @min(target, s.entity.open_amount + step);
        } else if (s.entity.open_amount > target) {
            s.entity.open_amount = @max(target, s.entity.open_amount - step);
        }
        // Solid until fully open (portcullis); solid again the instant it closes.
        s.entity.solid = s.entity.open_amount < 1.0;
    }

    evictFromClosingGates(state);
}

// Direction a closing gate pushes a trapped body: opposite its open direction
// (a down-opening gate fills from the bottom, so it pushes up).
fn gatePushDir(open_dir: GateDir) GateDir {
    return switch (open_dir) {
        .up => .down,
        .down => .up,
        .left => .right,
        .right => .left,
    };
}

// Eject bodies caught in a CLOSING gate. Each overlapping body is pushed one
// pixel at a time in the push direction until clear; a blocked pixel pushes a
// pushable blocker ahead and follows, or crushes the body (destroyBody) against
// an unpushable one / no room. Recursion slides a whole stacked column out
// together. Runs after gate solidity is set and BEFORE physics, per whole gate.
fn evictFromClosingGates(state: *State) void {
    // Index-based + length-snapshotted so a future kill effect that reallocates
    // can't invalidate us; freed slots are caught by the alive check.
    var gi: usize = 0;
    const n = state.entities().slots.items.len;
    while (gi < n) : (gi += 1) {
        const slots = state.entities().slots.items;
        const s = &slots[gi];
        if (!s.alive or s.entity.role != .gate) continue;
        const g = s.entity; // value copy: no live pointer held across the calls below
        // Closing = open_amount shrinking and not yet fully open (solid here).
        const closing = g.open_amount < g.prev_open_amount and g.open_amount < 1.0;
        if (!closing) continue;
        // Process each multi-cell gate once, from the cell owning the frame's
        // top-left (always true for a 1x1).
        if (g.rect.x != g.gate_rect.x or g.rect.y != g.gate_rect.y) continue;

        const frame = g.gate_rect;
        const dir = gatePushDir(g.dir);

        // Player first, then every dynamic cube overlapping the frame.
        evictBodyFromGate(state, .player, frame, dir);
        var bi: usize = 0;
        const bn = state.entities().slots.items.len;
        while (bi < bn) : (bi += 1) {
            const bslots = state.entities().slots.items;
            if (!bslots[bi].alive or !bslots[bi].entity.dynamic) continue;
            evictBodyFromGate(state, .{ .entity = @intCast(bi) }, frame, dir);
        }
    }
}

// Unit step vector for a push direction.
fn dirStep(dir: GateDir) rl.Vector2 {
    return switch (dir) {
        .up => .{ .x = 0, .y = -1 },
        .down => .{ .x = 0, .y = 1 },
        .left => .{ .x = -1, .y = 0 },
        .right => .{ .x = 1, .y = 0 },
    };
}

// Pixels `r` must travel in `dir` for its trailing edge to clear the frame.
fn evictDistance(r: rl.Rectangle, frame: rl.Rectangle, dir: GateDir) i32 {
    const d: f32 = switch (dir) {
        .up => (r.y + r.height) - frame.y,
        .down => (frame.y + frame.height) - r.y,
        .left => (r.x + r.width) - frame.x,
        .right => (frame.x + frame.width) - r.x,
    };
    return if (d > 0) @intFromFloat(@ceil(d)) else 0;
}

// Push one body out of the closing gate `frame` in `dir`, pixel by pixel until
// clear; an unmovable pixel destroys the body. The gate's own cells (via
// `frame`) are excluded from collision so the body slides out through the gate's
// footprint — what makes multi-cell gates work.
fn evictBodyFromGate(state: *State, b: Body, frame: rl.Rectangle, dir: GateDir) void {
    if (!overlaps(b.rect(state).*, frame)) return;
    var steps = evictDistance(b.rect(state).*, frame, dir);
    while (steps > 0) : (steps -= 1) {
        if (!evictStep(state, b, dir, frame, 0)) {
            destroyBody(state, b);
            return;
        }
    }
    // Cleared: zero the push-axis velocity/remainder and drop grounding.
    switch (dir) {
        .up, .down => {
            b.vel(state).y = 0;
            b.rem(state).y = 0;
        },
        .left, .right => {
            b.vel(state).x = 0;
            b.rem(state).x = 0;
        },
    }
    b.onGround(state).* = false;
}

// Move `b` one pixel in `dir`, pushing pushables ahead. Mirrors stepX's push
// recursion but works in any direction and treats the PLAYER as pushable (a gate
// can shove it). The pushing gate (via `frame`) is excluded. Returns true if moved.
fn evictStep(state: *State, b: Body, dir: GateDir, frame: rl.Rectangle, depth: u8) bool {
    const step = dirStep(dir);
    const r = b.rect(state);
    var probe = r.*;
    probe.x += step.x;
    probe.y += step.y;

    // Clear every solid ahead, re-probing after each push so a row is fully
    // cleared (or the step fails). Bounded by entity count and the depth cap.
    var guard: u32 = 0;
    while (evictBlocker(state, b, probe, frame)) |blocker| {
        if (depth >= push_max_depth) return false;
        if (!evictPushable(state, blocker)) return false; // unpushable → crush
        if (!evictStep(state, blocker, dir, frame, depth + 1)) return false; // no room → crush
        guard += 1;
        if (guard > max_bodies) return false; // safety net
    }

    r.x += step.x;
    r.y += step.y;
    return true;
}

// The first solid blocking `probe` for an evicting `mover` (pushable or not —
// the caller decides), or null. The mover and every cell of the pushing gate
// (matched by gate_rect == frame) are excluded, so a body escaping a multi-cell
// gate isn't blocked by the gate's own cells.
fn evictBlocker(state: *State, mover: Body, probe: rl.Rectangle, frame: rl.Rectangle) ?Body {
    if (mover != .player and overlaps(probe, state.world.player.rect)) return .player;
    for (state.entities().slots.items, 0..) |s, i| {
        if (!s.alive or !s.entity.solid) continue;
        const cand: Body = .{ .entity = @intCast(i) };
        if (cand.eql(mover)) continue;
        if (s.entity.role == .gate and sameRect(s.entity.gate_rect, frame)) continue;
        if (!overlaps(probe, s.entity.rect)) continue;
        return cand;
    }
    return null;
}

// Exact rect equality. Gate cells of one gate share gate_rect to the pixel.
fn sameRect(a: rl.Rectangle, b: rl.Rectangle) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}

// Pushable by a closing gate? Boxes and the player are; blocks/windows/gates
// aren't. A clone is pushable iff its kind is.
fn evictPushable(state: *State, b: Body) bool {
    return switch (b) {
        .player => true,
        .entity => |i| state.entities().slots.items[i].entity.pushable,
    };
}

// Sprite to sample particle colors from: the player's standing frame, or an
// entity's current sprite.
fn bodySprite(state: *State, b: Body) Sprite {
    return switch (b) {
        .player => player_walk_frames[0],
        .entity => |i| state.entities().slots.items[i].entity.sprite,
    };
}

// Destroy a crushed body: the player starts the death sequence; a box resets to
// spawn; a clone vanishes. Emits a death burst colored from the body's texture.
fn destroyBody(state: *State, b: Body) void {
    spawnDeathBurst(state, b.rect(state).*, bodySprite(state, b)); // before any reset
    switch (b) {
        .player => {
            // Start the death sequence (the teleport to start happens later,
            // under the wipe; see advanceDeathSeq). Don't restart if already running.
            const p = state.player();
            if (state.world.death_phase == .none) {
                state.world.death_cam = roomOrigin(
                    p.rect.x + p.rect.width / 2,
                    p.rect.y + p.rect.height / 2,
                );
                state.world.death_phase = .hold;
                state.world.death_timer = 0;
            }
            p.vel = .{ .x = 0, .y = 0 };
            p.rem = .{ .x = 0, .y = 0 };
            p.on_ground = false;
        },
        .entity => |i| {
            const e = &state.entities().slots.items[i].entity;
            if (e.is_clone) {
                // No real spawn: retire it (plays vanish), drop the active pointer.
                const h = state.entities().handleAt(i);
                retireClone(state, h);
                if (state.world.clone) |c| {
                    if (c.index == h.index and c.gen == h.gen) state.world.clone = null;
                }
            } else {
                e.rect.x = e.spawn_pos.x;
                e.rect.y = e.spawn_pos.y;
                e.vel = .{ .x = 0, .y = 0 };
                e.rem = .{ .x = 0, .y = 0 };
                e.on_ground = false;
                // If the object materializes back onto the player, the player
                // would be wedged inside a solid. Kill the player instead of
                // letting them get stuck. (Guarded so we don't recurse mid-death.)
                if (e.solid and state.world.death_phase == .none and
                    overlaps(e.rect, state.player().rect))
                {
                    destroyBody(state, .player);
                }
            }
        },
    }
}

// Max gate size (cells) that opens per pressed-button count: 0→0, 1→1, 2→2,
// 3→4, 4+→8.
fn gateCapForButtons(n: u32) u32 {
    return switch (n) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 4,
        else => 8,
    };
}

// True if the player or a weight-bearing cube overlaps `rect` (the button cell).
// Weight = any dynamic cube, or a still-solid clone (so a cloned block holds a
// button down; a vanishing clone doesn't).
fn cellOccupied(state: *State, rect: rl.Rectangle) bool {
    if (overlaps(rect, state.player().rect)) return true;
    for (state.entities().slots.items) |s| {
        if (!s.alive) continue;
        const weight = s.entity.dynamic or (s.entity.is_clone and s.entity.solid);
        if (!weight) continue;
        if (overlaps(rect, s.entity.rect)) return true;
    }
    return false;
}

// Advance spawn/vanish mask animations: spawning plays forward then reverts to
// normal draw; vanishing plays in reverse then self-removes. Removal during
// iteration is safe (slots never move).
fn animateSpawnMasks(state: *State, dt: f32) void {
    for (state.entities().slots.items, 0..) |*s, i| {
        if (!s.alive) continue;
        switch (s.entity.mask_phase) {
            .none => {},
            .spawning => {
                s.entity.mask_time += dt;
                while (s.entity.mask_time >= clone_mask_frame_time) {
                    s.entity.mask_time -= clone_mask_frame_time;
                    if (s.entity.mask_frame + 1 >= clone_mask_frames.len) {
                        s.entity.mask_phase = .none; // fully materialized
                        break;
                    }
                    s.entity.mask_frame += 1;
                }
            },
            .vanishing => {
                s.entity.mask_time += dt;
                while (s.entity.mask_time >= clone_vanish_frame_time) {
                    s.entity.mask_time -= clone_vanish_frame_time;
                    if (s.entity.mask_frame == 0) {
                        // Past the first frame: fully gone.
                        state.entities().remove(state.gpa, state.entities().handleAt(@intCast(i)));
                        break;
                    }
                    s.entity.mask_frame -= 1;
                }
            },
        }
    }
}

// Drive the player animation: movement plays the walk cycle and cancels a cast;
// otherwise a cast (from cloning) plays once; otherwise idle on frame 0.
// Advance each cart's roll animation while it moved this frame; when stopped it
// holds whatever frame it's on (no reset).
fn animateCarts(state: *State, dt: f32) void {
    for (state.entities().slots.items) |*s| {
        if (!s.alive or s.entity.kind != .cart) continue;
        const e = &s.entity;
        if (!e.cart_rolled) continue; // stopped: hold current frame
        const n = cart_anim_frames.len;
        e.cart_anim_time += dt;
        while (e.cart_anim_time >= cart_anim_frame_time) {
            e.cart_anim_time -= cart_anim_frame_time;
            if (e.cart_roll_dir >= 0) {
                e.cart_frame = (e.cart_frame + 1) % n;
            } else {
                // Step backward, wrapping 0 -> last (usize can't go negative).
                e.cart_frame = (e.cart_frame + n - 1) % n;
            }
        }
    }
}

fn animatePlayer(state: *State, dt: f32) void {
    const p = state.player();

    if (p.moving) {
        p.casting = false;
        if (p.pushing) {
            // Pushing a cart: cycle the push frames instead of the walk cycle.
            p.anim_frame = 0;
            p.anim_time = 0;
            p.push_time += dt;
            while (p.push_time >= push_frame_time) {
                p.push_time -= push_frame_time;
                p.push_frame = (p.push_frame + 1) % player_push_frames.len;
            }
            return;
        }
        p.push_frame = 0;
        p.push_time = 0;
        p.anim_time += dt;
        while (p.anim_time >= walk_frame_time) {
            p.anim_time -= walk_frame_time;
            p.anim_frame = (p.anim_frame + 1) % player_walk_frames.len;
        }
        return;
    }

    p.anim_frame = 0;
    p.anim_time = 0;
    p.push_frame = 0;
    p.push_time = 0;

    if (p.casting) {
        p.cast_time += dt;
        while (p.cast_time >= cast_frame_time) {
            p.cast_time -= cast_frame_time;
            p.cast_frame += 1;
            if (p.cast_frame >= player_cast_frames.len) {
                p.casting = false;
                break;
            }
        }
    }
}

// Key state → player intent: horizontal movement and facing.
fn handleInput(state: *State) void {
    const p = state.player();

    var dir: f32 = 0;
    if (rl.isKeyDown(.left) or rl.isKeyDown(.a)) dir -= 1;
    if (rl.isKeyDown(.right) or rl.isKeyDown(.d)) dir += 1;

    // Pushing = holding a direction with a pushable cart in the pixel directly
    // ahead. Derived from intent + adjacency, NOT from whole-pixel motion: the
    // player's speed banks sub-pixels in rem.x, so some frames move zero pixels
    // even while shoving — keying off motion would flicker the anim and speed.
    p.pushing = dir != 0 and cartDirectlyAhead(state, dir);

    // Pushing a cart slows the walk.
    const speed = if (p.pushing) move_speed * push_speed_mult else move_speed;
    p.vel.x = dir * speed;
    p.moving = dir != 0;
    if (dir != 0) p.facing = dir;
}

// True if a pushable cart sits in the 1px-ahead probe of the player in `dir`
// (and nothing unpushable blocks first). Mirrors stepX's push test so the push
// state matches what physics will actually do this frame.
fn cartDirectlyAhead(state: *State, dir: f32) bool {
    const pb: Body = .player;
    var probe = state.world.player.rect;
    probe.x += if (dir > 0) 1 else -1;
    if (!blocked(state, pb, probe, null)) return false; // free ahead: not pushing
    return pushableAhead(state, pb, probe) != null;
}

// ===========================================================================
// Physics: integer-pixel stepped AABB. Every body lives on whole pixels; the
// whole-pixel part of vel*dt is extracted each frame and stepped ONE PIXEL AT A
// TIME, stopping on contact. With integer positions and strict-touch overlap
// (shared edges don't overlap), a body over a same-width gap is unsupported at
// zero overlap and falls cleanly, pixel-stepping can't tunnel, and one routine
// moves all bodies. Pushing is emergent: a blocked horizontal step recurses to
// shove a pushable body, failing if it can't move.
//
// All collision goes through one predicate (`overlaps`) and one iterator
// (`querySolids`); blocked / supportBelow / restingOnGround wrap it.
// ===========================================================================

// A movable body, the player or a stored cube. Pushing recurses over Body values.
const Body = union(enum) {
    player,
    entity: u32, // slot index

    fn rect(self: Body, state: *State) *rl.Rectangle {
        return switch (self) {
            .player => &state.world.player.rect,
            .entity => |i| &state.entities().slots.items[i].entity.rect,
        };
    }
    fn vel(self: Body, state: *State) *rl.Vector2 {
        return switch (self) {
            .player => &state.world.player.vel,
            .entity => |i| &state.entities().slots.items[i].entity.vel,
        };
    }
    fn rem(self: Body, state: *State) *rl.Vector2 {
        return switch (self) {
            .player => &state.world.player.rem,
            .entity => |i| &state.entities().slots.items[i].entity.rem,
        };
    }
    fn onGround(self: Body, state: *State) *bool {
        return switch (self) {
            .player => &state.world.player.on_ground,
            .entity => |i| &state.entities().slots.items[i].entity.on_ground,
        };
    }
    fn eql(self: Body, other: Body) bool {
        return switch (self) {
            .player => other == .player,
            .entity => |i| switch (other) {
                .player => false,
                .entity => |j| i == j,
            },
        };
    }
};

// Integer AABB overlap, strict-touch (shared edges don't overlap). THE overlap
// predicate — every collision test uses it.
fn overlaps(a: rl.Rectangle, b: rl.Rectangle) bool {
    return a.x < b.x + b.width and b.x < a.x + a.width and
        a.y < b.y + b.height and b.y < a.y + a.height;
}

// How a solids query treats a STATIC floor: `strict` counts any overlap;
// `support` needs support_min px of horizontal overlap (dynamic floors stay
// strict), which lets a body drop into a same-width gap rather than snag a lip.
const SupportMode = enum { strict, support };

// THE collision query: does `r` (where `mover` would be) overlap any OTHER solid
// (the player as an obstacle for cubes, plus solid entities), per `mode`?
// `ignore` skips one body (self, or the body a pusher is actively pushing). The
// player is solid to cubes but never to itself. blocked/supportBelow/
// restingOnGround all wrap this.
fn querySolids(state: *State, mover: Body, r: rl.Rectangle, ignore: ?Body, mode: SupportMode) bool {
    const player_ignored = ignore != null and ignore.?.eql(.player);
    if (mover != .player and !player_ignored) {
        if (overlaps(r, state.world.player.rect)) return true; // player floor is strict
    }
    for (state.entities().slots.items, 0..) |s, i| {
        if (!s.alive or !s.entity.solid) continue;
        const b: Body = .{ .entity = @intCast(i) };
        if (b.eql(mover)) continue;
        if (ignore) |ig| if (b.eql(ig)) continue;
        if (!overlaps(r, s.entity.rect)) continue;
        // In support mode a STATIC floor needs real overlap; dynamic floors and
        // any non-support query count the overlap immediately.
        if (mode == .support and !s.entity.dynamic) {
            const ov = @min(r.x + r.width, s.entity.rect.x + s.entity.rect.width) -
                @max(r.x, s.entity.rect.x);
            if (ov < support_min) continue; // sliver lip: not real support
        }
        return true;
    }
    return false;
}

// Strict-overlap collision at `r`. Horizontal motion, ceilings, push building block.
fn blocked(state: *State, mover: Body, r: rl.Rectangle, ignore: ?Body) bool {
    return querySolids(state, mover, r, ignore, .strict);
}

// Downward/ground test: static floors need support_min px overlap; dynamic
// cubes and the player are strict.
fn supportBelow(state: *State, mover: Body, r: rl.Rectangle) bool {
    return querySolids(state, mover, r, null, .support);
}

// Step horizontally by `px` whole pixels, one at a time. On hitting a pushable
// body, shove it and follow; otherwise stop and zero vel.x. `depth` bounds the
// push recursion. Returns true if moved at all.
fn stepX(state: *State, b: Body, px: i32, depth: u8) bool {
    if (px == 0) return false;
    const dir: i32 = if (px > 0) 1 else -1;
    var remaining = if (px > 0) px else -px;
    var moved = false;
    const r = b.rect(state);
    while (remaining > 0) : (remaining -= 1) {
        var probe = r.*;
        probe.x += @floatFromInt(dir);
        if (blocked(state, b, probe, null)) {
            if (depth < push_max_depth) {
                if (pushableAhead(state, b, probe)) |other| {
                    if (stepX(state, other, dir, depth + 1)) {
                        r.x += @floatFromInt(dir);
                        moved = true;
                        continue;
                    }
                }
            }
            b.vel(state).x = 0;
            break;
        }
        r.x += @floatFromInt(dir);
        moved = true;
    }
    return moved;
}

// If the ONLY thing blocking `probe` is a single pushable body, return it; else
// null (a static blocker, the player, or a stack of two fails the push).
// Iterates directly since it needs per-hit classification, not just a boolean.
fn pushableAhead(state: *State, mover: Body, probe: rl.Rectangle) ?Body {
    if (mover != .player and overlaps(probe, state.world.player.rect)) return null;
    var found: ?Body = null;
    for (state.entities().slots.items, 0..) |s, i| {
        if (!s.alive or !s.entity.solid) continue;
        const b: Body = .{ .entity = @intCast(i) };
        if (b.eql(mover)) continue;
        if (!overlaps(probe, s.entity.rect)) continue;
        if (!s.entity.pushable) return null; // static blocker
        if (found != null) return null; // more than one pushable
        found = b;
    }
    return found;
}

// Step vertically by `px` whole pixels, one at a time; never pushes. Downward
// uses supportBelow (drop into same-width gaps) and flags grounding; upward
// (ceiling) is strict.
fn stepY(state: *State, b: Body, px: i32) void {
    if (px == 0) return;
    const dir: i32 = if (px > 0) 1 else -1;
    var remaining = if (px > 0) px else -px;
    const r = b.rect(state);
    while (remaining > 0) : (remaining -= 1) {
        var probe = r.*;
        probe.y += @floatFromInt(dir);
        const hit = if (dir > 0)
            supportBelow(state, b, probe)
        else
            blocked(state, b, probe, null);
        if (hit) {
            if (dir > 0) {
                b.onGround(state).* = true;
                b.vel(state).y = 0;
                settleIntoGap(state, b); // square up in a tight gap
            } else {
                b.vel(state).y = 0;
            }
            break;
        }
        r.y += @floatFromInt(dir);
    }
}

// Extract whole pixels from a remainder, banking the fraction. Positions stay
// integral since only the whole part moves.
fn takeWholePixels(remainder: *f32, amount: f32) i32 {
    remainder.* += amount;
    const whole = @trunc(remainder.*);
    remainder.* -= whole;
    return @intFromFloat(whole);
}

// Supported this frame? (A floor one pixel below.) Same rule as a downward step.
fn restingOnGround(state: *State, b: Body) bool {
    var probe = b.rect(state).*;
    probe.y += 1;
    return supportBelow(state, b, probe);
}

// After landing, square a body up inside a tight gap. The support_min rule lets
// a body fall past a wall-top it overlaps by up to support_min-1 px (needed to
// drop into a same-width hole), which can leave it resting clipped a pixel or two
// into the wall — and at rest stepX never runs to fix it. This nudges it flush.
// Conservative: STATIC walls only, sliver overlaps only (<= support_min; deeper
// is a real collision), and only if the squared-up spot is clear (a body wedged
// touching both walls is left as-is). One side per landing.
fn settleIntoGap(state: *State, b: Body) void {
    const r = b.rect(state);
    const tol: f32 = support_min;

    for (state.entities().slots.items) |s| {
        if (!s.alive or !s.entity.solid or s.entity.dynamic) continue; // static walls only
        const w = s.entity.rect;
        // Need overlap on BOTH axes (resting ON a floor touches only its top edge).
        if (!overlaps(r.*, w)) continue;

        const overlap_left = (r.x + r.width) - w.x;
        const overlap_right = (w.x + w.width) - r.x;

        // The smaller positive overlap is the clipping side; move opposite.
        var shift: f32 = 0;
        if (overlap_left > 0 and overlap_left <= overlap_right and overlap_left <= tol) {
            shift = -overlap_left;
        } else if (overlap_right > 0 and overlap_right < overlap_left and overlap_right <= tol) {
            shift = overlap_right;
        } else {
            continue; // too deep or ambiguous
        }

        var probe = r.*;
        probe.x += shift;
        // Commit only if the flush spot is clear (else the body spans the gap).
        if (!blocked(state, b, probe, null)) {
            r.x += shift;
            b.vel(state).x = 0;
            b.rem(state).x = 0;
        }
        return; // one correction per landing
    }
}

// Apply gravity and integrate every body. Dynamic cubes are processed top-first
// so a falling stack resolves against settled cubes below; the player moves
// last. Each body steps horizontally then vertically.
fn applyPhysics(state: *State, dt: f32) void {
    const slots = state.entities().slots.items;

    // Gather dynamic cubes, insertion-sort top-first (smaller y). Bottom-up would
    // let an upper cube move into a lower one before it settles.
    var order: [max_bodies]u32 = undefined;
    var n: usize = 0;
    for (slots, 0..) |*s, i| {
        if (!s.alive or !s.entity.dynamic) continue;
        if (n < order.len) {
            order[n] = @intCast(i);
            n += 1;
        }
    }
    var a: usize = 1;
    while (a < n) : (a += 1) {
        const v = order[a];
        const vy = slots[v].entity.rect.y;
        var k = a;
        while (k > 0 and slots[order[k - 1]].entity.rect.y > vy) : (k -= 1) {
            order[k] = order[k - 1];
        }
        order[k] = v;
    }

    // Snapshot x before any body moves: a cart can be shoved inside the player's
    // stepX (push recursion), not just in its own iteration, so a before/after
    // compare over the whole physics pass is the reliable "rolled" signal.
    var pre_x: [max_bodies]f32 = undefined;
    for (order[0..n], 0..) |i, oi| pre_x[oi] = slots[i].entity.rect.x;

    for (order[0..n]) |i| {
        const b: Body = .{ .entity = i };
        const e = &slots[i].entity;
        e.vel.y += gravity * dt;
        if (e.vel.y > max_fall) e.vel.y = max_fall;
        const dx = takeWholePixels(&e.rem.x, e.vel.x * dt);
        const dy = takeWholePixels(&e.rem.y, e.vel.y * dt);
        _ = stepX(state, b, dx, 0);
        stepY(state, b, dy);
        e.on_ground = restingOnGround(state, b);
    }

    const p = state.player();
    p.vel.y += gravity * dt;
    if (p.vel.y > max_fall) p.vel.y = max_fall;
    const pb: Body = .player;
    const pdx = takeWholePixels(&p.rem.x, p.vel.x * dt);
    const pdy = takeWholePixels(&p.rem.y, p.vel.y * dt);
    _ = stepX(state, pb, pdx, 0);
    stepY(state, pb, pdy);
    p.on_ground = restingOnGround(state, pb);

    // After all movement (incl. push recursion via the player's stepX), mark
    // which dynamic bodies actually changed x this frame. animateCarts reads it.
    for (order[0..n], 0..) |i, oi| {
        const dx = slots[i].entity.rect.x - pre_x[oi];
        slots[i].entity.cart_rolled = dx != 0;
        if (dx != 0) slots[i].entity.cart_roll_dir = if (dx > 0) 1 else -1;
    }
}

// React to action keys (currently just clone).
fn handleActions(state: *State) !void {
    if (rl.isKeyPressed(.enter)) try tryClone(state);
}

// Find the looked-at cube: a horizontal ray at the player's center, facing
// direction, within look_dist. Solid cubes occlude (windows and open gates don't);
// the target is the nearest clonable cube not past the occluder.
fn findLookTarget(state: *State) void {
    const p = state.player();
    const cx = p.rect.x + p.rect.width / 2;
    const cy = p.rect.y + p.rect.height / 2;

    state.world.look_target = null;

    // Pass 1: distance to the nearest solid occluder (windows excepted).
    var occluder_dist: f32 = look_dist;
    for (state.entities().slots.items) |s| {
        if (!s.alive or !s.entity.solid or s.entity.see_through) continue;
        const e = s.entity;
        if (cy < e.rect.y or cy >= e.rect.y + e.rect.height) continue;
        const edge = if (p.facing > 0) e.rect.x else e.rect.x + e.rect.width;
        const dist = (edge - cx) * p.facing;
        if (dist < 0 or dist >= occluder_dist) continue;
        occluder_dist = dist;
    }

    // Pass 2: nearest clonable cube not past the occluder (a clonable solid AT
    // occluder_dist IS the occluder, so allow <=). On a tie (same cell), prefer
    // the solid one (clone the box, not the decoration under it).
    var best_dist: f32 = occluder_dist;
    var best_solid = false;
    var nearest: ?usize = null;
    for (state.entities().slots.items, 0..) |s, i| {
        if (!s.alive or !s.entity.clonable) continue;
        if (s.entity.see_through) continue; // window
        if (s.entity.role == .gate and !s.entity.solid) continue; // open gate: pass through
        const e = s.entity;
        if (cy < e.rect.y or cy >= e.rect.y + e.rect.height) continue;
        const edge = if (p.facing > 0) e.rect.x else e.rect.x + e.rect.width;
        const dist = (edge - cx) * p.facing;
        if (dist < 0 or dist > best_dist) continue;
        if (nearest != null and dist == best_dist and !(e.solid and !best_solid)) continue;
        best_dist = dist;
        best_solid = e.solid;
        nearest = i;
    }

    if (nearest) |i| {
        state.world.look_target = state.entities().handleAt(@intCast(i));
    }
}

// Clone the looked-at cube flush against the player: in front; or, with no room
// ahead, in the player's cell (non-solid clone) or over the player, lifting them
// onto it (solid clone). Replaces any existing clone; copies the source's kind
// (and thus its flags).
fn tryClone(state: *State) !void {
    const tgt = state.world.look_target orelse return;
    const src_ptr = state.entities().get(tgt) orelse return; // stale
    const p = state.player();

    // Copy the source now (kind carries identity; spawn re-derives flags).
    var clone = src_ptr.*;
    clone.is_clone = true;
    clone.vel = .{ .x = 0, .y = 0 };
    clone.on_ground = false;
    clone.mask_phase = .spawning;
    clone.mask_frame = 0;
    clone.mask_time = 0;
    // Clean transient interactive state (cloned gate closed, button unpressed).
    clone.pressed = false;
    clone.open_amount = 0;
    // A freshly cloned checkpoint starts inactive and idle; it only becomes a
    // respawn point when the player walks onto it (which also lights its twin).
    // Record which original it descends from so the two pair up as twins (the
    // source's own cell, or the source's origin if we're cloning a clone).
    clone.cp_active = false;
    clone.cp_anim_playing = false;
    clone.cp_anim_reverse = false;
    clone.cp_anim_frame = 0;
    clone.cp_anim_time = 0;
    if (clone.kind == .book) {
        clone.cp_origin = src_ptr.cp_origin orelse .{
            @intFromFloat(@round(src_ptr.rect.x / tile)),
            @intFromFloat(@round(src_ptr.rect.y / tile)),
        };
    }
    const cw = clone.rect.width;
    const ch = clone.rect.height;

    // Front: flush against the player's leading edge, at the player's height.
    const front = rl.Rectangle{
        .x = if (p.facing > 0) p.rect.x + p.rect.width else p.rect.x - cw,
        .y = p.rect.y,
        .width = cw,
        .height = ch,
    };

    var new_rect: rl.Rectangle = undefined;
    var lift = false;
    var crush = false;
    // Front counts the existing clone as a blocker (intended): cloning again
    // while a clone sits ahead lifts you onto the new one rather than replacing
    // it in place.
    if (areaFree(state, front, null) and !overlaps(front, p.rect)) {
        new_rect = front;
    } else if (!clone.solid) {
        // Non-solid clone (flower/button): place in the player's cell (walk-through).
        new_rect = .{ .x = p.rect.x, .y = p.rect.y, .width = cw, .height = ch };
    } else {
        // Solid clone: place over the player and lift them onto it. Grounded only.
        if (!p.on_ground) return;
        const under = rl.Rectangle{ .x = p.rect.x, .y = p.rect.y, .width = cw, .height = ch };
        if (!areaFree(state, under, state.world.clone)) return;
        const lifted = rl.Rectangle{
            .x = p.rect.x,
            .y = p.rect.y - p.rect.height,
            .width = p.rect.width,
            .height = p.rect.height,
        };
        // If there's no room above, the clone still spawns under the player and
        // shoves them up into whatever is there — crushing them, like a gate.
        if (!areaFree(state, lifted, state.world.clone)) crush = true;
        new_rect = under;
        lift = true;
    }

    // Retire the old clone (left alive to play its vanish, just unpointed), spawn
    // the new one.
    if (state.world.clone) |c| retireClone(state, c);
    clone.rect = new_rect;
    // A cloned single-cell gate slides within its own new cell.
    if (clone.role == .gate) clone.gate_rect = new_rect;
    state.world.clone = try state.entities().spawn(state.gpa, clone);

    if (lift) {
        p.rect.y = new_rect.y - p.rect.height;
        p.vel.y = 0;
        p.on_ground = true;
        // Lifted into a blocked ceiling: crushed, just like a closing gate.
        if (crush) destroyBody(state, .player);
    }

    // Play the cast animation (cloning succeeded).
    p.casting = true;
    p.cast_frame = 0;
    p.cast_time = 0;

    // Cosmetic spawn sparkle at the new clone's location.
    spawnCloneBurst(state, new_rect, clone.sprite);
}

// Begin a clone's vanish: it stops being interactive (so it neither blocks nor
// can be re-targeted, won't fall, and — if it was a gate/button — no longer
// participates in the interactive system) and plays the spawn mask in reverse
// from the last frame. animateSpawnMasks removes it once the reverse finishes.
// (This mutates derived flags directly — the one sanctioned exception to "flags
// come from kind" — because a vanishing clone is leaving existence and must be
// inert regardless of what it was.)
fn retireClone(state: *State, h: Handle) void {
    const e = state.entities().get(h) orelse return;
    e.solid = false;
    e.dynamic = false;
    e.pushable = false;
    e.clonable = false;
    e.role = .none;
    e.pressed = false;
    e.mask_phase = .vanishing;
    e.mask_frame = clone_mask_frames.len - 1;
    e.mask_time = 0;
}

// True if `area` overlaps no solid cube. `ignore`, when given, excludes one
// entity (by slot index) from the test — used to ignore the current clone (about
// to be removed) when checking the clone's own destination and the lift space.
// Uses the shared `overlaps` predicate so clone placement and physics agree on
// what "touching" means.
fn areaFree(state: *State, area: rl.Rectangle, ignore: ?Handle) bool {
    for (state.entities().slots.items, 0..) |s, i| {
        if (!s.alive or !s.entity.solid) continue;
        if (ignore) |h| if (@as(usize, h.index) == i) continue;
        if (overlaps(area, s.entity.rect)) return false;
    }
    return true;
}

// ===========================================================================
// Particle system (cosmetic). A fixed inline pool on the World; particles are
// spawned in bursts, integrated each frame, and drawn as single tinted pixels.
// They never interact with physics, look, or cloning.
// ===========================================================================

// Add one particle to the pool. Reuses a dead slot, grows into unused capacity,
// or — when full — overwrites the oldest via the round-robin cursor so a burst
// never silently drops everything. Cosmetic, so overwrite-oldest is fine.
fn spawnParticle(state: *State, p: Particle) void {
    const w = &state.world;
    if (w.particle_count < max_particles) {
        w.particles[w.particle_count] = p;
        w.particle_count += 1;
    } else {
        w.particles[w.particle_cursor] = p;
        w.particle_cursor = (w.particle_cursor + 1) % max_particles;
    }
}

// Helper: a uniform random f32 in [lo, hi) from the World RNG.
fn randRange(state: *State, lo: f32, hi: f32) f32 {
    const r = state.world.rng.random().float(f32);
    return lo + r * (hi - lo);
}

// Emit `n` particles from `rect`'s center, flung outward. speed_lo/hi (tiles/s)
// and life_lo/hi (s) set the spreads; `use_gravity` arcs them (debris) vs floats
// (sparks); colors are sampled from `sprite`, lightened by `brighten`.
fn emitBurst(
    state: *State,
    rect: rl.Rectangle,
    sprite: Sprite,
    n: u32,
    speed_lo: f32,
    speed_hi: f32,
    life_lo: f32,
    life_hi: f32,
    use_gravity: bool,
    brighten: f32, // 0 = texture color as-is; >0 lightens toward white (sparkle)
    size: f32,
) void {
    const cx = rect.x + rect.width / 2;
    const cy = rect.y + rect.height / 2;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const ang = randRange(state, 0, std.math.tau);
        const spd = randRange(state, speed_lo, speed_hi) * tile;
        const life = randRange(state, life_lo, life_hi);
        // Jitter the origin a little within the rect so the burst isn't a point.
        const ox = cx + randRange(state, -rect.width / 4, rect.width / 4);
        const oy = cy + randRange(state, -rect.height / 4, rect.height / 4);
        // Color this particle from a random opaque texel of the source sprite.
        var tint = sampleSpriteColor(state, sprite);
        if (brighten > 0) tint = lighten(tint, brighten);
        spawnParticle(state, .{
            .pos = .{ .x = ox, .y = oy },
            .vel = .{ .x = @cos(ang) * spd, .y = @sin(ang) * spd },
            .life = life,
            .life0 = life,
            .size = size,
            .tint = tint,
            .gravity = use_gravity,
        });
    }
}

// Sample a representative color from a sprite's atlas cell: pick random pixels
// and return the first opaque one (so transparent background texels don't wash
// the burst gray). Reads the CPU-side atlas image kept on State. Falls back to
// white if the cell is fully transparent or no opaque texel is found in a few
// tries. `tile`-sized cells, so the search is cheap.
fn sampleSpriteColor(state: *State, sprite: Sprite) rl.Color {
    const sr = sprite.src(); // atlas pixel rect for this sprite
    const x0: i32 = @intFromFloat(sr.x);
    const y0: i32 = @intFromFloat(sr.y);
    const w: i32 = @intFromFloat(sr.width);
    const h: i32 = @intFromFloat(sr.height);
    var tries: u32 = 0;
    while (tries < 8) : (tries += 1) {
        const px = x0 + @as(i32, @intFromFloat(randRange(state, 0, @floatFromInt(w))));
        const py = y0 + @as(i32, @intFromFloat(randRange(state, 0, @floatFromInt(h))));
        const c = rl.getImageColor(state.atlas_img, px, py);
        if (c.a >= 128) return .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 };
    }
    return .{ .r = 255, .g = 255, .b = 255, .a = 255 };
}

// Lerp a color toward white by `t` (0..1), preserving alpha. Used to give the
// clone sparkle a brighter, more energetic look than the raw texture color.
fn lighten(c: rl.Color, t: f32) rl.Color {
    const lr: f32 = @floatFromInt(c.r);
    const lg: f32 = @floatFromInt(c.g);
    const lb: f32 = @floatFromInt(c.b);
    return .{
        .r = @intFromFloat(lr + (255 - lr) * t),
        .g = @intFromFloat(lg + (255 - lg) * t),
        .b = @intFromFloat(lb + (255 - lb) * t),
        .a = c.a,
    };
}

// Clone spawn effect: a quick, light, upward-biased sparkle. Colors are sampled
// from the cloned object's own texture, then lightened so the burst reads as
// energetic materialization rather than flat debris.
fn spawnCloneBurst(state: *State, rect: rl.Rectangle, sprite: Sprite) void {
    emitBurst(state, rect, sprite, 18, 1.5, 5.0, 0.25, 0.5, false, 0.45, 1);
}

// Death effect: a heavier debris burst with gravity, longer life. Colors come
// straight from the destroyed object's texture (no brighten) so it shatters into
// bits of itself.
fn spawnDeathBurst(state: *State, rect: rl.Rectangle, sprite: Sprite) void {
    emitBurst(state, rect, sprite, 28, 2.0, 8.0, 0.4, 0.9, true, 0.0, 2);
}

// Integrate every live particle: gravity (if any), Euler position step, age.
// Dead particles are swap-removed from the live prefix so the pool stays packed.
fn updateParticles(state: *State, dt: f32) void {
    const w = &state.world;
    var i: usize = 0;
    while (i < w.particle_count) {
        const p = &w.particles[i];
        p.life -= dt;
        if (p.life <= 0) {
            // Swap-remove: move the last live particle into this slot, shrink.
            w.particle_count -= 1;
            w.particles[i] = w.particles[w.particle_count];
            continue; // re-process the swapped-in particle at this index
        }
        if (p.gravity) p.vel.y += particle_gravity * dt;
        p.pos.x += p.vel.x * dt;
        p.pos.y += p.vel.y * dt;
        i += 1;
    }
}

// Draw every live particle as a tinted square of `size` px, alpha fading with
// remaining life. Positions are rounded to whole pixels so particles stay crisp
// under the integer upscale. Called inside the camera transform so they move
// with the world. One texture (the white cell) for all, so no atlas swaps.
fn drawParticles(state: *State) void {
    const src = whitePixelSrc();
    const w = &state.world;
    for (w.particles[0..w.particle_count]) |p| {
        var tint = p.tint;
        // Fade out over the last portion of life (alpha tracks life fraction).
        const frac = p.life / p.life0;
        tint.a = @intFromFloat(@max(0, @min(255, frac * 255)));
        const dest = rl.Rectangle{
            .x = @round(p.pos.x - p.size / 2),
            .y = @round(p.pos.y - p.size / 2),
            .width = p.size,
            .height = p.size,
        };
        rl.drawTexturePro(state.atlas, src, dest, .{ .x = 0, .y = 0 }, 0, tint);
    }
}

// Seed the foreground dust motes at random screen positions with gentle,
// slightly varied drift. Done once (lazily, so the RNG is available); thereafter
// updateDust just advects and wraps them.
fn seedDust(state: *State) void {
    const w = &state.world;
    for (&w.dust) |*d| {
        d.* = .{
            .pos = .{ .x = randRange(state, 0, virtual_w), .y = randRange(state, 0, virtual_h) },
            .vel = .{
                .x = randRange(state, -dust_drift_x, dust_drift_x),
                .y = randRange(state, dust_drift_y * 0.3, dust_drift_y),
            },
            .size = if (randRange(state, 0, 1) < 0.5) 1 else 2,
            .phase = randRange(state, 0, std.math.tau),
            // Color from the background texture, lightened so motes stay airy
            // rather than as dark as the backdrop itself.
            .color = lighten(sampleSpriteColor(state, sprite_background), 0.4),
        };
    }
    w.dust_seeded = true;
}

// Advect dust in screen space and wrap it around the edges so motes drift
// forever. Screen-space (virtual-resolution) coordinates, independent of the
// world camera. Seeds on first call.
fn updateDust(state: *State, dt: f32) void {
    const w = &state.world;
    if (!w.dust_seeded) seedDust(state);
    for (&w.dust) |*d| {
        d.pos.x += d.vel.x * dt;
        d.pos.y += d.vel.y * dt;
        // Wrap around the virtual screen (with a small margin so the size-2
        // motes don't pop at the very edge).
        if (d.pos.x < -2) d.pos.x += virtual_w + 4;
        if (d.pos.x > virtual_w + 2) d.pos.x -= virtual_w + 4;
        if (d.pos.y < -2) d.pos.y += virtual_h + 4;
        if (d.pos.y > virtual_h + 2) d.pos.y -= virtual_h + 4;
    }
}

// Draw the foreground dust in SCREEN space (no camera) over everything else.
// A slow per-mote twinkle modulates alpha so the field shimmers faintly. Uses
// the same white-pixel source as particles. `t` is elapsed time for the twinkle.
fn drawDust(state: *State, t: f32) void {
    const src = whitePixelSrc();
    const w = &state.world;
    for (w.dust) |d| {
        const tw = 0.5 + 0.5 * @sin(t * 1.5 + d.phase); // 0..1 twinkle
        const a: u8 = @intFromFloat(@max(0, @min(255, (0.15 + 0.35 * tw) * 255)));
        const tint = rl.Color{ .r = d.color.r, .g = d.color.g, .b = d.color.b, .a = a };
        const dest = rl.Rectangle{
            .x = @round(d.pos.x),
            .y = @round(d.pos.y),
            .width = d.size,
            .height = d.size,
        };
        rl.drawTexturePro(state.atlas, src, dest, .{ .x = 0, .y = 0 }, 0, tint);
    }
}

// A pseudo-random threshold in [0,1) for grid cell (cx, cy). Deterministic hash
// so the pixelated wipe fills/clears cells in a fixed scattered order rather than
// a boring left-to-right sweep.
fn wipeThreshold(cx: i32, cy: i32) f32 {
    var h: u32 = @bitCast(cx *% 374761393 +% cy *% 668265263);
    h = (h ^ (h >> 13)) *% 1274126177;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h & 0xFFFF)) / 65536.0;
}

// Pixelated death transition. Covers the screen black cell-by-cell during the
// `cover` phase (coverage 0→1) and clears it during `reveal` (1→0), in screen
// space over everything. Each cell flips based on its fixed threshold vs the
// current coverage, so the screen dissolves in chunky blocks — a pixel-art cut.
fn drawDeathWipe(state: *State) void {
    const w = &state.world;
    const coverage: f32 = switch (w.death_phase) {
        .cover => @min(1.0, w.death_timer / death_cover_time), // 0 → 1
        .reveal => 1.0 - @min(1.0, w.death_timer / death_reveal_time), // 1 → 0
        else => return, // none/hold: nothing drawn
    };
    if (coverage <= 0) return;

    const src = whitePixelSrc();
    var cy: i32 = 0;
    var y: f32 = 0;
    while (y < virtual_h) : (y += death_wipe_cell) {
        var cx: i32 = 0;
        var x: f32 = 0;
        while (x < virtual_w) : (x += death_wipe_cell) {
            if (wipeThreshold(cx, cy) < coverage) {
                const dest = rl.Rectangle{ .x = x, .y = y, .width = death_wipe_cell, .height = death_wipe_cell };
                rl.drawTexturePro(state.atlas, src, dest, .{ .x = 0, .y = 0 }, 0, .black);
            }
            cx += 1;
        }
        cy += 1;
    }
}

// Draw a sprite from the atlas into a world-space destination rectangle.
// `flip_x` mirrors horizontally (raylib flips when the source width is negative).
fn drawSprite(atlas: rl.Texture2D, sprite: Sprite, dest: rl.Rectangle, tint: rl.Color, flip_x: bool) void {
    var source = sprite.src();
    if (flip_x) source.width = -source.width;
    rl.drawTexturePro(atlas, source, dest, .{ .x = 0, .y = 0 }, 0, tint);
}

// Degrees a spike is rotated for a given visual direction. Reuses GateDir as a
// 4-way selector only; spikes have no gate behavior.
fn spikeRotation(dir: GateDir) f32 {
    return switch (dir) {
        .up => 0,
        .down => 90,
        .left => 180,
        .right => 270,
    };
}

// Draw a sprite rotated `deg` degrees about its own center, in place. Used for
// spikes (rotation is purely cosmetic). drawTexturePro rotates around `origin`,
// so we set the origin to the cell center and shift dest by the same amount.
fn drawSpriteRotated(atlas: rl.Texture2D, sprite: Sprite, dest: rl.Rectangle, tint: rl.Color, deg: f32) void {
    const source = sprite.src();
    const centered = rl.Rectangle{
        .x = dest.x + dest.width / 2,
        .y = dest.y + dest.height / 2,
        .width = dest.width,
        .height = dest.height,
    };
    rl.drawTexturePro(atlas, source, centered, .{ .x = dest.width / 2, .y = dest.height / 2 }, deg, tint);
}

// Draw a gate cell that is wholly or partly open. The whole gate slides as one
// unit toward its open edge by an offset measured against the full gate length
// (so multi-cell gates move together), clipped at the gate's frame edge. A
// gate_stick_out sliver is left visible even when fully open. Source and dest
// sub-rects match in size, so the sprite slides rigidly without scaling.
// Map a gate's linear open_amount (0..1) to an eased slide position that SLAMS:
// motion is slow at the start of a transition and accelerates into the endpoint,
// so a gate whips open and bangs shut instead of sliding at constant speed. The
// direction of travel (open vs close) is read from prev_open_amount, easing
// toward whichever end the gate is heading for. Fully-settled gates (no change)
// pass through uneased.
fn gateSlamEase(e: Entity) f32 {
    const a = e.open_amount;
    const closing = a < e.prev_open_amount;
    const opening = a > e.prev_open_amount;
    if (opening) {
        // Heading to 1 (open): ease-in, accelerating as it nears fully open.
        return a * a * a;
    } else if (closing) {
        // Heading to 0 (closed): ease-in toward 0 — slow release, hard slam.
        // Equivalent to flipping the ease-in curve around the 1->0 direction.
        const inv = 1 - a;
        return 1 - inv * inv * inv;
    }
    return a; // settled (0 or 1): no easing needed
}

fn drawGateSlide(atlas: rl.Texture2D, e: Entity) void {
    const g = e.gate_rect;
    const c = e.rect;
    const s0 = e.sprite.src();

    const axis_len = switch (e.dir) {
        .up, .down => g.height,
        .left, .right => g.width,
    };
    const o = gateSlamEase(e) * (axis_len - gate_stick_out); // eased slide distance

    var src = s0;
    var dst = c;
    switch (e.dir) {
        .up => {
            const new_y = c.y - o;
            if (new_y + c.height <= g.y) return; // slid fully past the frame top
            const clipped = @max(g.y - new_y, 0); // hidden above the frame
            const frac = clipped / c.height;
            src.y = s0.y + frac * s0.height;
            src.height = s0.height * (1 - frac);
            dst.y = new_y + clipped;
            dst.height = c.height - clipped;
        },
        .down => {
            const new_y = c.y + o;
            if (new_y >= g.y + g.height) return;
            const clipped = @max((new_y + c.height) - (g.y + g.height), 0);
            const frac = clipped / c.height;
            src.height = s0.height * (1 - frac);
            dst.y = new_y;
            dst.height = c.height - clipped;
        },
        .left => {
            const new_x = c.x - o;
            if (new_x + c.width <= g.x) return;
            const clipped = @max(g.x - new_x, 0);
            const frac = clipped / c.width;
            src.x = s0.x + frac * s0.width;
            src.width = s0.width * (1 - frac);
            dst.x = new_x + clipped;
            dst.width = c.width - clipped;
        },
        .right => {
            const new_x = c.x + o;
            if (new_x >= g.x + g.width) return;
            const clipped = @max((new_x + c.width) - (g.x + g.width), 0);
            const frac = clipped / c.width;
            src.width = s0.width * (1 - frac);
            dst.x = new_x;
            dst.width = c.width - clipped;
        },
    }
    rl.drawTexturePro(atlas, src, dst, .{ .x = 0, .y = 0 }, 0, e.tint);
}

// Draw one entity, choosing its sprite from interactive state and routing
// through the spawn-mask shader while it is materializing or vanishing.
fn drawEntity(state: *State, e: Entity) void {
    // Spikes: rotation is purely visual (`dir` reused as a 4-way selector).
    // Clones still draw through the ripple shader for the ghostly look; the
    // sprite is just oriented within it.
    if (e.kind == .spike) {
        const deg = spikeRotation(e.dir);
        if (e.is_clone) {
            beginCloneRipple(state, e, e.sprite);
            drawSpriteRotated(state.atlas, e.sprite, e.rect, e.tint, deg);
            rl.endShaderMode();
        } else {
            drawSpriteRotated(state.atlas, e.sprite, e.rect, e.tint, deg);
        }
        return;
    }

    // Checkpoint: idle sprite when inactive; the activation flourish plays once
    // and rests on the last (active) frame, the deactivation flourish plays in
    // reverse and rests on the idle frame. `dir == .right` mirrors all art.
    if (e.kind == .book) {
        const spr = if (e.cp_anim_playing)
            checkpoint_anim_frames[e.cp_anim_frame]
        else if (e.cp_active)
            checkpoint_anim_frames[checkpoint_anim_frames.len - 1]
        else
            sprite_checkpoint;
        drawSprite(state.atlas, spr, e.rect, e.tint, e.dir == .right);
        return;
    }

    const spr = switch (e.role) {
        .button => if (e.pressed) sprite_button_down else sprite_button_up,
        .none, .gate => if (e.kind == .cart) cart_anim_frames[e.cart_frame] else e.sprite,
    };

    const gate_opening = e.role == .gate and e.open_amount > 0 and e.mask_phase == .none;

    if (gate_opening and !e.is_clone) {
        // Opening/closing gate (not a clone): slide-and-clip the closed sprite.
        drawGateSlide(state.atlas, e);
    } else if (e.is_clone) {
        // Clones draw through the ripple shader (transparent + shine; dissolve
        // mask during spawn/vanish). A mid-open cloned gate also slides/clips
        // under the shader so it animates open while keeping the clone look.
        beginCloneRipple(state, e, spr);
        if (gate_opening) {
            drawGateSlide(state.atlas, e);
        } else {
            drawSprite(state.atlas, spr, e.rect, e.tint, false);
        }
        rl.endShaderMode();
    } else if (e.mask_phase != .none) {
        // A non-clone mid-mask (none today, but keep the path): plain mask draw.
        const atlas_w: f32 = @floatFromInt(state.atlas.width);
        const atlas_h: f32 = @floatFromInt(state.atlas.height);
        const sr = spr.src();
        const mr = clone_mask_frames[e.mask_frame].src();
        const sprite_rect = [4]f32{ sr.x / atlas_w, sr.y / atlas_h, sr.width / atlas_w, sr.height / atlas_h };
        const mask_rect = [4]f32{ mr.x / atlas_w, mr.y / atlas_h, mr.width / atlas_w, mr.height / atlas_h };
        rl.setShaderValue(state.mask_shader, state.loc_sprite_rect, &sprite_rect, .vec4);
        rl.setShaderValue(state.mask_shader, state.loc_mask_rect, &mask_rect, .vec4);
        rl.beginShaderMode(state.mask_shader);
        drawSprite(state.atlas, spr, e.rect, e.tint, false);
        rl.endShaderMode();
    } else {
        drawSprite(state.atlas, spr, e.rect, e.tint, false);
    }
}

// Set the ripple shader's uniforms for clone `e` and enter shader mode. The
// caller issues the draw call(s) — a plain sprite, or a slide-clipped gate — and
// must call rl.endShaderMode() afterward. Split from the draw so a cloned gate
// can slide/clip while still rendering through the ripple. Transparent + animated
// shine; during spawn/vanish the dissolve mask is applied too.
fn beginCloneRipple(state: *State, e: Entity, spr: Sprite) void {
    const atlas_w: f32 = @floatFromInt(state.atlas.width);
    const atlas_h: f32 = @floatFromInt(state.atlas.height);
    const sr = spr.src();
    const sprite_rect = [4]f32{ sr.x / atlas_w, sr.y / atlas_h, sr.width / atlas_w, sr.height / atlas_h };
    const t: f32 = @floatCast(rl.getTime());
    const base_alpha: f32 = 0.7; // overall clone transparency (higher = more solid)

    const masking = e.mask_phase != .none;
    const use_mask: f32 = if (masking) 1 else 0;
    // Mask cell only matters while masking; pass a valid one regardless.
    const mframe = if (masking) e.mask_frame else 0;
    const mr = clone_mask_frames[mframe].src();
    const mask_rect = [4]f32{ mr.x / atlas_w, mr.y / atlas_h, mr.width / atlas_w, mr.height / atlas_h };

    rl.setShaderValue(state.ripple_shader, state.loc_ripple_sprite_rect, &sprite_rect, .vec4);
    rl.setShaderValue(state.ripple_shader, state.loc_ripple_time, &t, .float);
    rl.setShaderValue(state.ripple_shader, state.loc_ripple_alpha, &base_alpha, .float);
    rl.setShaderValue(state.ripple_shader, state.loc_ripple_mask_rect, &mask_rect, .vec4);
    rl.setShaderValue(state.ripple_shader, state.loc_ripple_use_mask, &use_mask, .float);
    rl.beginShaderMode(state.ripple_shader);
}

fn draw(state: *State) void {
    rl.clearBackground(.{ .r = 30, .g = 30, .b = 40, .a = 255 });

    // Background layer: decorative tiles filling the screen, drawn in screen
    // space (no camera) so the backdrop is the same in every room.
    var by: f32 = 0;
    while (by < virtual_h) : (by += tile) {
        var bx: f32 = 0;
        while (bx < virtual_w) : (bx += tile) {
            drawSprite(state.atlas, sprite_background, .{ .x = bx, .y = by, .width = tile, .height = tile }, .white, false);
        }
    }

    // Room camera. The world is many screens; the view snaps to the room
    // containing the player's center. target = room origin, so on-screen
    // position = world position - room origin = world position mod screen size.
    const p = state.player();
    // During the death sequence the camera is locked to where the player died,
    // so the hold lingers on the death spot and the cover wipe doesn't jump to
    // the respawn room until reveal (which reseats death_cam to the new room).
    const origin = if (state.world.death_phase == .none or state.world.death_phase == .reveal)
        roomOrigin(p.rect.x + p.rect.width / 2, p.rect.y + p.rect.height / 2)
    else
        state.world.death_cam;
    const cam = rl.Camera2D{
        .target = origin,
        .offset = .{ .x = 0, .y = 0 },
        .rotation = 0,
        .zoom = 1,
    };
    rl.beginMode2D(cam);

    // Cubes, in two passes so buttons render behind everything else — boxes and
    // the player draw in front of a button sharing its cell.
    for (state.entities().slots.items) |s| {
        if (s.alive and s.entity.role == .button) drawEntity(state, s.entity);
    }
    for (state.entities().slots.items) |s| {
        if (s.alive and s.entity.role != .button) drawEntity(state, s.entity);
    }

    // Player: cast frame while casting, otherwise the current walk frame;
    // mirrored when facing left. Hidden during the death hold/cover (the body has
    // "died" and burst into particles); it reappears at respawn under the reveal.
    const dp = state.world.death_phase;
    if (dp != .hold and dp != .cover) {
        const player_sprite = if (p.casting)
            player_cast_frames[p.cast_frame]
        else if (p.pushing)
            player_push_frames[p.push_frame]
        else
            player_walk_frames[p.anim_frame];
        drawSprite(state.atlas, player_sprite, p.rect, .white, p.facing < 0);
    }

    // Cosmetic particles, on top of bodies, inside the camera so they track the
    // world. Drawn after the player so spawn/death bursts read clearly.
    drawParticles(state);

    // Edit-mode hovered-cell highlight, or the drag rectangle while dragging.
    if (state.edit_mode) {
        // Player-start marker: a green outlined cell where the player will spawn.
        const sr = cellRect(state.doc.start_cell[0], state.doc.start_cell[1]);
        rl.drawRectangleRec(sr, .{ .r = 80, .g = 220, .b = 120, .a = 70 });
        rl.drawRectangleLinesEx(sr, 1, .{ .r = 80, .g = 255, .b = 120, .a = 230 });

        const world = mouseWorld(state);
        const gx: i32 = @intFromFloat(@floor(world.x / tile));
        const gy: i32 = @intFromFloat(@floor(world.y / tile));
        var rx = gx;
        var ry = gy;
        var rw: i32 = 1;
        var rh: i32 = 1;
        if (state.drag_start) |ds| {
            rx = @min(ds[0], gx);
            ry = @min(ds[1], gy);
            rw = @intCast(@abs(gx - ds[0]) + 1);
            rh = @intCast(@abs(gy - ds[1]) + 1);
        }
        const area = rl.Rectangle{
            .x = @as(f32, @floatFromInt(rx)) * tile,
            .y = @as(f32, @floatFromInt(ry)) * tile,
            .width = @as(f32, @floatFromInt(rw)) * tile,
            .height = @as(f32, @floatFromInt(rh)) * tile,
        };
        rl.drawRectangleRec(area, .{ .r = 255, .g = 255, .b = 255, .a = 60 });
        rl.drawRectangleLinesEx(area, 1, .{ .r = 255, .g = 255, .b = 0, .a = 220 });

        // Committed selection: a cyan box (the source region for copy/cut).
        if (state.selection) |sel| {
            const srect = rl.Rectangle{
                .x = @as(f32, @floatFromInt(sel[0])) * tile,
                .y = @as(f32, @floatFromInt(sel[1])) * tile,
                .width = @as(f32, @floatFromInt(sel[2])) * tile,
                .height = @as(f32, @floatFromInt(sel[3])) * tile,
            };
            rl.drawRectangleRec(srect, .{ .r = 0, .g = 200, .b = 255, .a = 50 });
            rl.drawRectangleLinesEx(srect, 1, .{ .r = 0, .g = 220, .b = 255, .a = 230 });
        }

        // Paste preview: while Ctrl is held with a non-empty clipboard, outline
        // where a paste would land (top-left at the hovered cell).
        const ctrl_held = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
        if (ctrl_held and state.clipboard.items.len > 0) {
            const prect = rl.Rectangle{
                .x = @as(f32, @floatFromInt(gx)) * tile,
                .y = @as(f32, @floatFromInt(gy)) * tile,
                .width = @as(f32, @floatFromInt(state.clip_w)) * tile,
                .height = @as(f32, @floatFromInt(state.clip_h)) * tile,
            };
            rl.drawRectangleRec(prect, .{ .r = 255, .g = 160, .b = 0, .a = 50 });
            rl.drawRectangleLinesEx(prect, 1, .{ .r = 255, .g = 180, .b = 0, .a = 230 });
        }
    }

    rl.endMode2D();

    // Foreground dust: screen space, over the world, under the editor HUD. Only
    // in play mode (the editor wants a clean, static grid view).
    if (!state.edit_mode) {
        drawDust(state, @floatCast(rl.getTime()));
    }

    // Pixelated death transition: a cell-by-cell black wipe in screen space, over
    // everything. Fills during cover, clears during reveal.
    drawDeathWipe(state);

    // Edit-mode palette label (screen space).
    if (state.edit_mode) {
        const name = switch (state.palette) {
            .brick => "1:BRICK",
            .cart => "2:CART",
            .window => "3:WINDOW",
            .button => "4:BUTTON",
            .gate => "5:GATE",
            .start => "6:START",
            .flower => "7:FLOWER",
            .spike => "8:SPIKE",
            .book => "9:BOOK",
            .eraser => "0:ERASER",
            .select => "Q:SELECT",
        };
        rl.drawText("EDIT (Tab)", 4, 4, 10, .ray_white);
        rl.drawText(name, 4, 16, 10, .yellow);
        if (state.palette == .gate) {
            const dir = switch (state.edit_gate_dir) {
                .up => "R:dir UP",
                .down => "R:dir DOWN",
                .left => "R:dir LEFT",
                .right => "R:dir RIGHT",
            };
            rl.drawText(dir, 4, 28, 10, .yellow);
        }
        if (state.palette == .spike) {
            const rot = switch (state.edit_gate_dir) {
                .up => "R:rot 0",
                .down => "R:rot 90",
                .left => "R:rot 180",
                .right => "R:rot 270",
            };
            rl.drawText(rot, 4, 28, 10, .yellow);
        }
        if (state.palette == .book) {
            // Only .right flips; everything else faces left.
            const face = if (state.edit_gate_dir == .right) "R:face RIGHT" else "R:face LEFT";
            rl.drawText(face, 4, 28, 10, .yellow);
        }
        if (state.palette == .select) {
            rl.drawText("drag to select", 4, 28, 10, .yellow);
            rl.drawText("Ctrl C/X/V copy/cut/paste", 4, 52, 10, .gray);
        }
        rl.drawText("F5 save  RMB erase  Ctrl+Z undo", 4, 40, 10, .gray);
    }
}
