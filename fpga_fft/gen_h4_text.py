"""gen_h4_text.py — H4 screen text: writes the font, text layout and kHz tick ROMs.

    python fpga_fft/gen_h4_text.py          (re-run after changing MIC_BCLK_DIV in video_h3.v)

Writes src/hdmi/rom_font.v, rom_text.v, rom_ticks.v, rom_spec.v (the spectrogram's colour
table and tick marks) and previews of the fixed text, drawn with the same font:
docs/figures/h4_layout.png (bars) and h4_layout_spectrogram.png.

THE TEXT GRID. The 1280x720 picture is 80 x 45 cells of 16x16 px. Each cell shows one
character: a 5x7 glyph (this file's own font) drawn at 2x inside an 8x8 cell. rom_text holds a
10-bit word per cell:  [9:8] colour  [7] 1 = "live character k" (k = [3:0], set by
peak_readout.v)  [6:0] ASCII code.
PAGES. The ROM holds one page of text per display mode, chosen by text_overlay's page input
(S1): page 0 = bars, page 1 = spectrogram. ROM address = {page, row[5:0], col[6:0]}.
(Until 2026-11-04 only rows 1 and 42 had variants, one per sound source.)
"""
import os
import re

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
HDMI = os.path.join(HERE, "src", "hdmi")
PCLK = 74.25e6

src_v = open(os.path.join(HDMI, "video_h3.v")).read()
MIC_DIV = int(re.search(r"parameter integer MIC_BCLK_DIV\s*=\s*(\d+)", src_v).group(1))
FLOOR_DB = int(re.search(r"parameter integer FLOOR_DB\s*=\s*(\d+)", src_v).group(1))
OVERLAP = int(re.search(r"parameter integer OVERLAP\s*=\s*(\d+)", src_v).group(1))
# the only sound source since 2026-11-04 (the test tone and the ESP32 relay were removed)
SOURCE = "MIC DIRECT"
FS = PCLK / (64 * MIC_DIV)                      # mic_source: 64 bit clocks per sample
COLS, ROWS = 80, 45
BARS, SPECTROGRAM = 0, 1                         # pages = display modes (S1)
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
    "n": ".....|.....|#.##.|##..#|#...#|#...#|#...#", "o": ".....|.....|.###.|#...#|#...#|#...#|.###.",
    "s": ".....|.....|.####|#....|.###.|....#|####.", "w": ".....|.....|#...#|#...#|#.#.#|#.#.#|.#.#.",
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
cells = {}          # (page, row, col) -> 10-bit word
page = BARS         # the page put() writes to


def put(row, col, text, colour):
    for i, ch in enumerate(text):
        assert 0 <= col + i < COLS and 0 <= row < ROWS, (row, col, text)
        assert (page, row, col + i) not in cells, f"overlap on page {page} row {row} col {col + i}: {text!r}"
        cells[(page, row, col + i)] = (colour << 8) | ord(ch)


def put_right(row, end_col, text, colour):
    put(row, end_col - len(text) + 1, text, colour)


def put_live(row, col, first, n, colour):
    for i in range(n):
        cells[(page, row, col + i)] = (colour << 8) | 0x80 | (first + i)


def header(title):
    """Title, source, gain and peak readout: the same places on every page."""
    put(1, 1, title, WHITE)
    put_right(1, 78, f"{SOURCE}  {round(FS)} Hz", CYAN)
    put_right(2, 72, "GAIN +", CYAN)              # live 9-10: gain in dB
    put_live(2, 73, 9, 2, CYAN)
    put(2, 75, " dB", CYAN)
    put(4, 72, "PEAK", GREY)
    put_live(5, 72, 0, 5, YELLOW)                 # live 0-4: peak frequency, Hz
    put(5, 77, " Hz", YELLOW)
    put_live(6, 72, 5, 4, YELLOW)                 # live 5-8: peak level, dB
    put(6, 76, " dB", YELLOW)


# ---- page 0: bars ----
page = BARS
header("LIVE FFT SPECTRUM - TANG NANO 20K + GOWIN FFT")
# a label every 2 kHz when the axis is wide (fs 44.6 kHz: 0-22 kHz), every 1 kHz when narrow
STEP_KHZ = 2 if FS > 30000 else 1
ticks = []          # x of the kHz tick lines, bars page only
for k in range(0, 100, STEP_KHZ):
    x = 128 + round(2 * k * 1000 * 1024 / FS)
    if x > 1151:
        break
    ticks.append(x)
    label = str(k)
    put(42, round((x - 8 * len(label)) / 16), label, GREY)
