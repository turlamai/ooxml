#lang racket/base
;; Package-level operations on an OPC (Open Packaging Conventions) part
;; table: a hash from part name (string) to bytes, as produced by
;; `zip->hash`. Content types, reachability pruning, ordered writing and a
;; consistency checker that catches what Office reports only as "file is
;; corrupt".
(require racket/file racket/list racket/match racket/port racket/string xml
         (file "zip.rkt") (file "rels.rkt"))
(provide part-name?
         read-package
         write-package
         package-reachable
         prune-package
         parse-content-types
         content-types-xml
         content-type-of
         rebuild-content-types
         check-package)

;; Canonical part name: no empty segments, no "." / "..", no backslashes.
(define (part-name? s)
  (and (string? s)
       (or (string=? s "")
           (and (not (string-prefix? s "/"))
                (not (string-contains? s "\\"))
                (not (string-contains? s "//"))
                (not (member "." (string-split s "/")))
                (not (member ".." (string-split s "/")))))))

(define (read-package path) (zip->hash path))

;; Write a part table as a package: [Content_Types].xml first, then the rest
;; sorted by name (a stable order keeps diffable archives diffable). Entries
;; already compressed (images, fonts) are stored, XML is deflated.
(define (write-package out-path parts #:compress [compress default-compress])
  (define names (sort (hash-keys parts) string<?))
  (define ordered (if (hash-has-key? parts "[Content_Types].xml")
                      (cons "[Content_Types].xml" (remove "[Content_Types].xml" names))
                      names))
  (zip-write! out-path (map (lambda (n) (zip-entry n (hash-ref parts n))) ordered)
              #:compress compress))

(define (default-compress name)
  ;; case/memv never matches strings, so compare the extension with member
  (if (member (last (string-split name ".")) '("xml" "rels" "txt"))
      'deflate
      'store))

;; ---------------------------------------------------------------------------
;; Reachability
;; ---------------------------------------------------------------------------

;; Every part reachable from the package root through internal relationships,
;; plus the .rels parts on the way. `parts` may contain unreachable entries;
;; they are simply not listed.
(define (package-reachable parts)
  (define seen (make-hash))
  (let walk ([part ""])
    (unless (hash-has-key? seen part)
      (hash-set! seen part #t)
      (define rname (rels-name part))
      (when (hash-has-key? parts rname)
        (hash-set! seen rname #t)
        (for ([r (in-list (parse-rels (bytes->string/utf-8 (hash-ref parts rname))))])
          (when (eq? (rel-mode r) 'internal)
            (walk (resolve-target part (rel-target r))))))))
  (sort (hash-keys seen) string<?))

;; Drop every part that is not reachable (the equivalent of python-pptx's
;; part GC on save). [Content_Types].xml is kept but not rewritten: call
;; `rebuild-content-types` for that.
(define (prune-package parts)
  (define live (make-hash))
  (for ([p (in-list (package-reachable parts))])
    (when (hash-has-key? parts p) (hash-set! live p (hash-ref parts p))))
  (when (hash-has-key? parts "[Content_Types].xml")
    (hash-set! live "[Content_Types].xml" (hash-ref parts "[Content_Types].xml")))
  live)

;; ---------------------------------------------------------------------------
;; Content types
;; ---------------------------------------------------------------------------

;; `[Content_Types].xml` → (hash 'defaults 'overrides): defaults is an
;; association list (ext . content-type), overrides (part-name-without-slash
;; . content-type), both in document order.
(define (parse-content-types xml)
  (hash
   'defaults
   (for/list ([m (in-list (regexp-match* #px"<Default\\b[^>]*/>" xml))])
     (cons (cadr (regexp-match #px"Extension=\"([^\"]*)\"" m))
           (cadr (regexp-match #px"ContentType=\"([^\"]*)\"" m))))
   'overrides
   (for/list ([m (in-list (regexp-match* #px"<Override\\b[^>]*/>" xml))])
     (define part (cadr (regexp-match #px"PartName=\"([^\"]*)\"" m)))
     (cons (if (string-prefix? part "/") (substring part 1) part)
           (cadr (regexp-match #px"ContentType=\"([^\"]*)\"" m))))))

(define (content-types-xml defaults overrides)
  (string-append
   "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
   "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
   (apply string-append
          (for/list ([d (in-list defaults)])
            (format "<Default Extension=\"~a\" ContentType=\"~a\"/>" (car d) (cdr d))))
   (apply string-append
          (for/list ([o (in-list overrides)])
            (format "<Override PartName=\"/~a\" ContentType=\"~a\"/>" (car o) (cdr o))))
   "</Types>"))

;; Content type of `name` according to a parsed table, or #f. Overrides win
;; over defaults, as the spec requires.
(define (content-type-of ct name)
  (or (for/or ([o (in-list (hash-ref ct 'overrides))]) (and (string=? (car o) name) (cdr o)))
      (let ([ext (last (string-split name "."))])
        (for/or ([d (in-list (hash-ref ct 'defaults))]) (and (string=? (car d) ext) (cdr d))))))

;; Re-derive the content types table so it covers exactly the live parts:
;; defaults for live extensions (original order kept), overrides for live
;; parts. Parts without a declared type are left undeclared, so
;; `check-package` still reports them.
(define (rebuild-content-types parts)
  (define ct (parse-content-types (bytes->string/utf-8 (hash-ref parts "[Content_Types].xml"))))
  (define live (remove "[Content_Types].xml" (hash-keys parts)))
  (define live-exts (remove-duplicates (map (lambda (p) (last (string-split p "."))) live)))
  (define defaults (filter (lambda (d) (member (car d) live-exts)) (hash-ref ct 'defaults)))
  (define overrides (filter (lambda (o) (hash-has-key? parts (car o))) (hash-ref ct 'overrides)))
  (string->bytes/utf-8 (content-types-xml defaults overrides)))

;; ---------------------------------------------------------------------------
;; Consistency check
;; ---------------------------------------------------------------------------

;; Verify a package the way Office does before opening it:
;;   1. every .xml / .rels part is well-formed XML
;;   2. every internal relationship target exists; rIds unique per owner
;;   3. every r:id / r:embed / r:link used in a part resolves via its .rels
;;   4. [Content_Types].xml covers every part
;;   5. the package root has an officeDocument relationship
;; Returns a list of human-readable problems; empty means the package is
;; consistent. The zip container itself is trusted (`zip->hash` would have
;; failed on a broken one).
(define (check-package parts)
  (define errors '())
  (define (err! msg) (set! errors (cons msg errors)))
  (define (xml-part? n) (or (string-suffix? n ".xml") (string-suffix? n ".rels")))

  ;; 1. well-formed XML
  (define docs (make-hash))
  (for ([(name data) (in-hash parts)] #:when (xml-part? name))
    (with-handlers ([exn:fail? (lambda (e) (err! (format "malformed XML in ~a: ~a" name (exn-message e))))])
      (hash-set! docs name (xml->xexpr (document-element (read-xml (open-input-bytes data)))))))

  ;; 2. relationships
  (define rels (make-hash)) ; owner part -> (listof rel?)
  (for ([name (in-list (sort (hash-keys parts) string<?))] #:when (string-suffix? name ".rels"))
    (define owner (with-handlers ([exn:fail? (lambda (e) (err! (format "misplaced relationships part ~a" name)) #f)])
                    (owner-of-rels name)))
    (when owner
      (define entries
        (with-handlers ([exn:fail? (lambda (e) (err! (format "bad relationship in ~a: ~a" name (exn-message e))) '())])
          (parse-rels (bytes->string/utf-8 (hash-ref parts name)))))
      (hash-set! rels owner entries)
      (define ids (rel-ids entries))
      (unless (equal? ids (remove-duplicates ids)) (err! (format "duplicate rIds in ~a" name)))
      (for ([r (in-list entries)] #:when (eq? (rel-mode r) 'internal))
        (define full (resolve-target owner (rel-target r)))
        (unless (hash-has-key? parts full) (err! (format "~a: target missing ~a" name full))))))

  ;; 3. r:id / r:embed / r:link references
  (for ([(name data) (in-hash parts)] #:unless (or (string-suffix? name ".rels") (not (string-suffix? name ".xml"))))
    (define txt (bytes->string/utf-8 data))
    ;; regexp-match* yields whole matches only; pull the attribute value out.
    (define used
      (for/list ([m (in-list (regexp-match* #px"r:(?:id|embed|link)=\"[^\"]+\"" txt))])
        (cadr (regexp-match #px"\"([^\"]+)\"" m))))
    (define have (rel-ids (hash-ref rels name '())))
    (for ([id (in-list used)])
      (unless (member id have) (err! (format "~a: rId ~a not defined in ~a" name id (rels-name name))))))

  ;; 4. content types
  (define ct-part (hash-ref parts "[Content_Types].xml" #f))
  (cond
    [ct-part
     (define ct (parse-content-types (bytes->string/utf-8 ct-part)))
     (for ([name (in-list (sort (hash-keys parts) string<?))]
           #:unless (or (string=? name "[Content_Types].xml") (string-suffix? name ".rels")))
       (unless (content-type-of ct name) (err! (format "no content type for ~a" name))))]
    [else (err! "[Content_Types].xml missing")])

  ;; 5. root relationship
  (unless (for/or ([r (in-list (hash-ref rels "" '()))])
            (string=? (rel-type-uri (rel-type r)) (rel-type-uri 'officeDocument)))
    (err! "no officeDocument relationship in _rels/.rels"))

  (reverse errors))
