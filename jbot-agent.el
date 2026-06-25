;;; jbot-agent.el --- Emacs-native assistant for local models -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: John Tinnerholm
;; Keywords: tools, convenience, ai
;; Package-Requires: ((emacs "29.1"))
;; Version: 0.1.0

;;; Commentary:

;; JBOT Agent integrates a local OpenAI-compatible model server with ordinary
;; Emacs buffers.  llama.cpp is the primary backend.  The package deliberately
;; keeps edits proposal-first: generated changes are shown in a review
;; workspace and are never applied without an explicit command.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'diff)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'thingatpt)
(require 'url)
(require 'url-http)

(defgroup jbot-agent nil
  "An Emacs-native assistant backed by a local language model."
  :group 'tools
  :prefix "jbot-agent-")

(defcustom jbot-agent-server-url "http://127.0.0.1:8080"
  "Base URL of the OpenAI-compatible model server.

The default is llama.cpp's default server address."
  :type 'string
  :group 'jbot-agent)

(defcustom jbot-agent-model nil
  "Model identifier sent to the server.

When nil, JBOT asks `/v1/models' and uses the first returned model."
  :type '(choice (const :tag "Discover automatically" nil) string)
  :group 'jbot-agent)

(defcustom jbot-agent-discovery-urls
  '("http://127.0.0.1:8080"
    "http://127.0.0.1:11434"
    "http://127.0.0.1:1234")
  "Local OpenAI-compatible server URLs considered during discovery.

Only these explicit loopback addresses are probed; JBOT does not scan ports."
  :type '(repeat string)
  :group 'jbot-agent)

(defcustom jbot-agent-auto-select-server t
  "When non-nil, select a discovered server if the configured one is offline."
  :type 'boolean
  :group 'jbot-agent)

(defcustom jbot-agent-discovery-delay 1.5
  "Idle seconds before server discovery starts after enabling the mode."
  :type 'number
  :group 'jbot-agent)

(defcustom jbot-agent-request-timeout 180
  "Number of seconds before an inference request is cancelled."
  :type 'integer
  :group 'jbot-agent)

(defcustom jbot-agent-temperature 0.2
  "Sampling temperature used for JBOT requests."
  :type 'number
  :group 'jbot-agent)

(defcustom jbot-agent-reasoning-mode 'disabled
  "Reasoning behavior requested from llama.cpp.

`disabled' keeps interactive editing responsive, `enabled' asks the model to
think before answering, and `server-default' omits llama.cpp's
`chat_template_kwargs' request field.  Use `server-default' for a compatible
server that rejects llama.cpp-specific request fields."
  :type '(choice (const :tag "Disable thinking" disabled)
                 (const :tag "Enable thinking" enabled)
                 (const :tag "Use server default" server-default))
  :group 'jbot-agent)

(defcustom jbot-agent-max-output-tokens 4096
  "Maximum output tokens for ordinary advice, chat, and edit requests."
  :type 'integer
  :group 'jbot-agent)

(defcustom jbot-agent-file-review-max-output-tokens 16384
  "Maximum output tokens for a complete file review.

This must be large enough to contain the revised file plus findings."
  :type 'integer
  :group 'jbot-agent)

(defcustom jbot-agent-max-context-chars 60000
  "Maximum source characters sent by a single JBOT request.

JBOT reports an error instead of silently truncating source code."
  :type 'integer
  :group 'jbot-agent)

(defcustom jbot-agent-review-new-frame t
  "When non-nil, file reviews use a dedicated graphical frame."
  :type 'boolean
  :group 'jbot-agent)

(defcustom jbot-agent-advice-new-frame t
  "When non-nil, advice status and results use a dedicated graphical frame."
  :type 'boolean
  :group 'jbot-agent)

(defcustom jbot-agent-advice-frame-parameters
  '((name . "JBOT Advice") (width . 100) (height . 32))
  "Frame parameters used for advice status and response frames."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'jbot-agent)

(defcustom jbot-agent-review-frame-parameters
  '((name . "JBOT Review") (width . 150) (height . 46))
  "Frame parameters used for a dedicated review frame."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'jbot-agent)

(defcustom jbot-agent-diff-switches "-u"
  "Switches used when generating review diffs."
  :type 'string
  :group 'jbot-agent)

(defcustom jbot-agent-system-prompt
  (concat
   "You are a careful source-code reviewer working inside Emacs. "
   "Be concrete and concise. Preserve behavior unless asked to change it. "
   "Do not invent APIs. Mention uncertainty. Never include unrelated edits.")
  "Base system instruction for JBOT requests."
  :type 'string
  :group 'jbot-agent)

(defconst jbot-agent--package-directory
  (file-name-directory
   (or load-file-name
       (and (boundp 'byte-compile-current-file) byte-compile-current-file)
       buffer-file-name
       default-directory))
  "Directory containing the loaded JBOT package.")

(defcustom jbot-agent-personality-directory
  (expand-file-name "PERSONALITIES" jbot-agent--package-directory)
  "Directory containing JBOT personality Modelfiles.

JBOT reads the triple-quoted `SYSTEM' instruction from NAME.Modelfile.  This
makes the same personalities usable with llama.cpp requests and with tools
that consume Ollama Modelfiles directly."
  :type 'directory
  :group 'jbot-agent)

(defcustom jbot-agent-personality 'auto
  "Personality applied to JBOT requests.

The value `auto' chooses from `jbot-agent-personality-mode-alist' and source
context, nil disables personalities, and a string selects that personality by
its Modelfile name."
  :type '(choice (const :tag "Choose from major mode" auto)
                 (const :tag "No language personality" nil)
                 (string :tag "Modelfile name"))
  :group 'jbot-agent)

(defcustom jbot-agent-personality-mode-alist
  '((c++-mode . "cpp")
    (c++-ts-mode . "cpp")
    (julia-mode . "julia")
    (julia-ts-mode . "julia")
    (emacs-lisp-mode . "elisp")
    (lisp-interaction-mode . "elisp")
    (python-mode . "python")
    (python-ts-mode . "python")
    (metamodelica-mode . "metamodelica"))
  "Major modes and personality names used when selection is `auto'.

Modelica buffers containing MetaModelica compiler constructs are recognized
separately, so ordinary Modelica source is not given compiler-language advice."
  :type '(alist :key-type symbol :value-type string)
  :group 'jbot-agent)

(defface jbot-agent-heading
  '((t :inherit font-lock-keyword-face :weight bold :height 1.15))
  "Face used for JBOT response headings."
  :group 'jbot-agent)

(defface jbot-agent-muted
  '((t :inherit shadow))
  "Face used for secondary JBOT information."
  :group 'jbot-agent)

(defvar jbot-agent--active-request-buffers nil)
(defvar jbot-agent--discovered-servers nil)
(defvar jbot-agent--discovery-generation 0)
(defvar jbot-agent--discovery-timer nil)
(defvar jbot-agent--mode-line-string " JBOT")
(defvar jbot-agent--chat-history nil)
(defvar jbot-agent--chat-messages nil)
(defvar jbot-agent--chat-pending nil)
(defvar jbot-agent--chat-generation 0)
(defvar jbot-agent--review-counter 0)

(defvar-local jbot-agent--request-timeout-timer nil)
(defvar-local jbot-agent--request-timed-out nil)
(defvar-local jbot-agent--request-cancelled nil)
(defvar-local jbot-agent--review-session nil)
(defvar-local jbot-agent--response-context nil)
(defvar-local jbot-agent--response-frame nil)
(defvar-local jbot-agent--response-server nil)
(defvar-local jbot-agent--response-started-at nil)
(defvar-local jbot-agent--response-timer nil)

(defun jbot-agent--available-personalities ()
  "Return personality names found in `jbot-agent-personality-directory'."
  (when (file-directory-p jbot-agent-personality-directory)
    (mapcar (lambda (file)
              (string-remove-suffix ".Modelfile"
                                    (file-name-nondirectory file)))
            (directory-files jbot-agent-personality-directory t
                             "\\.Modelfile\\'" t))))

(defun jbot-agent--personality-file (name)
  "Return the Modelfile for personality NAME.

Reject NAME when it could escape the configured personality directory."
  (unless (and (stringp name)
               (string-match-p "\\`[[:alnum:]_-]+\\'" name))
    (error "Invalid JBOT personality name: %S" name))
  (expand-file-name (concat name ".Modelfile")
                    jbot-agent-personality-directory))

(defun jbot-agent--modelfile-system-prompt (file)
  "Read and return the triple-quoted SYSTEM instruction from FILE."
  (unless (file-readable-p file)
    (error "JBOT personality is not readable: %s" file))
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (unless (re-search-forward
             "^[[:space:]]*SYSTEM[[:space:]]+\"\"\"[[:space:]]*" nil t)
      (error "JBOT personality has no triple-quoted SYSTEM block: %s" file))
    (let ((start (point)))
      (unless (search-forward "\"\"\"" nil t)
        (error "JBOT personality has an unterminated SYSTEM block: %s" file))
      (string-trim (buffer-substring-no-properties start (match-beginning 0))))))

(defun jbot-agent--metamodelica-context-p (context)
  "Return non-nil when CONTEXT appears to contain compiler MetaModelica."
  (let ((mode (plist-get context :mode))
        (file (or (plist-get context :file) ""))
        (text (or (plist-get context :text) "")))
    (or (eq mode 'metamodelica-mode)
        (and (memq mode '(modelica-mode modelica-ts-mode))
             (or (string-match-p "/OMCompiler/Compiler/" file)
                 (string-match-p
                  (rx symbol-start
                      (or "uniontype" "match" "matchcontinue")
                      symbol-end)
                  text))))))

(defun jbot-agent--personality-for-context (context)
  "Return the personality name selected for CONTEXT, or nil."
  (cond
   ((null jbot-agent-personality) nil)
   ((stringp jbot-agent-personality) jbot-agent-personality)
   ((eq jbot-agent-personality 'auto)
    (or (and (jbot-agent--metamodelica-context-p context) "metamodelica")
        (alist-get (plist-get context :mode)
                   jbot-agent-personality-mode-alist)))
   (t (error "Invalid `jbot-agent-personality': %S"
             jbot-agent-personality))))

(defun jbot-agent--personality-label (context)
  "Return a display label for the personality selected for CONTEXT."
  (or (jbot-agent--personality-for-context context) "none"))

(defun jbot-agent--effective-system-prompt (context)
  "Return the base and selected language system prompts for CONTEXT."
  (if-let* ((name (jbot-agent--personality-for-context context)))
      (concat jbot-agent-system-prompt "\n\n"
              (jbot-agent--modelfile-system-prompt
               (jbot-agent--personality-file name)))
    jbot-agent-system-prompt))

;;;###autoload
(defun jbot-agent-select-personality (name)
  "Select personality NAME globally, with `auto' and `none' as alternatives."
  (interactive
   (list (completing-read
          "JBOT personality: "
          (append '("auto" "none")
                  (jbot-agent--available-personalities))
          nil t nil nil
          (cond ((eq jbot-agent-personality 'auto) "auto")
                ((null jbot-agent-personality) "none")
                (t jbot-agent-personality)))))
  (setq jbot-agent-personality
        (pcase name
          ("auto" 'auto)
          ("none" nil)
          (_ name)))
  (message "JBOT personality: %s"
           (if (eq jbot-agent-personality 'auto)
               "automatic"
             (or jbot-agent-personality "none"))))

(cl-defstruct (jbot-agent--review
               (:constructor jbot-agent--review-create))
  id
  title
  source-buffer
  source-tick
  original-buffer
  proposal-buffer
  diff-buffer
  findings-buffer
  frame
  window-configuration
  refresh-timer
  closed
  accepted)

(defun jbot-agent--base-url (url)
  "Return URL without trailing slashes."
  (replace-regexp-in-string "/+\\'" "" url))

(defun jbot-agent--endpoint (base path)
  "Join BASE and PATH into an endpoint URL."
  (concat (jbot-agent--base-url base) "/" (string-remove-prefix "/" path)))

(defun jbot-agent--set-status (&optional status)
  "Update the mode-line indicator to STATUS."
  (setq jbot-agent--mode-line-string
        (pcase status
          ('busy (format " JBOT[%d]" (length jbot-agent--active-request-buffers)))
          ('error " JBOT!")
          ('ready " JBOT✓")
          (_ " JBOT")))
  (force-mode-line-update t))

(defun jbot-agent--request-finished (buffer)
  "Remove request BUFFER from active request tracking."
  (when (memq buffer jbot-agent--active-request-buffers)
    (setq jbot-agent--active-request-buffers
          (delq buffer jbot-agent--active-request-buffers))
    (if jbot-agent--active-request-buffers
        (jbot-agent--set-status 'busy)
      (jbot-agent--set-status 'ready))))

(defun jbot-agent--request-buffer-killed ()
  "Clean request bookkeeping when the current URL buffer is killed."
  (when (timerp jbot-agent--request-timeout-timer)
    (cancel-timer jbot-agent--request-timeout-timer))
  (jbot-agent--request-finished (current-buffer)))

(defun jbot-agent--http-error-text (status-code)
  "Return a useful HTTP error description for STATUS-CODE in current buffer."
  (let ((body
         (when (and (boundp 'url-http-end-of-headers)
                    url-http-end-of-headers)
           (buffer-substring-no-properties
            url-http-end-of-headers
            (min (point-max) (+ url-http-end-of-headers 800))))))
    (format "HTTP %s%s"
            (or status-code "error")
            (if (string-empty-p (string-trim (or body "")))
                ""
              (format ": %s" (string-trim body))))))

(defun jbot-agent--http-json (method url data on-success on-error &optional timeout)
  "Asynchronously request JSON using METHOD at URL.

DATA is an Emacs Lisp object serialized as JSON, or nil.  Call ON-SUCCESS with
the parsed response.  Call ON-ERROR with a human-readable message.  TIMEOUT,
when non-nil, overrides `jbot-agent-request-timeout'."
  (let ((url-request-method method)
        (url-request-extra-headers
         (when data '(("Content-Type" . "application/json")
                      ("Accept" . "application/json"))))
        (url-request-data
         (when data (encode-coding-string (json-serialize data) 'utf-8)))
        request-buffer)
    (condition-case err
        (setq request-buffer
              (url-retrieve
               url
               (lambda (status)
                 (let ((buffer (current-buffer))
                       (cancelled jbot-agent--request-cancelled)
                       parsed failure)
                   (when (timerp jbot-agent--request-timeout-timer)
                     (cancel-timer jbot-agent--request-timeout-timer))
                   (unless cancelled
                     (setq failure
                           (if jbot-agent--request-timed-out
                               "Request timed out"
                             (plist-get status :error)))
                     (unless failure
                       (if (and (boundp 'url-http-response-status)
                                (>= (or url-http-response-status 500) 400))
                           (setq failure
                                 (jbot-agent--http-error-text
                                  url-http-response-status))
                         (condition-case parse-error
                             (progn
                               (goto-char
                                (or (and (boundp 'url-http-end-of-headers)
                                         url-http-end-of-headers)
                                    (point-min)))
                               (setq parsed
                                     (json-parse-buffer
                                      :object-type 'alist
                                      :array-type 'list
                                      :null-object nil
                                      :false-object :false)))
                           (error
                            (setq failure
                                  (error-message-string parse-error)))))))
                   (jbot-agent--request-finished buffer)
                   (unwind-protect
                       (unless cancelled
                         (if failure
                             (funcall on-error (format "%s" failure))
                           (funcall on-success parsed)))
                     (when (buffer-live-p buffer)
                       (kill-buffer buffer)))))
               nil t t))
      (error
       (funcall on-error (error-message-string err))))
    (when (buffer-live-p request-buffer)
      (push request-buffer jbot-agent--active-request-buffers)
      (with-current-buffer request-buffer
        (add-hook 'kill-buffer-hook #'jbot-agent--request-buffer-killed nil t)
        (setq-local
         jbot-agent--request-timeout-timer
         (run-at-time
          (or timeout jbot-agent-request-timeout) nil
          (lambda (buffer error-callback)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (setq jbot-agent--request-timed-out t))
              (let ((process (get-buffer-process buffer)))
                (when (process-live-p process)
                  (delete-process process)))
              ;; Deleting the process can synchronously invoke the URL
              ;; callback, which owns cleanup in that case.
              (when (buffer-live-p buffer)
                (jbot-agent--request-finished buffer)
                (kill-buffer buffer)
                (funcall error-callback "Request timed out"))))
          request-buffer on-error))))
    (when (buffer-live-p request-buffer)
      (jbot-agent--set-status 'busy))
    request-buffer))

(defun jbot-agent--report-error (message-text)
  "Report MESSAGE-TEXT as a JBOT error."
  (jbot-agent--set-status 'error)
  (message "JBOT: %s" message-text))

(defun jbot-agent-cancel ()
  "Cancel all active JBOT network requests."
  (interactive)
  (let ((count (length jbot-agent--active-request-buffers)))
    (dolist (buffer (copy-sequence jbot-agent--active-request-buffers))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq jbot-agent--request-cancelled t)
          (when (timerp jbot-agent--request-timeout-timer)
            (cancel-timer jbot-agent--request-timeout-timer)))
        (let ((process (get-buffer-process buffer)))
          (when (process-live-p process)
            (delete-process process)))
        (kill-buffer buffer)))
    (setq jbot-agent--active-request-buffers nil
          jbot-agent--chat-pending nil)
    (cl-incf jbot-agent--chat-generation)
    (jbot-agent--mark-pending-advice-cancelled)
    (jbot-agent--set-status 'ready)
    (message "JBOT: cancelled %d request%s" count (if (= count 1) "" "s"))))

(defun jbot-agent--models-from-response (response)
  "Extract model identifiers from an OpenAI-compatible RESPONSE."
  (delq nil
        (mapcar (lambda (entry) (alist-get 'id entry))
                (alist-get 'data response))))

(defun jbot-agent--list-models (base success error)
  "List models at BASE, calling SUCCESS or ERROR."
  (jbot-agent--http-json
   "GET" (jbot-agent--endpoint base "/v1/models") nil
   (lambda (response)
     (let ((models (jbot-agent--models-from-response response)))
       (if models
           (funcall success models)
         (funcall error "server returned no models"))))
   error 3))

(defun jbot-agent--with-model (function on-error)
  "Call FUNCTION with a model identifier and stable server URL.

Call ON-ERROR if automatic model discovery fails."
  (let ((server jbot-agent-server-url)
        (configured-model jbot-agent-model))
    (if (and (stringp configured-model)
             (not (string-empty-p configured-model)))
        (funcall function configured-model server)
      (jbot-agent--list-models
       server
       (lambda (models)
         (let ((model (car models)))
           (when (equal server jbot-agent-server-url)
             (setq jbot-agent-model model))
           (message "JBOT: using model %s" model)
           (funcall function model server)))
       (lambda (err)
         (funcall on-error
                  (format "cannot discover a model at %s: %s" server err)))))))

(defun jbot-agent--response-content (response)
  "Extract assistant text from chat completion RESPONSE."
  (let* ((choice (car (alist-get 'choices response)))
         (message-object (alist-get 'message choice))
         (content (alist-get 'content message-object))
         (reasoning (alist-get 'reasoning_content message-object)))
    (when (and (stringp content) (string-empty-p content)
               (stringp reasoning) (not (string-empty-p reasoning)))
      (error (concat
              "Model used its output budget for reasoning without a final answer; "
              "set `jbot-agent-reasoning-mode' to `disabled' or increase the token limit")))
    (unless (and (stringp content) (not (string-empty-p content)))
      (error "Server returned no assistant message"))
    content))

(defun jbot-agent--reasoning-request-field ()
  "Return the optional llama.cpp reasoning request field."
  (pcase jbot-agent-reasoning-mode
    ('disabled '((chat_template_kwargs . ((enable_thinking . :false)))))
    ('enabled '((chat_template_kwargs . ((enable_thinking . t)))))
    (_ nil)))

(defun jbot-agent--chat-completion
    (messages callback &optional max-tokens on-error)
  "Send MESSAGES and call CALLBACK with the assistant response text.

MAX-TOKENS overrides `jbot-agent-max-output-tokens'.  Call ON-ERROR after
reporting a transport or response error."
  (let ((error-handler
         (lambda (message-text)
           (jbot-agent--report-error message-text)
           (when on-error (funcall on-error message-text)))))
    (jbot-agent--with-model
   (lambda (model server)
     (jbot-agent--http-json
      "POST"
      (jbot-agent--endpoint server "/v1/chat/completions")
      (append
       `((model . ,model)
         ;; `json-serialize' treats a list as an object/alist.  The protocol
         ;; requires an array of message objects, represented by a vector.
         (messages . ,(vconcat messages)))
       (jbot-agent--reasoning-request-field)
       `((temperature . ,jbot-agent-temperature)
         (max_tokens . ,(or max-tokens jbot-agent-max-output-tokens))
         (stream . :false)))
      (lambda (response)
        (condition-case err
            (funcall callback (jbot-agent--response-content response))
          (error (funcall error-handler (error-message-string err)))))
      error-handler))
   error-handler)))

(defun jbot-agent-discover (&optional quiet)
  "Discover configured local model servers without scanning arbitrary ports.

With optional QUIET, do not display completion messages."
  (interactive)
  (setq jbot-agent--discovered-servers nil)
  (let* ((generation (cl-incf jbot-agent--discovery-generation))
         (urls (delete-dups
                (cons jbot-agent-server-url
                      (copy-sequence jbot-agent-discovery-urls))))
         (remaining (length urls))
         (configured jbot-agent-server-url))
    (cl-labels
        ((finish-one
          ()
          (when (= generation jbot-agent--discovery-generation)
            (setq remaining (1- remaining))
            (when (= remaining 0)
              (setq jbot-agent--discovered-servers
                    (sort jbot-agent--discovered-servers
                          (lambda (left right)
                            (< (cl-position (plist-get left :url) urls
                                            :test #'equal)
                               (cl-position (plist-get right :url) urls
                                            :test #'equal)))))
              (unless (or
                       ;; The user changed the endpoint while probes ran.
                       (not (equal jbot-agent-server-url configured))
                       (seq-find (lambda (entry)
                                   (equal (plist-get entry :url) configured))
                                 jbot-agent--discovered-servers))
                (when (and jbot-agent-auto-select-server
                           jbot-agent--discovered-servers)
                  (setq jbot-agent-server-url
                        (plist-get (car jbot-agent--discovered-servers) :url)
                        jbot-agent-model nil)))
              (jbot-agent--set-status
               (if jbot-agent--discovered-servers 'ready 'error))
              (unless quiet
                (message "JBOT: found %d local server%s"
                         (length jbot-agent--discovered-servers)
                         (if (= (length jbot-agent--discovered-servers) 1)
                             "" "s")))))))
      (dolist (url urls)
        ;; Each asynchronous callback needs its own binding.  The `dolist'
        ;; variable itself is reused and is nil after the loop finishes.
        (let ((candidate url))
          (jbot-agent--list-models
           candidate
           (lambda (models)
             (when (= generation jbot-agent--discovery-generation)
               (push (list :url candidate :models models)
                     jbot-agent--discovered-servers))
             (finish-one))
           (lambda (_error) (finish-one))))))))

(defun jbot-agent-select-server ()
  "Select a discovered or manually entered model server."
  (interactive)
  (let* ((known (delete-dups
                 (append (mapcar (lambda (entry) (plist-get entry :url))
                                 jbot-agent--discovered-servers)
                         (list jbot-agent-server-url)
                         jbot-agent-discovery-urls)))
         (selection
          (completing-read "JBOT server: " known nil nil
                           nil nil jbot-agent-server-url)))
    (cl-incf jbot-agent--discovery-generation)
    (setq jbot-agent-server-url (jbot-agent--base-url selection)
          jbot-agent-model nil)
    (message "JBOT: server set to %s" jbot-agent-server-url)))

(defun jbot-agent-select-model ()
  "Select a model exposed by the current server."
  (interactive)
  (let ((server jbot-agent-server-url))
    (jbot-agent--list-models
     server
     (lambda (models)
       ;; Defer minibuffer input out of the URL callback.
       (run-at-time
        0 nil
        (lambda ()
          (if (not (equal server jbot-agent-server-url))
              (message "JBOT: server changed; discarded stale model list")
            (setq jbot-agent-model
                  (completing-read "JBOT model: " models nil t nil nil
                                   jbot-agent-model))
            (message "JBOT: model set to %s" jbot-agent-model)))))
     #'jbot-agent--report-error)))

(defun jbot-agent--defun-bounds ()
  "Return bounds of the defun around point, or nil."
  (or (bounds-of-thing-at-point 'defun)
      (condition-case nil
          (save-excursion
            (end-of-defun)
            (let ((end (point)))
              (beginning-of-defun)
              (when (< (point) end)
                (cons (point) end))))
        (error nil))))

(defun jbot-agent--context (&optional scope)
  "Capture source context at point according to SCOPE.

SCOPE may be `file'.  Otherwise an active region, surrounding defun, or
paragraph is used, in that order."
  (let* ((buffer (current-buffer))
         (bounds
          (cond
           ((eq scope 'file)
            (save-restriction (widen) (cons (point-min) (point-max))))
           ((use-region-p) (cons (region-beginning) (region-end)))
           ((jbot-agent--defun-bounds))
           ((bounds-of-thing-at-point 'paragraph))
           (t (cons (line-beginning-position) (line-end-position)))))
         (beg (car bounds))
         (end (cdr bounds))
         text full-text)
    (save-restriction
      (widen)
      (setq text (buffer-substring-no-properties beg end)
            full-text (buffer-substring-no-properties (point-min) (point-max))))
    (when (> (length text) jbot-agent-max-context-chars)
      (user-error
       "JBOT context is %d characters; maximum is %d (customize `jbot-agent-max-context-chars')"
       (length text) jbot-agent-max-context-chars))
    (list :buffer buffer
          :buffer-name (buffer-name buffer)
          :file buffer-file-name
          :mode major-mode
          :beg beg
          :end end
          :text text
          :full-text full-text
          :tick (buffer-chars-modified-tick buffer)
          :scope (if (eq scope 'file) 'file
                   (if (use-region-p) 'region 'context)))))

(defun jbot-agent--language-name (context)
  "Return a language label suitable for prompts from CONTEXT."
  (string-remove-suffix "-mode" (symbol-name (plist-get context :mode))))

(defun jbot-agent--source-description (context)
  "Return a short source description for CONTEXT."
  (or (plist-get context :file) (plist-get context :buffer-name) "buffer"))

(define-derived-mode jbot-agent-response-mode special-mode "JBOT-Response"
  "Major mode for JBOT advice and explanations."
  (setq-local truncate-lines nil)
  (setq-local buffer-read-only t))

(define-key jbot-agent-response-mode-map (kbd "q") #'jbot-agent-response-close)
(define-key jbot-agent-response-mode-map (kbd "k") #'jbot-agent-response-cancel)

(defun jbot-agent--stop-response-timer (buffer)
  "Stop the status timer associated with response BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (timerp jbot-agent--response-timer)
        (cancel-timer jbot-agent--response-timer))
      (setq jbot-agent--response-timer nil))))

(defun jbot-agent--response-buffer-killed ()
  "Cancel the current response buffer's status timer before it is killed."
  (when (timerp jbot-agent--response-timer)
    (cancel-timer jbot-agent--response-timer)))

(defun jbot-agent-response-close ()
  "Close the current JBOT response pane or dedicated frame."
  (interactive)
  (let ((buffer (current-buffer))
        (frame jbot-agent--response-frame))
    (jbot-agent--stop-response-timer buffer)
    (if (and (frame-live-p frame) (> (length (frame-list)) 1))
        (progn
          (set-frame-parameter frame 'jbot-agent-response-buffer nil)
          (delete-frame frame))
      (quit-window nil))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(defun jbot-agent-response-cancel ()
  "Cancel active JBOT requests and mark the current advice as cancelled."
  (interactive)
  (jbot-agent-cancel))

(defun jbot-agent--render-advice-status (buffer)
  "Render current request status in advice BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (elapsed (if jbot-agent--response-started-at
                         (- (float-time) jbot-agent--response-started-at)
                       0.0))
            (context jbot-agent--response-context))
        (erase-buffer)
        (insert (propertize "JBOT advice" 'face 'jbot-agent-heading) "\n\n")
        (insert (propertize "Status: " 'face 'bold)
                "Waiting for the local model…\n")
        (insert (format "Server:  %s\n"
                        (or jbot-agent--response-server
                            jbot-agent-server-url)))
        (insert (format "Model:   %s\n" (or jbot-agent-model "discovering automatically")))
        (insert (format "Source:  %s\n" (jbot-agent--source-description context)))
        (insert (format "Context: %s\n" (jbot-agent--language-name context)))
        (insert (format "Persona: %s\n" (jbot-agent--personality-label context)))
        (insert (format "Elapsed: %.1f seconds\n\n" elapsed))
        (insert (propertize
                 "Emacs remains usable while llama.cpp generates the response.\n\n"
                 'face 'jbot-agent-muted))
        (insert-text-button
         "Cancel active JBOT requests"
         'follow-link t
         'action (lambda (_button)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (jbot-agent-response-cancel)))))
        (insert "    ")
        (insert-text-button
         "Close"
         'follow-link t
         'action (lambda (_button)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (jbot-agent-response-close)))))
        (goto-char (point-min))))))

(defun jbot-agent--start-advice-display (context &optional existing-buffer)
  "Create or reset a visible advice status display for CONTEXT.

Reuse EXISTING-BUFFER when it is live."
  (let* ((buffer (if (buffer-live-p existing-buffer)
                     existing-buffer
                   (generate-new-buffer "*JBOT Advice*")))
         (frame (and (buffer-live-p existing-buffer)
                     (buffer-local-value 'jbot-agent--response-frame
                                         existing-buffer))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'jbot-agent-response-mode)
        (jbot-agent-response-mode))
      (jbot-agent--stop-response-timer buffer)
      (setq-local jbot-agent--response-context context
                  jbot-agent--response-server jbot-agent-server-url
                  jbot-agent--response-started-at (float-time))
      (add-hook 'kill-buffer-hook #'jbot-agent--response-buffer-killed nil t))
    (unless (get-buffer-window buffer t)
      (when (and jbot-agent-advice-new-frame (display-graphic-p))
        (condition-case err
            (progn
              (setq frame (make-frame jbot-agent-advice-frame-parameters))
              (set-frame-parameter frame 'jbot-agent-response-buffer buffer)
              (with-selected-frame frame (switch-to-buffer buffer))
              (select-frame-set-input-focus frame))
          (error
           (message "JBOT: could not create advice frame: %s"
                    (error-message-string err))
           (when (frame-live-p frame) (delete-frame frame))
           (setq frame nil))))
      (unless frame
        (display-buffer-in-side-window
         buffer '((side . right) (slot . 0) (window-width . 0.38)))))
    (with-current-buffer buffer
      (setq-local jbot-agent--response-frame frame)
      (jbot-agent--render-advice-status buffer)
      (setq-local jbot-agent--response-timer
                  (run-at-time 1 1 #'jbot-agent--render-advice-status buffer)))
    buffer))

(defun jbot-agent--show-response (title text context &optional target-buffer)
  "Show response TEXT under TITLE for CONTEXT.

Update TARGET-BUFFER when it is live; otherwise use a side-window buffer."
  (let* ((existing (buffer-live-p target-buffer))
         (buffer (if existing target-buffer
                   (get-buffer-create "*JBOT Advice*"))))
    (jbot-agent--stop-response-timer buffer)
    (with-current-buffer buffer
      (unless (derived-mode-p 'jbot-agent-response-mode)
        (jbot-agent-response-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize title 'face 'jbot-agent-heading) "\n")
        (insert (propertize
                 (format "%s · %s · %s personality\n\n"
                         (jbot-agent--source-description context)
                         (jbot-agent--language-name context)
                         (jbot-agent--personality-label context))
                 'face 'jbot-agent-muted))
        (insert text)
        (unless (bolp) (insert "\n"))
        (insert "\n")
        (insert-text-button
         "Propose an improved version"
         'follow-link t
         'help-echo "Ask JBOT to generate a reviewable replacement"
         'action
         (lambda (_button)
           (unless (jbot-agent--context-current-p context)
             (user-error "Source changed; request fresh JBOT advice first"))
           (jbot-agent--request-improvement context)))
        (insert "    ")
        (insert-text-button
         "Close"
         'follow-link t
         'action (lambda (_button)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (jbot-agent-response-close)))))
        (setq-local jbot-agent--response-context context)
        (goto-char (point-min))))
    (unless (get-buffer-window buffer t)
      (display-buffer-in-side-window
       buffer '((side . right) (slot . 0) (window-width . 0.38))))
    buffer))

(defun jbot-agent--show-advice-error (buffer context message-text)
  "Show persistent advice error MESSAGE-TEXT in BUFFER for CONTEXT."
  (when (buffer-live-p buffer)
    (jbot-agent--stop-response-timer buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "JBOT advice" 'face 'jbot-agent-heading) "\n\n")
        (insert (propertize "Status: failed\n\n" 'face 'error))
        (insert message-text "\n\n")
        (insert-text-button
         "Retry"
         'follow-link t
         'action (lambda (_button)
                   (when (buffer-live-p buffer)
                     (jbot-agent--request-advice context buffer))))
        (insert "    ")
        (insert-text-button
         "Close"
         'follow-link t
         'action (lambda (_button)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (jbot-agent-response-close)))))
        (goto-char (point-min))))))

(defun jbot-agent--mark-pending-advice-cancelled ()
  "Replace all pending advice status displays with a cancelled state."
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (derived-mode-p 'jbot-agent-response-mode)
                   (timerp jbot-agent--response-timer)
                   jbot-agent--response-context)
          (jbot-agent--show-advice-error
           buffer jbot-agent--response-context "Request cancelled by user"))))))

(defun jbot-agent--advice-messages (context)
  "Build an advice request for CONTEXT."
  `(((role . "system") (content . ,(jbot-agent--effective-system-prompt context)))
    ((role . "user")
     (content .
              ,(format
                (concat
                 "Review the following %s code from %s. Explain the most "
                 "important correctness, clarity, maintainability, and "
                 "performance improvements. Do not rewrite the code yet. "
                 "Use short headings and actionable points.\n\n%s")
                (jbot-agent--language-name context)
                (jbot-agent--source-description context)
                (plist-get context :text))))))

;;;###autoload
(defun jbot-agent-advice ()
  "Review the active region or the function at point without editing it."
  (interactive)
  (jbot-agent--request-advice (jbot-agent--context)))

(defun jbot-agent--request-advice (context &optional existing-buffer)
  "Request advice for CONTEXT and update EXISTING-BUFFER when supplied."
  (let ((buffer (jbot-agent--start-advice-display context existing-buffer)))
    (message "JBOT: reviewing %s…" (jbot-agent--source-description context))
    (jbot-agent--chat-completion
     (jbot-agent--advice-messages context)
     (lambda (text)
       (when (buffer-live-p buffer)
         (jbot-agent--show-response "JBOT advice" text context buffer)))
     nil
     (lambda (message-text)
       (jbot-agent--show-advice-error buffer context message-text)))))

(defun jbot-agent--extract-section (text name)
  "Extract a sentinel-delimited NAME section from TEXT."
  (let* ((open (format "<JBOT_%s>" name))
         (close (format "</JBOT_%s>" name))
         (open-pos (string-match (regexp-quote open) text)))
    (when open-pos
      (let* ((start (+ open-pos (length open)))
             (start (cond
                     ((and (< (1+ start) (length text))
                           (= (aref text start) ?\r)
                           (= (aref text (1+ start)) ?\n))
                      (+ start 2))
                     ((and (< start (length text))
                           (= (aref text start) ?\n))
                      (1+ start))
                     (t start)))
             (close-pos (string-match (regexp-quote close) text start)))
        (when close-pos
          (let ((end close-pos))
            (cond
             ((and (> end (1+ start))
                   (= (aref text (- end 2)) ?\r)
                   (= (aref text (1- end)) ?\n))
              (setq end (- end 2)))
             ((and (> end start) (= (aref text (1- end)) ?\n))
              (setq end (1- end))))
            (substring text start end)))))))

(defun jbot-agent--context-current-p (context)
  "Return non-nil when CONTEXT still describes its live source buffer."
  (let ((buffer (plist-get context :buffer)))
    (and (buffer-live-p buffer)
         (with-current-buffer buffer
           (= (buffer-chars-modified-tick) (plist-get context :tick))))))

(defun jbot-agent--strip-code-fence (text)
  "Strip one surrounding Markdown code fence from TEXT."
  (let ((trimmed (string-trim text)))
    (if (string-match
         "\\````[^\n]*\n\\(\\(?:.\\|\n\\)*\\)\n```\\'" trimmed)
        (match-string 1 trimmed)
      ;; Whitespace is semantically significant in source.  Only the fenced
      ;; fallback path may discard wrapper whitespace.
      text)))

(defun jbot-agent--normalize-final-newline (replacement original)
  "Make REPLACEMENT's final-newline convention match ORIGINAL."
  (cond
   ((and (string-suffix-p "\n" original)
         (not (string-suffix-p "\n" replacement)))
    (concat replacement "\n"))
   ((and (not (string-suffix-p "\n" original))
         (string-suffix-p "\n" replacement))
    (string-remove-suffix "\n" replacement))
   (t replacement)))

(defun jbot-agent--improvement-messages (context &optional file-review)
  "Build an edit request for CONTEXT.

When FILE-REVIEW is non-nil, request a complete file review."
  `(((role . "system")
     (content .
              ,(concat
                (jbot-agent--effective-system-prompt context)
                " Return the requested sentinel sections exactly. Do not use Markdown fences.")))
    ((role . "user")
     (content .
              ,(format
                (if file-review
                    (concat
                     "Review this complete %s file from %s. Return two sections. "
                     "JBOT_FINDINGS must contain a concise prioritized review. "
                     "JBOT_REPLACEMENT must contain the complete revised file, "
                     "with no omissions or placeholders. Keep changes focused.\n\n"
                     "<JBOT_FINDINGS>\nfindings\n</JBOT_FINDINGS>\n"
                     "<JBOT_REPLACEMENT>\ncomplete revised file\n</JBOT_REPLACEMENT>\n\n"
                     "SOURCE:\n%s")
                  (concat
                   "Improve the following %s code from %s. Preserve its intended "
                   "behavior and local style. Return a short explanation and the "
                   "exact replacement, using these sections:\n\n"
                   "<JBOT_FINDINGS>\nexplanation\n</JBOT_FINDINGS>\n"
                   "<JBOT_REPLACEMENT>\nreplacement code only\n</JBOT_REPLACEMENT>\n\n"
                   "SOURCE:\n%s"))
                (jbot-agent--language-name context)
                (jbot-agent--source-description context)
                (plist-get context :text))))))

(defun jbot-agent--edit-response (text context title new-frame)
  "Turn model response TEXT for CONTEXT into a review named TITLE.

NEW-FRAME controls whether the review requests a dedicated frame."
  (let ((replacement (jbot-agent--extract-section text "REPLACEMENT"))
        (findings (or (jbot-agent--extract-section text "FINDINGS")
                      "No separate findings were returned.")))
    (if (not replacement)
        (jbot-agent--show-response
         "JBOT returned an unstructured edit"
         (concat
          "The model did not return the required <JBOT_REPLACEMENT> section. "
          "Nothing was changed.\n\n" text)
         context)
      (unless (jbot-agent--context-current-p context)
        (user-error
         "Source changed while JBOT was working; request a fresh proposal"))
      (setq replacement
            (jbot-agent--normalize-final-newline
             (jbot-agent--strip-code-fence replacement)
             (plist-get context :text)))
      (jbot-agent--open-review context replacement findings title new-frame))))

(defun jbot-agent--request-improvement (context &optional file-review new-frame)
  "Request a proposed improvement for CONTEXT.

FILE-REVIEW requests findings for a complete file.  NEW-FRAME controls review
display."
  (message "JBOT: generating a reviewable proposal…")
  (jbot-agent--chat-completion
   (jbot-agent--improvement-messages context file-review)
   (lambda (text)
     (jbot-agent--edit-response
      text context
      (if file-review "File review" "Proposed improvement")
      new-frame))
   (if file-review
       jbot-agent-file-review-max-output-tokens
     jbot-agent-max-output-tokens)))

;;;###autoload
(defun jbot-agent-improve ()
  "Propose an improvement for the active region or function at point."
  (interactive)
  (jbot-agent--request-improvement (jbot-agent--context) nil nil))

;;;###autoload
(defun jbot-agent-review-file ()
  "Review the current file in a dedicated review workspace."
  (interactive)
  (jbot-agent--request-improvement
   (jbot-agent--context 'file) t jbot-agent-review-new-frame))

(define-derived-mode jbot-agent-findings-mode special-mode "JBOT-Findings"
  "Major mode for the findings pane of a JBOT review."
  (setq-local truncate-lines nil))

(defvar jbot-agent-review-control-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'jbot-agent-review-accept)
    (define-key map (kbd "C-c C-k") #'jbot-agent-review-reject)
    (define-key map (kbd "C-c C-d") #'jbot-agent-review-refresh-diff)
    map)
  "Keymap shared by buffers in a JBOT review workspace.")

(define-minor-mode jbot-agent-review-control-mode
  "Minor mode providing review controls in JBOT workspace buffers."
  :lighter " Review"
  :keymap jbot-agent-review-control-mode-map)

(defun jbot-agent--put-review-help (buffer session)
  "Associate BUFFER with review SESSION and enable review controls."
  (with-current-buffer buffer
    (setq-local jbot-agent--review-session session)
    (jbot-agent-review-control-mode 1)))

(defun jbot-agent--prepare-code-buffer (buffer text mode directory read-only)
  "Prepare BUFFER with TEXT, MODE, DIRECTORY, and READ-ONLY state."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert text)
      (setq default-directory directory)
      (delay-mode-hooks (funcall mode))
      (setq buffer-read-only read-only)
      (set-buffer-modified-p nil)
      (goto-char (point-min)))))

(defun jbot-agent--proposal-changed (&rest _ignored)
  "Schedule a diff refresh after a proposal buffer changes."
  (when jbot-agent--review-session
    (let ((old (jbot-agent--review-refresh-timer jbot-agent--review-session)))
      (when (timerp old) (cancel-timer old))
      (setf (jbot-agent--review-refresh-timer jbot-agent--review-session)
            (run-with-idle-timer
             0.35 nil #'jbot-agent--refresh-session-diff
             jbot-agent--review-session)))))

(defun jbot-agent--refresh-session-diff (session)
  "Regenerate the diff buffer belonging to SESSION."
  (when (and (buffer-live-p (jbot-agent--review-original-buffer session))
             (buffer-live-p (jbot-agent--review-proposal-buffer session))
             (buffer-live-p (jbot-agent--review-diff-buffer session)))
    (let ((diff-buffer (jbot-agent--review-diff-buffer session))
          (windows nil))
      (dolist (window (get-buffer-window-list diff-buffer nil t))
        (push (cons window (window-start window)) windows))
      (diff-no-select
       (jbot-agent--review-original-buffer session)
       (jbot-agent--review-proposal-buffer session)
       jbot-agent-diff-switches t diff-buffer)
      (jbot-agent--put-review-help diff-buffer session)
      (dolist (entry windows)
        (when (window-live-p (car entry))
          (set-window-start (car entry) (cdr entry) t))))))

(defun jbot-agent-review-refresh-diff ()
  "Immediately regenerate the current review's diff."
  (interactive)
  (unless jbot-agent--review-session
    (user-error "This buffer is not part of a JBOT review"))
  (jbot-agent--refresh-session-diff jbot-agent--review-session)
  (message "JBOT: diff refreshed"))

(defun jbot-agent--review-layout (session frame)
  "Install review SESSION's window layout in FRAME."
  (with-selected-frame frame
    (delete-other-windows)
    (let* ((top-left (selected-window))
           (total-height (window-total-height top-left))
           (diff-height (max 9 (floor (* total-height 0.30))))
           (bottom (split-window top-left (- diff-height) 'below))
           (total-width (window-total-width top-left))
           (source-width (max 30 (floor (* total-width 0.34))))
           (middle (split-window top-left source-width 'right))
           (middle-width (window-total-width middle))
           (proposal-width (max 30 (floor (* middle-width 0.62))))
           (right (split-window middle proposal-width 'right)))
      (set-window-buffer top-left (jbot-agent--review-original-buffer session))
      (set-window-buffer middle (jbot-agent--review-proposal-buffer session))
      (set-window-buffer right (jbot-agent--review-findings-buffer session))
      (set-window-buffer bottom (jbot-agent--review-diff-buffer session))
      (select-window middle))))

(defun jbot-agent--display-review (session request-new-frame)
  "Display SESSION, using a new frame when REQUEST-NEW-FRAME permits it."
  (let ((origin-frame (selected-frame))
        frame)
    (when (and request-new-frame (display-graphic-p))
      (condition-case err
          (progn
            (setq frame (make-frame jbot-agent-review-frame-parameters))
            (setf (jbot-agent--review-frame session) frame)
            (set-frame-parameter frame 'jbot-agent-review-session session)
            (jbot-agent--review-layout session frame)
            (select-frame-set-input-focus frame))
        (error
         (message "JBOT: dedicated review frame failed, using current frame: %s"
                  (error-message-string err))
         (when (frame-live-p frame)
           (set-frame-parameter frame 'jbot-agent-review-session nil)
           (delete-frame frame))
         (setf (jbot-agent--review-frame session) nil
               frame nil))))
    (unless frame
      (with-selected-frame origin-frame
        (setf (jbot-agent--review-window-configuration session)
              (current-window-configuration))
        (condition-case nil
            (jbot-agent--review-layout session origin-frame)
          (error
           (delete-other-windows)
           (switch-to-buffer (jbot-agent--review-proposal-buffer session))
           (display-buffer-in-side-window
            (jbot-agent--review-diff-buffer session)
            '((side . bottom) (window-height . 0.35)))))))))

(defun jbot-agent--dispose-review-buffers (session)
  "Cancel timers and kill temporary buffers belonging to SESSION."
  (unless (jbot-agent--review-closed session)
    (setf (jbot-agent--review-closed session) t)
    (let ((timer (jbot-agent--review-refresh-timer session)))
      (when (timerp timer) (cancel-timer timer)))
    (dolist (buffer (list (jbot-agent--review-original-buffer session)
                          (jbot-agent--review-proposal-buffer session)
                          (jbot-agent--review-diff-buffer session)
                          (jbot-agent--review-findings-buffer session)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(defun jbot-agent--review-frame-deleted (frame)
  "Dispose of JBOT buffers when FRAME is deleted externally."
  (when-let* ((session (frame-parameter frame 'jbot-agent-review-session)))
    (set-frame-parameter frame 'jbot-agent-review-session nil)
    (setf (jbot-agent--review-frame session) nil)
    (jbot-agent--dispose-review-buffers session))
  (when-let* ((buffer (frame-parameter frame 'jbot-agent-response-buffer)))
    (set-frame-parameter frame 'jbot-agent-response-buffer nil)
    (when (buffer-live-p buffer)
      (jbot-agent--stop-response-timer buffer)
      (kill-buffer buffer))))

(add-hook 'delete-frame-functions #'jbot-agent--review-frame-deleted)

(defun jbot-agent--open-review (context replacement findings title new-frame)
  "Open a review for CONTEXT with REPLACEMENT and FINDINGS.

TITLE names the review.  NEW-FRAME requests a dedicated frame."
  (let* ((id (cl-incf jbot-agent--review-counter))
         (source (plist-get context :buffer))
         (full-text (plist-get context :full-text))
         (beg (plist-get context :beg))
         (end (plist-get context :end))
         (mode (plist-get context :mode))
         (directory (with-current-buffer source default-directory))
         (original (generate-new-buffer (format "*JBOT Original %d*" id)))
         (proposal (generate-new-buffer (format "*JBOT Proposal %d*" id)))
         (diff-buffer (generate-new-buffer (format "*JBOT Diff %d*" id)))
         (findings-buffer (generate-new-buffer (format "*JBOT Findings %d*" id)))
         (session
          (jbot-agent--review-create
           :id id :title title :source-buffer source
           :source-tick (plist-get context :tick)
           :original-buffer original :proposal-buffer proposal
           :diff-buffer diff-buffer :findings-buffer findings-buffer)))
    (condition-case err
        (progn
          (jbot-agent--prepare-code-buffer original full-text mode directory t)
          (jbot-agent--prepare-code-buffer proposal full-text mode directory nil)
          (with-current-buffer proposal
            (let ((inhibit-read-only t))
              (delete-region beg end)
              (goto-char beg)
              (insert replacement)
              (set-buffer-modified-p nil))
            (setq-local jbot-agent--review-session session)
            (add-hook 'after-change-functions #'jbot-agent--proposal-changed nil t))
          (with-current-buffer findings-buffer
            (let ((inhibit-read-only t))
              (insert (propertize title 'face 'jbot-agent-heading) "\n\n")
              (insert findings)
              (unless (bolp) (insert "\n"))
              (insert "\n")
              (insert (propertize
                       "C-c C-c apply · C-c C-k reject · C-c C-d refresh diff\n"
                       'face 'jbot-agent-muted))
              (jbot-agent-findings-mode)))
          (dolist (buffer (list original proposal findings-buffer diff-buffer))
            (jbot-agent--put-review-help buffer session))
          (jbot-agent--refresh-session-diff session)
          (jbot-agent--display-review session new-frame)
          session)
      (error
       (jbot-agent--dispose-review-buffers session)
       (signal (car err) (cdr err))))))

(defun jbot-agent--session-current ()
  "Return the review session associated with the current buffer."
  (or jbot-agent--review-session
      (user-error "This buffer is not part of a JBOT review")))

(defun jbot-agent--cleanup-review (session)
  "Close and dispose of review SESSION."
  (let ((timer (jbot-agent--review-refresh-timer session))
        (frame (jbot-agent--review-frame session))
        (configuration (jbot-agent--review-window-configuration session)))
    (when (timerp timer) (cancel-timer timer))
    (cond
     ((and (frame-live-p frame) (> (length (frame-list)) 1))
      (set-frame-parameter frame 'jbot-agent-review-session nil)
      (delete-frame frame))
     ((window-configuration-p configuration)
      (condition-case nil
          (set-window-configuration configuration)
        (error nil))))
    (jbot-agent--dispose-review-buffers session)))

(defun jbot-agent-review-accept ()
  "Apply the current proposal as one undoable change."
  (interactive)
  (let* ((session (jbot-agent--session-current))
         (source (jbot-agent--review-source-buffer session))
         (proposal (jbot-agent--review-proposal-buffer session))
         proposal-text)
    (unless (buffer-live-p source)
      (user-error "The source buffer no longer exists"))
    (unless (buffer-live-p proposal)
      (user-error "The proposal buffer no longer exists"))
    (setq proposal-text
          (with-current-buffer proposal
            (buffer-substring-no-properties (point-min) (point-max))))
    (with-current-buffer source
      (unless (= (buffer-chars-modified-tick)
                 (jbot-agent--review-source-tick session))
        (user-error
         "Source changed after this request; reject and request a fresh review"))
      (let ((inhibit-read-only nil))
        (undo-boundary)
        (atomic-change-group
          (save-restriction
            (widen)
            (delete-region (point-min) (point-max))
            (insert proposal-text)))
        (undo-boundary)))
    (setf (jbot-agent--review-accepted session) t)
    (jbot-agent--cleanup-review session)
    (message "JBOT: proposal applied; use `undo' to revert")))

(defun jbot-agent-review-reject ()
  "Reject and close the current review without changing its source."
  (interactive)
  (let ((session (jbot-agent--session-current)))
    (when (yes-or-no-p "Reject this JBOT proposal? ")
      (jbot-agent--cleanup-review session)
      (message "JBOT: proposal rejected"))))

(define-derived-mode jbot-agent-chat-mode special-mode "JBOT-Chat"
  "Major mode for JBOT conversations."
  (setq-local truncate-lines nil))

(defun jbot-agent--chat-buffer ()
  "Return the JBOT chat buffer, creating it if needed."
  (let ((buffer (get-buffer-create "*JBOT Chat*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'jbot-agent-chat-mode)
        (jbot-agent-chat-mode)
        (let ((inhibit-read-only t))
          (insert (propertize "JBOT chat\n" 'face 'jbot-agent-heading)
                  (propertize
                   "Use M-x jbot-agent-chat to send another message.\n\n"
                   'face 'jbot-agent-muted)))))
    buffer))

(defun jbot-agent--chat-insert (buffer heading text &optional face)
  "Append HEADING and TEXT to chat BUFFER, using FACE for the heading."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (propertize (concat heading "\n")
                            'face (or face 'jbot-agent-heading))
                text "\n\n")))))

;;;###autoload
(defun jbot-agent-chat (prompt)
  "Send PROMPT to the local model and display the conversation."
  (interactive
   (list (read-string "JBOT: " nil 'jbot-agent--chat-history)))
  (when (string-empty-p (string-trim prompt))
    (user-error "Prompt is empty"))
  (when jbot-agent--chat-pending
    (user-error "A JBOT chat response is still pending; cancel it or wait"))
  (let ((context (list :file buffer-file-name
                       :buffer-name (buffer-name)
                       :mode major-mode
                       :text ""))
        (buffer (jbot-agent--chat-buffer))
        (generation jbot-agent--chat-generation))
    (setq jbot-agent--chat-pending t)
    (setq jbot-agent--chat-messages
          (append jbot-agent--chat-messages
                  `(((role . "user") (content . ,prompt)))))
    (jbot-agent--chat-insert buffer "You" prompt)
    (display-buffer buffer)
    (jbot-agent--chat-completion
     (cons `((role . "system")
             (content . ,(jbot-agent--effective-system-prompt context)))
           jbot-agent--chat-messages)
     (lambda (text)
       (when (= generation jbot-agent--chat-generation)
         (setq jbot-agent--chat-pending nil
               jbot-agent--chat-messages
               (append jbot-agent--chat-messages
                       `(((role . "assistant") (content . ,text)))))
         (jbot-agent--chat-insert buffer "JBOT" text)))
     nil
     (lambda (message-text)
       (when (= generation jbot-agent--chat-generation)
         (setq jbot-agent--chat-pending nil)
         (jbot-agent--chat-insert buffer "JBOT error" message-text 'error))))))

(defun jbot-agent-chat-reset ()
  "Clear the current JBOT conversation."
  (interactive)
  (cl-incf jbot-agent--chat-generation)
  (setq jbot-agent--chat-messages nil
        jbot-agent--chat-pending nil)
  (when-let* ((buffer (get-buffer "*JBOT Chat*")))
    (kill-buffer buffer))
  (message "JBOT: chat reset"))

(defun jbot-agent-status ()
  "Display current JBOT server, model, personality, and request status."
  (interactive)
  (let ((buffer (get-buffer-create "*JBOT Status*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "JBOT status\n\n" 'face 'jbot-agent-heading))
        (insert (format "Server:      %s\nModel:       %s\nPersonality: %s\nActive:      %d\n\n"
                        jbot-agent-server-url
                        (or jbot-agent-model "automatic")
                        (cond ((eq jbot-agent-personality 'auto) "automatic")
                              ((null jbot-agent-personality) "none")
                              (t jbot-agent-personality))
                        (length jbot-agent--active-request-buffers)))
        (insert (propertize "Discovered servers\n" 'face 'jbot-agent-heading))
        (if jbot-agent--discovered-servers
            (dolist (entry jbot-agent--discovered-servers)
              (insert (format "  %s\n    %s\n"
                              (plist-get entry :url)
                              (string-join (plist-get entry :models) ", "))))
          (insert "  None discovered yet. Run M-x jbot-agent-discover.\n"))
        (jbot-agent-response-mode)
        (goto-char (point-min))))
    (display-buffer buffer)))

;;;###autoload
(define-minor-mode jbot-agent-mode
  "Global mode for local server discovery and JBOT status reporting."
  :global t
  :group 'jbot-agent
  (if jbot-agent-mode
      (progn
        (add-to-list 'global-mode-string 'jbot-agent--mode-line-string t)
        (when (timerp jbot-agent--discovery-timer)
          (cancel-timer jbot-agent--discovery-timer))
        (setq jbot-agent--discovery-timer
              (run-with-idle-timer jbot-agent-discovery-delay nil
                                   #'jbot-agent-discover t)))
    (when (timerp jbot-agent--discovery-timer)
      (cancel-timer jbot-agent--discovery-timer))
    (setq jbot-agent--discovery-timer nil
          global-mode-string
          (delq 'jbot-agent--mode-line-string global-mode-string))))

(defun jbot-agent-unload-function ()
  "Remove JBOT timers, requests, and global hooks before unloading."
  (when jbot-agent-mode (jbot-agent-mode -1))
  (when jbot-agent--active-request-buffers (jbot-agent-cancel))
  (remove-hook 'delete-frame-functions #'jbot-agent--review-frame-deleted)
  nil)

(provide 'jbot-agent)

;;; jbot-agent.el ends here
