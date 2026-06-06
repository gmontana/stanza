//! UTF-8 helpers: codepoint sequencing, tolerant decoding, and terminal
//! display width.
//!
//! Width follows the common wcwidth conventions: C0/C1 controls and combining
//! marks are zero cells, CJK and emoji ranges are two cells, everything else is
//! one. The tables are compact and are not a full Unicode database.

const std = @import("std");

/// Number of bytes in the UTF-8 sequence that begins with `first`. Returns 1
/// for invalid lead bytes so callers always make forward progress.
pub fn seqLen(first: u8) usize {
    return std.unicode.utf8ByteSequenceLength(first) catch 1;
}

/// Decode the codepoint at the start of `bytes`, falling back to the
/// replacement character on malformed input so editing never aborts.
pub fn decode(bytes: []const u8) u21 {
    if (bytes.len == 0) return 0xFFFD;
    const len = seqLen(bytes[0]);
    if (len > bytes.len) return 0xFFFD;
    return std.unicode.utf8Decode(bytes[0..len]) catch 0xFFFD;
}

/// True for UTF-8 continuation bytes (0b10xxxxxx).
pub fn isCont(b: u8) bool {
    return b & 0xc0 == 0x80;
}

/// Terminal cells occupied by a single codepoint.
pub fn cpWidth(cp: u21) usize {
    if (cp == 0) return 0;
    if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return 0;
    if (isCombining(cp)) return 0;
    if (isWide(cp)) return 2;
    return 1;
}

/// Display width of a UTF-8 string in terminal cells.
pub fn strWidth(bytes: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const end = @min(i + seqLen(bytes[i]), bytes.len);
        total += cpWidth(decode(bytes[i..end]));
        i = end;
    }
    return total;
}

fn isCombining(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036f) or
        (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or
        (cp >= 0x20d0 and cp <= 0x20ff) or
        (cp >= 0xfe20 and cp <= 0xfe2f);
}

fn isWide(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115f) or // Hangul Jamo
        (cp >= 0x2e80 and cp <= 0x303e) or // CJK radicals .. punctuation
        (cp >= 0x3041 and cp <= 0x33ff) or // Hiragana .. CJK symbols
        (cp >= 0x3400 and cp <= 0x4dbf) or // CJK Ext A
        (cp >= 0x4e00 and cp <= 0x9fff) or // CJK Unified
        (cp >= 0xa000 and cp <= 0xa4cf) or // Yi
        (cp >= 0xac00 and cp <= 0xd7a3) or // Hangul syllables
        (cp >= 0xf900 and cp <= 0xfaff) or // CJK compatibility
        (cp >= 0xfe30 and cp <= 0xfe4f) or // CJK compatibility forms
        (cp >= 0xff00 and cp <= 0xff60) or // fullwidth forms
        (cp >= 0xffe0 and cp <= 0xffe6) or
        (cp >= 0x1f300 and cp <= 0x1faff) or // emoji and symbols
        (cp >= 0x20000 and cp <= 0x3fffd); // CJK Ext B+
}

test "ascii width" {
    try std.testing.expectEqual(@as(usize, 5), strWidth("hello"));
}

test "wide and combining width" {
    try std.testing.expectEqual(@as(usize, 2), cpWidth(0x4e16)); // 世
    try std.testing.expectEqual(@as(usize, 0), cpWidth(0x0301)); // combining acute
    try std.testing.expectEqual(@as(usize, 4), strWidth("世界"));
}

test "sequence length" {
    try std.testing.expectEqual(@as(usize, 1), seqLen('a'));
    try std.testing.expectEqual(@as(usize, 3), seqLen("世"[0]));
}
