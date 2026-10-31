# Julia Forever 2

A fresh Julia package scaffold by Demetrius Michael.

## Requirements

Julia 1.13 or later in the 1.x series.

## Development

```sh
julia --project -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

The starter `greet` function and its tests are examples to build on. The test suite also runs Aqua package checks and JET static analysis. GitHub Actions runs the tests with coverage on pushes and pull requests and uploads an LCOV report as a workflow artifact.

The test suite checks Julia files throughout the repository for calls to `throw` or `rethrow`, `@assert`, and `try`/`catch`. `try`/`finally` without a catch is allowed.
