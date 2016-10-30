#lang racket/base

(require "../utils/utils.rkt"
         racket/list racket/match
         (prefix-in c: (contract-req))
         (rep type-rep prop-rep object-rep values-rep rep-utils)
         (only-in (infer infer) intersect)
         compatibility/mlist
         (types union subtype overlap subtract abbrev tc-result))

(provide/cond-contract
  [-and (c:->* () #:rest (c:listof Prop?) Prop?)]
  [-or (c:->* () #:rest (c:listof Prop?) Prop?)]
  [implies-atomic? (c:-> Prop? Prop? boolean?)]
  [negate-prop (c:-> Prop? Prop?)]
  [complementary? (c:-> Prop? Prop? boolean?)]
  [contradictory? (c:-> Prop? Prop? boolean?)]
  [add-unconditional-prop-all-args (c:-> Function? Type? Function?)]
  [add-unconditional-prop (c:-> tc-results/c Prop? tc-results/c)]
  [erase-props (c:-> tc-results/c tc-results/c)]
  [name-ref=? (c:-> name-ref/c name-ref/c boolean?)]
  [reduce-propset/type (c:-> PropSet? Type? PropSet?)]
  [reduce-tc-results/subsumption (c:-> tc-results/c tc-results/c)])

;; reduces a PropSet 'ps' with info from the type 't'
;; so the two are consistent (e.g. if the type is False,
;; its true proposition is -ff, etc)
(define (reduce-propset/type ps t)
  (cond
    [(type-equal? -Bottom t) -ff-propset]
    [(type-equal? -False t) (-PS -ff (PropSet-els ps))]
    [(not (overlap? t -False)) (-PS (PropSet-thn ps) -ff)]
    [else ps]))

;; reduce-tc-result/subsumption
;;
;; tc-result -> tc-result
;;
;; Update the tc-result to incorporate the
;; return type in the proposition (i.e. if it
;; can't be False, then the else prop should be -ff)
(define (reduce-tc-results/subsumption res)
  (define (update-ps t ps obj)
    (cond
      [(Bottom? t) (tc-result t -ff-propset -empty-obj)]
      [else
       (define p+ (if ps (PropSet-thn ps) -tt))
       (define p- (if ps (PropSet-els ps) -tt))
       (define o (if obj obj -empty-obj))
       (cond
         [(or (type-equal? -False t)
              (FalseProp? p+))
          (tc-result (intersect t -False) (-PS -ff p-) o)]
         [(not (overlap? t -False))
          (tc-result t (-PS p+ -ff) o)]
         [(prop-equal? -ff p-) (tc-result (subtract t -False) (-PS p+ -ff) o)]
         [else (tc-result t (-PS p+ p-) o)])]))
  (match res
    [(tc-any-results: _) res]
    [(tc-results: ts pss os)
     (tc-results (map update-ps ts pss os) #f)]
    [(tc-results: ts pss os dt db)
     (tc-results (map update-ps ts pss os) (cons dt db))]
    [_ (error 'reduce-tc-results/subsumption
              "invalid res in subst-tc-results: ~a"
              res)]))


;; contradictory: Prop? Prop? -> boolean?
;; Returns true if the AND of the two props is equivalent to FalseProp
(define (contradictory? p1 p2)
  (match* (p1 p2)
    [((TypeProp: o1 t1) (TypeProp: o2 t2))
     #:when (object-equal? o1 o2)
     (not (overlap? t1 t2))]
    [((TypeProp: o1 t1) (NotTypeProp: o2 t2))
     #:when (object-equal? o1 o2)
     (subtype t1 t2)]
    [((NotTypeProp: o2 t2) (TypeProp: o1 t1))
     #:when (object-equal? o1 o2)
     (subtype t1 t2)]
    [(_ _) (or (prop-equal? p1 -ff)
               (prop-equal? p2 -ff))]))

;; complementary: Prop? Prop? -> boolean?
;; Returns true if the OR of the two props is equivalent to Top
(define (complementary? p1 p2)
  (match* (p1 p2)
    [((TypeProp: o1 t1) (NotTypeProp: o2 t2))
     #:when (object-equal? o1 o2)
     (subtype t2 t1)]
    [((NotTypeProp: o2 t2) (TypeProp: o1 t1))
     #:when (object-equal? o1 o2)
     (subtype t2 t1)]
    [(_ _) (or (prop-equal? p1 -tt)
               (prop-equal? p2 -tt))]))

(define (name-ref=? a b)
  (or (equal? a b)
      (and (identifier? a)
           (identifier? b)
           (free-identifier=? a b))))

;; does p imply q? (but only directly/simply)
(define (implies-atomic? p q)
  (match* (p q)
    ;; reflexivity
    [(_ _) #:when (or (prop-equal? p q)
                      (prop-equal? q -tt)
                      (prop-equal? p -ff)) #t]
    ;; ps ⊆ qs ?
    [((OrProp: ps) (OrProp: qs))
     (and (for/and ([p (in-list ps)])
            (member p qs prop-equal?))
          #t)]
    ;; p ∈ qs ?
    [(p (OrProp: qs)) (and (member p qs prop-equal?) #t)]
    ;; q ∈ ps ?
    [((AndProp: ps) q) (and (member q ps prop-equal?) #t)]
    ;; t1 <: t2 ?
    [((TypeProp: o1 t1)
      (TypeProp: o2 t2))
     #:when (object-equal? o1 o2)
     (subtype t1 t2)]
    ;; t2 <: t1 ?
    [((NotTypeProp: o1 t1) (NotTypeProp: o2 t2))
     #:when (object-equal? o1 o2)
     (subtype t2 t1)]
    ;; t1 ∩ t2 = ∅ ?
    [((TypeProp: o1 t1) (NotTypeProp: o2 t2))
     #:when (object-equal? o1 o2)
     (not (overlap? t1 t2))]
    ;; otherwise we give up
    [(_ _) #f]))

;; intersect-update
;; (mlist (mcons Object Type)) Object Type -> (mlist (mcons Object Type))
;;
;; updates mutable association list 'dict' entry for 'o' w/ type t
;; if no entry for 'o' is found, else if some previous type s is present
;; update the type to t ∩ s
(define (intersect-update dict o t)
  (cond
    [(massq o dict) => (λ (p)
                         (set-mcdr! p (intersect t (mcdr p)))
                         dict)]
    [else (mcons (mcons o t) dict)]))


;; union-update
;; (mlist (mcons Object Type)) Object Type -> (mlist (mcons Object Type))
;;
;; updates mutable association list 'dict' entry for 'o' w/ type t
;; if no entry for 'o' is found, else if some previous type s is present
;; update the type to t ∪ s
(define (union-update dict o t)
  (cond
    [(massq o dict) => (λ (p)
                         (set-mcdr! p (Un t (mcdr p)))
                         dict)]
    [else (mcons (mcons o t) dict)]))


;; compact-or-props : (Listof prop) -> (Listof prop)
;;
;; This combines all the TypeProps at the same path into one TypeProp with Un, and
;; all of the NotTypeProps at the same path into one NotTypeProp with intersect.
;; The Or then simplifies to -tt if any of the atomic props simplified to -tt, and
;; any values of -ff are removed.
(define/cond-contract (compact-or-props props)
  ((c:listof Prop?) . c:-> . (c:listof Prop?))
  
  (define-values (pos neg others)
    (for/fold ([pos '()] [neg '()] [others '()])
              ([prop (in-list props)])
      (match prop
        [(TypeProp: o t)
         (values (union-update pos o t) neg others)]
        [(NotTypeProp: o t)
         (values pos (intersect-update neg o t) others)]
        [_ (values pos neg (cons prop others))])))

  
  (let ([pos (for*/list ([p (in-mlist pos)]
                         [p (in-value (-is-type (mcar p) (mcdr p)))]
                         #:when (not (FalseProp? p)))
               p)]
        [neg (for*/list ([p (in-mlist neg)]
                         [p (in-value (-not-type (mcar p) (mcdr p)))]
                         #:when (not (FalseProp? p)))
               p)])
    (if (or (member -tt pos prop-equal?)
            (member -tt neg prop-equal?))
        (list -tt)
        (append pos neg others))))



;; negate-prop: Prop? -> Prop?
;; Logically inverts a prop.
(define (negate-prop p)
  (match p
    [(? FalseProp?) -tt]
    [(? TrueProp?) -ff]
    [(TypeProp: o t) (-not-type o t)]
    [(NotTypeProp: o t) (-is-type o t)]
    [(AndProp: ps) (apply -or (map negate-prop ps))]
    [(OrProp: ps) (apply -and (map negate-prop ps))]))

;; -or
;; (listof Prop?) -> Prop?
;;
;; Smart 'normalizing' constructor for disjunctions. The result
;; will be a disjunction of only atomic propositions (i.e. a clause
;; in a CNF formula)
(define (-or . args)
  (define (distribute args)
    (define-values (ands others) (partition AndProp? args))
    (match ands
      [(cons (AndProp: elems) ands)
       (apply -and (for/list ([elem (in-list elems)])
                     (apply -or elem (append ands others))))]
      [_ (make-OrProp others)]))
  (let loop ([ps args] [result null])
    (match ps
      [(cons p ps)
       (match p
         [(OrProp: ps*) (loop (append ps* ps) result)]
         [(? FalseProp?) (loop ps result)]
         [_
          (let check-loop ([qs ps])
            (match qs
              [(cons q qs) (cond
                             [(complementary? p q) -tt]
                             [(implies-atomic? p q) (loop ps result)]
                             [else (check-loop qs)])]
              [_ #:when (for/or ([q (in-list result)])
                          (implies-atomic? p q))
                 (loop ps result)]
              [_ (loop ps (cons p result))]))])]
      [_ (distribute (compact-or-props result))])))

;; -and
;; (listof Prop?) -> Prop?
;;
;; Smart 'normalizing' constructor for conjunctions. The result
;; will be a conjunction of only atomic propositions and disjunctions
;; (i.e. a CNF proposition)
(define (-and . args)
  (define-values (pos neg others)
    (let loop ([args args]
               [pos '()]
               [neg '()]
               [others '()])
      (match args
        [(cons arg args)
         (match arg
           [(TypeProp: o t) (loop args (intersect-update pos o t) neg others)]
           [(NotTypeProp: o t) (loop args pos (union-update neg o t) others)]
           [(AndProp: ps)
            (let-values ([(pos neg others) (loop ps pos neg others)])
              (loop args pos neg others))]
           [_ (loop args pos neg (cons arg others))])]
        [_ (values pos neg others)])))
  ;; Move all the type props up front as they are the stronger props
  (let loop ([ps (append (for*/list ([p (in-mlist pos)]
                                     [p (in-value (-is-type (mcar p) (mcdr p)))]
                                     #:when (not (prop-equal? -tt p)))
                           p)
                         (for*/list ([p (in-mlist neg)]
                                     [p (in-value (-not-type (mcar p) (mcdr p)))]
                                     #:when (not (prop-equal? -tt p)))
                           p)
                         others)]
             [result null])
    (match ps
      [(cons p ps)
       (cond
         [(let check-loop ([qs ps])
            (match qs
              [(cons q qs) (cond
                             [(contradictory? p q) -ff]
                             [(implies-atomic? q p) (loop ps result)]
                             [else (check-loop qs)])]
              [_ #f]))]
         [(for/or ([q (in-list result)])
            (implies-atomic? q p))
          (loop ps result)]
         [else (loop ps (cons p result))])]
      [_ (make-AndProp result)])))

;; add-unconditional-prop: tc-results? Prop? -> tc-results?
;; Ands the given proposition to the props in the tc-results.
;; Useful to express properties of the form: if this expressions returns at all, we learn this
(define (add-unconditional-prop results prop)
  (match results
    [(tc-any-results: f) (tc-any-results (-and prop f))]
    [(tc-results: ts (list (PropSet: ps+ ps-) ...) os)
     (ret ts
          (for/list ([f+ (in-list ps+)]
                     [f- (in-list ps-)])
            (-PS (-and prop f+) (-and prop f-)))
          os)]
    [(tc-results: ts (list (PropSet: ps+ ps-) ...) os dty dbound)
     (ret ts
          (for/list ([f+ ps+] [f- ps-])
            (-PS (-and prop f+) (-and prop f-)))
          os
          dty
          dbound)]))


;; ands the given type prop to both sides of the given arr for each argument
;; useful to express properties of the form: if this function returns at all,
;; we learn this about its arguments (like fx primitives, or car/cdr, etc.)
(define (add-unconditional-prop-all-args arr type)
  (match arr
    [(Function: (list (arr: dom rng rest drest kws)))
     (match rng
       [(Values: (list (Result: tp (PropSet: -true-prop -false-prop) op)))
        (let ([new-props (apply -and (build-list (length dom)
                                                   (lambda (i)
                                                     (-is-type i type))))])
          (make-Function
           (list (make-arr
                  dom
                  (make-Values
                   (list (-result tp
                                  (-PS (-and -true-prop new-props)
                                       (-and -false-prop new-props))
                                  op)))
                  rest drest kws))))])]))

;; tc-results/c -> tc-results/c
(define (erase-props tc)
  (match tc
    [(tc-any-results: _) (tc-any-results #f)]
    [(tc-results: ts _ _)
     (define empties (make-list (length ts) #f))
     (ret ts
          empties
          empties)]
    [(tc-results: ts _ _ dty dbound)
     (define empties (make-list (length ts) #f))
     (ret ts
          empties
          empties
          dty dbound)]))