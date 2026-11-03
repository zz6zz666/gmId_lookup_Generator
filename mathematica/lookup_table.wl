(**
  lookup_table.wl
  ===============
  Mathematica lookup API for .h5 gm/ID lookup tables produced by extract.py.

  Public entry points:
    LoadLookupTable   Load a complete or selective table association.
    lookup            Direct lookup, derived-ratio lookup, and cross-lookup.
    lookupVGS         Recover VGS from GM_ID or ID_W.
    LookupInterpolant Build a reusable 4-D linear interpolant.
    SliceVGS          Return one variable as {VGS, value} samples.

  The five lookup modes, batching rules, return dimensions, and examples are
  documented in mathematica/README.md. Internal lkt* symbols are implementation
  details and may change without affecting the public API.
**)

ClearAll[LoadLookupTable, lookup, lookupVGS, LookupInterpolant, SliceVGS,
  EnableMapOptimization, DisableMapOptimization,
  lktParseArgs, lktNormalizeMethod, lktArray, lktGridValues,
  lktGridPointValues, lktSqueeze,
  lktDirectLookup, lktDirectLookupScalarVector, lktDirectLookupPointVectors,
  lktPackedRealArrayQ, lktKernelInput, lktPointKernel,
  lktPointBatch, lktPointBatchPrepared, lktPointValues,
  lktValidatedPointBatch, lktValidatedPointValues,
  lktVGSSweepKernel, lktVGSSweepBatch, lktValidatedVGSSweepBatch,
  lktDirectLookupMulti, lktCurveBatchKernel, lktCurveLookupBatch,
  lktBracket, lktLinearValue, lktPchipEndpoint, lktPchipSlopes,
  lktPchipValue, lktCurveLookup, lktLookupVGSOne, lktThreaded,
  lktDirectLookupVGSBatch, lktUnknownSourceVGSOne,
  lktUnknownSourceVGSBatch,
  lktDirectCrossLookupBatch, lktThreadValue, lktMappedDirectLookup,
  lktMappedLookup, lktMappedLookupOutputList,
  lktMappedLookupVGS, lktMappedDispatch, lktMappedHeldCall,
  lktMappedFallback, lktHeldLookupBodyQ,
  lktInstallMapRules, lktRemoveMapRules, lktCartesianChunkPoints,
  lktCartesianSlice, lktCartesianLookup, lktCartesianChunkSize];

(* Limit temporary point and result arrays for large Cartesian queries. *)
lktCartesianChunkSize = 32768;

(* Import every dataset of an .h5 file into an Association keyed by name.
   Quiet suppresses benign LibraryFunction::fpexc warnings raised when an
   array contains NaN (the noise datasets STH/SFL are NaN where the device
   is off). *)
