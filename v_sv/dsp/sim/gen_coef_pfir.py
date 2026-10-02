#!/usr/bin/env python
#=============================================================================
# gen_coef_pfir.py -- PFB 原型低通系数生成 (dsp_pfir 用)
#
# 生成: sim/coef_pfir_<N>x<K>.mem (hex, Q1.(B_CO-1) 补码, 每行一项)
# 约定: DC 增益归一到 2^(B_CO-1) (sum(h)≈2^(B_CO-1)), 稳态 DC 输出 == 输入;
#       系数布局 h[p + r*N] (p = 信道/相位, r = 抽头) 与 dsp_pfir 的
#       系数 ROM 斜读一致。
#
# 用法: python gen_coef_pfir.py [N] [K] [B_CO]
#=============================================================================
import math
import sys

N    = int(sys.argv[1]) if len(sys.argv) > 1 else 64
K    = int(sys.argv[2]) if len(sys.argv) > 2 else 8
B_CO = int(sys.argv[3]) if len(sys.argv) > 3 else 16
NK   = N * K

# 窗函数法低通: 截止 = fs/(2N) (信道半带宽), hamming 窗
fc = 1.0 / (2 * N)
h = []
for n in range(NK):
    if n == NK // 2:
        s = 2 * fc
    else:
        s = math.sin(2 * math.pi * fc * (n - NK // 2)) / (math.pi * (n - NK // 2))
    w = 0.54 - 0.46 * math.cos(2 * math.pi * n / (NK - 1))
    h.append(s * w)

g = sum(h)
h = [v / g for v in h]                      # DC 增益 1

scale = 2 ** (B_CO - 1)
hi = [int(round(v * scale)) for v in h]
print("sum(h_int) = %d (target %d), DC err = %.2f LSB"
      % (sum(hi), scale, abs(sum(hi) - scale)))

path = "coef_pfir_%dx%d.mem" % (N, K)
with open(path, "w") as f:
    f.write("// PFB 原型低通 h[0..%d], Q1.%d, sum = 2^%d (DC 增益 1)\n"
            % (NK - 1, B_CO - 1, B_CO - 1))
    f.write("// 生成: %s N=%d K=%d B_CO=%d (窗函数法 hamming, 截止 fs/(2N))\n"
            % (__file__, N, K, B_CO))
    for v in hi:
        f.write("%04x\n" % (v & ((1 << B_CO) - 1)))
print("written %s (%d coeffs)" % (path, NK))
