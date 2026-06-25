# JBOT code personalities

These files are valid Ollama Modelfiles and are also JBOT's language-specific
system prompts. With the default llama.cpp backend, JBOT reads only each
triple-quoted `SYSTEM` block and sends it as part of the OpenAI-compatible chat
request. `FROM` and `PARAMETER` are used only when creating a model with
Ollama.

Available personalities:

- `cpp` — modern C++ interfaces, RAII, ownership, lifetimes, and correctness.
- `julia` — multiple dispatch, type stability, allocation awareness, and Julia
  package conventions.
- `elisp` — native Emacs lifecycle, buffer/window safety, asynchronous work,
  byte compilation, Checkdoc, and ERT.
- `python` — explicit Python APIs, typing, resources, exceptions, async safety,
  security boundaries, and tests.
- `metamodelica` — OpenModelica NFFrontEnd phases, uniontypes, match semantics,
  immutable lists, NF traversal, identity preservation, and diagnostics.

JBOT defaults to `jbot-agent-personality` set to `auto`. It maps C++, Julia,
Emacs Lisp, and Python major modes directly. MetaModelica is selected for
`metamodelica-mode`, or for a Modelica buffer whose path or source indicates
that it is compiler MetaModelica. This avoids applying MetaModelica rules to
ordinary Modelica models.

Use `M-x jbot-agent-select-personality` to select `auto`, `none`, or a named
personality. Configuration examples:

```elisp
(setq jbot-agent-personality 'auto)
(setq jbot-agent-personality "metamodelica")
(setq jbot-agent-personality nil)
```

To use one with Ollama directly, first pull or replace the `FROM` model, then
create the derived model:

```sh
ollama create jbot-cpp -f PERSONALITIES/cpp.Modelfile
```

The default `FROM qwen3-coder:30b` is independent of JBOT's llama.cpp model.
Changing it does not change the model served by llama.cpp.

## Research basis

- C++: [ISO C++ Core Guidelines](https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines),
  especially interfaces, resource management, RAII, and ownership.
- Julia: the official [Julia Style Guide](https://docs.julialang.org/en/v1/manual/style-guide/)
  and [Performance Tips](https://docs.julialang.org/en/v1/manual/performance-tips/).
- Emacs Lisp: [GNU Emacs Lisp Coding Conventions](https://www.gnu.org/software/emacs/manual/html_node/elisp/Coding-Conventions.html)
  and package conventions.
- Python: [PEP 8](https://peps.python.org/pep-0008/) and the
  [official typing specification](https://typing.python.org/en/latest/spec/).
- MetaModelica: current local OpenModelica sources under
  `OMCompiler/Compiler/NFFrontEnd`, particularly `NFType.mo`,
  `NFExpression.mo`, `NFTyping.mo`, and `NFInst.mo`.
- Modelfile format: [Ollama's official Modelfile reference](https://docs.ollama.com/modelfile).
