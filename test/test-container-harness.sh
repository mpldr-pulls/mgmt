#!/bin/bash
# Container Test Harness for mgmt
# Builds a static mgmt binary, launches systemd-enabled Docker containers for
# each supported OS, and runs MCL test scripts inside each container. Produces
# a structured pass/fail report.
#
# Usage: ./test/test-container-harness.sh [--os <name>] [--test <name>] [--keep] [--help]
#   --os <name>    Run tests only for the specified OS (fedora, debian, ubuntu, archlinux)
#   --test <name>  Run only the specified test script (without .mcl extension)
#   --keep         Don't remove containers after tests (for debugging)
#   --help         Show usage information

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$ROOT/mgmt.static"
TEST_MCL_DIR="$ROOT/test/container-mcl"
DOCKERFILE_DIR="$ROOT/test/container-dockerfiles"
LOG_DIR="$ROOT/test/container-logs"

OS_NAMES=(fedora debian ubuntu archlinux)

# Build TESTS array dynamically from test/container-mcl/test-*.mcl files.
TESTS=()
for _mcl in "$TEST_MCL_DIR"/test-*.mcl; do
	TESTS+=("$(basename "${_mcl%.mcl}")")
done
unset _mcl

# CLI flags
FILTER_OS=""
FILTER_TEST=""
KEEP=false

# Result tracking
PASS=0
FAIL=0
ERRORS=""

# Tracking active containers for cleanup
CONTAINERS=()

OS_COUNT=0

log() { echo "==> $*"; }

pass() {
	PASS=$((PASS + 1))
	echo "  PASS  $1"
}

fail() {
	FAIL=$((FAIL + 1))
	local detail="  [$2] $1"
	if [ -n "${3:-}" ]; then
		detail="$detail\n    $3"
	fi
	ERRORS="${ERRORS}\n${detail}"
	echo "  FAIL  $1"
}

usage() {
	cat <<EOF
Usage: $0 [--os <name>] [--test <name>] [--keep] [--help]
  --os <name>    Run tests only for the specified OS (fedora, debian, ubuntu, archlinux)
  --test <name>  Run only the specified test script (without .mcl extension)
  --keep         Don't remove containers after tests (for debugging)
  --help         Show usage information

Valid OS names: ${OS_NAMES[*]}
EOF
}

# shellcheck disable=SC2329 # invoked via trap
cleanup() {
	if [ "$KEEP" = true ]; then
		if [ ${#CONTAINERS[@]} -gt 0 ]; then
			log "Containers kept (--keep): ${CONTAINERS[*]}"
		fi
		return
	fi
	for cid in "${CONTAINERS[@]}"; do
		docker rm -f "$cid" >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT INT TERM

# CLI parsing
while [ $# -gt 0 ]; do
	case "$1" in
		--os)
			if [ -z "${2:-}" ]; then
				echo "ERROR: --os requires a value"
				usage
				exit 1
			fi
			FILTER_OS="$2"
			shift 2
			;;
		--test)
			if [ -z "${2:-}" ]; then
				echo "ERROR: --test requires a value"
				usage
				exit 1
			fi
			FILTER_TEST="$2"
			shift 2
			;;
		--keep)
			KEEP=true
			shift
			;;
		--help)
			usage
			exit 0
			;;
		*)
			echo "ERROR: Unknown flag: $1"
			usage
			exit 1
			;;
	esac
done

# --os flag validation
if [ -n "$FILTER_OS" ]; then
	valid=false
	for name in "${OS_NAMES[@]}"; do
		if [ "$name" = "$FILTER_OS" ]; then
			valid=true
			break
		fi
	done
	if [ "$valid" = false ]; then
		echo "ERROR: Unknown OS '$FILTER_OS'. Valid OS names: ${OS_NAMES[*]}"
		exit 1
	fi
fi

