# Security Policy

## Status

ZAUR is under active development. Security hardening has been applied to path validation, API input handling, and GPG operations.

## Supported Versions

Security support currently applies to the active main branch while the project is being stabilized.

## Reporting A Vulnerability

Please do not open a public issue for security-sensitive problems.

Report vulnerabilities privately to the maintainer through the project's preferred private contact channel. Include:

- a clear description of the issue
- affected commit or branch information
- reproduction steps if available
- impact assessment
- any suggested mitigation

## Scope

Security issues may include:

- authentication or authorization bypass
- unsafe package source handling
- command injection or shell injection
- archive extraction issues
- path traversal in file serving or build paths
- secrets exposure
- signature verification or signing workflow flaws
- container or deployment misconfiguration with security impact

## Response Expectations

Reports will be triaged and validated before a fix timeline is communicated. Coordinated disclosure is preferred.
