#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

task_id="eliza-test-$$-$(date +%s)"
runtime_image="${task_id}:runtime"
restored_image="${task_id}:restored"
unit_image="${task_id}:unit"
client_image="${task_id}:client"
network="${task_id}-network"
volume="${task_id}-results"
server="${task_id}-server"
open_server="${task_id}-open"
client="${task_id}-client"
unit="${task_id}-unit"
import_daemon="${task_id}-import"
transfer_dir=$(mktemp -d "${TMPDIR:-/tmp}/eliza-delta.XXXXXX")
transfer_user="$(id -u):$(id -g)"
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
        docker logs "$import_daemon" 2>/dev/null || true
    fi
    docker rm -f "$client" "$unit" "$server" "$open_server" >/dev/null 2>&1 || true
    docker rm -fv "$import_daemon" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    docker volume rm "$volume" >/dev/null 2>&1 || true
    docker image rm "$runtime_image" "$restored_image" "$unit_image" "$client_image" >/dev/null 2>&1 || true
    rm -rf -- "$transfer_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# BuildKit's cached base need not have a tag in Docker's image store. Export a
# freshly resolved base and build against that tag; the helper checks its exact
# DiffIDs, failing if the registry tag moved between pull and build.
docker pull debian:trixie-slim
docker build --pull --target perl-tests -t "$unit_image" .
docker run --rm --name "$unit" --network none "$unit_image"
docker build --target runtime -t "$runtime_image" .
docker build -f tests/Dockerfile -t "$client_image" .
docker run --rm --name "$client" --network none --entrypoint python \
    "$client_image" -m unittest -v test_image_delta

docker image save -o "$transfer_dir/base.tar" debian:trixie-slim
docker image save -o "$transfer_dir/full.tar" "$runtime_image"
run_delta() {
    docker run --rm --name "$client" --network none --user "$transfer_user" \
        -v "$transfer_dir:/transfer" --entrypoint python \
        "$client_image" tools/image_delta.py "$@"
}
run_delta export --base /transfer/base.tar --image /transfer/full.tar --output /transfer/delta.tar.gz
run_delta assemble --base /transfer/base.tar --delta /transfer/delta.tar.gz \
    --output /transfer/restored.tar --tag "$restored_image"
docker image load -i "$transfer_dir/restored.tar"
test "$(docker image inspect "$runtime_image" --format '{{.Id}}')" = \
    "$(docker image inspect "$restored_image" --format '{{.Id}}')"
echo 'Reconstructed image ID matches source; running API tests using the reconstructed image.'

if [[ ${ELIZA_TEST_ISOLATED_IMPORT:-0} == 1 ]]; then
    # Opt-in because nested Docker requires a privileged container. No host
    # Docker socket or filesystem is mounted into this disposable daemon.
    docker run -d --privileged --name "$import_daemon" --network none \
        --entrypoint dockerd docker:29-dind \
        --host=unix:///var/run/docker.sock --storage-driver=vfs \
        --feature=containerd-snapshotter=false --iptables=false --bridge=none >/dev/null
    ready=0
    for ((attempt=0; attempt<60; attempt++)); do
        if docker exec "$import_daemon" docker info >/dev/null 2>&1; then ready=1; break; fi
        sleep 0.5
    done
    test "$ready" = 1
    docker exec -i "$import_daemon" docker image load < "$transfer_dir/base.tar"
    if docker exec "$import_daemon" docker image inspect "$runtime_image" >/dev/null 2>&1; then
        echo 'Isolated daemon unexpectedly contains the application image' >&2
        exit 1
    fi
    docker exec "$import_daemon" docker image save debian:trixie-slim > "$transfer_dir/target-base.tar"
    run_delta assemble --base /transfer/target-base.tar --delta /transfer/delta.tar.gz \
        --output /transfer/isolated-restored.tar --tag "$restored_image"
    docker exec -i "$import_daemon" docker image load < "$transfer_dir/isolated-restored.tar"
    test "$(docker exec "$import_daemon" docker image inspect "$restored_image" --format '{{.Id}}')" = \
        "$(docker image inspect "$runtime_image" --format '{{.Id}}')"
    docker exec "$import_daemon" docker run -d --name smoke --network none \
        --user "$random_uid:0" "${restricted[@]}" "$restored_image" >/dev/null
    ready=0
    for ((attempt=0; attempt<30; attempt++)); do
        if docker exec "$import_daemon" docker exec smoke perl -MMojo::UserAgent -e \
            'exit(Mojo::UserAgent->new->request_timeout(1)->get("http://127.0.0.1:8080/healthz")->result->is_success ? 0 : 1)' \
            >/dev/null 2>&1; then ready=1; break; fi
        sleep 0.2
    done
    test "$ready" = 1
    docker exec "$import_daemon" docker exec smoke perl -MMojo::UserAgent -MMojo::JSON=true -e '
        my $ua = Mojo::UserAgent->new->request_timeout(5);
        my $body = {model => "eliza", messages => [
            {role => "user", content => "my bicycle is blue"},
            {role => "user", content => "zzzxxy"}]};
        my $url = "http://127.0.0.1:8080/v1/chat/completions";
        my $res = $ua->post($url => json => $body)->result;
        die "memory replay failed" unless $res->is_success &&
            $res->json->{choices}[0]{message}{content} =~ /bicycle is blue/;
        $body->{stream} = true;
        $res = $ua->post($url => json => $body)->result;
        die "streaming failed" unless $res->is_success && $res->body =~ /data: \[DONE\]/;
        print "Isolated import, memory replay, and SSE smoke tests passed.\n";
    '
fi

docker network create --internal "$network" >/dev/null
docker volume create "$volume" >/dev/null
docker run -d --name "$server" --network "$network" --network-alias eliza \
    --user "$random_uid:0" "${restricted[@]}" \
    -e ELIZA_API_KEY=docker-test-key -e PERL_HASH_SEED=123 -e PERL_PERTURB_KEYS=1 \
    "$restored_image" >/dev/null
docker run -d --name "$open_server" --network "$network" --network-alias eliza-open \
    "${restricted[@]}" \
    -e PERL_HASH_SEED=98765 -e PERL_PERTURB_KEYS=1 "$restored_image" >/dev/null

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
    "$restored_image" >/dev/null
run_client after
check_identity "$server" "$second_uid" "$second_uid"

docker exec "$server" perl -MMojo::UserAgent -e \
    'exit(Mojo::UserAgent->new->get("http://127.0.0.1:8080/healthz")->result->is_success ? 0 : 1)'
docker image inspect "$runtime_image" --format 'Runtime image: {{.Size}} bytes; user: {{.Config.User}}'
echo "Docker end-to-end tests passed: default UID, arbitrary UIDs $random_uid and $second_uid, restricted settings, and deterministic replay after restart/replacement."
