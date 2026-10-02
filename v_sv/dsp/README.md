# v_sv/dsp —— 通信 / 雷达接收机定点 DSP 积木

与 `v_sv/xpm_wrappers` 平级的第二个家族:**纯 RTL** 定点 DSP 模块,天然跨厂商,
不依赖 XPM(需要存储器时下沉到 `xpm_sdpram`);复位/流控等基础设施反向消费
xpm_wrappers。收"接收机里反复出现、IP 不占优、接口可参数化、可自检"的模块,
不收 FIR/FFT/CORDIC 大核以外的 IP 替代品。

## 验证方法(与 xpm_wrappers 的本质区别)

xpm_wrappers 验证的是**协议**,dsp 家族验证的是**数值**:TB 内置 real-math
参考模型(`$sin/$cos/$atan2/$hypot` 定点化)逐点对拍,容差按 LSB 计,
输出 MAX_ERR 统计。MATLAB 对拍 harness(`matlab/+dsp/`)规划中,建好后
作为复杂数学模块(滤波器/检测器)的标准验证件。

统一约定:定点 Q 格式显式标注;流接口 `in_valid/in_data → out_valid/out_data`
(无 ready——DSP 块恒速,背压交给 FIFO 层);复位高有效(纯数据流水线多数
无复位需求);每个模块自带参数预检 + 对拍 tb + 事实清单。

## 文件清单

| 文件 | 模块 | 用途 | 状态 |
| --- | --- | --- | --- |
| `dsp_cordic.sv` | `dsp_cordic` | CORDIC 核:旋转(sin/cos)+ 矢量(幅/相)双模式 | v1.0,312 项对拍 |
| `dsp_cic_decim.sv` | `dsp_cic_decim` | CIC 抽取滤波器(参数化 N/R,DC 增益 1,免乘法) | v1.0,67 项位精确对拍 |
| `sim/tb_dsp_cordic.sv` `sim/tb_dsp_cic_decim.sv` | — | real-math / longint 位精确对拍自检 | 合计 379 项检查 |
| `sim/run_xsim.sh` | — | 单版本跑自检(纯 RTL,无需 XPM 源;两个 top 依次跑) | |
| `synth/synth_top.sv` `synth/synth_check.tcl` | — | 综合冒烟(查零警告与资源) | |

## dsp_cordic 速查

