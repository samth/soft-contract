(module mc91
  (provide
   [mc91 ([n : int?] . -> . (and/c int? (λ (a) (if (<= n 101) (= a 91) 'admit))))])
  (define (mc91 x)
    (if (> x 100) (- x 10)
        (mc91 (mc91 (+ x 11))))))

(require mc91)
(mc91 •)