;;; jbot.el --- Bootstrap loader for jbot-agent -*- lexical-binding: t; -*-

;; Copyright (C) 2026 John Tinnerholm

;; This file is part of JBOT.

;; JBOT is free software: you can redistribute it and/or modify it under the
;; terms of the GNU General Public License as published by the Free Software
;; Foundation, either version 3 of the License, or (at your option) any later
;; version.

;; JBOT is distributed in the hope that it will be useful, but WITHOUT ANY
;; WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
;; FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
;; details.

;; You should have received a copy of the GNU General Public License along with
;; JBOT.  If not, see <https://www.gnu.org/licenses/>.

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
