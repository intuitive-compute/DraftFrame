# Contributing to DraftFrame

Thanks for your interest in contributing! Here's how to get started.

## Development Setup

```bash
# Clone the repo
git clone https://github.com/imjohsep/draftframe.git
cd draftframe

# Build
swift build

# Run
.build/debug/DraftFrame

# Run tests
swift test
```

Requires macOS 14.0+ and Swift 5.9+.

## Making Changes

1. Fork the repo and create a branch from `main`
2. Make your changes
3. Run `swift test` and ensure all tests pass
4. Run `swift build` to verify the build succeeds
5. Open a pull request

## Pull Requests

- Keep PRs focused — one feature or fix per PR
- Include a clear description of what changed and why
- Add tests for new functionality when possible
- Make sure CI passes before requesting review

## Reporting Bugs

Open an issue with:
- macOS version
- Steps to reproduce
- Expected vs actual behavior
- Any relevant logs or screenshots

## Code Style

- Follow existing conventions in the codebase
- Use Swift standard naming conventions
- Keep files focused on a single responsibility

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
