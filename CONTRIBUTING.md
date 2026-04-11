# Contributing to ZAUR

## Development Setup

1. Install Zig 0.16.0-dev or later
2. Clone the repository
3. Run `zig build` to compile
4. Run `zig build test` to run tests

## Testing

All tests should be run in the Docker test environment:

```bash
cd docker
./run-tests.sh basic   # Basic integration tests
./run-tests.sh full    # Full integration tests
./run-tests.sh shell   # Interactive shell for manual testing
```

## Code Style

- Follow Zig style conventions
- Use `zig fmt` before committing
- Keep functions focused and small
- Handle errors explicitly - no silent `catch {}`

## Pull Requests

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests in Docker environment
5. Submit PR with clear description

## Reporting Issues

- Include Zig version
- Include error output
- Steps to reproduce
