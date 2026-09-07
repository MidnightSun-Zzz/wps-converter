# Repository Guidelines

跨项目协作见仓库根目录 `../AGENTS.md`。

## Project Structure & Module Organization

This repository is currently a small Python 3.13 application:

- `main.py` contains the executable entry point.
- `pyproject.toml` defines project metadata, the supported Python version, and dependencies.
- `README.md` is reserved for user-facing setup and usage documentation.
- `.python-version` pins Python 3.13 for compatible environment managers.

As the converter grows, place importable code under `src/wps_converter/` and tests under `tests/`, mirroring source modules (for example, `src/wps_converter/parser.py` and `tests/test_parser.py`). Keep generated documents and local fixtures out of the repository unless they are small, sanitized test assets.

## Build, Test, and Development Commands

Use `uv` for environment and dependency management:

- `uv sync` creates or updates `.venv` from `pyproject.toml`.
- `uv run python main.py` runs the current application.
- `uv run python -m compileall main.py` performs a quick syntax check.
- `uv run pytest` runs the test suite after `pytest` is added as a development dependency.
- `uv build` builds distribution artifacts once a packaging layout and build system are configured.

Add runtime dependencies with `uv add <package>` and development tools with `uv add --dev <package>`. Do not commit `.venv/`, caches, or build output.

## Coding Style & Naming Conventions

Follow PEP 8 with four-space indentation and type hints on public functions. Use `snake_case` for modules, functions, and variables; `PascalCase` for classes; and `UPPER_SNAKE_CASE` for constants. Keep file-conversion logic separate from CLI or WPS integration code. Prefer small functions with explicit inputs and outputs.

When Ruff is configured, run `uv run ruff check .` and `uv run ruff format --check .` before submitting changes.

## Testing Guidelines

Use `pytest` and name files `test_<module>.py` and tests `test_<behavior>()`. Cover successful conversions, unsupported formats, malformed input, Unicode filenames, and cleanup after failures. Use temporary directories rather than writing generated files into the repository. Every bug fix should include a regression test.

## Commit & Pull Request Guidelines

The repository has no commit history yet. Use concise, imperative commit subjects, optionally following Conventional Commits, such as `feat: add DOCX conversion` or `fix: preserve output filename`.

Pull requests should explain the user-visible change, list verification commands, and link relevant issues. Include sanitized sample input/output details for conversion changes and screenshots only when UI behavior changes. Keep each pull request focused and document any new configuration or dependency.
