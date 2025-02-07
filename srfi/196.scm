;;; Copyright (C) 2020 Wolfgang Corcoran-Mathe
;;;
;;; Permission is hereby granted, free of charge, to any person obtaining a
;;; copy of this software and associated documentation files (the "Software"),
;;; to deal in the Software without restriction, including without limitation
;;; the rights to use, copy, modify, merge, publish, distribute, sublicense,
;;; and/or sell copies of the Software, and to permit persons to whom the
;;; Software is furnished to do so, subject to the following conditions:
;;;
;;; The above copyright notice and this permission notice shall be included in
;;; all copies or substantial portions of the Software.
;;;
;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
;;; THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
;;; FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
;;; DEALINGS IN THE SOFTWARE.

(: exact-natural? (* -> boolean))
(define (exact-natural? x)
  (and (exact-integer? x) (not (negative? x))))

;; Find the least element of a list non-empty of naturals. If an element
;; is zero, returns it immediately.
(: short-minimum ((list-of fixnum) -> fixnum))
(define (short-minimum ns)
  (call-with-current-continuation
   (lambda (return)
     (reduce (lambda (n s)
               (if (zero? n) (return n) (min n s)))
             0
             ns))))

(: sum ((list-of fixnum) -> fixnum))
(define (sum ns) (reduce + 0 ns))

(define-record-type <range>
  (raw-range start-index
             length
             indexer
             complexity)
  range?
  (start-index range-start-index : fixnum)
  (length range-length : fixnum)
  (indexer range-indexer : (fixnum -> *))
  (complexity range-complexity : fixnum))

;; Maximum number of indexers to compose with range-reverse and
;; range-append before a range is expanded with vector-range.
;; This may need adjustment.
(: %range-maximum-complexity fixnum)
(define %range-maximum-complexity 16)

;; Returns an empty range which is otherwise identical to r.
(: %empty-range-from ((struct <range>) -> (struct <range>)))
(define (%empty-range-from r)
  (raw-range (range-start-index r) 0 (range-indexer r) (range-complexity r)))

(: threshold? (fixnum -> boolean))
(define (threshold? k)
  (> k %range-maximum-complexity))

(: %range-valid-index? ((struct <range>) fixnum -> boolean))
(define (%range-valid-index? r index)
  (and (exact-natural? index)
       (< index (range-length r))))

;; As the previous check, but bound is assumed to be exclusive.
(: %range-valid-bound? ((struct <range>) * -> boolean))
(define (%range-valid-bound? r bound)
  (and (exact-natural? bound)
       (<= bound (range-length r))))

;;;; Constructors

;; The primary range constructor does some extra consistency checking.
(: range (fixnum (fixnum -> *) -> (struct <range>)))
(define (range length indexer)
  (assume (exact-natural? length))
  (assume (procedure? indexer))
  (raw-range 0 length indexer 0))

(: numeric-range (or (fixnum fixnum -> (struct <range>))
                     (fixnum fixnum fixnum -> (struct <range>))))