LoadLookupTable[file_String] := Module[{names},
  names = Import[file, "Datasets"];
  Association[StringTrim[#, "/"] -> Quiet[Import[file, {"Datasets", #}]] & /@ names]
];

(* Selective loading avoids importing every large 4-D array when a workflow
   needs only a few variables, for example a GM_ID corner comparison. *)
LoadLookupTable[file_String, keys_List] := Association[
  (ToUpperCase[#] -> Quiet[Import[file, {"Datasets", "/" <> ToUpperCase[#]}]]) & /@ keys
];

(* Build a lightweight callable over (L, VGS, VDS, VSB). Multidimensional
   lookup is linear, matching the Appendix implementation. *)
LookupInterpolant[data_Association, varKey_String] := Module[
  {axes, arr},
  axes = data /@ {"L", "VGS", "VDS", "VSB"};
  arr = lktArray[data, varKey];
  Function[{l, vgs, vds, vsb}, lktLinearValue[axes, arr, {l, vgs, vds, vsb}]]
];

(* Convert the Matlab/Python-style alternating name/value arguments to an
   Association. Parameter names are case-insensitive. *)
lktParseArgs[args_List] := Module[{pairs},
  If[OddQ[Length[args]], Return[$Failed]];
  pairs = Partition[args, 2];
  If[!And @@ (StringQ[First[#]] & /@ pairs), Return[$Failed]];
  Association[(ToUpperCase[First[#]] -> Last[#]) & /@ pairs]
];

lktNormalizeMethod[value_] := Module[{method = ToLowerCase[ToString[value]]},
  If[MemberQ[{"pchip", "linear", "cubic"}, method], method, $Failed]
];

(* Resolve a stored variable or a ratio such as GM_CGG or GM_ID.
   Textbook naming: GM_ID = GM/ID, GM_CGG = GM/CGG (=> fT = GM_CGG/(2 Pi)),
   GM_GDS = GM/GDS (=> intrinsic gain), ID_W = ID/W. VDSAT is stored. *)
lktArray[data_Association, name_String] := Module[
  {key = ToUpperCase[name], parts, numerator, denominator},
  If[KeyExistsQ[data, key], Return[data[key]]];
  parts = StringSplit[key, "_"];
  If[Length[parts] != 2, Return[$Failed]];
  numerator = Lookup[data, parts[[1]], Missing["NotFound"]];
  denominator = If[parts[[2]] == "W", Lookup[data, "W", Missing["NotFound"]],
    Lookup[data, parts[[2]], Missing["NotFound"]]];
  If[MissingQ[numerator] || MissingQ[denominator], $Failed,
    Quiet[numerator/denominator]]
];

(* Resolve only selected grid entries. This avoids constructing a full 4-D
   ratio array when a query needs one VGS sweep at fixed L/VDS/VSB. *)
lktGridValues[data_Association, name_String, il_, ig_, id_, is_] := Module[
  {key = ToUpperCase[name], stored, parts, numerator, denominator},
  stored = Lookup[data, key, Missing["NotFound"]];
  If[ArrayQ[stored, 4], Return[stored[[il, ig, id, is]]]];
  parts = StringSplit[key, "_"];
  If[Length[parts] != 2, Return[$Failed]];
  numerator = Lookup[data, parts[[1]], Missing["NotFound"]];
  denominator = Lookup[data, parts[[2]], Missing["NotFound"]];
  If[parts[[2]] == "W",
    denominator = First[Flatten[{Lookup[data, "W", Missing["NotFound"]]}]]];
  If[!ArrayQ[numerator, 4] || MissingQ[denominator], Return[$Failed]];
  Quiet[If[ArrayQ[denominator, 4],
    numerator[[il, ig, id, is]]/denominator[[il, ig, id, is]],
    numerator[[il, ig, id, is]]/denominator]]
];

(* Paired form for a path through 4-D bias space. Each row of indices selects
   one point, unlike Part with several list indices, which forms a product. *)
lktGridPointValues[data_Association, name_String, indices_List] := Module[
  {key = ToUpperCase[name], stored, parts, numerator, denominator},
  stored = Lookup[data, key, Missing["NotFound"]];
  If[ArrayQ[stored, 4], Return[Extract[stored, indices]]];
  parts = StringSplit[key, "_"];
  If[Length[parts] != 2, Return[$Failed]];
  numerator = Lookup[data, parts[[1]], Missing["NotFound"]];
  denominator = Lookup[data, parts[[2]], Missing["NotFound"]];
  If[parts[[2]] == "W",
    denominator = First[Flatten[{Lookup[data, "W", Missing["NotFound"]]}]]];
  If[!ArrayQ[numerator, 4] || MissingQ[denominator], Return[$Failed]];
  Quiet[If[ArrayQ[denominator, 4],
    Extract[numerator, indices]/Extract[denominator, indices],
    Extract[numerator, indices]/denominator]]
];

(* Constant-time eligibility check for the compiled path. PackedArrayQ avoids
   scanning a full 4-D table; one element establishes that the packed type is
   machine real rather than integer. *)
lktPackedRealArrayQ[array_, depth_Integer] :=
  Developer`PackedArrayQ[array] && Length[Dimensions[array]] == depth &&
    MachineNumberQ[Extract[array, ConstantArray[1, depth]]];

(* Resolve a stored variable or A_B ratio for the compiled kernel. Unsupported
   or unpacked arrays return $Failed and transparently fall back to the general
   Wolfram Language implementation. Packed machine NaNs propagate normally. *)
lktKernelInput[data_Association, name_String] := Module[
  {key = ToUpperCase[name], stored, parts, numerator, denominator, divide,
   scale = 1., w},
  stored = Lookup[data, key, Missing["NotFound"]];
  If[lktPackedRealArrayQ[stored, 4],
    numerator = stored; denominator = stored; divide = 0,
    parts = StringSplit[key, "_"];
    If[Length[parts] != 2, Return[$Failed]];
    numerator = Lookup[data, parts[[1]], Missing["NotFound"]];
    If[!lktPackedRealArrayQ[numerator, 4], Return[$Failed]];
    If[parts[[2]] == "W",
      w = Flatten[{Lookup[data, "W", Missing["NotFound"]]}];
      If[Length[w] != 1 || !NumericQ[First[w]] || First[w] == 0,
        Return[$Failed]];
      denominator = numerator; divide = 0; scale = 1./N[First[w]],
      denominator = Lookup[data, parts[[2]], Missing["NotFound"]];
      If[!lktPackedRealArrayQ[denominator, 4], Return[$Failed]];
      divide = 1]];
  {numerator, denominator, divide, scale}
];

(* Generate a fixed-signature point kernel. Tables remain separate 4-D
   arguments; only the output statements vary with N. *)
lktPointKernel[n_Integer?Positive, divideFlags_List] :=
  lktPointKernel[n, divideFlags] = Module[
    {decls, locals, init, updates, writes, source},
    decls = StringRiffle[Table[
      "{num" <> ToString[i] <> ",_Real,4},{den" <> ToString[i] <>
        ",_Real,4},{scale" <>
        ToString[i] <> ",_Real}", {i, n}], ","];
    locals = StringRiffle[Flatten[Table[
      {"value" <> ToString[i], "valid" <> ToString[i],
       "corner" <> ToString[i], "dv" <> ToString[i]}, {i, n}]], ","];
    init = StringRiffle[Table["value" <> ToString[i] <> "=0.;valid" <>
        ToString[i] <> "=1.", {i, n}], ";"];
    updates = StringRiffle[Table[
      If[divideFlags[[i]] == 1,
        "dv" <> ToString[i] <> "=den" <> ToString[i] <>
        "[[il+a,ig+b,id+c,is+d]];If[dv" <> ToString[i] <>
        "==0.,valid" <> ToString[i] <> "=0.;corner" <> ToString[i] <>
        "=0.,corner" <> ToString[i] <> "=num" <> ToString[i] <>
        "[[il+a,ig+b,id+c,is+d]]/dv" <> ToString[i] <> "]",
        "corner" <> ToString[i] <> "=num" <> ToString[i] <>
        "[[il+a,ig+b,id+c,is+d]]"] <> ";value" <> ToString[i] <>
        "+=weight corner" <> ToString[i], {i, n}], ";"];
    writes = StringRiffle[Table[
      "output[[p," <> ToString[2 i - 1] <> "]]=scale" <> ToString[i] <>
      " value" <> ToString[i] <> ";output[[p," <> ToString[2 i] <>
      "]]=valid" <> ToString[i], {i, n}], ";"];
    source = "Compile[{{lAxis,_Real,1},{gAxis,_Real,1},{dAxis,_Real,1}," <>
      "{sAxis,_Real,1}," <> decls <> ",{points,_Real,2}},Module[" <>
      "{np=Length[points],output,p,il,ig,id,is,a,b,c,d,l,g,vd,vs,wl,wg,wd,ws,weight,lo,hi,mid," <>
      locals <> "},output=Table[0.,{np},{" <> ToString[2 n] <> "}];" <>
      "For[p=1,p<=np,p++,l=points[[p,1]];g=points[[p,2]];vd=points[[p,3]];vs=points[[p,4]];" <>
      "lo=1;hi=Length[lAxis]-1;While[lo<hi,mid=Quotient[lo+hi+1,2];If[lAxis[[mid]]<=l,lo=mid,hi=mid-1]];il=lo;" <>
      "lo=1;hi=Length[gAxis]-1;While[lo<hi,mid=Quotient[lo+hi+1,2];If[gAxis[[mid]]<=g,lo=mid,hi=mid-1]];ig=lo;" <>
      "lo=1;hi=Length[dAxis]-1;While[lo<hi,mid=Quotient[lo+hi+1,2];If[dAxis[[mid]]<=vd,lo=mid,hi=mid-1]];id=lo;" <>
      "lo=1;hi=Length[sAxis]-1;While[lo<hi,mid=Quotient[lo+hi+1,2];If[sAxis[[mid]]<=vs,lo=mid,hi=mid-1]];is=lo;" <>
      "wl=(l-lAxis[[il]])/(lAxis[[il+1]]-lAxis[[il]]);" <>
      "wg=(g-gAxis[[ig]])/(gAxis[[ig+1]]-gAxis[[ig]]);" <>
      "wd=(vd-dAxis[[id]])/(dAxis[[id+1]]-dAxis[[id]]);" <>
      "ws=(vs-sAxis[[is]])/(sAxis[[is+1]]-sAxis[[is]]);" <> init <> ";" <>
      "For[a=0,a<=1,a++,For[b=0,b<=1,b++,For[c=0,c<=1,c++,For[d=0,d<=1,d++," <>
      "weight=If[a==0,1.-wl,wl] If[b==0,1.-wg,wg] If[c==0,1.-wd,wd] If[d==0,1.-ws,ws];" <>
      updates <> "]]]];" <> writes <> "];output],RuntimeOptions->\"Speed\"]";
    ToExpression[source]
  ];

lktPointBatchPrepared[data_Association, names_List, points_List,
    inputs_List] := Module[{n = Length[names], axes, packedPoints, raw},
  If[names == {} || points == {}, Return[{}]];
  axes = data /@ {"L", "VGS", "VDS", "VSB"};
  If[!And @@ (lktPackedRealArrayQ[#, 1] & /@ axes), Return[$Failed]];
  packedPoints = Developer`ToPackedArray[N[points]];
  If[!lktPackedRealArrayQ[packedPoints, 2], Return[$Failed]];
  raw = lktPointKernel[n, inputs[[All, 3]]][Sequence @@ axes,
    Sequence @@ Flatten[inputs[[All, {1, 2, 4}]], 1], packedPoints];
  Table[MapThread[If[#2 == 1., #1, Indeterminate] &,
    {raw[[All, 2 r - 1]], raw[[All, 2 r]]}], {r, n}]
];

lktPointBatch[data_Association, names_List, points_List] := Module[{inputs},
  If[names == {} || points == {}, Return[{}]];
  inputs = lktKernelInput[data, #] & /@ names;
  If[MemberQ[inputs, $Failed], Return[$Failed]];
  lktPointBatchPrepared[data, names, points, inputs]
];

lktPointValues[data_Association, name_String, points_List] := Module[{values},
  values = lktPointBatch[data, {name}, points];
  If[values === $Failed, $Failed, First[values]]
];

lktValidatedPointBatch[data_Association, names_List, points_List] := Module[
  {axes, valid, safePoints, values},
  If[names == {} || points == {}, Return[{}]];
  axes = data /@ {"L", "VGS", "VDS", "VSB"};
  valid = Function[point, Length[point] == 4 && And @@ MapThread[
      NumericQ[#2] && First[#1] <= #2 <= Last[#1] &,
      {axes, point}]] /@ points;
  safePoints = MapThread[If[#2, N[#1], First /@ axes] &, {points, valid}];
  values = lktPointBatch[data, names, safePoints];
  If[values === $Failed, Return[$Failed]];
  Map[MapThread[If[#2, #1, Indeterminate] &, {#, valid}] &, values]
];

lktValidatedPointValues[data_Association, name_String, points_List] := Module[
  {axes, valid, safePoints, values},
  If[points == {}, Return[{}]];
  axes = data /@ {"L", "VGS", "VDS", "VSB"};
  valid = Function[point, Length[point] == 4 && And @@ MapThread[
      NumericQ[#2] && First[#1] <= #2 <= Last[#1] &,
      {axes, point}]] /@ points;
  safePoints = MapThread[If[#2, N[#1], First /@ axes] &, {points, valid}];
  values = lktPointValues[data, name, safePoints];
  If[values === $Failed, Return[$Failed]];
  MapThread[If[#2, #1, Indeterminate] &, {values, valid}]
];

(* Generate a fixed-signature VGS sweep kernel. Unlike the point kernel, this
   kernel keeps the three non-VGS brackets outside the VGS loop and evaluates
   all requested curves in the same corner traversal. The output is flattened
   by combination, then VGS, with value/validity columns for each variable. *)
lktVGSSweepKernel[n_Integer?Positive, divideFlags_List] :=
  lktVGSSweepKernel[n, divideFlags] = Module[
    {decls, locals, init, updates, writes, source},
    decls = StringRiffle[Table[
      "{num" <> ToString[i] <> ",_Real,4},{den" <> ToString[i] <>
        ",_Real,4},{scale" <>
        ToString[i] <> ",_Real}", {i, n}], ","];
    locals = StringRiffle[Flatten[Table[
      {"value" <> ToString[i], "valid" <> ToString[i],
       "corner" <> ToString[i], "dv" <> ToString[i]}, {i, n}]], ","];
    init = StringRiffle[Table[
      "value" <> ToString[i] <> "=0.;valid" <> ToString[i] <> "=1.",
      {i, n}], ";"];
    updates = StringRiffle[Table[
      If[divideFlags[[i]] == 1,
        "dv" <> ToString[i] <> "=den" <> ToString[i] <>
          "[[il+a,ig+b,id+c,is+d]];If[dv" <> ToString[i] <>
          "==0.,valid" <> ToString[i] <> "=0.];corner" <>
          ToString[i] <> "=num" <> ToString[i] <>
          "[[il+a,ig+b,id+c,is+d]]/(dv" <>
          ToString[i] <> "+If[dv" <> ToString[i] <> "==0.,1.,0.])",
        "corner" <> ToString[i] <> "=num" <> ToString[i] <>
          "[[il+a,ig+b,id+c,is+d]]"] <> ";value" <> ToString[i] <>
        "+=weight corner" <> ToString[i], {i, n}], ";"];
    writes = StringRiffle[Table[
      "output[[row," <> ToString[2 i - 1] <> "]]=scale" <> ToString[i] <>
        " value" <> ToString[i] <> ";output[[row," <> ToString[2 i] <>
        "]]=valid" <> ToString[i], {i, n}], ";"];
    source = "Compile[{{lAxis,_Real,1},{gAxis,_Real,1},{dAxis,_Real,1}," <>
      "{sAxis,_Real,1}," <> decls <>
      ",{combinations,_Real,2},{vgs,_Real,1}},Module[" <>
      "{nk=Length[combinations],ng=Length[vgs],output,p,q,row,il,ig,id,is," <>
      "a,b,c,d,l,g,vd,vs,wl,wg,wd,ws,weight,lo,hi,mid,gIndices,gWeights," <>
      locals <> "}," <>
      "output=Table[0.,{nk ng},{" <> ToString[2 n] <> "}];" <>
      "gIndices=Table[1,{ng}];gWeights=Table[0.,{ng}];" <>
      "For[q=1,q<=ng,q++,g=vgs[[q]];lo=1;hi=Length[gAxis]-1;While[lo<hi,mid=Quotient[lo+hi+1,2];If[gAxis[[mid]]<=g,lo=mid,hi=mid-1]];" <>
      "gIndices[[q]]=lo;gWeights[[q]]=(g-gAxis[[lo]])/(gAxis[[lo+1]]-gAxis[[lo]])];" <>
      "For[p=1,p<=nk,p++,l=combinations[[p,1]];vd=combinations[[p,2]];" <>
      "vs=combinations[[p,3]];lo=1;hi=Length[lAxis]-1;While[lo<hi,mid=Quotient[lo+hi+1,2];If[lAxis[[mid]]<=l,lo=mid,hi=mid-1]];il=lo;" <>
      "lo=1;hi=Length[dAxis]-1;While[lo<hi,mid=Quotient[lo+hi+1,2];If[dAxis[[mid]]<=vd,lo=mid,hi=mid-1]];id=lo;" <>
      "lo=1;hi=Length[sAxis]-1;While[lo<hi,mid=Quotient[lo+hi+1,2];If[sAxis[[mid]]<=vs,lo=mid,hi=mid-1]];is=lo;" <>
      "wl=(l-lAxis[[il]])/(lAxis[[il+1]]-lAxis[[il]]);" <>
      "wd=(vd-dAxis[[id]])/(dAxis[[id+1]]-dAxis[[id]]);" <>
      "ws=(vs-sAxis[[is]])/(sAxis[[is+1]]-sAxis[[is]]);" <>
      "For[q=1,q<=ng,q++,ig=gIndices[[q]];wg=gWeights[[q]];" <> init <> ";" <>
      "For[a=0,a<=1,a++,For[b=0,b<=1,b++,For[c=0,c<=1,c++,For[d=0,d<=1,d++," <>
      "weight=If[a==0,1.-wl,wl] If[b==0,1.-wg,wg] If[c==0,1.-wd,wd] " <>
      "If[d==0,1.-ws,ws];" <> updates <> "]]]];" <>
      "row=(p-1)ng+q;" <> writes <> "];];output],RuntimeOptions->\"Speed\"]";
    ToExpression[source]
  ];

lktVGSSweepBatch[data_Association, names_List, combinations_List,
    vgs_List] := Module[{inputs, axes, packedCombinations, packedVgs, raw,
    ng, n},
  n = Length[names];
  If[names == {} || combinations == {} || vgs == {}, Return[{}]];
  inputs = lktKernelInput[data, #] & /@ names;
  If[MemberQ[inputs, $Failed], Return[$Failed]];
  axes = data /@ {"L", "VGS", "VDS", "VSB"};
  If[!And @@ (lktPackedRealArrayQ[#, 1] & /@ axes), Return[$Failed]];
  packedCombinations = Developer`ToPackedArray[N[combinations]];
  packedVgs = Developer`ToPackedArray[N[vgs]];
  If[!lktPackedRealArrayQ[packedCombinations, 2] ||
      !lktPackedRealArrayQ[packedVgs, 1], Return[$Failed]];
  raw = lktVGSSweepKernel[n, inputs[[All, 3]]][Sequence @@ axes,
    Sequence @@ Flatten[inputs[[All, {1, 2, 4}]], 1], packedCombinations,
    packedVgs];
  ng = Length[vgs];
  Table[Partition[MapThread[If[#2 == 1., #1, Indeterminate] &,
      {raw[[All, 2 i - 1]], raw[[All, 2 i]]}], ng], {i, n}]
];

(* Validate public sweep coordinates once, execute only safe machine-real
   values, then restore the Cartesian invalid mask to every sampled curve. *)
lktValidatedVGSSweepBatch[data_Association, names_List, combinations_List,
    vgs_List] := Module[{axes, combinationValid, vgsValid, safeCombinations,
    safeVgs, rows},
  If[names == {} || combinations == {} || vgs == {}, Return[{}]];
  axes = data /@ {"L", "VGS", "VDS", "VSB"};
  combinationValid = Function[c,
      Length[c] == 3 && And @@ MapThread[
        NumericQ[#2] && First[#1] <= #2 <= Last[#1] &,
        {axes[[{1, 3, 4}]], c}]] /@ combinations;
  vgsValid = NumericQ[#] && First[axes[[2]]] <= # <= Last[axes[[2]]] & /@ vgs;
  safeCombinations = MapThread[
    If[#2, N[#1], First /@ axes[[{1, 3, 4}]]] &,
    {combinations, combinationValid}];
  safeVgs = MapThread[If[#2, N[#1], First[axes[[2]]]] &, {vgs, vgsValid}];
  rows = lktVGSSweepBatch[data, names, safeCombinations, safeVgs];
  If[rows === $Failed, Return[$Failed]];
  Table[MapThread[Function[{row, validCombination},
      MapThread[If[validCombination && #2, #1, Indeterminate] &,
        {row, vgsValid}]], {rows[[i]], combinationValid}], {i, Length[names]}]
];

(* Sort and invert each mode-3 curve inside the VM. Output column 2 is a
   validity flag so out-of-range targets can be restored as Indeterminate. *)
lktCurveBatchKernel = Compile[{
    {xRows, _Real, 2}, {yRows, _Real, 2}, {targets, _Real, 2},
    {branchMode, _Integer}, {methodMode, _Integer}},
  Module[{nr = Length[xRows], ng = Length[xRows[[1]]], nt = Length[targets[[1]]],
    output, xs, ys, h, delta, slopes, p, j, k, row, start, finish,
    maxIndex, n, unique, xv, yv, target, h1, h2, d1, d2, slope, w1, w2,
    interval, u, u2, u3, value, ascending, strictDescending, temp},
    output = Table[0.0, {nr nt}, {2}];
    xs = Table[0.0, {ng}]; ys = Table[0.0, {ng}];
    h = Table[0.0, {ng - 1}]; delta = Table[0.0, {ng - 1}];
    slopes = Table[0.0, {ng}];
    For[p = 1, p <= nr, p++,
      maxIndex = 1;
      For[j = 2, j <= ng, j++,
        If[xRows[[p, j]] > xRows[[p, maxIndex]], maxIndex = j]];
      start = If[branchMode == 1, maxIndex, 1];
      finish = If[branchMode == 2, maxIndex, ng];
      n = 0;
      For[j = start, j <= finish, j++,
        xv = xRows[[p, j]]; yv = yRows[[p, j]];
        If[xv == xv && yv == yv,
          n++;
          xs[[n]] = xv; ys[[n]] = yv;
        ];
      ];
      ascending = 1; strictDescending = 1;
      For[j = 2, j <= n, j++,
        If[xs[[j]] < xs[[j - 1]], ascending = 0];
        If[xs[[j]] >= xs[[j - 1]], strictDescending = 0];
      ];
      If[strictDescending == 1,
        For[j = 1, j <= Quotient[n, 2], j++,
          temp = xs[[j]]; xs[[j]] = xs[[n - j + 1]];
          xs[[n - j + 1]] = temp;
          temp = ys[[j]]; ys[[j]] = ys[[n - j + 1]];
          ys[[n - j + 1]] = temp;
        ],
        If[ascending == 0,
          For[j = 2, j <= n, j++,
            xv = xs[[j]]; yv = ys[[j]]; k = j;
            While[k > 1 && xs[[k - 1]] > xv,
              xs[[k]] = xs[[k - 1]]; ys[[k]] = ys[[k - 1]]; k--];
            xs[[k]] = xv; ys[[k]] = yv;
          ]
        ]
      ];
      unique = 0;
      For[j = 1, j <= n, j++,
        If[unique == 0 || xs[[j]] != xs[[unique]],
          unique++; xs[[unique]] = xs[[j]]; ys[[unique]] = ys[[j]]];
      ];
      If[unique >= 2 && methodMode == 0,
        For[j = 1, j < unique, j++,
          h[[j]] = xs[[j + 1]] - xs[[j]];
          delta[[j]] = (ys[[j + 1]] - ys[[j]])/h[[j]];
        ];
        If[unique == 2,
          slopes[[1]] = delta[[1]]; slopes[[2]] = delta[[1]],
          h1 = h[[1]]; h2 = h[[2]]; d1 = delta[[1]]; d2 = delta[[2]];
          slope = ((2.0 h1 + h2) d1 - h1 d2)/(h1 + h2);
          If[Sign[slope] != Sign[d1], slope = 0.0,
            If[Sign[d1] != Sign[d2] && Abs[slope] > 3.0 Abs[d1],
              slope = 3.0 d1]];
          slopes[[1]] = slope;
          For[j = 2, j < unique, j++,
            If[delta[[j - 1]] delta[[j]] > 0.0,
              w1 = 2.0 h[[j]] + h[[j - 1]];
              w2 = h[[j]] + 2.0 h[[j - 1]];
              slopes[[j]] = (w1 + w2)/(w1/delta[[j - 1]] + w2/delta[[j]]),
              slopes[[j]] = 0.0];
          ];
          h1 = h[[unique - 1]]; h2 = h[[unique - 2]];
          d1 = delta[[unique - 1]]; d2 = delta[[unique - 2]];
          slope = ((2.0 h1 + h2) d1 - h1 d2)/(h1 + h2);
          If[Sign[slope] != Sign[d1], slope = 0.0,
            If[Sign[d1] != Sign[d2] && Abs[slope] > 3.0 Abs[d1],
              slope = 3.0 d1]];
          slopes[[unique]] = slope;
        ];
      ];
      For[k = 1, k <= nt, k++,
        row = (p - 1) nt + k; target = targets[[p, k]];
        If[unique >= 2 && target >= xs[[1]] && target <= xs[[unique]],
          interval = 1;
          While[interval < unique - 1 && xs[[interval + 1]] <= target,
            interval++];
          h1 = xs[[interval + 1]] - xs[[interval]];
          u = (target - xs[[interval]])/h1; u2 = u u; u3 = u2 u;
          value = If[methodMode == 1,
            (1.0 - u) ys[[interval]] + u ys[[interval + 1]],
            (2.0 u3 - 3.0 u2 + 1.0) ys[[interval]] +
              (u3 - 2.0 u2 + u) h1 slopes[[interval]] +
              (-2.0 u3 + 3.0 u2) ys[[interval + 1]] +
              (u3 - u2) h1 slopes[[interval + 1]]];
          output[[row, 1]] = value; output[[row, 2]] = 1.0,
          output[[row, 1]] = 0.0; output[[row, 2]] = 0.0];
      ];
    ];
    output],
  RuntimeOptions -> "Speed"];

lktCurveLookupBatch[xRows_List, yRows_List, targets_List, variable_String,
    method_String] := Module[
  {packedX, packedY, packedTargets, targetRows, branchMode, raw, rowValid,
   validIndices, fallbackIndices, output, targetCount, normalizedMethod,
   methodMode},
  normalizedMethod = ToLowerCase[method];
  If[!MemberQ[{"pchip", "linear"}, normalizedMethod], Return[$Failed]];
  methodMode = If[normalizedMethod == "linear", 1, 0];
  targetRows = If[ArrayDepth[targets] == 2, targets,
    ConstantArray[targets, Length[xRows]]];
  If[Length[targetRows] != Length[xRows] || targetRows === {} ||
      !SameQ @@ (Length /@ targetRows), Return[$Failed]];
  targetCount = Length[First[targetRows]];
  packedTargets = Developer`ToPackedArray[N[targetRows]];
  If[!lktPackedRealArrayQ[packedTargets, 2], Return[$Failed]];
  rowValid = MapThread[Function[{x, y},
      And @@ MapThread[NumericQ[#1] && NumericQ[#2] &, {x, y}]],
    {xRows, yRows}];
  validIndices = Flatten[Position[rowValid, True]];
  fallbackIndices = Flatten[Position[rowValid, False]];
  output = ConstantArray[{}, Length[xRows]];
  branchMode = Which[variable == "GM_ID", 1,
    MemberQ[{"GM_CGG", "GM_CGS"}, variable], 2, True, 0];
  If[validIndices =!= {},
    packedX = Developer`ToPackedArray[N[xRows[[validIndices]]]];
    packedY = Developer`ToPackedArray[N[yRows[[validIndices]]]];
    If[!lktPackedRealArrayQ[packedX, 2] || !lktPackedRealArrayQ[packedY, 2],
      Return[$Failed]];
    raw = lktCurveBatchKernel[packedX, packedY,
      packedTargets[[validIndices]], branchMode, methodMode];
    output[[validIndices]] = Partition[
      MapThread[If[#2 == 1., #1, Indeterminate] &,
        {raw[[All, 1]], raw[[All, 2]]}], targetCount]];
  Do[output[[i]] = lktCurveLookup[xRows[[i]], yRows[[i]], targetRows[[i]],
      variable, method], {i, fallbackIndices}];
  output
];

lktSqueeze[value_] := Module[{dims},
  If[!ArrayQ[value], Return[value]];
  dims = Select[Dimensions[value], # != 1 &];
  Which[dims == {}, First[Flatten[value]], dims == Dimensions[value], value,
    True, ArrayReshape[value, dims]]
];

lktBracket[axis_List, value_?NumericQ] := Module[{n, i},
  n = Length[axis];
  If[n < 2 || value < First[axis] || value > Last[axis], Return[$Failed]];
  i = Clip[Total[Boole[Thread[axis <= value]]], {1, n - 1}];
  {i, (value - axis[[i]])/(axis[[i + 1]] - axis[[i]])}
];

lktLinearValue[axes_List, arr_, point_List] := Module[
  {brackets, index, weight},
  brackets = MapThread[lktBracket, {axes, point}];
  If[MemberQ[brackets, $Failed], Return[Indeterminate]];
  index = brackets[[All, 1]];
  weight = brackets[[All, 2]];
  Sum[
    arr[[index[[1]] + a, index[[2]] + b, index[[3]] + c, index[[4]] + d]]*
      (If[a == 0, 1 - weight[[1]], weight[[1]]])*
      (If[b == 0, 1 - weight[[2]], weight[[2]]])*
      (If[c == 0, 1 - weight[[3]], weight[[3]]])*
      (If[d == 0, 1 - weight[[4]], weight[[4]]]),
    {a, 0, 1}, {b, 0, 1}, {c, 0, 1}, {d, 0, 1}]
];

(* Vectorized path for one VGS sweep. Only the eight L/VDS/VSB neighbor lines
   are read, and ratio arithmetic is performed only on those grid entries. *)
lktDirectLookupScalarVector[data_Association, outvar_String, l_, vgs_List,
    vds_, vsb_] := Module[
  {axes, bl, bd, bs, il, id, is, wl, wd, ws, valid, safeVgs, ig, wg,
   result, sweeps, a, c, d, lower, upper, weight},
  sweeps = lktValidatedVGSSweepBatch[data, {outvar}, {{l, vds, vsb}}, vgs];
  If[sweeps =!= $Failed, Return[First[First[sweeps]]]];
  axes = data /@ {"L", "VGS", "VDS", "VSB"};
  bl = lktBracket[axes[[1]], l];
  bd = lktBracket[axes[[3]], vds];
  bs = lktBracket[axes[[4]], vsb];
  If[MemberQ[{bl, bd, bs}, $Failed],
    Return[ConstantArray[Indeterminate, Length[vgs]]]];
  {il, wl} = bl; {id, wd} = bd; {is, ws} = bs;
  valid = NumericQ[#] && First[axes[[2]]] <= # <= Last[axes[[2]]] & /@ vgs;
  safeVgs = MapThread[If[#2, #1, First[axes[[2]]]] &, {vgs, valid}];
  ig = Clip[Total[Boole[Thread[axes[[2]] <= #]]],
      {1, Length[axes[[2]]] - 1}] & /@ safeVgs;
  wg = (safeVgs - axes[[2]][[ig]])/
    (axes[[2]][[ig + 1]] - axes[[2]][[ig]]);
  result = ConstantArray[0., Length[vgs]];
  Do[
    lower = lktGridValues[data, outvar, il + a, ig, id + c, is + d];
    upper = lktGridValues[data, outvar, il + a, ig + 1, id + c, is + d];
    If[lower === $Failed || upper === $Failed, Return[$Failed]];
    weight = If[a == 0, 1 - wl, wl] If[c == 0, 1 - wd, wd]
      If[d == 0, 1 - ws, ws];
    result += weight ((1 - wg) lower + wg upper),
    {a, 0, 1}, {c, 0, 1}, {d, 0, 1}];
  MapThread[If[#2, #1, Indeterminate] &, {result, valid}]
];

(* Vectorized interpolation of paired coordinates along an arbitrary path.
   Used by lookupVGS mode 5, where VGS/VDS/VSB change together. *)
lktDirectLookupPointVectors[data_Association, outvar_String, l_, vgs_List,
    vds_List, vsb_List] := Module[
  {axes, n, coordinates, validAxes, safe, indices, weights, valid, result,
   compiled, offsets, pointIndices, values, cornerWeight, a, b, c, d},
  n = Length[vgs];
  If[Length[vds] != n || Length[vsb] != n, Return[$Failed]];
  axes = data /@ {"L", "VGS", "VDS", "VSB"};
  coordinates = {ConstantArray[l, n], vgs, vds, vsb};
  validAxes = MapThread[
    Function[{axis, coordinateValues},
      NumericQ[#] && First[axis] <= # <= Last[axis] & /@ coordinateValues],
    {axes, coordinates}];
  safe = MapThread[
    Function[{axis, coordinateValues, flags},
      MapThread[If[#2, #1, First[axis]] &, {coordinateValues, flags}]],
    {axes, coordinates, validAxes}];
  valid = And @@@ Transpose[validAxes];
  compiled = lktPointValues[data, outvar, Transpose[safe]];
  If[compiled =!= $Failed,
    Return[MapThread[If[#2, #1, Indeterminate] &, {compiled, valid}]]];
  indices = MapThread[
    Function[{axis, coordinateValues},
      Clip[Total[Boole[Thread[axis <= #]]], {1, Length[axis] - 1}] & /@
        coordinateValues],
    {axes, safe}];
  weights = MapThread[
    Function[{axis, coordinateValues, indexValues},
      (coordinateValues - axis[[indexValues]])/
        (axis[[indexValues + 1]] - axis[[indexValues]])],
    {axes, safe, indices}];
  result = ConstantArray[0., n];
  Do[
    offsets = {a, b, c, d};
    pointIndices = Transpose[MapThread[Plus, {indices, offsets}]];
    values = lktGridPointValues[data, outvar, pointIndices];
    If[values === $Failed, Return[$Failed]];
    cornerWeight = Times @@ MapThread[
      If[#2 == 0, 1 - #1, #1] &, {weights, offsets}];
    result += cornerWeight values,
    {a, 0, 1}, {b, 0, 1}, {c, 0, 1}, {d, 0, 1}];
  MapThread[If[#2, #1, Indeterminate] &, {result, valid}]
];

(* Evaluate one source-referenced path where VGS and VDS move with VSB. *)
lktUnknownSourceVGSOne[data_Association, targetVar_String, path_List,
    targets_List, method_String] := Module[
  {axes, sourceBias, x, pairs},
  If[Length[path] != 3 || !And @@ (NumericQ /@ path), Return[$Failed]];
  axes = data /@ {"L", "VGS", "VDS", "VSB"};
  sourceBias = Range[Max[axes[[4]]], Min[axes[[4]]],
    -Abs[axes[[2, 2]] - axes[[2, 1]]]];
  x = lktDirectLookupPointVectors[data, targetVar, path[[1]],
    path[[3]] - sourceBias, path[[2]] - sourceBias, sourceBias];
  If[x === $Failed, Return[$Failed]];
  pairs = Select[Transpose[{x, path[[3]] - sourceBias}],
    NumericQ[First[#]] &];
  If[Length[pairs] < 2, ConstantArray[Indeterminate, Length[targets]],
    lktCurveLookup[pairs[[All, 1]], pairs[[All, 2]], targets, targetVar,
      method]]
];

(* Batch several source-referenced paths in one point-kernel call. This
   geometry remains separate from the fixed-source VGS sweep kernel. *)
lktUnknownSourceVGSBatch[data_Association, targetVar_String, paths_List,
    targets_, method_String] := Module[
  {axes, sourceBias, pathLength, targetRows, pointsByPath, allPoints,
   values, valueRows, vgsRows, result, fallback, one, x, pairs},
  If[paths == {}, Return[{}]];
  If[!And @@ (Length[#] == 3 && And @@ (NumericQ /@ #) & /@ paths),
    Return[$Failed]];
  targetRows = If[ArrayDepth[targets] == 2, targets,
    ConstantArray[Flatten[{targets}], Length[paths]]];
  If[Length[targetRows] =!= Length[paths] || targetRows === {} ||
      !SameQ @@ (Length /@ targetRows), Return[$Failed]];
  If[Length[paths] == 1,
    one = lktUnknownSourceVGSOne[data, targetVar, First[paths],
      First[targetRows], method];
    Return[If[one === $Failed, $Failed, {one}]]
  ];
  axes = data /@ {"L", "VGS", "VDS", "VSB"};
  sourceBias = Range[Max[axes[[4]]], Min[axes[[4]]],
    -Abs[axes[[2, 2]] - axes[[2, 1]]]];
  pathLength = Length[sourceBias];
  pointsByPath = Function[path,
      Transpose[{ConstantArray[path[[1]], pathLength],
        path[[3]] - sourceBias, path[[2]] - sourceBias, sourceBias}]] /@ paths;
  allPoints = Flatten[pointsByPath, 1];
  values = lktValidatedPointBatch[data, {targetVar}, allPoints];
  If[values === $Failed,
    fallback = MapThread[Function[{path, pathTargets},
      x = lktDirectLookupPointVectors[data, targetVar, path[[1]],
        path[[3]] - sourceBias, path[[2]] - sourceBias, sourceBias];
      If[x === $Failed, $Failed,
        pairs = Select[Transpose[{x, path[[3]] - sourceBias}],
          NumericQ[First[#]] &];
        If[Length[pairs] < 2,
          ConstantArray[Indeterminate, Length[pathTargets]],
          lktCurveLookup[pairs[[All, 1]], pairs[[All, 2]], pathTargets,
            targetVar, method]]]], {paths, targetRows}];
    Return[If[MemberQ[fallback, $Failed], $Failed, fallback]]
  ];
  valueRows = Partition[First[values], pathLength];
  vgsRows = (#[[3]] - sourceBias) & /@ paths;
  result = MapThread[Function[{row, vgs, pathTargets},
      pairs = Select[Transpose[{row, vgs}], NumericQ[First[#]] &];
      If[Length[pairs] < 2, ConstantArray[Indeterminate, Length[pathTargets]],
        lktCurveLookup[pairs[[All, 1]], pairs[[All, 2]], pathTargets,
          targetVar, method]]], {valueRows, vgsRows, targetRows}];
  result
];

(* Generate only one contiguous slice of Tuples. The last coordinate varies
   fastest, matching Tuples and the public result dimensions. *)
lktCartesianChunkPoints[query_List, start_Integer, count_Integer] := Module[
  {dims = Length /@ query, strides, rank, index, k},
  rank = Length[query];
  strides = Table[
    If[j == rank, 1, Times @@ Take[dims, {j + 1, rank}]],
    {j, rank}];
  Table[
    index = Mod[Quotient[k, #1], #2] + 1 & @@@ Transpose[{strides, dims}];
    MapThread[#1[[#2]] &, {query, index}],
    {k, start, start + count - 1}]
];

(* Evaluate a Cartesian query through the compiled point kernel without
   materializing all points or a full derived ratio array. *)
lktCartesianSlice[data_Association, outvar_String, query_List,
    start_Integer, count_Integer] := Module[
  {points, chunk},
  If[count <= 0, Return[{}]];
  points = lktCartesianChunkPoints[query, start, count];
  chunk = lktValidatedPointValues[data, outvar, points];
  If[chunk === $Failed, Return[$Failed]];
  chunk
];

lktCartesianLookup[data_Association, outvar_String, query_List] :=
 Module[{dims, total, chunkSize, start, count, values},
  dims = Length /@ query;
  If[!And @@ (# > 0 & /@ dims), Return[{}]];
  total = Times @@ dims;
  chunkSize = Max[1, lktCartesianChunkSize];
  values = Reap[
      For[start = 0, start < total, start += chunkSize,
       count = Min[chunkSize, total - start];
       values = lktCartesianSlice[data, outvar, query, start, count];
       If[values === $Failed, Return[$Failed]];
       Sow[values];
      ]][[2]];
   If[values === {}, {}, Join @@ First[values]]
  ];

lktDirectLookup[data_Association, outvar_String, params_Association] := Module[
  {axes, query, arr, dims, values},
  axes = {data["L"], data["VGS"], data["VDS"], data["VSB"]};
  query = Flatten[{Lookup[params, #]}] & /@ {"L", "VGS", "VDS", "VSB"};
  dims = Length /@ query;
  If[MemberQ[dims, 0], Return[{}]];
  If[Length[query[[1]]] == 1 && Length[query[[3]]] == 1 &&
      Length[query[[4]]] == 1,
    values = lktDirectLookupScalarVector[data, outvar, First[query[[1]]],
      query[[2]], First[query[[3]]], First[query[[4]]]];
    If[values === $Failed, Return[$Failed]];
    Return[lktSqueeze[ArrayReshape[values, dims]]]];
  values = lktCartesianLookup[data, outvar, query];
  If[values =!= $Failed,
    Return[lktSqueeze[ArrayReshape[values, dims]]]];
  arr = lktArray[data, outvar];
  If[arr === $Failed, Return[$Failed]];
  values = lktLinearValue[axes, arr, #] & /@ Tuples[query];
  lktSqueeze[ArrayReshape[values, dims]]
];

lktDirectLookupMulti[data_Association, outvars_List, params_Association] :=
 Module[{axes, query, dims, total, chunkSize, start, count, points, valid,
   safePoints, chunkValues, values, arrays, inputs, names},
  axes = data /@ {"L", "VGS", "VDS", "VSB"};
  query = Flatten[{Lookup[params, #]}] & /@ {"L", "VGS", "VDS", "VSB"};
  dims = Length /@ query;
  If[MemberQ[dims, 0], Return[ConstantArray[{}, Length[outvars]]]];
  total = Times @@ dims;
  chunkSize = Max[1, lktCartesianChunkSize];
  names = ToUpperCase /@ outvars;
  inputs = lktKernelInput[data, #] & /@ names;
  If[MemberQ[inputs, $Failed], inputs = $Failed];
  values = ConstantArray[{}, Length[outvars]];
  For[start = 0, start < total, start += chunkSize,
    count = Min[chunkSize, total - start];
    points = lktCartesianChunkPoints[query, start, count];
    valid = Function[point, And @@ MapThread[
        NumericQ[#2] && First[#1] <= #2 <= Last[#1] &, {axes, point}]] /@
      points;
    safePoints = MapThread[If[#2, N[#1], First /@ axes] &,
      {points, valid}];
    chunkValues = If[inputs === $Failed, $Failed,
      lktPointBatchPrepared[data, names, safePoints, inputs]];
    If[chunkValues === $Failed, Break[]];
    chunkValues = MapThread[If[#2, #1, Indeterminate] &, {#, valid}] & /@
      chunkValues;
    values = MapThread[Join, {values, chunkValues}]
  ];
  If[Total[Length /@ values] == 0 ||
      !And @@ (Length[#] == total & /@ values),
    arrays = lktDirectLookup[data, #, params] & /@ outvars;
    If[MemberQ[arrays, $Failed], Return[$Failed]];
    Return[arrays]];
  Return[lktSqueeze /@ (ArrayReshape[#, dims] & /@ values)];
 ];

lktPchipEndpoint[h1_, h2_, delta1_, delta2_] := Module[{slope},
  slope = ((2*h1 + h2)*delta1 - h1*delta2)/(h1 + h2);
  Which[
    Sign[slope] != Sign[delta1], 0.,
    Sign[delta1] != Sign[delta2] && Abs[slope] > 3*Abs[delta1], 3*delta1,
    True, slope]
];

lktPchipSlopes[x_List, y_List] := Module[
  {n = Length[x], h, delta, slopes, k, w1, w2},
  h = Differences[x];
  delta = Differences[y]/h;
  If[n == 2, Return[{First[delta], First[delta]}]];
  slopes = ConstantArray[0., n];
  slopes[[1]] = lktPchipEndpoint[h[[1]], h[[2]], delta[[1]], delta[[2]]];
  slopes[[-1]] = lktPchipEndpoint[h[[-1]], h[[-2]], delta[[-1]], delta[[-2]]];
  For[k = 2, k <= n - 1, k++,
    If[delta[[k - 1]]*delta[[k]] > 0,
      w1 = 2*h[[k]] + h[[k - 1]];
      w2 = h[[k]] + 2*h[[k - 1]];
      slopes[[k]] = (w1 + w2)/(w1/delta[[k - 1]] + w2/delta[[k]])]
  ];
  slopes
];

lktPchipValue[pairs_List, targets_List] := Module[
  {x, y, slopes, derivativeData, interpolant, xmin, xmax},
  x = pairs[[All, 1]]; y = pairs[[All, 2]];
  slopes = lktPchipSlopes[x, y];
  derivativeData = MapThread[{{#1}, #2, #3} &, {x, y, slopes}];
  interpolant = Interpolation[derivativeData, Method -> "Hermite"];
  xmin = First[x]; xmax = Last[x];
  If[NumericQ[#] && xmin <= # <= xmax, Quiet[interpolant[#]], Indeterminate] & /@
    targets
];

(* Final one-dimensional interpolation used by cross-lookup and lookupVGS. *)
lktCurveLookup[x_List, y_List, target_, variable_String, method_String] := Module[
  {pairs, idx, normalizedMethod, order, targets, scalarTarget, result,
   interpolant},
  scalarTarget = !ListQ[target];
  targets = Flatten[{target}];
  pairs = Select[Transpose[{x, y}], NumericQ[#[[1]]] && NumericQ[#[[2]]] &];
  If[Length[pairs] < 2, Return[If[scalarTarget, Indeterminate,
    ConstantArray[Indeterminate, Length[targets]]]]];
  idx = First@Ordering[pairs[[All, 1]], -1];
  pairs = Which[
    variable == "GM_ID", pairs[[idx ;;]],
    MemberQ[{"GM_CGG", "GM_CGS"}, variable], pairs[[;; idx]],
    True, pairs];
  pairs = DeleteDuplicatesBy[SortBy[pairs, First], First];
  If[Length[pairs] < 2, Return[If[scalarTarget, Indeterminate,
    ConstantArray[Indeterminate, Length[targets]]]]];
  normalizedMethod = ToLowerCase[method];
  If[!MemberQ[{"pchip", "linear", "cubic"}, normalizedMethod],
    Return[$Failed]];
  result = If[normalizedMethod == "pchip",
    lktPchipValue[pairs, targets],
    order = If[normalizedMethod == "linear", 1, Min[3, Length[pairs] - 1]];
    interpolant = Interpolation[pairs, InterpolationOrder -> order];
    If[!NumericQ[#] || # < First[pairs][[1]] || # > Last[pairs][[1]],
      Indeterminate, Quiet[interpolant[#]]] & /@ targets];
  If[scalarTarget, First[result], result]
];

(* Map and MapThread integration. lktThreaded marks the single paired
   dimension; ordinary lists inside lookup retain their Cartesian semantics. *)
lktThreadValue[value_, index_Integer] := If[Head[value] === lktThreaded,
  value[[1, index]], value];

lktMappedDirectLookup[data_Association, outvar_String, parameterRows_List] :=
 Module[{queryRows, dimensions, counts, offsets, total, chunkSize,
   start, count, cursor, remaining, row, localStart, takeCount, points,
   chunk, gathered, values, starts},
  queryRows = Table[
    Flatten[{Lookup[params, #]}] & /@ {"L", "VGS", "VDS", "VSB"},
    {params, parameterRows}];
  dimensions = Map[Length, queryRows, {2}];
  counts = Times @@@ dimensions;
  If[MemberQ[counts, 0], Return[$Failed]];
  offsets = Most[FoldList[Plus, 0, counts]];
  total = Total[counts];
  chunkSize = Max[1, lktCartesianChunkSize];
  If[total <= chunkSize,
    points = Flatten[Tuples /@ queryRows, 1];
    values = lktValidatedPointValues[data, outvar, points];
    If[values === $Failed, Return[$Failed]];
    starts = Most[FoldList[Plus, 1, counts]];
    Return[MapThread[
      lktSqueeze[ArrayReshape[Take[values, {#1, #1 + #2 - 1}], #3]] &,
      {starts, counts, dimensions}]]
  ];
  gathered = Reap[
      For[start = 0, start < total, start += chunkSize,
        count = Min[chunkSize, total - start];
        cursor = start; remaining = count; row = 1; points = {};
        While[row < Length[counts] && cursor >= offsets[[row]] + counts[[row]],
          row++];
        While[remaining > 0,
          localStart = cursor - offsets[[row]];
          takeCount = Min[remaining, counts[[row]] - localStart];
          points = Join[points, lktCartesianChunkPoints[queryRows[[row]],
            localStart, takeCount]];
          cursor += takeCount; remaining -= takeCount; row++];
        chunk = lktValidatedPointValues[data, outvar, points];
        If[chunk === $Failed, Return[$Failed]];
        Sow[chunk];
      ]][[2]];
  values = If[gathered === {}, {}, Join @@ First[gathered]];
  starts = Most[FoldList[Plus, 1, counts]];
  MapThread[lktSqueeze[ArrayReshape[Take[values, {#1, #1 + #2 - 1}], #3]] &,
    {starts, counts, dimensions}]
];

lktMappedLookup[data_Association, outvar_String, args_List,
    threadCount_Integer] := Module[
  {params, defaults, method, warning, nonCoordinates, inputVar, parameterRows,
    targetRows, lRows, vdsRows, vsbRows, vgsRows, combinationsByThread,
    counts, allCombinations, starts, rows, result,
    allTargetRows, allResults, dimensions, methods, t},
  params = lktParseArgs[args];
  If[params === $Failed || !And @@ (FreeQ[#, lktThreaded] ||
        Head[#] === lktThreaded & /@ Values[params]), Return[$Failed]];
  defaults = <|"L" -> Min[data["L"]], "VGS" -> data["VGS"],
    "VDS" -> Max[data["VDS"]]/2, "VSB" -> 0.,
    "METHOD" -> "pchip", "WARNING" -> "off"|>;
  params = Join[defaults, params];
  nonCoordinates = Complement[Keys[params], Keys[defaults]];
  parameterRows = Table[Map[lktThreadValue[#, t] &, params],
    {t, threadCount}];
  If[nonCoordinates == {},
    Return[lktMappedDirectLookup[data, outvar, parameterRows]]];
  If[Length[nonCoordinates] != 1, Return[$Failed]];
  inputVar = First[nonCoordinates];
  If[!StringContainsQ[outvar, "_"] || !StringContainsQ[inputVar, "_"],
    Return[$Failed]];
  methods = lktNormalizeMethod[#["METHOD"]] & /@ parameterRows;
  If[MemberQ[methods, $Failed] || !SameQ @@ methods, Return[$Failed]];
  method = First[methods];
  warning = ToLowerCase[ToString[parameterRows[[1, "WARNING"]]]];
  If[!SameQ @@ (ToLowerCase[ToString[#["WARNING"]]] & /@ parameterRows),
    Return[$Failed]];
  targetRows = Flatten[{#[inputVar]}] & /@ parameterRows;
  If[MemberQ[Length /@ targetRows, 0], Return[$Failed]];
  lRows = Flatten[{#["L"]}] & /@ parameterRows;
  vdsRows = Flatten[{#["VDS"]}] & /@ parameterRows;
  vsbRows = Flatten[{#["VSB"]}] & /@ parameterRows;
  vgsRows = Flatten[{#["VGS"]}] & /@ parameterRows;
  If[!SameQ @@ vgsRows, Return[$Failed]];
  combinationsByThread = MapThread[Tuples[{#1, #2, #3}] &,
    {lRows, vdsRows, vsbRows}];
  counts = Length /@ combinationsByThread;
  allCombinations = Flatten[combinationsByThread, 1];
  starts = Most[FoldList[Plus, 1, counts]];
  allTargetRows = Flatten[MapThread[ConstantArray, {targetRows, counts}], 1];
  allResults = lktDirectCrossLookupBatch[data, {inputVar, outvar},
    allCombinations, allTargetRows, method, First[vgsRows]];
  If[allResults === $Failed, Return[$Failed]];
  allResults = First[allResults];
  allResults = MapThread[Take[allResults, {#1, #1 + #2 - 1}] &,
    {starts, counts}];
  rows = Table[
    result = allResults[[t]];
    dimensions = {Length[lRows[[t]]], Length[vdsRows[[t]]],
      Length[vsbRows[[t]]], Length[targetRows[[t]]]};
    lktSqueeze[ArrayReshape[Flatten[result], dimensions]],
    {t, threadCount}];
  If[warning == "on" && !FreeQ[rows, Indeterminate],
    Print["lookup warning: ", inputVar,
      " input out of range (Indeterminate returned)."]];
 rows
 ];

(* A mapped output-variable dimension can be folded into one multi-output
   lookup when the remaining arguments are shared. This preserves Map's
   result order while allowing the N-output kernel to run once. *)
lktMappedLookupOutputList[data_Association, outvars_List, args_List,
    threadCount_Integer] := Module[{expression, result},
  If[!And @@ (StringQ /@ outvars) || Length[outvars] =!= threadCount,
    Return[$Failed]];
  If[FreeQ[args, lktThreaded], Return[lookup[data, outvars, Sequence @@ args]]];
  expression = HoldComplete[lookup[data, outvar, Sequence @@ args]];
  result = Table[
    ReleaseHold[expression /. lktThreaded[value_] :> value[[t]]],
    {t, threadCount}];
  result
];

lktMappedLookupVGS[data_Association, args_List, threadCount_Integer] := Module[
  {params, parameterRows, method, warning, targetVar, targetRows, lRows,
    vdsRows, vsbRows, combinationsByThread, counts, allCombinations,
    starts, allTargetRows, allResults, rows, result, dimensions, paths, methods,
    t},
  params = lktParseArgs[args];
  If[params === $Failed || !And @@ (FreeQ[#, lktThreaded] ||
        Head[#] === lktThreaded & /@ Values[params]), Return[$Failed]];
  targetVar = Which[KeyExistsQ[params, "ID_W"], "ID_W",
    KeyExistsQ[params, "GM_ID"], "GM_ID", True, Return[$Failed]];
  parameterRows = Table[Map[lktThreadValue[#, t] &, params],
    {t, threadCount}];
  methods = lktNormalizeMethod[Lookup[#, "METHOD", "pchip"]] & /@ parameterRows;
  If[MemberQ[methods, $Failed] || !SameQ @@ methods, Return[$Failed]];
  method = First[methods];
  warning = ToLowerCase[ToString[Lookup[parameterRows[[1]], "WARNING", "off"]]];
  If[!SameQ @@ (ToLowerCase[ToString[Lookup[#, "WARNING", "off"]]] & /@
        parameterRows), Return[$Failed]];
  targetRows = Flatten[{#[targetVar]}] & /@ parameterRows;
  If[MemberQ[Length /@ targetRows, 0], Return[$Failed]];
  lRows = Flatten[{Lookup[#, "L", Min[data["L"]]]}] & /@ parameterRows;
  If[KeyExistsQ[params, "VDB"] || KeyExistsQ[params, "VGB"],
    If[!KeyExistsQ[params, "VDB"] || !KeyExistsQ[params, "VGB"] ||
        !And @@ (Length[#] == 1 & /@ lRows), Return[$Failed]];
    paths = MapThread[{First[#1], #2, #3} &,
      {lRows, Lookup[parameterRows, "VDB"], Lookup[parameterRows, "VGB"]}];
    allResults = lktUnknownSourceVGSBatch[data, targetVar, paths, targetRows,
      method];
    If[allResults === $Failed, Return[$Failed]];
    rows = lktSqueeze /@ allResults;
    If[warning == "on" && targetVar == "GM_ID" &&
        !FreeQ[rows, Indeterminate],
      Print["lookupVGS: GM_ID input larger than maximum!"]];
    Return[rows]
  ];
  vdsRows = Flatten[{Lookup[#, "VDS", Max[data["VDS"]]/2]}] & /@ parameterRows;
  vsbRows = Flatten[{Lookup[#, "VSB", 0.]}] & /@ parameterRows;
  combinationsByThread = MapThread[Tuples[{#1, #2, #3}] &,
    {lRows, vdsRows, vsbRows}];
  counts = Length /@ combinationsByThread;
  allCombinations = Flatten[combinationsByThread, 1];
  starts = Most[FoldList[Plus, 1, counts]];
  allTargetRows = Flatten[MapThread[ConstantArray, {targetRows, counts}], 1];
  allResults = lktDirectLookupVGSBatch[data, targetVar, allCombinations,
    allTargetRows, method];
  If[allResults === $Failed, Return[$Failed]];
  allResults = MapThread[Take[allResults, {#1, #1 + #2 - 1}] &,
    {starts, counts}];
  rows = Table[
    result = allResults[[t]];
    dimensions = {Length[lRows[[t]]], Length[vdsRows[[t]]],
      Length[vsbRows[[t]]], Length[targetRows[[t]]]};
    lktSqueeze[ArrayReshape[Flatten[result], dimensions]],
    {t, threadCount}];
  If[warning == "on" && targetVar == "GM_ID" && !FreeQ[rows, Indeterminate],
    Print["lookupVGS: GM_ID input larger than maximum!"]];
  rows
];

lktMappedFallback[body_HoldComplete, lists_List] := Module[{n, function},
  function = body /. HoldComplete[expression_] :> Function[expression];
  n = If[lists === {}, 0, Min[Length /@ lists]];
  Table[Apply[function, lists[[All, i]]], {i, n}]
];

lktMappedHeldCall[
    HoldComplete[lookup[data_, outvar_String, args___]], threadCount_Integer] :=
  lktMappedLookup[data, outvar, {args}, threadCount];

lktMappedHeldCall[
    HoldComplete[lookup[data_, outvar_lktThreaded, args___]],
    threadCount_Integer] :=
  lktMappedLookupOutputList[data, outvar[[1]], {args}, threadCount];

lktMappedHeldCall[
    HoldComplete[lookupVGS[data_, args___]], threadCount_Integer] :=
  lktMappedLookupVGS[data, {args}, threadCount];

lktMappedHeldCall[_, _] := $Failed;

lktMappedDispatch[body_HoldComplete, lists_List] := Module[
  {lengths, chunks, markers, expression, result},
  If[lists === {} || !And @@ (ListQ /@ lists),
    Return[lktMappedFallback[body, lists]]];
  lengths = Length /@ lists;
  If[!SameQ @@ lengths, Return[lktMappedFallback[body, lists]]];
  If[First[lengths] == 0, Return[{}]];
  If[First[lengths] > 4,
    chunks = Transpose[Partition[#, UpTo[4]] & /@ lists];
    Return[Join @@ Table[lktMappedDispatch[body, chunks[[i]]],
      {i, Length[chunks]}]]];
  markers = lktThreaded /@ lists;
  expression = body /. Slot[k_Integer] :> markers[[k]] /.
    Slot[] :> First[markers];
  result = lktMappedHeldCall[expression, First[lengths]];
  If[result === $Failed, lktMappedFallback[body, lists], result]
];

lktHeldLookupBodyQ[HoldComplete[lookup[__]]] := True;
lktHeldLookupBodyQ[HoldComplete[lookupVGS[__]]] := True;
lktHeldLookupBodyQ[_] := False;

lktInstallMapRules[] := Module[{},
  Unprotect[Map, MapThread];
  Map[Function[body_], list_List] /;
      lktHeldLookupBodyQ[HoldComplete[body]] :=
    lktMappedDispatch[HoldComplete[body], {list}];
  MapThread[Function[body_], lists_List] /;
      lktHeldLookupBodyQ[HoldComplete[body]] && lists =!= {} &&
        And @@ (ListQ /@ lists) && SameQ @@ (Length /@ lists) :=
    lktMappedDispatch[HoldComplete[body], lists];
  Protect[Map, MapThread];
];

lktRemoveMapRules[] := Module[{},
  Unprotect[Map, MapThread];
  DownValues[Map] = DeleteCases[DownValues[Map],
    rule_ /; !FreeQ[rule, lktMappedDispatch]];
  DownValues[MapThread] = DeleteCases[DownValues[MapThread],
    rule_ /; !FreeQ[rule, lktMappedDispatch]];
  Protect[Map, MapThread];
];

EnableMapOptimization[] := (lktRemoveMapRules[]; lktInstallMapRules[]; Null);
DisableMapOptimization[] := (lktRemoveMapRules[]; Null);

lookup[data_Association, outvar_String, args___] := Module[
  {params, defaults, method, warning, nonCoordinates, inputVar, targets,
   l, vds, vsb, combinations, rows, result, batch, vgs},
  params = lktParseArgs[{args}];
  If[params === $Failed, Return[$Failed]];
  defaults = <|"L" -> Min[data["L"]], "VGS" -> data["VGS"],
    "VDS" -> Max[data["VDS"]]/2, "VSB" -> 0.,
    "METHOD" -> "pchip", "WARNING" -> "off"|>;
  params = Join[defaults, params];
  method = lktNormalizeMethod[params["METHOD"]];
  If[method === $Failed, Return[$Failed]];
  warning = ToLowerCase[ToString[params["WARNING"]]];
  nonCoordinates = Complement[Keys[params], Keys[defaults]];

  If[nonCoordinates == {}, Return[lktDirectLookup[data, outvar, params]]];
  If[Length[nonCoordinates] != 1, Return[$Failed]];

  inputVar = First[nonCoordinates];
  If[!StringContainsQ[outvar, "_"] || !StringContainsQ[inputVar, "_"],
    Return[$Failed]];
  targets = Flatten[{params[inputVar]}];
  If[targets == {}, Return[{}]];
  l = Flatten[{params["L"]}];
  vds = Flatten[{params["VDS"]}];
  vsb = Flatten[{params["VSB"]}];
  combinations = Tuples[{l, vds, vsb}];
  vgs = Flatten[{params["VGS"]}];
  batch = lktDirectCrossLookupBatch[data, {inputVar, outvar}, combinations,
    targets, method, vgs];
  rows = If[batch === $Failed,
    Table[Module[{x, y},
        x = Flatten[{lktDirectLookup[data, inputVar,
            <|"L" -> c[[1]], "VGS" -> params["VGS"], "VDS" -> c[[2]],
              "VSB" -> c[[3]]|>]}];
        y = Flatten[{lktDirectLookup[data, outvar,
            <|"L" -> c[[1]], "VGS" -> params["VGS"], "VDS" -> c[[2]],
              "VSB" -> c[[3]]|>]}];
        lktCurveLookup[x, y, targets, inputVar, method]], {c, combinations}],
    First[batch]];
  result = lktSqueeze[ArrayReshape[Flatten[rows], {Length[l], Length[vds],
      Length[vsb], Length[targets]}]];
  If[warning == "on" && !FreeQ[result, Indeterminate],
    Print["lookup warning: ", inputVar, " input out of range (Indeterminate returned)."]];
 result
 ];

(* Multi-output lookup. Mode 3 samples the input ratio and all requested
   output ratios on the same VGS curves before the final 1-D inversion. *)
lookup[data_Association, outvars_List, args___] /;
    And @@ (StringQ /@ outvars) := Module[
  {params, defaults, nonCoordinates, inputVar, targets, l, vds, vsb, vgs,
   combinations, rows, method, warning},
  If[outvars == {}, Return[{}]];
  params = lktParseArgs[{args}];
  If[params === $Failed, Return[$Failed]];
  defaults = <|"L" -> Min[data["L"]], "VGS" -> data["VGS"],
    "VDS" -> Max[data["VDS"]]/2, "VSB" -> 0.,
    "METHOD" -> "pchip", "WARNING" -> "off"|>;
  params = Join[defaults, params];
  nonCoordinates = Complement[Keys[params], Keys[defaults]];
  If[Length[nonCoordinates] == 1,
    inputVar = First[nonCoordinates];
    If[!StringContainsQ[inputVar, "_"] ||
        !And @@ (StringContainsQ[#, "_"] & /@ outvars), Return[$Failed]];
    targets = Flatten[{params[inputVar]}];
    If[targets == {}, Return[ConstantArray[{}, Length[outvars]]]];
    l = Flatten[{params["L"]}]; vds = Flatten[{params["VDS"]}];
    vsb = Flatten[{params["VSB"]}]; vgs = Flatten[{params["VGS"]}];
    combinations = Tuples[{l, vds, vsb}];
    method = lktNormalizeMethod[params["METHOD"]];
    If[method === $Failed, Return[$Failed]];
    warning = ToLowerCase[ToString[params["WARNING"]]];
    rows = lktDirectCrossLookupBatch[data,
      Prepend[outvars, inputVar], combinations, targets, method, vgs];
    If[rows === $Failed,
      rows = lookup[data, #, Sequence @@ {args}] & /@ outvars;
      If[MemberQ[rows, $Failed], Return[$Failed]],
      rows = lktSqueeze /@ (ArrayReshape[Flatten[#],
          {Length[l], Length[vds], Length[vsb], Length[targets]}] & /@ rows)];
    If[warning == "on" && !FreeQ[rows, Indeterminate],
      Print["lookup warning: ", inputVar,
        " input out of range (Indeterminate returned)."]];
    Return[rows]
  ];
  If[nonCoordinates =!= {}, Return[$Failed]];
  lktDirectLookupMulti[data, outvars, params]
 ];

lktLookupVGSOne[data_Association, targetVar_String, targets_List, l_, vds_, vsb_, method_] :=
  Module[{x, vgs = data["VGS"]},
    x = Flatten[{lktDirectLookup[data, targetVar,
        <|"L" -> l, "VGS" -> vgs, "VDS" -> vds, "VSB" -> vsb|>]}];
    lktCurveLookup[x, vgs, targets, targetVar, method]
  ];

(* Evaluate all ordinary lookupVGS bias combinations in one compiled call.
   VGS varies fastest so each returned row is one curve. *)
lktDirectLookupVGSBatch[data_Association, targetVar_String, combinations_List,
    targets_List, method_String] := Module[
  {vgs, rows, targetRows, result},
  If[combinations == {} || targets == {}, Return[{}]];
  vgs = data["VGS"];
  rows = lktValidatedVGSSweepBatch[data, {targetVar}, combinations, vgs];
  If[rows === $Failed, Return[$Failed]];
  rows = First[rows];
  targetRows = If[ArrayDepth[targets] == 2, targets,
    ConstantArray[targets, Length[rows]]];
  If[Length[targetRows] =!= Length[rows] ||
      !SameQ @@ (Length /@ targetRows), Return[$Failed]];
  result = lktCurveLookupBatch[rows, ConstantArray[vgs, Length[rows]],
    targetRows, targetVar, method];
  If[result === $Failed,
    result = MapThread[lktCurveLookup[#1, vgs, #2, targetVar, method] &,
      {rows, targetRows}]];
 result
 ];

(* Sample the inversion variable and all outputs on one set of validated VGS
   curves. The first name is the inversion variable; results cover the rest. *)
lktDirectCrossLookupBatch[data_Association, names_List, combinations_List,
    targets_List, method_String, vgs_List] := Module[
  {rows, targetRows, inputRows, outputRows, result, batch},
  If[Length[names] < 2 || combinations == {} || targets == {}, Return[{}]];
  rows = lktValidatedVGSSweepBatch[data, names, combinations, vgs];
  If[rows === $Failed, Return[$Failed]];
  targetRows = If[ArrayDepth[targets] == 2, targets,
    ConstantArray[targets, Length[rows[[1]]]]];
  If[Length[targetRows] =!= Length[rows[[1]]] ||
      !SameQ @@ (Length /@ targetRows), Return[$Failed]];
  inputRows = rows[[1]];
  outputRows = Rest[rows];
  result = Map[Function[output,
    batch = lktCurveLookupBatch[inputRows, output, targetRows, First[names],
      method];
    If[batch === $Failed,
      MapThread[lktCurveLookup[#1, #2, #3, First[names], method] &,
        {inputRows, output, targetRows}], batch]], outputRows];
  If[MemberQ[result, $Failed], Return[$Failed]];
  result
 ];

lookupVGS[data_Association, args___] := Module[
  {params, method, warning, targetVar, targets, l, vds, vsb, vdb, vgb, rows,
    combinations, result, dimensions},
  params = lktParseArgs[{args}];
  If[params === $Failed, Return[$Failed]];
  method = lktNormalizeMethod[Lookup[params, "METHOD", "pchip"]];
  If[method === $Failed, Return[$Failed]];
  warning = ToLowerCase[ToString[Lookup[params, "WARNING", "off"]]];
  targetVar = Which[KeyExistsQ[params, "ID_W"], "ID_W",
    KeyExistsQ[params, "GM_ID"], "GM_ID", True, Return[$Failed]];
  targets = Flatten[{params[targetVar]}];
  If[targets == {}, Return[{}]];
  l = Flatten[{Lookup[params, "L", Min[data["L"]]]}];

  If[KeyExistsQ[params, "VDB"] || KeyExistsQ[params, "VGB"],
    If[!KeyExistsQ[params, "VDB"] || !KeyExistsQ[params, "VGB"], Return[$Failed]];
    If[Length[l] != 1, Return[$Failed]];
    vdb = params["VDB"]; vgb = params["VGB"];
    If[!NumericQ[vdb] || !NumericQ[vgb], Return[$Failed]];
    result = lktUnknownSourceVGSOne[data, targetVar, {First[l], vdb, vgb},
      targets, method];
    If[result === $Failed, Return[$Failed]];
    result = lktSqueeze[result];
    If[warning == "on" && targetVar == "GM_ID" && !FreeQ[result, Indeterminate],
      Print["lookupVGS: GM_ID input larger than maximum!"]];
    Return[result]
  ];

  vds = Flatten[{Lookup[params, "VDS", Max[data["VDS"]]/2]}];
  vsb = Flatten[{Lookup[params, "VSB", 0.]}];
  combinations = Tuples[{l, vds, vsb}];
  rows = lktDirectLookupVGSBatch[data, targetVar, combinations, targets, method];
  If[rows === $Failed,
    rows = lktLookupVGSOne[data, targetVar, targets, #[[1]], #[[2]], #[[3]],
        method] & /@ combinations];
  dimensions = {Length[l], Length[vds], Length[vsb], Length[targets]};
  result = lktSqueeze[ArrayReshape[Flatten[rows], dimensions]];
  If[warning == "on" && targetVar == "GM_ID" && !FreeQ[result, Indeterminate],
    Print["lookupVGS: GM_ID input larger than maximum!"]];
  result
];

(* 1-D sweep of a variable vs VGS at a fixed (L, VDS, VSB). *)
SliceVGS[data_Association, varKey_String, l_, vds_, vsb_] :=
  Module[{vgs = data["VGS"], values},
    values = lookup[data, varKey, "L", l, "VGS", vgs, "VDS", vds,
      "VSB", vsb];
    If[values === $Failed, Return[$Failed]];
    Transpose[{vgs, Flatten[{values}]}]
  ];

(* Only direct lookup/lookupVGS pure functions are specialized. *)
EnableMapOptimization[];
