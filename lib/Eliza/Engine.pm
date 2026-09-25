package Eliza::Engine;
use strict;
use warnings;
use Chatbot::Eliza;
use Digest::SHA qw(sha256_hex);

our $VERSION = '1';

sub new {
    my ($class, %args) = @_;
    my $seed = $args{seed} // 42;
    die "seed must be an integer from 1 to 2147483646\n"
        unless !ref($seed) && $seed =~ /\A[0-9]+\z/ && $seed >= 1 && $seed <= 2147483646;
    my $bot = Chatbot::Eliza->new;
    # Eliza uses keys() for matching, including equal-rank rules. Canonicalize
    # these three maps only, leaving Perl's global hash randomization intact.
    for my $field (qw(pre post decomplist)) {
        tie my %ordered, 'Eliza::Engine::OrderedRules', $bot->{$field};
        $bot->{$field} = \%ordered;
    }
    my $self = bless {bot => $bot, rng => 0 + $seed}, $class;
    # Capture a separate scalar reference, not $self (which would form a cycle).
    my $state = \$self->{rng};
    $bot->myrand(sub {
        $$state = ($$state * 48271) % 2147483647;
        return ($$state / 2147483647) * (defined $_[0] ? $_[0] : 1);
    });
    return $self;
}

sub transform { $_[0]->{bot}->transform($_[1]) }

sub replay {
    my ($class, $turns, %args) = @_;
    my $engine = $class->new(%args);
    my $reply;
    $reply = $engine->transform($_) for @$turns;
    return ($reply, $engine);
}

# Snapshot the mutable state that affects subsequent transform() calls.
sub state {
    my ($self) = @_;
    my $bot = $self->{bot};
    return {
        rng => $self->{rng},
        memory => [@{$bot->{memory}}],
        next_reasmblist => {%{$bot->{next_reasmblist} // {}}},
        next_reasmblist_for_memory => {%{$bot->{next_reasmblist_for_memory} // {}}},
    };
}

sub fingerprint {
    my @source;
    for my $file (__FILE__, $INC{'Chatbot/Eliza.pm'}) {
        open my $fh, '<:raw', $file or die "Cannot read engine source: $!";
        local $/;
        push @source, <$fh>;
    }
    return 'eliza-' . substr(sha256_hex(join "\0", $], @source), 0, 24);
}

package Eliza::Engine::OrderedRules;
use strict;
use warnings;

sub TIEHASH { bless {data => $_[1]}, $_[0] }
sub FETCH { $_[0]->{data}{$_[1]} }
sub EXISTS { exists $_[0]->{data}{$_[1]} }
sub SCALAR { scalar %{$_[0]->{data}} }
sub FIRSTKEY {
    $_[0]->{keys} = [sort keys %{$_[0]->{data}}];
    return shift @{$_[0]->{keys}};
}
sub NEXTKEY { shift @{$_[0]->{keys}} }
sub STORE { die "Eliza rule maps are read-only\n" }
sub DELETE { die "Eliza rule maps are read-only\n" }
sub CLEAR { die "Eliza rule maps are read-only\n" }

1;
