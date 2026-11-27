package Perl5::Bisect;
use 5.14.0;
use warnings;
our $VERSION = "0.01";
use Cwd;
use File::Spec;
use Getopt::Long qw(:config pass_through no_auto_abbrev);
use Data::Dump qw(dd pp);
use lib ('blib/lib');
use Perl5::Bisect::Auxiliary qw(
);
use Perl5::Bisect::Patching qw(
);
use Perl5::Bisect::Subs qw(
);

=head1 NAME

Perl5::Bisect - Bisection of the Perl core distribution, modularized

=head1 DESCRIPTION

Very little here yet -- only a constructor which encapsulates what were 100+ lines in F<bin/bisector.pl>.

Once we determine how to combine the functionality currently found in
F<bin/bisect.pl> and F<bin/bisect-runner.pl> into a single production program,
this package will hold the top-level subroutines and methods implementing that
functionality.

=head1 METHODS

=head2 c<new()>

=over 4

=item * Purpose

Perl5::Bisect constructor.  Processes command-line switches and all other
arguments provided thereupon.

=item * Environmental Variables

F<git>.  F<git> checkout of Perl 5 core distribution.

There must be an environmental variable C<SECONDARY_CHECKOUT_DIR> defined
whose value is the absolute path of the directory holding the F<git> checkout
we will use during bisection.

=item * Arguments

None.  This function gets all its arguments by processing the command-line.

=item * Return Value

Perl5::Bisect object.

=item * Comment

In F<bin/bisect.pl> we will immediately assign the elements within this object
to variables and proceed from there.  As this module evolves, we will work
directly with elements within the object.

=back

=cut

sub new {
    my $class = shift;

    # We start by making sure we have a checkout of a (Perl 5) git repository in
    # an envvar SECONDARY_CHECKOUT_DIR.  We make sure that we can move to the
    # repository directory and prepare it for operations.

    my $cwd = cwd();

    my $checkout_dir = $ENV{SECONDARY_CHECKOUT_DIR};
    die "Unable to locate checkout of Perl 5" unless (
        -d $checkout_dir &&
        -d "$checkout_dir/.git"
    );
    chdir $checkout_dir or die "Unable to change to $checkout_dir: $!";
    system(qq|git clean -dfxq|)
        and die "Unable to do git-clean on $checkout_dir:$!";

    # We return to our starting point.

    chdir $cwd or die "Unable to change back to $cwd: $!";

    my $bisector = "$cwd/$0";
    my $brunner = "$cwd/bin/bisect-runner.pl";
    die "Can't find bisect runner $brunner" unless -f $brunner;

    my ($start, $end, $validate, $usage, $jobs, $make, $gold,
        $module, $with_module, $verbose);

    my $need_cpan_config;
    my $cpan_config_dir;

    my $bad = !GetOptions(
        'start=s'               => \$start,
        'end=s'                 => \$end,
        'jobs|j=i'              => \$jobs,
        'make=s'                => \$make,
        'gold=s'                => \$gold,
        validate                => \$validate,
        'usage|help|?'          => \$usage,
        'module=s'              => \$module,
        'with-module=s'         => \$with_module,
        'cpan-config-dir=s'     => \$cpan_config_dir,
        'verbose|v'             => \$verbose,
    );

    unshift @ARGV, '--help' if $bad || $usage;
    unshift @ARGV, '--validate' if $validate;

    if ($module || $with_module) {
        unshift @ARGV, '--module', $module if defined $module;
        unshift @ARGV, '--with-module', $with_module if defined $with_module;
  
        if ($cpan_config_dir) {
            my $c = File::Spec->catfile($cpan_config_dir, 'CPAN', 'MyConfig.pm');
            die "--cpan-config-dir: $c does not exist\n" unless -e $c;

            unshift @ARGV, '--cpan-config-dir', $cpan_config_dir;
        }
        else {
          $need_cpan_config = 1;
        }
    }

    # We return to SECONDARY_CHECKOUT_DIR and continue preparations.
    # We will stay in this directory for the balance of this program.

    chdir $checkout_dir or die "Unable to change to $checkout_dir: $!";

    # In the balance of this program there are 7 possible system calls to
    # bisect-runner.pl.  When bisecting a BBC, for example, only #1, #2, #4, #5
    # and #7 are actually invoked -- but, ultimately, we have to be able to
    # functionally test each of them.

    # My hypothesis is that they are differentiated (apart from their different
    # functional objectives) by the state of @ARGV and of %options at the point
    # where each is invoked.

    # Note further that bisect-runner.pl has its own call to GetOptions() to
    # process the then-current state of the command-line.

    if ($verbose) {
        say "bisect.pl:        $bisector";
        say "bisect-runner.pl: $brunner";
    }

    # Note that we're calling the bisect-runner here with 2 command-line switches
    # that are NOT listed in this program's invocation of GetOptions() (above) but
    # ARE processed by the runner's invocation of GetOptions().

    if ($verbose) {
        say 'RUNNER INVOCATION #1';
        say 'AAA: @ARGV before first possible invocation of bisect-runner.pl: ', join(' ' => @ARGV);
    }

    my %data = (
        argv                => [ @ARGV ],
        bad                 => $bad,
        bisector            => $bisector,
        brunner             => $brunner,
        end                 => $end,
        gold                => $gold,
        jobs                => $jobs,
        make                => $make,
        need_cpan_config    => $need_cpan_config,
        start               => $start,
        usage               => $usage,
        validate            => $validate,
        verbose             => $verbose,
    );
    my $self = bless \%data, $class;
    return $self;
}

1;

