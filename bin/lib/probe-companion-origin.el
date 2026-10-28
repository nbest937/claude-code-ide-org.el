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

(defconst probe-companion-origin--seconds
  (let ((env (getenv "PROBE_SECONDS")))
    (if (and env (string-match-p "\\`[1-9][0-9]*\\'" env)) (string-to-number env) 10))
  "How long to wait for the handshake and for each reply.
PROBE_SECONDS overrides it, so the suite can reach a timeout quickly.")

;; After a refused handshake websocket.el closes the socket, calls
;; `on-error', and then reads the refusal's body as frames anyway. Answering
;; one of those signals inside the process filter, and a batch Emacs
;; re-signals a filter error at top level, killing the probe with 255
;; whatever handler surrounds it. So frames on a closed socket are skipped,
;; for the length of `probe-companion-origin-main' only: loaded anywhere
;; else, this file changes nothing about websocket.el.
(defun probe-companion-origin--open-only (ws &rest _)
  "Let websocket.el process a frame only while WS is open."
  (websocket-openp ws))

(defun probe-companion-origin--wait (pred)
  "Spin until PRED returns non-nil or the timeout passes; return its value."
  (let ((deadline (+ (float-time) probe-companion-origin--seconds))
        value)
    (while (and (not (setq value (funcall pred)))
                (< (float-time) deadline))
      (accept-process-output nil 0.1))
    value))

(defun probe-companion-origin--port (port)
  "Probe the companion on PORT; return `refused', `open', `unreachable' or
`inconclusive'.
Prints one line saying which, and for `open' whether executeCode ran."
  (let ((replies (make-hash-table))
        (state 'connecting)
        ws)
    (condition-case err
        (setq ws (websocket-open
                  (format "ws://127.0.0.1:%d" port)
                  :custom-header-alist
                  `(("Origin" . ,probe-companion-origin--origin))
                  ;; The companion offers `mcp', and a page can ask for it
                  ;; (new WebSocket(url, ["mcp"])); a server that refused a
                  ;; handshake without it must not read as fixed.
                  :protocols '("mcp")
                  ;; websocket.el calls `on-error' for a refused handshake
                  ;; and then marks the socket open and calls `on-open'
                  ;; anyway, so the refusal has to win.
                  :on-open (lambda (_ws)
                             (unless (eq state 'refused) (setq state 'open)))
                  ;; A frame that is not JSON is not a reply. Left to
                  ;; signal, websocket.el would route it to `on-error'.
                  ;; Only a parse error: a missing parser is checked once,
                  ;; in `probe-companion-origin-main', and must not pass for
                  ;; a server that never answered.
                  :on-message
                  (lambda (_ws frame)
                    (let* ((msg (condition-case nil
                                    (json-parse-string (websocket-frame-text frame)
                                                       :object-type 'alist)
                                  (json-parse-error nil)))
                           (id (and (consp msg) (alist-get 'id msg))))
                      (when id (puthash id msg replies))))
                  ;; A close during the handshake is a refusal; after it,
                  ;; the verdict is the reply's, and the probe's own close
                  ;; below must not overwrite one.
                  :on-close (lambda (_ws)
                              (when (eq state 'connecting) (setq state 'refused)))
                  ;; websocket.el also calls `on-error' for any callback
                  ;; that signals, so only a handshake error is a refusal.
                  :on-error (lambda (_ws _type _err)
                              (when (eq state 'connecting) (setq state 'refused)))))
      (error
       (message "probe-companion-origin: %d: unreachable (%s)"
                port (error-message-string err))
       (setq state 'unreachable)))
    (unless (eq state 'unreachable)
      (probe-companion-origin--wait (lambda () (not (eq state 'connecting))))
      (pcase state
        ;; A handshake is not the verdict: websocket.el's server sends the
        ;; 101 before `on-open' can see the Origin, so a companion that
        ;; checks it can only close the socket after accepting. An answer
        ;; is the verdict -- a page that is answered can drive the server.
        ('open
         (let* ((call
                 (lambda (id method params)
                   (ignore-errors
                     (websocket-send-text
                      ws (json-encode `((jsonrpc . "2.0") (id . ,id)
                                        (method . ,method) (params . ,params)))))
                   (probe-companion-origin--wait
                    (lambda () (or (gethash id replies) (not (websocket-openp ws)))))
                   (gethash id replies)))
                (listing (funcall call 1 "tools/list" (make-hash-table))))
           (cond
            (listing
             (let* ((reply (funcall call 2 "tools/call"
                                    '((name . "executeCode")
                                      (arguments
                                       . ((code . "(list (emacs-pid) (+ 40 2))"))))))
                    (err (alist-get 'error reply)))
               ;; Only -32601, method not found, means the tool is not
               ;; offered; any other error (-32603 for an eval failure)
               ;; means it exists and ran. A result of {} parses to nil,
               ;; so its key, not its value, says it answered.
               (message "probe-companion-origin: %d: OPEN -- a page from %s was answered; %s"
                        port probe-companion-origin--origin
                        (cond ((assq 'result reply)
                               ;; JSON null parses to :null, so nil is {}.
                               (format "executeCode ran and returned %s"
                                       (if (alist-get 'result reply)
                                           (json-encode (alist-get 'result reply))
                                         "{}")))
                              ((eql (alist-get 'code err) -32601)
                               (format "executeCode not offered (%s)" (alist-get 'message err)))
                              (err (format "executeCode exists and failed (%s: %s)"
                                           (alist-get 'code err) (alist-get 'message err)))
                              (t "executeCode did not answer")))))
            ((not (websocket-openp ws))
             (message "probe-companion-origin: %d: refused -- the socket closed unanswered after the handshake"
                      port)
             (setq state 'refused))
            ;; Silence is no verdict either way: a companion inside a busy
            ;; Emacs is silent too. Neither pass nor fail, so the run
            ;; cannot report a fixed companion as a regression.
            (t
             (message "probe-companion-origin: %d: no verdict -- handshake accepted, no answer in %ds"
                      port probe-companion-origin--seconds)
             (setq state 'inconclusive)))))
        ('connecting
         (message "probe-companion-origin: %d: no verdict -- no handshake reply in %ds"
                  port probe-companion-origin--seconds)
         (setq state 'inconclusive))
        (_ (message "probe-companion-origin: %d: refused -- the handshake failed" port)))
      (when ws (ignore-errors (websocket-close ws))))
    state))

(defun probe-companion-origin-main ()
  "Probe each port on the command line.
Exit 1 if any companion accepted the foreign Origin, else 2 if any was
unreachable or gave no verdict, else 0."
  (let ((ports (mapcar #'string-to-number command-line-args-left)))
    (setq command-line-args-left nil)
    (unless (json-available-p)
      (message "probe-companion-origin: this Emacs has no JSON parser; no reply could be read")
      (kill-emacs 2))
    (advice-add 'websocket-process-input-on-open-ws :before-while
                #'probe-companion-origin--open-only)
    (let ((states (unwind-protect (mapcar #'probe-companion-origin--port ports)
                    (advice-remove 'websocket-process-input-on-open-ws
                                   #'probe-companion-origin--open-only))))
      (kill-emacs (cond ((memq 'open states) 1)
                        ((or (memq 'unreachable states) (memq 'inconclusive states)) 2)
                        (t 0))))))

;;; probe-companion-origin.el ends here