(define numeric-range
  (case-lambda
    ((start end) (numeric-range start end 1))
    ((start end step)
     (assume (real? start))
     (assume (real? end))
     (assume (not (zero? step)) "numeric-range: zero-valued step")
     (let ((len (exact (ceiling (max 0 (/ (- end start) step))))))
       ;; Try to ensure that we can compute a correct range from the
       ;; given parameters, i.e. one not plagued by roundoff errors.
       (assume (cond ((and (positive? step) (< start end))
                      (and (> (+ start step) start)
                           (< (+ start (* (- len 1) step)) end)))
                     ((and (negative? step) (> start end))
                      (and (< (+ start step) start)
                           (> (+ start (* (- len 1) step)) end)))
                     (else #t))
               "numeric-range: invalid parameters")
       (raw-range 0 len (lambda (n) (+ start (* n step))) 0)))))

;; TODO: Consider possible round-off bugs.
(: iota-range (or (fixnum -> (struct <range>))
                  (fixnum fixnum -> (struct <range>))
                  (fixnum fixnum fixnum -> (struct <range>))))
(define iota-range
  (case-lambda
    ((len) (iota-range len 0 1))
    ((len start) (iota-range len start 1))
    ((len start step)
     (assume (exact-natural? len))
     (assume (real? start))
     (assume (real? step))
     (raw-range 0
                len
                (cond ((and (zero? start) (= step 1)) (lambda (i) i))
                      ((= step 1) (lambda (i) (+ start i)))
                      ((zero? start) (lambda (i) (* step i)))
                      (else (lambda (i) (+ start (* step i)))))
                0))))

(: vector-range (vector -> (struct <range>)))
(define (vector-range vec)
  (assume (vector? vec))
  (raw-range 0 (vector-length vec) (lambda (i) (vector-ref vec i)) 0))

;; This implementation assumes that string-ref is O(n), as would be
;; the case with UTF-8.  If an implementation has an O(1) string-ref,
;; the following version is preferable:
;;
;; (raw-range 0 (string-length s) (lambda (i) (string-ref s i))))
;;
(: string-range (string -> (struct <range>)))
(define (string-range s)
  (assume (string? s))
  (vector-range (string->vector s)))

(: %range-maybe-vectorize ((struct <range>) -> (struct <range>)))
(define (%range-maybe-vectorize r)
  (if (threshold? (range-complexity r))
      (vector-range (range->vector r))
      r))

;;;; Accessors

(: range-ref ((struct <range>) fixnum -> *))
(define (range-ref r index)
  (assume (range? r))
  (assume (%range-valid-index? r index) "range-ref: invalid index")
  ((range-indexer r) (+ index (range-start-index r))))

;; A portable implementation can't rely on inlining, but it
;; can rely on macros.
(define-syntax %range-ref-no-check
  (syntax-rules ()
    ((_ r index)
     ((range-indexer r) (+ index (range-start-index r))))))

(: range-first ((struct <range>) -> *))
(define (range-first r) (%range-ref-no-check r (range-start-index r)))

(: range-last ((struct <range>) -> *))
(define (range-last r) (%range-ref-no-check r (- (range-length r) 1)))

;;;; Predicates

(: range=? (or ((* * -> boolean) (struct <range>) (struct <range>) -> boolean)
               ((* * -> boolean) #!rest (list-of (struct <range>)) -> boolean)))
(define range=?
  (case-lambda
    ((equal ra rb)                      ; two-range fast path
     (assume (procedure? equal))
     (assume (range? ra))
     (%range=?-2 equal ra rb))
    ((equal . rs)                       ; variadic path
     (assume (procedure? equal))
     (assume (pair? rs))
     (let ((ra (car rs)))
       (assume (range? ra))
       (every (lambda (rb) (%range=?-2 equal ra rb)) (cdr rs))))))

(: %range=?-2 ((* * -> boolean) (struct <range>) (struct <range>) -> boolean))
(define (%range=?-2 equal ra rb)
  (assume (range? rb))
  (or (eqv? ra rb)                      ; quick check
      (let ((la (range-length ra)))
        (and (= la (range-length rb))
             (if (zero? la)
                 #t                     ; all empty ranges are equal
                 (let lp ((i 0))
                   (cond ((= i la) #t)
                         ((not (equal (%range-ref-no-check ra i)
                                      (%range-ref-no-check rb i)))
                          #f)
                         (else (lp (+ i 1))))))))))

;;;; Iteration

(: range-split-at ((struct <range>) fixnum -> (struct <range>) (struct <range>)))
(define (range-split-at r index)
  (assume (range? r))
  (assume (%range-valid-bound? r index))
  (cond ((= index 0) (values (%empty-range-from r) r))
        ((= index (range-length r)) (values r (%empty-range-from r)))
        (else
         (let ((indexer (range-indexer r)) (k (range-complexity r)))
           (values (raw-range (range-start-index r) index indexer k)
                   (raw-range index (- (range-length r) index) indexer k))))))

(: subrange ((struct <range>) fixnum fixnum -> (struct <range>)))
(define (subrange r start end)
  (assume (range? r))
  (assume (%range-valid-index? r start) "subrange: invalid start index")
  (assume (%range-valid-bound? r end) "subrange: invalid end index")
  (assume (not (negative? (- end start))) "subrange: invalid subrange")
  (if (and (zero? start) (= end (range-length r)))
      r
      (raw-range (+ (range-start-index r) start)
                 (- end start)
                 (range-indexer r)
                 (range-complexity r))))

(: range-segment ((struct <range>) fixnum -> (list-of (struct <range>))))
(define (range-segment r k)
  (assume (range? r))
  (assume (and (exact-integer? k) (positive? k)))
  (let ((len (range-length r))
        (%subrange-no-check
         (lambda (s e)
           (raw-range (+ (range-start-index r) s)
                      (- e s)
                      (range-indexer r)
                      (range-complexity r)))))
    (unfold (lambda (i) (>= i len))
            (lambda (i) (%subrange-no-check i (min len (+ i k))))
            (lambda (i) (+ i k))
            0)))

(: range-take ((struct <range>) fixnum -> (struct <range>)))
(define (range-take r count)
  (assume (range? r))
  (assume (%range-valid-bound? r count) "range-take: invalid count")
  (cond ((zero? count) (%empty-range-from r))
        ((= count (range-length r)) r)
        (else (raw-range (range-start-index r)
                         count
                         (range-indexer r)
                         (range-complexity r)))))

(: range-take-right ((struct <range>) fixnum -> (struct <range>)))
(define (range-take-right r count)
  (assume (range? r))
  (assume (%range-valid-bound? r count)
          "range-take-right: invalid count")
  (cond ((zero? count) (%empty-range-from r))
        ((= count (range-length r)) r)
        (else
         (raw-range (+ (range-start-index r) (- (range-length r) count))
                    count
                    (range-indexer r)
                    (range-complexity r)))))

(: range-drop ((struct <range>) fixnum -> (struct <range>)))
(define (range-drop r count)
  (assume (range? r))
  (assume (%range-valid-bound? r count) "range-drop: invalid count")
  (if (zero? count)
      r
      (raw-range (+ (range-start-index r) count)
                 (- (range-length r) count)
                 (range-indexer r)
                 (range-complexity r))))

(: range-drop-right ((struct <range>) fixnum -> (struct <range>)))
(define (range-drop-right r count)
  (assume (range? r))
  (assume (%range-valid-bound? r count) "range-drop: invalid count")
  (if (zero? count)
      r
      (raw-range (range-start-index r)
                 (- (range-length r) count)
                 (range-indexer r)
                 (range-complexity r))))

(: range-count (procedure (struct <range>) #!rest (list-of (struct <range>)) -> fixnum))
(define (range-count pred r . rs)
  (assume (procedure? pred))
  (assume (range? r))
  (if (null? rs)                        ; one-range fast path
      (%range-fold-1 (lambda (c x) (if (pred x) (+ c 1) c)) 0 r)
      (apply range-fold                 ; variadic path
             (lambda (c . xs)
               (if (apply pred xs) (+ c 1) c))
             0
             r
             rs)))

(: range-any (procedure (struct <range>) #!rest (list-of (struct <range>)) -> boolean))
(define (range-any pred r . rs)
  (assume (procedure? pred))
  (assume (range? r))
  (if (null? rs)                        ; one-range fast path
      (%range-fold-1 (lambda (last x) (or (pred x) last)) #f r)
      (apply range-fold                 ; variadic path
             (lambda (last . xs) (or (apply pred xs) last))
             #f
             r
             rs)))

(: range-every (procedure (struct <range>) #!rest (list-of (struct <range>)) -> boolean))
(define (range-every pred r . rs)
  (assume (procedure? pred))
  (assume (range? r))
  (call-with-current-continuation
   (lambda (return)
     (if (null? rs)                     ; one-range fast path
         (%range-fold-1 (lambda (_ x) (or (pred x) (return #f))) #t r)
         (apply range-fold              ; variadic path
                (lambda (_ . xs) (or (apply pred xs) (return #f)))
                #t
                r
                rs)))))

(: range-map (procedure #!rest (list-of (struct <range>))
              -> (struct <range>)))
(define (range-map proc . rs)
  (assume (pair? rs))
  (vector-range (apply range-map->vector proc rs)))

(: range-filter-map (procedure #!rest (list-of (struct <range>))
                     -> (struct <range>)))
(define (range-filter-map proc . rs)
  (assume (pair? rs))
  (vector-range (list->vector (apply range-filter-map->list proc rs))))

(: range-map->list (procedure (struct <range>) #!rest (list-of (struct <range>))
                    -> list))
(define (range-map->list proc r . rs)
  (assume (procedure? proc))
  (if (null? rs)                        ; one-range fast path
      (%range-fold-right-1 (lambda (res x) (cons (proc x) res)) '() r)
      (apply range-fold-right           ; variadic path
             (lambda (res . xs) (cons (apply proc xs) res))
             '()
             r
             rs)))

(: range-filter-map->list (procedure (struct <range>) #!rest (list-of (struct <range>))
                           -> list))
(define (range-filter-map->list proc r . rs)
  (if (null? rs)                        ; one-range fast path
      (%range-fold-right-1 (lambda (res x)
                             (cond ((proc x) =>
                                    (lambda (elt) (cons elt res)))
                                   (else res)))
                           '()
                           r)
      (apply range-fold-right           ; variadic path
             (lambda (res . xs)
               (cond ((apply proc xs) => (lambda (elt) (cons elt res)))
                     (else res)))
             '()
             r
             rs)))

(: range-map->vector (procedure (struct <range>) #!rest (list-of (struct <range>))
                      -> vector))
(define (range-map->vector proc r . rs)
  (assume (procedure? proc))
  (assume (range? r))
  (if (null? rs)                        ; one-range fast path
      (vector-unfold (lambda (i) (proc (%range-ref-no-check r i)))
                     (range-length r))
      (let ((rs* (cons r rs)))          ; variadic path
        (vector-unfold (lambda (i)
                         (apply proc (map (lambda (r)
                                            (%range-ref-no-check r i))
                                          rs*)))
                       (short-minimum (map range-length rs*))))))

(: range-for-each (procedure (struct <range>) #!rest (list-of (struct <range>))
                   -> undefined))
(define (range-for-each proc r . rs)
  (assume (procedure? proc))
  (assume (range? r))
  (if (null? rs)                        ; one-range fast path
      (let ((len (range-length r)))
        (let lp ((i 0))
          (cond ((= i len) (if #f #f))
                (else (proc (%range-ref-no-check r i))
                      (lp (+ i 1))))))
      (let* ((rs* (cons r rs))          ; variadic path
             (len (short-minimum (map range-length rs*))))
        (let lp ((i 0))
          (cond ((= i len) (if #f #f))
                (else
                 (apply proc (map (lambda (r)
                                    (%range-ref-no-check r i))
                                  rs*))
                 (lp (+ i 1))))))))

(: %range-fold-1 (procedure * (struct <range>)
                  -> *))
(define (%range-fold-1 proc nil r)
  (assume (procedure? proc))
  (assume (range? r))
  (let ((len (range-length r)))
    (let lp ((i 0) (acc nil))
      (if (= i len)
          acc
          (lp (+ i 1) (proc acc (%range-ref-no-check r i)))))))

(: range-fold (or (procedure * (struct <range>) -> *)
                  (procedure * #!rest (list-of (struct <range>)) -> *)))
(define range-fold
  (case-lambda
    ((proc nil r)                       ; one-range fast path
     (%range-fold-1 proc nil r))
    ((proc nil . rs)                    ; variadic path
     (assume (procedure? proc))
     (assume (pair? rs))
     (let ((len (short-minimum (map range-length rs))))
       (let lp ((i 0) (acc nil))
         (if (= i len)
             acc
             (lp (+ i 1)
                 (apply proc acc (map (lambda (r)
                                        (%range-ref-no-check r i))
                                      rs)))))))))

(: %range-fold-right-1 (procedure * (struct <range>) -> *))
(define (%range-fold-right-1 proc nil r)
  (assume (procedure? proc))
  (assume (range? r))
  (let ((len (range-length r)))
    (let rec ((i 0))
      (if (= i len)
          nil
          (proc (rec (+ i 1)) (%range-ref-no-check r i))))))

(: range-fold-right (or (procedure * (struct <range>) -> *)
                        (procedure * #!rest (list-of (struct <range>)) -> *)))
(define range-fold-right
  (case-lambda
    ((proc nil r)                       ; one-range fast path
     (%range-fold-right-1 proc nil r))
    ((proc nil . rs)                    ; variadic path
     (assume (procedure? proc))
     (assume (pair? rs))
     (let ((len (short-minimum (map range-length rs))))
       (let rec ((i 0))
         (if (= i len)
             nil
             (apply proc
                    (rec (+ i 1))
                    (map (lambda (r) (%range-ref-no-check r i)) rs))))))))

(: range-filter (procedure (struct <range>) -> (struct <range>)))
(define (range-filter pred r)
  (vector-range (list->vector (range-filter->list pred r))))

(: range-filter->list (procedure (struct <range>) -> list))
(define (range-filter->list pred r)
  (assume (procedure? pred))
  (assume (range? r))
  (range-fold-right (lambda (xs x)
                      (if (pred x) (cons x xs) xs))
                    '()
                    r))

(: range-remove (procedure (struct <range>) -> (struct <range>)))
(define (range-remove pred r)
  (vector-range (list->vector (range-remove->list pred r))))

(: range-remove->list (procedure (struct <range>) -> list))
(define (range-remove->list pred r)
  (assume (procedure? pred))
  (assume (range? r))
  (range-fold-right (lambda (xs x)
                      (if (pred x) xs (cons x xs)))
                    '()
                    r))

(: range-reverse ((struct <range>) -> (struct <range>)))
(define (range-reverse r)
  (assume (range? r))
  (%range-maybe-vectorize
   (raw-range (range-start-index r)
              (range-length r)
              (lambda (n)
                ((range-indexer r) (- (range-length r) 1 n)))
              (+ 1 (range-complexity r)))))

(: range-append (or (-> (struct <range>))
                    ((struct <range>) -> (struct <range>))
                    ((struct <range>) (struct <range>) -> (struct <range>))
                    (#!rest (list-of (struct <range>)) -> (struct <range>))))
(define range-append
  (case-lambda
    (() (raw-range 0 0 identity 0))
    ((r) r)                             ; one-range fast path
    ((ra rb)                            ; two-range fast path
     (let ((la (range-length ra))
           (lb (range-length rb)))
       (%range-maybe-vectorize          ; FIXME: should be lazy.
        (raw-range 0
                   (+ la lb)
                   (lambda (i)
                     (if (< i la)
                         (%range-ref-no-check ra i)
                         (%range-ref-no-check rb (- i la))))
                   (+ 2 (range-complexity ra) (range-complexity rb))))))
    (rs                                 ; variadic path
     (let ((lens (map range-length rs)))
       (%range-maybe-vectorize          ; FIXME: should be lazy.
        (raw-range 0
                   (sum lens)
                   (lambda (i)
                     (let lp ((i i) (rs rs) (lens lens))
                       (if (< i (car lens))
                           (%range-ref-no-check (car rs) i)
                           (lp (- i (car lens)) (cdr rs) (cdr lens)))))
                   (+ (length rs) (sum (map range-complexity rs)))))))))

;;;; Searching

(: range-index (procedure (struct <range>) #!rest (list-of (struct <range>))
                -> (or fixnum false)))
(define (range-index pred r . rs)
  (assume (procedure? pred))
  (assume (range? r))
  (if (null? rs)                        ; one-range fast path
      (let ((len (range-length r)))
        (let lp ((i 0))
          (cond ((= i len) #f)
                ((pred (%range-ref-no-check r i)) i)
                (else (lp (+ i 1))))))
      (let* ((rs* (cons r rs))          ; variadic path
             (len (short-minimum (map range-length rs*))))
        (let lp ((i 0))
          (cond ((= i len) #f)
                ((apply pred
                        (map (lambda (s) (%range-ref-no-check s i))
                             rs*))
                 i)
                (else (lp (+ i 1))))))))

(: range-index-right (procedure (struct <range>) #!rest (list-of (struct <range>))
                      -> (or fixnum false)))
(define (range-index-right pred r . rs)
  (assume (procedure? pred))
  (assume (range? r))
  (if (null? rs)                        ; one-range fast path
      (let lp ((i (- (range-length r) 1)))
        (cond ((< i 0) #f)
              ((pred (%range-ref-no-check r i)) i)
              (else (lp (- i 1)))))
      (let ((len (range-length r))      ; variadic path
            (rs* (cons r rs)))
        (assume (every (lambda (s) (= len (range-length s))) rs)
                "range-index-right: ranges must be of the same length")
        (let lp ((i (- len 1)))
          (cond ((< i 0) #f)
                ((apply pred
                        (map (lambda (s) (%range-ref-no-check s i))
                             rs*))
                 i)
                (else (lp (- i 1))))))))

(: range-take-while (procedure (struct <range>) -> (struct <range>)))
(define (range-take-while pred r)
  (cond ((range-index (lambda (x) (not (pred x))) r) =>
         (lambda (i) (range-take r i)))
        (else r)))

(: range-take-while-right (procedure (struct <range>) -> (struct <range>)))
(define (range-take-while-right pred r)
  (cond ((range-index-right (lambda (x) (not (pred x))) r) =>
         (lambda (i) (range-take-right r (- (range-length r) 1 i))))
        (else r)))

(: range-drop-while (procedure (struct <range>) -> (struct <range>)))
(define (range-drop-while pred r)
  (cond ((range-index (lambda (x) (not (pred x))) r) =>
         (lambda (i) (range-drop r i)))
        (else (%empty-range-from r))))

(: range-drop-while-right (procedure (struct <range>) -> (struct <range>)))
(define (range-drop-while-right pred r)
  (cond ((range-index-right (lambda (x) (not (pred x))) r) =>
         (lambda (i) (range-drop-right r (- (range-length r) 1 i))))
        (else (%empty-range-from r))))

;;;; Conversion

(: range->list ((struct <range>) -> list))
(define (range->list r)
  (range-fold-right xcons '() r))

(: range->vector ((struct <range>) -> vector))
(define (range->vector r)
  (assume (range? r))
  (vector-unfold (lambda (i) (%range-ref-no-check r i))
                 (range-length r)))

(: range->string ((struct <range>) -> string))
(define (range->string r)
  (assume (range? r))
  (let ((res (make-string (range-length r))))
    (range-fold (lambda (i c) (string-set! res i c) (+ i 1)) 0 r)
    res))

(: vector->range (vector -> (struct <range>)))
(define (vector->range vec)
  (assume (vector? vec))
  (vector-range (vector-copy vec)))

(: range->generator ((struct <range>) -> procedure))
(define (range->generator r)
  (assume (range? r))
  (let ((i 0) (len (range-length r)))
    (lambda ()
      (if (>= i len)
          (eof-object)
          (begin
           (let ((v (%range-ref-no-check r i)))
             (set! i (+ i 1))
             v))))))
