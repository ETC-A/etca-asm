## Golden tests

The tests here are designed to check that the assembler outputs what is expected. The primary point is regression tests, coverage tests and cross-compatibility.

Each test entry consists of at least a `<name>.s` and a `<name>.bin` file to check what the raw binary output is. In addition, the following files are checked against if present:

| file pattern  | `-mformat=` |
|---------------|-------------|
| `<name>.bin`  | `binary`    |
| `<name>.ann`  | `annotated` |
| `<name>.tc`   | `tc`        |
| `<name>.tc64` | `tc-64`     |

Note that these more descriptive formats can be break with changes in the assembler that are not in fact regressions, and they might be completely useless for other assemblers.

The first line of `.s` is assumed to be a comment containing additional arguments to pass to the assembler, e.g. `-mnaked-reg`. This comment also needs to be present and empty if no additional arguments should be passed.

To generate the files in the various formats one can use the `--gen` parameter for the `golden_tester_generic` script.