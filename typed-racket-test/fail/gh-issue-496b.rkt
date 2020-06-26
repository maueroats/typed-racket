#;
(exn-pred #rx"Type Checker: could not apply function.*\n.*wrong number of arguments provided")
#lang typed/racket

; max should not accept 0 arguments
(max)
