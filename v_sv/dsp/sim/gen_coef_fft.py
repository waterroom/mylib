#!/usr/bin/env python
#=============================================================================
# gen_coef_fft.py -- twiddle ROM 生成 + 整数模型 numpy 交叉验证 (dsp_fft 用)
#
# 1) 生成: sim/coef_fft_<N>_w<WT>.mem
#    每行 = 两个十六进制字段 "ccccssss" (cos, sin), Q1.(WT-1) 补码,
#    e^{-j2*pi*k/N}, k = 0..N/2-1 (共 N/2 行; 全圆周由对称性覆盖)。
#    量化: scale = 2^(WT-1) - 1 (1.0 用饱和码值表示, 与 litedsp 同约定)。
#
# 2) 交叉验证: 用与 RTL 逐位相同的整数模型跑 4 组向量 (冲激/直流/单音/
#    随机), 与 numpy.fft 浮点结果比对, 打印最大误差 (输入 LSB 计)。
#    模型验证通过 = RTL 的参照可信; TB 再验证 RTL == 模型 (位精确)。
#
# 用法: python gen_coef_fft.py [N] [WT]
#=============================================================================
import math
import sys

import numpy as np

N  = int(sys.argv[1]) if len(sys.argv) > 1 else 64
WT = int(sys.argv[2]) if len(sys.argv) > 2 else 16
LG = int(math.log2(N))
assert 1 << LG == N, "N 必须是 2 的幂"

SCALE = (1 << (WT - 1)) - 1
MASK  = (1 << WT) - 1

def tw(k):
    """e^{-j2*pi*k/N} 的 Q1.(WT-1) 量化 (整数, 补码位型)"""
    c = int(round(math.cos(-2 * math.pi * k / N) * SCALE)) & MASK
    s = int(round(math.sin(-2 * math.pi * k / N) * SCALE)) & MASK
    return c, s

def sgn(v, w):
    m = 1 << (w - 1)
    v &= (1 << w) - 1
    return v - (1 << w) if v >= m else v

def rnd_shr(v, sh):
    """round half up + 算术右移 (镜像 SV: (v + 2^(sh-1)) >>> sh)"""
    return (v + (1 << (sh - 1))) >> sh

def fft_model(x_i, x_q, B):
    """与 RTL 逐位相同的迭代 DIT radix-2 模型 (无逐级缩放)"""
    WI = B + LG + 1
    xi = [sgn(v, B) for v in x_i]
    xq = [sgn(v, B) for v in x_q]
    # 位倒序装载 (输入自然序 -> RAM 位倒序地址)
    def bitrev(k):
        r = 0
        for _ in range(LG):
            r = (r << 1) | (k & 1); k >>= 1
        return r
    a_i = [0] * N; a_q = [0] * N
    for n in range(N):
        a_i[bitrev(n)] = xi[n]; a_q[bitrev(n)] = xq[n]
    # LG 级蝶形
    for m in range(1, LG + 1):
        half = 1 << (m - 1)
        for k in range(N // 2):
            g   = k // half
            pos = k % half
            aa  = (g << m) + pos
            bb  = aa + half
            tw_idx = pos << (LG - m)
            wc, ws = tw(tw_idx)
            wc = sgn(wc, WT); ws = sgn(ws, WT)
            bi, bq = a_i[bb], a_q[bb]
            pi = rnd_shr(bi * wc - bq * ws, WT - 1)     # 复数乘 (b * w)
            pq = rnd_shr(bi * ws + bq * wc, WT - 1)
            ai, aq = a_i[aa], a_q[aa]
            a_i[aa] = sgn(ai + pi, WI); a_q[aa] = sgn(aq + pq, WI)
            a_i[bb] = sgn(ai - pi, WI); a_q[bb] = sgn(aq - pq, WI)
    return a_i, a_q, WI

def check(name, xf):
    B = 16
    xi = [int(round(v * (1 << (B - 1)))) for v in xf.real]
    xq = [int(round(v * (1 << (B - 1)))) for v in xf.imag]
    oi, oq, WI = fft_model(xi, xq, B)
    ref = np.fft.fft(xf)
    err = max(max(abs(oi[k] / (1 << (B - 1)) - ref[k].real) for k in range(N)),
              max(abs(oq[k] / (1 << (B - 1)) - ref[k].imag) for k in range(N)))
    print("  %-12s 模型 vs numpy: max_err = %.4f LSB(输入标度)  [WI=%d]" % (name, err, WI))
    return err

print("== coef_fft_%d_w%d model cross-check ==" % (N, WT))
x = np.zeros(N, dtype=complex); x[0] = 0.5
check("impulse", x)
x = np.full(N, 0.25 + 0j)
check("dc", x)
x = np.exp(2j * np.pi * 5 * np.arange(N) / N) * 0.4
check("tone@5", x)
rng = np.random.default_rng(7)
x = (rng.uniform(-1, 1, N) + 1j * rng.uniform(-1, 1, N)) * 0.5
check("random", x)

# 写 ROM 文件
path = "coef_fft_%d_w%d.mem" % (N, WT)
with open(path, "w") as f:
    f.write("// twiddle ROM: e^{-j2*pi*k/%d}, Q1.%d, k=0..%d; 每行 cos,sin\n"
            % (N, WT - 1, N // 2 - 1))
    for k in range(N // 2):
        c, s = tw(k)
        f.write("%0*x%0*x\n" % (WT // 4, c, WT // 4, s))
print("written %s (%d lines)" % (path, N // 2))
