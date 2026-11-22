# PodNet.Templates [![NuGet](https://img.shields.io/nuget/v/PodNet.Templates)](https://www.nuget.org/packages/PodNet.Templates/)
Custom .NET repository templates for PodNet packages. This is a template package, not a project dependency.

## Usage

Install the actual candidate `.nupkg` with `dotnet new install <path-to-PodNet.Templates.nupkg>`, then run `dotnet new pod-nuget-repo --name Example --description "Example library" --packageTags "example library"`. The generated repository lives in `<output>/PodNet.Example`.

| Option | Required | Default |
|---|---|---|
| `--description` | Yes | — |
| `--packageTags` | Yes | — |
| `--sdkVersion` | No | `11.0.100` |
| `--targetFramework` | No | `net11.0` |

The library framework can be `netstandard2.0`; source tests run on `net11.0`. The generated `global.json` pins `PodNet.Sdk` 0.1.0-preview.1, `MSTest.Sdk` 4.5.3 and Microsoft.Testing.Platform. C# 15 is supplied by the shared SDK; there is no `--langVersion` option. Add real tests before relying on the test stage.

The SDK is not yet published. Configure a NuGet source containing the candidate before evaluating generated projects. Do not tag or publish generated repositories until the SDK and composite action release gates are complete. Update the generated copyright year annually. The generated README has build and publishing guidance.

## Validate this repository

For existing repositories, see [semantic drift detection](docs/drift.md). It compares template-owned settings against a freshly instantiated baseline, without modifying the repository.

The pack project deliberately uses standalone common rules, so it can build without the unpublished SDK. Run `pwsh ./tests/acceptance.ps1 -SdkFeed <candidate-feed> -OutputFeed <output-feed>` to pack from an isolated copy, install that exact package in an isolated template hive and build, test and pack two generated repositories. NuGet.org is required for MSTest and framework dependencies. Pull-request CI builds the SDK from the pinned source commit into a local feed; it does not publish.