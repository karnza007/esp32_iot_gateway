import sys, numpy as np
n, out = int(sys.argv[1]), sys.argv[2]
k = np.arange(n)
for name, v in (("twRe.v", np.round(32767*np.cos(2*np.pi*k/n))), ("twIm.v", np.round(-32767*np.sin(2*np.pi*k/n)))):
    v = v.astype(int) & 0xFFFF
    open(f"{out}/{name}", "w").write(",\n".join(f"16'd{x}" for x in v))
