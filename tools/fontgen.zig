const std = @import("std");
const c = @cImport({
    @cInclude("hb.h");
    @cInclude("hb-ot.h");
    @cInclude("freetype/freetype.h");
});

const min_char = ' ';
const max_char = '~';

const disabled_features = [_][]const u8{ "liga", "clig", "calt", "dlig" };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.InvalidArguments;
    const output_path = args[1];

    var output_file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer output_file.close(io);
    var buffer: [1024]u8 = undefined;
    var output = output_file.writer(io, &buffer);

    try output.interface.writeAll(
        \\pub const Font = struct {
        \\    chars: []const ?Char,
        \\    center: i32,
        \\    baseline: i32,
        \\    bottom: i32,
        \\};
        \\
        \\pub const Char = struct {
        \\    bitmap: []const []const u8,
        \\    top: i32,
        \\    left: i32,
        \\    width: i32,
        \\    advance: []const ?i32,
        \\};
        \\
    );

    var features: [disabled_features.len]c.hb_feature_t = undefined;
    for (disabled_features, &features) |name, *feature| {
        try hbCheck(c.hb_feature_from_string(name.ptr, @intCast(name.len), feature));
        feature.value = 0;
    }

    const buf = c.hb_buffer_create().?;
    try hbCheck(c.hb_buffer_allocation_successful(buf));
    defer c.hb_buffer_destroy(buf);

    var library: c.FT_Library = null;
    try ftCheck(c.FT_Init_FreeType(&library));
    defer _ = c.FT_Done_FreeType(library);

    for (args[2..]) |font_spec| {
        const colon = std.mem.find(u8, font_spec, ":") orelse
            return error.InvalidArguments;

        const path = font_spec[0..colon];
        const path_sentinel = try arena.dupeSentinel(u8, path, 0);
        const file_name = std.fs.path.basename(path);
        const dot = std.mem.find(u8, file_name, ".") orelse
            return error.InvalidArguments;
        const name = file_name[0..dot];

        const blob = try hbCheck(c.hb_blob_create_from_file_or_fail(path_sentinel.ptr));
        defer c.hb_blob_destroy(blob);

        const face = try hbCheck(c.hb_face_create(blob, 0));
        defer c.hb_face_destroy(face);

        const font = c.hb_font_create(face);
        defer c.hb_font_destroy(font);

        var ft_face: c.FT_Face = null;
        try ftCheck(c.FT_New_Face(library, path_sentinel.ptr, 0, &ft_face));
        defer _ = c.FT_Done_Face(ft_face);

        var sizes = font_spec[colon + 1 ..];
        while (sizes.len > 0) {
            const comma = std.mem.find(u8, sizes, ",") orelse sizes.len;
            const size_str = sizes[0..comma];
            sizes = sizes[@min(sizes.len, comma + 1)..];

            const size = std.fmt.parseInt(c_uint, size_str, 10) catch
                return error.InvalidArguments;
            try generateFont(
                &output.interface,
                font,
                ft_face,
                buf,
                &features,
                name,
                size,
            );
        }
    }

    try output.flush();
}

fn generateFont(
    w: *std.Io.Writer,
    font: ?*c.hb_font_t,
    face: c.FT_Face,
    buf: *c.hb_buffer_t,
    features: []const c.hb_feature_t,
    name: []const u8,
    size: c_uint,
) !void {
    const scale: c_int = @intCast(size * 64);
    c.hb_font_set_scale(font, scale, scale);
    try ftCheck(c.FT_Set_Pixel_Sizes(face, 0, size));

    for (min_char..max_char + 1) |char| {
        var glyph: c.hb_codepoint_t = undefined;
        try hbCheck(c.hb_font_get_nominal_glyph(font, @intCast(char), &glyph));
    }

    const metrics = face.*.size.*.metrics;
    const ascender: c_int = @intCast(metrics.ascender >> 6);
    const descender: c_int = @intCast(metrics.descender >> 6);

    const baseline = ascender;
    const bottom_line = ascender - descender;

    var cap_height: c.hb_position_t = 0;
    c.hb_ot_metrics_get_position_with_fallback(
        font,
        c.HB_OT_METRICS_TAG_CAP_HEIGHT,
        &cap_height,
    );
    const center_line = baseline - @divFloor(cap_height + 64, 128);

    try w.print("pub const {s}{}: Font = ", .{ name, size });
    try w.print(
        ".{{ .center = {}, .baseline = {}, .bottom = {}, .chars = &.{{\n",
        .{ center_line, baseline, bottom_line },
    );

    for (0..256) |left| {
        if (left < min_char or left > max_char) {
            try w.writeAll("null,\n");
            continue;
        }

        const width = try getAdvance(font, buf, features, &.{@intCast(left)});
        try w.print(".{{ .width = {}, .advance = &.{{", .{width});
        for (0..256) |right| {
            if (right < min_char or right > max_char) {
                try w.writeAll("null,");
                continue;
            } else {
                const advance = try getAdvance(
                    font,
                    buf,
                    features,
                    &.{ @intCast(left), @intCast(right) },
                );
                try w.print("{},", .{advance});
            }
        }
        try w.writeAll("},\n");

        try writeBitmap(w, face, @intCast(left), baseline);
        try w.writeAll(" },\n");
    }

    try w.writeAll("}};\n");
}

