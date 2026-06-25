# jbot-agent

`jbot-agent` is an Emacs-native assistant for local language models. It uses an
OpenAI-compatible HTTP server, with llama.cpp as the primary backend. Generated
edits are proposals: JBOT never changes a source buffer without explicit review
and approval.

## Requirements

- Emacs 29.1 or newer.
- A running OpenAI-compatible local model server.
- A `diff` executable for review buffers.
- Gitleaks only for the optional repository pre-commit hook.

## Setup

Start llama.cpp, normally on port 8080:

```sh
llama-server -m /path/to/model.gguf --port 8080
```

Load JBOT from your Emacs configuration:

```elisp
(add-to-list 'load-path "/home/johti17/.emacs.d/JBOT")
(require 'jbot-agent)
(jbot-agent-mode 1)
```

Alternatively, open `jbot.el` and run `M-x eval-buffer`. The bootstrap file
locates the sibling `jbot-agent.el` and enables `jbot-agent-mode`. During
development, reload changed implementation code explicitly because `require`
caches loaded features:

```elisp
(load-file "/home/johti17/.emacs.d/JBOT/jbot-agent.el")
```

The default server is `http://127.0.0.1:8080`. An explicit configuration can
set both the endpoint and model identifier:

```elisp
(setq jbot-agent-server-url "http://127.0.0.1:8080"
      jbot-agent-model "your-model-id")
```

### Server discovery

When `jbot-agent-mode` is enabled, an idle timer probes the explicitly selected
server plus these default loopback endpoints; JBOT does not scan arbitrary
ports:

- `http://127.0.0.1:8080` — llama.cpp
- `http://127.0.0.1:11434` — Ollama's OpenAI-compatible API
- `http://127.0.0.1:1234` — LM Studio's OpenAI-compatible API

Discovery uses `GET /v1/models`. If `jbot-agent-model` is nil, the first model
returned by the selected server is used. Customize `jbot-agent-discovery-urls`
for other endpoints, or use `M-x jbot-agent-select-server` and
`M-x jbot-agent-select-model`.

JBOT disables llama.cpp thinking mode by default to keep interactive requests
responsive:

```elisp
(setq jbot-agent-reasoning-mode 'enabled)       ; enable model reasoning
(setq jbot-agent-reasoning-mode 'server-default) ; omit llama.cpp-specific field
```

Use `server-default` when another OpenAI-compatible server rejects llama.cpp's
`chat_template_kwargs` request field.

### Code personalities

JBOT includes C++, Julia, Emacs Lisp, Python, and OpenModelica MetaModelica
specialists under [`PERSONALITIES`](PERSONALITIES/README.md). They are valid
Ollama Modelfiles, but llama.cpp does not need Ollama: JBOT reads the selected
file's triple-quoted `SYSTEM` block and includes it in the ordinary chat request.

`jbot-agent-personality` defaults to `auto`. C++, Julia, Emacs Lisp, and Python
are selected from the current major mode. MetaModelica is selected for
`metamodelica-mode`, or when a Modelica buffer is inside an OMCompiler compiler
tree or contains MetaModelica constructs. Ordinary Modelica source is left
unmatched.

Use `M-x jbot-agent-select-personality` to choose `auto`, `none`, or a specific
personality. It can also be configured directly:

```elisp
(setq jbot-agent-personality 'auto)          ; choose from source context
(setq jbot-agent-personality "metamodelica") ; force one personality
(setq jbot-agent-personality nil)            ; use only the base prompt
```

The advice status pane displays the personality selected for that request.
Customize `jbot-agent-personality-mode-alist` to support additional major modes
and `jbot-agent-personality-directory` to load another Modelfile directory.

## Commands and user interface

### Advice

`M-x jbot-agent-advice` chooses context in this order:

1. Active region.
2. Function or defun at point.
3. Paragraph at point.
4. Current line.

Graphical Emacs immediately opens a dedicated status frame showing the server,
model, source, language mode, and elapsed time. Terminal Emacs, or
`jbot-agent-advice-new-frame` set to nil, uses a right-side window. The response
is not streamed; the same status buffer becomes the completed response when the
server finishes. Failures remain visible and provide a Retry button.