put(42, 76, "kHz", GREY)
for db in range(0, -FLOOR_DB - 1, -20):        # gridlines every 20 dB from y 60 (0 dB) to 660
    put_right((60 + 600 * -db // FLOOR_DB) // 16, 6, f"{db} dB", GREY)

# ---- page 1: spectrogram (spectrogram_display.v: plot x 128-1151, y 148-659) ----
page = SPECTROGRAM
header("LIVE SPECTROGRAM - TANG NANO 20K + GOWIN FFT")
ROW_HZ = FS / 512                               # one row = two FFT bins
COL_PER_S = FS / (512 if OVERLAP else 1024)    # one column per FFT (every 512 samples with overlap)
f_ticks = []        # y of the 1 kHz tick marks left of the plot
for k in range(0, 100):
    y = 659 - round(2 * k * 1000 / ROW_HZ)
    if y < 148:
        break
    f_ticks.append(y)
    put_right(round((y - 8) / 16), 6, str(k), GREY)
put_right(7, 6, "kHz", GREY)
STEP_S = 1 if OVERLAP else 2                   # 256 columns = 5.9 s with overlap, 11.7 s without
t_ticks = []        # x of the time tick marks below the plot (newest column at the right edge)
for t in range(0, 100, STEP_S):
    col = 255 - t * COL_PER_S
    if col < 1:
        break
    x = 128 + round(4 * col) + 2
    t_ticks.append(x)
    label = "now" if t == 0 else f"-{t}s"
    put(42, round((x - 8 * len(label)) / 16), label, GREY)
put(8, 73, "dB", GREY)                          # colour scale, x 1168-1183, 0 dB at the top
put_right(9, 78, "0", GREY)
put_right(25, 78, "-40", GREY)
put_right(41, 78, "-80", GREY)
# the 16 colours, 5 dB each from -80 dB (0) to 0 dB (15): matplotlib's "inferno" map sampled
# at i/15, except 0, which is pure black so the FFT's rounding noise (about -80 dB) stays hidden
SPEC_RGB = [0x000000, 0x0C0826, 0x240C4F, 0x420A68, 0x5D126E, 0x781C6D, 0x932667, 0xAE305C,
            0xC73E4C, 0xDD513A, 0xED6925, 0xF8850F, 0xFCA50A, 0xFAC62D, 0xF2E661, 0xFCFFA4]


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
         "// [6:0] ASCII. Address {page, row, col}: page 0 = bars, 1 = spectrogram.",
         "module rom_text (", "    input  wire        clk,", "    input  wire [13:0] addr,   // {page, row[5:0], col[6:0]}",
         "    output reg  [9:0]  q = 10'h020", ");", "    always @(posedge clk)", "        case (addr)"]
for (pg, row, col), w in sorted(cells.items()):
    if w & 0xFF != 0x20:
        lines.append(f"            14'd{pg * 8192 + row * 128 + col}: q <= 10'h{w:03X};")
lines += ["            default: q <= 10'h020;", "        endcase", "endmodule", ""]
write("rom_text.v", "\n".join(lines))

cond = " || ".join(f"x == 12'd{x}" for x in ticks)
lines = [f"// rom_ticks.v — generated by fpga_fft/gen_h4_text.py, do not edit.",
         f"// kHz tick lines every {STEP_KHZ} kHz on the bars page (mic: BCLK_DIV {MIC_DIV}, {FS:.1f} Hz).",
         "// q = 1 one clock after x.",
         "module rom_ticks (", "    input  wire        clk,", "    input  wire        page,",
         "    input  wire [11:0] x,", "    output reg         q = 1'b0", ");", "    always @(posedge clk)",
         f"        q <= !page && ({cond});", "endmodule", ""]
write("rom_ticks.v", "\n".join(lines))

lines = ["// rom_spec.v — generated by fpga_fft/gen_h4_text.py, do not edit.",
         "// Tables for spectrogram_display.v (combinational).",
         "// spec_colour: colour number (5 dB per step, 0 = -80 dB and below) -> RGB.",
         "module spec_colour (", "    input  wire [3:0]  i,", "    output reg  [23:0] rgb", ");",
         "    always @(*)", "        case (i)"]
lines += [f"            4'd{i}: rgb = 24'h{c:06X};" for i, c in enumerate(SPEC_RGB[:-1])]
lines += [f"            default: rgb = 24'h{SPEC_RGB[-1]:06X};", "        endcase", "endmodule", "",
          f"// spec_ticks: tick marks left of the plot every 1 kHz (x 120-127; {ROW_HZ:.2f} Hz per row)",
          f"// and below it every {STEP_S} s (y 660-667; {COL_PER_S:.2f} columns per second).",
          "module spec_ticks (", "    input  wire [11:0] x, y,", "    output wire        q", ");",
          "    assign q = (x >= 12'd120 && x < 12'd128 && (" + " || ".join(f"y == 12'd{v}" for v in f_ticks) + "))",
          "            || (y >= 12'd660 && y < 12'd668 && (" + " || ".join(f"x == 12'd{v}" for v in t_ticks) + "));",
          "endmodule", ""]
write("rom_spec.v", "\n".join(lines))

# ---- previews of the fixed text, one per page (live characters shown as '#') ----
os.makedirs(os.path.join(HERE, "..", "docs", "figures"), exist_ok=True)
for pg, name in ((BARS, "h4_layout.png"), (SPECTROGRAM, "h4_layout_spectrogram.png")):
    img = Image.new("RGB", (1280, 720))
    px = img.load()
    for (p, row, col), w in cells.items():
        if p != pg:
            continue
        ch = "#" if w & 0x80 else chr(w & 0x7F)
        g = glyph_rows(ch) if ch != "#" else [0x7C] * 7 + [0]
        for r in range(8):
            for c in range(8):
                if g[r] >> (7 - c) & 1:
                    for dy in range(2):
                        for dx in range(2):
                            px[col * 16 + c * 2 + dx, row * 16 + r * 2 + dy] = RGB[w >> 8]
    img.save(os.path.join(HERE, "..", "docs", "figures", name))
print(f"floor -{FLOOR_DB} dB; mic BCLK_DIV {MIC_DIV}: fs {FS:.1f} Hz; text cells per page "
      f"{[sum(1 for k in cells if k[0] == pg) for pg in (BARS, SPECTROGRAM)]}; {len(ticks)} ticks")
