#lang racket/base
;; Unit tests for ooxml. Everything runs on packages assembled in memory; no
;; Office file ships with the repo, so the fixtures are readable here.
(require rackunit racket/file racket/list racket/port racket/string file/unzip
         (file "../zip.rkt") (file "../rels.rkt") (file "../package.rkt"))

(define CT
  (string-append
   "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
   "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
   "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
   "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
   "<Default Extension=\"png\" ContentType=\"image/png\"/>"
   "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
   "</Types>"))

(define ROOT-RELS
  (string-append
   "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
   "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
   "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
   "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
   "</Relationships>"))

(define DOC-RELS
  (string-append
   "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
   "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
   "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
   "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image1.png\"/>"
   "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"https://example.com/\" TargetMode=\"External\"/>"
   "</Relationships>"))

(define DOCUMENT
  "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><w:body><w:p><w:r><w:t>Hi &amp; bye</w:t></w:r><w:hyperlink r:id=\"rId3\"><w:r><w:t>link</w:t></w:r></w:hyperlink></w:p></w:body></w:document>")

(define PNG (bytes #x89 #x50 #x4E #x47 #x0D #x0A #x1A #x0A 1 2 3 4 5 6 7 8))

;; A minimal but complete package.
(define (sample-parts [extra '()])
  (make-hash (append (list (cons "[Content_Types].xml" (string->bytes/utf-8 CT))
                           (cons "_rels/.rels" (string->bytes/utf-8 ROOT-RELS))
                           (cons "word/document.xml" (string->bytes/utf-8 DOCUMENT))
                           (cons "word/_rels/document.xml.rels" (string->bytes/utf-8 DOC-RELS))
                           (cons "word/styles.xml" #"<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"/>")
                           (cons "word/media/image1.png" PNG)
                           (cons "docProps/core.xml" #"<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\"><dc:title xmlns:dc=\"http://purl.org/dc/elements/1.1/\">t</dc:title></cp:coreProperties>"))
                     extra)))

(define (roundtrip parts [compress 'deflate])
  (define tmp (make-temporary-file "ooxml-test-~a"))
  (dynamic-wind
    void
    (lambda ()
      (write-package tmp parts #:compress compress)
      (zip->hash tmp))
    (lambda () (delete-file tmp))))

;; ── zip ──

(check-equal? (crc32 #"") 0)
(check-equal? (crc32 #"123456789") #xCBF43926)           ; the standard check value
(check-equal? (crc32 (make-bytes 1000 65)) (crc32 (make-bytes 1000 65)))

(let ([parts (sample-parts)])
  (for ([m (in-list '(deflate store))])
    (define back (roundtrip parts m))
    (for ([(n v) (in-hash parts)])
      (check-equal? (hash-ref back n #f) v (format "roundtrip (~a) keeps ~a" m n))))
  ;; deflate really compresses the repetitive XML parts
  (define entries (hash-map parts (lambda (k v) (list k v))))
  (define stored (bytes-length (zip-entries->bytes entries #:compress 'store)))
  (define packed (bytes-length (zip-entries->bytes entries #:compress 'deflate)))
  (check-true (< packed stored) "deflate must be smaller than store"))

;; write-package default: text parts deflated, binary parts stored
(let ([parts (sample-parts)])
  (define ordered (sort (hash-keys parts) string<?))
  (define all-stored (bytes-length (zip-entries->bytes (map (lambda (n) (list n (hash-ref parts n))) ordered)
                                                     #:compress 'store)))
  (define tmp (make-temporary-file "ooxml~a.docx"))
  (write-package tmp parts)
  (define default-size (file-size tmp))
  (define back (read-package tmp))
  (delete-file tmp)
  (check-true (< default-size all-stored) "write-package compresses XML by default")
  (check-equal? back parts "write-package/read-package roundtrip"))

;; ── rels ──

(check-equal? (rels-name "") "_rels/.rels")
(check-equal? (rels-name "word/document.xml") "word/_rels/document.xml.rels")
(check-equal? (rels-name "ppt/slides/slide1.xml") "ppt/slides/_rels/slide1.xml.rels")
(check-equal? (owner-of-rels "_rels/.rels") "")
(check-equal? (owner-of-rels "ppt/slides/_rels/slide1.xml.rels") "ppt/slides/slide1.xml")

(check-equal? (resolve-target "ppt/presentation.xml" "slides/slide1.xml") "ppt/slides/slide1.xml")
(check-equal? (resolve-target "ppt/slides/slide1.xml" "../slideLayouts/slideLayout1.xml") "ppt/slideLayouts/slideLayout1.xml")
(check-equal? (resolve-target "word/document.xml" "/word/styles.xml") "word/styles.xml")
(check-equal? (resolve-target "" "word/document.xml") "word/document.xml")
(check-equal? (resolve-target "a/b/c.xml" "./d/../e.xml") "a/b/e.xml")

(define doc-rels (parse-rels DOC-RELS))
(check-equal? (length doc-rels) 3)
(check-equal? (rel-ids doc-rels) '("rId1" "rId2" "rId3"))
(check-equal? (rel-mode (third doc-rels)) 'external)
(check-equal? (rel-mode (first doc-rels)) 'internal)
(check-equal? (rels-xml doc-rels) DOC-RELS "rels roundtrip is byte exact")
(check-equal? (rel-type-uri 'image) "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image")
(check-equal? (rel-type-uri "urn:x") "urn:x")
(check-exn exn:fail? (lambda () (rel-type-uri 'nope)))
(check-equal? (next-rid doc-rels) "rId4")
(check-equal? (next-rid '()) "rId1")
(check-equal? (next-rid (list (make-rel "rId10" 'image "a.png"))) "rId11")
(check-equal? (next-rid (list (make-rel "Id7" 'image "a.png"))) "rId1")

;; ── content types ──

(define ct (parse-content-types CT))
(check-equal? (content-type-of ct "word/document.xml")
              "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml")
(check-equal? (content-type-of ct "word/styles.xml") "application/xml")
(check-equal? (content-type-of ct "word/media/image1.png") "image/png")
(check-false (content-type-of ct "word/media/image1.jpg"))
(check-equal? (content-types-xml (hash-ref ct 'defaults) (hash-ref ct 'overrides)) CT "content types roundtrip")

;; ── reachability / pruning ──

(let ([parts (sample-parts (list (cons "word/media/orphan.png" PNG)
                                 (cons "ppt/orphan.xml" #"<x/>")))])
  (check-not-false (member "word/media/image1.png" (package-reachable parts)) "image reachable")
  (check-false (member "word/media/orphan.png" (package-reachable parts)))
  (check-false (member "ppt/orphan.xml" (package-reachable parts)))
  (define pruned (prune-package parts))
  (check-false (hash-has-key? pruned "word/media/orphan.png"))
  (check-false (hash-has-key? pruned "ppt/orphan.xml"))
  (check-true (hash-has-key? pruned "word/_rels/document.xml.rels"))
  (check-equal? (hash-count pruned) 7)
  (define new-ct (bytes->string/utf-8 (rebuild-content-types pruned)))
  (check-true (string-contains? new-ct "Extension=\"png\"") "png is still used by image1")
  ;; dropping the image relationship makes the png default unused
  (define no-image (sample-parts))
  (hash-set! no-image "word/_rels/document.xml.rels"
             (string->bytes/utf-8 (string-replace DOC-RELS "Target=\"media/image1.png\"" "Target=\"media/image2.png\"")))
  (define pruned-no-image (prune-package no-image))
  (check-false (hash-has-key? pruned-no-image "word/media/image1.png") "unreferenced image pruned")
  (define no-png (bytes->string/utf-8 (rebuild-content-types pruned-no-image)))
  (check-false (string-contains? no-png "Extension=\"png\"") "unused default dropped")
  (check-true (string-contains? no-png "Extension=\"xml\"") "used default kept"))

;; ── check-package ──

(check-equal? (check-package (sample-parts)) '())
(check-equal? (check-package (roundtrip (sample-parts))) '() "written package passes")

(let ([parts (sample-parts)])
  (hash-set! parts "word/document.xml" #"<w:document><w:p>")          ; malformed
  (check-true (ormap (lambda (p) (string-contains? p "word/document.xml")) (check-package parts))
              "malformed XML reported"))

(let ([parts (sample-parts)])
  (hash-remove! parts "word/styles.xml")                               ; missing target
  (hash-set! parts "word/document.xml"                                 ; dangling r:id
             (string->bytes/utf-8 (string-replace DOCUMENT "rId3" "rId9")))
  (define problems (check-package parts))
  (check-true (ormap (lambda (p) (string-contains? p "target missing word/styles.xml")) problems))
  (check-true (ormap (lambda (p) (string-contains? p "rId rId9 not defined")) problems)))

(let ([parts (sample-parts)])
  (hash-remove! parts "[Content_Types].xml")
  (check-not-false (member "[Content_Types].xml missing" (check-package parts)) "CT missing reported"))

(let ([parts (sample-parts (list (cons "word/media/pic.jpg" #"x")))])
  (check-true (ormap (lambda (p) (string-contains? p "no content type for word/media/pic.jpg"))
                     (check-package parts))
            "unreachable parts still need a content type"))

(let ([parts (sample-parts)])
  (hash-set! parts "_rels/.rels"
             (string->bytes/utf-8 (string-replace ROOT-RELS "officeDocument" "thumbnail")))
  (check-not-false (member "no officeDocument relationship in _rels/.rels" (check-package parts))
                   "missing officeDocument reported"))

(let ([parts (sample-parts)])
  (hash-set! parts "word/_rels/document.xml.rels" (string->bytes/utf-8 (string-replace DOC-RELS "rId2" "rId1")))
  (check-true (ormap (lambda (p) (string-prefix? p "duplicate rIds")) (check-package parts))))
