#lang typed/racket

(: test-reverse : (List* Integer (Listof Integer)) -> (List* Integer (Listof Integer)))
(define (test-reverse xs)
  (reverse xs))

; will not typecheck if reverse does not preserve nonempty lists