| 项 | 说明 |
| --- | --- |
| 模式 | `MODE="rotate"`(相位 → sin/cos,NCO/DDS 核心)/ `"vector"`((x,y) → 幅/相,IFM 前置) |
| 相位 | `P_DW` 位无符号 [0, 2π),LSB = 2π/2^P_DW |
| 数据 | `D_DW` 位 Q1.(D-1) 二补码;sin/cos 峰值 +1.0 饱和到 2^(D-1)−1 |
| 幅值 | vector 输出 = \|v\|·2^(D-1) 无符号无饱和(\|v\| 最大 √2);GAIN_COMP=1 补 1/K(1 个 DSP48),=0 时输出 K·\|v\|·2^(D-2) 且 \|v\|≤1 |
| 延迟 | STAGES + 2 拍,out_valid 逐笔对应 |
| 精度 | 实测(D=16, S=16, P=16):sin/cos ±3 LSB、mag ±1 LSB、phase ±1 LSB;rotate 满幅比理想 FS 低 ~3.3 LSB(x0 防饱和余量,见事实 #6) |
| 资源 | rotate:D 位直通 + 预旋转,无饱和器;vector:D+4 位 + 归一化移位器;1/K 补偿为 CSD 移位加。xczu48dr 两模式合计 2414 LUT / 1761 FF / **0 DSP48** |

### dsp_cic_decim 速查

| 项 | 说明 |
| --- | --- |
| 接口 | `rst`(高有效同步清零,可接 0)+ `in_valid/in_data[B_IN]` → `out_valid/out_data[B_OUT]`;out_valid 每 R 个输入样一个 |
| 参数 | `N` 级数 1..8(默认 3)/ `R` 抽取比 **2 的幂** 2..2^16(默认 64)/ `B_IN` 4..32 / `B_OUT` ≤ B_IN+N·log2(R) / `ROUND`(1 = round half up) |
| 性质 | DC 增益恰 1(稳态 out == in,免标定);零点在 f = k·f_s/R;位增长 G = N·log2(R),内部宽 B_IN+G 无损;免乘法 |
| 瞬态 | 前 N 个输出样(三阶差分窗填充,实测 N=3 时第 3 个输出起稳态) |
| 资源 | 纯加法/移位,0 DSP48;xczu48dr 合计(含两个 CORDIC)2627 LUT / 2111 FF |
| 限制 | **抽取比 R 编译期固化,不支持运行时切换**。运行时变 R 的两条可行路径:(a) 多实例(不同 R)+ 输出 mux;(b) ADI 式把各级采样使能外置由系统采样时序生成(library/util_cic 的做法)。**不要用独立模块内部的多级 toggle 门控**——实测各级 tog 与数据脉冲同拍耦合会产生级间锁相死锁(某级使能恒 0,断链),这是把 ADI 结构模块化时最容易踩的坑 |

**已验证的事实(dsp 家族 #1~#7,2022.1 实测,三版本回归一致):**

1. **纯截断右移的偏移不可接受**:每级 `>>>` 向下取整,16 级累积成
   sin/cos **±7 LSB** 的输出误差(实测);每级加 round-half-up 后降到
   **±3 LSB**。整数域 CORDIC 的移位必须带舍入。
2. **atan 表量化误差要求内部相位加宽**:α 表缩到 P_DW 位时每级 ±0.5 LSB
   相位误差累积成 sin/cos ±5 LSB;内部 z 用 **P_DW+4** 位后降到 ±3 LSB。
   (输出精度要求高时,内部相位/数据通路各加宽 4/4 bit 是标准配置)
3. **矢量模式必须输入归一化**:小幅输入 (1,1)/(0,0) 时修正项 `x>>>g`
   舍入为 0,z 直接卡死在 Σα(实测相位差 1.74 rad)。解法:输入左移到
   MSB 就位(优先编码器 + 桶形移位),移位量随流水带到输出除回。
4. **归一化余量公式**:峰值 = K·√2·FS·2^s,归一化目标位取 **DWI−4**
   (即 D_DW)时峰值 = 0.58·2^(DWI-1) 与输入 MSB 无关。目标位 DWI−2/
   DWI−3 都实测在对角角点溢出(对角输入比轴上多 √2,迭代再乘 K,
   两级余量都不能省)。
5. **`x=y=0` 时 out_phase 无意义**(z 累满 Σα ≈ 1.74 rad),atan2(0,0)
   本身无定义;mag 恒 0。TB 对该角点只查幅值。
6. **ADI 式三个瘦身手段**(对拍对齐 ADI 后重写,资源 9 DSP48 → 0):
   * **输入预旋转代替输出拼装**:象限折叠进初始向量(q=01 → (0,+X),
     q=10 → (0,−X)),输出直接 x=cos/y=sin,省掉 4 路 16 位拼装 mux;
   * **x0 防饱和余量代替饱和器**:x0 = round(FS/K) − 2,峰值 = FS−3.3
     天然不越界;代价是全部输出比理想满幅低 ~3.3 LSB —— 对拍参考的
     幅度基准必须与 DUT 对齐(K·X0),否则全样本假失败;
   * **1/K 补偿用 CSD 移位加**:1/K = 2^-1+2^-3−2^-6−2^-9−2^-12+
     2^-14+2^-16(7 项,逼近误差 0.036 LSB),7 个加法器替代 19×19
     常数乘的 9 个 DSP48。
7. **CIC 采样寄存器必须条件锁存**(对拍实测的真 bug):`c[0] <= acc[N-1]`
   若写成每拍无条件跟随(而非仅采样拍锁存),comb 窗会被采样后的
   acc 继续积累污染,输出对应"非整数个样"的窗(144 对 151,手算
   无法解释的量级)——位精确对拍一跑即现。
8. **CIC 的瞬态与相位**:非阻塞级联积分器第 N 级滞后 2 拍(第 k 样
   的完整贡献在 k+2 拍才进 acc[N-1]),叠加 comb 链填充,DC 输入下
   前 N−1 个输出样是瞬态(实测 N=3:第 3 个输出起稳态 == 输入);
   TB 参考必须镜像 RTL 的非阻塞语义(阻塞级联会与 RTL 差 N 拍,
   输出窗错位)。

参考:ADI hdl `library/common/ad_dds_cordic_pipe.v`(单级旋转结构参照,
本模块为独立自写实现);Ray Andraka, "A Survey of CORDIC Algorithms for
FPGA Based Computers"。

## 路线图

`nco`(查表 1/4 波压缩)→ `cic_decim`(R/N/M 参数化)→ `ddc_ch`(NCO+CIC
信道单元)→ `timebase` + `detector` + `pdw_meas`(测量链)。MATLAB 对拍
harness 在 nco 之前落地。

## 验证

```bash
# 行为自检: 312 项对拍检查
bash sim/run_xsim.sh            # 默认 Vivado 2022.1
VIVADO_ROOT=/d/Xilinx/Vivado/2024.2 bash sim/run_xsim.sh   # 换版本

# 综合冒烟: 查 DSP48 映射
vivado -mode batch -source synth/synth_check.tcl -tclargs xczu48dr-ffvg1517-2-e
```

已回归:Vivado 2018.3 / 2022.1 / 2024.2 三版本 312 项全过;xczu48dr 综合
零 ERROR / 零 critical warning,DSP48 = 1。
