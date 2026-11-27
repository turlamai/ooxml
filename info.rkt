#lang info

(define version "0.1")
;; Multi-collection package shape: the collection is the `ooxml/` subdirectory.
(define collection 'multi)
(define deps '("base" "rackunit-lib"))
(define build-deps '("base" "scribble-lib" "racket-doc" "rackunit-lib"))
(define pkg-desc "Pure-Racket OOXML (OPC) package layer: zip reader/writer with deflate, relationships, content types, reachability pruning and a package consistency checker for .docx/.xlsx/.pptx")
(define pkg-authors '("turlamai"))
(define license 'MIT)
(define test-omit-paths '("ooxml/scribblings"))
