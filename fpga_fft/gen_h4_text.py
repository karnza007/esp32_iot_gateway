"""gen_h4_text.py — H4 screen text: writes the font, text layout and kHz tick ROMs.

    python fpga_fft/gen_h4_text.py          (re-run after changing MIC_BCLK_DIV in video_h3.v)

Writes src/hdmi/rom_font.v, rom_text.v, rom_ticks.v and docs/figures/h4_layout.png (a
preview of the fixed text, drawn with the same font).

THE TEXT GRID. The 1280x720 picture is 80 x 45 cells of 16x16 px. Each cell shows one
character: a 5x7 glyph (this file's own font) drawn at 2x inside an 8x8 cell. rom_text holds a
10-bit word per cell:  [9:8] colour  [7] 1 = "live character k" (k = [3:0], set by
peak_readout.v)  [6:0] ASCII code.
Rows 1 (title + source) and 42 (kHz axis) change with the source, so one version per source
is stored below the visible picture: row 1 is read from row 45 + src, row 42 from 48 + src.
"""
import os
import re

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
HDMI = os.path.join(HERE, "src", "hdmi")
PCLK = 74.25e6

src_v = open(os.path.join(HDMI, "video_h3.v")).read()
MIC_DIV = int(re.search(r"parameter integer MIC_BCLK_DIV\s*=\s*(\d+)", src_v).group(1))
# src values, as in video_h3.v: 0 test tone, 1 direct mic (the ESP32 relay, src 2, was removed)
SOURCES = [
    ("TEST TONE", PCLK / (64 * MIC_DIV)),       # tone_gen: run at the mic's rate (video_h3.v)
    ("MIC DIRECT", PCLK / (64 * MIC_DIV)),      # mic_source: 64 bit clocks per sample
]
COLS, ROWS, VAR_TITLE, VAR_AXIS = 80, 45, 45, 48
WHITE, GREY, YELLOW, CYAN = 0, 1, 2, 3
RGB = {WHITE: (255, 255, 255), GREY: (180, 180, 180), YELLOW: (255, 210, 60), CYAN: (80, 200, 255)}

# ---- font: 5x7 glyphs ----
GLYPHS = {
    "0": ".###.|#...#|#..##|#.#.#|##..#|#...#|.###.", "1": "..#..|.##..|..#..|..#..|..#..|..#..|.###.",
    "2": ".###.|#...#|....#|...#.|..#..|.#...|#####", "3": "#####|...#.|..#..|...#.|....#|#...#|.###.",
    "4": "...#.|..##.|.#.#.|#..#.|#####|...#.|...#.", "5": "#####|#....|####.|....#|....#|#...#|.###.",
    "6": "..##.|.#...|#....|####.|#...#|#...#|.###.", "7": "#####|....#|...#.|..#..|.#...|.#...|.#...",
    "8": ".###.|#...#|#...#|.###.|#...#|#...#|.###.", "9": ".###.|#...#|#...#|.####|....#|...#.|.##..",
    "A": ".###.|#...#|#...#|#####|#...#|#...#|#...#", "B": "####.|#...#|#...#|####.|#...#|#...#|####.",
    "C": ".###.|#...#|#....|#....|#....|#...#|.###.", "D": "###..|#..#.|#...#|#...#|#...#|#..#.|###..",
    "E": "#####|#....|#....|####.|#....|#....|#####", "F": "#####|#....|#....|####.|#....|#....|#....",
    "G": ".###.|#...#|#....|#.###|#...#|#...#|.####", "H": "#...#|#...#|#...#|#####|#...#|#...#|#...#",
    "I": ".###.|..#..|..#..|..#..|..#..|..#..|.###.", "J": "..###|...#.|...#.|...#.|...#.|#..#.|.##..",
    "K": "#...#|#..#.|#.#..|##...|#.#..|#..#.|#...#", "L": "#....|#....|#....|#....|#....|#....|#####",
    "M": "#...#|##.##|#.#.#|#.#.#|#...#|#...#|#...#", "N": "#...#|#...#|##..#|#.#.#|#..##|#...#|#...#",
    "O": ".###.|#...#|#...#|#...#|#...#|#...#|.###.", "P": "####.|#...#|#...#|####.|#....|#....|#....",
    "Q": ".###.|#...#|#...#|#...#|#.#.#|#..#.|.##.#", "R": "####.|#...#|#...#|####.|#.#..|#..#.|#...#",
    "S": ".####|#....|#....|.###.|....#|....#|####.", "T": "#####|..#..|..#..|..#..|..#..|..#..|..#..",
    "U": "#...#|#...#|#...#|#...#|#...#|#...#|.###.", "V": "#...#|#...#|#...#|#...#|#...#|.#.#.|..#..",
    "W": "#...#|#...#|#...#|#.#.#|#.#.#|#.#.#|.#.#.", "X": "#...#|#...#|.#.#.|..#..|.#.#.|#...#|#...#",
    "Y": "#...#|#...#|.#.#.|..#..|..#..|..#..|..#..", "Z": "#####|....#|...#.|..#..|.#...|#....|#####",
    "d": "....#|....#|.##.#|#..##|#...#|#...#|.####", "k": "#....|#....|#..#.|#.#..|##...|#.#..|#..#.",
    "z": ".....|.....|#####|...#.|..#..|.#...|#####",
    "+": ".....|..#..|..#..|#####|..#..|..#..|.....", "-": ".....|.....|.....|#####|.....|.....|.....",
    ".": ".....|.....|.....|.....|.....|.##..|.##..", ":": ".....|.##..|.##..|.....|.##..|.##..|.....",
    "/": ".....|....#|...#.|..#..|.#...|#....|.....",
}


