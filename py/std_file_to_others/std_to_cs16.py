#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""将 SDR 采集的 .STD 转换为 .cs16 (交织 int16 复数 I/Q)。

【2026-09-01 重大修复】旧版硬编码按 int16 读数据, 但 STD 头 datatype 字段
决定了真实类型。FS27MHz 系列 datatype=3(float32) 被当 int16 读 -> 频谱全是
噪声伪迹、自相关无峰、FM 解调全错。本版按 datatype 正确解析。

STD 头格式 (50 字节):
    offset  size  字段
    0       9     samplingTime (uint8[9])
    9       1     datatype   (0=char 1=short 2=int 3=float 4=double)
    10      2     signaltype (uint16)
    12      2     Mirror     (uint16)
    14      2     channelnum (uint16)
    16      2     channelID  (uint16)
    18      8     turnfreq     (double, 调谐频率 Hz)
    26      8     intermfreq   (double, 中频 Hz)
    34      8     channelwidth (double, 信道带宽 Hz)
    42      8     samplingfreq (double, 采样率 Hz)  <-- 采样率权威来源
    50 ...        数据: 按 datatype 交织 (复信号 I/Q) 或单通道 (实信号)

实/复信号判据 (项目经验):
    channelwidth == samplingfreq -> 实信号 (单通道) -> 需 Hilbert 生成解析信号
    channelwidth == 0            -> 复信号 (I/Q 交织) -> 直接分离 I/Q
    (可用 --force-real / --force-complex 覆盖)

频偏处理:
    模拟视频 FM: 载波常在 2~5MHz (SDR 本振偏置)。默认自动 dechirp:
    取复谱峰 (排除 DC 与 fs/4 伪迹), 若 |f| > 0.02*fs 则混频到零中频。
    用 --no-dechirp 关闭, 或 --dechirp-freq 手动指定。

输出: 归一化到 ±scale (默认 30000, 留 int16 余量避免削顶)。

用法:
  # 常规: 自动判类型/实复/dechirp
  python py/std_file_to_others/std_to_cs16.py data/xxx_FS27MHz_csSwith.STD -o data/xxx_27m.cs16
  # 只取前 20M 样点 (控制内存/时长)
  python py/std_file_to_others/std_to_cs16.py in.STD --nsamp 20000000
  # 不做频偏补偿 (信号已在零中频)
  python py/std_file_to_others/std_to_cs16.py in.STD --no-dechirp
  # 手动指定频偏
  python py/std_file_to_others/std_to_cs16.py in.STD --dechirp-freq 3.68e6
