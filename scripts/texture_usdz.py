#!/usr/bin/env python3
"""Bind the MatterPak texture atlases onto the ModelIO-exported USD and package a
textured USDZ. ModelIO drops OBJ map_Kd textures, so we re-add a UsdUVTexture +
primvar(st) reader to each material and connect it to diffuseColor, then package.

Run from the folder holding house.usdc + the <base>_NNN.jpg atlases:
    scripts/.venv/bin/python scripts/texture_usdz.py <base> <house.usdc> <out.usdz>
Reads only; writes house_final.usdc (temp) and the output usdz.
"""
import sys
from pxr import Usd, UsdShade, Sdf, UsdUtils, UsdGeom

base, src, out = sys.argv[1], sys.argv[2], sys.argv[3]
stage = Usd.Stage.Open(src)
# ModelIO exports metersPerUnit=0.01 (cm) but the coordinates are in metres, which
# makes RealityKit render the house 100x too small. The data is metres -> declare 1.
UsdGeom.SetStageMetersPerUnit(stage, 1.0)
bound = 0
for i in range(20):
    mpath = f"/house/Materials/_{base}_{i:03d}_jpg"
    mat = UsdShade.Material.Get(stage, mpath)
    surf = UsdShade.Shader.Get(stage, mpath + "/surfaceShader")
    if not mat or not surf:
        continue
    st = UsdShade.Shader.Define(stage, mpath + "/stReader")
    st.CreateIdAttr("UsdPrimvarReader_float2")
    st.CreateInput("varname", Sdf.ValueTypeNames.Token).Set("st")
    st_out = st.CreateOutput("result", Sdf.ValueTypeNames.Float2)

    tex = UsdShade.Shader.Define(stage, mpath + "/diffuseTex")
    tex.CreateIdAttr("UsdUVTexture")
    tex.CreateInput("file", Sdf.ValueTypeNames.Asset).Set(f"./{base}_{i:03d}.jpg")
    tex.CreateInput("st", Sdf.ValueTypeNames.Float2).ConnectToSource(st_out)
    tex.CreateInput("sourceColorSpace", Sdf.ValueTypeNames.Token).Set("sRGB")
    tex.CreateInput("wrapS", Sdf.ValueTypeNames.Token).Set("repeat")
    tex.CreateInput("wrapT", Sdf.ValueTypeNames.Token).Set("repeat")
    rgb = tex.CreateOutput("rgb", Sdf.ValueTypeNames.Float3)

    surf.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).ConnectToSource(rgb)
    bound += 1

flat = "house_final.usdc"
stage.GetRootLayer().Export(flat)
ok = UsdUtils.CreateNewUsdzPackage(flat, out)
print(f"bound {bound} materials; packaged={ok} -> {out}")