def glyph_rows(ch):
    """8 bytes, MSB = leftmost pixel: the 5x7 glyph at columns 1-5, rows 0-6."""
    if ch not in GLYPHS:
        return [0] * 8
    rows = GLYPHS[ch].split("|")
    assert len(rows) == 7 and all(len(r) == 5 for r in rows), ch
    return [int("0" + r.replace("#", "1").replace(".", "0") + "00", 2) for r in rows] + [0]


# ---- text layout ----
cells = {}          # (row, col) -> 10-bit word


def put(row, col, text, colour):
    for i, ch in enumerate(text):
        assert 0 <= col + i < COLS, (row, col, text)
        assert (row, col + i) not in cells, f"overlap at row {row} col {col + i}: {text!r}"
        cells[(row, col + i)] = (colour << 8) | ord(ch)


def put_right(row, end_col, text, colour):
    put(row, end_col - len(text) + 1, text, colour)


def put_live(row, col, first, n, colour):
    for i in range(n):
        cells[(row, col + i)] = (colour << 8) | 0x80 | (first + i)


TITLE = "LIVE FFT SPECTRUM - TANG NANO 20K + GOWIN FFT"
ticks = []
for s, (name, fs) in enumerate(SOURCES):
    put(VAR_TITLE + s, 1, TITLE, WHITE)
    put_right(VAR_TITLE + s, 78, f"{name}  {round(fs)} Hz", CYAN)
    xs = []
    for k in range(0, 100, 2):
        x = 128 + round(2 * k * 1000 * 1024 / fs)
        if x > 1151:
            break
        xs.append(x)
        label = str(k)
        put(VAR_AXIS + s, round((x - 8 * len(label)) / 16), label, GREY)
    put(VAR_AXIS + s, 76, "kHz", GREY)
    ticks.append(xs)

put_right(2, 72, "GAIN +", CYAN)              # live 9-10: gain in dB
put_live(2, 73, 9, 2, CYAN)
put(2, 75, " dB", CYAN)
for db, row in zip(range(0, -101, -20), (3, 11, 18, 26, 33, 41)):   # gridlines y 60..660
    put_right(row, 6, f"{db} dB", GREY)
put(4, 72, "PEAK", GREY)
put_live(5, 72, 0, 5, YELLOW)                 # live 0-4: peak frequency, Hz
put(5, 77, " Hz", YELLOW)
put_live(6, 72, 5, 4, YELLOW)                 # live 5-8: peak level, dB
put(6, 76, " dB", YELLOW)


