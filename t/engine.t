use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP;
use Eliza::Engine;

my @turns = (
    'hello', 'I remember my mother and my father', 'I feel sad and I want help',
    'my bicycle is blue', 'zzzxxy', 'you remind me of my mother',
    'I am unhappy because I dream', 'hello', 'hello', 'hello', 'hello', 'hello',
    'my café is beautiful', 'zzzxxy', 'I am sorry', 'I cannot sleep',
);

for my $seed (1, 42, 2147483646) {
    subtest "replay equals a live instance, seed $seed" => sub {
        my $live = Eliza::Engine->new(seed => $seed);
        my @prefix;
        for my $turn (@turns) {
            push @prefix, $turn;
            my $expected = $live->transform($turn);
            # An unrelated conversation and global RNG use must not affect it.
            Eliza::Engine->replay(['my boat is green', 'zzzxxy']);
            rand() for 1 .. 10;
            my ($actual, $replayed) = Eliza::Engine->replay(\@prefix, seed => $seed);
            is $actual, $expected, 'same reply at turn ' . scalar(@prefix);
            is_deeply $replayed->state, $live->state, 'same complete mutable state';
        }
    };
}

my ($remembered) = Eliza::Engine->replay(['my bicycle is blue', 'zzzxxy']);
like $remembered, qr/bicycle is blue/, 'prior user detail is recalled';
my ($fresh) = Eliza::Engine->replay(['zzzxxy']);
unlike $fresh, qr/bicycle/, 'fresh conversation has no leaked memory';

subtest 'per-instance random generators are independent' => sub {
    my $a = Eliza::Engine->new(seed => 99);
    my $b = Eliza::Engine->new(seed => 99);
    my $c = Eliza::Engine->new(seed => 100);
    my (@a, @b, @c);
    for (1 .. 10) {
        push @a, $a->{bot}->myrand->(1);
        rand() for 1 .. 10;
        push @c, $c->{bot}->myrand->(1);
        push @b, $b->{bot}->myrand->(1);
    }
    is_deeply \@a, \@b, 'same seed gives the same stream despite interleaving';
    isnt join(',', @a), join(',', @c), 'different seeds give different random streams';
};

subtest 'fresh interpreters and hash seeds produce identical transcripts and state' => sub {
    my $source = q{
        use Eliza::Engine;
        use JSON::PP;
        my $turns = decode_json($ARGV[0]);
        my $engine = Eliza::Engine->new(seed => 42);
        my @results;
        for (@$turns) { push @results, [$engine->transform($_), $engine->state] }
        print JSON::PP->new->canonical->utf8->encode(\@results);
    };
    my $expected;
    for my $hash_seed (0, 1, 42, 12345, 98765) {
        local $ENV{PERL_HASH_SEED} = $hash_seed;
        local $ENV{PERL_PERTURB_KEYS} = 1;
        open my $child, '-|', $^X, '-Ilib', '-e', $source, encode_json(\@turns) or die $!;
        my $result = do { local $/; <$child> };
        close $child;
        is $?, 0, 'child exited successfully';
        $expected //= $result;
        is $result, $expected, "same transcript and state with hash seed $hash_seed";
    }
};

for my $seed (0, -1, 'abc', 1.5, 2147483647) {
    eval { Eliza::Engine->new(seed => $seed) };
    like $@, qr/seed must be/, "reject invalid seed $seed";
}
like(Eliza::Engine->fingerprint, qr/^eliza-[a-f0-9]{24}$/, 'engine fingerprint');
done_testing;
