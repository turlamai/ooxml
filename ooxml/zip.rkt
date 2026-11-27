#lang racket/base
;; Zip archive layer for OOXML packages. Reading goes through `file/unzip`;
;; writing is done here so that the archive shape matches what Office and
;; python-pptx/python-docx produce: no directory entries, local headers
;; followed by one central directory, [Content_Types].xml first (callers
;; decide the order; the writer just keeps it).
;;
;; Entries can be STORED (method 0) or DEFLATED (method 8). Deflate comes
;; from `file/gzip`: its header (10 bytes with mtime 0 and no name) and
;; trailer (CRC32 + size, 8 bytes) are stripped, leaving the raw deflate
;; stream that the zip format expects.
(require racket/list racket/match racket/port file/unzip file/gzip)
(provide zip->hash
         zip->entries
         zip-write!
         zip-entries->bytes
         deflate
         crc32
         (struct-out zip-entry))

;; One file entry; `name` is the archive path with forward slashes.
(struct zip-entry (name data) #:transparent)

;; Archives are limited to 4 GiB per entry and 65535 entries (no ZIP64);
;; Office documents are far below both.

;; ---------------------------------------------------------------------------
;; Reading
;; ---------------------------------------------------------------------------

;; Every file entry of a zip archive as a hash: name (string) -> bytes.
(define (zip->hash path)
  (define h (make-hash))
  (for ([e (in-list (zip->entries path))])
    (hash-set! h (zip-entry-name e) (zip-entry-data e)))
  h)

;; File entries in archive order (directory entries are skipped).
(define (zip->entries path)
  (define acc '())
  (call-with-input-file path
    (lambda (in)
      (unzip in (lambda (name dir? pin)
                  (unless dir?
                    (set! acc (cons (zip-entry (bytes->string/utf-8 name) (port->bytes pin)) acc)))))))
  (reverse acc))

;; ---------------------------------------------------------------------------
;; Checksum and compression
;; ---------------------------------------------------------------------------

;; CRC-32 (IEEE 802.3) of a byte string, table driven.
(define crc32-table
  (let ([t (make-vector 256)])
    (for ([i (in-range 256)])
      (vector-set! t i
                    (let loop ([k 0] [c i])
                      (if (= k 8) c
                          (loop (+ k 1)
                                (bitwise-xor (arithmetic-shift c -1)
                                             (if (bitwise-bit-set? c 0) #xEDB88320 0)))))))
    t))

(define (crc32 bstr)
  (bitwise-xor
   (for/fold ([c #xFFFFFFFF]) ([b (in-bytes bstr)])
     (bitwise-xor (arithmetic-shift c -8)
                  (vector-ref crc32-table (bitwise-and (bitwise-xor c b) #xFF))))
   #xFFFFFFFF))

;; Raw deflate stream (zlib format, window bits -15) of `data`.
(define (deflate data)
  (define gz (call-with-output-bytes
              (lambda (out) (gzip-through-ports (open-input-bytes data) out #f 0))))
  ;; Fixed 10-byte header when FLG is 0 (no FNAME/FCOMMENT/FEXTRA).
  (unless (zero? (bitwise-and (bytes-ref gz 3) #xFF))
    (error 'deflate "unexpected gzip header flags"))
  (subbytes gz 10 (- (bytes-length gz) 8)))

;; ---------------------------------------------------------------------------
;; Writing
;; ---------------------------------------------------------------------------

;; Write `entries` ((listof zip-entry?) or (listof (list name bytes))) to
;; `out-path`, in the given order. `compress` selects the method per entry:
;; 'deflate for everything, 'store for everything, or a procedure taking the
;; name and returning one of the two symbols.
(define (zip-write! out-path entries #:compress [compress 'deflate])
  (define out (open-output-file out-path #:exists 'truncate))
  (dynamic-wind void
                (lambda () (write-archive out entries compress))
                (lambda () (close-output-port out))))

;; Same as `zip-write!` but returns the archive bytes (handy for tests).
(define (zip-entries->bytes entries #:compress [compress 'deflate])
  (call-with-output-bytes (lambda (out) (write-archive out entries compress))))

(define (write-archive out entries compress)
  (define (u16 v) (write-bytes (integer->integer-bytes v 2 #f #f) out))
  (define (u32 v) (write-bytes (integer->integer-bytes v 4 #f #f) out))
  (define (method-for name)
    (case (if (procedure? compress) (compress name) compress)
      [(deflate) 8]
      [(store) 0]
      [else (error 'zip-write! "unknown compression method: ~a" compress)]))
  (define central
    (for/list ([e (in-list entries)])
      (define-values (name data)
        (if (zip-entry? e) (values (zip-entry-name e) (zip-entry-data e)) (values (first e) (second e))))
      (define nbuf (string->bytes/utf-8 name))
      (define method (method-for name))
      (define payload (if (= method 8) (deflate data) data))
      (define crc (crc32 data))
      (define offset (file-position out))
      (u32 #x04034b50) (u16 20) (u16 0) (u16 method) (u16 0) (u16 0)
      (u32 crc) (u32 (bytes-length payload)) (u32 (bytes-length data))
      (u16 (bytes-length nbuf)) (u16 0)
      (write-bytes nbuf out)
      (write-bytes payload out)
      (list nbuf method (bytes-length payload) (bytes-length data) crc offset)))
  (define cd-start (file-position out))
  (for ([c (in-list central)])
    (match-define (list nbuf method csize size crc offset) c)
    (u32 #x02014b50) (u16 20) (u16 20) (u16 0) (u16 method) (u16 0) (u16 0)
    (u32 crc) (u32 csize) (u32 size) (u16 (bytes-length nbuf)) (u16 0) (u16 0)
    (u16 0) (u16 0) (u32 0) (u32 offset)
    (write-bytes nbuf out))
  (define cd-size (- (file-position out) cd-start))
  (u32 #x06054b50) (u16 0) (u16 0) (u16 (length central)) (u16 (length central))
  (u32 cd-size) (u32 cd-start) (u16 0))
