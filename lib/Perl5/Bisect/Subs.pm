package Perl5::Bisect::Subs;
use 5.14.0;
use warnings;
#use Data::Dump qw(dd pp);
our ( $VERSION, @ISA, @EXPORT_OK );
$VERSION = "0.01";
require Exporter;
@ISA         = qw(Exporter);
@EXPORT_OK = ( qw|
    validate
|);

=head1 NAME

Perl5::Bisect::Subs - Functionality for F<bin/bisect.pl>

=head1 DESCRIPTION

This package exports on request only those subroutines which were previously
defined in the Perl 5 core distribution's F<Porting/bisect.pl>.  There
actually was only one such subroutine, C<validate()>, all other subroutines
having been defined in F<Porting/bisect-runner.pl>.  Those subroutines have
been moved into C<Perl5::Bisect::Auxiliary> and C<Perl5::Bisect::Patching>.

=head1 SUBROUTINES

=head2 C<validate()>

=over 4

=item * Purpose

Test that all stable (.0) revisions can be built. By default, attempts to
build I<blead>, then tagged stable releases in reverse order down to

=item * Arguments

    $result = validate($commit, $args);

List of two arguments:

=over 4

=item * Scalar holding either C<blead> or the name of a tag of a stable (C<.0>) Perl release.

=item * Reference to a hash with these elements:

    $args = {
        start   => $start,      # start commit for bisection
        end     => $end,        # end commit for bisection
        verbose => $verbose,    # verbosity level in caller
        brunner => $brunner,    # path to bisect-runner program
        argv    => [@ARGV],     # reference to current @ARGV
    };

=back

=item * Return Value

Returns undefined value if the commit provided in the first argument is
earlier than the C<start> commit or if the commit provided in the first
argument is later than the C<end>commit.

Upon success it will simply return the string originally supplied in the first
argument.

=item * Comments

C<validate()> assumes you have F<git> installed and are operating in a F<git
checkout> of the Perl 5 repository.

C<validate()> attempts to make a F<git checkout> from the Perl 5 core
distribution of the commit provided in the first argument and will C<die> if
that is not possible.

C<validate()> will print debugging information if C<verbose> has been set to
a true value.

C<validate()> will then call the bisect-runner (with the C<--no-clean> switch
and the current C<@ARGV>).  It will C<die> upon failure of any subsequent
F<git> operation.

=back

=cut

sub validate {
    my $commit = shift;

    my $args = shift;
    if (defined $args->{start} && `git rev-list -n1 $commit ^$args->{start}^` eq "") {
        print "Skipping $commit, as it is earlier than $args->{start}\n";
        return;
    }
    if (defined $args->{end} && `git rev-list -n1 $args->{end} ^$commit^` eq "") {
        print "Skipping $commit, as it is more recent than $args->{end}\n";
        return;
    }
    print "Testing $commit...\n";
    system "git checkout $commit </dev/null" and die;
    say 'RUNNER INVOCATION #3' if $args->{verbose};
    my $ret = system $^X, $args->{brunner}, '--no-clean', @{$args->{argv}};
    die "Runner returned $ret, not 0 for revision $commit" if $ret;

    system 'git clean -dxf </dev/null' and die;
    system 'git reset --hard HEAD </dev/null' and die;
    return $commit;
}

1;
