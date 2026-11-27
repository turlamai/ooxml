# AGENTS.md

OOXML（ECMA-376 / OPC）包层的纯 Racket 实现（MIT）：zip 读写、关系、内容类型、可达性裁剪与一致性校验（MIT）。

## 结构

Multi-collection 包：collection 即 `ooxml/` 子目录，scribblings 声明在 `ooxml/info.rkt`（collection 级）。`zip.rkt` 归档层 → `rels.rkt` 关系 → `package.rkt` 部件表操作，三层单向依赖。

## 常用命令

```bash
raco pkg install --auto --link "$(pwd)"
raco test -p ooxml
```

## 验证与发版

- CI（`ci.yml`）：即上面两条命令 + quickstart + `raco setup --check-pkg-deps`，三平台跑。
- 发版 = tag `v<版本>` + CHANGELOG 同步；catalog 侧为手动提交（pkgd）。
