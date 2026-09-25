package Eliza::API;
use Mojo::Base 'Mojolicious';
use Mojo::JSON qw(encode_json true false);
use Mojo::Util qw(secure_compare);
use Eliza::Engine;

sub _positive_env {
    my ($name, $default) = @_;
    my $value = $ENV{$name} // $default;
    die "$name must be a positive integer\n" unless $value =~ /\A[1-9][0-9]*\z/;
    return 0 + $value;
}

sub _string { defined $_[0] && !ref($_[0]) && encode_json($_[0]) =~ /\A"/ }
sub _boolean { ref($_[0]) && (ref($_[0]) eq ref(true)) }

sub startup {
    my ($self) = @_;
    $self->mode('production');
    $self->log->level('info');
    $self->max_request_size(_positive_env('ELIZA_MAX_REQUEST_BYTES', 1048576));
    my $max_messages = _positive_env('ELIZA_MAX_MESSAGES', 256);
    my $api_key = $ENV{ELIZA_API_KEY} // '';
    my $fingerprint = Eliza::Engine->fingerprint;
    my $model = {id => 'eliza', object => 'model', created => 0, owned_by => 'local'};

    $self->helper(api_error => sub {
        my ($c, $status, $message, $param, $code) = @_;
        return $c->render(status => $status, json => {error => {
            message => $message,
            type => $status == 401 ? 'authentication_error' : $status >= 500 ? 'server_error' : 'invalid_request_error',
            param => $param, code => $code // 'invalid_request',
        }});
    });
    $self->helper('reply.exception' => sub {
        my ($c) = @_;
        $c->app->log->error('Request failed with an internal error');
        $c->api_error(500, 'Internal server error', undef, 'internal_error');
    });
    $self->hook(before_dispatch => sub {
        my ($c) = @_;
        if (my $error = $c->req->error) {
            my $status = $c->req->is_limit_exceeded ? 413 : 400;
            $c->api_error($status, $status == 413 ? 'Request too large' : 'Malformed HTTP request');
        }
    });

    $self->routes->get('/healthz')->to(cb => sub { $_[0]->render(json => {status => 'ok'}) });
    my $api = $self->routes->under('/v1')->to(cb => sub {
        my ($c) = @_;
        if (length $api_key && !secure_compare($c->req->headers->authorization // '', "Bearer $api_key")) {
            $c->res->headers->www_authenticate('Bearer');
            $c->api_error(401, 'Invalid API key', undef, 'invalid_api_key');
            return undef;
        }
        return 1;
    });
    $api->get('/models')->to(cb => sub { $_[0]->render(json => {object => 'list', data => [$model]}) });
    $api->get('/models/:model')->to(cb => sub {
        my ($c) = @_;
        return $c->api_error(404, 'Unknown model', 'model', 'model_not_found') unless $c->stash('model') eq 'eliza';
        $c->render(json => $model);
    });
    $api->post('/chat/completions')->to(cb => sub {
        my ($c) = @_;
        return $c->api_error(415, 'Use application/json')
            unless ($c->req->headers->content_type // '') =~ m{\Aapplication/json(?:\s*;|\z)}i;
        my $body = $c->req->json;
        return $c->api_error(400, 'Expected a JSON object') unless ref($body) eq 'HASH';
        return $c->api_error(404, 'Unknown model; use eliza', 'model', 'model_not_found')
            unless _string($body->{model}) && $body->{model} eq 'eliza';
        my %allowed = map { $_ => 1 } qw(model messages stream stream_options seed n temperature top_p max_tokens max_completion_tokens frequency_penalty presence_penalty user metadata);
        for my $key (sort keys %$body) {
            return $c->api_error(400, "Unsupported parameter: $key", $key, 'unsupported_parameter') unless $allowed{$key};
        }
        return $c->api_error(400, 'Only n=1 is supported', 'n')
            if exists $body->{n} && (ref($body->{n}) || !defined($body->{n}) || $body->{n} !~ /\A1\z/);
        return $c->api_error(400, 'stream must be a boolean', 'stream')
            if exists $body->{stream} && !_boolean($body->{stream});
        my $stream = $body->{stream} // false;
        my $include_usage = 0;
        if (exists $body->{stream_options}) {
            my $options = $body->{stream_options};
            return $c->api_error(400, 'stream_options requires stream=true and an object', 'stream_options')
                unless $stream && ref($options) eq 'HASH';
            return $c->api_error(400, 'Only include_usage is supported in stream_options', 'stream_options')
                if grep { $_ ne 'include_usage' } keys %$options;
            return $c->api_error(400, 'include_usage must be a boolean', 'stream_options.include_usage')
                if exists $options->{include_usage} && !_boolean($options->{include_usage});
            $include_usage = $options->{include_usage} // 0;
        }
        my $seed = exists $body->{seed} ? $body->{seed} : 42;
        return $c->api_error(400, 'seed must be an integer from 1 to 2147483646', 'seed')
            unless defined($seed) && !ref($seed) && $seed =~ /\A[0-9]+\z/ && $seed >= 1 && $seed <= 2147483646;
        my $messages = $body->{messages};
        return $c->api_error(400, "messages must contain 1 to $max_messages entries", 'messages')
            unless ref($messages) eq 'ARRAY' && @$messages && @$messages <= $max_messages;
        my @turns;
        for my $message (@$messages) {
            return $c->api_error(400, 'Each message needs a supported role and text content', 'messages')
                unless ref($message) eq 'HASH' && _string($message->{role})
                    && $message->{role} =~ /\A(user|assistant|system|developer)\z/;
            return $c->api_error(400, 'Tool calls and non-text messages are unsupported', 'messages')
                if grep { $_ ne 'role' && $_ ne 'content' && $_ ne 'name' } keys %$message;
            my $content = $message->{content};
            if (ref($content) eq 'ARRAY') {
                return $c->api_error(400, 'Only text content parts are supported', 'messages')
                    if grep { ref($_) ne 'HASH' || !_string($_->{type}) || $_->{type} ne 'text' || !_string($_->{text}) } @$content;
                $content = join '', map { $_->{text} } @$content;
            }
            return $c->api_error(400, 'Message content must be text', 'messages') unless _string($content);
            if ($message->{role} eq 'user') {
                return $c->api_error(400, 'User messages must not be empty', 'messages') unless $content =~ /\S/;
                push @turns, $content;
            }
        }
        return $c->api_error(400, 'The final message must have role user', 'messages') unless $messages->[-1]{role} eq 'user';

        my ($reply) = Eliza::Engine->replay(\@turns, seed => $seed);
        open my $random, '<:raw', '/dev/urandom' or die 'Cannot open random source';
        read($random, my $bytes, 16) == 16 or die 'Cannot generate completion ID';
        close $random;
        my %common = (id => 'chatcmpl-' . unpack('H*', $bytes), created => time, model => 'eliza', system_fingerprint => $fingerprint);
        my $usage = {prompt_tokens => 0, completion_tokens => 0, total_tokens => 0};
        unless ($stream) {
            return $c->render(json => {%common, object => 'chat.completion', usage => $usage, choices => [
                {index => 0, message => {role => 'assistant', content => $reply, refusal => undef}, logprobs => undef, finish_reason => 'stop'}
            ]});
        }
        my @chunks;
        for my $part ([{role => 'assistant'}, undef], [{content => $reply}, undef], [{}, 'stop']) {
            push @chunks, {%common, object => 'chat.completion.chunk', choices => [
                {index => 0, delta => $part->[0], logprobs => undef, finish_reason => $part->[1]}
            ], ($include_usage ? (usage => undef) : ())};
        }
        push @chunks, {%common, object => 'chat.completion.chunk', choices => [], usage => $usage} if $include_usage;
        $c->res->headers->cache_control('no-cache');
        $c->res->headers->header('X-Accel-Buffering' => 'no');
        # Eliza has already produced its short reply; frame it as SSE without
        # adding artificial delays or retaining any per-client state.
        $c->render(data => join('', map { 'data: ' . encode_json($_) . "\n\n" } @chunks) . "data: [DONE]\n\n",
            format => 'txt');
        $c->res->headers->content_type('text/event-stream; charset=utf-8');
    });
    $self->routes->any('/*unmatched')->to(cb => sub { $_[0]->api_error(404, 'Unknown endpoint', undef, 'not_found') });
    $self->routes->any('/')->to(cb => sub { $_[0]->api_error(404, 'Unknown endpoint', undef, 'not_found') });
}

1;
