#lang racket/base
;; Relationships (ECMA-376 Part 2, §9) and OPC part-name arithmetic.
;;
;; A package part is addressed by its part name: a "/"-separated path without
;; a leading slash inside the API ("/" is the package root, written "").
;; Relationships live in a `_rels` directory next to their owner part.
(require racket/list racket/string)
(provide (struct-out rel)
         make-rel
         rel-type-uri
         rels-name
         owner-of-rels
         parse-rels
         rels-xml
         resolve-target
         next-rid
         rel-ids)

;; One relationship. `mode` is 'internal (the default) or 'external; external
;; targets are URIs kept verbatim and never resolved against the owner.
(struct rel (id type target mode) #:transparent)

(define (make-rel id type target [mode 'internal]) (rel id type target mode))

;; Shorthands for the relationship types an Office package uses.
(define rel-type->uri
  (hash 'officeDocument   "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
        'metadata         "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
        'extendedProperties "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties"
        'thumbnail        "http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail"
        'slideLayout      "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout"
        'slideMaster      "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster"
        'slide            "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"
        'notesMaster      "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster"
        'notesSlide       "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide"
        'theme            "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme"
        'image            "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
        'font             "http://schemas.openxmlformats.org/officeDocument/2006/relationships/font"
        'hyperlink        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
        'styles           "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
        'numbering        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering"
        'settings         "http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings"
        'webSettings      "http://schemas.openxmlformats.org/officeDocument/2006/relationships/webSettings"
        'footnotes        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes"
        'endnotes         "http://schemas.openxmlformats.org/officeDocument/2006/relationships/endnotes"
        'header           "http://schemas.openxmlformats.org/officeDocument/2006/relationships/header"
        'footer           "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer"
        'worksheet        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
        'sharedStrings    "http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"
        'table            "http://schemas.openxmlformats.org/officeDocument/2006/relationships/table"
        'chart            "http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart"
        'customXml        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXml"
        'presProps        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/presProps"
        'viewProps        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/viewProps"
        'tableStyles      "http://schemas.openxmlformats.org/officeDocument/2006/relationships/tableStyles"))

;; A type is either a symbol from the table above or a full URI (kept
;; verbatim).
(define (rel-type-uri t) (if (symbol? t) (hash-ref rel-type->uri t (lambda () (error 'rel-type-uri "unknown relationship type: ~a" t))) t))

;; Part name of the .rels file owning relationships for `part`.
(define (rels-name part)
  (if (string=? part "") "_rels/.rels"
      (let ([segs (string-split part "/")])
        (string-append (string-join (drop-right segs 1) "/") "/_rels/" (last segs) ".rels"))))

;; Inverse of `rels-name`: the part a .rels file belongs to.
(define (owner-of-rels rels-part)
  (cond [(string=? rels-part "_rels/.rels") ""]
        [(regexp-match #rx"^(.*)/_rels/([^/]+)\\.rels$" rels-part)
         => (lambda (m) (string-append (cadr m) "/" (caddr m)))]
        [else (error 'owner-of-rels "not a relationships part name: ~a" rels-part)]))

;; Parse the <Relationship …/> elements of a .rels part into rel values, in
;; document order.
(define (parse-rels xml)
  (define (attr k m)
    (define hit (regexp-match (pregexp (format "~a=\"([^\"]*)\"" k)) m))
    (and hit (cadr hit)))
  (for/list ([m (in-list (regexp-match* #px"<Relationship\\b[^>]*/>" xml))])
    (define (required k)
      (or (attr k m) (error 'parse-rels "relationship without ~a: ~a" k m)))
    (rel (required "Id") (required "Type") (required "Target")
         (if (equal? (attr "TargetMode" m) "External") 'external 'internal))))

(define (xml-attr-escape s)
  (regexp-replace* #px"[&<>\"']" s
                   (lambda (m) (hash-ref (hash "&" "&amp;" "<" "&lt;" ">" "&gt;" "\"" "&quot;" "'" "&apos;") m))))

;; Render a list of rel values as the XML of a .rels part.
(define (rels-xml rels)
  (string-append
   "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
   "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
   (apply string-append
          (for/list ([r (in-list rels)])
            (format "<Relationship Id=\"~a\" Type=\"~a\" Target=\"~a\"~a/>"
                    (xml-attr-escape (rel-id r))
                    (xml-attr-escape (rel-type-uri (rel-type r)))
                    (xml-attr-escape (rel-target r))
                    (if (eq? (rel-mode r) 'external) " TargetMode=\"External\"" ""))))
   "</Relationships>"))

;; Resolve `target` (relative, or absolute when it starts with "/") against
;; the directory of `from-part`. Pure string arithmetic: `simplify-path`
;; would anchor a relative path in the current directory.
(define (resolve-target from-part target)
  (if (string-prefix? target "/")
      (substring target 1)
      (let norm ([segs (append (if (string=? from-part "") '() (drop-right (string-split from-part "/") 1))
                               (string-split target "/"))]
                 [acc '()])
        (cond [(null? segs) (string-join (reverse acc) "/")]
              [(string=? (first segs) "..") (norm (rest segs) (if (null? acc) acc (rest acc)))]
              [(string=? (first segs) ".") (norm (rest segs) acc)]
              [else (norm (rest segs) (cons (first segs) acc))]))))

(define (rel-ids rels) (map rel-id rels))

;; Highest rId number in use, ignoring ids that are not `prefix<N>`.
(define (max-rid-num rels [prefix "rId"])
  (for/fold ([m 0]) ([r (in-list rels)])
    (define id (rel-id r))
    (max m (or (and (string-prefix? id prefix)
                    (string->number (substring id (string-length prefix))))
               0))))

;; The first free "rIdN" (N from 1) for a list of rel values.
(define (next-rid rels [prefix "rId"])
  (format "~a~a" prefix (add1 (max-rid-num rels prefix))))
