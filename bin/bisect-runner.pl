#!/usr/bin/perl -w
use strict;

use Getopt::Long qw(:config bundling no_auto_abbrev);
use Pod::Usage;
use Config;
use File::Temp qw(tempdir);
use File::Spec;
use lib ("$ENV{HOME}/gitwork/noncore/perl-bisect/lib");
use Perl5::Bisect::Auxiliary qw(
    croak_255
    die_255
    open_or_die
    close_or_die
    system_or_die
    run_with_options
    extract_from_file
    edit_file
    process_hunk
    ud2cd
    placate_patch_prog
    apply_patch
    patch_from_commit
    apply_commit
    revert_commit
    skip
    check_shebang
    checkout_file
    match_and_exit
    report_and_exit
    run_report_and_exit
);
use Perl5::Bisect::Patching qw(
    force_manifest
    force_manifest_cleanup
    apply_fixups
    fake_noextensions
    patch_ext
    patch_SH
    patch_t
    patch_hints
    patch_Configure
    patch_C
);

my @targets
    = qw(none config.sh config.h miniperl lib/Config.pm Fcntl perl test_prep);

my %options =
    (
     'expect-pass' => 1,
     clean => 1, # mostly for debugging this
    );

# We accept #!./miniperl and #!./perl
# We don't accept #!miniperl and #!perl as their intent is ambiguous
my $run_with_our_perl = qr{\A#!(\./(?:mini)?perl)\b};

my $linux64 = `uname -sm` eq "Linux x86_64\n" ? '64' : '';

my @paths;

if ($^O eq 'linux') {
    # This is the search logic for a multi-arch library layout
    # added to linux.sh in commits 40f026236b9959b7 and dcffd848632af2c7.
    my $gcc = -x '/usr/bin/gcc' ? '/usr/bin/gcc' : 'gcc';

    foreach (`$gcc -print-search-dirs`) {
        next unless /^libraries: =(.*)/;
        foreach (split ':', $1) {
            next if m/gcc/;
            next unless -d $_;
            s!/$!!;
            push @paths, $_;
        }
    }
    push @paths, map {$_ . $linux64} qw(/usr/local/lib /lib /usr/lib)
        if $linux64;
}

my %defines =
    (
     usedevel => '',
     optimize => '-g',
     ld => 'cc',
     (@paths ? (libpth => \@paths) : ()),
    );

# Needed for the 'ignore_versioned_solibs' emulation below.
push @paths, qw(/usr/local/lib /lib /usr/lib)
        unless $linux64;

my $rv = GetOptions(
    \%options,
    'target=s', 'make=s', 'jobs|j=i', 'crash', 'expect-pass=i',
    'expect-fail' => sub { $options{'expect-pass'} = 0; },
    'clean!', 'one-liner|e=s@', 'c', 'l', 'w', 'match=s',
    'no-match=s' => sub {
        $options{match} = $_[1];
        $options{'expect-pass'} = 0;
    },
    'force-manifest', 'force-regen', 'setpgrp!', 'timeout=i',
    'test-build', 'validate',
    'all-fixups', 'early-fixup=s@', 'late-fixup=s@', 'valgrind',
    'check-args', 'check-shebang!', 'usage|help|?', 'gold=s',
    'module=s', 'with-module=s', 'cpan-config-dir=s',
    'test-module=s', 'no-module-tests',
    'A=s@',
    'D=s@' => sub {
        my (undef, $val) = @_;
        if ($val =~ /\A([^=]+)=(.*)/s) {
            $defines{$1} = length $2 ? $2 : "\0";
        } else {
            $defines{$val} = '';
        }
    },
    'U=s@' => sub {
        $defines{$_[1]} = undef;
    },
);
exit 255 unless $rv;

my ($target, $match) = @options{qw(target match)};

# El Capitan (OS X 10.11) (and later) strip DYLD_LIBRARY_PATH
# from the environment of /bin/sh
# https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html
#
# (They *could* have chosen instead to ignore it and pass it through. It would
# have the same direct effect, but maybe needing more coding. I suspect the
# choice to strip it was deliberate, as it will also eliminate a bunch more
# attack vectors, because it prevents you sneaking an override "into" something
# else you convince the user to run.)

my $aggressive_apple_security = "";
if ($^O eq 'darwin') {
    require Cwd;
    my $cwd = quotemeta Cwd::getcwd();
    $aggressive_apple_security = "DYLD_LIBRARY_PATH=$cwd ";
}

# If, having built a perl in a git checkout, we were to run:
#
#     $ sh -c "cd t && ./perl TEST base/*.t"
#     t/base/cond ........ ok
#     t/base/if .......... ok
#     t/base/lex ......... ok
#     t/base/num ......... ok
#     t/base/pat ......... ok
#     t/base/rs .......... ok
#     t/base/term ........ ok
#     t/base/translate ... ok
#     t/base/while ....... ok
#     All tests successful.
#     Elapsed: 0 sec
#     u=0.01  s=0.00  cu=0.00  cs=0.01  scripts=9  tests=502
#
# This is a simple test of whether perl, at a given commit, tag or release, has
# been built or not.

@ARGV = ('sh', '-c', "cd t && $aggressive_apple_security./perl TEST base/*.t")
    if $options{validate} && !@ARGV;

pod2usage(exitval => 0, verbose => 2) if $options{usage};

# This needs to be done before the next arguments check, as it's populating
# @ARGV
if (defined $target && $target =~ /\.t\z/) {
    # t/TEST doesn't have a reliable way to run the test script under valgrind
    # The $ENV{VALGRIND} code was only added after v5.8.0, and is more
    # geared to logging than to exiting on failure if errors are found.
    # I guess one could fudge things by replacing the symlink t/perl with a
    # wrapper script which invokes valgrind, but leave doing that until
    # someone needs it. (If that's you, then patches welcome.)
    foreach (qw(valgrind match validate test-build one-liner)) {
        die_255("$0: Test-case targets can't be run with --$_")
            if $options{$_};
    }
    die_255("$0: Test-case targets can't be combined with an explicit test")
        if @ARGV;

    # Needing this unless is a smell suggesting that this implementation of
    # test-case targets is not really in the right place.
    unless ($options{'check-args'}) {
        # The top level sanity tests refuse to start or end a test run at a
        # revision which skips, hence this test ensures reasonable sanity at
        # automatically picking a suitable start point for both normal operation
        # and --expect-fail
        skip("Test case $target is not a readable file")
            unless -f $target && -r _;
    }

    # t/TEST runs from and takes pathnames relative to t/, so need to strip
    # out a leading t, or add ../ otherwise
    unless ($target =~ s!\At/!!) {
        $target = "../$target";
    }
    @ARGV = ('sh', '-c', "cd t && $aggressive_apple_security./perl TEST " . quotemeta $target);
    $target = 'test_prep';
}

pod2usage(exitval => 255, verbose => 1)
    unless @ARGV || $match || $options{'test-build'}
        || defined $options{'one-liner'} || defined $options{module}
        || defined $options{'test-module'};
pod2usage(exitval => 255, verbose => 1)
    if !$options{'one-liner'} && ($options{l} || $options{w});
if ($options{'no-module-tests'} && $options{module}) {
    print STDERR "--module and --no-module-tests are exclusive.\n\n";
    pod2usage(exitval => 255, verbose => 1)
}
if ($options{'no-module-tests'} && $options{'test-module'}) {
    print STDERR "--test-module and --no-module-tests are exclusive.\n\n";
    pod2usage(exitval => 255, verbose => 1)
}
if ($options{module} && $options{'test-module'}) {
    print STDERR "--module and --test-module are exclusive.\n\n";
    pod2usage(exitval => 255, verbose => 1)
}

check_shebang($ARGV[0], $run_with_our_perl)
    if $options{'check-shebang'} && @ARGV && !$options{match};

exit 0 if $options{'check-args'};

die_255("$0: Can't build $target")
    if defined $target && !grep {@targets} $target;

foreach my $phase (qw(early late)) {
    next unless $options{"$phase-fixup"};
    my $bail_out;
    require File::Glob;
    my @expanded;
    foreach my $glob (@{$options{"$phase-fixup"}}) {
        my @got = File::Glob::bsd_glob($glob);
        push @expanded, @got ? @got : $glob;
    }
    @expanded = sort @expanded;
    $options{"$phase-fixup"} = \@expanded;
    foreach (@expanded) {
        unless (-f $_) {
            print STDERR "$phase-fixup '$_' is not a readable file\n";
            ++$bail_out;
        }
    }
    exit 255 if $bail_out;
}

unless (exists $defines{cc}) {
    # If it fails, the heuristic of 63f9ec3008baf7d6 is noisy, and hence
    # confusing.
    # FIXME - really it should be replaced with a proper test of
    # "can we build something?" and a helpful diagnostic if we can't.
    # For now, simply move it here.
    no warnings 'exec';
    $defines{cc} = (`ccache -V`, $?) ? 'cc' : 'ccache cc';
}

my $j = $options{jobs} ? "-j$options{jobs}" : '';

if (exists $options{make}) {
    if (!exists $defines{make}) {
        $defines{make} = $options{make};
    }
} else {
    $options{make} = 'make';
}

# Sadly, however hard we try, I don't think that it will be possible to build
# modules in ext/ on x86_64 Linux before commit e1666bf5602ae794 on 1999/12/29,
# which updated to MakeMaker 3.7, which changed from using a hard coded ld
# in the Makefile to $(LD). On x86_64 Linux the "linker" is gcc.

# Not going to assume that system perl is yet new enough to have autodie
system_or_die('git clean -dxf');

if (!defined $target) {
    match_and_exit(undef, [@ARGV], $match) if $match;
    $target = 'test_prep';
} elsif ($target eq 'none') {
    match_and_exit(undef, [@ARGV], $match) if $match;
    run_report_and_exit(\%options, @ARGV);
}

skip('no Configure - is this the //depot/perlext/Compiler branch?')
    unless -f 'Configure';

my $case_insensitive;
{
    my ($dev_C, $ino_C) = stat 'Configure';
    die_255("Could not stat Configure: $!") unless defined $dev_C;
    my ($dev_c, $ino_c) = stat 'configure';
    ++$case_insensitive
        if defined $dev_c && $dev_C == $dev_c && $ino_C == $ino_c;
}

# This changes to PERL_VERSION in 4d8076ea25903dcb in 1999
my $major = extract_from_file(
    'patchlevel.h',
    qr/^#define\s+(?:PERL_VERSION|PATCHLEVEL)\s+(\d+)\s/,
    0
);

my $unfixable_db_file;

if ($major < 10
    && !extract_from_file('ext/DB_File/DB_File.xs',
                          qr!^#else /\* Berkeley DB Version > 2 \*/$!)) {
    # This DB_File.xs is really too old to patch up.
    # Skip DB_File, unless we're invoked with an explicit -Unoextensions
    if (!exists $defines{noextensions}) {
        $defines{noextensions} = 'DB_File';
    } elsif (defined $defines{noextensions}) {
        $defines{noextensions} .= ' DB_File';
    }
    ++$unfixable_db_file;
}

patch_Configure($major);
patch_hints(\%options, $case_insensitive, $major);
if ($options{'all-fixups'}) {
    patch_SH($aggressive_apple_security, $major, \%options);
    patch_C($major);
    patch_ext($major, $unfixable_db_file, \%options);
    patch_t($aggressive_apple_security);
}
apply_fixups($options{'early-fixup'});

# if Encode is not needed for the test, you can speed up the bisect by
# excluding it from the runs with -Dnoextensions=Encode
# ccache is an easy win. Remove it if it causes problems.
# Commit 1cfa4ec74d4933da adds ignore_versioned_solibs to Configure, and sets it
# to true in hints/linux.sh
# On dromedary, from that point on, Configure (by default) fails to find any
# libraries, because it scans /usr/local/lib /lib /usr/lib, which only contain
# versioned libraries. Without -lm, the build fails.
# Telling /usr/local/lib64 /lib64 /usr/lib64 works from that commit onwards,
# until commit faae14e6e968e1c0 adds it to the hints.
# However, prior to 1cfa4ec74d4933da telling Configure the truth doesn't work,
# because it will spot versioned libraries, pass them to the compiler, and then
# bail out pretty early on. Configure won't let us override libswanted, but it
# will let us override the entire libs list.

foreach (@{$options{A}}) {
    push @paths, $1 if /^libpth=(.*)/s;
}

unless (extract_from_file('Configure', 'ignore_versioned_solibs')) {
    # Before 1cfa4ec74d4933da, so force the libs list.

    my @libs;
    # This is the current libswanted list from Configure, less the libs removed
    # by current hints/linux.sh
    foreach my $lib (qw(sfio socket inet nsl nm ndbm gdbm dbm db malloc dl
			ld sun m crypt sec util c cposix posix ucb BSD)) {
	foreach my $dir (@paths) {
            # Note the wonderful consistency of dot-or-not in the config vars:
            next unless -f "$dir/lib$lib.$Config{dlext}"
                || -f "$dir/lib$lib$Config{lib_ext}";
	    push @libs, "-l$lib";
	    last;
	}
    }
    $defines{libs} = \@libs unless exists $defines{libs};
}

# a4f3eea9be6bcf3c added a test for GNU libc to Configure
# Prior to that we really don't get much choice but to force usenm off
# everywhere (and modern systems are fast enough that this doesn't matter)
$defines{usenm} = undef
    if $major < 4 && !exists $defines{usenm};

my ($missing, $created_dirs);
($missing, $created_dirs) = force_manifest()
    if $options{'force-manifest'};

my @ARGS = '-dEs';
foreach my $key (sort keys %defines) {
    my $val = $defines{$key};
    if (ref $val) {
        push @ARGS, "-D$key=@$val";
    } elsif (!defined $val) {
        push @ARGS, "-U$key";
    } elsif (!length $val) {
        push @ARGS, "-D$key";
    } else {
        $val = "" if $val eq "\0";
        push @ARGS, "-D$key=$val";
    }
}
push @ARGS, map {"-A$_"} @{$options{A}};

my $prefix;

# Testing a module? We need to install perl/cpan modules to a temp dir
if ($options{module} || $options{'with-module'} || $options{'test-module'})
{
  $prefix = tempdir(CLEANUP => 1);

  push @ARGS, "-Dprefix=$prefix";
  push @ARGS, "-Uversiononly", "-Dinstallusrbinperl=n";
}

# If a file in MANIFEST is missing, Configure asks if you want to
# continue (the default being 'n'). With stdin closed or /dev/null,
# it exits immediately and the check for config.sh below will skip.
# Without redirecting stdin, the commands called will attempt to read from
# stdin (and thus effectively hang)
run_with_options({stdin => '/dev/null', name => 'Configure'},
                 './Configure', @ARGS);

patch_SH($aggressive_apple_security, $major, \%options) unless $options{'all-fixups'};
apply_fixups($options{'late-fixup'});

if (-f 'config.sh') {
    # Emulate noextensions if Configure doesn't support it.
    fake_noextensions(\%defines)
        if $major < 10 && $defines{noextensions};
    if (system './Configure -S') {
        # See commit v5.23.5-89-g7a4fcb3.  Configure may try to run
        # ./optdef.sh instead of UU/optdef.sh.  Copying the file is
        # easier than patching Configure (which mentions optdef.sh multi-
        # ple times).
        require File::Copy;
        File::Copy::copy("UU/optdef.sh", "./optdef.sh");
        system_or_die('./Configure -S');
    }
}

if ($target =~ /config\.s?h/) {
    match_and_exit(undef, [@ARGV], $match) if $match && -f $target;
    report_and_exit( {
        good => -f $target,
        pass => 'could build',
        fail => 'could not build',
        description => $target,
        options => \%options,
    } ) if $options{'test-build'};

    skip("could not build $target") unless -f $target;

    run_report_and_exit(\%options, @ARGV);
}
elsif (!-f 'config.sh') {
    report_and_exit( {
        good => undef,
        pass => 'PLEASE REPORT BUG',
        fail => 'could not build',
        description => 'config.sh',
        options => \%options,
    } ) if $options{'test-build'};

    # Skip if something went wrong with Configure
    skip('could not build config.sh');
}

force_manifest_cleanup($missing, $created_dirs)
        if $missing;

if($options{'force-regen'}
   && extract_from_file('Makefile', qr/\bregen_headers\b/)) {
    # regen_headers was added in e50aee73b3d4c555, patch.1m for perl5.001
    # It's not worth faking it for earlier revisions.
    system_or_die('make regen_headers');
}

unless ($options{'all-fixups'}) {
    patch_C($major);
    patch_ext($major, $unfixable_db_file, \%options);
    patch_t($aggressive_apple_security);
}

# Parallel build for miniperl is safe
system "$options{make} $j miniperl </dev/null";

# This is the file we expect make to create
my $expected_file = $target =~ /^test/ ? 't/perl'
    : $target eq 'Fcntl' ? "lib/auto/Fcntl/Fcntl.$Config{so}"
    : $target;
# This is the target we tell make to build in order to get $expected_file
my $real_target = $target eq 'Fcntl' ? $expected_file : $target;

if ($target ne 'miniperl') {
    # Nearly all parallel build issues fixed by 5.10.0. Untrustworthy before that.
    $j = '' if $major < 10;

    if ($real_target eq 'test_prep') {
        if ($major < 8) {
            # test-prep was added in 5.004_01, 3e3baf6d63945cb6.
            # renamed to test_prep in 2001 in 5fe84fd29acaf55c.
            # earlier than that, just make test. It will be fast enough.
            $real_target = extract_from_file('Makefile.SH',
                                             qr/^(test[-_]prep):/,
                                             'test');
        }
    }

    system "$options{make} $j $real_target </dev/null";
}

my $expected_file_found = $expected_file =~ /perl$/
    ? -x $expected_file : -r $expected_file;

if ($expected_file_found && $expected_file eq 't/perl') {
    # Check that it isn't actually pointing to ../miniperl, which will happen
    # if the sanity check ./miniperl -Ilib -MExporter -e '<?>' fails, and
    # Makefile tries to run minitest.

    # Of course, helpfully sometimes it's called ../perl, other times .././perl
    # and who knows if that list is exhaustive...
    my ($dev0, $ino0) = stat 't/perl';
    my ($dev1, $ino1) = stat 'perl';
    unless (defined $dev0 && defined $dev1 && $dev0 == $dev1 && $ino0 == $ino1) {
        undef $expected_file_found;
        my $link = readlink $expected_file;
        warn "'t/perl' => '$link', not 'perl'";
        die_255("Could not realink t/perl: $!") unless defined $link;
    }
}

my $just_testing = 0;

if ($options{'test-build'}) {
    report_and_exit( {
        good => $expected_file_found,
        pass => 'could build',
        fail => 'could not build',
        description => $real_target,
        options => \%options,
    } );
}
elsif (!$expected_file_found) {
    skip("could not build $real_target");
}
elsif (my $mod_opt = $options{module} || $options{'with-module'}
               || ($just_testing++, $options{'test-module'})) {
  # Testing a cpan module? See if it will install
  # First we need to install this perl somewhere
  system_or_die('./installperl');

  my @m = split(',', $mod_opt);

  my $bdir = File::Temp::tempdir(
    CLEANUP => 1,
  ) or die $!;

  # Don't ever stop to ask the user for input
  $ENV{AUTOMATED_TESTING} = 1;
  $ENV{PERL_MM_USE_DEFAULT} = 1;

  # Don't let these interfere with our cpan installs
  delete $ENV{PERL_MB_OPT};
  delete $ENV{PERL_MM_OPT};

  # Make sure we load up our CPAN::MyConfig and then
  # override the build_dir so we have a fresh one
  # every build
  my $cdir = $options{'cpan-config-dir'}
          || File::Spec->catfile($ENV{HOME},".cpan");

  my @cpanshell = (
    "$prefix/bin/perl",
    "-I", "$cdir",
    "-MCPAN::MyConfig",
    "-MCPAN",
    "-e","\$CPAN::Config->{build_dir}=q{$bdir};",
    "-e",
  );

  for (@m) {
    s/-/::/g if /-/ and !m|/|;
  }
  my $install = join ",", map { "'$_'" } @m;
  if ($just_testing) {
    $install = "test($install)";
  } elsif ($options{'no-module-tests'}) {
    $install = "notest('install',$install)";
  } else {
    $install = "install($install)";
  }
  my $last = $m[-1];
  my $status_method = $just_testing ? 'test' : 'uptodate';
  my $shellcmd = "$install; die unless CPAN::Shell->expand(Module => '$last')->$status_method;";

  if ($options{module} || $options{'test-module'}) {
    run_report_and_exit(\%options, @cpanshell, $shellcmd);
  } else {
    my $ret = run_with_options({setprgp => $options{setpgrp},
                                timeout => $options{timeout},
                               }, @cpanshell, $shellcmd);
    $ret &= 0xff if $options{crash};

    # Failed? Give up
    if ($ret) {
      report_and_exit( {
        good => !$ret,
        pass => 'zero exit from',
        fail => 'non-zero exit from',
        description => "@_",
        options => \%options,
      } );
    }
  }
}

match_and_exit($real_target, [@ARGV], $match) if $match;

if (defined $options{'one-liner'}) {
    my $exe = $target =~ /^(?:perl$|test)/ ? 'perl' : 'miniperl';
    unshift @ARGV, map {('-e', $_)} @{$options{'one-liner'}};
    foreach (qw(c l w)) {
        unshift @ARGV, "-$_" if $options{$_};
    }
    unshift @ARGV, "./$exe", '-Ilib';
}

if (-f $ARGV[0]) {
    my $fh = open_or_die($ARGV[0]);
    my $line = <$fh>;
    unshift @ARGV, $1, '-Ilib'
        if $line =~ $run_with_our_perl;
}

if ($options{valgrind}) {
    # Turns out to be too confusing to use an optional argument with the path
    # of the valgrind binary, as if --valgrind takes an optional argument,
    # then specifying it as the last option eats the first part of the testcase.
    # ie this: .../bisect.pl --valgrind testcase
    # is treated as --valgrind=testcase and as there is no test case given,
    # it's an invalid commandline, bailing out with the usage message.

    # Currently, the test script can't signal a skip with 125, so anything
    # non-zero would do. But to keep that option open in future, use 124
    unshift @ARGV, 'valgrind', '--error-exitcode=124';
}

# This is what we came here to run:

if (exists $Config{ldlibpthname}) {
    require Cwd;
    my $varname = $Config{ldlibpthname};
    my $cwd = Cwd::getcwd();
    if (defined $ENV{$varname}) {
        $ENV{$varname} = $cwd . $Config{path_sep} . $ENV{$varname};
    } else {
        $ENV{$varname} = $cwd;
    }
}

run_report_and_exit(\%options, @ARGV);

=head1 NAME

bisect.pl - use git bisect to pinpoint changes

=head1 SYNOPSIS

 # When did this become an error?
 .../Porting/bisect.pl -e 'my $a := 2;'
 # When did this stop being an error?
 .../Porting/bisect.pl --expect-fail -e '1 // 2'
 # When did this test start failing?
 .../Porting/bisect.pl --target t/op/sort.t
 # When were all lines matching this pattern removed from all files?
 .../Porting/bisect.pl --match '\b(?:PL_)hash_seed_set\b'
 # When was some line matching this pattern added to some file?
 .../Porting/bisect.pl --expect-fail --match '\buseithreads\b'
 # When did this test program stop exiting 0?
 .../Porting/bisect.pl -- ./perl -Ilib ../test_prog.pl
 # When did this test program start crashing (any signal or coredump)?
 .../Porting/bisect.pl --crash -- ./perl -Ilib ../test_prog.pl
 # When did this first become valid syntax?
 .../Porting/bisect.pl --target=miniperl --end=v5.10.0 \
      --expect-fail -e 'my $a := 2;'
 # What was the last revision to build with these options?
 .../Porting/bisect.pl --test-build -Dd_dosuid
 # When did this test program start generating errors from valgrind?
 .../Porting/bisect.pl --valgrind ../test_prog.pl
 # When did these cpan modules start failing to compile/pass tests?
 .../Porting/bisect.pl --module=autobox,Moose
 # When did this code stop working in blead with these modules?
 .../Porting/bisect.pl --with-module=Moose,Moo -e 'use Moose; 1;'
 # Like the above 2 but with custom CPAN::MyConfig
 .../Porting/bisect.pl --module=Moo --cpan-config-dir=/home/blah/custom/

=head1 DESCRIPTION

Together F<bisect.pl> and F<bisect-runner.pl> attempt to automate the use
of C<git bisect> as much as possible. With one command (and no other files)
it's easy to find out

=over 4

=item *

Which commit caused this example code to break?

=item *

Which commit caused this example code to start working?

=item *

Which commit added the first file to match this regex?

=item *

Which commit removed the last file to match this regex?

=back

usually without needing to know which versions of perl to use as start and
end revisions.

By default F<bisect.pl> will process all options, then use the rest of the
command line as arguments to list C<system> to run a test case. By default,
the test case should pass (exit with 0) on earlier perls, and fail (exit
non-zero) on I<blead>. F<bisect.pl> will use F<bisect-runner.pl> to find the
earliest stable perl version on which the test case passes, check that it
fails on blead, and then use F<bisect-runner.pl> with C<git bisect run> to
find the commit which caused the failure.

Many of perl's own test scripts exit 0 even if their TAP reports test
failures, and some need particular setup (such as running from the right
directory, or adding C<-T> to the command line). Hence if you want to bisect
a test script, you can specify it with the I<--target> option, and it will
be invoked using F<t/TEST> which performs all the setup, and exits non-zero
if the TAP reports failures. This works for any file ending C<.t>, so you can
use it with a file outside of the working checkout, for example to test a
particular version of a test script, as a path inside the repository will
(of course) be testing the version of the script checked out for the current
revision, which may be too early to have the test you are interested in.

Because the test case is the complete argument to C<system>, it is easy to
run something other than the F<perl> built, if necessary. If you need to run
the perl built, you'll probably need to invoke it as C<./perl -Ilib ...>.
As a special case, if the first argument of the test case is a readable file
(whether executable or not), matching C<qr{\A#!./(?:mini)?perl\b}> then it
will have C<./perl> <-Ilib> (or C<./miniperl>) prepended to it.

You need a clean checkout to run a bisect. You can use the checkout
containing F<Porting/bisect.pl> if you wish - in this case
F<Porting/bisect.pl> will copy F<Porting/bisect-runner.pl> to a temporary
file generated by C<File::Temp::tempfile()>. If doing this, beware that when
the bisect ends (or you abort it) then your checkout is no longer at
C<blead>, so you will need to C<git checkout blead> before restarting, to
get the current version of F<Porting/bisect.pl> again. It's often easier
either to copy F<Porting/bisect.pl> and F<Porting/bisect-runner.pl> to
another directory (I<e.g.> F<~/bin>, if you have one), or to create a second
git repository for running bisect. To create a second local repository, if
your working checkout is called F<perl>, a simple solution is to make a
local clone, and run from that. I<i.e.>:

    cd ..
    git clone perl perl2
    cd perl2
    ../perl/Porting/bisect.pl ...

By default, F<bisect-runner.pl> will automatically disable the build of
L<DB_File> for commits earlier than ccb44e3bf3be2c30, as it's not practical
to patch DB_File 1.70 and earlier to build with current Berkeley DB headers.
(ccb44e3bf3be2c30 was in September 1999, between 5.005_62 and 5.005_63.)
If your F<db.h> is old enough you can override this with C<-Unoextensions>.

=head1 OPTIONS

=over 4

=item *

--start I<commit-ish>

Earliest revision to test, as a I<commit-ish> (a tag, commit or anything
else C<git> understands as a revision). If not specified, F<bisect.pl> will
search stable .0 perl releases until it finds one where the test case
passes. The default is to search from 5.002 to the most recent tagged stable
release (v5.18.0 at the time of writing). If F<bisect.pl> detects that the
checkout is on a case insensitive file system, it will search from 5.005 to
the most recent tagged stable release. Only .0 stable releases are used
because these are the only stable releases that are parents of blead, and
hence suitable for a bisect run.

=item *

--end I<commit-ish>

Most recent revision to test, as a I<commit-ish>. If not specified, defaults
to I<blead>.

=item *

--target I<target>

F<Makefile> target (or equivalent) needed, to run the test case. If specified,
this should be one of

=over 4

=item *

I<none>

Don't build anything - just run the user test case against a clean checkout.
Using this gives a couple of features that a plain C<git bisect run> can't
offer - automatic start revision detection, and test case C<--timeout>.

=item *

I<config.sh>

Just run F<./Configure>

=item *

I<config.h>

Run the various F<*.SH> files to generate F<Makefile>, F<config.h>, I<etc>.

=item *

I<miniperl>

Build F<miniperl>.

=item *

I<lib/Config.pm>

Use F<miniperl> to build F<lib/Config.pm>

=item *

I<Fcntl>

Build F<lib/auto/Fcntl/Fnctl.so> (strictly, C<.$Config{so}>). As L<Fcntl>
is simple XS module present since 5.000, this provides a fast test of
whether XS modules can be built. Note, XS modules are built by F<miniperl>,
hence this target will not build F<perl>.

=item *

I<perl>

Build F<perl>. This also builds pure-Perl modules in F<cpan>, F<dist> and
F<ext>. XS modules (such as L<Fcntl>) are not built.

=item *

I<test_prep>

Build everything needed to run the tests. This is the default if we're
running test code, but is time consuming, as it means building all
XS modules. For older F<Makefile>s, the previous name of C<test-prep>
is automatically substituted. For very old F<Makefile>s, C<make test> is
run, as there is no target provided to just get things ready, and for 5.004
and earlier the tests run very quickly.

=item *

A file ending C<.t>

Build everything needed to run the tests, and then run this test script using
F<t/TEST>. This is actually implemented internally by using the target
I<test_prep>, and setting the test case to "sh", "-c", "cd t && ./TEST ..."

=back

=item *

--one-liner 'code to run'

=item *

-e 'code to run'

Example code to run, just like you'd use with C<perl -e>.

This prepends C<./perl -Ilib -e 'code to run'> to the test case given,
or F<./miniperl> if I<target> is C<miniperl>.

(Usually you'll use C<-e> instead of providing a test case in the
non-option arguments to F<bisect.pl>. You can repeat C<-e> on the command
line, just like you can with C<perl>)

C<-E> intentionally isn't supported, as it's an error in 5.8.0 and earlier,
which interferes with detecting errors in the example code itself.

=item *

-c

Add C<-c> to the command line, to cause perl to exit after syntax checking.

=item *

-l

Add C<-l> to the command line with C<-e>

This will automatically append a newline to every output line of your testcase.
Note that you can't specify an argument to F<perl>'s C<-l> with this, as it's
not feasible to emulate F<perl>'s somewhat quirky switch parsing with
L<Getopt::Long>. If you need the full flexibility of C<-l>, you need to write
a full test case, instead of using C<bisect.pl>'s C<-e> shortcut.

=item *

-w

Add C<-w> to the command line with C<-e>

It's not valid to pass C<-c>,  C<-l> or C<-w> to C<bisect.pl> unless you are
also using C<-e>

=item *

--expect-fail

The test case should fail for the I<start> revision, and pass for the I<end>
revision. The bisect run will find the first commit where it passes.

=item *

--crash

Treat any non-crash as success, any crash as failure. (Crashing defined
as exiting with a signal or a core dump.)

=item *

-D I<config_arg=value>

=item *

-U I<config_arg>

=item *

-A I<config_arg=value>

Arguments (C<-A>, C<-D>, C<-U>) to pass to F<Configure>.  The C<-D>, C<-A> and
C<-U> switches should be spelled as if you were normally giving them to
F<./Configure>.  For example,

    -Dnoextensions=Encode
    -Uusedevel
    -Accflags=-DNO_MATHOMS

Repeated C<-A> arguments are passed
through as is. C<-D> and C<-U> are processed in order, and override
previous settings for the same parameter. F<bisect-runner.pl> emulates
C<-Dnoextensions> when F<Configure> itself does not provide it, as it's
often very useful to be able to disable some XS extensions.

=item *

--make I<make-prog>

The C<make> command to use. If this not set, F<make> is used. If this is
set, it also adds a C<-Dmake=...> else some recursive make invocations
in extensions may fail. Typically one would use this as C<--make gmake>
to use F<gmake> in place of the system F<make>.

=item *

--jobs I<jobs>

=item *

-j I<jobs>

Number of C<make> jobs to run in parallel. A value of 0 suppresses
parallelism. If F</proc/cpuinfo> exists and can be parsed, or F</sbin/sysctl>
exists and reports C<hw.ncpu>, or F</usr/bin/getconf> exists and reports
C<_NPROCESSORS_ONLN> defaults to 1 + I<number of CPUs>. On HP-UX with the
system make defaults to 0, otherwise defaults to 2.

=item *

--match pattern

=item *

--no-match pattern

Instead of running a test program to determine I<pass> or I<fail>,
C<--match> will pass if the given regex matches, and hence search for the
commit that removes the last matching file. C<--no-match> inverts the test,
to search for the first commit that adds files that match.

The remaining command line arguments are treated as glob patterns for files
to match against. If none are specified, then they default as follows:

=over 4

=item *

If no I<target> is specified, the match is against all files in the
repository (which is fast).

=item *

If a I<target> is specified, that target is built, and the match is against
only the built files.

=back

Treating the command line arguments as glob patterns should not cause
problems, as the perl distribution has never shipped or built files with
names that contain characters which are globbing metacharacters.

Anything which is not a readable file is ignored, instead of generating an
error. (If you want an error, run C<grep> or C<ack> as a test case). This
permits one to easily search in a file that changed its name. For example:

    .../Porting/bisect.pl --match 'Pod.*Functions' 'pod/buildtoc*'

C<--no-match ...> is implemented as C<--expect-fail --match ...>

=item *

--valgrind

Run the test program under C<valgrind>. If you need to test for memory
errors when parsing invalid programs, the default parser fail exit code of
255 will always override C<valgrind>, so try putting the test case invalid
code inside a I<string> C<eval>, so that the perl interpreter will exit with 0.
(Be sure to check the output of $@, to avoid missing mistakes such as
unintended C<eval> failures due to incorrect C<@INC>)

Specifically, this option prepends C<valgrind> C<--error-exitcode=124> to
the command line that runs the testcase, to cause valgrind to exit non-zero
if it detects errors, with the assumption that the test program itself
always exits with zero. If you require more flexibility than this, either
specify your C<valgrind> invocation explicitly as part of the test case, or
use a wrapper script to control the command line or massage the exit codes.

In order for the test program to be seen as a perl script to valgrind
(rather than a shell script), the first line must be one of the following

  #!./perl
  #!./miniperl

=item *

--test-build

Test that the build completes, without running any test case.

By default, if the build for the desired I<target> fails to complete,
F<bisect-runner.pl> reports a I<skip> back to C<git bisect>, the assumption
being that one wants to find a commit which changed state "builds && passes"
to "builds && fails". If instead one is interested in which commit broke the
build (possibly for particular F<Configure> options), use I<--test-build>
to treat a build failure as a failure, not a "skip".

Often this option isn't as useful as it first seems, because I<any> build
failure will be reported to C<git bisect> as a failure, not just the failure
that you're interested in. Generally, to debug a particular problem, it's
more useful to use a I<target> that builds properly at the point of interest,
and then a test case that runs C<make>. For example:

    .../Porting/bisect.pl --start=perl-5.000 --end=perl-5.002 \
        --expect-fail --force-manifest --target=miniperl make perl

will find the first revision capable of building L<DynaLoader> and then
F<perl>, without becoming confused by revisions where F<miniperl> won't
even link.

=item *

--module module1,module2,...

Install this (or these) module(s), die when it (the last of those)
cannot be updated to the current version.

Misnomer. the argument can be any argument that can be passed to CPAN
shell's install command. B<But>: since we only have the uptodate
command to verify that an install has taken place, we are unable to
determine success for arguments like
MSCHWERN/Test-Simple-1.005000_005.tar.gz.

In so far, it is not such a misnomer.

Note that this and I<--with-module> will both require a C<CPAN::MyConfig>.
If F<$ENV{HOME}/.cpan/CPAN/MyConfig.pm> does not exist, a CPAN shell will
be started up for you so you can configure one. Feel free to let
CPAN pick defaults for you. Enter 'quit' when you are done, and
then everything should be all set. Alternatively, you may
specify a custom C<CPAN::MyConfig> by using I<--cpan-config-dir>.

Also, if you want to bisect a module that needs a display (like
TK) and you don't want random screens appearing and disappearing
on your computer while you're working, you can do something like
this:

In a terminal:

 $ while true; do date ; if ! ps auxww | grep -v grep \
   | grep -q Xvfb; then Xvfb :121 & fi; echo -n 'sleeping 60 '; \
   sleep 60; done

And then:

  DISPLAY=":121" .../Porting/bisect.pl --module=TK

(Some display alternatives are vncserver and Xnest.)

=item *

--with-module module1,module2,...

Like I<--module> above, except this simply installs the requested
modules and they can then be used in other tests.

For example:

  .../Porting/bisect.pl --with-module=Moose -e 'use Moose; ...'

=item *

--no-module-tests

Use in conjunction with I<--with-module> to install the modules without
running their tests. This can be a big time saver.

For example:

  .../Porting/bisect.pl --with-module=Moose --no-module-tests \
       -e 'use Moose; ...'

=item *

--test-module

This is like I<--module>, but just runs the module's tests, instead of
installing it.

WARNING: This is a somewhat experimental option, known to work on recent
CPAN shell versions.  If you use this option and strange things happen,
please report them.

Usually, you can just use I<--module>, but if you are getting inconsistent
installation failures and you just want to see when the tests started
failing, you might find this option useful.

=item *

--cpan-config-dir /home/blah/custom

If defined, this will cause L<CPAN> to look for F<CPAN/MyConfig.pm> inside of
the specified directory, instead of using the default config of
F<$ENV{HOME}/.cpan/>.

If no default config exists, a L<CPAN> shell will be fired up for you to
configure things. Letting L<CPAN> automatically configure things for you
should work well enough. You probably want to choose I<manual> instead of
I<local::lib> if it asks. When you're finished with configuration, just
type I<q> and hit I<ENTER> and the bisect should continue.

=item *

--force-manifest

By default, a build will "skip" if any files listed in F<MANIFEST> are not
present. Usually this is useful, as it avoids false-failures. However, there
are some long ranges of commits where listed files are missing, which can
cause a bisect to abort because all that remain are skipped revisions.

In these cases, particularly if the test case uses F<miniperl> and no modules,
it may be more useful to force the build to continue, even if files
F<MANIFEST> are missing.

=item *

--force-regen

Run C<make regen_headers> before building F<miniperl>. This may fix a build
that otherwise would skip because the generated headers at that revision
are stale. It's not the default because it conceals this error in the true
state of such revisions.

=item *

--expect-pass [0|1]

C<--expect-pass=0> is equivalent to C<--expect-fail>. I<1> is the default.

=item *

--timeout I<seconds>

Run the testcase with the given timeout. If this is exceeded, kill it (and
by default all its children), and treat it as a failure.

=item *

--setpgrp

Run the testcase in its own process group. Specifically, call C<setpgrp 0, 0>
just before C<exec>-ing the user testcase. The default is not to set the
process group, unless a timeout is used.

=item *

--all-fixups

F<bisect-runner.pl> will minimally patch various files on a platform and
version dependent basis to get the build to complete. Normally it defers
doing this as long as possible - C<.SH> files aren't patched until after
F<Configure> is run, and C<C> and C<XS> code isn't patched until after
F<miniperl> is built. If C<--all-fixups> is specified, all the fixups are
done before running C<Configure>. In rare cases adding this may cause a
bisect to abort, because an inapplicable patch or other fixup is attempted
for a revision which would usually have already I<skip>ped. If this happens,
please report it as a bug, giving the OS and problem revision.

=item *

--early-fixup file

=item *

--late-fixup file

Specify a file containing a patch or other fixup for the source code. The
action to take depends on the first line of the fixup file

=over 4

=item *

C<#!perl>

If the first line starts C<#!perl> then the file is run using C<$^X>

=item *

C<#!/absolute/path>

If a shebang line is present the file is executed using C<system>

=item *

C<I<filename> =~ /I<pattern>/>

=item *

C<I<filename> !~ /I<pattern>/>

If I<filename> does not exist then the fixup file's contents are ignored.
Otherwise, for C<=~>, if it contains a line matching I<pattern>, then the
file is fed to C<patch -p1> on standard input. For C<=~>, the patch is
applied if no lines match the pattern.

As the empty pattern in Perl is a special case (it matches the most recent
successful match) which is not useful here, the treatment of an empty pattern
is special-cased. C<I<filename> =~ //> applies the patch if filename is
present. C<I<filename> !~ //> applies the patch if filename missing. This
makes it easy to unconditionally apply patches to files, and to use a patch
as a way of creating a new file.

=item *

Otherwise, the file is assumed to be a patch, and always applied.

=back

I<early-fixup>s are applied before F<./Configure> is run. I<late-fixup>s are
applied just after F<./Configure> is run.

These options can be specified more than once. I<file> is actually expanded
as a glob pattern. Globs that do not match are errors, as are missing files.

=item *

--no-clean

Tell F<bisect-runner.pl> not to clean up after the build. This allows one
to use F<bisect-runner.pl> to build the current particular perl revision for
interactive testing, or for debugging F<bisect-runner.pl>.

Passing this to F<bisect.pl> will likely cause the bisect to fail badly.

=item *

--validate

Test that all stable (.0) revisions can be built. By default, attempts to
build I<blead>, then tagged stable releases in reverse order down to
I<perl-5.002> (or I<perl5.005> on a case insensitive file system). Stops at
the first failure, without cleaning the checkout. Use I<--start> to specify
the earliest revision to test, I<--end> to specify the most recent. Useful
for validating a new OS/CPU/compiler combination. For example

    ../perl/Porting/bisect.pl --validate -le 'print "Hello from $]"'

If no testcase is specified, the default is to use F<t/TEST> to run
F<t/base/*.t>

=item *

--check-args

Validate the options and arguments, and exit silently if they are valid.

=item *

--check-shebang

Validate that the test case isn't an executable file with a
C<#!/usr/bin/perl> line (or similar). As F<bisect-runner.pl> does B<not>
automatically prepend C<./perl> to the test case, a I<#!> line specifying an
external F<perl> binary will cause the test case to always run with I<that>
F<perl>, not the F<perl> built by the bisect runner. Likely this is not what
you wanted. If your test case is actually a wrapper script to run other
commands, you should run it with an explicit interpreter, to be clear. For
example, instead of C<../perl/Porting/bisect.pl ~/test/testcase.pl> you'd
run C<../perl/Porting/bisect.pl /usr/bin/perl ~/test/testcase.pl>

=item *

--gold

Revision to use when checking out known-good recent versions of files,
such as F<hints/freebsd.sh>. F<bisect-runner.pl> defaults this to I<blead>,
but F<bisect.pl> will default it to the most recent stable release.

=item *

--usage

=item *

--help

=item *

-?

Display the usage information and exit.

=back

=head1 ABOUT BISECTION

The process is all about identifying the commit that caused some change
in behaviour - maybe good, maybe bad. But it is built around C<git bisect>,
which is much more specifically aimed at finding "what broke the build".
C<git> terminology embeds that assumption - commits earlier than the
target commit are "good" commits, those at or later than the target commit
are "bad" commits.

The default behaviour of F<bisect.pl> mimics this - you supply some code
that I<fails> with a perl built B<at or after> the target commit and
I<succeeds> with a perl built B<before> the target commit, and F<bisect.pl>
will find the target commit.

The F<bisect.pl> option C<--expect-fail> reverses those expectations
(and changes nothing else). So with C<--expect-fail>, you should supply
code that I<fails> only with a perl built B<before> the target commit,
and I<succeeds> with a perl built B<at or after> the target commit.

By default, I<failure> is a piece of perl code that terminates with
a non-zero exit code, e.g. by calling C<die()>. Options that change what
is interpreted as failure include C<--crash>, C<--test-build> and C<--match>.

=head1 EXAMPLES

=head2 Code has started to crash under C<miniperl>

=over 4

=item * Problem

Under C<make minitest> (but not under C<make test_harness>), F<t/re/pat.t> was
failing to compile.  What was the first commit at which that compilation
failure could be observed?

=item * Solution

Extract code from the test file at the point where C<./miniperl -Ilib -c> was
showing a compilation failure.  Use that in bisection with the C<miniperl>
target.

    .../Porting/bisect.pl --target=miniperl --start=2ec4590e \
        -e 'q|ace| =~ /c(?=.$)/; $#{^CAPTURE} == -1); exit 0;'

=item * Reference

L<GH issue 17293|https://github.com/Perl/perl5/issues/17293>

=back

=head2 Blead breaks CPAN on threaded builds only

=over 4

=item * Problem

Tests in CPAN module XML::Parser's test suite had begun to fail when tested
against blead in threaded builds only.

=item * Solution

Provide F<Configure>-style switch to bisection program.  Straightforward use
of the C<--module> switch.

    .../Porting/bisect.pl -Duseithreads \
        --start=6256cf2c \
        --end=f6f85064 \
        --module=XML::Parser

=item * Reference

L<GH issue 16918|https://github.com/Perl/perl5/issues/16918>

=back

=head2 Point in time where code started to segfault is unknown

=over 4

=item * Problem

User submitted code sample which when run caused F<perl> to segfault, but did
not claim that this was a recent change.

=item * Solution

Used locally installed production releases of perl (previously created by
F<perlbrew>) to identify the first production release at which the code would
not compile.  Used that information to shorten bisection time.

    .../perl Porting/bisect.pl \
        --start=v5.14.4 \
        --end=v5.16.3 \
        --crash -- ./perl -Ilib /tmp/gh-17333-map.pl

    $ cat gh-17333-map.pl

    @N = 1..5;
    map { pop @N } @N;

=item * Reference

L<GH issue 17333|https://github.com/Perl/perl5/issues/17333>

=back

=head2 Interaction of debug flags caused crash on C<-DDEBUGGING> builds

=over 4

=item * Problem

In C<-DDEBUGGING> builds, the debug flags C<Xvt> would crash a program when
F<strict.pm> was loaded via C<require> or C<use>.

=item * Solution

Two-stage solution.  In each stage, to shorten debugging time investigator
made use of existing set of production releases of F<perl> built with
C<-DDEBUGGING>.

=over 4

=item * Stage 1

Investigator used existing C<-DDEBUGGING> builds to determine the production
cycle in which crash first appeared.  Then:

    .../perl/Porting/bisect.pl \
        --start v5.20.0 \
        --end v5.22.1 \
        -DDEBUGGING \
        --target miniperl \
        --crash \
        -- ./miniperl -Ilib -DXvt -Mstrict -e 1

First bad commit was identified as
L<ed958fa315|https://github.com/Perl/perl5/commit/ed958fa315>.

=item * Stage 2

A second investigator was able to create a reduction of the code needed to
trigger a crash, then used this reduced case and the commit reported at the
end of Stage 1 to further bisect.

 .../perl/Porting/bisect.pl \
   --start v5.18.4 \
   --end ed958fa315 \
   -DDEBUGGING \
   --target miniperl \
   --crash \
   -- ./miniperl -Ilib -DXv -e '{ my $n=1; *foo= sub () { $n }; }'

=back

The first bisect determined the point at which code was introduced to
F<strict.pm> that triggered the problem. With an understanding of the trigger,
the second bisect then determined the point at which such a trigger started
causing a crash.

* Reference

L<GH issue 193463|https://github.com/Perl/perl5/issues/19463>

=back

=head2 When did perl start failing to build on a certain platform using C<g++> as the C-compiler?

=over 4

=item * Problem

On NetBSD-8.0, C<perl> had never been smoke-tested using C<g++> as the
C-compiler.  Once this was done, it became evident that changes in that
version of the operating system's code were incompatible with some C<perl>
source written long before that OS version was ever released!

=item * Solution

Bisection range was first narrowed using existing builds at release tags.
Then, bisection specified the C-compiler via C<Configure>-style switch and
used C<--test-build> to identify the commit which "broke" the build.

    .../perl Porting/bisect.pl \
        -Dcc=g++ \
        --test-build \
        --start=v5.21.6 \
        --end=v5.21.7

Then, problem was discussed with knowledgeable NetBSD user.

=item * Reference

L<GH issue 17381|https://github.com/Perl/perl5/issues/17381>

=back

=head2 When did a test file start to emit warnings?

=over 4

=item * Problem

When F<dist/Tie-File/t/43_synopsis> was run as part of C<make test>, we
observed warnings not previously seen.  At what commit were those warnings
first emitted?

=item * Solution

We know that when this test file was first committed to blead, no warnings
were observed and there was no output to C<STDERR>.  So that commit becomes
the value for C<--start>.

Since the test file in question is for a CPAN distribution maintained by core,
we must prepare to run that test by including C<--target=test_prep> in the
bisection invocation.  We then run the test file in a way that captures
C<STDERR> in a file.  If that file has non-zero size, then we have presumably
captured the newly seen warnings.

    export ERR="/tmp/err"

    .../perl Porting/bisect.pl \
      --start=507614678018ae1abd55a22e9941778c65741ba3 \
      --end=d34b46d077dcfc479c36f65b196086abd7941c76 \
      --target=test_prep \
      -e 'chdir("t");
        system(
          "./perl harness ../dist/Tie-File/t/43_synopsis.t
            2>$ENV{ERR}"
        );
        -s $ENV{ERR} and die "See $ENV{ERR} for warnings thrown";'

Bisection pointed to a commit where strictures and warnings were first turned
on throughout the F<dist/Tie-File/> directory.

=item * Reference

L<Commit 125e1a3|https://github.com/Perl/perl5/commit/125e1a36a939>

=back

=head2 When did a one-liner start to emit warnings?

=over 4

=item * Problem

In L<GH issue 21555|https://github.com/Perl/perl5/issues/21555>, it was
reported that the following one-liner was not emitting warnings in perl-5.16
but was in perl-5.26 and later releases.

    perl -we '"ab" =~ /.{-1,4}/;'

The reporter's concern was the negative repeat in this (generated) regular
expression.  The warning being emitted was:

    Unescaped left brace in regex is passed through in regex;
      marked by <-- HERE in m/.{ <-- HERE -1,4}/ at -e line 1.

At what commit was that warning first emitted?

=item * Solution

We used F<perlbrew> to narrow down the range needing testing to the 5.25
development cycle.  We then bisected with the C<--one-liner> switch and the
following invocation:

    export ERR=/tmp/err; rm $ERR

    perl Porting/bisect.pl \
      --start=v5.24.0 \
      --end=v5.26.0 \
      --one-liner 'system(qq|./perl -we "q{ab} =~ /.{-1,4}/" 2>$ENV{ERR}|);
                  die "See $ENV{ERR} for warnings thrown" if -s $ENV{ERR};'

Bisection pointed to a commit where a modification had been made to a warning.

=item * Reference

L<Commit 8e84dec|https://github.com/Perl/perl5/commit/8e84dec289>

=back

=head2 When did perl stop segfaulting on certain code?

=over 4

=item * Problem

It was reported that perl was segfaulting on this code in perl-5.36.0:

    @a = sort{eval"("}1,2

Bisection subsequently identified the commit at which the segfaulting first
appeared.  But when we ran that code against what was then the HEAD of blead
(L<Commit 70d911|https://github.com/Perl/perl5/commit/70d911984f>), we got no
segfault.  So the next question we faced was: At what commit did the
segfaulting cease?

=item * Solution

Because the code in question loaded no libraries, it was amenable to bisection
with C<miniperl>, thereby shortening bisection time considerably.

    perl Porting/bisect.pl \
        --start=v5.36.0 \
        --target=miniperl \
        --expect-fail -e '@a = sort{eval"("}1,2'

=item * Reference

L<GH issue 20261|https://github.com/Perl/perl5/issues/20261>

=back

=head2 When did perl stop emitting warnings when running on certain code?

=over 4

=item * Background

Most of the time, we bisect in order to identify the first "bad" commit:  the
first time code failed to compile; the first time the code emitted warnings;
and so forth.

Some times, however, we want to identify the first "good" commit:  the point
where the code began to compile; the point where the code no longer emitted
warnings; etc.

We can use this program for that purpose, but we have to reverse our sense of
"good" and "bad" commits.  We use the C<--expect-fail> option to do that
reversal.

=item * Problem

It was reported that in an older version of Perl, a warning was being emitted
when a program was using the F<bigrat> module and
C<Scalar::Util::looks_like_number()> was called passing a non-integral number
(I<i.e.,> a rational).

    $ perl -wE 'use Scalar::Util; use bigrat;
      say "mercy" if Scalar::Util::looks_like_number(1/9);'

In perl-5.32, this emitted:

    $ Argument "1/9" isn't numeric in addition (+) at
      /usr/local/lib/perl5/5.32/Math/BigRat.pm line 1955.
      mercy

But it was observed that there was no warning in perl-5.36.

=item * Solution

    $ perl Porting/bisect.pl \
        --start=5624cfff8f \
        --end=b80b9f7fc6 \
        --expect-fail \
        -we 'use Scalar::Util; use bigrat; my @w;
            local $SIG{__WARN__} = sub { die };
            print "mercy\n" if Scalar::Util::looks_like_number(1/9)'

=item * Reference

L<GH issue 20685|https://github.com/Perl/perl5/issues/20685>

=item * Problem

An issue was identified during use of the Perl debugger, but soon a change in
C-level code became suspected.  Identifying the breaking commit entailed
writing a Perl program which used a dummy C<Devel::*> module.

=item * Solution

=over 4

=item *

Create this file:

    $ cat /tmp/21564.pl
    #!/usr/bin/perl

    use strict; no strict 'refs';
    use warnings;
    use B qw(svref_2object SVf_IOK);

    use v5.10;

    my $b = svref_2object(\(${"_</tmp/21564b.pl"}[4]));
    unless ($b->FLAGS & SVf_IOK) {
      die "Fail!";
    }
    say "Ok";

=item *

Bisect with an invocation which calls a `perl` debugger program.

    $ PERL5DB='sub DB::DB {}' perl Porting/bisect.pl \
      --start=v5.35.5 \
      --end=v5.35.6 \
      -- ./perl -Ilib -d /tmp/21564b.pl

=back

=item * Reference

L<GH issue 21564|https://github.com/Perl/perl5/issues/21564>

=back

=head2 When did program using locally installed module stop crashing?

=over 4

=item * Problem

Use of a feature (C<module_true>) was reported as crashing under certain
circumstances (the experimental C<class> feature).  The program demonstrating
the crash needed to use a module installed in the same directory as the demo
program.  The feature was subsequently reported to be working properly.  At what
commit did the program stop crashing?

=item * Solution

The module:

    $ cat /tmp/Noofoo.pm
    # https://github.com/Perl/perl5/issues/23435
    use experimental 'class';
    use feature 'module_true';
    class Noofoo;
    ADJUST {}

The demonstration program:

    $ cat /tmp/foo.pl
    use strict;
    use warnings;
    use Noofoo;
    print "Hello world!\n";

The bisection invocation:

    $ perl Porting/bisect.pl \
    --expect-fail \
    --start=v5.43.3 \
    --end=v5.43.4 \
    -- ./perl -Ilib -I/tmp "/tmp/foo.pl"

=item * Reference

L<GH issue 23435|https://github.com/Perl/perl5/issues/23435#issuecomment-3067034712>

=back

=cut

# ex: set ts=8 sts=4 sw=4 et:
