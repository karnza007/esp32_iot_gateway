"""Figures for the FFT benchmark report (docs/reports/2026-10-11.md).

    python plot_fft_report.py --fetch    # pull raw spectra from the FPGA + ESP32, then plot
    python plot_fft_report.py            # re-plot from the saved data only

Raw data: data/fft/spectra-1024.csv  (signal, device, bin, re, im; 'exact' = numpy ÷ N)
Figures:  docs/figures/fft/*.png
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

import fft_model as fm

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "fft" / "spectra-1024.csv"
FIG = ROOT / "docs" / "figures" / "fft"
N = 1024
SIGNALS = ("tone_on_bin", "noise")
DEVICES = {"Gowin FPGA": b"F", "ESP32 SIMD": b"L", "ESP32 plain C": b"A"}

# Reference palette (dataviz skill, light mode): fixed slots, exact answer in neutral ink
SURFACE, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e1"
COLOR = {"exact": "#52514e", "Gowin FPGA": "#2a78d6", "ESP32 SIMD": "#eb6834",
         "ESP32 plain C": "#1baf7a", "ideal 16-bit": "#8a8984"}

plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "axes.edgecolor": GRID, "axes.labelcolor": INK2, "axes.titlecolor": INK,
    "xtick.color": INK2, "ytick.color": INK2, "text.color": INK,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8,
    "axes.spines.top": False, "axes.spines.right": False,
    "font.size": 10, "axes.titlesize": 11, "axes.titleweight": "bold",
    "lines.linewidth": 1.2, "legend.frameon": False,
})


# ---------------------------------------------------------------------------
# data
# ---------------------------------------------------------------------------

def fetch() -> None:
    from fft_bench import Device, find_port
    dev = Device(find_port(("/dev/cu.wchusbserial*",)), 2_000_000)
    sigs = {s.name: s for s in fm.make_signals(N)}
    rows = []
    for name in SIGNALS:
        s = sigs[name]
        ref = fm.reference(s.re, s.im)
        rows += [(name, "exact", k, ref.real[k], ref.imag[k]) for k in range(N)]
        for label, cmd in DEVICES.items():
            r, i, _ = dev.fft(s, cmd)
            rows += [(name, label, k, int(r[k]), int(i[k])) for k in range(N)]
            print(f"  fetched {name:<12} from {label}")
    RAW.parent.mkdir(parents=True, exist_ok=True)
    with RAW.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["signal", "device", "bin", "re", "im"])
        w.writerows(rows)
    print(f"saved {RAW.relative_to(ROOT)}")


def load() -> dict:
    d: dict = {}
    with RAW.open() as f:
        for row in csv.DictReader(f):
            key = (row["signal"], row["device"])
            d.setdefault(key, np.zeros(N, complex))[int(row["bin"])] = \
                float(row["re"]) + 1j * float(row["im"])
    s = {x.name: x for x in fm.make_signals(N)}["noise"]
    ir, ii, _ = fm.ideal_fixed_fft(s.re, s.im)
    d[("noise", "ideal 16-bit")] = ir + 1j * ii
    return d


def bitrev(n_bits: int) -> np.ndarray:
    k = np.arange(1 << n_bits)
    out = np.zeros_like(k)
    for b in range(n_bits):
        out |= ((k >> b) & 1) << (n_bits - 1 - b)
    return out


def save(fig, name: str) -> None:
    FIG.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIG / name, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"  wrote docs/figures/fft/{name}")


# ---------------------------------------------------------------------------
# figures
# ---------------------------------------------------------------------------

def fig_complex_bin(d: dict) -> None:
    """One bin = two 16-bit numbers = one arrow: length (magnitude) and angle (phase)."""
    k = 100
    z = d[("noise", "Gowin FPGA")][k]
    re, im = z.real, z.imag
    mag, ph = abs(z), np.degrees(np.angle(z))
    fig, ax = plt.subplots(figsize=(5.2, 5.0))
    lim = 1.25 * max(abs(re), abs(im), mag)
    ax.axhline(0, color=INK2, lw=0.8)
    ax.axvline(0, color=INK2, lw=0.8)
    ax.annotate("", xy=(re, im), xytext=(0, 0),
                arrowprops=dict(arrowstyle="-|>", color=COLOR["Gowin FPGA"], lw=2))
    ax.plot([re, re], [0, im], ls="--", color=INK2, lw=1)
    ax.plot([0, re], [im, im], ls="--", color=INK2, lw=1)
    ax.plot(re, 0, "o", color=INK, ms=6)
    ax.plot(0, im, "o", color=INK, ms=6)
    ax.text(re, -0.07 * lim, f"re = {re:.0f}", ha="center", va="top", color=INK)
    ax.text(-0.03 * lim, im + 0.05 * lim, f"im = {im:.0f}", ha="right", va="bottom", color=INK)
    t = np.linspace(0, np.angle(z), 50)
    ax.plot(0.25 * mag * np.cos(t), 0.25 * mag * np.sin(t), color=INK2, lw=1)
    ax.text(-0.95 * lim, 0.62 * lim, f"magnitude (arrow length)\n= √(re² + im²) = {mag:.0f}",
            color=COLOR["Gowin FPGA"], ha="left", va="center")
    ax.text(0.30 * mag, 0.22 * mag, f"phase (angle)\n= atan2(im, re) = {ph:.0f}°",
            color=INK2, fontsize=9, ha="left", va="bottom")
    ax.set_xlim(-lim, lim)
    ax.set_ylim(-lim, lim)
    ax.set_aspect("equal")
    ax.set_xlabel("real part (16-bit number #1)")
    ax.set_ylabel("imaginary part (16-bit number #2)")
    ax.set_title(f"One FFT bin (bin {k}, Gowin, noise input) as an arrow")
    save(fig, "complex_bin.png")


def fig_bitrev_8() -> None:
    """8-point picture: where each bin lands in a radix-2 FFT's raw output."""
    br = bitrev(3)
    fig, ax = plt.subplots(figsize=(7.0, 3.4))
    ax.grid(False)
    for p in range(8):
        k = br[p]
        ax.plot([0, 1], [7 - p, 7 - k], color=COLOR["ESP32 SIMD"] if p != k else INK2,
                lw=1.6 if p != k else 1.0)
        ax.text(-0.04, 7 - p, f"position {p} ({p:03b})  holds bin {k}", ha="right",
                va="center", fontsize=9)
        ax.text(1.04, 7 - p, f"bin {p} ({p:03b})", ha="left", va="center", fontsize=9)
    ax.text(0, 8.0, "raw radix-2 output\n(bit-reversed order)", ha="center", fontsize=9,
            color=INK2)
    ax.text(1, 8.0, "natural order\n(0, 1, 2, …)", ha="center", fontsize=9, color=INK2)
    ax.set_xlim(-0.9, 1.4)
    ax.set_ylim(-0.6, 8.8)
    ax.axis("off")
    ax.set_title("Bit reversal, 8 points: position p holds bin reverse_bits(p)")
    save(fig, "bitrev_8.png")


