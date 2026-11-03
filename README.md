# gm/ID 查找表生成（TSMC N40 / tsmc18）

面向 TSMC N40 1.1 V 核心器件和 TSMC 0.18 µm (tsmc18) 器件的
nch / pch gm/ID 查找表生成工具集：Spectre 扫描仿真 + 数据提取，输出
HDF5（.h5）查找表。两种工艺共用同一套仿真、提取与查询代码，通过
`config_<proc>.py` 区分扫描网格与模型卡。

---

## 项目结构

```
.
├── config_common.py      # 与工艺无关的配置（变量表、netlist 模板、装配）
├── config_tsmcN40.py     # TSMC N40 工艺参数（轴 / 模型 / 器件尺寸）
├── config_tsmc18.py      # TSMC 0.18µm 工艺参数（轴按参考 180nm 设置）
├── run_sim.py            # Spectre 仿真（多工艺角并行）
├── extract.py            # 数据提取，生成 .h5 查找表
├── psf_reader.py         # PSF 格式仿真结果读取器
├── cli.py                # run_sim / extract 共用的命令行解析
├── paths.py              # 读取 machine.env，解析本机路径
├── pipeline.sh           # 逐 L 流水线（仿真 → 提取 → 清理）
├── machine.env.example   # 本机路径配置模板（machine.env 不入库）
├── lookup_funs/          # Python 查找表查询 API、EKV 提取与示例
│   ├── lookup_table.py
│   ├── ekv_extract.py
│   ├── lookup_demo_tsmcN40.py
│   ├── xtract_demo_tsmcN40.py
│   └── LOOKUP_README.md
├── mathematica/          # Mathematica 加载 / 插值脚本与示例
│   ├── lookup_table.wl
│   ├── ekv_extract.wl
│   ├── lookup_demo_tsmcN40.wl
│   ├── xtract_demo_tsmcN40.wl
│   └── README.md
└── README.md
```

## 扫描网格（fine 模式）

两种工艺的参考器件相同：**W = 10 µm（2 µm/指 × 5 指）**，网表参数为
`w=2e-6 m=5`，数据按总宽 10 µm 归一化；每个文件包含 18 个变量（16 DC + 2 噪声）。

### TSMC N40 — `config_tsmcN40.py`

| 参数       | 值 |
| ---------- | --- |
| 工艺 / 器件 | TSMC N40 (CRN40LP)，1.1 V 核心器件，BSIM4，nch / pch |
| VGS        | 0 ~ 1.1 V，步长 0.02 → 56 点 |
| VDS        | 0 ~ 1.1 V，步长 0.02 → 56 点 |
| VSB        | 0 ~ 0.8 V，步长 0.1 → 9 点 |
| L          | 0.04 ~ 2 µm → 44 点（0.04~0.14 步 0.01；0.16~0.50 步 0.02；0.55~1.00 步 0.05；1.20~2.00 步 0.20） |
| 单变量网格 | 44 × 56 × 56 × 9 = 1,241,856 点，维度顺序 (L, VGS, VDS, VSB) |
| 工艺角     | `tt ff ss fs sf` |
| 输出文件   | `nch_<corner>.h5` / `pch_<corner>.h5`，共 10 个 |

### TSMC 0.18 µm — `config_tsmc18.py`

| 参数       | 值 |
| ---------- | --- |
| 工艺 / 器件 | TSMC 0.18 µm (tsmc18)，1.8 V 器件，BSIM4，nch / pch |
| VGS        | 0 ~ 1.8 V，步长 0.025 → 73 点 |
| VDS        | 0 ~ 1.8 V，步长 0.025 → 73 点 |
| VSB        | 0 ~ 1.0 V，步长 0.1 → 11 点 |
| L          | 0.18 ~ 2 µm → 32 点（0.18~0.50 步 0.02；0.60~2.00 步 0.10） |
| 单变量网格 | 32 × 73 × 73 × 11 = 1,875,808 点，维度顺序 (L, VGS, VDS, VSB) |
| 工艺角     | `tt ff ss fs sf` |
| 输出文件   | `tsmc18_nch_<corner>.h5` / `tsmc18_pch_<corner>.h5`，共 10 个 |

tsmc18 的四个扫描轴取自 `techsweep_config_bsim3_180_hspice.m`；参考器件尺寸由
该配置的 W = 5 µm / 1 指改为 W = 10 µm / 5 指。

## 存储格式（.h5，HDF5）

- 每个文件对应一个器件与工艺角的组合，如 `nch_tt.h5`、`pch_tt.h5`；tsmc18 的表
  文件名带 `tsmc18_` 前缀（`tsmc18_nch_tt.h5`），可与 N40 表共存于同一目录。
