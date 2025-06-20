# ZAUR Makefile
.PHONY: all build test clean install uninstall package help

# Default target
all: build

# Build the project
build:
	@echo "Building ZAUR..."
	zig build -Doptimize=ReleaseSafe

# Run tests
test:
	@echo "Running tests..."
	zig build test

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf zig-out zig-cache .zig-cache

# Install system-wide (requires root)
install: build
	@echo "Installing ZAUR system-wide..."
	install -Dm755 zig-out/bin/zaur /usr/bin/zaur
	install -Dm644 README.md /usr/share/doc/zaur/README.md
	install -Dm644 LICENSE /usr/share/licenses/zaur/LICENSE
	@echo "ZAUR installed to /usr/bin/zaur"

# Uninstall system-wide (requires root)
uninstall:
	@echo "Uninstalling ZAUR..."
	rm -f /usr/bin/zaur
	rm -rf /usr/share/doc/zaur
	rm -rf /usr/share/licenses/zaur
	@echo "ZAUR uninstalled"

# Build Arch package
package:
	@echo "Building Arch package..."
	makepkg -f

# Development build
dev:
	@echo "Building for development..."
	zig build

# Run the built binary
run: build
	@echo "Running ZAUR..."
	./zig-out/bin/zaur help

# Help target
help:
	@echo "ZAUR Build System"
	@echo ""
	@echo "Available targets:"
	@echo "  all      - Build the project (default)"
	@echo "  build    - Build optimized binary"
	@echo "  test     - Run tests"
	@echo "  clean    - Clean build artifacts"
	@echo "  install  - Install system-wide (requires root)"
	@echo "  uninstall- Uninstall system-wide (requires root)"
	@echo "  package  - Build Arch package with makepkg"
	@echo "  dev      - Build for development"
	@echo "  run      - Build and run help command"
	@echo "  help     - Show this help"