# --test flag validation
if [ -n "$FILTER_TEST" ]; then
	valid=false
	for t in "${TESTS[@]}"; do
		if [ "$t" = "$FILTER_TEST" ]; then
			valid=true
			break
		fi
	done
	if [ "$valid" = false ]; then
		echo "ERROR: Unknown test '$FILTER_TEST'. Valid test names: ${TESTS[*]}"
		exit 1
	fi
fi

if ! command -v docker >/dev/null 2>&1; then
	echo "ERROR: Docker is not installed. Docker is required to run container tests."
	exit 1
fi

if ! docker info >/dev/null 2>&1; then
	echo "ERROR: Docker is not available. Ensure the Docker daemon is running and you have permission to use it."
	exit 1
fi

log "Docker is available"
log "OS matrix: ${OS_NAMES[*]}"
if [ -n "$FILTER_OS" ]; then
	log "Filtering to OS: $FILTER_OS"
fi
if [ -n "$FILTER_TEST" ]; then
	log "Filtering to test: $FILTER_TEST"
fi

# Build static binary
cd "$ROOT" || exit 1
if ! make lang resources funcgen; then
	echo "ERROR: Code generation (make lang resources funcgen) failed."
	exit 1
fi

SVERSION="0.0.0-container-test"
PROGRAM="mgmt"
if ! CGO_ENABLED=0 go build -trimpath -tags 'noaugeas novirt netgo' \
	-ldflags "-extldflags \"-static\" -X main.program=$PROGRAM -X main.version=$SVERSION -s -w" \
	-o "$BINARY"; then
	echo "ERROR: building binary failed."
	exit 1
fi

# Container lifecycle

PREPARED_IMAGE=""

build_image() {
	local idx="$1"
	local os_name="${OS_NAMES[$idx]}"
	local dockerfile="$DOCKERFILE_DIR/Dockerfile.${os_name}"
	local image_tag="mgmt-test-${os_name}:latest"

	log "Building image for $os_name..."

	if [ ! -f "$dockerfile" ]; then
		PREPARED_IMAGE=""
		echo "ERROR: Dockerfile not found: $dockerfile"
		return 1
	fi

	local build_output
	if ! build_output=$(docker build -t "$image_tag" -f "$dockerfile" "$DOCKERFILE_DIR" 2>&1); then
		PREPARED_IMAGE=""
		echo "ERROR: Docker build failed for $os_name:"
		echo "$build_output"
		return 1
	fi

	PREPARED_IMAGE="$image_tag"
	log "Image ready for $os_name: $image_tag"
	return 0
}

CURRENT_CONTAINER=""

launch_container() {
	local idx="$1"
	local os_name="${OS_NAMES[$idx]}"
	local cname="mgmt-test-${os_name}-$$"

	log "Launching systemd container for $os_name..."

	local cid
	if ! cid=$(docker run -d \
		--name "$cname" \
		--tmpfs /run \
		--tmpfs /tmp \
		--privileged \
		--cgroupns=host \
		-v /sys/fs/cgroup:/sys/fs/cgroup:rw \
		-v "$BINARY:/usr/local/bin/mgmt:ro" \
		-v "$TEST_MCL_DIR:/tests:ro" \
		"$PREPARED_IMAGE" \
		/sbin/init 2>&1); then
		CURRENT_CONTAINER=""
		echo "ERROR: Failed to start container for $os_name: $cid"
		return 1
	fi

	CONTAINERS+=("$cname")
	CURRENT_CONTAINER="$cname"
	return 0
}

wait_for_systemd() {
	local cname="$1"
	local timeout=30

	log "Waiting for systemd to boot in $cname (timeout: ${timeout}s)..."

	SECONDS=0
	while [ "$SECONDS" -lt "$timeout" ]; do
		local status
		status=$(docker exec "$cname" systemctl is-system-running 2>/dev/null || true)
		if [ "$status" = "running" ] || [ "$status" = "degraded" ]; then
			log "systemd is ready in $cname (status: $status, ${SECONDS}s)"
			return 0
		fi
		sleep 1
	done

	echo "ERROR: systemd did not reach running/degraded in $cname within ${timeout}s"
	return 1
}

