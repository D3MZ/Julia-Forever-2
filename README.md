# Julia Forever 2

A fresh Julia package scaffold by Demetrius Michael.

## Requirements

Julia 1.13 or later in the 1.x series.

## Development

```sh
julia --project -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

The starter `greet` function and its tests are examples to build on. GitHub Actions runs the tests with coverage on pushes and pull requests and uploads an LCOV report as a workflow artifact.
