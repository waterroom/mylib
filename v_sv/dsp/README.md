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
| `dsp_pfir.sv` | `dsp_pfir` | 多相滤波器组 FIR(PFB 信道化滤波级,时分复用 MAC) | v1.0,901 项位精确对拍 |
| `dsp_fft.sv` | `dsp_fft` | N 点复 FFT(迭代式 radix-2, in-place BRAM, 定长突发) | v1.0,644 项位精确对拍 |
| `dsp_chan.sv` | `dsp_chan` | **多相信道化器**(IQ 入 → N 复数信道出, pfir×2+FIFO+fft 装配) | v1.0,多音系统级 7 项 |
| `sim/tb_dsp_*.sv` (5 个) | — | 位精确对拍 + 系统级多音注入自检 | 合计 1931 项检查 |
| `sim/gen_coef_pfir.py` `sim/coef_pfir_64x8.mem` | — | PFB 原型系数生成脚本与系数文件 | |
| `sim/gen_coef_fft.py` `sim/coef_fft_64_w16.mem` | — | FFT twiddle 生成脚本(含 numpy 交叉验证)与系数文件 | |
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

### dsp_pfir 速查

| 项 | 说明 |
| --- | --- |
| 接口 | `rst`(高有效)+ `in_valid/in_data[B_IN]` → `out_valid/out_data[B_OUT]/out_frame`(帧首标记);每输入 N 样输出一帧 N 个信道值,顺序 p=0..N-1 |
| 参数 | `N` 信道数(2 的幂 4..1024)/ `K` 每相抽头(2..64)/ `B_IN`/`B_CO` 系数位宽/ `B_OUT`/ `ROUND`/ `COEF_FILE` |
| 数学 | y_p[m] = Σ_r h[p+rN]·x[mN+p−rN];系数布局 **h[p + r*N]**;DC 增益 1(sum(h)=2^(B_CO-1)) |
| 输入率 | 每帧 N 样后需 ≥ N·(K+1) 拍计算间隙(时分复用 1 个乘法器;后 CIC 场景恒满足) |
| 资源 | 1 个乘法器 + 循环缓冲 LUTRAM((K+1)·N 深);xczu48dr 合计(四模块)DSP48=9 / 3204 LUT / 2232 FF |

### dsp_fft 速查

| 项 | 说明 |
| --- | --- |
| 接口 | `in_valid/in_ready` 收 N 个复样(每拍 1 个), 蝶形后 unload 阶段 `out_valid/out_frame/out_i/out_q` 每拍 1 个;与 `dsp_pfir` 的帧输出直接串联 |
| 参数 | `N` 点数(2 的幂 8..1024)/ `B` 输入位宽 / `WT` twiddle 位宽 / `B_OUT`(默认 WI=B+log2(N)+1, 满精度)/ `TW_FILE` |
| 结构 | 单个 radix-2 蝶形 in-place 操作双口 RAM(库内 `xpm_sdpram`);输入位倒序装载(DIT)、自然序读出;6 拍微序列/蝶形, 单乘法器 |
| 标度 | 无逐级缩放, 输出 = 复数 FFT 满精度结果(相对 1/N 归一 DFT 放大 N 倍, 监测门限可吸收; 需 1/N 标度在外层右移) |
| 时序 | 每帧 = N(load) + 6·(N/2)·log2(N)(compute) + N+1(unload);N=64 约 900 拍/帧 |
| 精度 | 量化模型经 numpy 交叉验证 max_err 0.002 LSB(输入标度);RTL 与模型逐位精确(冲激/直流/单音/随机 5 用例) |
| 资源 | 四模块合计(xczu48dr, 含 pfir→fft 链路):DSP48=45 / 3478 LUT / 2403 FF |

### dsp_chan 速查

| 项 | 说明 |
| --- | --- |
| 接口 | `in_valid/in_i/in_q` IQ 流(帧节奏约束见下)→ `out_valid/out_frame/out_i/out_q[B_BIN]`(每信道一个,bin 0..N-1 顺序成帧) |
| 结构 | `dsp_pfir`×2(I/Q 共享系数, 线性分离性)+ 同步 FIFO(解耦 pfir 脉冲与 fft 握手)+ `dsp_fft` |
| 映射 | **bin k = 信道 k**(输入 e^{+j2πkn/N} 落 bin k;bin0=直流, 1..N/2-1 正频, N/2..N-1 负频) |
| 增益/隔离 | 信道中心音 \|bin\| = 1.000·A(±0.01%);邻道泄漏实测 **−58.8 dB**(N=64/K=8) |
| 帧节奏 | **帧周期必须 ≥ FFT 帧时间**(N + 6·(N/2)·log2(N) + N+1 拍, N=64 约 1281 拍)——pfir 输出经 FIFO 解耦但无背压, 上游快于 FFT 会溢出丢样(CIC 抽取后的流恒满足) |

