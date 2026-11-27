# ooxml — OOXML packages in pure Racket

[English](README.md) · **中文**

[![CI](https://github.com/turlamai/ooxml/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/ooxml/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`ooxml` 处理 **ECMA-376** 文档（`.docx`、`.pptx`、`.xlsx`）的容器层：由关系串联起来的 XML 部件组成的 zip 归档。它不解释 WordprocessingML 或 DrawingML，只负责给你部件、关系、内容类型和校验器，XML 由你自己处理。

全部以纯 Racket 实现：无 FFI，无系统依赖。读取走 `file/unzip`；写入器产出与 Office 和 python-pptx/python-docx 相同的归档形态——无目录项、`[Content_Types].xml` 居首、XML 压缩、媒体原样存储——其输出可被 Word、PowerPoint、LibreOffice 和 .NET `ZipFile` 打开。

## 安装

```
raco pkg install ooxml
```

## 用法

```racket
#lang racket/base
(require ooxml)

(define parts (read-package "deck.pptx"))
(check-package parts)                        ; 一致时 => '()
(length (package-reachable parts))           ; 从根可达的部件数

(define pruned (prune-package parts))        ; 丢弃不可达部件
(write-package "pruned.pptx"
               (hash-set pruned "[Content_Types].xml"
                         (rebuild-content-types pruned)))
```

### 关系

部件表是从部件名到字节串的哈希。关系遵循 ECMA-376 第 2 部分：`rels-name` 把部件映射到它的 `_rels` 文件，`parse-rels` / `rels-xml` 在 XML 与 `rel` 值之间转换（支持 `'slide`、`'image` 等简写符号），`resolve-target` 做部件名路径运算，`next-rid` 分配空闲 id。

### 校验

`check-package` 返回那些 Office 只会报“文件已损坏”的缺陷：XML 良构错误、关系目标缺失、id 重复、无法解析的 `r:id` 引用、没有内容类型的部件，以及缺失的 `officeDocument` 关系。

## API 文档与开发

完整的部件表模型、关系与内容类型契约、裁剪与校验规则以及 zip 层请查阅
[Scribble API 文档](ooxml/scribblings/ooxml.scrbl)；文档中的
`scribble/example` 会在构建时真实执行。
[独立入门示例](ooxml/examples/quickstart.rkt)从零构造一个包、校验并经磁盘往返。

安装 Racket 及 `raco` 后，在仓库根目录运行：

```sh
raco pkg install --auto --link "$(pwd)"
raco test -p ooxml
racket ooxml/examples/quickstart.rkt
raco setup --check-pkg-deps -l ooxml
```

CI 在 Linux、macOS、Windows 上检查这些步骤。`ooxml` 是公开的
`require` 模块路径；运行时不需要 Office、Python 或网络。如发现问题，请在
[GitHub Issues](https://github.com/turlamai/ooxml/issues)
提交脱敏的最小包示例，避免上传专有文档。

## 许可证

[MIT](LICENSE)。