wait_for_packagekit() {
	local cname="$1"
	local timeout=60

	# Refresh APT lists if present; PackageKit will hang trying to resolve
	# packages on apt-based systems when the lists were deleted in the image.
	docker exec "$cname" apt-get update -qq 2>/dev/null || true

	log "Starting PackageKit in $cname..."
	docker exec "$cname" systemctl start packagekit 2>/dev/null || true

	SECONDS=0
	while [ "$SECONDS" -lt "$timeout" ]; do
		if docker exec "$cname" systemctl is-active packagekit >/dev/null 2>&1; then
			log "PackageKit ready in $cname (${SECONDS}s)"
			return 0
		fi
		sleep 1
	done

	log "WARNING: PackageKit not ready in $cname after ${timeout}s (pkg/svc tests will fail)"
}

# Per-test cleanup
# Removes leftover state from a previous run of the given test.
cleanup_test() {
	local cname="$1"
	local test_name="$2"

	case "$test_name" in
		test-file)
			docker exec "$cname" rm -rf /tmp/mgmt-test-file/ 2>/dev/null || true
			;;
		test-exec)
			docker exec "$cname" rm -rf /tmp/mgmt-test-exec/ 2>/dev/null || true
			;;
		test-line)
			docker exec "$cname" rm -rf /tmp/mgmt-test-line/ 2>/dev/null || true
			;;
		test-gzip)
			docker exec "$cname" rm -rf /tmp/mgmt-test-gzip/ 2>/dev/null || true
			;;
		test-tar)
			docker exec "$cname" rm -rf /tmp/mgmt-test-tar/ 2>/dev/null || true
			docker exec "$cname" mkdir -p /tmp/mgmt-test-tar/input/ 2>/dev/null || true
			;;
		test-hostname)
			docker exec "$cname" rm -rf /tmp/mgmt-test-hostname/ 2>/dev/null || true
			;;
		test-set-hostname)
			# hostname is transient state, no filesystem cleanup needed
			;;
		test-user)
			docker exec "$cname" userdel -r mgmttestuser 2>/dev/null || true
			;;
		test-group)
			docker exec "$cname" groupdel mgmttestgroup 2>/dev/null || true
			;;
		test-ssh-key)
			docker exec "$cname" rm -rf /tmp/mgmt-test-sshkey/ 2>/dev/null || true
			;;
		test-cron)
			docker exec "$cname" systemctl stop mgmt-test-cron.timer 2>/dev/null || true
			docker exec "$cname" rm -f /etc/systemd/system/mgmt-test-cron.service 2>/dev/null || true
			docker exec "$cname" rm -f /etc/systemd/system/mgmt-test-cron.timer 2>/dev/null || true
			docker exec "$cname" systemctl daemon-reload 2>/dev/null || true
			;;
		# test-distro, test-json: no filesystem state to clean
		# test-set-hostname: transient state only
		# test-pkg, test-svc: package/service state is idempotent, no pre-cleanup needed
	esac
}

