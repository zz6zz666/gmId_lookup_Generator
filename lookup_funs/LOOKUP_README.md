# 查找表使用指南

## 1. 查找表文件（.h5）

由 `extract.py` 生成，HDF5 格式，一个文件 = 工艺 + 器件 + 工艺角，文件名带工艺前缀。
输出目录由 `machine.env` 的 `MATDIR` 决定，下面以本机习惯的路径为例：

```text
D:\tsmcN40_lookup\
├── tsmcN40_nch_tt.h5      (N40, nch, typical corner)
├── tsmcN40_nch_ff.h5
├── tsmcN40_nch_fs.h5
├── tsmcN40_nch_sf.h5
├── tsmcN40_nch_ss.h5
├── tsmcN40_pch_tt.h5
└── ...

D:\tsmc18_lookup\
├── tsmc18_nch_tt.h5       (0.18 µm, nch, typical corner)
├── tsmc18_nch_ff.h5
├── tsmc18_nch_fs.h5
├── tsmc18_nch_sf.h5
├── tsmc18_nch_ss.h5
├── tsmc18_pch_tt.h5
└── ...
```

每种工艺 10 个文件（nch / pch × tt / ff / ss / fs / sf）。正常设计使用 `tt` corner。
所有查表值都以**参考宽度归一化**：元数据 W = 10 µm（2 µm/指 × 5 指）。

## 2. 工艺参数概览

| 参数           | TSMC N40                                      | TSMC 0.18 µm (tsmc18)                        |
| -------------- | --------------------------------------------- | -------------------------------------------- |
| **电源电压**   | **1.1 V**（核心器件）                         | **1.8 V**（核心器件）                        |
| **默认 VDS**   | **0.55 V**（VDD/2）                           | **0.9 V**（VDD/2）                           |
| **默认 VSB**   | 0 V                                           | 0 V                                          |
| VGS 范围       | 0 ~ 1.1 V，步长 0.02 V（56 点）               | 0 ~ 1.8 V，步长 0.025 V（73 点）             |
| VDS 范围       | 0 ~ 1.1 V，步长 0.02 V（56 点）               | 0 ~ 1.8 V，步长 0.025 V（73 点）             |
| VSB 范围       | 0 ~ 0.8 V，步长 0.1 V（9 点）                 | 0 ~ 1.0 V，步长 0.1 V（11 点）               |
| L 范围         | 0.04 ~ 2 µm（44 点），详细值见下方            | 0.18 ~ 2 µm（32 点），详细值见下方           |
| 仿真宽度 W     | 10 µm                                         | 10 µm                                        |
| 单变量网格     | 44 × 56 × 56 × 9 = 1,241,856 点               | 32 × 73 × 73 × 11 = 1,875,808 点             |

维度顺序均为 `(L, VGS, VDS, VSB)`。

**L 详细值**：

- N40（44 点）：0.04 ~ 0.14（步长 0.01）；0.16 ~ 0.50（步长 0.02）；
  0.55 ~ 1.00（步长 0.05）；1.2, 1.4, 1.6, 1.8, 2.0
- tsmc18（32 点）：0.18 ~ 0.50（步长 0.02）；0.60 ~ 2.00（步长 0.10）

## 3. 数据结构

- 4-D 数据数组 `(L, VGS, VDS, VSB)`（与官方 Murmann 查找表布局一致），float32 + gzip 压缩。
- 变量：`ID VT IGD IGS GM GMB GDS CGG CGS CSG CGD CDG CGB CDD CSS VDSAT`，外加噪声 `STH SFL`。
  tsmc18 的模型不含栅电流（模型卡 `igcmod=0`），其 `IGD` / `IGS` 列恒为 0。
- 元数据数据集：`CORNER DEVICE INFO TEMP W NFING`。
- 坐标轴数据集：`L VGS VDS VSB`。
- 其余比例量（如 `GM_CGG = GM/CGG`、`GM_GDS = GM/GDS`、`ID_W = ID/W`）由原始量现算。
  fT = `GM_CGG/(2π)`，固有增益 = `GM_GDS`。

## 4. Python API

