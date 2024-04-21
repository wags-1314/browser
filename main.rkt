#lang racket

(require racket/gui net/http-easy threading)

(define *width* (make-parameter 1000))
(define *height* (make-parameter 1000))
(define *scroll* (make-parameter 0))
(define *url* (make-parameter #f))
(define SCROLL-STEP 100)

(define browser-frame%
  (class frame%
    (super-new)
    (define/override (on-size w h)
      (super on-size w h)
      (*width* w)
      (*height* h)
      (printf "Frame resized to width: ~a height: ~a\n" w h))))

(define frame (new browser-frame% [label "Browser"]
                   [width (*width*)]
                   [height (*height*)]))

(define browser (new vertical-panel% [parent frame]))
(define url-bar (new horizontal-panel% [parent browser]))
(define url-entry (new text-field% [parent url-bar] [label "URL"]))
(define url-button
  (new button% [parent url-bar] [label "Go"]
       [callback (lambda (_b _e)
                   (enter-url dc (send url-entry get-value)))]))
(define scroll-up (new button% [parent url-bar] [label "Up"]
                       [callback (lambda (_b _e)
                                   (*scroll*
                                    (if (zero? (*scroll*))
                                        (*scroll*)
                                        (- (*scroll*) SCROLL-STEP)))
                                   (draw-page dc))]))

(define scroll-down (new button% [parent url-bar] [label "Down"]
                       [callback (lambda (_b _e)
                                   (*scroll* (+ (*scroll*) SCROLL-STEP))
                                   (draw-page dc))]))

(define web-page (new canvas% [parent browser]
                      [min-height (round (/ (* 11 (*height*)) 12))]
                      [paint-callback
                       (lambda (c d)
                         (when (*url*)
                           (enter-url d (*url*))))]))

(define dc (send web-page get-dc))

(define HSTEP 20)
(define VSTEP 20)

(define *display-list* (make-parameter '()))

(define (text->dlist dc dlist text x y fsize fweight fstyle)
  (define font (make-font #:size fsize
                          #:style fstyle
                          #:weight fweight))
  (send dc set-font font)
  (let loop ([words (string-split text)]
             [cursor-x x]
             [cursor-y y]
             [display-list dlist])
    (if (empty? words)
        (list display-list cursor-x cursor-y)
        (let* ([word (first words)]
               [new-dlist (cons (list cursor-x cursor-y word font) display-list)]
               [w (get-font-width dc word)]
               [new-x (+ cursor-x w (get-font-width dc " "))]
               [new-y (+ cursor-y (* (get-font-size dc) 1.25))])
          (if (> (+ cursor-x w) (- (*width*) (* 5 HSTEP)))
              (loop (rest words) HSTEP new-y new-dlist)
              (loop (rest words) new-x cursor-y new-dlist))))))

(define (layout-new dc tokens)
  (define (loop tokens x y dlist fsize fweight fstyle ignore?)
    (cond
      [(empty? tokens)
       (*display-list* (reverse dlist))]
      [else
       (define token (first tokens))
       (define ts (rest tokens))
       (define font (list fsize fweight fstyle))
       (cond
         [(and (equal? (first token) 'tag)
               (equal? (second token) "/script"))
          (loop ts x y dlist fsize fweight fstyle #f)]
         [(and (equal? (first token) 'tag)
               (string-contains? (second token) "script"))
          (loop ts x y dlist fsize fweight fstyle #t)]
         [ignore? (loop ts x y dlist fsize fweight fstyle ignore?)]
         [(equal? (first token) 'text)
          (match-define (list n-dlist nx ny)
            (text->dlist dc dlist (second token) x y fsize fweight fstyle))
          (loop ts nx ny n-dlist fsize fweight fstyle ignore?)]
         [(equal? (second token) "i")
          (loop ts x y dlist fsize fweight 'italic ignore?)]
         [(equal? (second token) "/i")
          (loop ts x y dlist fsize fweight 'normal ignore?)]
         [(equal? (second token) "b")
          (loop ts x y dlist fsize 'bold fstyle ignore?)]
         [(equal? (second token) "/b")
          (loop ts x y dlist fsize 'normal fstyle ignore?)]
         [(equal? (second token) "/p")
          (define ny (+ y (* (get-font-size dc) 1.25) (* 2 VSTEP)))
          (loop ts HSTEP ny dlist fsize fweight fstyle ignore?)]
         [(equal? (second token) "/pre")
          (define ny (+ y (* (get-font-size dc) 1.25) (* 2 VSTEP)))
          (loop ts HSTEP ny dlist fsize fweight fstyle ignore?)]
         [(equal? (second token) "br")
          (define ny (+ y (* (get-font-size dc) 1.25)))
          (loop ts HSTEP ny dlist fsize fweight fstyle ignore?)]
         [(equal? (second token) "/h1")
          (define ny (+ y (* (get-font-size dc) 1.25)))
          (loop ts HSTEP ny dlist fsize fweight fstyle ignore?)]
         [(equal? (second token) "/li")
          (define ny (+ y (* (get-font-size dc) 1.25)))
          (loop ts HSTEP ny dlist fsize fweight fstyle ignore?)]
         [(equal? (second token) "/ul")
          (define ny (+ y (* (get-font-size dc) 1.25) (* 2 VSTEP)))
          (loop ts HSTEP ny dlist fsize fweight fstyle ignore?)]
         [else (loop ts x y dlist fsize fweight fstyle ignore?)])]))
  (loop tokens HSTEP VSTEP '() 16 'normal 'normal #f))



(define (get-font-size dc)
  (define font (send dc get-font))
  (send font get-size #t))

(define (get-font-width dc word)
  (define-values (width height ascent descent)
    (send dc get-text-extent word))
  width)


(define (draw-page dc)
  (send dc clear)
  (for ([coords (in-list (*display-list*))])
    (match-define (list x y c f) coords)
    (send dc set-font f)
    (unless (or (> y (+ (*scroll*) (*height*)))
                (< (+ y VSTEP) (*scroll*)))
      (send dc draw-text (escape c) x (- y (*scroll*))))))

(define (lex-tags body)
  (define (lex-helper chars buffer in-tag result)
    (cond
      [(empty? chars)
       (if (and (not in-tag) (not (string=? buffer "")))
           (append result (list (list 'text buffer)))
           result)]
      [(char=? (first chars) #\<)
       (if (not (string=? buffer ""))
           (lex-helper (cdr chars) "" #t (append result (list (list 'text buffer))))
           (lex-helper (cdr chars) "" #t result))]
      [(char=? (first chars) #\>)
       (if (not (string=? buffer ""))
           (lex-helper (rest chars) "" #f (append result (list (list 'tag buffer))))
           (lex-helper (rest chars) "" #f result))]
      [else
       (lex-helper (rest chars) (string-append buffer (string (first chars))) in-tag result)]))
  
  (lex-helper (string->list body) "" #f '()))

(define (escape text)
  (~> text
      (string-replace _ "&lt;" "<")
      (string-replace _ "&gt;" ">")
      (string-replace _ "&quot;" "\"")
      (string-replace _ "&#39;" "'")))

(define (enter-url dc url)
  (*url* url)
  (define res (get url))
  (*scroll* 0)
  (*display-list* '())

  (define page
    (~> res
        response-body
        bytes->string/utf-8
        lex-tags))
  (layout-new dc page)
  
  (draw-page dc))

(send frame show #t)