#;
(exn-pred #rx"Type Checker: could not apply function.*\n.*wrong number of arguments provided")
#lang typed/racket

; min should not accept 0 arguments
(min)
