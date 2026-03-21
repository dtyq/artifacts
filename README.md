# Magic Artifacts

Helm repository for deploying [Magic](https://github.com/dtyq/magic) on Kubernetes.

## Usage

[Helm](https://helm.sh) must be installed before using these charts.
See the official [Helm documentation](https://helm.sh/docs/) to get started.

Add this chart repository:

```console
helm repo add dtyq https://dtyq.github.io/artifacts
helm repo update
```

List available charts:

```console
helm search repo dtyq/
```

Install a chart:

```console
helm install my-release dtyq/<chart-name> --version <chart-version>
```

## Chart Packages

Chart packages are published by CI and referenced through this `index.yaml`.
Release artifacts are available in the repository release page.

## Contributing

The Magic source code is available at:
<https://github.com/dtyq/magic>

## License

See [LICENSE](https://github.com/dtyq/artifacts/blob/master/LICENSE).

## Helm charts build status

![Release Charts](https://github.com/dtyq/artifacts/actions/workflows/release.yaml/badge.svg?branch=master)