def fig_bitrev_1024(d: dict) -> None:
    """The tone at bin 37 before and after the ESP32's bit-reverse step."""
    nat = np.abs(d[("tone_on_bin", "ESP32 SIMD")])
    raw = nat[bitrev(10)]                    # what the buffer held before dsps_bit_rev
    fig, axes = plt.subplots(2, 1, figsize=(8.5, 4.6), sharex=True)
    for ax, y, title in ((axes[0], raw, "Before bit reversal (raw ESP-DSP output)"),
                         (axes[1], nat, "After bit reversal (natural order)")):
        ax.plot(np.arange(N), y, color=COLOR["ESP32 SIMD"])
        ax.set_title(title, loc="left")
        ax.set_ylabel("magnitude")
        ax.set_ylim(0, 9500)
    for p in sorted(np.argsort(raw)[-2:]):
        left = p == min(np.argsort(raw)[-2:])
        axes[0].annotate(f"position {p}\n= bin {bitrev(10)[p]}", (p, raw[p]),
                         xytext=(p - 60 if left else p + 60, 6000),
                         ha="right" if left else "left", fontsize=9,
                         arrowprops=dict(arrowstyle="-", color=INK2, lw=0.8))
    for k in (37, 987):
        axes[1].annotate(f"bin {k}", (k, nat[k]), xytext=(k + (60 if k < 500 else -60), 6000),
                         ha="left" if k < 500 else "right", fontsize=9,
                         arrowprops=dict(arrowstyle="-", color=INK2, lw=0.8))
    axes[1].set_xlabel("position in the result array")
    fig.suptitle("Tone at bin 37 (and its mirror, bin 987): the same data, two orders",
                 fontweight="bold", x=0.02, ha="left")
    fig.tight_layout()
    save(fig, "bitrev_1024.png")