```python
from lookup_table import loadmat, lookup, lookupVGS

nch = loadmat(r"D:\tsmcN40_lookup\tsmcN40_nch_tt.h5")
pch = loadmat(r"D:\tsmcN40_lookup\tsmcN40_pch_tt.h5")

# 基础查表
gm_id = lookup(nch, 'GM_ID', 'VGS', 0.6, 'VDS', 0.7, 'VSB', 0, 'L', 0.1)
gain  = lookup(nch, 'GM_GDS', 'VGS', 0.6, 'VDS', 0.7, 'VSB', 0, 'L', 0.1)
ft    = lookup(nch, 'GM_CGG', 'VGS', 0.6, 'VDS', 0.7, 'VSB', 0, 'L', 0.1) / (2*pi)

# 反查 VGS（给定 gm/id 或电流密度）
VGS = lookupVGS(nch, 'GM_ID', 15, 'VDS', 0.7, 'VSB', 0, 'L', 0.1)

# 交叉查表（gm/Cgg vs gm/id）
wt = lookup(nch, 'GM_CGG', 'GM_ID', [5, 10, 15], 'VDS', 0.7, 'VSB', 0, 'L', 0.1)
```

> 两种工艺的表格接口相同；换工艺只需换文件（如 `tsmc18_nch_tt.h5`），查询参数按各自的
> VDD / L 网格取值。pch 文件同样使用**正电压域**（|VSG|、|VSD|）查询，与 nch 一致。

### 附录缺省值

| 函数 | 缺省值 |
| --- | --- |
| `lookup` | `L=min(data.L)`，`VGS=data.VGS`，`VDS=max(data.VDS)/2`，`VSB=0` |
| `lookup` 交叉查表 | 最终一维插值 `METHOD='pchip'`，提示 `WARNING='off'`；多维插值固定为线性 |
| `lookupVGS` | `L=min(data.L)`，`VDS=max(data.VDS)/2`，`VSB=0`，`METHOD='pchip'`，`WARNING='off'` |
| `XTRACT` | `rho=0.6`，`TEMP=300 K` |
| `XTRACT2` | `rho=0.6`，温度按 `300 K`；输入 `ID` 不做宽度归一化，返回 `IS` |

`lookupVGS` 按附录限制为至多一个向量输入。交叉查表显式传入 `VGS` 时，该向量用作
交点搜索范围；未传入时使用完整的 `data.VGS`。

`XTRACT2` 额外保留 `TEMP` 和 `W` 扩展参数。两者均不影响缺省调用：`TEMP` 缺省为
300 K，`W=None` 表示直接使用总电流并返回 `IS`；只有显式传入 `W`（µm）时才使用
`ID/W` 并返回电流密度 `JS`。

```python
from ekv_extract import XTRACT, XTRACT2

y = XTRACT(nch, 0.1, 0.55, 0)       # rho=0.6, TEMP=300 K
p = XTRACT2(vgs, ids)                 # [n, VT, IS], rho=0.6, 300 K
p_density = XTRACT2(vgs, ids, W=10)   # [n, VT, JS]
```

## 5. Mathematica

Mathematica API 与附录及本项目 Python API 保持相同的函数划分和参数顺序。见项目
`mathematica/lookup_table.wl`：

```mathematica
<< "mathematica/lookup_table.wl";
data = LoadLookupTable["D:\\tsmcN40_lookup\\tsmcN40_nch_tt.h5"];

gmId = lookup[data, "GM_ID", "VGS", 0.6, "VDS", 0.7, "VSB", 0, "L", 0.1];
vgs = lookupVGS[data, "GM_ID", 15, "VDS", 0.7, "VSB", 0, "L", 0.1];
wt = lookup[data, "GM_CGG", "GM_ID", {5, 10, 15}, "VDS", 0.7,
  "VSB", 0, "L", 0.1];
```

参数使用与 Matlab/Python 相同的交替名称和值形式，名称不区分大小写，未提供的
`L/VGS/VDS/VSB` 使用附录规定的默认值。`LookupInterpolant` 和 `SliceVGS` 仍保留为底层接口。

```mathematica
<< "mathematica/ekv_extract.wl";
y = XTRACT[data, 0.1, 0.55, 0];
p = XTRACT2[vgs, ids];
pDensity = XTRACT2[vgs, ids, 0.6, 300., 10.];
```

Mathematica 的 `XTRACT2` 宽度扩展缺省为 `Automatic`，语义与 Python 的 `W=None`
相同：不做宽度归一化。