fn writeBitmap(w: *std.Io.Writer, face: c.FT_Face, char: u8, baseline: c_int) !void {
    try ftCheck(c.FT_Load_Char(face, char, c.FT_LOAD_RENDER));
    const bitmap = face.*.glyph.*.bitmap;
    if (bitmap.rows != 0 and bitmap.pixel_mode != c.FT_PIXEL_MODE_GRAY)
        return error.UnexpectedPixelMode;
    if (bitmap.pitch < 0) return error.UnexpectedPitch;
    const glyph = face.*.glyph;
    const pitch: usize = @intCast(bitmap.pitch);

    var first_row: usize = bitmap.rows;
    var last_row: usize = 0;
    var first_col: usize = bitmap.width;
    var last_col: usize = 0;
    for (0..bitmap.rows) |row| {
        for (0..bitmap.width) |col| {
            if (bitmap.buffer[row * pitch + col] == 0) continue;
            first_row = @min(first_row, row);
            last_row = row;
            first_col = @min(first_col, col);
            last_col = @max(last_col, col);
        }
    }

    if (first_row == bitmap.rows) {
        try w.writeAll(".bitmap = &.{}, .top = 0, .left = 0,");
        return;
    }

    try w.writeAll(".bitmap = &.{");
    for (first_row..last_row + 1) |row| {
        try w.writeAll("&.{");
        for (first_col..last_col + 1) |col| {
            try w.print("{},", .{bitmap.buffer[row * pitch + col]});
        }
        try w.writeAll("},");
    }
    try w.writeAll("},");

    const top = baseline - glyph.*.bitmap_top + @as(c_int, @intCast(first_row));
    const left = glyph.*.bitmap_left + @as(c_int, @intCast(first_col));
    try w.print(" .top = {}, .left = {},", .{ top, left });
}

fn getAdvance(
    font: ?*c.hb_font_t,
    buf: *c.hb_buffer_t,
    features: []const c.hb_feature_t,
    chars: []const c.hb_codepoint_t,
) !i32 {
    c.hb_buffer_clear_contents(buf);
    c.hb_buffer_add_codepoints(buf, chars.ptr, @intCast(chars.len), 0, @intCast(chars.len));
    c.hb_buffer_set_direction(buf, c.HB_DIRECTION_LTR);
    c.hb_buffer_set_script(buf, c.HB_SCRIPT_LATIN);
    c.hb_buffer_set_language(buf, c.hb_language_from_string("en", -1));
    try hbCheck(c.hb_shape_full(font, buf, features.ptr, @intCast(features.len), null));

    var len: c_uint = 0;
    const positions = c.hb_buffer_get_glyph_positions(buf, &len);
    if (len != chars.len) return error.UnexpectedGlyphCount;

    return @intCast(@divFloor(positions[0].x_advance + 32, 64));
}

fn HbCheck(R: anytype) type {
    return switch (@typeInfo(R)) {
        .optional => |opt| opt.child,
        else => void,
    };
}

fn hbCheck(r: anytype) !HbCheck(@TypeOf(r)) {
    return switch (@typeInfo(@TypeOf(r))) {
        .optional => r orelse error.HarfBuzzError,
        .int => if (r == 0) error.HarfBuzzError,
        else => @compileError("bad HarfBuzz return type"),
    };
}

fn ftCheck(r: c.FT_Error) !void {
    if (r != 0) return error.FreeTypeError;
}
