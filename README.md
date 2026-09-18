# to HEIF

一个 macOS 工具：把「照片」图库里的 JPEG / PNG 转成 HEIF，保留 HDR 增益图，
校验通过后再让你决定是否删除原图。

```bash
./build-app.sh      # 构建 build.noindex/to HEIF.app
./package-dmg.sh    # 连带打出可分发的 DMG
```

需要 macOS 15+ 和完整的 Xcode（SDK 里要有 `kCGImageAuxiliaryDataTypeISOGainMap`）。

## 结构

| 路径 | 作用 |
|---|---|
| `Sources/ConversionKit/` | 转换核心：格式嗅探、转码、校验、像素比对 |
| `Sources/heifconv/` | 命令行工具，用于诊断与实测 |
| `App/Sources/` | SwiftUI 界面与 PhotoKit 管线 |
| `Tools/makeicon.swift` | 从 `App/Resources/logo.png` 生成 iconset |

命令行工具带几个实测用的子命令：`inspect`、`sweep`（质量-体积曲线）、
`diff`（逐像素 PSNR）、`generations`（多代转换的累积损失）。

## 几个踩过坑的决定

**不用 `CGImageSourceGetType` 判断格式。** 它在带增益图的 JPEG 上，一旦
ImageIO 深度解析过文件就会改口返回 `public.heic`。改成自己嗅探文件头。

**转码走 ImageIO 而不是 CoreImage。** `CIContext.writeHEIFRepresentation`
配合 `.hdrImage` 会让 CoreImage **重新推导**一张增益图，实测比原图亮 2%、
饱和度低 1.7 个点。改用 `CGImageDestinationAddImageFromSource` 配合
`kCGImageDestinationPreserveGainMap`，原样搬运，误差回到 0.01 个点以内，
顺带保住了 EXIF、GPS、方向标记和透明通道。

**HDR 角标分两条路探测。** HEIF 看 `ftyp` box 里有没有 `tmap` 品牌（只需读
4KB）；JPEG 搜文件头 512KB 内的 XMP 标记。Photos 数据库里的 `isHDR` /
`hdrGain` 只对 HEIF 生效，靠不住。搜索直接在字节上做——先转成 String 再搜
实测要 9ms，字节搜索只要 0.02ms。

**预览按显示器能力切换渲染路径。** 不支持 EDR 的屏幕上不做 HDR 展开，否则
高光会被硬裁成纯白。判据用 `maximumPotentialExtendedDynamicRange...`，因为
`maximum...`（当前值）在支持的屏幕上没有 HDR 内容时也是 1.0。

**删除前必须过校验。** 尺寸（含方向转置与缩放后的预期值）、增益图、EXIF、
GPS 逐项确认，任一不符就不进删除列表。删除走「最近删除」，30 天可恢复。
