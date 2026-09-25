#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

task_id="eliza-test-$$-$(date +%s)"
runtime_image="${task_id}:runtime"
unit_image="${task_id}:unit"
client_image="${task_id}:client"
network="${task_id}-network"
volume="${task_id}-results"
server="${task_id}-server"
open_server="${task_id}-open"
client="${task_id}-client"
unit="${task_id}-unit"
# Namespace-style UIDs deliberately absent from the image's passwd database.
random_uid=$((1000000000 + RANDOM * 32768 + RANDOM))
second_uid=$((random_uid + 1))
restricted=(--cap-drop ALL --security-opt no-new-privileges=true
    --read-only --tmpfs /tmp:rw,noexec,nosuid,mode=1777,size=16m)

cleanup() {
    status=$?
    trap - EXIT
    if (( status != 0 )); then
        docker logs "$server" 2>/dev/null || true
        docker logs "$open_server" 2>/dev/null || true
    fi
    docker rm -f "$client" "$unit" "$server" "$open_server" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    docker volume rm "$volume" >/dev/null 2>&1 || true
    docker image rm "$runtime_image" "$unit_image" "$client_image" >/dev/null 2>&1 || true
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker build --target perl-tests -t "$unit_image" .
docker run --rm --name "$unit" --network none "$unit_image"
docker build --target runtime -t "$runtime_image" .
docker build -f tests/Dockerfile -t "$client_image" .
docker network create --internal "$network" >/dev/null
docker volume create "$volume" >/dev/null
docker run -d --name "$server" --network "$network" --network-alias eliza \
    --user "$random_uid:0" "${restricted[@]}" \
    -e ELIZA_API_KEY=docker-test-key -e PERL_HASH_SEED=123 -e PERL_PERTURB_KEYS=1 \
    "$runtime_image" >/dev/null
docker run -d --name "$open_server" --network "$network" --network-alias eliza-open \
    "${restricted[@]}" \
    -e PERL_HASH_SEED=98765 -e PERL_PERTURB_KEYS=1 "$runtime_image" >/dev/null

run_client() {
    docker run --rm --name "$client" --network "$network" \
        -v "$volume:/results" "$client_image" "$1"
}
run_client before
docker restart -t 5 "$server" >/dev/null
run_client after

check_identity() {
    local container="$1" expected_uid="$2" expected_gid="$3"
    test "$(docker exec "$container" id -u)" = "$expected_uid"
    test "$(docker exec "$container" id -g)" = "$expected_gid"
    docker exec "$container" perl -MFile::Temp=tempfile -e '
        die "unexpected passwd entry" if defined getpwuid($<);
        die "HOME must be writable" unless -w $ENV{HOME};
        my ($fh, $path) = tempfile(DIR => $ENV{TMPDIR}, UNLINK => 1);
        print $fh "arbitrary UID can write temporary files\n";
        open my $status, "<", "/proc/1/status" or die $!;
        local $/;
        my $text = <$status>;
        die "capabilities remain" unless $text =~ /^CapEff:\s+0+$/m;
        die "privilege escalation allowed" unless $text =~ /^NoNewPrivs:\s+1$/m;
    '
}
check_identity "$server" "$random_uid" 0
check_identity "$open_server" 10001 0

# Also prove that code reads, temporary files, and replay do not depend on
# membership in group 0, including after replacement with a different UID.
docker rm -f "$server" >/dev/null
docker run -d --name "$server" --network "$network" --network-alias eliza \
    --user "$second_uid:$second_uid" "${restricted[@]}" \
    -e ELIZA_API_KEY=docker-test-key -e PERL_HASH_SEED=456 -e PERL_PERTURB_KEYS=1 \
    "$runtime_image" >/dev/null
run_client after
check_identity "$server" "$second_uid" "$second_uid"

docker exec "$server" perl -MMojo::UserAgent -e \
    'exit(Mojo::UserAgent->new->get("http://127.0.0.1:8080/healthz")->result->is_success ? 0 : 1)'
docker image inspect "$runtime_image" --format 'Runtime image: {{.Size}} bytes; user: {{.Config.User}}'
echo "Docker end-to-end tests passed: default UID, arbitrary UIDs $random_uid and $second_uid, restricted settings, and deterministic replay after restart/replacement."
