use strict;
use warnings;
#use v5.36; # for signatures
use Perl5::Bisect;
use Test::More;
use Data::Dump qw(dd pp);

my ($issue, $module, $start, $end);

{
    $issue = 24827;
    $module = 'B::Utils';
    $start = '7d4c4f980edaec3dc4dae350cc33cc758716a2e9';
    $end   = '033e40522c9a6369f97a67736e705d2dc2ba6f7d';
    basic_bbc_check($issue, $module, $start, $end);
}

sub basic_bbc_check {
    my ($issue, $module, $start, $end) = @_;

    local @ARGV = (
        "--module=$module",
        "--start=$start",
        "--end=$end",
    );

    my $self = Perl5::Bisect->new();
    ok(defined $self,
        "preliminary_check() returned defined value for issue GH $issue");
    isa_ok($self, 'Perl5::Bisect');
    my $argv_str = join(' ' => @{$self->{argv}});
    # Make flexible enough to handle --with-module
    like($argv_str, qr/--module\s$module/,
        "$module is subject of bisection");
    is(ref($self->{h}), 'HASH', "internal hashref h");
    is($self->{h}->{start}, $start, "Got expected 'start' commit");
    is($self->{h}->{end}, $end, "Got expected 'end' commit");
    ok(! $self->{bad}, "No problem observed in options processing");
    ok($self->{check_for_cpan_config},
        "Not having provided an explicit CPAN config file, we will check for one");
}

done_testing();

