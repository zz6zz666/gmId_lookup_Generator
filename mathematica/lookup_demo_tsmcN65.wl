(* ::Package:: *)

(* =====================================================================
   lookup_demo_tsmcN65.wl  \[LongDash]  TSMC 65 nm LP (1.2 V) lookup-table plots
   使用前先运行 0 号 Setup cell；各节可单独复制到 Notebook 中运行。
   数据位置: D:\tsmc18_lookup\tsmc18_{nch,pch}_{tt,ff,ss,fs,sf}.h5
   ===================================================================== *)

(* =====================================================================
   0. Setup \[LongDash] 载入数据
   ===================================================================== *)
dataDir = "D:\\tsmcN65_lookup";
scriptDir = FileNameJoin[{dataDir, "mathematica"}];
Get[FileNameJoin[{scriptDir, "lookup_table.wl"}]];

nch[corner_] := LoadLookupTable[FileNameJoin[{dataDir, "tsmcN65_nch_" <> corner <> ".h5"}]];
nchGMID[corner_] := LoadLookupTable[
   FileNameJoin[{dataDir, "tsmcN65_nch_" <> corner <> ".h5"}],
   {"CORNER", "DEVICE", "INFO", "TEMP", "W", "NFING", "L", "VGS", "VDS",
     "VSB", "GM", "ID"}];
pch[corner_] := LoadLookupTable[FileNameJoin[{dataDir, "tsmcN65_pch_" <> corner <> ".h5"}]];

tt = nch["tt"];
corners = {"tt", "ff", "ss", "fs", "sf"};

(* --- 数据网格信息 --- *)
vgsAx = tt["VGS"]; vdsAx = tt["VDS"]; vsbAx = tt["VSB"]; Lall = tt["L"];
VDD = Max[vgsAx]; VDSo = VDD/2;
vdTag = "@ VDS=" <> ToString[VDSo] <> "V";   (* 偏置标签随 VDD 走 *)

Style[Grid[{
   {"器件", tt["DEVICE"] <> " " <> tt["CORNER"],
    "W=" <> ToString[tt["W"]] <> " um, T=" <> ToString[tt["TEMP"]] <> " K"},
   {"VSB", ToString[Length[vsbAx]] <> " 点", vsbAx},
   {"VDS", ToString[Length[vdsAx]] <> " 点",
    ToString[Min[vdsAx]] <> " .. " <> ToString[Max[vdsAx]] <> " V, 步长 " <>
     ToString[vdsAx[[2]] - vdsAx[[1]]]},
   {"VGS", ToString[Length[vgsAx]] <> " 点",
    ToString[Min[vgsAx]] <> " .. " <> ToString[Max[vgsAx]] <> " V, 步长 " <>
     ToString[vgsAx[[2]] - vgsAx[[1]]]},
   {"L", ToString[Length[Lall]] <> " 点",
    ToString[Min[Lall]] <> " .. " <> ToString[Max[Lall]] <> " um"}},
  Dividers -> All, Spacings -> {1.5, 0.6}, Background -> {None, LightGray},
  ItemStyle -> {Bold, Bold}],
 FontFamily -> "Microsoft YaHei"]

