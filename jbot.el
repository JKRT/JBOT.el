;;; jbot.el --- Bootstrap loader for jbot-agent -*- lexical-binding: t; -*-

;;; Commentary:

;; Load the sibling jbot-agent implementation without requiring this directory
;; to be present in `load-path', then enable its global mode.

;;; Code:

(declare-function jbot-agent-mode "jbot-agent" (&optional arg))

(let* ((loader-file (or load-file-name buffer-file-name))
       (loader-directory
        (and loader-file (file-name-directory loader-file))))
  (unless loader-directory
    (error "JBOT cannot determine the directory containing jbot.el"))
  (require 'jbot-agent (expand-file-name "jbot-agent" loader-directory)))

(jbot-agent-mode 1)
(message "JBOT Agent loaded; use M-x jbot-agent-advice or M-x jbot-agent-chat")

(provide 'jbot)

;;; jbot.el ends here