"""
import argparse
import os
import struct
import numpy as np

DEFAULT_HEADER = 50
# datatype -> (名称, numpy dtype, 每样本字节数)
DATATYPES = {
    0: ('char',   np.int8,   1),
    1: ('short',  np.int16,  2),
    2: ('int',    np.int32,  4),
    3: ('float',  np.float32, 4),
    4: ('double', np.float64, 8),
}


def parse_std_header(path):
    """解析 STD 50 字节头。"""
    with open(path, "rb") as f:
        h = f.read(DEFAULT_HEADER)
    if len(h) < DEFAULT_HEADER:
        raise ValueError("文件不足 50 字节头")
    d = {}
    d['sampling_time'] = h[0:9]
    d['datatype'] = h[9]
    d['signaltype'], d['mirror'], d['channelnum'], d['channelid'] = struct.unpack_from('<4H', h, 10)
    d['turnfreq'], d['intermfreq'], d['channelwidth'], d['samplingfreq'] = struct.unpack_from('<4d', h, 18)
    return d


def is_real_signal(h):
    """实信号判据: channelwidth == samplingfreq (非零)。"""
    cw, sf = h['channelwidth'], h['samplingfreq']
    return cw > 0 and sf > 0 and abs(cw - sf) < max(1.0, 1e-6 * sf)


def hilbert_blockwise(x, block=4_000_000, overlap=2048):
    """分块 Hilbert, 控制大文件内存; overlap 抑制块边界效应。"""
    from scipy.signal import hilbert
    n = len(x)
    out = np.empty(n, dtype=np.complex128)
    pos = 0
    while pos < n:
        s = max(0, pos - overlap)
        e = min(n, pos + block + overlap)
        seg = np.asarray(x[s:e], dtype=np.float64)
        ana = hilbert(seg)
        a = pos - s
        b = a + min(block, n - pos)
        out[pos:pos + (b - a)] = ana[a:b]
        pos += block
    return out


def find_carrier(iq, fs):
    """复谱峰找载波 (排除 DC 与 fs/4 伪迹)。返回 (频率Hz, 峰功率dB, DC功率dB, fs4功率dB)。"""
    n = min(len(iq), 1 << 20)
    seg = iq[:n]
    F = np.fft.fftshift(np.fft.fftfreq(n, 1.0 / fs))
    P = np.abs(np.fft.fftshift(np.fft.fft(seg)))
    Pdb = 10.0 * np.log10(P ** 2 / (P.max() ** 2) + 1e-30)
    f4 = fs / 4.0
    dc_mask = np.abs(F) < 50e3
    f4_mask = np.abs(np.abs(F) - f4) < 3e6
    valid = (~dc_mask) & (~f4_mask) & (np.abs(F) < 0.49 * fs)
    if not valid.any():
        return 0.0, Pdb.max(), Pdb[dc_mask].max() if dc_mask.any() else -np.inf, \
               Pdb[f4_mask].max() if f4_mask.any() else -np.inf
    idx = np.flatnonzero(valid)[np.argmax(Pdb[valid])]
    return float(F[idx]), float(Pdb[idx]), \
           float(Pdb[dc_mask].max()) if dc_mask.any() else -np.inf, \
           float(Pdb[f4_mask].max()) if f4_mask.any() else -np.inf


def main():
    ap = argparse.ArgumentParser(description=".STD -> .cs16 (datatype 感知, 自动实/复 + dechirp)")
    ap.add_argument("std", help="输入 .STD 文件")
    ap.add_argument("-o", "--out", default=None, help="输出 .cs16 (默认 <输入去扩展>.cs16)")
    ap.add_argument("--fs", type=float, default=None, help="采样率 Hz (缺省用头内 samplingfreq)")
    ap.add_argument("--header", type=int, default=None, help="覆盖头字节数 (默认 50)")
    ap.add_argument("--nsamp", type=int, default=None, help="最多处理的复数样点数 (控制内存/时长)")
    ap.add_argument("--scale", type=float, default=30000.0, help="输出峰值幅度 (默认 30000)")
    ap.add_argument("--no-dechirp", action="store_true", help="关闭自动频偏补偿")
    ap.add_argument("--dechirp-freq", type=float, default=None, help="手动指定频偏 Hz (覆盖自动检测)")
    ap.add_argument("--dechirp-thr", type=float, default=0.02,
                    help="自动 dechirp 触发阈值 (|f|/fs, 默认 0.02)")
    ap.add_argument("--force-real", action="store_true", help="强制按实信号处理 (Hilbert)")
    ap.add_argument("--force-complex", action="store_true", help="强制按复信号处理 (I/Q 交织)")
    args = ap.parse_args()

    # ---- 头解析 ----
    hdr = args.header if args.header is not None else DEFAULT_HEADER
    h = None
    try:
        h = parse_std_header(args.std)
        dt_name, dt_np, dt_size = DATATYPES.get(h['datatype'], ('?', np.int16, 2))
        print(f"[std2cs16] 头: datatype={h['datatype']}({dt_name},{dt_size}B)  "
              f"channelnum={h['channelnum']}  signaltype={h['signaltype']}")
        print(f"[std2cs16]     turnfreq={h['turnfreq']:.6g}Hz  intermfreq={h['intermfreq']:.6g}Hz  "
              f"channelwidth={h['channelwidth']:.6g}Hz  samplingfreq={h['samplingfreq']:.6g}Hz")
    except ValueError as e:
        print(f"[std2cs16] 警告: 标准头解析失败({e})")
        dt_name, dt_np, dt_size = ('short', np.int16, 2)

    fs = args.fs
    if fs is None and h is not None and h['samplingfreq'] > 0:
        fs = h['samplingfreq']
    if fs is None:
        raise SystemExit("[std2cs16] 错误: 未解析到采样率, 请用 --fs 指定")

    if h['datatype'] == 3:
        print(f"[std2cs16] 注意: datatype=3(float32) -> 按 float32 解析 (旧版按 int16 读是错的)")

    # ---- 实/复判据 ----
    if args.force_real and args.force_complex:
        raise SystemExit("[std2cs16] 错误: --force-real 与 --force-complex 互斥")
    if args.force_real:
        real_sig = True
    elif args.force_complex:
        real_sig = False
    elif h is not None:
        real_sig = is_real_signal(h)
    else:
        real_sig = False
    print(f"[std2cs16] 信号类型: {'实信号(单通道, 需 Hilbert)' if real_sig else '复信号(I/Q 交织)'}")

    # ---- 读数据 ----
    fsize = os.path.getsize(args.std)
    avail = (fsize - hdr) // dt_size
    nread = avail
    if args.nsamp is not None and args.nsamp > 0:
        nread = min(avail, args.nsamp * (2 if not real_sig else 1))
    print(f"[std2cs16] 文件 {fsize/1e6:.1f}MB, 可读 {avail/1e6:.2f}M 样本, 本次处理 {nread/1e6:.2f}M")

    with open(args.std, "rb") as f:
        f.seek(hdr)
        data = np.frombuffer(f.read(nread * dt_size), dtype=dt_np)
    if len(data) < 2:
        raise SystemExit("[std2cs16] 错误: 数据不足")

    # ---- 构造复数 I/Q ----
    if real_sig:
        # 实信号: 全部样本是单通道实值 -> Hilbert 生成解析信号
        x = np.asarray(data, dtype=np.float64)
        iq = hilbert_blockwise(x)
        print(f"[std2cs16] Hilbert 完成: 实信号 {len(x)/1e6:.2f}M -> 解析信号")
    else:
        # 复信号: 交织 I/Q
        if len(data) % 2:
            data = data[:-1]
        I = np.asarray(data[0::2], dtype=np.float64)
        Q = np.asarray(data[1::2], dtype=np.float64)
        iq = I + 1j * Q

    n_cplx = len(iq)
    del data

    # ---- 去 IQ 直流 ----
    iq = iq - np.mean(iq)

    # ---- 频偏补偿 (dechirp) ----
    f_res = 0.0
    if args.dechirp_freq is not None:
        f_res = args.dechirp_freq
        print(f"[std2cs16] dechirp (手动): {f_res/1e6:+.4f} MHz")
    elif not args.no_dechirp:
        f_peak, p_peak, p_dc, p_f4 = find_carrier(iq, fs)
        print(f"[std2cs16] 谱峰: {f_peak/1e6:+.4f}MHz ({p_peak:+.1f}dB)  "
              f"DC={p_dc:+.1f}dB  fs/4={p_f4:+.1f}dB")
        if abs(f_peak) > args.dechirp_thr * fs:
            f_res = f_peak
            print(f"[std2cs16] dechirp (自动): {f_res/1e6:+.4f} MHz -> 零中频")
        else:
            print(f"[std2cs16] 谱峰接近零中频 (<{args.dechirp_thr}*fs), 不 dechirp")
    else:
        print("[std2cs16] dechirp: 关闭 (--no-dechirp)")

    if f_res != 0.0:
        t = np.arange(len(iq), dtype=np.float64) / fs
        iq = iq * np.exp(-1j * 2.0 * np.pi * f_res * t)

    # ---- 归一化到 int16 ----
    amp = np.abs(iq)
    peak = np.percentile(amp, 99.9)
    if peak <= 0:
        raise SystemExit("[std2cs16] 错误: 信号全零")
    k = args.scale / peak
    z = iq * k
    # 硬限幅防削顶溢出
    I2 = np.clip(np.round(z.real), -32768, 32767).astype('<i2')
    Q2 = np.clip(np.round(z.imag), -32768, 32767).astype('<i2')

    out = args.out or (os.path.splitext(args.std)[0] + ".cs16")
    interleaved = np.empty(n_cplx * 2, dtype='<i2')
    interleaved[0::2] = I2
    interleaved[1::2] = Q2
    with open(out, "wb") as f:
        f.write(interleaved.tobytes())

    print(f"[std2cs16] -> {out}")
    print(f"[std2cs16] {n_cplx} 复数样点 @ {fs/1e6:.3f}MHz = {n_cplx/fs:.3f}s, "
          f"峰值归一到 {args.scale:.0f} (p99.9 拉伸)")
    print(f"[std2cs16] 下游: python tools/render_cvbs.py --iq {out} --fs {fs:.0f} "
          f"--std pal|ntsc --sync-source grid -o out.png")


if __name__ == "__main__":
    main()