# Per-test validation
# Validates the result of a test execution. Returns 0 on success, 1 on failure.
# Arguments: CONTAINER_NAME TEST_NAME MGMT_OUTPUT
validate_test() {
	local cname="$1"
	local test_name="$2"
	local mgmt_output="$3"

	case "$test_name" in
		test-file)
			local content
			content=$(docker exec "$cname" cat /tmp/mgmt-test-file/output 2>&1) || {
				echo "File /tmp/mgmt-test-file/output not found: $content"
				return 1
			}
			if [ "$content" != "hello from mgmt container test" ]; then
				echo "Expected 'hello from mgmt container test', got: '$content'"
				return 1
			fi
			;;
		test-exec)
			local content
			content=$(docker exec "$cname" cat /tmp/mgmt-test-exec/output 2>&1) || {
				echo "File /tmp/mgmt-test-exec/output not found: $content"
				return 1
			}
			if [ "$content" != "hello from exec resource" ]; then
				echo "Expected 'hello from exec resource', got: '$content'"
				return 1
			fi
			;;
		test-distro)
			if ! echo "$mgmt_output" | grep -q "os.family:"; then
				echo "Expected mgmt output to contain 'os.family:', got: $mgmt_output"
				return 1
			fi
			;;
		test-line)
			local content
			content=$(docker exec "$cname" cat /tmp/mgmt-test-line/output 2>&1) || {
				echo "File /tmp/mgmt-test-line/output not found: $content"
				return 1
			}
			if ! echo "$content" | grep -q "hello from mgmt line resource"; then
				echo "Expected line 'hello from mgmt line resource' in file, got: '$content'"
				return 1
			fi
			;;
		test-gzip)
			local size
			size=$(docker exec "$cname" stat -c%s /tmp/mgmt-test-gzip/output.gz 2>&1) || {
				echo "File /tmp/mgmt-test-gzip/output.gz not found: $size"
				return 1
			}
			if [ "$size" -eq 0 ]; then
				echo "File /tmp/mgmt-test-gzip/output.gz is empty"
				return 1
			fi
			;;
		test-tar)
			local size
			size=$(docker exec "$cname" stat -c%s /tmp/mgmt-test-tar/output.tar 2>&1) || {
				echo "File /tmp/mgmt-test-tar/output.tar not found: $size"
				return 1
			}
			if [ "$size" -eq 0 ]; then
				echo "File /tmp/mgmt-test-tar/output.tar is empty"
				return 1
			fi
			;;
		test-json)
			if ! echo "$mgmt_output" | grep -q "json:"; then
				echo "Expected mgmt output to contain 'json:', got: $mgmt_output"
				return 1
			fi
			;;
		test-hostname)
			local content
			content=$(docker exec "$cname" cat /tmp/mgmt-test-hostname/output 2>&1) || {
				echo "File /tmp/mgmt-test-hostname/output not found: $content"
				return 1
			}
			if [ -z "$content" ]; then
				echo "File /tmp/mgmt-test-hostname/output is empty"
				return 1
			fi
			;;
		test-set-hostname)
			local actual
			actual=$(docker exec "$cname" hostname 2>&1) || {
				echo "Failed to read hostname: $actual"
				return 1
			}
			if [ "$actual" != "mgmt-test-host" ]; then
				echo "Expected hostname 'mgmt-test-host', got: '$actual'"
				return 1
			fi
			;;
		test-user)
			docker exec "$cname" id mgmttestuser >/dev/null 2>&1 || {
				echo "User 'mgmttestuser' does not exist"
				return 1
			}
			;;
		test-group)
			docker exec "$cname" getent group mgmttestgroup >/dev/null 2>&1 || {
				echo "Group 'mgmttestgroup' does not exist"
				return 1
			}
			;;
		test-ssh-key)
			local content
			content=$(docker exec "$cname" cat /tmp/mgmt-test-sshkey/authorized_keys 2>&1) || {
				echo "File /tmp/mgmt-test-sshkey/authorized_keys not found: $content"
				return 1
			}
			if ! echo "$content" | grep -q "ssh-ed25519"; then
				echo "Expected SSH key entry with 'ssh-ed25519' in authorized_keys, got: '$content'"
				return 1
			fi
			;;
		test-pkg)
			docker exec "$cname" bash -c "command -v tree" >/dev/null 2>&1 || {
				echo "Package 'tree' is not installed (tree not found in PATH)"
				return 1
			}
			;;
		test-svc)
			local status
			status=$(docker exec "$cname" systemctl is-active nginx 2>&1) || true
			if [ "$status" != "active" ]; then
				echo "Service 'nginx' is not running (status: $status)"
				return 1
			fi
			;;
		test-cron)
			docker exec "$cname" systemctl list-timers --all 2>&1 | grep -q "mgmt-test-cron" || {
				echo "Timer 'mgmt-test-cron' not found in systemctl list-timers"
				return 1
			}
			;;
		*)
			echo "No validation function for test: $test_name"
			return 1
			;;
	esac
	return 0
}