**已验证的事实(dsp 家族 #1~#14,2022.1 实测,三版本回归一致):**

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
9. **Verilog signedness 陷阱 (PFB MAC 实测踩中)**:`macen ? coef*data : '0`
   这种含无类型 `'0` 的三元,整个表达式按**无符号**求值——负数系数被
   当无符号数(−6 → 65530),乘积错成 2.1e9 (`65530×32767`,实测 acc
   打印值正是此数)。修法:乘积放在**全 signed 操作数的独立表达式**里
   (`assign prod = coef_r2 * ram_q;` 再进三元)。凡是 signed 算术进
   含 `'0` 的表达式,都要过这一关。
10. **PFB 多相结构的三个关键点 (dsp_pfir 实测)**:
    * 系数布局 **h[p + r*N]**(p 步进 1、r 步进 N),写成 p*K+r 会得到
      "支路整体平移 K 倍"的错位 (实测冲激响应错位 +4 支路);
    * 循环缓冲深度 **(K+1)*N** 多留一帧:计算窗 [w−N·K, w−1] 与写窗
      [w, w+N) 不相交;深 K*N 在全速输入时覆盖未读最老样;
    * 每支路末尾插 **1 拍空闲槽做零系数虚拟取指**:保持取指/使能相位
      连续(末 tap 的 MAC 还要 2 拍才发生),同时把支路边界处的悬空
      MAC 乘积化为 0;支路和的捕获+清零用 3 级 done 链对齐,单表达式
      `acc <= (done_p3 ? 0 : acc) + prod` 完成(避免同沿双写)。

参考:ADI hdl `library/common/ad_dds_cordic_pipe.v`(单级旋转结构参照,
本模块为独立自写实现);Ray Andraka, "A Survey of CORDIC Algorithms for
FPGA Based Computers"。
11. **饱和比较的 signedness 复发 (dsp_fft 实测)**:`signed'(1 <<< N) - 1'b1`
   里混入无符号字面量 `1'b1`, 整个比较被拖成**无符号** -- 负值 (-4) 当无符号
   大数看恒大于上限, 结果**所有负值被饱和到 +max**(DC 帧的负 q 桶全变
   4194303)。修法:阈值用 `localparam logic signed` 常量比较。这是事实 #9
   的同族陷阱第二次现形:凡 signed 比较/算术与无类型字面量混用都要过这一关。
12. **TB 首样的零延迟竞争 (dsp_fft 实测, 隐蔽度高)**:喂样任务若在进入时
   `in_ready` 已高, 会在**正沿当拍**驱动 `in_valid/data` -- 与 DUT 的沿采样
   竞争, 表现为首样写入丢失/整条数据错位(FFT 输出全桶带常数偏置, 且
   只有非首帧暴露, 因为首帧的"错值"恰好被初值掩盖)。喂样任务入口必须先
   `@(negedge clk)`, 所有激励变化严格发生在下降沿。
13. **迭代式 FFT 的四个实现要点 (dsp_fft 实测)**:
   * in-place DIT:输入按位倒序装载、自然序读出, 无需输出重排;
   * 数据词布局必须 load 与 compute 完全一致(46 位 = 两个 WI 字段;load
     直接写 32 位会落在读窗口之外, 实测全桶出垃圾);
   * unload 填充拍读地址必须为 0(`u` 还残留上帧终值, 否则 bin0 读到
     mem[63]);输出缓存宽度按 WI 满精度, 逐级误差不累积(无缩放);
   * twiddle 用 saturating 码 (2^(WT-1)-1) 表示 1.0, 每级有 ~1/2^WT 的
     幅度亏差(解析 sanity 的容差要按此放宽), 位精确比对由量化模型覆盖。

14. **信道化装配的两个坑 (dsp_chan 实测)**:
   * **FIFO 字序即频谱方向**:pfir I/Q 配对进 FIFO 时写成 `{Q, I}` 而 fft 的
     `in_i` 接高半位 → I/Q 交换 → 输入 e^{+j} 变 e^{-j} → 频谱整体镜像
     (信道 k 的音出现在 bin N−k, 实测 ch5→bin59)。修复后 bin k = 信道 k。
   * **吞吐失配**:FFT 帧时间(~1281 拍)大于 pfir 帧周期(704 拍)时,
     信道 FIFO 溢出丢样, fft 永远凑不满一帧(表现为死锁)。上游帧节奏
     必须按整链瓶颈(FFT)规划;真实施(CIC 抽取后)恒满足。FIFO 解耦的
     是"脉冲节奏"不是" sustained 吞吐"。
   * 装配实测:信道中心音增益 1.000(±0.01%), 邻道隔离 −58.8 dB——
     两级各自的对拍精度在装配后保持(无额外损失)。


## 路线图

频域信道化(PFB 信道化,监测接收机用)推进中:
`dsp_pfir`(多相滤波级,**完成**)→ `dsp_fft`(迭代式 radix-2,**完成**)
→ `dsp_chan`(**完成**:IQ 入 → N 复数信道出, 多音系统级实测增益 1.000、
隔离 −58.8 dB)。可选升级:2× 过采样(信道边缘无缝)、fftshift 重排
(或由软件按 bin=k 映射)。
背景:RFSoC 硬 DDC 与 AMD DUC/DDC/DSP IP 覆盖"重滤波 IP 化"路线,
本库的频域信道化走**全可见 RTL** 路线(跨厂商、可对拍、可嵌入自有测量链),
参照 litedsp(MIT)/CASPER(SDR 生态)结构。

测量链(IP 生态不覆盖,差异化正业):`timebase` + `detector` + `pdw_meas`。

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