- 4-D 数据数组 `(L, VGS, VDS, VSB)`，
  **float32 + gzip(level 6) + shuffle**，chunk = 一个 L 的整片 `(1, VGS, VDS, VSB)`。
- 元数据存为标量/字符串数据集：`CORNER DEVICE INFO TEMP W NFING`。
- 坐标轴存为 1-D 数据集：`L VGS VDS VSB`。
- 变量名：`ID VT IGD IGS GM GMB GDS CGG CGS CSG CGD CDG CGB CDD CSS VDSAT`（+ 噪声 `STH SFL`）。
  `VDSAT`=BSIM 饱和电压，唯一存储的复合量；其余复合量均为比例，现算：
  `GM_ID`=gm/id、`GM_CGG`=gm/Cgg（fT=`GM_CGG/(2π)`）、`GM_GDS`=gm/gds（固有增益）、`ID_W`=ID/W。

N40 单文件约 45–50 MB（float32 + gzip6），10 个文件合计约 0.5 GB；
tsmc18 网格更大，单文件约 65–70 MB，合计约 0.7 GB。

## 关键配置说明（`config_<proc>.py`）

工艺文件定义该工艺的参数：`TAG`（临时文件名中的工艺标签）、`INFO`（写入 .h5 的
描述）、`SECTIONS`、`CORNERS`、`TEMP`、`VDD`、`VSB_MAX`、`WIDTH` / `NFING`，
以及 `COARSE` / `FINE` 两套网格。netlist 模板、存储变量表与 PSF 信号映射位于
`config_common.py`。

- **模型文件**：路径由 `machine.env` 的 `PDK_MODEL_FILE` 指定。`SECTIONS` 为空时
  直接 `include "..."`；`'stat'`、`'global'`、`'{corner}'` 等条目展开为
  `include "..." section=...`（N40 模型卡使用 `stat` / `global` / 工艺角三段）。
- **工艺角**：由 `CORNERS` 定义，`pipeline.sh`、`run_sim.py`、`extract.py` 均从
  配置读取。
- **Spectre**：`machine.env` 中的 `SPECTRE_BIN`（默认 `/opt/eda/cadence/SPECTRE181/tools.lnx86/bin/spectre`）。
- **N40 缩放**：PDK 文档（T-N40-CM-SP-001）说明基础模型卡已含缩放因子，因此直接
  包含基础卡；叠加 `setscale scalefactor=0.9` 会造成双重缩放（0.9×0.9=0.81）。

## 运行环境（远端 Linux / VM）

| 组件                 | 环境要求                                     |
| -------------------- | -------------------------------------------- |
| Spectre 扫描仿真     | Cadence SPECTRE 18.1（`/opt/eda/cadence/SPECTRE181`） |
| 数据提取 & .h5 生成  | Python ≥ 3.10 + numpy, h5py, scipy, **psf-parser**（二进制 PSF 解析） |
| 查找表 API           | Python 3.x + numpy, scipy, h5py              |
| Pipeline             | Bash + Python                                     |

### Python 环境（CentOS 7 等旧系统建议使用 uv）

CentOS 7 的发行版 Python 为 3.6，低于 psf-parser 要求的 3.10；缺少预编译 wheel 时，
旧版 pip / setuptools 需要从源码构建 numpy / h5py。uv 为静态二进制，包含独立构建的
CPython，不依赖系统 Python 和编译器：

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh      # 安装到 ~/.local/bin/uv
uv python install 3.13
uv venv --python 3.13 "$HOME/venvs/gmId313"          # 与 PYTHON_BIN 默认路径一致
uv pip install --python "$HOME/venvs/gmId313/bin/python" \
    numpy h5py scipy psf-parser
