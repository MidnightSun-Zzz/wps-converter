# 内置字体

镜像内 `FangSong_GB2312`、`KaiTi_GB2312`、`FZXiaoBiaoSong-B05S` 优先用于对应
公文标准字体名，朱雀仿宋仅作为仿宋兜底。OFD 内嵌字体始终优先。

> 除朱雀仿宋外，以下字体由使用方提供，仓库未声明其再分发许可。部署或分发镜像前，
> 请确认已取得字体权利人的授权；如无授权，请删除对应文件并恢复使用开源替代字体。

## ZhuqueFangsong-Regular.ttf

- 字体：朱雀仿宋 / Zhuque Fangsong
- 版本：v0.212
- 来源：<https://github.com/TrionesType/zhuque/releases/tag/v0.212>
- SHA256：`558c62730844fe54ba220146ed62f859d4e2880188d92d985f8921c6e3743bc4`
- 许可：SIL Open Font License 1.1，见 `OFL-ZhuqueFangsong.txt`

## 仿宋_GB2312.ttf

- 字体族：`FangSong_GB2312`
- SHA256：`fef7cf991b458cabd184b73378918d9d15429010e1d6c804f08d394395c3c3b4`
- 用途：`仿宋`、`仿宋_GB2312`、`FangSong` 的优先字体

## 楷体_GB2312.ttf

- 字体族：`KaiTi_GB2312`
- SHA256：`99092cbb0df301625f46509e85854db8685556551742097ab3fbbc2e2ca0778b`
- 用途：`楷体`、`楷体_GB2312`、`KaiTi`、`FZKai` 的优先字体

## 方正小标宋简体.TTF

- 字体族：`FZXiaoBiaoSong-B05S`
- SHA256：`2322dbfb4fe3b51e5f530c0ee668a7d83df20c0fd8b1aa113a0a9e7ee45d45f3`
- 用途：`方正小标宋简体`、`FZXiaoBiaoSong` 的优先字体

构建时 Dockerfile 会校验以上 SHA256；更新字体文件时请同步更新本文件和校验值。
