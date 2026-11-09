use strict;
use warnings;
#use v5.36; # for signatures
use Perl5::Bisect;
use Test::More;
use Data::Dump qw(dd pp);

note("needs revision because interface not yet ready");
ok(1, "hello world");

#my ($issue, $module, $start, $end);
#
#{
#    $issue = 24827;
#    $module = 'B::Utils';
#    $start = '7d4c4f980edaec3dc4dae350cc33cc758716a2e9';
#    $end   = '033e40522c9a6369f97a67736e705d2dc2ba6f7d';
#    basic_bbc_check($issue, $module, $start, $end);
#}
#
###### TESTING SUBROUTINES #####
#
#sub basic_bbc_check {
#    my ($issue, $module, $start, $end) = @_;
#
#    local @ARGV = (
#        "--module=$module",
#        "--start=$start",
#        "--end=$end",
#    );
#
#    my $self = Perl5::Bisect->new();
#pp $self;
#    ok(defined $self,
#        "preliminary_check() returned defined value for issue GH $issue");
#    isa_ok($self, 'Perl5::Bisect');
#
#    # test get_argv()
#    # test get_argv_as_string()
#    # test get_options()
#
#    my $argv_str = $self->get_argv_as_string;
#
#    # Make flexible enough to handle --with-module
#    like($argv_str, qr/--module\s$module/,
#        "$module is subject of bisection");
#    is(ref($self->get_options), 'HASH', "internal hashref h");
#    is($self->get_options->{start}, $start, "Got expected value for 'start' commit");
#    is($self->get_options->{end}, $end, "Got expected value for 'end' commit");
#    ok(! $self->{bad}, "No problem observed in options processing");
#    ok($self->{check_for_cpan_config},
#        "Not having provided an explicit CPAN config file, we will check for one");
#}

done_testing();