"$HOME/venvs/gmId313/bin/python" -c "import numpy, h5py, scipy, psf_parser; print('ok')"
```

- uv 与 python-build-standalone 的 glibc 下限为 2.17，与 CentOS 7 一致；numpy /
  h5py / scipy 提供 manylinux_2_17 wheel。
- psf-parser 为纯 Python 包，无需编译。
- Python 3.13 要求 h5py ≥ 3.11。
- uv 通过 HTTPS 下载；系统 CA 证书过旧时先执行 `yum update ca-certificates`。
- 备选方案：micromamba / conda-forge 的 Python 发行版，同样不依赖系统 Python。

### 路径配置

机器路径（PDK 模型、Spectre、Python、数据目录）集中在项目根目录的 `machine.env`
（模板 `machine.env.example`，已 git 忽略），值可用 `$HOME` 或引用前面的键（如 `$SIMDIR/raw`）。
Python 经 `paths.py` 读取，`pipeline.sh` 经 `source machine.env` 读取，脚本不硬编码
目录或用户名。

原始仿真数据与查找表存放于 `$HOME/simulation`：`RAWDIR`（原始 PSF，提取后删除）、
`MATDIR`（最终 .h5）、`LOGDIR`（日志）。`PYTHON_BIN` 指向上面的 venv
（默认 `$HOME/venvs/gmId313/bin/python`）；未安装 psf-parser 时 `psf_reader.py`
回退到 ASCII 解析（速度较慢，且要求 `rawfmt=psfascii`）。

## 快速开始

### 1. 配置 machine.env

```bash
cp machine.env.example machine.env   # 然后填入本机路径
```

### 2. Pipeline 一键运行（推荐）

```bash
bash pipeline.sh
```

逐 L 增量处理：每个 L 依次执行仿真、提取与清理。各工艺角在
`run_sim.py` / `extract.py` 内部并行（每个 corner 一个 worker），`pipeline.sh` 负责任务
顺序、日志与计时。原始仿真数据写入 `$RAWDIR`（默认 `$HOME/simulation/raw`），
提取完成后删除。
.h5 输出到 `$MATDIR`（默认 `$HOME/simulation/out`）。启动时清理上次中断残留的 raw
数据、日志与过期 spectre 工作目录。

### 3. 分步运行

```bash
# Step 1 — 扫描仿真（指定 corner 和输出目录）
$PYTHON_BIN run_sim.py tt --fine --outdir "$RAWDIR"

# Step 2 — 数据提取
$PYTHON_BIN extract.py --fine --srcdir "$RAWDIR" --outdir "$MATDIR" --workers 5

# Step 3 — 使用查找表 API（示例见下文"Python 使用"）
from lookup_funs.lookup_table import loadmat, lookup, lookupVGS
nch = loadmat(r"D:\tsmcN40_lookup\nch_tt.h5")
```

### 4. 切换工艺 / 新增工艺

工艺参数定义在 `config_<proc>.py`（模型卡、四个扫描轴、器件尺寸、corner 列表）；
与工艺无关的部分位于 `config_common.py`（存储变量表、PSF 信号映射、netlist 模板、
装配与网表输出）。运行时通过 `CONFIG_MODULE` 选择配置：

```bash
CONFIG_MODULE=config_tsmc18 bash pipeline.sh
# 或写入 machine.env：CONFIG_MODULE=config_tsmc18
```

同时将 `PDK_MODEL_FILE` 指向该工艺的模型卡；`MATDIR` 建议按工艺分目录。tsmc18 的
表文件名带 `tsmc18_` 前缀，与 N40 表共用目录时不会冲突。

两种工艺的扫描网格见「扫描网格」一节。

新增工艺：复制 `config_tsmc18.py`，修改 `TAG`、`INFO`、`SECTIONS`、`CORNERS`、
`VDD`、`VSB_MAX`、`WIDTH`、`NFING` 与 `FINE` 轴；`run_sim.py`、`extract.py`、
`pipeline.sh` 无需修改。

## Python 使用

`lookup_funs/lookup_table.py` 提供查询 API（numpy + scipy + h5py），完整说明见
`lookup_funs/LOOKUP_README.md`：

```python
from lookup_funs.lookup_table import loadmat, lookup, lookupVGS

nch = loadmat(r"D:\tsmcN40_lookup\nch_tt.h5")
pch = loadmat(r"D:\tsmcN40_lookup\pch_tt.h5")

gm_id = lookup(nch, 'GM_ID', 'VGS', 0.6, 'VDS', 0.7, 'VSB', 0, 'L', 0.1)     # 查表
VGS   = lookupVGS(nch, 'GM_ID', 15, 'VDS', 0.7, 'VSB', 0, 'L', 0.1)          # 反查 VGS
wt    = lookup(nch, 'GM_CGG', 'GM_ID', [5, 10, 15], 'VDS', 0.7, 'VSB', 0, 'L', 0.1)  # 交叉查表

