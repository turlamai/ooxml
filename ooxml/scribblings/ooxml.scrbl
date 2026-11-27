#lang scribble/manual
@(require (for-label racket/base
                     racket/contract
                     ooxml)
          scribble/example)

@(define ooxml-eval (make-base-eval #:lang 'racket/base '(require ooxml)))

@title[#:tag "ooxml"]{ooxml: OOXML packages}
@author{turinglambdaai}

@defmodule[ooxml]

The @filepath{ooxml} package works with the container layer of
@hyperlink["https://www.ecma-international.org/publications-and-standards/standards/ecma-376/"]{ECMA-376}
documents — @tt{.docx}, @tt{.pptx} and @tt{.xlsx} files, which are zip
archives of XML parts wired together by @deftech{relationships}.  It does
not know about WordprocessingML or DrawingML; it gives you the parts,
their relationships, content types and a validator, and leaves the XML
to you.

Everything is implemented in pure Racket: no FFI, no system dependency.

@section{Quick start}

@examples[
#:eval ooxml-eval
(define parts
  (hash "[Content_Types].xml"
        (string->bytes/utf-8
         (content-types-xml '(("rels" . "application/vnd.openxmlformats-package.relationships+xml")
                              ("xml" . "application/xml"))
                            '(("word/document.xml" . "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"))))
        "_rels/.rels"
        (string->bytes/utf-8 (rels-xml (list (make-rel "rId1" 'officeDocument "word/document.xml"))))
        "word/document.xml" #"<w:document/>"
        "word/media/orphan.png" #"..."))
(package-reachable parts)
(check-package parts)
]

@margin-note{Parts are kept in a plain hash so that they stay
inspectable; @racket[read-package] produces one straight from a file.}

@section{Package operations}

A @deftech{part table} is a @racket[hash?] from part name
(@racket[string?]) to @racket[bytes?].  Part names are
@litchar{/}-separated, have no leading slash, and name the package root
@racket[""].

@defproc[(part-name? [v any/c]) boolean?]{
 Whether @racket[v] is a canonical part name (or the root
 @racket[""]): no empty segments, no @litchar{.} or @litchar{..}, no
 backslashes.
}

@defproc[(read-package [path path-string?]) (hash/c string? bytes?)]{
 Reads every file entry of the archive at @racket[path].  Directory
 entries are skipped.  Raises @racket[exn:fail] on a broken container.
}

@defproc[(write-package [out-path path-string?]
                        [parts (hash/c string? bytes?)]
                        [#:compress compress (or/c 'deflate 'store (-> string? (or/c 'deflate 'store)))
                                  default-compress])
         void?]{
 Writes @racket[parts] as an archive: @tt{[Content_Types].xml} first,
 the rest sorted by name, so that diffable packages stay diffable.
 @racket[compress] picks the method per part; the default deflates
 @tt{.xml}, @tt{.rels} and @tt{.txt} and stores everything else (images
 and fonts are already compressed).
}

@section{Relationships}

Relationships follow ECMA-376 Part 2, §9.  The relationships of a part
live in a @tt{_rels} directory next to it: @racket["word/document.xml"]
owns @racket["word/_rels/document.xml.rels"], and the package root
@racket[""] owns @racket["_rels/.rels"].

@defstruct*[rel ([id string?] [type (or/c symbol? string?)] [target string?] [mode (or/c 'internal 'external)])]{
 One relationship.  @racket[type] is either a shorthand symbol
 (@racket['officeDocument], @racket['slide], @racket['image],
 @racket['hyperlink], ...) or a full type URI; @racket[mode] is
 @racket['external] for targets that are URIs.
}

@defproc[(make-rel [id string?] [type (or/c symbol? string?)] [target string?] [mode (or/c 'internal 'external) 'internal]) rel?]{
 Constructor with @racket['internal] as the default mode.
}

@defproc[(rel-type-uri [type (or/c symbol? string?)]) string?]{
 The URI of a shorthand symbol; a string is returned verbatim.
}

@defproc[(rels-name [part string?]) string?]{
 The part name of the relationships file owned by @racket[part].
}

@defproc[(owner-of-rels [rels-part string?]) string?]{
 The inverse of @racket[rels-name].
}

@defproc[(parse-rels [xml string?]) (listof rel?)]{
 Parses the @tt{<Relationship …/>} elements of a relationships part, in
 document order.
}

@defproc[(rels-xml [rels (listof rel?)]) string?]{
 Renders the XML of a relationships part.
}

@defproc[(resolve-target [from-part string?] [target string?]) string?]{
 Resolves @racket[target] against the directory of @racket[from-part],
 applying @litchar{.} and @litchar{..}; a target starting with
 @litchar{/} is absolute.
}

@defproc[(next-rid [rels (listof rel?)] [prefix string? "rId"]) string?]{
 The first free @tt{rId}@math{N}, numbering from 1.
}

@defproc[(rel-ids [rels (listof rel?)]) (listof string?)]{
 The ids of @racket[rels], in order.
}

@section{Reachability and content types}

@defproc[(package-reachable [parts (hash/c string? bytes?)]) (listof string?)]{
 Every part reachable from the package root through internal
 relationships, plus the relationships parts on the way, sorted.
}

@defproc[(prune-package [parts (hash/c string? bytes?)]) (hash/c string? bytes?)]{
 Drops every part that @racket[package-reachable] does not list — the
 equivalent of python-pptx's part GC on save.  @tt{[Content_Types].xml}
 is kept as-is; call @racket[rebuild-content-types] to match it.
}

@defproc[(parse-content-types [xml string?])
         (hash/c symbol? (listof (cons/c string? string?)))]{
 Parses @tt{[Content_Types].xml} into @racket['defaults] (extension
 to content type) and @racket['overrides] (part name to content type),
 both in document order.  Override part names lose their leading slash.
}

@defproc[(content-types-xml [defaults (listof (cons/c string? string?))]
                            [overrides (listof (cons/c string? string?))])
         string?]{
 Renders @tt{[Content_Types].xml}; a round trip through
 @racket[parse-content-types] reproduces the input.
}

@defproc[(content-type-of [ct (hash/c symbol? (listof (cons/c string? string?)))]
                          [name string?])
         (or/c string? #f)]{
 The content type of @racket[name]; overrides win over defaults.
}

@defproc[(rebuild-content-types [parts (hash/c string? bytes?)]) bytes?]{
 Re-derives @tt{[Content_Types].xml} from @racket[parts]: defaults for
 the extensions still present, overrides for the parts still present.
 Parts without a declared type stay undeclared.
}

@section{Validation}

@defproc[(check-package [parts (hash/c string? bytes?)]) (listof string?)]{
 Returns the problems of a package, in a stable order; @racket['()]
 means it is consistent.  Checked: every @tt{.xml} / @tt{.rels} part is
 well-formed; every internal relationship target exists and ids are
 unique per owner; every @tt{r:id}, @tt{r:embed} and @tt{r:link} used
 in a part is defined in its relationships; @tt{[Content_Types].xml}
 covers every part; the root has an @racket['officeDocument]
 relationship.  These are the faults Office reports only as
 ``file is corrupt''.
}

@section{Zip layer}

@defstruct*[zip-entry ([name string?] [data bytes?])]{
 One archive entry.
}

@defproc[(zip->hash [path path-string?]) (hash/c string? bytes?)]{
 Every file entry of an archive as a hash.
}

@defproc[(zip->entries [path path-string?]) (listof zip-entry?)]{
 Every file entry in archive order.
}

@defproc[(zip-write! [out-path path-string?]
                     [entries (listof (or/c zip-entry? (list/c string? bytes?)))]
                     [#:compress compress (or/c 'deflate 'store (-> string? (or/c 'deflate 'store))) 'deflate])
         void?]{
 Writes @racket[entries] in the given order.  No directory entries,
 no ZIP64.
}

@defproc[(zip-entries->bytes [entries (listof (or/c zip-entry? (list/c string? bytes?)))]
                             [#:compress compress (or/c 'deflate 'store (-> string? (or/c 'deflate 'store))) 'deflate])
         bytes?]{
 Like @racket[zip-write!] but returns the archive.
}

@defproc[(deflate [data bytes?]) bytes?]{
 A raw deflate stream of @racket[data].
}

@defproc[(crc32 [data bytes?]) exact-nonnegative-integer?]{
 The CRC-32 of @racket[data] (IEEE 802.3, the zip check value).
}

@section{License}

MIT.
