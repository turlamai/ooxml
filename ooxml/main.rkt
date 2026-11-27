#lang racket/base
;; ooxml: the package layer of Office Open XML documents.
;;
;;   (require ooxml)
;;   (define parts (read-package "in.docx"))        ; hash: name -> bytes
;;   (hash-set! parts "word/document.xml" new-xml)
;;   (define problems (check-package parts))         ; '() when consistent
;;   (write-package "out.docx" parts)
;;
;; The layer is format-agnostic: it knows zip containers, relationships and
;; content types, nothing about wordprocessingml or drawingml.
(require (file "zip.rkt") (file "rels.rkt") (file "package.rkt"))
(provide (all-from-out (file "zip.rkt") (file "rels.rkt") (file "package.rkt")))
