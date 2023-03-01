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

### Alternate Makefile

Alternatively, there is a Makefile for running the tests. The target `<name>.mode.test`, can be used to compare the assembler's current output
for `<name>.s` (in mode `mode`) to the stored output in `<name>.mode`. For example, `make neg_movs.bin.test` will test the `neg_movs.s` file in
the `bin` mode.

The `test` target discovers all stored output files and runs the tests for all of them. Failing tests will put their new output in
`<name>.mode.fail`, which you can then use `diff` to examine later. Give `-k` (for "keep going") to `make` to allow it to continue
running tests if one fails.

If the new output for a failing test is in fact the correct output, you can update the stored golden output to match by using the target
`<name>.mode.accept`, which will replace the contents of `<name>.mode` with the contents of `<name>.mode.fail`. The target `accept-all`
will attempt to accept the new output for every currently stored output (if there is no corresponding `.fail` file, nothing will be changed).

To generate `bin` and `ann` files for all assembly files present (overwriting existing golden files, if they exist), run `make generate`.
The `generate` target uses the `MODES` make variable to determine what modes to generate output for. The default value is like calling
`make generate MODES="bin ann"` but you can explicitly add `MODES="<modes>"` to generate, say, `tc` format output.

If you'd like to use an assembler other than `etc-as`, override the `ASM` make variable with `make test ASM=my-etc-as`.
The CLI of your chosen assembler must match that of `etc-as`, to the extent that the tests use `etc-as` flags and `-mformat` options.