Ls = {0.06, 0.1, 0.2, 0.5, 1.0};
cols = ColorData["Rainbow"][#] & /@ Subdivide[0, 0.9, Length[Ls] - 1];

(* 固定 (VSB,VDS) 沿 VGS 扫出各 L 的一组曲线 *)
fam[data_, var_, vsb_, vds_, L_] :=
  lookup[data, var, "VGS", vgsAx, "VSB", vsb, "VDS", vds, "L", L,
    "WARNING", "off"];

legend[L_] := LineLegend[cols, Map["L=" <> ToString[#] <> " um" &, L],
  LegendLabel -> "L"];

(* =====================================================================
   1. gm/ID vs VGS \[LongDash] 弱反型峰值区 ~25~35，强反型单调下降
   ===================================================================== *)
ListLinePlot[fam[tt, "GM_ID", 0, VDSo, Ls], DataRange -> {0, VDD},
 PlotStyle -> cols, PlotLegends -> legend[Ls],
 AxesLabel -> {"VGS (V)", "gm/ID (S/A)"},
 PlotLabel -> "nch tt: gm/ID vs VGS  " <> vdTag <> " VSB=0",
 GridLines -> Automatic]

(* =====================================================================
   2. ID vs VGS（对数）\[LongDash] 亚阈值区固呈直线、无折点
   ===================================================================== *)
ListLogPlot[fam[tt, "ID", 0, VDSo, Ls], DataRange -> {0, VDD},
 PlotStyle -> cols, PlotLegends -> legend[Ls],
 AxesLabel -> {"VGS (V)", "ID (A)"},
 PlotLabel -> "nch tt: ID vs VGS (log)  " <> vdTag <> " VSB=0",
 GridLines -> Automatic]

(* =====================================================================
   3. ID vs VDS（输出特性族）\[LongDash] 饱和区应平坦、无扭结
   ===================================================================== *)
vgsO = N@Round[VDD*{0.35, 0.5, 0.65, 0.8}, 0.05];
With[{L0 = First[Ls],
   curves = lookup[tt, "ID", "L", First[Ls], "VGS", vgsO, "VDS", vdsAx, "VSB", 0]},
  ListLinePlot[
    Table[Transpose[{vdsAx, curves[[i]]}], {i, Length[vgsO]}],
    AxesLabel -> {"VDS (V)", "ID (A)"},
    PlotLabel -> "nch tt: ID vs VDS  L=" <> ToString[L0] <> "um VSB=0",
    PlotLegends -> LineLegend[Automatic, Map["VGS=" <> ToString[#] <> "V" &, vgsO]],
    GridLines -> Automatic]]

(* =====================================================================
   4. 本征增益 GAIN = gm/gds (GM_GDS) vs gm/ID
   ===================================================================== *)
ListLinePlot[
  Transpose[#] & /@ Transpose[{fam[tt, "GM_ID", 0, VDSo, Ls],
     fam[tt, "GM_GDS", 0, VDSo, Ls]}],
  PlotStyle -> cols, PlotLegends -> legend[Ls],
  AxesLabel -> {"gm/ID (S/A)", "gm/gds (V/V)"},
  PlotLabel -> "nch tt: Intrinsic Gain  " <> vdTag <> " VSB=0",
  GridLines -> Automatic]

(* =====================================================================
   5. fT vs gm/ID  (fT = GM_CGG/(2 Pi))
   ===================================================================== *)
ListLogPlot[
  Transpose[#] & /@ Transpose[{fam[tt, "GM_ID", 0, VDSo, Ls],
     fam[tt, "GM_CGG", 0, VDSo, Ls]/(2 Pi)}],
  PlotStyle -> cols, PlotLegends -> legend[Ls],
  AxesLabel -> {"gm/ID (S/A)", "fT (Hz)"},
  PlotLabel -> "nch tt: fT  " <> vdTag <> " VSB=0",
  GridLines -> Automatic]

(* =====================================================================
   6. 电容 Cgg / Cgs / Cgd vs VGS
   ===================================================================== *)
With[{L0 = First[Ls]},
  ListLinePlot[{
    lookup[tt, "CGG", "L", L0, "VGS", vgsAx, "VDS", VDSo, "VSB", 0],
    lookup[tt, "CGS", "L", L0, "VGS", vgsAx, "VDS", VDSo, "VSB", 0],
    lookup[tt, "CGD", "L", L0, "VGS", vgsAx, "VDS", VDSo, "VSB", 0]},
   DataRange -> {0, VDD}, PlotRange -> All,
   PlotStyle -> {Blue, Orange, Red},
   PlotLegends -> LineLegend[{"Cgg", "Cgs", "Cgd"}],
   AxesLabel -> {"VGS (V)", "Cap (F)"},
   PlotLabel -> "nch tt: capacitances  L=" <> ToString[L0] <> "um " <> vdTag <> " VSB=0",
   GridLines -> Automatic]]

(* =====================================================================
   7. VDSAT vs VGS \[LongDash] 强反型 VDSAT ~ 2/(gm/ID)
   ===================================================================== *)
ListLinePlot[fam[tt, "VDSAT", 0, VDSo, Ls], DataRange -> {0, VDD},
 PlotStyle -> cols, PlotLegends -> legend[Ls],
 AxesLabel -> {"VGS (V)", "VDSAT (V)"},
 PlotLabel -> "nch tt: VDSAT  " <> vdTag <> " VSB=0",
 GridLines -> Automatic]

(* =====================================================================
   8. 体效应 \[LongDash] ID vs VGS, VSB=0..1.0（VT 随 |VSB| 增大）
   ===================================================================== *)
With[{vsbs = {0.0, 0.25, 0.5, 0.75, 1.0}},
  ListLogPlot[
    Transpose[lookup[tt, "ID", "L", First[Ls], "VGS", vgsAx, "VDS", VDSo,
      "VSB", vsbs]],
    DataRange -> {0, VDD}, PlotStyle -> Automatic,
    PlotLegends -> LineLegend[Automatic, Map["VSB=" <> ToString[#] <> "V" &, vsbs]],
    AxesLabel -> {"VGS (V)", "ID (A)"},
    PlotLabel -> "nch tt: body effect  L=" <> ToString[First[Ls]] <> "um " <> vdTag,
    GridLines -> Automatic]]

(* =====================================================================
   9. 工艺角对比 \[LongDash] 固定偏置下 gm/ID 随 corner 的散布
   ===================================================================== *)
ListLinePlot[
  Table[
    lookup[If[c == "tt", tt, nchGMID[c]], "GM_ID", "L", First[Ls], "VGS", vgsAx,
      "VDS", VDSo, "VSB", 0],
    {c, corners}],
  DataRange -> {0, VDD},
  PlotStyle -> ColorData["DarkRainbow"][#] & /@ Subdivide[0, 1, Length[corners] - 1],
  PlotLegends -> LineLegend[Automatic, corners],
  AxesLabel -> {"VGS (V)", "gm/ID (S/A)"},
  PlotLabel -> "nch: gm/ID corners  L=" <> ToString[First[Ls]] <> "um " <> vdTag <> " VSB=0",
  GridLines -> Automatic]

(* =====================================================================
   10. gm/ID 二维云图 (VDS, VGS) \[LongDash] 检查网格覆盖与连续性
   ===================================================================== *)
With[{z = lookup[tt, "GM_ID", "L", First[Ls], "VGS", vgsAx, "VDS", vdsAx,
     "VSB", 0]},
  ListContourPlot[
    Flatten[Table[{vdsAx[[j]], vgsAx[[i]], z[[i, j]]},
      {i, Length[vgsAx]}, {j, Length[vdsAx]}], 1],
    FrameLabel -> {"VDS (V)", "VGS (V)"},
    PlotLabel -> "nch tt: gm/ID contour  L=" <> ToString[First[Ls]] <> "um VSB=0",
    ColorFunction -> "Rainbow", PlotLegends -> Automatic]]

(* =====================================================================
   11. 噪声 STH / SFL vs VGS \[LongDash] 关断区趋于 0、开启区量级合理
       STH 来自 mn:id（沟道热噪声），SFL 来自 mn:fn（闪烁噪声）
   ===================================================================== *)
With[{L0 = First[Ls]},
  ListLinePlot[{
    lookup[tt, "STH", "L", L0, "VGS", vgsAx, "VDS", VDSo, "VSB", 0],
    lookup[tt, "SFL", "L", L0, "VGS", vgsAx, "VDS", VDSo, "VSB", 0]},
   DataRange -> {0, VDD}, PlotRange -> All,
   PlotLegends -> LineLegend[{"STH (id, A^2/Hz)", "SFL (fn, A^2/Hz)"}],
   AxesLabel -> {"VGS (V)", "Noise PSD (A^2/Hz)"},
   PlotLabel -> "nch tt: noise  L=" <> ToString[L0] <> "um " <> vdTag <> " VSB=0",
   GridLines -> Automatic]]

(* =====================================================================
   12. 数据质量报告
   ===================================================================== *)
nanFrac[arr_] := N[Total[Flatten@Boole[Map[! NumericQ[#] &, arr, {-1}]]] /
    Max[1, Length[Flatten[arr]]]];
idarr = tt["ID"];
neg = Flatten@Table[Select[Differences[idarr[[il, All, id, iv]]], # < 0 &],
    {il, Length[Lall]}, {id, Length[vdsAx]}, {iv, Length[vsbAx]}];
off = Max[Flatten@Table[idarr[[il, 1, id, iv]],
    {il, Length[Lall]}, {id, Length[vdsAx]}, {iv, Length[vsbAx]}]];

Style[Grid[{
   {"变量", "NaN/非数值占比"},
   {"STH", nanFrac[tt["STH"]]}, {"SFL", nanFrac[tt["SFL"]]},
   {"ID", nanFrac[tt["ID"]]}, {"GM", nanFrac[tt["GM"]]},
   {"VDSAT", nanFrac[tt["VDSAT"]]},
   {"CGG", nanFrac[tt["CGG"]]}},
  Dividers -> All, Spacings -> {2, 0.5}, Background -> {None, LightGray},
  ItemStyle -> {Bold, Bold}, Alignment -> Left],
 FontFamily -> "Microsoft YaHei"]

Style[Grid[{
   {"ID 沿 VGS 单调性（负增量个数）", ToString[Length[neg]]},
   {"ID 沿 VGS 单调性（最大负增量）", ToString[If[Length[neg] > 0, Min[neg], 0.]]},
   {"最大关断电流 ID@VGS=0 (A)", ScientificForm[off, 6]}},
  Dividers -> All, Spacings -> {2, 0.5}, Background -> {None, Automatic},
  ItemStyle -> {Bold, Bold}, Alignment -> Left],
 FontFamily -> "Microsoft YaHei"]
