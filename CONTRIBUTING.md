# Contributing

We welcome bug reports, feature requests, documentation fixes, and changes to the runtime image.
Our [code of conduct](CODE_OF_CONDUCT.md) applies to issues and pull requests.

## Reporting issues

For suspected vulnerabilities, follow the [security reporting instructions](SECURITY.md).
For other bugs and feature requests, search the [issue tracker](https://github.com/aws/aws-lambda-nodejs-runtime/issues)
for an existing discussion. When reporting a bug, include the image tag or commit, architecture,
runtime variant, steps to reproduce, and the expected and actual results.

## Submitting a pull request

Start from the latest `main`. For a substantial change, open an issue first so maintainers can
discuss the approach with you. Keep the pull request focused and link the issue if there is one.

For runtime changes, [build the image](README.md#building-an-image) and run the
[smoke and security tests](README.md#testing) for your architecture. Describe what you tested
in the pull request and add a test case when fixing a bug that the existing tests miss.

The pull request template asks you to confirm that your contribution is licensed under the
[Apache License 2.0](LICENSE).