# Main loop over OS matrix
rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

for i in "${!OS_NAMES[@]}"; do
	os_name="${OS_NAMES[$i]}"

	if [ -n "$FILTER_OS" ] && [ "$os_name" != "$FILTER_OS" ]; then
		continue
	fi

	log "--- $os_name ---"
	OS_COUNT=$((OS_COUNT + 1))
	OS_LOG="$LOG_DIR/${os_name}.log"
	: > "$OS_LOG"

	if ! build_image "$i"; then
		for t in "${TESTS[@]}"; do
			if [ -n "$FILTER_TEST" ] && [ "$t" != "$FILTER_TEST" ]; then
				continue
			fi
			fail "$t" "$os_name" "Image build failed"
		done
		continue
	fi

	if ! launch_container "$i"; then
		for t in "${TESTS[@]}"; do
			if [ -n "$FILTER_TEST" ] && [ "$t" != "$FILTER_TEST" ]; then
				continue
			fi
			fail "$t" "$os_name" "Container failed to start"
		done
		continue
	fi

	if ! wait_for_systemd "$CURRENT_CONTAINER"; then
		for t in "${TESTS[@]}"; do
			if [ -n "$FILTER_TEST" ] && [ "$t" != "$FILTER_TEST" ]; then
				continue
			fi
			fail "$t" "$os_name" "systemd boot timeout"
		done
		continue
	fi

	wait_for_packagekit "$CURRENT_CONTAINER"

	# Test execution
	for t in "${TESTS[@]}"; do
		# Apply --test filter
		if [ -n "$FILTER_TEST" ] && [ "$t" != "$FILTER_TEST" ]; then
			continue
		fi

		cleanup_test "$CURRENT_CONTAINER" "$t"

		# test-svc starts nginx which can take >60s on some distros due to
		# systemd waiting on network-online.target in the container.
		# FIXME: can we set that manually to have triggered?
		test_timeout=60
		case "$t" in
			test-svc) test_timeout=120 ;;
		esac

		output=""
		rc=0
		output=$(docker exec "$CURRENT_CONTAINER" \
			timeout "$test_timeout" mgmt run --tmp-prefix --no-watch --no-stream-watch --no-deploy-watch \
			--converged-timeout=1 \
			lang "/tests/${t}.mcl" 2>&1) || rc=$?

		if [ "$rc" -eq 124 ]; then
			{
				echo "--- $t: TIMEOUT after ${test_timeout}s ---"
				echo "$output"
				echo ""
			} >> "$OS_LOG"
			fail "$t" "$os_name" "Timeout after ${test_timeout}s (see $OS_LOG)"
			continue
		fi

		if [ "$rc" -ne 0 ]; then
			{
				echo "--- $t: mgmt exited with code $rc ---"
				echo "$output"
				echo ""
			} >> "$OS_LOG"
			fail "$t" "$os_name" "mgmt exited with code $rc (see $OS_LOG)"
			continue
		fi

		val_output=""
		val_rc=0
		val_output=$(validate_test "$CURRENT_CONTAINER" "$t" "$output" 2>&1) || val_rc=$?

		if [ "$val_rc" -ne 0 ]; then
			{
				echo "--- $t: validation failed ---"
				echo "$val_output"
				echo "mgmt output:"
				echo "$output"
				echo ""
			} >> "$OS_LOG"
			fail "$t" "$os_name" "Validation failed: $val_output (see $OS_LOG)"
			continue
		fi

		pass "$t"
	done
done

echo ""
echo "=== Container Test Harness Results ==="
TOTAL=$((PASS + FAIL))
echo "=== Summary: $PASS passed, $FAIL failed out of $TOTAL tests across $OS_COUNT operating system(s) ==="

if [ -n "$ERRORS" ]; then
	echo ""
	echo "Failures:"
	echo -e "$ERRORS"
	echo ""
	echo "Detailed logs: $LOG_DIR/"
fi

if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
exit 0
