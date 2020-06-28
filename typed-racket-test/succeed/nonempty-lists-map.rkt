#lang typed/racket

(: test-map : (List* Integer (Listof Integer)) -> (List* Integer (Listof Integer)))
(define (test-map xs)
  (map add1 xs))

; will not typecheck if map does not preserve nonempty lists
