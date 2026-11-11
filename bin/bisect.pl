#!/usr/bin/perl -w
use strict;

=for comment

Documentation for this is in bisect-runner.pl

=cut

# The default, auto_abbrev will treat -e as an abbreviation of --end
# Which isn't what we want.
use 5.14.0;
use Getopt::Long qw(:config pass_through no_auto_abbrev);
use File::Spec;
use File::Path qw(mkpath);
use Cwd;
use Perl5::Bisect;

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

my ($start, $end, $validate, $usage, $bad, $jobs, $make, $gold,
    $module, $with_module, $verbose);

my $need_cpan_config;
my $cpan_config_dir;

$bad = !GetOptions(
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
# We will stay here for the balance of this program.

chdir $checkout_dir or die "Unable to change to $checkout_dir: $!";

# In the balance of this program there are 6 possible system calls to
# bisect-runner.pl.  When bisecting a BBC, for example, only #1, #2, #4 and #5
# are actually invoked -- but, ultimately, we have to be able to functionally
# test each of them.

# My hypothesis is that they are differentiated (apart from their different
# functional objectives) by the state of @ARGV and of %options at the point
# where each is invoked.

# Note further that bisect-runner.pl has its own call to GetOptions() to
# process the then-current state of the command-line.

if ($verbose) {
    say "bisect.pl:        $bisector";
    say "bisect-runner.pl: $brunner";
    say 'RUNNER INVOCATION #1';
    say 'AAA: @ARGV before first possible invocation of bisect-runner.pl: ', join(' ' => @ARGV);
}

# Note that we're calling the bisect-runner here with 2 command-line switches
# that are NOT listed in this program's invocation of GetOptions() (above) but
# ARE processed by the runner's invocation of GetOptions().

system $^X, $brunner, '--check-args', '--check-shebang', @ARGV and exit 255;
exit 255 if $bad;
exit 0 if $usage;

my $start_time = time;

if (!defined $jobs &&
    !($^O eq 'hpux' && system((defined $make ? $make : 'make')
                              . ' --version >/dev/null 2>&1'))) {
    # Try to default to (ab)use all the CPUs:
    my $cpus;
    if (open my $fh, '<', '/proc/cpuinfo') {
        while (<$fh>) {
            ++$cpus if /^processor\s+:\s+\d+$/;
        }
    }
    elsif (-x '/sbin/sysctl' || -x '/usr/sbin/sysctl') {
        my $sysctl =  '/sbin/sysctl';
        $sysctl =  "/usr$sysctl" unless -x $sysctl;
        $cpus =  $1 if `$sysctl hw.ncpu` =~ /^hw\.ncpu: (\d+)$/;
    }
    elsif (-x '/usr/bin/getconf') {
        $cpus = $1 if `/usr/bin/getconf _NPROCESSORS_ONLN` =~ /^(\d+)$/;
    }
    $jobs = defined $cpus ? $cpus + 1 : 2;
}

unshift @ARGV, '--jobs', $jobs if defined $jobs;
unshift @ARGV, '--make', $make if defined $make;

if ($need_cpan_config) {
  # Make sure we have a CPAN::MyConfig so if we start at an old
  # revision CPAN doesn't ask for user input to configure itself

  my $cdir = File::Spec->catdir($ENV{HOME},".cpan","CPAN");
  my $cfile = File::Spec->catfile($cdir, "MyConfig.pm");

  unless (-e $cfile) {
    printf <<EOF;
I could not find a CPAN::MyConfig. We need to create one now so that
you can bisect with --module or --with-module. I'll boot up the CPAN
shell for you. Feel free to use defaults or change things as needed.
We recommend using 'manual' over 'local::lib' if it asks.

Type 'quit' when finished.

EOF
    system("$^X -MCPAN -e shell");
  }
}

# We try these in this order for the start revision if none is specified.
my @stable = map {chomp $_; $_} grep {/v5\.[0-9]+[02468]\.0$/} `git tag -l`;
die "git tag -l didn't seem to return any tags for stable releases"
    unless @stable;
unshift @stable, qw(perl-5.005 perl-5.6.0 perl-5.8.0);

{
    my ($dev_C, $ino_C) = stat 'Configure';
    my ($dev_c, $ino_c) = stat 'configure';
    if (defined $dev_C && defined $dev_c
        && $dev_C == $dev_c && $ino_C == $ino_c) {
        print "You seem to be on a case-insensitive file system.\n\n";
    }
    else {
        unshift @stable, qw(perl-5.002 perl-5.003 perl-5.004)
    }
}

unshift @ARGV, '--gold', defined $gold ? $gold : $stable[-1];

if (!defined $end) {
    # If we have a branch blead, use that as the end
    $end = `git rev-parse --verify --quiet blead`;
    die unless defined $end;
    if (!length $end) {
        # Else use whichever is newer - HEAD, or the most recent stable tag.
        if (`git rev-list -n1 HEAD ^$stable[-1]` eq "") {
            $end = pop @stable;
        }
        else {
            $end = 'HEAD';
        }
    }
}

# Canonicalising branches to revisions before moving the checkout permits one
# to use revisions such as 'HEAD' for --start or --end
foreach ($start, $end) {
    next unless $_;
    $_ = `git rev-parse $_`;
    die unless defined $_;
    chomp;
}

{
    # Check for files in the git-checkout directory which (a) are being
    # tracked but which have been modified or deleted or (b) files which are
    # not yet being tracked.

    my $modified = my @modified = `git ls-files --modified --deleted --others`;

    my ($dev0, $ino0) = stat $bisector;
    die "Can't stat $bisector: $!" unless defined $ino0;
    my ($dev1, $ino1) = stat $bisector;
    my $inplace = defined $dev1 && $dev0 == $dev1 && $ino0 == $ino1;

    if ($modified) {
        my $final = $inplace
            ? "Can't run a bisect using a dirty directory containing $brunner"
            : "You can use 'git clean -Xdf' to cleanup the ignored files";

        die "This checkout is not clean, found file(s):\n",
            join("\t","",@modified),
                "$modified modified, untracked, or other file(s)\n",
                "These files may not show in git status as they may be ignored.\n",
                "$final.\n";
    }

    if ($inplace) {
        # We assume that it's safe to copy the runner to the temporary
        # directory and run it from there, because a shared /tmp should be +t
        # and hence others are not be able to delete or rename our file.
        require File::Temp;
        my ($to, $toname) = File::Temp::tempfile();
        die "Can't create tempfile"
            unless $to;
        open my $from, '<', $brunner
            or die "Can't open '$brunner': $!";
        local $/;
        print {$to} <$from>
            or die "Can't copy from '$brunner' to '$toname': $!";
        close $from
            or die "Can't close '$brunner': $!";
        close $to
            or die "Can't close '$toname': $!";
        chmod 0500, $toname
            or die "Can't chmod 0500, '$toname': $!";
        $brunner = $toname;

        say 'RUNNER INVOCATION #2' if $verbose;

        # Once again, '--check-args' is a switch for the runner, not for this
        # program itself.

        system $^X, $brunner, '--check-args', @ARGV
            and die "Can't run inplace for some reason. :-(";
    }
}
say "BBB: bisect-runner.pl: Now: $brunner" if $verbose;

sub validate {
    my $commit = shift;
    if (defined $start && `git rev-list -n1 $commit ^$start^` eq "") {
        print "Skipping $commit, as it is earlier than $start\n";
        return;
    }
    if (defined $end && `git rev-list -n1 $end ^$commit^` eq "") {
        print "Skipping $commit, as it is more recent than $end\n";
        return;
    }
    print "Testing $commit...\n";
    system "git checkout $commit </dev/null" and die;
    say 'RUNNER INVOCATION #3' if $verbose;
    my $ret = system $^X, $brunner, '--no-clean', @ARGV;
    die "Runner returned $ret, not 0 for revision $commit" if $ret;
    system 'git clean -dxf </dev/null' and die;
    system 'git reset --hard HEAD </dev/null' and die;
    return $commit;
}

# Calling:
#
#     perl bin/bisect.pl --validate
#
# ... will, starting with blead, configure and build and run tests of base/*.t
# at tags for production releases as far back as possible on your machine.
# Output will terminate something like this:
#
#     HEAD is now at a5f75d6678 perl 5.002
#     Successfully validated blead v5.44.0 v5.42.0 v5.40.0 v5.38.0 v5.36.0
#     v5.34.0 v5.32.0 v5.30.0 v5.28.0 v5.26.0 v5.24.0 v5.22.0 v5.20.0 v5.18.0
#     v5.16.0 v5.14.0 v5.12.0 v5.10.0 perl-5.8.0 perl-5.6.0 perl-5.005 perl-5.004
#     perl-5.003 perl-5.002
#     That took 1440 seconds.

if ($validate) {
    require Text::Wrap;
    my @built = map {validate $_} 'blead', reverse @stable;
    if (@built) {
        print Text::Wrap::wrap("", "", "Successfully validated @built\n");
        exit 0;
    }
    print "Did not validate anything\n";
    exit 1;
}

my $git_version = `git --version`;
if (defined $git_version
    && $git_version =~ /\Agit version (\d+\.\d+\.\d+)(.*)/) {
    $git_version = eval "v$1";
}
else {
    $git_version = v0.0.0;
}

if ($git_version ge v1.6.6) {
    system "git bisect reset HEAD" and die;
}
else {
    system "git bisect reset" and die;
}

# Sanity check the first and last revisions:
say 'CCC: @ARGV before sanity-check of \'end\' revision: ', join(' ' => @ARGV)
    if $verbose;
system "git checkout $end" and die;
say 'RUNNER INVOCATION #4' if $verbose;
my $ret = system $^X, $brunner, @ARGV;
die "Runner returned $ret for end revision" unless $ret;
die "Runner returned $ret for end revision, which is a skip"
    if $ret == 125 * 256;

say 'DDD: @ARGV before sanity-check of \'start\' revision: ', join(' ' => @ARGV)
    if $verbose;
if (defined $start) {
    system "git checkout $start" and die;
say 'RUNNER INVOCATION #5' if $verbose;
    my $ret = system $^X, $brunner, @ARGV;
    die "Runner returned $ret, not 0 for start revision" if $ret;
}
else {
    # Try to find the earliest version for which the test works
    my @tried;
    foreach my $try (@stable) {
        if (`git rev-list -n1 $end ^$try^` eq "") {
            print "Skipping $try, as it is more recent than end commit "
                . (substr $end, 0, 16) . "\n";
            # As @stable is supposed to be in age order, arguably we should
            # last; here.
            next;
        }
        system "git checkout $try" and die;
        say 'RUNNER INVOCATION #6' if $verbose;
        my $ret = system $^X, $brunner, @ARGV;
        if (!$ret) {
            $start = $try;
            last;
        }
        push @tried, $try;
    }
    die "Can't find a suitable start revision to default to.\nTried @tried"
        unless defined $start;
}

# Only now are we ready to turn things over to 'git bisect':
say 'EEE: @ARGV before starting \'git bisect\': ', join(' ' => @ARGV)
    if $verbose;

system "git bisect start" and die;
system "git bisect good $start" and die;
system "git bisect bad $end" and die;

# And now get git bisect to do the hard work:
system 'git', 'bisect', 'run', $^X, $brunner, @ARGV and die;

END {
    my $end_time = time;

    printf "That took %d seconds.\n", $end_time - $start_time
        if defined $start_time;
}

=for comment

Documentation for this is in bisect-runner.pl

=cut

# ex: set ts=8 sts=4 sw=4 et:
