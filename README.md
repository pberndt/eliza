# Eliza with an OpenAI-compatible API

Eliza, Joseph Weizenbaum's classic 1966 program, is a mock Rogerian
psychotherapist that uses a simple transformation algorithm to change user
input into a follow-up question.

A local pseudo-LLM backed by Debian's `libchatbot-eliza-perl` package. The runtime
is Perl and Mojolicious on Debian slim. It uses Eliza's built-in English script;
no model weights, OpenAI account, external API, or GPU are needed.

## Build and run

```sh
make build
docker run --rm -p 127.0.0.1:8080:8080 eliza-openai:local
```

The container defaults to UID/GID `10001:0`, supports arbitrary non-root UIDs,
listens on port 8080, and includes a health check. It also supports
`--read-only --tmpfs /tmp`. Runtime packages
are installed without recommendations; Python and the OpenAI SDK are only in
the separate test image.

```sh
curl http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"eliza","messages":[{"role":"user","content":"my bicycle is blue"}]}'
```

For streaming, add `"stream":true` and use `curl -N`.

## Interactive terminal chat with llm

[LLM](https://llm.datasette.io/en/stable/usage.html#starting-an-interactive-chat)
provides a simple interactive chat that keeps conversation history. With
[uv](https://docs.astral.sh/uv/getting-started/installation/) installed, install
the client on your host:

```sh
uv tool install llm
```

If uv reports that its executable directory is missing from `PATH`, run
`uv tool update-shell` and open a new terminal.

Start the Eliza container using the commands above, then open another terminal.
Find LLM's configuration directory:

```sh
dirname "$(llm logs path)"
```

Create `extra-openai-models.yaml` in that directory, or append this entry to an
existing file:

```yaml
- model_id: eliza
  model_name: eliza
  api_base: http://localhost:8080/v1
```

This uses LLM's built-in support for
[OpenAI-compatible endpoints](https://llm.datasette.io/en/stable/other-models.html#configure-an-openai-compatible-model).
With the default unauthenticated Eliza configuration, no API key is needed.
Start chatting:

```sh
llm chat -m eliza
```

For example, enter `my bicycle is blue`, then `zzzxxy` to exercise Eliza's memory
recall. The client resends the conversation history automatically. Type `quit`
or `exit` to leave; `llm chat -c` resumes your most recent conversation.

## OpenAI Python client and conversations

Point your client's base URL at `http://localhost:8080/v1`, and select model
`eliza`. When authentication is disabled, the SDK still requires a nonempty
placeholder key.

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8080/v1", api_key="unused")
messages = [{"role": "user", "content": "my bicycle is blue"}]
reply = client.chat.completions.create(model="eliza", messages=messages, seed=42)
print(reply.choices[0].message.content)

messages.append({"role": "assistant", "content": reply.choices[0].message.content})
messages.append({"role": "user", "content": "zzzxxy"})
for chunk in client.chat.completions.create(
    model="eliza", messages=messages, seed=42, stream=True,
    stream_options={"include_usage": True},
):
    if chunk.choices:
        print(chunk.choices[0].delta.content or "", end="", flush=True)
print()
```

Clients own conversation history. Send all preceding user turns on every
request; assistant replies may be included as usual. Every request creates a
fresh Eliza instance and replays the user turns, returning only the final reply.
There are no persistent server sessions, cookies, session IDs, or volumes.
Conversations are isolated, and restarting the same image does not lose context
when the client resends its history. Truncating history also truncates Eliza's
reconstructed state. Replay cost grows with the supplied history.

### Determinism

The unmodified package is **not** deterministic with `srand()` alone: matching
uses randomized Perl hash traversal. Our adapter gives the `pre`, `post`, and
`decomplist` maps canonical lexical iteration order and installs an independent
Park–Miller RNG through Eliza's supported `myrand` callback. The package on disk
is unchanged; Perl's global hash randomization remains enabled. Canonical rule
ordering deliberately resolves ambiguous matches consistently.

`seed` defaults to **42** and accepts integers **1–2147483646**. Keep it constant
throughout a conversation. With the same history, seed, and engine/runtime
version, replies and mutable state are reproducible, including after restart.
The default script's memory probability is 1, so changing the seed need not
change replies. Response IDs and timestamps are intentionally not deterministic.
`system_fingerprint` identifies the adapter source, installed Eliza source, and
Perl version. Rebuilt images can contain updated packages; retain the same image
digest when replaying long-lived histories. Arbitrary engine upgrades are not
promised to preserve wording.

## Supported API

| Endpoint | Behavior |
| --- | --- |
| `GET /healthz` | Unauthenticated readiness check |
| `GET /v1/models` | Lists `eliza` |
| `GET /v1/models/eliza` | Model metadata |
| `POST /v1/chat/completions` | JSON or SSE text completion |

- Messages accept strings or arrays of `{ "type": "text", "text": "..." }`.
  Text parts are concatenated in order. The final message must be a nonempty
  user message. All user turns must contain non-whitespace text.
- `system`, `developer`, and `assistant` text is accepted but ignored by Eliza.
  Eliza does not follow system instructions or interpret historical assistant text.
- `n` must be 1. `temperature`, `top_p`, `max_tokens`, `max_completion_tokens`,
  `frequency_penalty`, and `presence_penalty` are accepted **without effect**.
  `user`, `metadata`, and message `name` are also ignored.
- Usage fields are zero: Eliza consumes no LLM tokens. These are not text-length
  estimates. With `stream_options.include_usage=true`, an additional usage chunk
  has an empty `choices` array.
- Streaming sends an assistant-role chunk, one complete content chunk, a stop
  chunk, optional usage, and `[DONE]`, without artificial typing delays.
- Tools, images/audio, structured output, stop sequences, log probabilities,
  unknown request parameters, the Responses API, and legacy Completions are
  unsupported. Invalid requests use an OpenAI-shaped `error` object.

## Configuration

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `ELIZA_API_KEY` | Empty | If set, require `Authorization: Bearer ...` on `/v1` |
| `ELIZA_MAX_REQUEST_BYTES` | `1048576` | Maximum HTTP request size |
| `ELIZA_MAX_MESSAGES` | `256` | Maximum entries in the messages array |

Set variables with Docker's `-e` or `--env-file`. No real OpenAI key is needed.
The service logs to stderr without logging conversation bodies.

## OpenShift

The image supports OpenShift-assigned UIDs, including UIDs without an
`/etc/passwd` entry. Application files are readable but not writable; `HOME` and
`TMPDIR` point to `/tmp`. Startup requires no root privileges, capabilities,
passwd-file changes, or writable application directory.

Let OpenShift assign the UID and volume groups: do not set `runAsUser`,
`runAsGroup`, or `fsGroup` to the image's default IDs in your Deployment.
The following pod-spec example uses settings compatible with
[OpenShift's restricted-v2 SCC](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/authentication_and_authorization/managing-pod-security-policies).
Replace the image reference with your pushed image, preferably pinned by digest:

```yaml
# Under spec.template.spec in a Deployment:
automountServiceAccountToken: false
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
containers:
  - name: eliza
    image: your-registry/your-project/eliza-openai:your-tag
    ports:
      - name: http
        containerPort: 8080
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: [ALL]
    volumeMounts:
      - name: tmp
        mountPath: /tmp
    readinessProbe:
      httpGet:
        path: /healthz
        port: http
    livenessProbe:
      httpGet:
        path: /healthz
        port: http
      initialDelaySeconds: 5
volumes:
  - name: tmp
    emptyDir:
      sizeLimit: 16Mi
```

The `/tmp` volume permits temporary request-body storage with a read-only root
filesystem. Point your Service's `targetPort` at `http` (8080). Kubernetes uses
the probes above rather than the Dockerfile's `HEALTHCHECK`. If authentication
is desired, supply `ELIZA_API_KEY` from a Secret; health probes need no key.

`make test` checks the image under Docker with arbitrary UIDs, dropped
capabilities, no privilege escalation, and a read-only root filesystem. These
checks do not replace validation against your cluster's SCC and SELinux policy;
no live OpenShift deployment has been tested here.

## Tests

```sh
make test
```

Requires Docker and Bash on the host. The test builds all images, runs the Perl
tests, and exercises the runtime over an isolated Docker network using a pinned
OpenAI Python SDK. It covers JSON and streaming, UTF-8, memory recall, isolation,
concurrency, authentication, validation, limits, and exact transcript equality
after a container restart. The Perl tests compare every replayed turn's reply,
memory, reply counters, and RNG state with one continuously alive instance, and
compare fresh interpreters with different hash seeds. The HTTP suite runs before
and after restart under a random UID with group 0, then after replacing the
container with another random UID and a nonzero group. It also checks the default
UID, temporary-file access, large request-body storage, dropped capabilities, and
no privilege escalation, and prints the runtime image size. Containers, network, result volume,
and temporary image tags are cleaned up; build caches remain for later runs.

For local Perl tests, install `libchatbot-eliza-perl` and `libmojolicious-perl`,
then run `make test-unit`. `make build IMAGE=your-tag` sets the runtime image tag.
