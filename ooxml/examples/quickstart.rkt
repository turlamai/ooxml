#lang racket/base
;; Quick start: build a minimal OOXML package from scratch, validate it,
;; read it back from disk and drop an unreachable part.
;;
;;   racket ooxml/examples/quickstart.rkt

(require ooxml racket/file)

(define (xml-decl body)
  (string->bytes/utf-8 (string-append "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" body)))

;; 1. a part table: part name -> bytes
(define parts
  (hash "[Content_Types].xml"
        (xml-decl (content-types-xml '(("xml" . "application/xml") ("png" . "image/png"))
                                      '(("word/document.xml" . "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"))))
        "_rels/.rels"
        (xml-decl (rels-xml (list (make-rel "rId1" 'officeDocument "word/document.xml"))))
        "word/_rels/document.xml.rels"
        (xml-decl (rels-xml (list (make-rel "rId1" 'image "media/logo.png"))))
        "word/document.xml"
        (xml-decl "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p></w:body></w:document>")
        "word/media/logo.png" #"not-really-a-png"
        "word/media/orphan.png" #"never referenced"))

;; 2. relationships, reachability and pruning
(printf "reachable: ~a\n" (package-reachable parts))
(define pruned (prune-package parts))
(printf "orphan kept after prune: ~a\n" (hash-has-key? pruned "word/media/orphan.png"))

;; 3. validation and a round trip through disk
(printf "problems: ~a\n" (check-package parts))
(define out (make-temporary-file "quickstart~a.docx"))
(write-package out pruned)
(define back (read-package out))
(printf "read back ~a parts, identical: ~a\n" (hash-count back) (equal? back pruned))
(delete-file out)
