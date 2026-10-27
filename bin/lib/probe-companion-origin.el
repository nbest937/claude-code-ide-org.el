;;; probe-companion-origin.el --- Does a foreign Origin reach the IDE companion?  -*- lexical-binding: t; -*-

;; The core of bin/probe-companion-origin, which says why it exists
;; (TODO.org :ID: d7b2f50f). Runs in a batch Emacs as a *client*: it opens
;; the WebSocket a web page would open, with a foreign Origin, and reports
;; what the companion let it do. It never talks to the running Emacs any
;; other way.

(require 'json)
(require 'websocket)

(defconst probe-companion-origin--origin "https://evil.example.com"
  "The Origin a hostile page would send.")

(defconst probe-companion-origin--seconds 10
  "How long to wait for the handshake and for each reply.")

;; After a refused handshake websocket.el closes the socket, calls
;; `on-error', and then reads the refusal's body as frames anyway. Answering
;; one of those signals inside the process filter, and a batch Emacs
;; re-signals a filter error at top level, killing the probe with 255
;; whatever handler surrounds it. So frames on a closed socket are skipped.
(advice-add 'websocket-process-input-on-open-ws :before-while
            (lambda (ws &rest _) (websocket-openp ws)))

(defun probe-companion-origin--wait (pred)
  "Spin until PRED returns non-nil or the timeout passes; return its value."
  (let ((deadline (+ (float-time) probe-companion-origin--seconds))
        value)
    (while (and (not (setq value (funcall pred)))
                (< (float-time) deadline))
      (accept-process-output nil 0.1))
    value))

(defun probe-companion-origin--port (port)
  "Probe the companion on PORT; return `refused', `open' or `unreachable'.
Prints one line saying which, and for `open' whether executeCode ran."
  (let ((replies (make-hash-table))
        (state 'connecting)
        ws)
    (condition-case err
        (setq ws (websocket-open
                  (format "ws://127.0.0.1:%d" port)
                  :custom-header-alist
                  `(("Origin" . ,probe-companion-origin--origin))
                  ;; websocket.el calls `on-error' for a refused handshake
                  ;; and then marks the socket open and calls `on-open'
                  ;; anyway, so the refusal has to win.
                  :on-open (lambda (_ws)
                             (unless (eq state 'refused) (setq state 'open)))
                  :on-message
                  (lambda (_ws frame)
                    (let* ((msg (json-parse-string (websocket-frame-text frame)
                                                   :object-type 'alist))
                           (id (alist-get 'id msg)))
                      (when id (puthash id msg replies))))
                  :on-close (lambda (_ws)
                              (unless (eq state 'open) (setq state 'refused)))
                  :on-error (lambda (_ws _type _err) (setq state 'refused))))
      (error
       (message "probe-companion-origin: %d: unreachable (%s)"
                port (error-message-string err))
       (setq state 'unreachable)))
    (unless (eq state 'unreachable)
      (probe-companion-origin--wait (lambda () (not (eq state 'connecting))))
      (pcase state
        ('open
         (let ((call
                (lambda (id method params)
                  (ignore-errors
                    (websocket-send-text
                     ws (json-encode `((jsonrpc . "2.0") (id . ,id)
                                       (method . ,method) (params . ,params)))))
                  (probe-companion-origin--wait (lambda () (gethash id replies))))))
           (funcall call 1 "tools/list" (make-hash-table))
           (let* ((reply (funcall call 2 "tools/call"
                                  '((name . "executeCode")
                                    (arguments
                                     . ((code . "(list (emacs-pid) (+ 40 2))"))))))
                  (result (alist-get 'result reply)))
             (message "probe-companion-origin: %d: OPEN -- a page from %s connected; %s"
                      port probe-companion-origin--origin
                      (if result
                          (format "executeCode ran and returned %s"
                                  (json-encode result))
                        "executeCode refused")))))
        ('connecting
         (message "probe-companion-origin: %d: no handshake reply in %ds; treating it as open"
                  port probe-companion-origin--seconds)
         (setq state 'open))
        (_ (message "probe-companion-origin: %d: refused -- the handshake failed" port)))
      (when ws (ignore-errors (websocket-close ws))))
    state))

(defun probe-companion-origin-main ()
  "Probe each port on the command line.
Exit 1 if any companion accepted the foreign Origin, else 2 if any was
unreachable, else 0."
  (let* ((ports (mapcar #'string-to-number command-line-args-left))
         (states (mapcar #'probe-companion-origin--port ports)))
    (setq command-line-args-left nil)
    (kill-emacs (cond ((memq 'open states) 1)
                      ((memq 'unreachable states) 2)
                      (t 0)))))

;;; probe-companion-origin.el ends here