def to_dbfs(z: np.ndarray) -> np.ndarray:
    return 20 * np.log10(np.maximum(np.abs(z), 0.5) / 32767)   # 0 is drawn at the ½-LSB floor


def fig_tone_spectrum(d: dict) -> None:
    """Linear scale: the errors are invisible. dB scale: they are the floor."""
    names = ["exact", "Gowin FPGA", "ESP32 SIMD", "ESP32 plain C"]
    fig = plt.figure(figsize=(9.5, 8.6))
    gs = fig.add_gridspec(5, 1, height_ratios=[1.3, 1, 1, 1, 1], hspace=0.55)
    ax0 = fig.add_subplot(gs[0])
    for nm in names:
        ax0.plot(np.arange(N // 2), np.abs(d[("tone_on_bin", nm)])[:N // 2], color=COLOR[nm],
                 label=nm, lw=1.4 if nm == "exact" else 1.0)
    ax0.set_xlim(0, 120)
    ax0.set_title("Linear scale (bins 0–120): all four look identical", loc="left")
    ax0.set_ylabel("magnitude")
    ax0.legend(ncol=4, loc="upper right", fontsize=9)
    for j, nm in enumerate(names):
        ax = fig.add_subplot(gs[j + 1])
        ax.plot(np.arange(N // 2), to_dbfs(d[("tone_on_bin", nm)])[:N // 2], color=COLOR[nm])
        ax.set_ylim(-100, 0)
        ax.set_xlim(0, N // 2)
        ax.set_yticks([0, -40, -80])
        ax.set_ylabel("dBFS")
        ax.set_title(f"dB scale: {nm}", loc="left")
        if j == 3:
            ax.set_xlabel("frequency bin")
    fig.suptitle("Tone at bin 37, amplitude 16384: the error only shows on a dB scale, as a floor",
                 fontweight="bold", x=0.02, ha="left", y=0.995)
    fig.text(0.02, 0.005, "Bins where the value is exactly 0 are drawn at the ½-LSB line (−96 dBFS).",
             fontsize=8, color=INK2)
    save(fig, "tone_spectrum.png")


def errors(d: dict, dev: str) -> np.ndarray:
    """Error of every output NUMBER (real and imaginary parts), noise input."""
    e = d[("noise", dev)] - d[("noise", "exact")]
    return np.concatenate([e.real, e.imag])


def fig_error_per_bin(d: dict) -> None:
    devs = ["ESP32 plain C", "ESP32 SIMD", "Gowin FPGA"]
    fig, axes = plt.subplots(3, 1, figsize=(9.5, 6.4), sharex=True, sharey=True)
    for ax, nm in zip(axes, devs):
        e = (d[("noise", nm)] - d[("noise", "exact")]).real
        rms = np.sqrt(np.mean(errors(d, nm) ** 2))
        ax.plot(np.arange(N), e, color=COLOR[nm], lw=0.7)
        ax.axhline(0, color=INK, lw=0.8)
        for s in (rms, -rms):
            ax.axhline(s, color=INK2, lw=0.8, ls="--")
        ax.set_ylim(-11, 11)
        ax.set_title(f"{nm}: typical error (rms) {rms:.2f} LSB, dashed = ±rms", loc="left")
        ax.set_ylabel("error (LSB)")
    axes[-1].set_xlabel("frequency bin (real part shown)")
    fig.suptitle("Random input: every bin has its own small error (device − exact)",
                 fontweight="bold", x=0.02, ha="left")
    fig.tight_layout()
    save(fig, "error_per_bin.png")


def fig_error_hist(d: dict) -> None:
    devs = ["ideal 16-bit", "ESP32 plain C", "ESP32 SIMD", "Gowin FPGA"]
    edges = np.arange(-10.5, 11, 1.0)
    fig, axes = plt.subplots(len(devs), 1, figsize=(8.5, 7.2), sharex=True)
    for ax, nm in zip(axes, devs):
        e = errors(d, nm)
        ax.hist(e, bins=edges, color=COLOR[nm], edgecolor=SURFACE, linewidth=2)
        ax.axvline(0, color=INK, lw=0.8)
        ax.axvline(e.mean(), color=INK2, lw=1.2, ls="--")
        ax.set_title(f"{nm}: rms {np.sqrt(np.mean(e ** 2)):.2f} LSB, average (dashed) "
                     f"{e.mean():+.2f}, worst {np.abs(e).max():.1f}", loc="left")
        ax.set_ylabel("numbers")
    axes[-1].set_xlabel("error of one output number, in LSB (device − exact)")
    fig.suptitle("How big the errors are: 2,048 output numbers per device, random input",
                 fontweight="bold", x=0.02, ha="left")
    fig.tight_layout()
    save(fig, "error_histogram.png")


def fig_rms_summary(d: dict) -> None:
    devs = ["ideal 16-bit", "ESP32 plain C", "ESP32 SIMD", "Gowin FPGA"]
    vals = [np.sqrt(np.mean(errors(d, nm) ** 2)) for nm in devs]
    fig, ax = plt.subplots(figsize=(8.0, 3.2))
    y = np.arange(len(devs))[::-1]
    ax.barh(y, vals, color=[COLOR[nm] for nm in devs], height=0.6)
    for yy, v in zip(y, vals):
        ax.text(v + 0.1, yy, f"{v:.2f}", va="center", color=INK)
    ax.set_axisbelow(True)
    ax.axvline(4, color=INK, lw=1.2, ls="--")
    ax.text(4.1, y[-1] - 0.05, "correctness gate\n4 LSB", fontsize=9, color=INK, va="center")
    ax.axvline(7.1, color="#e34948", lw=1.2, ls=":")
    ax.text(7.2, y[-1] - 0.05, "smallest bug\n7.1 LSB", fontsize=9, color=INK, va="center")
    ax.set_yticks(y, devs)
    ax.set_xlim(0, 9)
    ax.set_xlabel("typical error (rms), LSB, random input, N = 1024")
    ax.set_title("All three devices are correct; they differ in how carefully they round",
                 loc="left")
    ax.grid(axis="y", visible=False)
    save(fig, "rms_summary.png")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fetch", action="store_true", help="pull fresh spectra from the devices")
    a = ap.parse_args()
    if a.fetch:
        fetch()
    if not RAW.exists():
        sys.exit("no data yet: run with --fetch")
    d = load()
    fig_complex_bin(d)
    fig_bitrev_8()
    fig_bitrev_1024(d)
    fig_tone_spectrum(d)
    fig_error_per_bin(d)
    fig_error_hist(d)
    fig_rms_summary(d)
    return 0


if __name__ == "__main__":
    sys.exit(main())
