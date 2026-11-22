# PodNet.ProjectTemplate [![NuGet](https://img.shields.io/nuget/v/PodNet.ProjectTemplate)](https://www.nuget.org/packages/PodNet.ProjectTemplate/)
$PodNetPackageDescription$

## Development

Install the stable .NET SDK specified in `global.json`. The preview `PodNet.Sdk` must be available from a configured NuGet source before evaluating projects. Add library code under `src` and real source tests under `tests`; the test project targets .NET 11 even if the library targets an earlier framework.

Run `dotnet build` and `dotnet pack -c Release` from the repository root. After adding tests, run `dotnet test`; an empty test project is not a meaningful test suite and may return a non-success exit code. Update `PodNetCopyrightYear` in `Directory.Build.props` each year before a Release pack. Review the package metadata and repository URLs before publishing.

## Publishing

The tag workflow uses the composite action in a job owned by this repository. Configure NuGet Trusted Publishing for the repository and workflow, set `NUGET_USER`, and ensure the pinned SDK and action are available before tagging. The workflow skips package integration tests; add them and the `integration` stage when the repository tests its packaged output.

## Contributing

Issues and pull requests are welcome.