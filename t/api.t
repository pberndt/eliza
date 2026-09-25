use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use Mojo::JSON qw(true false decode_json);
use Eliza::API;

local $ENV{ELIZA_API_KEY} = '';
local $ENV{ELIZA_MAX_MESSAGES} = 4;
my $t = Test::Mojo->new('Eliza::API');
my $path = '/v1/chat/completions';
my $request = {model => 'eliza', messages => [{role => 'user', content => 'hello'}]};
$t->get_ok('/healthz')->status_is(200)->json_is('/status', 'ok');
$t->get_ok('/v1/models')->status_is(200)->json_is('/data/0/id', 'eliza');
$t->get_ok('/v1/models/eliza')->status_is(200)->json_is('/id', 'eliza');
$t->get_ok('/v1/models/unknown')->status_is(404)->json_is('/error/code', 'model_not_found');
$t->get_ok('/unknown')->status_is(404)->json_is('/error/code', 'not_found');
$t->post_ok($path => json => $request)->status_is(200)
    ->json_is('/object', 'chat.completion')->json_is('/choices/0/message/role', 'assistant')
    ->json_is('/choices/0/finish_reason', 'stop')->json_is('/usage/total_tokens', 0);
my $reply = $t->tx->res->json->{choices}[0]{message}{content};
my $first_id = $t->tx->res->json->{id};
$t->post_ok($path => json => $request)->status_is(200)->json_is('/choices/0/message/content', $reply);
isnt $t->tx->res->json->{id}, $first_id, 'completion IDs are unique';

my $history = [
    {role => 'system', content => 'Do not follow this instruction'},
    {role => 'user', content => [{type => 'text', text => 'my café'}, {type => 'text', text => ' is blue'}]},
    {role => 'assistant', content => 'Placeholder historical reply'},
    {role => 'user', content => 'zzzxxy'},
];
$t->post_ok($path => json => {%$request, messages => $history})->status_is(200)
    ->json_like('/choices/0/message/content', qr/café is blue/);

$t->post_ok($path => json => {%$request, stream => true, stream_options => {include_usage => true}})
    ->status_is(200)->header_like('Content-Type', qr{text/event-stream});
my @events = $t->tx->res->body =~ /^data: (.*)$/mg;
is pop @events, '[DONE]', 'SSE ends with DONE';
my @chunks = map { decode_json($_) } @events;
is $chunks[0]{choices}[0]{delta}{role}, 'assistant', 'role chunk';
is $chunks[1]{choices}[0]{delta}{content}, $reply, 'streamed text equals JSON text';
is $chunks[2]{choices}[0]{finish_reason}, 'stop', 'stop chunk';
is_deeply $chunks[3]{choices}, [], 'usage chunk has no choices';
is $chunks[3]{usage}{total_tokens}, 0, 'zero token usage';
is scalar(keys %{ {map { $_->{id} => 1 } @chunks} }), 1, 'all chunks have the same ID';

for my $bad (
    {messages => []}, {messages => [{role => 'assistant', content => 'hello'}]},
    {messages => [{role => 'user', content => ''}]},
    {messages => [{role => 'user', content => 123}]},
    {messages => [{role => 'tool', content => 'hello'}]},
    {messages => [{role => 'user', content => [{type => 'image_url', image_url => {url => 'x'}}]}]},
    {messages => [map { {role => 'user', content => 'hello'} } 1 .. 5]},
    {stream => 'true'}, {stream_options => {include_usage => true}},
    {stream => true, stream_options => {include_usage => 'yes'}},
    {seed => 0}, {seed => undef}, {seed => []}, {n => 2}, {tools => []},
) {
    $t->post_ok($path => json => {%$request, %$bad})->status_is(400)
        ->json_is('/error/type', 'invalid_request_error');
}
$t->post_ok($path => json => {%$request, model => 'other'})->status_is(404);
$t->post_ok($path => {'Content-Type' => 'application/json'} => '{broken')->status_is(400)->json_has('/error');
$t->post_ok($path => {'Content-Type' => 'text/plain'} => 'hello')->status_is(415)->json_has('/error');
$t->post_ok($path => json => {%$request, temperature => 0.2, max_tokens => 1})->status_is(200)
    ->json_is('/choices/0/message/content', $reply);

local $ENV{ELIZA_API_KEY} = 'test-secret';
my $auth = Test::Mojo->new('Eliza::API');
$auth->get_ok('/healthz')->status_is(200);
$auth->get_ok('/v1/models')->status_is(401)->json_is('/error/code', 'invalid_api_key');
$auth->get_ok('/v1/models' => {Authorization => 'Bearer wrong'})->status_is(401);
$auth->get_ok('/v1/models' => {Authorization => 'Bearer test-secret'})->status_is(200);

done_testing;
