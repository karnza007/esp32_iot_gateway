"""check_hdmi.py — decode the simulated HDMI bit stream like a monitor, check the H1 picture.

    python check_hdmi.py <bits file from tb_hdmi.v>

1. Word alignment from the clock lane (5 zeros then 5 ones per pixel, bit 0 first).
2. Each 10-bit word on the 3 data lanes is decoded: one of the 4 control words (blanking,
   carrying HSYNC/VSYNC on lane 0) or a TMDS data word, undone back to the colour byte.
3. Checks: the 720p frame structure (1650 x 750, porches, sync widths), the DC balance of
   every lane, and every visible pixel against a model of test_pattern.v.
"""
import sys
import numpy as np

CTRL = {0b1101010100: (0, 0), 0b0010101011: (0, 1), 0b0101010100: (1, 0), 0b1010101011: (1, 1)}


def tmds_decode(q: int) -> int:
    d = (~q & 0xFF) if (q >> 9) & 1 else (q & 0xFF)
    out = d & 1
    for i in range(1, 8):
        b = ((d >> i) ^ (d >> (i - 1))) & 1
        if not (q >> 8) & 1:
            b ^= 1
        out |= b << i
    return out


def model(x: int, y: int, sq_x: int) -> tuple[int, int, int]:
    bars = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
            (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]
    if x in (0, 1279) or y in (0, 719):
        return (255, 255, 255)
    if y < 560:
        return bars[min(x // 160, 7)]
    if y < 620:
        g = (x * 51) >> 8
        return (g, g, g)
    if 640 <= y < 680 and sq_x <= x < sq_x + 40:
        return (255, 255, 255)
    return (0, 0, 0)


def main(path: str) -> int:
    s = open(path).read().replace("\n", "")
    v = np.frombuffer(s.encode(), dtype=np.uint8)
    v = np.where(v <= ord("9"), v - ord("0"), v - ord("a") + 10).astype(np.uint8)
    lanes = [(v >> k) & 1 for k in range(4)]          # 0..2 data, 3 clock
    ok = True

    def check(name, cond, detail=""):
        nonlocal ok
        ok &= bool(cond)
        print(f"  {'PASS' if cond else 'FAIL'}  {name:<52} {detail}")

    # 1. alignment: find the offset where every clock word is 0000011111 (bit 0 first)
    clk_word = np.array([0, 0, 0, 0, 0, 1, 1, 1, 1, 1], np.uint8)
    best = None
    for off in range(10):
        n = (len(v) - off) // 10
        w = lanes[3][off:off + 10 * n].reshape(n, 10)
        frac = np.mean(np.all(w == clk_word, axis=1))
        if best is None or frac > best[1]:
            best = (off, frac)
    off, frac = best
    n = (len(v) - off) // 10
    check("clock lane: 5 zeros + 5 ones per pixel", frac > 0.999, f"{100 * frac:.3f} % of words")

    def words(lane):
        b = lanes[lane][off:off + 10 * n].reshape(n, 10).astype(np.int64)
        return (b << np.arange(10)).sum(axis=1)       # bit 0 arrived first

    W = [words(k) for k in range(3)]
    start = 50                                        # skip the reset/pipeline start-up
    W = [w[start:] for w in W]
    m = len(W[0])
    is_ctrl = [np.isin(w, list(CTRL)) for w in W]
    de = ~is_ctrl[0]
    check("all 3 lanes agree on blanking vs picture", np.array_equal(de, ~is_ctrl[1]) and
          np.array_equal(de, ~is_ctrl[2]))
    hs = np.array([CTRL[q][1] if c else 0 for q, c in zip(W[0], is_ctrl[0])], np.uint8)
    vs = np.array([CTRL[q][0] if c else 0 for q, c in zip(W[0], is_ctrl[0])], np.uint8)
    ctrl12 = all(all(CTRL[q] == (0, 0) for q in w[c]) for w, c in zip(W[1:], is_ctrl[1:]))
    check("lanes 1, 2 send control word 00 in blanking", ctrl12)

    # 2. structure. The stream starts mid-frame after reset, so the frame that is checked
    #    is the complete one that follows the first VSYNC.
    i8 = lambda a: np.diff(a.astype(np.int8))
    vrise, vfall = np.where(i8(vs) == 1)[0] + 1, np.where(i8(vs) == -1)[0] + 1
    hrise, hfall = np.where(i8(hs) == 1)[0] + 1, np.where(i8(hs) == -1)[0] + 1
    starts, ends = np.where(i8(de) == 1)[0] + 1, np.where(i8(de) == -1)[0] + 1
    check("two VSYNCs (one complete frame between them)", len(vrise) >= 2,
          f"{len(vrise)} found")
    if len(vrise) < 2:
        print("  -> FAILED"); return 1
    f0, f1 = vrise[0], vrise[1]
    starts = starts[(starts > f0) & (starts < f1)]
    ends = ends[(ends > f0) & (ends < f1)]
    runs = ends - starts
    check("visible lines in the frame", len(runs) == 720, f"{len(runs)}")
    check("1280 visible pixels on every line", np.all(runs == 1280), f"{runs.min()}..{runs.max()}")
    period = np.diff(starts)
    check("1650 slots per line", np.all(period == 1650), f"{period.min()}..{period.max()}")
    check("750 lines per frame (VSYNC to VSYNC)", (f1 - f0) == 750 * 1650, f"{(f1 - f0) / 1650}")
    hw = hfall[np.searchsorted(hfall, hrise[:-1])] - hrise[:-1]
    check("HSYNC 40 slots wide", set(hw.tolist()) == {40}, f"{set(hw.tolist())}")
    fp = {int(hrise[np.searchsorted(hrise, e)] - e) for e in ends}
    check("front porch 110 (picture end -> HSYNC)", fp == {110}, f"{fp}")
    bp = {int(s - hfall[np.searchsorted(hfall, s) - 1]) for s in starts}
    check("back porch 220 (HSYNC end -> picture)", bp == {220}, f"{bp}")
    vlines = (vfall[np.searchsorted(vfall, f1)] - f1) / 1650
    check("VSYNC 5 lines long", vlines == 5, f"{vlines}")
    # exact positions, counted from the frame's first visible pixel (line 0, slot 0):
    # VSYNC starts on line 720 + 5 = 725 at slot 1280 + 110 = 1390, where HSYNC starts
    pos = int(f1 - starts[0])
    check("VSYNC starts at line 725, slot 1390", pos == 725 * 1650 + 1390,
          f"line {pos // 1650}, slot {pos % 1650}")
    check("VSYNC starts together with an HSYNC", f0 in set(hrise.tolist()) and f1 in set(hrise.tolist()))
    pre = int(starts[0] - f0)
    check("previous VSYNC 25 lines - 1390 slots before line 0", pre == 25 * 1650 - 1390, f"{pre} slots")

    # 3. DC balance, as the standard defines it: within each line of picture data the
    #    running count of 1s minus 0s stays small (the encoder restarts it in blanking)
    for k in range(3):
        worst = 0
        for s0, e0 in zip(starts, ends):
            bits = lanes[k][off + 10 * (start + s0):off + 10 * (start + e0)].astype(np.int64)
            worst = max(worst, int(np.abs(np.cumsum(2 * bits - 1)).max()))
        check(f"lane {k} DC balance within each line", worst <= 20, f"worst running 1s-0s: {worst}")

    # 4. picture: decode every visible pixel, compare with the model
    pix = np.zeros((720, 1280, 3), np.int64)
    for ln, s0 in enumerate(starts[:720]):
        for c, lane in ((2, 0), (1, 1), (0, 2)):      # lane 0 = blue, 1 = green, 2 = red
            pix[ln, :, c] = [tmds_decode(int(q)) for q in W[lane][s0:s0 + 1280]]
    row = pix[650, :, 0]
    sq = np.where((row == 255) & (np.arange(1280) > 0) & (np.arange(1280) < 1279))[0]
    sq_x = int(sq.min()) if len(sq) else -1
    check("moving square found, 40 px wide", len(sq) == 40, f"at x = {sq_x}")
    exp = np.array([[model(x, y, sq_x) for x in range(1280)] for y in range(720)])
    bad = np.argwhere(np.any(pix != exp, axis=2))
    check("every visible pixel matches the test pattern", len(bad) == 0,
          f"{len(bad)} of 921,600 differ" + (f", first at (x,y)={tuple(bad[0][::-1])}" if len(bad) else ""))
    print("  ->", "ALL PASS" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