nch.VDSAT                                # 直接取存储的 4-D 数组 (L,VGS,VDS,VSB)
nch.GM / nch.CGG                         # 任意比例量现算（= GM_CGG，fT=GM_CGG/(2π)）
```

- `loadmat` 返回 `LookupTable`，存储变量名为属性（`ID GM VDSAT ...`），4-D 数组
  `(L, VGS, VDS, VSB)`（与官方 .mat 布局一致；也可直接加载官方 `.mat` 文件）。
- `lookup(data, outvar, ...)`：`outvar` 可为存储变量或比例量（`GM_ID`、`ID_W`、`GM_CGG`、`GM_GDS` 等，
  由原始量现算），支持 4-D 插值、交叉查表；`lookupVGS(...)` 按 gm/id 或电流密度反查 VGS。
- pch 文件用正电压域（|VSG|、|VSD|）查询，与 nch 一致。

## Mathematica 使用

HDF5 文件可由 Mathematica `Import` 直接读取，见 `mathematica/lookup_table.wl`：

```mathematica
<< "mathematica/lookup_table.wl"
data = LoadLookupTable["D:\\tsmcN40_lookup\\nch_tt.h5"];
gmId = lookup[data, "GM_ID", "VGS", 0.6, "VDS", 0.7, "VSB", 0, "L", 0.1];
vgs = lookupVGS[data, "GM_ID", 15, "VDS", 0.7, "VSB", 0, "L", 0.1];
wt = lookup[data, "GM_CGG", "GM_ID", {5, 10, 15}, "VDS", 0.7, "L", 0.1];

(* 正查一次获取多个变量；返回值顺序与变量名列表一致 *)
{intrinsicGain, idPerWidth} = lookup[data, {"GM_GDS", "ID_W"},
  "L", {0.04, 0.06}, "VGS", {0.6, 0.7}, "VDS", 0.7, "VSB", 0.];

(* lookupVGS 也支持普通 mode 1 的多维 Cartesian 输入 *)
vgs = lookupVGS[data, "GM_ID", {10., 12., 15.},
  "L", {0.04, 0.06}, "VDS", {0.5, 0.7}, "VSB", 0.];
Dimensions[vgs]                         (* {2, 2, 3} *)

vgsUnknownSource = lookupVGS[data, "GM_ID", {10., 12., 15.},
  "VDB", .6, "VGB", 1., "L", .04];

(* MapThread 参数按位置配对；原生 VDS 列表仍是笛卡尔维度 *)
gain = MapThread[
  lookup[data, "GM_GDS", "GM_ID", #1, "L", #2,
    "VDS", {0.5, 0.7, 0.9}, "VSB", 0.] &,
  {{8, 10, 12}, {0.04, 0.06, 0.08}}];
Dimensions[gain]                         (* {3, 3} = 配对维度 × VDS维度 *)
```

- `lookup`、`lookupVGS` 的函数划分、交替名称/值参数及默认值与附录和 Python API 对齐；
  Mathematica 版本额外提供多输出和多维批量扩展。
- `METHOD` 的有效值为 `"pchip"`、`"linear"` 和 `"cubic"`；多维表插值固定为线性。
- 加载查表文件后，函数体直接为 `lookup` 或 `lookupVGS` 的 `/@` 与 `MapThread`
  会自动合并为分块批量查询。`MapThread` 中的列表按位置配对，函数体内直接传给查表函数的
  普通列表仍形成笛卡尔积；其他 Mathematica 函数的 `Map`/`MapThread` 行为不变。
- 可用 `DisableMapOptimization[]` 禁用上述系统规则，并用
  `EnableMapOptimization[]` 再次启用。复杂 Slot 表达式或不支持的查表模式自动回退到逐项求值。
- `XTRACT`、`XTRACT2` 位于 `mathematica/ekv_extract.wl`，保持附录中的位置参数接口。
- 附录缺省值为：`lookup` 使用最小 `L`、完整 `VGS`、最大 `VDS/2` 和 `VSB=0`；
  `lookupVGS` 另使用 PCHIP；`XTRACT/XTRACT2` 使用 `rho=0.6` 和 300 K。
- `XTRACT2` 缺省直接使用总电流并返回 `IS`。显式提供扩展宽度参数时才返回 `JS=IS/W`。
- `LookupInterpolant` 提供可复用的四维线性插值函数；`SliceVGS` 返回固定
  `{L,VDS,VSB}` 下的 `{VGS,value}` 样本。
- 验证：`wolframscript -script mathematica/xtract_demo_tsmcN40.wl`（读取实际 .h5 文件，
  打印与 Python `lookup` 一致的插值结果）。

## 备注

- N40 最小 L 为 0.04 µm（40 nm），网格从 0.04 µm 起步，最长 2 µm；tsmc18 从
  0.18 µm 起步，最长 2 µm。
- 新增工艺：复制 `config_tsmc18.py` 并修改参数，将 `machine.env` 的
  `CONFIG_MODULE` / `PDK_MODEL_FILE` 指向新工艺；`run_sim.py`、`extract.py`、
  `pipeline.sh` 与两套查表 API 均无需修改。
- 扩展 N40 的 2.5 V IO（nch_25 / pch_25）或 LVT / HVT 时，在 `config_tsmcN40.py`
  中增加 device 分组。
