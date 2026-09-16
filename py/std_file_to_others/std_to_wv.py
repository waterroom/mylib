#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""将 SDR 采集的 .STD 峰域转换为 R&S 兼容 .wv I/Q 波形文件 (A100 信号源导入)。

字节布局完全对齐 data/rs_generate_wave.m (R&S MATLAB Toolkit 官方函数)
与 data/std_to_wv_or_bin.m 的 .wv 分支:

    {TYPE: SMU-WV, 0}{COMMENT: ...}{ORIGIN INFO: RS Matlab Toolkit}
    {LEVEL OFFS: <rms-dB>, <peak-dB>}{DATE: <dd-Mmm-yyyy>;<HH:MM:SS>}
    {CLOCK: <fs>}{SAMPLES: <N>}{WAVEFORM-<4N+3>: #<int16 IQ 交织, 小端>}

与参考脚本一致的信号处理:
- 不做 dechirp (WiFi 信号载波在信道中心, 不是 std_to_cs16 的模拟视频 FM 场景);
- 不去直流 (参考脚本 .wv 分支直接用 datai/dataq);
- 包络峰值归一化到 1.0 (IQinfo.no_scaling 缺省=0 -> 自动缩放);
- 量化 floor(v*10000 + 0.5) 到 int16 (±10000 刻度, 同 rs_generate_wave.m);
- 不做 std_to_wv_or_bin.m 的 .bin 分支里的 ±100 kHz 频谱复制 (那会镜像出
  ±100 kHz 两个副本, 对 ESP32 WiFi 回放有害; 参考脚本 .wv 分支本就不用)。

用法:
  python std_to_wv.py UAV_DJ_WIFI_ag.std -o UAV_DJ_WIFI_ag.wv
"""
import argparse
import os
import struct
import sys
from datetime import datetime

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

try:
    from std_to_cs16 import parse_std_header, DATATYPES, is_real_signal
except ImportError:
    # 独立运行兜底: 头解析仅依赖 std 50 字节布局, 与 std_to_cs16 一致
    def parse_std_header(path):
        with open(path, "rb") as f:
            h = f.read(50)
        if len(h) < 50:
            raise ValueError("文件不足 50 字节头")
        d = {
            'sampling_time': h[0:9],
            'datatype': h[9],
            'signaltype': struct.unpack_from('<H', h, 10)[0],
            'mirror': struct.unpack_from('<H', h, 12)[0],
            'channelnum': struct.unpack_from('<H', h, 14)[0],
            'channelid': struct.unpack_from('<H', h, 16)[0],
            'turnfreq': struct.unpack_from('<d', h, 18)[0],
            'intermfreq': struct.unpack_from('<d', h, 26)[0],
            'channelwidth': struct.unpack_from('<d', h, 34)[0],
            'samplingfreq': struct.unpack_from('<d', h, 42)[0],
        }
        return d

    DATATYPES = {
        0: ('char', np.int8, 1),
        1: ('short', np.int16, 2),
        2: ('int', np.int32, 4),
        3: ('float', np.float32, 4),
        4: ('double', np.float64, 8),
    }

    def is_real_signal(h):
        cw, sf = h['channelwidth'], h['samplingfreq']
        return cw > 0 and sf > 0 and abs(cw - sf) < max(1.0, 1e-6 * sf)

# ---- R&S .wv 标签常量 (参考 rs_generate_wave.m, 若 A100 软件仍不认,
#      用它能导出的样例 .wv 对照修改这里) ----
WV_TYPE = "{TYPE: SMU-WV, 0}"
WV_COMMENT = "{COMMENT: Waveform converted from .MAT file}"
WV_ORIGIN = "{ORIGIN INFO: RS Matlab Toolkit}"
WV_SCALE = 10000.0  # rs_generate_wave.m: IQ_data = floor(IQ_data*10000+0.5)

_MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def num2str(x):
    """近似 MATLAB num2str 默认格式: 整数全量打印, 小数 4 位有效数字。"""
    v = float(x)
    if abs(v) < 1e16 and v == round(v):
        return str(int(v))
    return "%.4g" % v


def build_wv(iq, fs, now=None, scale=WV_SCALE):
    """按 rs_generate_wave.m 的字节布局生成完整 .wv 字节。

    iq: 复数 I/Q (浮点); fs: 时钟率 Hz; 返回 (bytes, 峰值/rms 统计)。
    """
    now = now or datetime.now()
    z = np.asarray(iq, dtype=np.complex128)
    peak_env = float(np.max(np.abs(z)))
    if peak_env <= 0:
        raise SystemExit("[std2wv] 错误: 信号全零")
    z = z / peak_env
    rms = float(np.sqrt(np.mean(np.abs(z) ** 2)))
    crf = 20.0 * np.log10(1.0 / rms) if rms > 0 else 0.0

    Iq = np.floor(z.real * scale + 0.5).astype('<i2')
    Qq = np.floor(z.imag * scale + 0.5).astype('<i2')
    n = len(z)
    interleaved = np.empty(n * 2, dtype='<i2')
    interleaved[0::2] = Iq
    interleaved[1::2] = Qq

    head = (WV_TYPE + WV_COMMENT + WV_ORIGIN
            + "{LEVEL OFFS: %s, %s}"
            % (num2str(20 * np.log10(1.0 / rms)), num2str(0.0))
            + "{DATE: %s;%s}"
            % (now.strftime("%d-%b-%Y"), now.strftime("%H:%M:%S"))
            + "{CLOCK: %s}" % num2str(fs)
            + "{SAMPLES: %d}" % n
            + "{WAVEFORM-%d: #" % (4 * n + 3))
    return head.encode('ascii') + interleaved.tobytes() + b'}', \
        peak_env, rms, crf, n


def main():
    ap = argparse.ArgumentParser(description=".STD -> .wv (R&S 兼容 I/Q 波形)")
    ap.add_argument("std", help="输入 .STD 文件")
    ap.add_argument("-o", "--out", default=None, help="输出 .wv (默认 <输入去扩展>.wv)")
    ap.add_argument("--fs", type=float, default=None, help="时钟率 Hz (缺省用头内 samplingfreq)")
    ap.add_argument("--header", type=int, default=None, help="覆盖头字节数 (默认 50)")
    ap.add_argument("--scale", type=float, default=WV_SCALE,
                    help="输出峰值刻度 int16 (默认 10000, 与 rs_generate_wave.m 一致; "
                         "最大 32000 左右留削顶余量, 例如 30000 ≈ +9.5dB)")
    ap.add_argument("--force-real", action="store_true", help="强制按实信号处理 (Hilbert)")
    ap.add_argument("--force-complex", action="store_true", help="强制按复信号处理 (I/Q 交织)")
    args = ap.parse_args()

    # ---- 头解析 ----
    hdr = args.header if args.header is not None else 50
    h = None
    try:
        h = parse_std_header(args.std)
        dt_name, dt_np, dt_size = DATATYPES.get(h['datatype'], ('?', np.int16, 2))
        print("[std2wv] 头: datatype=%s(%s,%dB)  channelnum=%s  signaltype=%s"
              % (h['datatype'], dt_name, dt_size, h['channelnum'], h['signaltype']))
        print("[std2wv]     turnfreq=%.6gHz  intermfreq=%.6gHz  "
              "channelwidth=%.6gHz  samplingfreq=%.6gHz"
              % (h['turnfreq'], h['intermfreq'], h['channelwidth'], h['samplingfreq']))
    except ValueError as e:
        print("[std2wv] 警告: 标准头解析失败(%s)" % e)
        dt_name, dt_np, dt_size = ('short', np.int16, 2)

    fs = args.fs
    if fs is None and h is not None and h['samplingfreq'] > 0:
        fs = h['samplingfreq']
    if fs is None:
        raise SystemExit("[std2wv] 错误: 未解析到采样率, 请用 --fs 指定")

    # ---- 实/复判据 ----
    if args.force_real and args.force_complex:
        raise SystemExit("[std2wv] 错误: --force-real 与 --force-complex 互斥")
    if args.force_real:
        real_sig = True
    elif args.force_complex:
        real_sig = False
    elif h is not None:
        real_sig = is_real_signal(h)
    else:
        real_sig = False
    print("[std2wv] 信号类型: %s"
          % ('实信号(单通道, Hilbert)' if real_sig else '复信号(I/Q 交织)'))

    # ---- 读数据 ----
    fsize = os.path.getsize(args.std)
    avail = (fsize - hdr) // dt_size
    with open(args.std, "rb") as f:
        f.seek(hdr)
        data = np.frombuffer(f.read(avail * dt_size), dtype=dt_np)
    if len(data) < 2:
        raise SystemExit("[std2wv] 错误: 数据不足")

    if real_sig:
        from scipy.signal import hilbert
        iq = hilbert(np.asarray(data, dtype=np.float64))
    else:
        if len(data) % 2:
            data = data[:-1]
        iq = np.asarray(data[0::2], dtype=np.float64) \
             + 1j * np.asarray(data[1::2], dtype=np.float64)
    del data
    print("[std2wv] 复数样点 %d @ %.3fMHz = %.3fms"
          % (len(iq), fs / 1e6, len(iq) / fs * 1e3))

    # ---- 生成 .wv (归一化 + 量化 + R&S 标签) ----
    out = args.out or (os.path.splitext(args.std)[0] + ".wv")
    blob, peak_env, rms, crf, n = build_wv(iq, fs, scale=args.scale)
    with open(out, "wb") as f:
        f.write(blob)
    print("[std2wv] 包络峰值=%.4g -> 归一化 1.0; rms=%.4g; 峰均比=%.3g dB"
          % (peak_env, rms, crf))
    print("[std2wv] -> %s (%d 组 I/Q, int16 ±%d 刻度, %.1f KB)"
          % (out, n, int(args.scale), len(blob) / 1024))
    print("[std2wv] 相对默认10000增益: %+.1f dB" % (20*np.log10(args.scale/WV_SCALE)))

    # ---- 读回校验: 按 {WAVEFORM-<len>: # 定位数据, 与源 int16 逐点比对 ----
    with open(out, "rb") as f:
        raw = f.read()
    tag = b"{WAVEFORM-"
    i = raw.find(tag)
    j = raw.find(b": #", i)
    if i < 0 or j < 0:
        raise SystemExit("[std2wv] 错误: 读回校验失败, 找不到 WAVEFORM 标签")
    wv_len = int(raw[i + len(tag):j])
    body = raw[j + 3:]
    # 标签内 4N+3 = '#'+'}' 等 3 字节 + 数据 4N; 数据区取 wv_len-3 字节, 之后应正好是 '}'
    if len(body) < wv_len - 3:
        raise SystemExit("[std2wv] 错误: 读回校验失败, 数据不足 "
                         "(文件尾 %d 字节 < 标签 %d-3)" % (len(body), wv_len))
    back = np.frombuffer(body[:wv_len - 3], dtype='<i2').reshape(n, 2)
    # 重算期望 int16 (与 build_wv 相同的归一化/量化)
    peak = np.max(np.abs(iq))
    z = iq / peak
    exp_i = np.floor(z.real * args.scale + 0.5).astype('<i2')
    exp_q = np.floor(z.imag * args.scale + 0.5).astype('<i2')
    max_err = int(np.max(np.abs(back[:, 0].astype(np.int32) - exp_i.astype(np.int32))
                         + np.abs(back[:, 1].astype(np.int32) - exp_q.astype(np.int32))))
    print("[std2wv] 读回校验: %s" % ('OK' if max_err == 0 else 'FAIL (err=%d)' % max_err))

    # ---- 加载参数提示 ----
    if h is not None and h['turnfreq'] > 0:
        freq_hint = "%.6g Hz" % h['turnfreq']
    else:
        freq_hint = "头内为 0, 回放频点自选 (DJI 文件同场景为 2437MHz/WiFi ch6)"
    print("[std2wv] A100 加载: CLOCK=%.3f MHz, RF 中心=%s, 循环触发"
          % (fs / 1e6, freq_hint))
    print("[std2wv] 验证判据: ESP32 接收板出 \"interface\":\"WiFi Beacon\" JSON 即通过")


if __name__ == "__main__":
    main()