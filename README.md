# ooxml — OOXML packages in pure Racket

**English** · [中文](README.zh-CN.md)

[![CI](https://github.com/turlamai/ooxml/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/ooxml/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`ooxml` works with the container layer of **ECMA-376** documents —
`.docx`, `.pptx` and `.xlsx` files: zip archives of XML parts wired
together by relationships. It does not know about WordprocessingML or
DrawingML; it gives you the parts, their relationships, content types
and a validator, and leaves the XML to you.

Everything is implemented in pure Racket: no FFI, no system dependency.
The reader goes through `file/unzip`; the writer produces the same
archive shape as Office and python-pptx/python-docx — no directory
entries, `[Content_Types].xml` first, XML deflated, media stored —
and its output opens in Word, PowerPoint, LibreOffice and .NET's
`ZipFile`.

## Installation

```
raco pkg install ooxml
```

## Usage

```racket
#lang racket/base
(require ooxml)

(define parts (read-package "deck.pptx"))
(check-package parts)                        ; => '() when consistent
(length (package-reachable parts))           ; parts reachable from the root

(define pruned (prune-package parts))        ; drop unreachable parts
(write-package "pruned.pptx"
               (hash-set pruned "[Content_Types].xml"
                         (rebuild-content-types pruned)))
```

### Relationships

A part table is a hash from part name to bytes. Relationships follow
ECMA-376 Part 2: `rels-name` maps a part to its `_rels` file,
`parse-rels` / `rels-xml` convert between XML and `rel` values (with
shorthand symbols such as `'slide` and `'image`), `resolve-target`
does the part-name arithmetic, and `next-rid` hands out free ids.

### Validation

`check-package` returns the faults Office reports only as *file is
corrupt*: malformed XML, missing relationship targets, duplicate ids,
`r:id` references that resolve nowhere, parts without a content type
and a missing `officeDocument` relationship.

## API documentation and development

The [Scribble API reference](ooxml/scribblings/ooxml.scrbl) defines the
part-table model, relationship and content-type contracts, the pruning
and validation rules and the zip layer. Its quickstart uses
`scribble/example` and is evaluated during documentation builds. The
[executable quickstart](ooxml/examples/quickstart.rkt) builds a package
from scratch, validates it and round-trips it through disk.

From the repository root, with Racket and `raco` installed:

```sh
raco pkg install --auto --link "$(pwd)"
raco test -p ooxml
racket ooxml/examples/quickstart.rkt
raco setup --check-pkg-deps -l ooxml
```

These steps are covered by the Linux/macOS/Windows CI matrix. Racket
module path `ooxml` is the public API; nothing needs Office, Python or
a network connection at runtime. For bugs, submit a minimal package
reproducer (no proprietary documents) to
[GitHub Issues](https://github.com/turlamai/ooxml/issues).

## License

[MIT](LICENSE).