In an advice buffer:

- `k` cancels all active JBOT requests and displays a cancelled state.
- `q` closes the pane or frame but does not cancel inference by itself.
- “Propose an improved version” starts the edit-review workflow.

`M-x jbot-agent-cancel` also cancels all active requests and updates pending
advice frames. Cancellation is global rather than request-specific.

### Reviewable edits

- `M-x jbot-agent-improve` proposes a replacement for the active region or the
  context at point.
- `M-x jbot-agent-review-file` requests findings and a complete replacement for
  the current buffer.

File review uses a dedicated frame in graphical Emacs when
`jbot-agent-review-new-frame` is non-nil. Otherwise the current frame is used.
The workspace contains the original source, editable proposal, findings, and a
unified diff. Editing the proposal refreshes the diff after a short idle delay.

Review controls are available from every workspace buffer:

- `C-c C-c`: apply the proposal as one undoable change.
- `C-c C-k`: reject and close the proposal.
- `C-c C-d`: refresh the diff immediately.

The original source remains unchanged during review. JBOT refuses to open or
apply a stale proposal if the source changed while the model was working. It
does not save the source file after applying an accepted proposal.

### Chat and status

- `M-x jbot-agent-chat` reads a prompt from the minibuffer and appends the
  exchange to `*JBOT Chat*`.
- `M-x jbot-agent-chat-reset` clears the conversation.
- `M-x jbot-agent-status` shows the selected server, model, active request
  count, personality configuration, and discovered endpoints.

The chat command refuses a second prompt while its current response is pending.
`jbot-agent-chat-reset` invalidates a late response but does not stop the
underlying HTTP request; use `jbot-agent-cancel` first when inference should
also stop. Advice and edit requests may overlap. Actual inference parallelism
or queuing is controlled by the model server.

## Asynchronous behavior and limits

HTTP requests and llama.cpp inference are asynchronous, so Emacs remains usable
while the model generates. JBOT does not create Emacs Lisp worker threads.
Response JSON parsing, unified-diff generation, and accepted-edit application
run synchronously on Emacs's main thread. Very large or highly divergent file
reviews can therefore cause a temporary pause after inference completes.

Relevant defaults:

- Request timeout: 180 seconds (`jbot-agent-request-timeout`).
- Maximum source context: 60,000 characters (`jbot-agent-max-context-chars`).
- Normal output budget: 4,096 tokens (`jbot-agent-max-output-tokens`).
- Whole-file output budget: 16,384 tokens
  (`jbot-agent-file-review-max-output-tokens`).

JBOT reports oversized context instead of silently truncating it. Whole-file
review requires the model's context and output limits to accommodate the entire
file and revised result.

## Development and CI

Run the local Emacs checks:

```sh
emacs -Q --batch -L . \
  --eval "(setq byte-compile-error-on-warn t)" \
  -f batch-byte-compile jbot-agent.el jbot.el

emacs -Q --batch -L . -L test \
  -l test/jbot-agent-test.el \
  -f ert-run-tests-batch-and-exit

emacs -Q --batch -L . \
  --eval "(progn (require 'checkdoc) \
  (checkdoc-file \"jbot-agent.el\") \
  (checkdoc-file \"jbot.el\"))"
```

`.github/workflows/ci.yml` runs byte compilation, ERT, Checkdoc, and a pinned
Gitleaks scan on pull requests. It also runs on pushes to `main` or `master` and
manual dispatches. CI checks out full Git history for secret scanning.

### Pre-commit secret scanning

Install Gitleaks, then enable the versioned hook once per clone:

```sh
git config core.hooksPath .githooks
```

`.githooks/pre-commit` scans staged changes with
`gitleaks git --pre-commit --redact --staged --verbose`. It fails closed when
Gitleaks is unavailable. For an exceptional intentional bypass:

```sh
SKIP=gitleaks git commit ...
```

The bypass affects only the local hook; CI still scans Git history. `.gitignore`
ignores dotfiles and dot-directories by default, while explicitly retaining
`.gitignore`, `.github`, and `.githooks` as repository infrastructure.
