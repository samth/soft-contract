#lang typed/racket
(require "utils.rkt")
(provide (all-defined-out))

(define-type Sym^3 (List Sym Sym Sym))

;; prefixing types with dots just so i can use 1-letter variables without shadowing them

;; program and module
(struct: .p ([modules : .m*] [main : .e]) #:transparent)
(struct: .m ([order : (Listof Sym)] [defs : (Map Sym (Pairof .e (U #f .e)))]) #:transparent)
(struct: .m* ([order : (Listof Sym)] [modules : (Map Sym .m)]) #:transparent)

;; expression
(define-data (.e)
  (subset: (.v)
    (.λ [arity : Int] [body : .e] [var? : Bool])    
    (.•)
    (subset: (.prim)
      (.b [unboxed : (U Num Bool String Sym)])
      (subset: (.o)
        (subset: (.o1)
          (subset: (.pred)
            (.st-p [tag : Sym] [arity : Int])
            (.num?) (.real?) (.int?) (.true?) (.false?) (.bool?) (.str?) (.symbol?) (.proc?))
          (.st-ac [tag : Sym] [arity : Int] [index : Int])
          (.add1) (.sub1) (.str-len) (.sqrt))
        (subset: (.o2)
          (.equal?) (.=) (.>) (.<) (.≥) (.≤) (.+) (.-) (.*) (./)
          (.arity=?) (.arity≥?) (.arity-includes?))
        (.st-mk [tag : Sym] [arity : Int]))))
  (.x [sd : Int]) ; static distance
  (.ref [name : Sym] [in : Sym] [ctx : Sym])
  (.@ [f : .e] [xs : (Listof .e)] [ctx : Sym])
  (.@-havoc [x : .x]) ; hack for havoc
  #;(.apply [f : .e] [xs : .e] [ctx : Sym])
  (.if [i : .e] [t : .e] [e : .e])
  (.amb [e* : (Setof .e)])
  ; contract stuff
  (.μ/c [x : Sym] [c : .e])
  (.λ/c [xs : (Listof .e)] [cy : .e] [var? : Bool])
  (.x/c [x : Sym])
  (.struct/c [tag : Sym] [fields : (Listof .e)])
  #;(.and/c [l : .e] [r : .e])
  #;(.or/c [l : .e] [r : .e])
  #;(.¬/c [c : .e]))

(: FV : (case→ [.e → (Setof Int)]
               [.e Int → (Setof Int)]))
(define (FV e [d 0])
  (match e
    [(.x sd) (if (>= sd d) {set (- sd d)} ∅)]
    [(.λ n e _) (FV e (+ d n))]
    [(.@ f xs _) (for/fold ([FVs (FV f d)]) ([x xs])
                   (set-union FVs (FV x d)))]
    [(.@-havoc x) (FV x d)]
    #;[(.apply f xs _) (set-union (FV f d) (FV xs d))]
    [(.if e e1 e2) (set-union (FV e d) (FV e1 d) (FV e2 d))]
    [(.amb e*) (for/fold: ([FVs : (Setof Int) ∅]) ([e e*])
                 (set-union FVs (FV e d)))]
    [(.μ/c _ e) (FV e d)]
    [(.λ/c cx cy _) (for/fold ([FVs (FV cy (+ d (length cx)))]) ([c cx])
                      (set-union FVs (FV c d)))]
    [(.struct/c _ cs) (for/fold: ([FVs : (Setof Int) ∅]) ([c cs])
                        (set-union FVs (FV c d)))]
    [_ ∅]))

(: closed? : .e → Bool)
(define (closed? e) (set-empty? (FV e)))

(: checks# : (Rec X (U .e .p .m (Listof X))) → Int)
(define checks#
  (match-lambda
    [(? list? es) (for/sum ([e es]) (checks# e))]
    [(.p (.m* _ ms) e) (+ (ann (for/sum ([(l mi) (in-hash ms)]
                                         #:unless (equal? l '☠))
                                 (checks# mi)) Int)
                          (checks# e))]
    [(.m _ defs) (for/sum ([(l d) (in-hash defs)])
                   (match-let ([(cons e c) d])
                     (+ (checks# e) (match c [(? .e? c) (checks# c)] [_ 0]))))]
    [(.λ _ e _) (checks# e)]
    [(.@ f xs _) (+ 1 (checks# f) (checks# xs))]
    [(.@-havoc x) 1]
    #;[(.apply f xs _) (+ 1 (checks# f) (checks# xs))]
    [(.if e e1 e2) (+ (checks# e) (checks# e1) (checks# e2))]
    [(.amb e*) (for/sum ([e e*]) (checks# e))]
    [(.μ/c _ e) (checks# e)]
    [(.λ/c cx cy _) (+ (checks# cx) (checks# cy))]
    [(.struct/c _ cs) (checks# cs)]
    [(.pred) 0]
    [(.o) 1] ; FIXME: depends on arity
    [_ 0]))

;; frequently used constants
(define • (.•))
(define .tt (.b #t))
(define .ff (.b #f))
(define .any/c (.λ 1 .tt #f))
(define .none/c (.λ 1 .ff #f))
(define .empty/c (.st-p 'empty 0))
(define .false/c (.false?))
(define .bool/c (.bool?))
(define .car (.st-ac 'cons 2 0))
(define .cdr (.st-ac 'cons 2 1))
(define .zero (.b 0))
(define .one (.b 1))

(: .cons/c : .e .e → .e)
(define (.cons/c c d) (.struct/c 'cons (list c d)))

(:* [.or/c .and/c] : Sym (Listof .e) → .e)
(define (.or/c l e*)
  (match e*
    ['() .none/c]
    [(list c) c]
    [(cons c cr) (.@ (.st-mk 'or/c 2) (list c (.or/c l cr)) l)]))
(define (.and/c l e*)
  (match e*
    ['() .any/c]
    [(list c ) c]
    [(cons c cr) (.@ (.st-mk 'and/c 2) (list c (.and/c l cr)) l)]))
(: .not/c : Sym .e → .e)
(define (.not/c l c)
  (.@ (.st-mk '¬/c 1) (list c) l))

(: prim : (U Sym Num String Bool) → (U #f .e))
(define prim
  (memoize
   #:eq? #t
   (match-lambda
     ['add1 (.add1)] ['sub1 (.sub1)] ['sqrt (.sqrt)] ['+ (.+)] ['- (.-)] ['* (.*)] ['/ (./)]
     ['str-len (.str-len)]
     ['num? (.num?)] ['real? (.real?)] ['int? (.int?)]
     ['true? (.true?)] [(or 'false? 'not) (.false?)] ['bool? (.bool?)]
     ['str? (.str?)] ['symbol? (.symbol?)] ['proc? (.proc?)]     
     ['equal? (.equal?)]
     [(or 'any 'any/c) .any/c]
     [(or 'none 'none/c) .none/c]
     ['= (.=)]
     ['< (.<)]
     ['> (.>)]
     [(or '>= '≥) (.≥)]
     [(or '<= '≤) (.≤)]
     ['arity=? (.arity=?)]
     [(or 'arity>=? 'arity≥?) (.arity≥?)]
     ['arity-includes? (.arity-includes?)]
     ['cons? (.st-p 'cons 2)]
     ['cons (.st-mk 'cons 2)]
     ['car .car]
     ['cdr .cdr]
     ['empty (.@ (.st-mk 'empty 0) empty 'Λ)]
     ['empty? .empty/c]
     [(? num? x) (.b x)]
     [#f .ff]
     [#t .tt]
     [(? str? x) (.b x)]
     #;[`(quote ,(? sym? x)) (.b x)]
     [_ #f])))

(: name : .o → Sym)
(define name
  (match-lambda [(.add1) 'add1] [(.sub1) 'sub1] [(.sqrt) 'sqrt] [(.+) '+] [(.-) '-] [(.*) '*] [(./) '/]
                [(.str-len) 'str-len] [(.equal?) 'equal?]
                [(.=) '=] [(.>) '>] [(.<) '<] [(.≥) '≥] [(.≤) '≤]
                [(.arity=?) 'arity=?] [(.arity≥?) 'arity≥?] [(.arity-includes?) 'arity-includes?]
                [(.num?) 'num?] [(.real?) 'real?] [(.int?) 'int?] [(.true?) 'true?] [(.false?) 'false?]
                [(.bool?) 'bool?] [(.str?) 'str?] [(.symbol?) 'symbol?] [(.proc?) 'proc?]
                [(.st-mk t _) t]
                [(.st-ac 'cons 2 0) 'car]
                [(.st-ac 'cons 2 1) 'cdr]
                [(.st-ac t _ i)
                 (string->symbol (string-append (symbol->string t) "@" (number->string i)))]
                [(.st-p t _) (string->symbol (string-append (symbol->string t) "?"))]))

(define .pred/c (.λ/c (list .any/c) .bool/c #f))

(: ¬l : Sym^3 → Sym^3)
(define ¬l
  (match-lambda [(list l+ l- lo) (list l- l+ lo)]))

(: gen-havoc : .p → .p)
(define (gen-havoc p)
  (match-define (.p (.m* m-seq ms) e†) p)
  
  (define acs ; all public accessors
    (set->list
     (for*/fold: : (Setof .st-ac) ([acs : (Setof .st-ac) {set .car .cdr}])
       ([m (in-hash-values ms)]
        [defs (in-value (.m-defs m))]
        [d (in-hash-values defs)]
        [c (in-value (cdr d))]
        #:when (match? c (.λ/c _ (? .struct/c?) _)))
       (match-let* ([(.λ/c _ (.struct/c t cs) _) c]
                    [n (length cs)])
         (for/fold ([acs acs]) ([i n])
           (set-add acs (.st-ac t n i)))))))
  
  (define havoc
    (.λ 1 (.amb (set-add (for/set: .@ ([ac acs])
                           (.@ (.ref 'havoc '☠ '☠)
                               (list (.@ ac (list (.x 0)) '☠)) '☠))
                         (.@ (.ref 'havoc '☠ '☠)
                             (list (.@-havoc (.x 0))) '☠))) #f))
  
  (define ☠ (.m (list 'havoc)
                (hash-set (ann #hash() (Map Sym (Pairof .e (U #f .e))))
                          'havoc (cons havoc (.λ/c (list .any/c) .none/c #f)))))
  
  (if (hash-has-key? ms '☠) p
      (.p (.m* (cons '☠ m-seq) (hash-set ms '☠ ☠)) e†)))

(: amb : (Listof .e) → .e)
(define (amb e*)
  (let ([s (for/fold: ([ac : (Setof .e) ∅]) ([e e*])
             (match e ; try to avoid nested amb
               [(.amb s) (set-union ac s)]
               [_ (set-add ac e)]))])
    (match (set-count s)
      [1 (set-first s)]
      [_ (.amb s)])))