# ---- write the ROMs ----
def write(name, body):
    with open(os.path.join(HDMI, name), "w") as f:
        f.write(body)


lines = [f"// rom_font.v — generated by fpga_fft/gen_h4_text.py, do not edit.",
         "// 128 characters x 8 rows, MSB = leftmost pixel. Undefined characters are blank.",
         "module rom_font (", "    input  wire       clk,", "    input  wire [9:0] addr,   // {ASCII code, row}",
         "    output reg  [7:0] q = 0", ");", "    always @(posedge clk)", "        case (addr)"]
for ch in sorted(GLYPHS):
    for r, bits in enumerate(glyph_rows(ch)):
        if bits:
            lines.append(f"            10'd{ord(ch) * 8 + r}: q <= 8'h{bits:02X};   // {ch!r} row {r}")
lines += ["            default: q <= 8'h00;", "        endcase", "endmodule", ""]
write("rom_font.v", "\n".join(lines))

lines = [f"// rom_text.v — generated by fpga_fft/gen_h4_text.py, do not edit.",
         "// One 10-bit word per 16x16 cell: [9:8] colour, [7] live character ([3:0] = which),",
         "// [6:0] ASCII. Address {row, col}; rows 45-47 / 48-50 are the per-source rows 1 / 42.",
         "module rom_text (", "    input  wire        clk,", "    input  wire [12:0] addr,   // {row[5:0], col[6:0]}",
         "    output reg  [9:0]  q = 10'h020", ");", "    always @(posedge clk)", "        case (addr)"]
for (row, col), w in sorted(cells.items()):
    if w & 0xFF != 0x20:
        lines.append(f"            13'd{row * 128 + col}: q <= 10'h{w:03X};")
lines += ["            default: q <= 10'h020;", "        endcase", "endmodule", ""]
write("rom_text.v", "\n".join(lines))

lines = [f"// rom_ticks.v — generated by fpga_fft/gen_h4_text.py, do not edit.",
         f"// kHz tick lines every 2 kHz, per source (mic: BCLK_DIV {MIC_DIV}). q = 1 one clock after x.",
         "module rom_ticks (", "    input  wire        clk,", "    input  wire [1:0]  src,",
         "    input  wire [11:0] x,", "    output reg         q = 1'b0", ");", "    always @(posedge clk)",
         "        case (src)"]
for s, xs in enumerate(ticks):
    cond = " || ".join(f"x == 12'd{x}" for x in xs)
    lines.append(f"            2'd{s}: q <= {cond};   // {SOURCES[s][0]}, {SOURCES[s][1]:.1f} Hz")
lines += ["            default: q <= 1'b0;", "        endcase", "endmodule", ""]
write("rom_ticks.v", "\n".join(lines))

# ---- preview of the fixed text (source 1, live characters shown as '#') ----
img = Image.new("RGB", (1280, 720))
px = img.load()
for (row, col), w in cells.items():
    vis = {VAR_TITLE + 1: 1, VAR_AXIS + 1: 42}.get(row, row)
    if vis >= ROWS:
        continue
    ch = "#" if w & 0x80 else chr(w & 0x7F)
    g = glyph_rows(ch) if ch != "#" else [0x7C] * 7 + [0]
    for r in range(8):
        for c in range(8):
            if g[r] >> (7 - c) & 1:
                for dy in range(2):
                    for dx in range(2):
                        px[col * 16 + c * 2 + dx, vis * 16 + r * 2 + dy] = RGB[w >> 8]
os.makedirs(os.path.join(HERE, "..", "docs", "figures"), exist_ok=True)
img.save(os.path.join(HERE, "..", "docs", "figures", "h4_layout.png"))
print(f"mic BCLK_DIV {MIC_DIV}: fs {SOURCES[1][1]:.1f} Hz; {len(cells)} text cells; "
      f"ticks per source {[len(t) for t in ticks]}")
