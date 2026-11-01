# Julia Forever 2

[![CI](https://github.com/D3MZ/Julia-Forever-2/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/D3MZ/Julia-Forever-2/actions/workflows/ci.yml?query=branch%3Amain)
[![codecov](https://codecov.io/gh/D3MZ/Julia-Forever-2/graph/badge.svg?branch=main)](https://codecov.io/gh/D3MZ/Julia-Forever-2)
[![Julia](https://img.shields.io/badge/Julia-1.13%2B%20%281.x%29-9558B2?logo=julia&logoColor=white)](Project.toml)

A fresh Julia package scaffold by Demetrius Michael.

## Requirements

Julia 1.13 or later in the 1.x series.

## Development

```sh
julia --project -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

The starter `greet` function and its tests are examples to build on. The test suite also runs Aqua package checks and JET static analysis. GitHub Actions runs the tests with coverage on pushes and pull requests, uploads an LCOV report as a workflow artifact, and sends it to Codecov.

The test suite checks Julia files throughout the repository for calls to `throw` or `rethrow`, `@assert`, and `try`/`catch`. `try`/`finally` without a catch is allowed.
