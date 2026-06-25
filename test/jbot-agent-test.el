;;; jbot-agent-test.el --- Tests for jbot-agent -*- lexical-binding: t; -*-

(require 'ert)
(require 'jbot-agent)

(ert-deftest jbot-agent-test-endpoint ()
  (should (equal (jbot-agent--endpoint "http://localhost:8080/" "/v1/models")
                 "http://localhost:8080/v1/models")))

(ert-deftest jbot-agent-test-packaged-personalities-have-system-prompts ()
  (let ((names '("cpp" "julia" "elisp" "python" "metamodelica")))
    (dolist (name names)
      (let ((prompt
             (jbot-agent--modelfile-system-prompt
              (jbot-agent--personality-file name))))
        (should (> (length prompt) 200))))))

(ert-deftest jbot-agent-test-personality-auto-selection ()
  (let ((jbot-agent-personality 'auto))
    (should (equal
             (jbot-agent--personality-for-context
              '(:mode emacs-lisp-mode :text ""))
             "elisp"))
    (should (equal
             (jbot-agent--personality-for-context
              '(:mode modelica-mode :text "uniontype Expression"))
             "metamodelica"))
    (should-not
     (jbot-agent--personality-for-context
      '(:mode modelica-mode :text "algorithm\n  x := x + 1;")))))

(ert-deftest jbot-agent-test-effective-system-prompt-includes-personality ()
  (let ((jbot-agent-personality "python")
        (jbot-agent-system-prompt "base prompt"))
    (let ((prompt
           (jbot-agent--effective-system-prompt '(:mode fundamental-mode))))
      (should (string-prefix-p "base prompt\n\n" prompt))
      (should (string-match-p "Python specialist" prompt)))))

(ert-deftest jbot-agent-test-personality-name-rejects-path-traversal ()
  (should-error (jbot-agent--personality-file "../private")))

(ert-deftest jbot-agent-test-extract-section ()
  (let ((text (concat "prefix\n<JBOT_FINDINGS>\nUseful note\n</JBOT_FINDINGS>\n"
                      "<JBOT_REPLACEMENT>\n(defun x () 1)\n"
                      "</JBOT_REPLACEMENT>\nsuffix")))
    (should (equal (jbot-agent--extract-section text "FINDINGS") "Useful note"))
    (should (equal (jbot-agent--extract-section text "REPLACEMENT")
                   "(defun x () 1)"))))

(ert-deftest jbot-agent-test-extract-section-handles-crlf-wrappers ()
  (should
   (equal
    (jbot-agent--extract-section
     "<JBOT_REPLACEMENT>\r\nline one\r\nline two\r\n</JBOT_REPLACEMENT>"
     "REPLACEMENT")
    "line one\r\nline two")))

(ert-deftest jbot-agent-test-normalize-final-newline ()
  (should (equal (jbot-agent--normalize-final-newline "a" "old\n") "a\n"))
  (should (equal (jbot-agent--normalize-final-newline "a\n" "old") "a")))

(ert-deftest jbot-agent-test-response-cleanup-preserves-indentation ()
  (should (equal (jbot-agent--strip-code-fence "  indented-call()  ")
                 "  indented-call()  ")))

(ert-deftest jbot-agent-test-response-cleanup-removes-code-fence ()
  (should (equal (jbot-agent--strip-code-fence
                  "```elisp\n(message \"ok\")\n```")
                 "(message \"ok\")")))

(ert-deftest jbot-agent-test-context-prefers-region ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun example ()\n  (+ 1 2))\n")
    (goto-char 8)
    (set-mark 14)
    (activate-mark)
    (let ((context (jbot-agent--context)))
      (should (eq (plist-get context :scope) 'region))
      (should (equal (plist-get context :text)
                     (buffer-substring-no-properties
                      (region-beginning) (region-end)))))))

(ert-deftest jbot-agent-test-advice-status-precedes-response ()
  (let ((jbot-agent-advice-new-frame nil)
        status-observed
        advice-buffer)
    (save-window-excursion
      (with-temp-buffer
        (emacs-lisp-mode)
        (insert "(defun sample () t)\n")
        (goto-char 10)
        (cl-letf (((symbol-function 'jbot-agent--chat-completion)
                   (lambda (_messages success &rest _args)
                     (setq advice-buffer (get-buffer "*JBOT Advice*"))
                     (setq status-observed
                           (and advice-buffer
                                (with-current-buffer advice-buffer
                                  (string-match-p
                                   "Waiting for the local model"
                                   (buffer-string)))))
                     (funcall success "Completed advice"))))
          (jbot-agent-advice)))
      (unwind-protect
          (progn
            (should status-observed)
            (should (buffer-live-p advice-buffer))
            (with-current-buffer advice-buffer
              (should (string-match-p "Completed advice" (buffer-string)))
              (should-not (timerp jbot-agent--response-timer))))
        (when (buffer-live-p advice-buffer)
          (kill-buffer advice-buffer))))))

(ert-deftest jbot-agent-test-advice-error-stops-status-timer ()
  (let ((jbot-agent-advice-new-frame nil)
        advice-buffer)
    (save-window-excursion
      (with-temp-buffer
        (insert "source\n")
        (let ((context (jbot-agent--context 'file)))
          (setq advice-buffer (jbot-agent--start-advice-display context))
          (jbot-agent--show-advice-error advice-buffer context "server failed")))
      (unwind-protect
          (with-current-buffer advice-buffer
            (should (string-match-p "Status: failed" (buffer-string)))
            (should (string-match-p "server failed" (buffer-string)))
            (should-not (timerp jbot-agent--response-timer)))
        (when (buffer-live-p advice-buffer)
          (kill-buffer advice-buffer))))))

(ert-deftest jbot-agent-test-global-cancel-updates-advice-status ()
  (let ((jbot-agent-advice-new-frame nil)
        (jbot-agent--active-request-buffers nil)
        advice-buffer)
    (save-window-excursion
      (with-temp-buffer
        (insert "source\n")
        (setq advice-buffer
              (jbot-agent--start-advice-display
               (jbot-agent--context 'file))))
      (unwind-protect
          (progn
            (jbot-agent-cancel)
            (with-current-buffer advice-buffer
              (should (string-match-p "Request cancelled by user"
                                      (buffer-string)))
              (should-not (timerp jbot-agent--response-timer))))
        (when (buffer-live-p advice-buffer)
          (kill-buffer advice-buffer))))))

(ert-deftest jbot-agent-test-model-response ()
  (should
   (equal
    (jbot-agent--response-content
     '((choices . (((message . ((content . "hello"))))))))
    "hello")))

(ert-deftest jbot-agent-test-chat-request-messages-serialize-as-array ()
  (let (captured)
    (cl-letf (((symbol-function 'jbot-agent--with-model)
               (lambda (callback _on-error)
                 (funcall callback "test-model" "http://test.invalid")))
              ((symbol-function 'jbot-agent--http-json)
               (lambda (_method _url data _success _error &optional _timeout)
                 (setq captured data))))
      (jbot-agent--chat-completion
       '(((role . "user") (content . "hello"))) #'ignore))
    (let ((messages (alist-get 'messages captured)))
      (should (equal (alist-get 'model captured) "test-model"))
      (should (vectorp messages))
      (should (= (length messages) 1))
      (should (equal (aref messages 0)
                     '((role . "user") (content . "hello"))))
      (should (eq
               (alist-get 'enable_thinking
                          (alist-get 'chat_template_kwargs captured))
               :false))
      (should (= (alist-get 'temperature captured) 0.2))
      (should (= (alist-get 'max_tokens captured) 4096))
      (should (eq (alist-get 'stream captured) :false)))))

(ert-deftest jbot-agent-test-reasoning-without-answer-is-an-error ()
  (should-error
   (jbot-agent--response-content
    '((choices . (((message . ((content . "")
                               (reasoning_content . "unfinished reasoning"))))))))
   :type 'error))

(ert-deftest jbot-agent-test-review-applies-proposal ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun old () 1)\n")
    (let* ((source (current-buffer))
           (context (jbot-agent--context 'file))
           session)
      (cl-letf (((symbol-function 'jbot-agent--display-review)
                 (lambda (_session _new-frame))))
        (setq session
              (jbot-agent--open-review
               context "(defun improved () 2)\n" "One finding" "Test" nil)))
      (with-current-buffer (jbot-agent--review-proposal-buffer session)
        (jbot-agent-review-accept))
      (should (equal (with-current-buffer source (buffer-string))
                     "(defun improved () 2)\n")))))

(ert-deftest jbot-agent-test-review-refuses-stale-source ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "old\n")
    (let* ((context (jbot-agent--context 'file))
           session)
      (cl-letf (((symbol-function 'jbot-agent--display-review)
                 (lambda (_session _new-frame))))
        (setq session
              (jbot-agent--open-review context "new\n" "Finding" "Test" nil)))
      (goto-char (point-max))
      (insert "changed\n")
      (unwind-protect
          (with-current-buffer (jbot-agent--review-proposal-buffer session)
            (should-error (jbot-agent-review-accept) :type 'user-error))
        (jbot-agent--cleanup-review session)))))

(ert-deftest jbot-agent-test-asynchronous-server-discovery-keeps-url ()
  (let ((jbot-agent-server-url "http://127.0.0.1:8080")
        (jbot-agent-discovery-urls
         '("http://127.0.0.1:8080" "http://127.0.0.1:1234"))
        (jbot-agent-auto-select-server t)
        (jbot-agent--discovered-servers nil)
        callbacks)
    (cl-letf (((symbol-function 'jbot-agent--list-models)
               (lambda (url success error)
                 (push (list url success error) callbacks))))
      (jbot-agent-discover t))
    (let ((llama (assoc "http://127.0.0.1:8080" callbacks))
          (studio (assoc "http://127.0.0.1:1234" callbacks)))
      (funcall (nth 2 llama) "offline")
      (funcall (nth 1 studio) '("local-model")))
    (should
     (equal (plist-get (car jbot-agent--discovered-servers) :url)
            "http://127.0.0.1:1234"))
    (should (equal jbot-agent-server-url "http://127.0.0.1:1234"))))

(ert-deftest jbot-agent-test-stale-server-discovery-is-ignored ()
  (let ((jbot-agent-server-url "http://one.invalid")
        (jbot-agent-discovery-urls '("http://one.invalid"))
        (jbot-agent--discovery-generation 0)
        (jbot-agent--discovered-servers nil)
        first second callbacks)
    (cl-letf (((symbol-function 'jbot-agent--list-models)
               (lambda (url success error)
                 (push (list url success error) callbacks))))
      (jbot-agent-discover t)
      (setq first callbacks callbacks nil)
      (jbot-agent-discover t)
      (setq second callbacks)
      (funcall (nth 1 (car first)) '("stale-model"))
      (should-not jbot-agent--discovered-servers)
      (funcall (nth 1 (car second)) '("current-model")))
    (should (equal (plist-get (car jbot-agent--discovered-servers) :models)
                   '("current-model")))))

(ert-deftest jbot-agent-test-discovery-does-not-override-manual-server-change ()
  (let ((jbot-agent-server-url "http://configured.invalid")
        (jbot-agent-discovery-urls
         '("http://configured.invalid" "http://fallback.invalid"))
        (jbot-agent-auto-select-server t)
        (jbot-agent--discovery-generation 0)
        callbacks)
    (cl-letf (((symbol-function 'jbot-agent--list-models)
               (lambda (url success error)
                 (push (list url success error) callbacks))))
      (jbot-agent-discover t)
      (setq jbot-agent-server-url "http://manual.invalid")
      (let ((configured (assoc "http://configured.invalid" callbacks))
            (fallback (assoc "http://fallback.invalid" callbacks)))
        (funcall (nth 2 configured) "offline")
        (funcall (nth 1 fallback) '("fallback-model"))))
    (should (equal jbot-agent-server-url "http://manual.invalid"))))

(ert-deftest jbot-agent-test-model-selection-discards-stale-server-list ()
  (let ((jbot-agent-server-url "http://old.invalid")
        list-callback
        prompted)
    (cl-letf (((symbol-function 'jbot-agent--list-models)
               (lambda (_url success _error) (setq list-callback success)))
              ((symbol-function 'run-at-time)
               (lambda (_time _repeat function &rest args)
                 (apply function args)))
              ((symbol-function 'completing-read)
               (lambda (&rest _args) (setq prompted t) "model")))
      (jbot-agent-select-model)
      (setq jbot-agent-server-url "http://new.invalid")
      (funcall list-callback '("old-model")))
    (should-not prompted)))

(ert-deftest jbot-agent-test-model-discovery-keeps-original-server ()
  (let ((jbot-agent-server-url "http://original.invalid")
        (jbot-agent-model nil)
        model-callback result)
    (cl-letf (((symbol-function 'jbot-agent--list-models)
               (lambda (_server success _error)
                 (setq model-callback success))))
      (jbot-agent--with-model
       (lambda (model server) (setq result (list model server))) #'ignore)
      (setq jbot-agent-server-url "http://changed.invalid")
      (funcall model-callback '("original-model")))
    (should (equal result '("original-model" "http://original.invalid")))
    (should-not jbot-agent-model)))

(ert-deftest jbot-agent-test-http-start-error-is-reported ()
  (let (reported)
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (&rest _args) (error "cannot start request"))))
      (should-not
       (jbot-agent--http-json
        "GET" "http://invalid" nil #'ignore
        (lambda (message-text) (setq reported message-text)))))
    (should (string-match-p "cannot start request" reported))))

(ert-deftest jbot-agent-test-cancel-suppresses-request-error ()
  (let ((jbot-agent--active-request-buffers nil)
        reported
        request-buffer)
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (&rest _args)
                 (setq request-buffer (generate-new-buffer " *JBOT fake URL*")))))
      (jbot-agent--http-json
       "GET" "http://invalid" nil #'ignore
       (lambda (message-text) (setq reported message-text)))
      (jbot-agent-cancel))
    (should-not reported)
    (should-not (buffer-live-p request-buffer))
    (should-not jbot-agent--active-request-buffers)))

(ert-deftest jbot-agent-test-timeout-reports-once ()
  (let ((jbot-agent--active-request-buffers nil)
        (reports 0))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (&rest _args)
                 (generate-new-buffer " *JBOT fake timeout*"))))
      (jbot-agent--http-json
       "GET" "http://invalid" nil #'ignore
       (lambda (_message-text) (cl-incf reports)) 0.01)
      (sleep-for 0.05))
    (should (= reports 1))
    (should-not jbot-agent--active-request-buffers)))

(ert-deftest jbot-agent-test-review-failure-cleans-temporary-buffers ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(message \"source\")\n")
    (let ((context (jbot-agent--context 'file))
          (before (buffer-list)))
      (cl-letf (((symbol-function 'jbot-agent--display-review)
                 (lambda (&rest _args) (error "layout failed"))))
        (should-error
         (jbot-agent--open-review context "replacement\n" "Finding" "Test" nil)))
      (dolist (buffer (seq-difference (buffer-list) before))
        (should-not (string-prefix-p "*JBOT " (buffer-name buffer)))))))

(ert-deftest jbot-agent-test-external-review-frame-close-cleans-buffers ()
  (with-temp-buffer
    (insert "source\n")
    (let* ((context (jbot-agent--context 'file))
           (frame (selected-frame))
           session buffers)
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'jbot-agent--display-review) #'ignore))
              (setq session
                    (jbot-agent--open-review
                     context "proposal\n" "Finding" "Test" nil)))
            (setq buffers
                  (list (jbot-agent--review-original-buffer session)
                        (jbot-agent--review-proposal-buffer session)
                        (jbot-agent--review-diff-buffer session)
                        (jbot-agent--review-findings-buffer session)))
            (set-frame-parameter frame 'jbot-agent-review-session session)
            (jbot-agent--review-frame-deleted frame)
            (should (jbot-agent--review-closed session))
            (should-not (seq-some #'buffer-live-p buffers)))
        (set-frame-parameter frame 'jbot-agent-review-session nil)
        (when (and session (not (jbot-agent--review-closed session)))
          (jbot-agent--cleanup-review session))))))

(ert-deftest jbot-agent-test-review-does-not-copy-proposal-properties ()
  (with-temp-buffer
    (buffer-enable-undo)
    (emacs-lisp-mode)
    (insert "old\n")
    (let* ((source (current-buffer))
           (context (jbot-agent--context 'file))
           session)
      (cl-letf (((symbol-function 'jbot-agent--display-review) #'ignore))
        (setq session
              (jbot-agent--open-review context "new\n" "Finding" "Test" nil)))
      (with-current-buffer (jbot-agent--review-proposal-buffer session)
        (put-text-property (point-min) (point-max) 'jbot-test-property t)
        (jbot-agent-review-accept))
      (should (equal (with-current-buffer source (buffer-string)) "new\n"))
      (should-not (with-current-buffer source
                    (text-property-any (point-min) (point-max)
                                       'jbot-test-property t)))
      (with-current-buffer source
        (undo 1)
        (should (equal (buffer-string) "old\n"))))))

(ert-deftest jbot-agent-test-chat-prevents-overlapping-requests ()
  (let ((jbot-agent--chat-pending nil)
        (jbot-agent--chat-generation 0)
        (jbot-agent--chat-messages nil))
    (unwind-protect
        (cl-letf (((symbol-function 'jbot-agent--chat-completion)
                   (lambda (&rest _args))))
          (jbot-agent-chat "first")
          (should-error (jbot-agent-chat "second") :type 'user-error))
      (setq jbot-agent--chat-pending nil)
      (when-let* ((buffer (get-buffer "*JBOT Chat*")))
        (kill-buffer buffer)))))

(ert-deftest jbot-agent-test-chat-reset-ignores-late-response ()
  (let ((jbot-agent--chat-pending nil)
        (jbot-agent--chat-generation 0)
        (jbot-agent--chat-messages nil)
        callback)
    (unwind-protect
        (cl-letf (((symbol-function 'jbot-agent--chat-completion)
                   (lambda (_messages success &rest _args)
                     (setq callback success))))
          (jbot-agent-chat "question")
          (jbot-agent-chat-reset)
          (funcall callback "late response")
          (should-not jbot-agent--chat-messages)
          (should-not (get-buffer "*JBOT Chat*")))
      (setq jbot-agent--chat-pending nil)
      (when-let* ((buffer (get-buffer "*JBOT Chat*")))
        (kill-buffer buffer)))))

(ert-deftest jbot-agent-test-edit-response-refuses-stale-context ()
  (with-temp-buffer
    (insert "old\n")
    (let ((context (jbot-agent--context 'file)))
      (insert "changed\n")
      (should-error
       (jbot-agent--edit-response
        (concat "<JBOT_FINDINGS>note</JBOT_FINDINGS>\n"
                "<JBOT_REPLACEMENT>new</JBOT_REPLACEMENT>")
        context "Test" nil)
       :type 'user-error))))

(provide 'jbot-agent-test)

;;; jbot-agent-test.el ends here
