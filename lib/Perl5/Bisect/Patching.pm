package Perl5::Bisect::Patching;
use strict;
use warnings;
use Data::Dump qw(dd pp);
use Perl5::Bisect::Auxiliary qw(
    edit_file
    open_or_die
    close_or_die
    system_or_die
    die_255
    skip
    extract_from_file
    apply_patch
    apply_commit
    checkout_file
);
our ( $VERSION, @ISA, @EXPORT_OK );
$VERSION = "0.01";
require Exporter;
@ISA         = qw(Exporter);
@EXPORT_OK = ( qw|
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
|);

=head1 NAME

Perl5::Bisect::Patching - Patching, editing, faking subroutines for Perl5::Bisect

=head1 SYNOPSIS

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

=head1 DESCRIPTION

This module exports on request only subroutines used in
F<bin/bisect-runner.pl>.  These subroutines derive from the subroutines
defined in F<Porting/bisect-runner.pl> in the Perl 5 core distribution.  These
subroutines are grouped together in this package because they are all
concerned with preparing the files found at a particular F<git> commit in the
core distribution for use in a bisection.  That preparation may require
patching F<MANIFEST>, F<Configure>, F<hints/*.sh>, etc.

This module uses other subroutines which are also used directly by F<bin/bisect-runner.pl>.  Those other subroutines are defined in, and exported by, F<Perl::Bisect::Auxiliary>.

=cut

############################################################################
#
# Patching, editing and faking routines only below here.
#
############################################################################

=head1 SUBROUTINES

sub fake_noextensions {
    #print "ZZZ: fake_noextensions\n";
    my $defines = shift;
    edit_file('config.sh', sub {
                  my @lines = split /\n/, shift;
                  my @ext = split /\s+/, $defines->{noextensions};
                  foreach (@lines) {
                      next unless /^extensions=/ || /^dynamic_ext/;
                      foreach my $ext (@ext) {
                          s/\b$ext( )?\b/$1/;
                      }
                  }
                  return join "\n", @lines;
              });
}

=head2 C<force_manifest>

=over 4

=item * Purpose

Identify defects in the F<MANIFEST> that may impact bisection.

=item * Arguments

    my ($missing, $created_dirs) = force_manifest();

No arguments needed.

=item * Return Value

Two array references.  This first holds a list of files missing from the
F<MANIFEST> in the directory where bisection is being conducted.  The second
is to a list of directories created in TK.

=item * Comment

In production, this subroutine is only run if the switch C<--force-manifest>
has been provided on the command line.

=back

=cut

sub force_manifest {
    #print "ZZZ: force_manifest\n";
    my (@missing, @created_dirs);
    my $fh = open_or_die('MANIFEST');
    while (<$fh>) {
        next unless /^(\S+)/;
        # -d is special case needed (at least) between 27332437a2ed1941 and
        # bf3d9ec563d25054^ inclusive, as manifest contains ext/Thread/Thread
        push @missing, $1
            unless -f $1 || -d $1;
    }
    close_or_die($fh);

    foreach my $pathname (@missing) {
        my @parts = split '/', $pathname;
        my $leaf = pop @parts;
        my $path = '.';
        while (@parts) {
            $path .= '/' . shift @parts;
            next if -d $path;
            # In core, this was 0700
            mkdir $path, 0711 or die_255("Can't create $path: $!");
            unshift @created_dirs, $path;
        }
        $fh = open_or_die($pathname, '>');
        close_or_die($fh);

        # Why do we want to chmod to 0 here?
        # Why not something like 0664 as in core distribution?

        # chmod 0, $pathname or die_255("Can't chmod 0 $pathname: $!");

        # commit 67382a3b09f476ec932adab80ae6b37134864f9b
        # Author:     Nicholas Clark <nick@ccl4.org>
        # AuthorDate: Sat Oct 1 16:23:41 2011 +0200
        # Commit:     Nicholas Clark <nick@ccl4.org>
        # CommitDate: Sat Oct 1 16:31:06 2011 +0200
        #
        #     Add options --force-manifest and --test-build to bisect.pl
        #
        #     --force-manifest touches any files in MANIFEST that are missing. This avoids
        #     hanging on 5.004 or earlier (where Configure's stdin is a tty) when Configure
        #     detects the missing files and asks you if you want to stop. It's also useful
        #     on 5.005 or later if you don't want to treat missing files as a "skip".
        #     --test-build changes behaviour to treat failing to build the target exectuable
        #     as a "fail", instead of a "skip".
        #
        # But there's no specific explanation for 'chmod 0'!
        # Let's try something more normal

        chmod 0664, $pathname or die_255("Can't chmod 0664 $pathname: $!");
    }
    return \@missing, \@created_dirs;
}

=head2 C<force_manifest_cleanup>

=over 4

=item * Purpose

=item * Arguments

=item * Return Value

=item * Comment

=back

=cut

sub force_manifest_cleanup {
    #print "ZZZ: force_manifest_cleanup\n";
    my ($missing, $created_dirs) = @_;
    # This is probably way too paranoid:
    my @errors;
    require Fcntl;
    foreach my $file (@$missing) {
        my (undef, undef, $mode, undef, undef, undef, undef, $size)
            = stat $file;
        if (!defined $mode) {
            push @errors, "Added file $file has been deleted by Configure";
            next;
        }
        if (Fcntl::S_IMODE($mode) != 0) {
            push @errors,
                sprintf 'Added file %s had mode changed by Configure to %03o',
                    $file, $mode;
        }
        if ($size != 0) {
            push @errors,
                "Added file $file had sized changed by Configure to $size";
        }
        unlink $file or die_255("Can't unlink $file: $!");
    }
    foreach my $dir (@$created_dirs) {
        rmdir $dir or die_255("Can't rmdir $dir: $!");
    }
    skip("@errors")
        if @errors;
}

sub patch_Configure {
    #print "ZZZ: patch_Configure\n";
    my $major = shift;
    if ($major < 1) {
        if (extract_from_file('Configure',
                              qr/^\t\t\*=\*\) echo "\$1" >> \$optdef;;$/)) {
            # This is "        Spaces now allowed in -D command line options.",
            # part of commit ecfc54246c2a6f42
            apply_patch(<<'EOPATCH');
diff --git a/Configure b/Configure
index 3d3b38d..78ffe16 100755
--- a/Configure
+++ b/Configure
@@ -652,7 +777,8 @@ while test $# -gt 0; do
 			echo "$me: use '-U symbol=', not '-D symbol='." >&2
 			echo "$me: ignoring -D $1" >&2
 			;;
-		*=*) echo "$1" >> $optdef;;
+		*=*) echo "$1" | \
+				sed -e "s/'/'\"'\"'/g" -e "s/=\(.*\)/='\1'/" >> $optdef;;
 		*) echo "$1='define'" >> $optdef;;
 		esac
 		shift
EOPATCH
        }

        if (extract_from_file('Configure', qr/^if \$contains 'd_namlen' \$xinc\b/)) {
            # Configure's original simple "grep" for d_namlen falls foul of the
            # approach taken by the glibc headers:
            # #ifdef _DIRENT_HAVE_D_NAMLEN
            # # define _D_EXACT_NAMLEN(d) ((d)->d_namlen)
            #
            # where _DIRENT_HAVE_D_NAMLEN is not defined on Linux.
            # This is also part of commit ecfc54246c2a6f42
            apply_patch(<<'EOPATCH');
diff --git a/Configure b/Configure
index 3d3b38d..78ffe16 100755
--- a/Configure
+++ b/Configure
@@ -3935,7 +4045,8 @@ $rm -f try.c
 
 : see if the directory entry stores field length
 echo " "
-if $contains 'd_namlen' $xinc >/dev/null 2>&1; then
+$cppstdin $cppflags $cppminus < "$xinc" > try.c
+if $contains 'd_namlen' try.c >/dev/null 2>&1; then
 	echo "Good, your directory entry keeps length information in d_namlen." >&4
 	val="$define"
 else
EOPATCH
        }
    }

    if ($major < 2
        && !extract_from_file('Configure',
                              qr/Try to guess additional flags to pick up local libraries/)) {
        my $mips = extract_from_file('Configure',
                                     qr!(''\) if (?:\./)?mips; then)!);
        # This is part of perl-5.001n. It's needed, to add -L/usr/local/lib to
        # the ld flags if libraries are found there. It shifts the code to set
        # up libpth earlier, and then adds the code to add libpth entries to
        # ldflags
        # mips was changed to ./mips in ecfc54246c2a6f42, perl5.000 patch.0g
        apply_patch(sprintf <<'EOPATCH', $mips);
diff --git a/Configure b/Configure
index 53649d5..0635a6e 100755
--- a/Configure
+++ b/Configure
@@ -2749,6 +2749,52 @@ EOM
 	;;
 esac
 
+: Set private lib path
+case "$plibpth" in
+'') if ./mips; then
+		plibpth="$incpath/usr/lib /usr/local/lib /usr/ccs/lib"
+	fi;;
+esac
+case "$libpth" in
+' ') dlist='';;
+'') dlist="$plibpth $glibpth";;
+*) dlist="$libpth";;
+esac
+
+: Now check and see which directories actually exist, avoiding duplicates
+libpth=''
+for xxx in $dlist
+do
+    if $test -d $xxx; then
+		case " $libpth " in
+		*" $xxx "*) ;;
+		*) libpth="$libpth $xxx";;
+		esac
+    fi
+done
+$cat <<'EOM'
+
+Some systems have incompatible or broken versions of libraries.  Among
+the directories listed in the question below, please remove any you
+know not to be holding relevant libraries, and add any that are needed.
+Say "none" for none.
+
+EOM
+case "$libpth" in
+'') dflt='none';;
+*)
+	set X $libpth
+	shift
+	dflt=${1+"$@"}
+	;;
+esac
+rp="Directories to use for library searches?"
+. ./myread
+case "$ans" in
+none) libpth=' ';;
+*) libpth="$ans";;
+esac
+
 : flags used in final linking phase
 case "$ldflags" in
 '') if ./venix; then
@@ -2765,6 +2811,23 @@ case "$ldflags" in
 	;;
 *) dflt="$ldflags";;
 esac
+
+: Possible local library directories to search.
+loclibpth="/usr/local/lib /opt/local/lib /usr/gnu/lib"
+loclibpth="$loclibpth /opt/gnu/lib /usr/GNU/lib /opt/GNU/lib"
+
+: Try to guess additional flags to pick up local libraries.
+for thislibdir in $libpth; do
+	case " $loclibpth " in
+	*" $thislibdir "*)
+		case "$dflt " in 
+		"-L$thislibdir ") ;;
+		*)  dflt="$dflt -L$thislibdir" ;;
+		esac
+		;;
+	esac
+done
+
 echo " "
 rp="Any additional ld flags (NOT including libraries)?"
 . ./myread
@@ -2828,52 +2891,6 @@ n) echo "OK, that should do.";;
 esac
 $rm -f try try.* core
 
-: Set private lib path
-case "$plibpth" in
-%s
-		plibpth="$incpath/usr/lib /usr/local/lib /usr/ccs/lib"
-	fi;;
-esac
-case "$libpth" in
-' ') dlist='';;
-'') dlist="$plibpth $glibpth";;
-*) dlist="$libpth";;
-esac
-
-: Now check and see which directories actually exist, avoiding duplicates
-libpth=''
-for xxx in $dlist
-do
-    if $test -d $xxx; then
-		case " $libpth " in
-		*" $xxx "*) ;;
-		*) libpth="$libpth $xxx";;
-		esac
-    fi
-done
-$cat <<'EOM'
-
-Some systems have incompatible or broken versions of libraries.  Among
-the directories listed in the question below, please remove any you
-know not to be holding relevant libraries, and add any that are needed.
-Say "none" for none.
-
-EOM
-case "$libpth" in
-'') dflt='none';;
-*)
-	set X $libpth
-	shift
-	dflt=${1+"$@"}
-	;;
-esac
-rp="Directories to use for library searches?"
-. ./myread
-case "$ans" in
-none) libpth=' ';;
-*) libpth="$ans";;
-esac
-
 : compute shared library extension
 case "$so" in
 '')
EOPATCH
    }

    if ($major < 4 && extract_from_file('Configure',
                                        qr/: see which flavor of setpgrp is in use/)) {
        edit_file('Configure', sub {
                      my $code = shift;
                      my $new = <<'EOT';
if $cc $ccflags $ldflags -o set set.c $libs >/dev/null 2>&1; then
EOT
                      chomp $new;

                      # before commit ecfc54246c2a6f42:
                      # before commit 8e07c86ebc651fe9:
                      my @old = (<<'EOT', <<'EOT');
if $cc $ccflags -o set $ldflags set.c $libs >/dev/null 2>&1; then
EOT
if $cc $ccflags -o set set.c $ldflags $libs >/dev/null 2>&1; then
EOT
                      for my $was (@old) {
                          # Yes, this modifies @old. No problem here:
                          chomp $was;
                          $was = quotemeta $was;
                          $code =~ s/$was/$new/;
                      }

                      # also commit ecfc54246c2a6f42:
                      $code =~ s!\tif usg; then!\tif ./usg; then!;

                      return $code;
                  });

        # We need the new probe from 2afac517c48c20de, which has prototypes
        # (but include the various C headers unconditionally)
        apply_patch(<<'EOPATCH');
diff --git a/Configure b/Configure
index 18f2172435..5a75ebd767 100755
--- a/Configure
+++ b/Configure
@@ -4986,45 +5055,61 @@ eval $inlibc
 set setpgrp d_setpgrp
 eval $inlibc
 
-: see which flavor of setpgrp is in use
+echo "Checking to see which flavor of setpgrp is in use . . . "
 case "$d_setpgrp" in
 "$define")
 	echo " "
 	$cat >set.c <<EOP
+#include <stdio.h>
+#include <sys/types.h>
+#include <unistd.h>
 main()
 {
 	if (getuid() == 0) {
 		printf("(I see you are running Configure as super-user...)\n");
 		setuid(1);
 	}
+#ifdef TRY_BSD_PGRP
 	if (-1 == setpgrp(1, 1))
-		exit(1);
-	exit(0);
+		exit(0);
+#else
+	if (setpgrp() != -1)
+		exit(0);
+#endif
+	exit(1);
 }
 EOP
-	if $cc $ccflags $ldflags -o set set.c $libs >/dev/null 2>&1; then
-		./set 2>/dev/null
-		case $? in
-		0) echo "You have to use setpgrp() instead of setpgrp(pid, pgrp)." >&4
-			val="$undef";;
-		*) echo "You have to use setpgrp(pid, pgrp) instead of setpgrp()." >&4
-			val="$define";;
-		esac
+	if $cc -DTRY_BSD_PGRP $ccflags $ldflags -o set set.c $libs >/dev/null 2>&1 && ./set; then
+		echo 'You have to use setpgrp(pid,pgrp) instead of setpgrp().' >&4
+		val="$define"
+	elif $cc $ccflags $ldflags -o set set.c $libs >/dev/null 2>&1 && ./set; then
+		echo 'You have to use setpgrp() instead of setpgrp(pid,pgrp).' >&4
+		val="$undef"
 	else
+		echo "I can't seem to compile and run the test program."
 		if ./usg; then
-			xxx="USG one, i.e. you use setpgrp()."
-			val="$undef"
+			xxx="a USG one, i.e. you use setpgrp()."
 		else
-			xxx="BSD one, i.e. you use setpgrp(pid, pgrp)."
-			val="$define"
+			# SVR4 systems can appear rather BSD-ish.
+			case "$i_unistd" in
+			$undef)
+				xxx="a BSD one, i.e. you use setpgrp(pid,pgrp)."
+				val="$define"
+				;;
+			$define)
+				xxx="probably a USG one, i.e. you use setpgrp()."
+				val="$undef"
+				;;
+			esac
 		fi
-		echo "Assuming your setpgrp is a $xxx" >&4
+		echo "Assuming your setpgrp is $xxx" >&4
 	fi
 	;;
 *) val="$undef";;
 esac
-set d_bsdpgrp
+set d_bsdsetpgrp
 eval $setvar
+d_bsdpgrp=$d_bsdsetpgrp
 $rm -f set set.c
 
 : see if bzero exists
EOPATCH
    }

    if ($major == 4 && extract_from_file('Configure', qr/^d_gethbynam=/)) {
        # Fixes a bug introduced in 4599a1dedd47b916
        apply_commit('3cbc818d1d0ac470');
    }

    if ($major == 4 && extract_from_file('Configure',
                                         qr/gethbadd_addr_type=`echo \$gethbadd_addr_type/)) {
        # Fixes a bug introduced in 3fd537d4b944bc7a
        apply_commit('6ff9219da6cf8cfd');
    }

    if ($major == 4 && extract_from_file('Configure',
                                         qr/^pthreads_created_joinable=/)) {
        # Fix for bug introduced in 52e1cb5ebf5e5a8c
        # Part of commit ce637636a41b2fef
        edit_file('Configure', sub {
                      my $code = shift;
                      $code =~ s{^pthreads_created_joinable=''}
                                {d_pthreads_created_joinable=''}ms
                                    or die_255("Substitution failed");
                      $code =~ s{^pthreads_created_joinable='\$pthreads_created_joinable'}
                                {d_pthreads_created_joinable='\$d_pthreads_created_joinable'}ms
                           or die_255("Substitution failed");
                      return $code;
                  });
    }

    if ($major < 5 && extract_from_file('Configure',
                                        qr!if \$cc \$ccflags try\.c -o try >/dev/null 2>&1; then!)) {
        # Analogous to the more general fix of dfe9444ca7881e71
        # Without this flags such as -m64 may not be passed to this compile,
        # which results in a byteorder of '1234' instead of '12345678', which
        # can then cause crashes.

        if (extract_from_file('Configure', qr/xxx_prompt=y/)) {
            # 8e07c86ebc651fe9 or later
            # ("This is my patch  patch.1n  for perl5.001.")
            apply_patch(<<'EOPATCH');
diff --git a/Configure b/Configure
index 62249dd..c5c384e 100755
--- a/Configure
+++ b/Configure
@@ -8247,7 +8247,7 @@ main()
 }
 EOCP
 	xxx_prompt=y
-	if $cc $ccflags try.c -o try >/dev/null 2>&1 && ./try > /dev/null; then
+	if $cc $ccflags $ldflags try.c -o try >/dev/null 2>&1 && ./try > /dev/null; then
 		dflt=`./try`
 		case "$dflt" in
 		[1-4][1-4][1-4][1-4]|12345678|87654321)
EOPATCH
        } else {
            apply_patch(<<'EOPATCH');
diff --git a/Configure b/Configure
index 53649d5..f1cd64a 100755
--- a/Configure
+++ b/Configure
@@ -6362,7 +6362,7 @@ main()
 	printf("\n");
 }
 EOCP
-	if $cc $ccflags try.c -o try >/dev/null 2>&1 ; then
+	if $cc $ccflags $ldflags try.c -o try >/dev/null 2>&1 ; then
 		dflt=`./try`
 		case "$dflt" in
 		????|????????) echo "(The test program ran ok.)";;
EOPATCH
        }
    }

    if ($major < 5) {
        my $what = extract_from_file('Configure', qr!(\s+)return __libc_main!);
        if ($what) {
            # To add to the fun commit commit dfe9444ca7881e71 in Feb 1988
            # changed several things:
            if ($what !~ /\t/) {
                apply_patch(<<'EOPATCH');
--- a/Configure
+++ b/Configure
@@ -3854,11 +3911,12 @@ n) echo "OK, that should do.";;
 int
 main()
 {
-  return __libc_main();
+	return __libc_main();
 }
 EOM
-if $cc $ccflags $ldflags -o gnulibc gnulibc.c $libs >/dev/null 2>&1 && \
-    ./gnulibc | $contains '^GNU C Library' >/dev/null 2>&1; then
+set gnulibc
+if eval $compile && \
+  ./gnulibc | $contains '^GNU C Library' >/dev/null 2>&1; then
 	val="$define"
 	echo "You are using the GNU C Library"
 else
EOPATCH
            }

            # And commit dc45a647708b6c54 tweaks 1 line in April 1998
            edit_file('Configure', sub {
                          my $code = shift;
                          $code =~ s{contains '\^GNU C Library' >/dev/null 2>&1; then}
                                    {contains '^GNU C Library'; then};
                          return $code;
                      });

            # This is part of aebf16e7cdbc86ec from June 1998
            # but with compiles_ok inlined
            apply_patch(<<'EOPATCH');
diff --git a/Configure b/Configure
index 38072f0e5e..43735feacf 100755
--- a/Configure
+++ b/Configure
@@ -4024,15 +4024,19 @@ $cc $optimize $ccflags $ldflags -o ${mc_file} $* ${mc_file}.c $libs;'
 echo " "
 echo "Checking for GNU C Library..." >&4
 cat >gnulibc.c <<EOM
+#include <stdio.h>
 int
 main()
 {
-	return __libc_main();
+#ifdef __GLIBC__
+    exit(0);
+#else
+    exit(1);
+#endif
 }
 EOM
 set gnulibc
-if eval $compile && \
-  ./gnulibc | $contains '^GNU C Library'; then
+if $cc $ccflags $ldflags -o gnulibc gnulibc.c $libs && ./gnulibc; then
 	val="$define"
 	echo "You are using the GNU C Library"
 else
EOPATCH
        }
    }

    if ($major < 6 && !extract_from_file('Configure',
                                         qr!^\t-A\)$!)) {
        # This adds the -A option to Configure, which is incredibly useful
        # Effectively this is commits 02e93a22d20fc9a5, 5f83a3e9d818c3ad,
        # bde6b06b2c493fef, f7c3111703e46e0c and 2 lines of trailing whitespace
        # removed by 613d6c3e99b9decc, but applied at slightly different
        # locations to ensure a clean patch back to 5.000
        # Note, if considering patching to the intermediate revisions to fix
        # bugs in -A handling, f7c3111703e46e0c is from 2002, and hence
        # $major == 8

        # To add to the fun, early patches add -K and -O options, and it's not
        # trivial to get patch to put the C<. ./posthint.sh> in the right place
        edit_file('Configure', sub {
                      my $code = shift;
                      $code =~ s/(optstr = ")([^"]+";\s*# getopt-style specification)/$1A:$2/
                          or die_255("Substitution failed");
                      $code =~ s!^(: who configured the system)!
touch posthint.sh
. ./posthint.sh

$1!ms
                          or die_255("Substitution failed");
                      return $code;
                  });
        apply_patch(<<'EOPATCH');
diff --git a/Configure b/Configure
index 4b55fa6..60c3c64 100755
--- a/Configure
+++ b/Configure
@@ -1150,6 +1150,7 @@ set X `for arg in "$@"; do echo "X$arg"; done |
 eval "set $*"
 shift
 rm -f options.awk
+rm -f posthint.sh
 
 : set up default values
 fastread=''
@@ -1172,6 +1173,56 @@ while test $# -gt 0; do
 	case "$1" in
 	-d) shift; fastread=yes;;
 	-e) shift; alldone=cont;;
+	-A)
+	    shift
+	    xxx=''
+	    yyy="$1"
+	    zzz=''
+	    uuu=undef
+	    case "$yyy" in
+            *=*) zzz=`echo "$yyy"|sed 's!=.*!!'`
+                 case "$zzz" in
+                 *:*) zzz='' ;;
+                 *)   xxx=append
+                      zzz=" "`echo "$yyy"|sed 's!^[^=]*=!!'`
+                      yyy=`echo "$yyy"|sed 's!=.*!!'` ;;
+                 esac
+                 ;;
+            esac
+            case "$xxx" in
+            '')  case "$yyy" in
+                 *:*) xxx=`echo "$yyy"|sed 's!:.*!!'`
+                      yyy=`echo "$yyy"|sed 's!^[^:]*:!!'`
+                      zzz=`echo "$yyy"|sed 's!^[^=]*=!!'`
+                      yyy=`echo "$yyy"|sed 's!=.*!!'` ;;
+                 *)   xxx=`echo "$yyy"|sed 's!:.*!!'`
+                      yyy=`echo "$yyy"|sed 's!^[^:]*:!!'` ;;
+                 esac
+                 ;;
+            esac
+	    case "$xxx" in
+	    append)
+		echo "$yyy=\"\${$yyy}$zzz\""	>> posthint.sh ;;
+	    clear)
+		echo "$yyy=''"			>> posthint.sh ;;
+	    define)
+	        case "$zzz" in
+		'') zzz=define ;;
+		esac
+		echo "$yyy='$zzz'"		>> posthint.sh ;;
+	    eval)
+		echo "eval \"$yyy=$zzz\""	>> posthint.sh ;;
+	    prepend)
+		echo "$yyy=\"$zzz\${$yyy}\""	>> posthint.sh ;;
+	    undef)
+	        case "$zzz" in
+		'') zzz="$uuu" ;;
+		esac
+		echo "$yyy=$zzz"		>> posthint.sh ;;
+            *)  echo "$me: unknown -A command '$xxx', ignoring -A $1" >&2 ;;
+	    esac
+	    shift
+	    ;;
 	-f)
 		shift
 		cd ..
EOPATCH
    }

    if ($major < 6) {
        edit_file('Configure', sub {
                      my $code = shift;
                      # This will cause a build failure, but it will stop
                      # Configure looping endlessly trying to get a different
                      # answer:
                      $code =~ s{(dflt=)n(\n\s+rp="Function \$ans does not exist)}
                                {$1y$2};
                      return $code;
                  });
    }

    if ($major < 8 && $^O eq 'aix') {
        edit_file('Configure', sub {
                      my $code = shift;
                      # Replicate commit a8c676c69574838b
                      # Whitespace allowed at the ends of /lib/syscalls.exp lines
                      # and half of commit c6912327ae30e6de
                      # AIX syscalls.exp scan: the syscall might be marked 32, 3264, or 64
                      $code =~ s{(\bsed\b.*\bsyscall)(?:\[0-9\]\*)?(\$.*/lib/syscalls\.exp)}
                                {$1 . "[0-9]*[ \t]*" . $2}e;
                      return $code;
                  });
    }

    if ($major < 8 && !extract_from_file('Configure',
                                         qr/^\t\tif test ! -t 0; then$/)) {
        # Before dfe9444ca7881e71, Configure would refuse to run if stdin was
        # not a tty. With that commit, the tty requirement was dropped for -de
        # and -dE
        # Commit aaeb8e512e8e9e14 dropped the tty requirement for -S
        # For those older versions, it's probably easiest if we simply remove
        # the sanity test.
        edit_file('Configure', sub {
                      my $code = shift;
                      $code =~ s/test ! -t 0/test Perl = rules/;
                      return $code;
                  });
    }

    if ($major < 32) {
        edit_file('Configure', sub {
                      my $code = shift;

                      # A lot of the probes used to be written assuming no need
                      # for prototypes for exit(), printf() etc.
                      # Curiously also the code was written to call exit()
                      # rather than return from main - early portability?
                      #
                      # Commit 55954f198635e488 did most of the work in ensuring
                      # that there was always a prototype for exit, by adding
                      # #include <stdlib.h> in many probes. However the last
                      # missing prototype was only addressed by f16c94bc75aefb81
                      # (for futimes), and the last missing prototypes a few
                      # commits later in f82f0f36c7188b6d
                      #
                      # As an aside, commit dc45a647708b6c54 fixes the signal
                      # name probe (etc) - the commit tagged as perl-5.004_01
                      # *seems* to fix the signal name probe, but actually it
                      # fixes an error in the fallback awk code, not the C
                      # probe's missing prototype.
                      #
                      # With current C compilers there is no correctness risk
                      # from including a header more than once, so the easiest
                      # approach to making this all work is to add includes
                      # "to be sure to be sure"
                      #
                      # The trick is not to break *working* probes by
                      # accidentally including a header *within* a construction.
                      # So we need to have some confidence that it's the start
                      # of a file (or somewhere safe)

                      my $headers = <<'EOFIX';
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
EOFIX

                      # This handles $cat and plain cat:
                      $code =~ s{([\$\t\n ]cat > *[a-z0-9]+\.c <<[^\n]*\n)}
                                {$1$headers}g;
                      # Of course, there's always one that's backwards:
                      $code =~ s{([\$\t\n ]cat <<[^\n]* > *[a-z0-9]+\.c\n)}
                                {$1$headers}g;

                      # and >> used to *create* a file.
                      # We have to be careful to distinguish those from >> used
                      # to append to a file. All the first lines have #include
                      # or #ifdef. Except the few that don't...
                      $code =~ s{
                                    ([\$\t\n ]cat\ >>\ *[a-z]+\.c\ <<[^\n]*\n)
                                    (
                                        # #include/#ifdef ...
                                        \#
                                    |
                                        # The non-blocking IO probe
                                        (?:int\ )?main\(\)
                                    |
                                        # The alignment constraint probe
                                        struct\ foobar
                                    )
                                }
                                {$1$headers$2}gx;

                      # This is part of commit c727eafaa06ca49a:
                      $code =~ s{\(int\)exit\(0\);}
                                {\(void\)exit\(0\);};

                      return $code;
                  });
    }

    if ($major < 10) {
        # Fix symbol detection to that of commit 373dfab3839ca168 if it's any
        # intermediate version 5129fff43c4fe08c or later, as the intermediate
        # versions don't work correctly on (at least) Sparc Linux.
        # 5129fff43c4fe08c adds the first mention of mistrustnm.
        # 373dfab3839ca168 removes the last mention of lc=""
        #
        # Fix symbol detection prior to 5129fff43c4fe08c to use the same
        # approach, where we don't call printf without a prototype
        # We can't include <stdio.h> to get its prototype, as the way this works
        # is to create a (wrong) prototype for the probed functions, and those
        # conflict if the function in question is in stdio.h.
        edit_file('Configure', sub {
                      my $code = shift;
                      return $code
                          if $code !~ /\btc="";/; # 373dfab3839ca168 or later
                      if ($code !~ /\bmistrustnm\b/) {
                          # doing this as a '' heredoc seems to be the easiest
                          # way to avoid confusing levels of backslashes:
                          my $now = <<'EOT';
void *(*(p()))$tdc { extern void *$1$tdc; return &$1; } int main() { if(p()) return(0); else return(1); }
EOT
                          chomp $now;

                          # before 5129fff43c4fe08c
                          # befure 16d20bd98cd29be7
                          my @old = (<<'EOT', <<'EOT');
main() { extern short $1$tdc; printf(\"%hd\", $1$tc); }
EOT
main() { extern int $1$tdc; printf(\"%d\", $1$tc); }
EOT
                          for my $was (@old) {
                              chomp $was;
                              $was = quotemeta $was;

                              # Prior to commit d674cd6de52ff38b there was no
                              # 'int ' for 'int main'
                              $code =~ s/(?:int )?$was/$now/;
                          }
                          return $code;
                      }

                      my $fixed = <<'EOC';

: is a C symbol defined?
csym='tlook=$1;
case "$3" in
-v) tf=libc.tmp; tdc="";;
-a) tf=libc.tmp; tdc="[]";;
*) tlook="^$1\$"; tf=libc.list; tdc="()";;
esac;
tx=yes;
case "$reuseval-$4" in
true-) ;;
true-*) tx=no; eval "tval=\$$4"; case "$tval" in "") tx=yes;; esac;;
esac;
case "$tx" in
yes)
	tval=false;
	if $test "$runnm" = true; then
		if $contains $tlook $tf >/dev/null 2>&1; then
			tval=true;
		elif $test "$mistrustnm" = compile -o "$mistrustnm" = run; then
			echo "void *(*(p()))$tdc { extern void *$1$tdc; return &$1; } int main() { if(p()) return(0); else return(1); }"> try.c;
			$cc -o try $optimize $ccflags $ldflags try.c >/dev/null 2>&1 $libs && tval=true;
			$test "$mistrustnm" = run -a -x try && { $run ./try$_exe >/dev/null 2>&1 || tval=false; };
			$rm -f try$_exe try.c core core.* try.core;
		fi;
	else
		echo "void *(*(p()))$tdc { extern void *$1$tdc; return &$1; } int main() { if(p()) return(0); else return(1); }"> try.c;
		$cc -o try $optimize $ccflags $ldflags try.c $libs >/dev/null 2>&1 && tval=true;
		$rm -f try$_exe try.c;
	fi;
	;;
*)
	case "$tval" in
	$define) tval=true;;
	*) tval=false;;
	esac;
	;;
esac;
eval "$2=$tval"'

EOC
                      $code =~ s/\n: is a C symbol defined\?\n.*?\neval "\$2=\$tval"'\n\n/$fixed/sm
                          or die_255("substitution failed");
                      return $code;
                  });
    }

    if ($major < 10
        && extract_from_file('Configure', qr/^set malloc\.h i_malloc$/)) {
        # This is commit 01d07975f7ef0e7d, trimmed, with $compile inlined as
        # prior to bd9b35c97ad661cc Configure had the malloc.h test before the
        # definition of $compile.
        apply_patch(<<'EOPATCH');
diff --git a/Configure b/Configure
index 3d2e8b9..6ce7766 100755
--- a/Configure
+++ b/Configure
@@ -6743,5 +6743,22 @@ set d_dosuid
 
 : see if this is a malloc.h system
-set malloc.h i_malloc
-eval $inhdr
+: we want a real compile instead of Inhdr because some systems have a
+: malloc.h that just gives a compile error saying to use stdlib.h instead
+echo " "
+$cat >try.c <<EOCP
+#include <stdlib.h>
+#include <malloc.h>
+int main () { return 0; }
+EOCP
+set try
+if $cc $optimize $ccflags $ldflags -o try $* try.c $libs > /dev/null 2>&1; then
+    echo "<malloc.h> found." >&4
+    val="$define"
+else
+    echo "<malloc.h> NOT found." >&4
+    val="$undef"
+fi
+$rm -f try.c try
+set i_malloc
+eval $setvar
 
EOPATCH
    }

    if ($major < 38 && !extract_from_file('Configure', qr/Too many attempts asking the same question/)) {
        # Without this, myread can loop infinitely trying to get a valid answer,
        # and hence Configure gets stuck in a loop, outputting the same question
        # repeatedly. This isn't what we need.
        apply_commit('46bfb3c49f22629a');
    }
}

sub patch_hints {
    #print "ZZZ: patch_hints\n";
    my ($options, $case_insensitive, $major) = @_;
    if ($^O eq 'freebsd') {
        # There are rather too many version-specific FreeBSD hints fixes to
        # patch individually. Also, more than once the FreeBSD hints file has
        # been written in what turned out to be a rather non-future-proof style,
        # with case statements treating the most recent version as the
        # exception, instead of treating previous versions' behaviour explicitly
        # and changing the default to cater for the current behaviour. (As
        # strangely, future versions inherit the current behaviour.)
        #checkout_file('hints/freebsd.sh');
        checkout_file({
            file => 'hints/freebsd.sh',
            commit => '',
            options => $options,
        });
    } elsif ($^O eq 'darwin') {
        if ($major < 8) {
            # We can't build on darwin without some of the data in the hints
            # file. Probably less surprising to use the earliest version of
            # hints/darwin.sh and then edit in place just below, than use
            # blead's version, as that would create a discontinuity at
            # f556e5b971932902 - before it, hints bugs would be "fixed", after
            # it they'd resurface. This way, we should give the illusion of
            # monotonic bug fixing.
            my $faking_it;
            if (!-f 'hints/darwin.sh') {
                checkout_file({
                    file => 'hints/darwin.sh',
                    commit => 'f556e5b971932902',
                    options => $options,
                });
                ++$faking_it;
            }

            edit_file('hints/darwin.sh', sub {
                      my $code = shift;
                      # Part of commit 8f4f83badb7d1ba9, which mostly undoes
                      # commit 0511a818910f476c.
                      $code =~ s/^cppflags='-traditional-cpp';$/cppflags="\${cppflags} -no-cpp-precomp"/m;
                      # commit 14c11978e9b52e08/803bb6cc74d36a3f
                      # Without this, code in libperl.bundle links against op.o
                      # in preference to opmini.o on the linker command line,
                      # and hence miniperl tries to use File::Glob instead of
                      # csh
                      $code =~ s/^(lddlflags=)/ldflags="\${ldflags} -flat_namespace"\n$1/m;
                      # f556e5b971932902 also patches Makefile.SH with some
                      # special case code to deal with useshrplib for darwin.
                      # Given that post 5.8.0 the darwin hints default was
                      # changed to false, and it would be very complex to splice
                      # in that code in various versions of Makefile.SH back
                      # to 5.002, lets just turn it off.
                      $code =~ s/^useshrplib='true'/useshrplib='false'/m
                          if $faking_it;

                      # Part of commit d235852b65d51c44
                      # Don't do this on a case sensitive HFS+ partition, as it
                      # breaks the build for 5.003 and earlier.
                      if ($case_insensitive
                          && $code !~ /^firstmakefile=GNUmakefile/) {
                          $code .= "\nfirstmakefile=GNUmakefile;\n";
                      }

                      return $code;
                  });
        }

        if ($major < 8 ||
                ($major < 10 && !extract_from_file('ext/DynaLoader/Makefile.PL',
                                                   qr/sub MY::static /))) {
            edit_file('hints/darwin.sh', sub {
                          my $code = shift;
                          # As above, the build fails if version of code in op.o
                          # is linked to, instead of opmini.o
                          # We don't need this after commit 908fcb8bef8cbab8,
                          # which moves DynaLoader.o into the shared perl
                          # library, as it *also* redoes the build so that
                          # miniperl is linked against all the object files
                          # (explicitly excluding op.o), instead of against the
                          # shared library (and reyling on "flat namespaces"
                          # - ie make Mach-O behave like ELF - to end up with
                          # objects in the library linking against opmini.o)
                          $code .= <<'EOHACK';

# Force a flat namespace everywhere:
echo $ldflags | grep flat_namespace || ldflags=`echo \$lddflags -flat_namespace`
echo $lddlflags | grep flat_namespace || lddlflags=`echo \$lddlflags -flat_namespace`
EOHACK
                          return $code;
                      });
        }

        if ($major < 16) {
            edit_file('hints/darwin.sh', sub {
                          my $code = shift;
                          # This is commit 60a655a1ee05c577
                          $code =~ s/usenm='true'/usenm='false'/;

                          # With the Configure probes fixed (in patch_Configure)
                          # the "d_stdstdio" logic now concludes "define".
                          # Unfortunately that is not correct - attempting to
                          # build 5.8.0 without this override results in SEGVs
                          # or similar chaos.
                          #
                          # The problem is introduced by commit 5a3a8a022aa61cba
                          # which enables perlio by default.
                          # The problem is hidden after 15b61c98f82f3010, which
                          # adds "d_faststdio" and defaults it to "undef" from
                          # that commit onwards, but override that and the build
                          # would break, up until "turning off perlio" was
                          # disabled by commit dd35fa16610ef2fa
                          $code .= "\nd_stdstdio='undef'\n";

                          return $code;
                      });
        }

        if ($major < 34) {
            edit_file('hints/darwin.sh', sub {
                      my $code = shift;
                      # This is commits aadc6422eaec39c2 and 54d41b60822734cf
                      # rolled into one:
                      $code =~ s/    10\.\*(?: \| 11\.\*)?\)/    [1-9][0-9].*)/g;
                      return $code;
                  });
        }
    } elsif ($^O eq 'netbsd') {
        if ($major < 6) {
            # These are part of commit 099685bc64c7dbce
            edit_file('hints/netbsd.sh', sub {
                          my $code = shift;
                          my $fixed = <<'EOC';
case "$osvers" in
0.9|0.8*)
	usedl="$undef"
	;;
*)
	if [ -f /usr/libexec/ld.elf_so ]; then
		d_dlopen=$define
		d_dlerror=$define
		ccdlflags="-Wl,-E -Wl,-R${PREFIX}/lib $ccdlflags"
		cccdlflags="-DPIC -fPIC $cccdlflags"
		lddlflags="--whole-archive -shared $lddlflags"
	elif [ "`uname -m`" = "pmax" ]; then
# NetBSD 1.3 and 1.3.1 on pmax shipped an 'old' ld.so, which will not work.
		d_dlopen=$undef
	elif [ -f /usr/libexec/ld.so ]; then
		d_dlopen=$define
		d_dlerror=$define
		ccdlflags="-Wl,-R${PREFIX}/lib $ccdlflags"
# we use -fPIC here because -fpic is *NOT* enough for some of the
# extensions like Tk on some netbsd platforms (the sparc is one)
		cccdlflags="-DPIC -fPIC $cccdlflags"
		lddlflags="-Bforcearchive -Bshareable $lddlflags"
	else
		d_dlopen=$undef
	fi
	;;
esac
EOC
                          $code =~ s/^case "\$osvers" in\n0\.9\|0\.8.*?^esac\n/$fixed/ms;
                          return $code;
                      });
        }
    } elsif ($^O eq 'openbsd') {
        if ($major < 8) {
            checkout_file({
                file => 'hints/openbsd.sh',
                commit => '43051805d53a3e4c',
                options => $options,
            }) unless -f 'hints/openbsd.sh';
            my $which = extract_from_file('hints/openbsd.sh',
                                          qr/# from (2\.8|3\.1) onwards/,
                                          '');
            if ($which eq '') {
                my $was = extract_from_file('hints/openbsd.sh',
                                            qr/(lddlflags="(?:-Bforcearchive )?-Bshareable)/);
                # This is commit 154d43cbcf57271c and parts of 5c75dbfa77b0949c
                # and 29b5585702e5e025
                apply_patch(sprintf <<'EOPATCH', $was);
diff --git a/hints/openbsd.sh b/hints/openbsd.sh
index a7d8bf2..5b79709 100644
--- a/hints/openbsd.sh
+++ b/hints/openbsd.sh
@@ -37,7 +37,25 @@ OpenBSD.alpha|OpenBSD.mips|OpenBSD.powerpc|OpenBSD.vax)
 	# we use -fPIC here because -fpic is *NOT* enough for some of the
 	# extensions like Tk on some OpenBSD platforms (ie: sparc)
 	cccdlflags="-DPIC -fPIC $cccdlflags"
-	%s $lddlflags"
+	case "$osvers" in
+	[01].*|2.[0-7]|2.[0-7].*)
+		lddlflags="-Bshareable $lddlflags"
+		;;
+	2.[8-9]|3.0)
+		ld=${cc:-cc}
+		lddlflags="-shared -fPIC $lddlflags"
+		;;
+	*) # from 3.1 onwards
+		ld=${cc:-cc}
+		lddlflags="-shared -fPIC $lddlflags"
+		libswanted=`echo $libswanted | sed 's/ dl / /'`
+		;;
+	esac
+
+	# We need to force ld to export symbols on ELF platforms.
+	# Without this, dlopen() is crippled.
+	ELF=`${cc:-cc} -dM -E - </dev/null | grep __ELF__`
+	test -n "$ELF" && ldflags="-Wl,-E $ldflags"
 	;;
 esac
 
EOPATCH
            } elsif ($which eq '2.8') {
                # This is parts of 5c75dbfa77b0949c and 29b5585702e5e025, and
                # possibly eb9cd59d45ad2908
                my $was = extract_from_file('hints/openbsd.sh',
                                            qr/lddlflags="(-shared(?: -fPIC)?) \$lddlflags"/);

                apply_patch(sprintf <<'EOPATCH', $was);
--- a/hints/openbsd.sh	2011-10-21 17:25:20.000000000 +0200
+++ b/hints/openbsd.sh	2011-10-21 16:58:43.000000000 +0200
@@ -44,11 +44,21 @@
 	[01].*|2.[0-7]|2.[0-7].*)
 		lddlflags="-Bshareable $lddlflags"
 		;;
-	*) # from 2.8 onwards
+	2.[8-9]|3.0)
 		ld=${cc:-cc}
-		lddlflags="%s $lddlflags"
+		lddlflags="-shared -fPIC $lddlflags"
+		;;
+	*) # from 3.1 onwards
+		ld=${cc:-cc}
+		lddlflags="-shared -fPIC $lddlflags"
+		libswanted=`echo $libswanted | sed 's/ dl / /'`
 		;;
 	esac
+
+	# We need to force ld to export symbols on ELF platforms.
+	# Without this, dlopen() is crippled.
+	ELF=`${cc:-cc} -dM -E - </dev/null | grep __ELF__`
+	test -n "$ELF" && ldflags="-Wl,-E $ldflags"
 	;;
 esac
 
EOPATCH
            } elsif ($which eq '3.1'
                     && !extract_from_file('hints/openbsd.sh',
                                           qr/We need to force ld to export symbols on ELF platforms/)) {
                # This is part of 29b5585702e5e025
                apply_patch(<<'EOPATCH');
diff --git a/hints/openbsd.sh b/hints/openbsd.sh
index c6b6bc9..4839d04 100644
--- a/hints/openbsd.sh
+++ b/hints/openbsd.sh
@@ -54,6 +54,11 @@ alpha-2.[0-8]|mips-*|vax-*|powerpc-2.[0-7]|m88k-*)
 		libswanted=`echo $libswanted | sed 's/ dl / /'`
 		;;
 	esac
+
+	# We need to force ld to export symbols on ELF platforms.
+	# Without this, dlopen() is crippled.
+	ELF=`${cc:-cc} -dM -E - </dev/null | grep __ELF__`
+	test -n "$ELF" && ldflags="-Wl,-E $ldflags"
 	;;
 esac
 
EOPATCH
            }
        }
    } elsif ($^O eq 'linux') {
        if ($major < 1) {
            # sparc linux seems to need the -Dbool=char -DHAS_BOOL part of
            # perl5.000 patch.0n: [address Configure and build issues]
            edit_file('hints/linux.sh', sub {
                          my $code = shift;
                          $code =~ s!-I/usr/include/bsd!-Dbool=char -DHAS_BOOL!g;
                          return $code;
                      });
        }

        if ($major <= 9) {
            if (`uname -sm` =~ qr/^Linux sparc/) {
                if (extract_from_file('hints/linux.sh', qr/sparc-linux/)) {
                    # Be sure to use -fPIC not -fpic on Linux/SPARC
                    apply_commit('f6527d0ef0c13ad4');
                } elsif(!extract_from_file('hints/linux.sh',
                                           qr/^sparc-linux\)$/)) {
                    my $fh = open_or_die('hints/linux.sh', '>>');
                    print $fh <<'EOT' or die_255($!);

case "`uname -m`" in
sparc*)
	case "$cccdlflags" in
	*-fpic*) cccdlflags="`echo $cccdlflags|sed 's/-fpic/-fPIC/'`" ;;
	*)	 cccdlflags="$cccdlflags -fPIC" ;;
	esac
	;;
esac
EOT
                    close_or_die($fh);
                }
            }
        }
    } elsif ($^O eq 'solaris') {
        if (($major == 13 || $major == 14)
            && extract_from_file('hints/solaris_2.sh', qr/getconfldllflags/)) {
            apply_commit('c80bde4388070c45');
        }
    }
}

sub patch_SH {
    #print "ZZZ: patch_SH\n";
    my ($aggressive_apple_security, $major, $options) = @_;
    # Cwd.xs added in commit 0d2079faa739aaa9. Cwd.pm moved to ext/ 8 years
    # later in commit 403f501d5b37ebf0
    if ($major > 0 && <*/Cwd/Cwd.xs>) {
        if ($major < 10
            && !extract_from_file('Makefile.SH', qr/^extra_dep=''$/)) {
            # The Makefile.PL for Unicode::Normalize needs
            # lib/unicore/CombiningClass.pl. Even without a parallel build, we
            # need a dependency to ensure that it builds. This is a variant of
            # commit 9f3ef600c170f61e. Putting this for earlier versions gives
            # us a spot on which to hang the edits below
            apply_patch(<<'EOPATCH');
diff --git a/Makefile.SH b/Makefile.SH
index f61d0db..6097954 100644
--- a/Makefile.SH
+++ b/Makefile.SH
@@ -155,10 +155,20 @@ esac
 
 : Prepare dependency lists for Makefile.
 dynamic_list=' '
+extra_dep=''
 for f in $dynamic_ext; do
     : the dependency named here will never exist
       base=`echo "$f" | sed 's/.*\///'`
-    dynamic_list="$dynamic_list lib/auto/$f/$base.$dlext"
+    this_target="lib/auto/$f/$base.$dlext"
+    dynamic_list="$dynamic_list $this_target"
+
+    : Parallel makes reveal that we have some interdependencies
+    case $f in
+	Math/BigInt/FastCalc) extra_dep="$extra_dep
+$this_target: lib/auto/List/Util/Util.$dlext" ;;
+	Unicode/Normalize) extra_dep="$extra_dep
+$this_target: lib/unicore/CombiningClass.pl" ;;
+    esac
 done
 
 static_list=' '
@@ -987,2 +997,9 @@ n_dummy $(nonxs_ext):	miniperl$(EXE_EXT) preplibrary $(DYNALOADER) FORCE
 	@$(LDLIBPTH) sh ext/util/make_ext nonxs $@ MAKE=$(MAKE) LIBPERL_A=$(LIBPERL)
+!NO!SUBS!
+
+$spitshell >>Makefile <<EOF
+$extra_dep
+EOF
+
+$spitshell >>Makefile <<'!NO!SUBS!'
 
EOPATCH
        }

        if ($major == 15 && $^O !~ /^(linux|darwin|.*bsd)$/
            && extract_from_file('Makefile.SH', qr/^V.* \?= /)) {
            # Remove the GNU-make-ism (which the BSD makes also support, but
            # most other makes choke on)
            apply_patch(<<'EOPATCH');
diff --git a/Makefile.SH b/Makefile.SH
index 94952bd..13e9001 100755
--- a/Makefile.SH
+++ b/Makefile.SH
@@ -338,8 +338,8 @@ linux*|darwin)
 $spitshell >>$Makefile <<!GROK!THIS!
 # If you're going to use valgrind and it can't be invoked as plain valgrind
 # then you'll need to change this, or override it on the make command line.
-VALGRIND ?= valgrind
-VG_TEST  ?= ./perl -e 1 2>/dev/null
+VALGRIND = valgrind
+VG_TEST  = ./perl -e 1 2>/dev/null
 
 !GROK!THIS!
 	;;
EOPATCH
        }

        if ($major == 11) {
            if (extract_from_file('patchlevel.h',
                                  qr/^#include "unpushed\.h"/)) {
                # I had thought it easier to detect when building one of the 52
                # commits with the original method of incorporating the git
                # revision and drop parallel make flags. Commits shown by
                # git log 46807d8e809cc127^..dcff826f70bf3f64^ ^d4fb0a1f15d1a1c4
                # However, it's not actually possible to make miniperl for that
                # configuration as-is, because the file .patchnum is only made
                # as a side effect of target 'all'
                # I also don't think that it's "safe" to simply run
                # make_patchnum.sh before the build. We need the proper
                # dependency rules in the Makefile to *stop* it being run again
                # at the wrong time.
                # This range is important because contains the commit that
                # merges Schwern's y2038 work.
                apply_patch(<<'EOPATCH');
diff --git a/Makefile.SH b/Makefile.SH
index 9ad8b6f..106e721 100644
--- a/Makefile.SH
+++ b/Makefile.SH
@@ -540,9 +544,14 @@ sperl.i: perl.c $(h)
 
 .PHONY: all translators utilities make_patchnum
 
-make_patchnum:
+make_patchnum: lib/Config_git.pl
+
+lib/Config_git.pl: make_patchnum.sh
 	sh $(shellflags) make_patchnum.sh
 
+# .patchnum, unpushed.h and lib/Config_git.pl are built by make_patchnum.sh
+unpushed.h .patchnum: lib/Config_git.pl
+
 # make sure that we recompile perl.c if .patchnum changes
 perl$(OBJ_EXT): .patchnum unpushed.h
 
EOPATCH
            } elsif (-f '.gitignore'
                     && extract_from_file('.gitignore', qr/^\.patchnum$/)) {
                # 8565263ab8a47cda to 46807d8e809cc127^ inclusive.
                edit_file('Makefile.SH', sub {
                              my $code = shift;
                              $code =~ s/^make_patchnum:\n/make_patchnum: .patchnum

.sha1: .patchnum

.patchnum: make_patchnum.sh
/m;
                              return $code;
                          });
            } elsif (-f 'lib/.gitignore'
                     && extract_from_file('lib/.gitignore',
                                          qr!^/Config_git.pl!)
                     && !extract_from_file('Makefile.SH',
                                        qr/^uudmap\.h.*:bitcount.h$/)) {
                # Between commits and dcff826f70bf3f64 and 0f13ebd5d71f8177^
                edit_file('Makefile.SH', sub {
                              my $code = shift;
                              # Bug introduced by 344af494c35a9f0f
                              # fixed in 0f13ebd5d71f8177
                              $code =~ s{^(pod/perlapi\.pod) (pod/perlintern\.pod): }
                                        {$1: $2\n\n$2: }m;
                              # Bug introduced by efa50c51e3301a2c
                              # fixed in 0f13ebd5d71f8177
                              $code =~ s{^(uudmap\.h) (bitcount\.h): }
                                        {$1: $2\n\n$2: }m;

                              # The rats nest of getting git_version.h correct

                              if ($code =~ s{git_version\.h: stock_git_version\.h
\tcp stock_git_version\.h git_version\.h}
                                            {}m) {
                                  # before 486cd780047ff224

                                  # We probably can't build between
                                  # 953f6acfa20ec275^ and 8565263ab8a47cda
                                  # inclusive, but all commits in that range
                                  # relate to getting make_patchnum.sh working,
                                  # so it is extremely unlikely to be an
                                  # interesting bisect target. They will skip.

                                  # No, don't spawn a submake if
                                  # make_patchnum.sh or make_patchnum.pl fails
                                  $code =~ s{\|\| \$\(MAKE\) miniperl.*}
                                            {}m;
                                  $code =~ s{^\t(sh.*make_patchnum\.sh.*)}
                                            {\t-$1}m;

                                  # Use an external perl to run make_patchnum.pl
                                  # because miniperl still depends on
                                  # git_version.h
                                  $code =~ s{^\t.*make_patchnum\.pl}
                                            {\t-$^X make_patchnum.pl}m;


                                  # "Truth in advertising" - running
                                  # make_patchnum generates 2 files.
                                  $code =~ s{^make_patchnum:.*}{
make_patchnum: lib/Config_git.pl

git_version.h: lib/Config_git.pl

perlmini\$(OBJ_EXT): git_version.h

lib/Config_git.pl:}m;
                              }
                              # Right, now we've corrected Makefile.SH to
                              # correctly describe how lib/Config_git.pl and
                              # git_version.h are made, we need to fix the rest

                              # This emulates commit 2b63e250843b907e
                              # This might duplicate the rule stating that
                              # git_version.h depends on lib/Config_git.pl
                              # This is harmless.
                              $code =~ s{^(?:lib/Config_git\.pl )?git_version\.h: (.* make_patchnum\.pl.*)}
                                        {git_version.h: lib/Config_git.pl

lib/Config_git.pl: $1}m;

                              # This emulates commits 0f13ebd5d71f8177
                              # and a04d4598adc57886. It ensures that
                              # lib/Config_git.pl is built before configpm,
                              # and that configpm is run exactly once.
                              $code =~ s{^(\$\(.*?\) )?(\$\(CONFIGPOD\))(: .*? configpm Porting/Glossary)( lib/Config_git\.pl)?}{
                                  # If present, other files depend on $(CONFIGPOD)
                                  ($1 ? "$1: $2\n\n" : '')
                                      # Then the rule we found
                                      . $2 . $3
                                          # Add dependency if not there
                                          . ($4 ? $4 : ' lib/Config_git.pl')
                              }me;

                              return $code;
                          });
            }
        }

        if ($major < 14) {
            # Commits dc0655f797469c47 and d11a62fe01f2ecb2
            edit_file('Makefile.SH', sub {
                          my $code = shift;
                          foreach my $ext (qw(Encode SDBM_File)) {
                              next if $code =~ /\b$ext\) extra_dep=/s;
                              $code =~ s!(\) extra_dep="\$extra_dep
\$this_target: .*?" ;;)
(    esac
)!$1
	$ext) extra_dep="\$extra_dep
\$this_target: lib/auto/Cwd/Cwd.\$dlext" ;;
$2!;
                          }
                          return $code;
                      });
        }
    }

    if ($major == 3) {
        # This is part of commit f0efd8cf98c95b42:
        edit_file('Makefile.SH', sub {
                      my $code = shift;
                      $code =~ s/<<!NO!SUBS!/<<'!NO!SUBS!'/;
                      return $code;
                  });
    }

    if ($major == 7) {
        # Remove commits 9fec149bb652b6e9 and 5bab1179608f81d8, which add/amend
        # rules to automatically run regen scripts that rebuild C headers. These
        # cause problems because a git checkout doesn't preserve relative file
        # modification times, hence the regen scripts may fire. This will
        # obscure whether the repository had the correct generated headers
        # checked in.
        # Also, the dependency rules for running the scripts were not correct,
        # which could cause spurious re-builds on re-running make, and can cause
        # complete build failures for a parallel make.
        if (extract_from_file('Makefile.SH',
                              qr/Writing it this way gives make a big hint to always run opcode\.pl before/)) {
            apply_commit('70c6e6715e8fec53');
        } elsif (extract_from_file('Makefile.SH',
                                   qr/^opcode\.h opnames\.h pp_proto\.h pp\.sym: opcode\.pl$/)) {
            revert_commit('9fec149bb652b6e9');
        }
    }

    if ($^O eq 'darwin' && ($major < 8
                                || ($major < 10
                                    && !extract_from_file('ext/DynaLoader/Makefile.PL',
                                                          qr/sub MY::static /)))) {
        my $cwd = Cwd::getcwd();
        my $wrapper = 'miniperl.sh';
        my $fh = open_or_die($wrapper, '>');
        print $fh <<"EOT";
#!/bin/sh
${aggressive_apple_security}exec $cwd/miniperl "\$\@"
EOT
        close_or_die($fh);
        chmod 0755, $wrapper
            or die "Couldn't chmod 0755 $wrapper: $!";

        edit_file('ext/util/make_ext', sub {
                      my $code = shift;
                      # This is shell expansion syntax
                      $code =~ s{ (\.\./\$depth/miniperl) }
                                { $1.sh };
                      # This is actually the same line as edited above.
                      # We need this because (yay), without this EU::MM will
                      # default to searching for a working perl binary
                      # (sensible plan) but due to macOS stripping
                      # DYLD_LIBRARY_PATH during system(...), .../miniperl
                      # (as found from $^X) *isn't* going to work.
                      $code =~ s{ (Makefile\.PL INSTALLDIRS=perl) }
                                { $1 PERL=\.\./\$depth/miniperl.sh };
                      return $code;
                  });
    }

    if ($^O eq 'aix' && $major >= 8 && $major < 28
        && extract_from_file('Makefile.SH', qr!\Q./$(MINIPERLEXP) makedef.pl\E.*aix!)) {
        # This is a variant the AIX part of commit 72bbce3da5eeffde:
        # miniperl also needs -Ilib for perl.exp on AIX etc
        edit_file('Makefile.SH', sub {
                      my $code = shift;
                      $code =~ s{(\Q./$(MINIPERLEXP)\E) (makedef\.pl.*aix)}
                                {$1 -Ilib $2};
                      return $code;
                  })
    }
    # This is the line before the line we've edited just above:
    if ($^O eq 'aix' && $major >= 11 && $major <= 15
        && extract_from_file('makedef.pl', qr/^use Config/)) {
        edit_file('Makefile.SH', sub {
                      # The AIX part of commit e6807d8ab22b761c
                      # It's safe to substitute lib/Config.pm for config.sh
                      # as lib/Config.pm depends on config.sh
                      # If the tree is post e6807d8ab22b761c, the substitution
                      # won't match, which is harmless.
                      my $code = shift;
                      $code =~ s{^(perl\.exp:.* )config\.sh(\b.*)}
                                {$1 . '$(CONFIGPM)' . $2}me;
                      return $code;
                  });
    }

    # There was a bug in makedepend.SH which was fixed in version 96a8704c.
    # Symptom was './makedepend: 1: Syntax error: Unterminated quoted string'
    # Remove this if you're actually bisecting a problem related to
    # makedepend.SH
    # If you do this, you may need to add in code to correct the output of older
    # makedepends, which don't correctly filter newer gcc output such as
    # <built-in>

    # It's the same version in v5.26.0 to v5.34.0
    # Post v5.34.0, commit 8d469d0ecbd06a99 completely changes how makedepend.SH
    # interacts with Makefile.SH, meaning that it's not a drop-in upgrade.
    checkout_file({
        file => 'makedepend.SH',
        commit => 'v5.34.0',
        options => $options,
    }) if $major < 26;

    if ($major < 4 && -f 'config.sh'
        && !extract_from_file('config.sh', qr/^trnl=/)) {
        # This seems to be necessary to avoid makedepend becoming confused,
        # and hanging on stdin. Seems that the code after
        # make shlist || ...here... is never run.
        edit_file('makedepend.SH', sub {
                      my $code = shift;
                      $code =~ s/^trnl='\$trnl'$/trnl='\\n'/m;
                      return $code;
                  });
    }
}

sub patch_C {
    #print "ZZZ: patch_C\n";
    my $major = shift;
    # This is ordered by $major, as it's likely that different platforms may
    # well want to share code.

    if ($major == 0) {
        apply_patch(<<'EOPATCH');
diff --git a/proto.h b/proto.h
index 9ffc6bbabc..16da198342 100644
--- a/proto.h
+++ b/proto.h
@@ -8,6 +8,7 @@
 #endif
 #ifdef OVERLOAD
 SV*	amagic_call _((SV* left,SV* right,int method,int dir));
+bool Gv_AMupdate _((HV* stash));
 #endif /* OVERLOAD */
 OP*	append_elem _((I32 optype, OP* head, OP* tail));
 OP*	append_list _((I32 optype, LISTOP* first, LISTOP* last));
EOPATCH
    }

    if ($major == 2 && extract_from_file('perl.c', qr/^\tfclose\(e_fp\);$/)) {
        # need to patch perl.c to avoid calling fclose() twice on e_fp when
        # using -e
        # This diff is part of commit ab821d7fdc14a438. The second close was
        # introduced with perl-5.002, commit a5f75d667838e8e7
        # Might want a6c477ed8d4864e6 too, for the corresponding change to
        # pp_ctl.c (likely without this, eval will have "fun")
        apply_patch(<<'EOPATCH');
diff --git a/perl.c b/perl.c
index 03c4d48..3c814a2 100644
--- a/perl.c
+++ b/perl.c
@@ -252,6 +252,7 @@ setuid perl scripts securely.\n");
 #ifndef VMS  /* VMS doesn't have environ array */
     origenviron = environ;
 #endif
+    e_tmpname = Nullch;
 
     if (do_undump) {
 
@@ -405,6 +406,7 @@ setuid perl scripts securely.\n");
     if (e_fp) {
 	if (Fflush(e_fp) || ferror(e_fp) || fclose(e_fp))
 	    croak("Can't write to temp file for -e: %s", Strerror(errno));
+	e_fp = Nullfp;
 	argc++,argv--;
 	scriptname = e_tmpname;
     }
@@ -470,10 +472,10 @@ setuid perl scripts securely.\n");
     curcop->cop_line = 0;
     curstash = defstash;
     preprocess = FALSE;
-    if (e_fp) {
-	fclose(e_fp);
-	e_fp = Nullfp;
+    if (e_tmpname) {
 	(void)UNLINK(e_tmpname);
+	Safefree(e_tmpname);
+	e_tmpname = Nullch;
     }
 
     /* now that script is parsed, we can modify record separator */
@@ -1369,7 +1371,7 @@ SV *sv;
 	scriptname = xfound;
     }
 
-    origfilename = savepv(e_fp ? "-e" : scriptname);
+    origfilename = savepv(e_tmpname ? "-e" : scriptname);
     curcop->cop_filegv = gv_fetchfile(origfilename);
     if (strEQ(origfilename,"-"))
 	scriptname = "";

EOPATCH
    }

    if ($major < 3 && $^O eq 'openbsd'
        && !extract_from_file('pp_sys.c', qr/BSD_GETPGRP/)) {
        # Part of commit c3293030fd1b7489
        apply_patch(<<'EOPATCH');
diff --git a/pp_sys.c b/pp_sys.c
index 4608a2a..f0c9d1d 100644
--- a/pp_sys.c
+++ b/pp_sys.c
@@ -2903,8 +2903,8 @@ PP(pp_getpgrp)
 	pid = 0;
     else
 	pid = SvIVx(POPs);
-#ifdef USE_BSDPGRP
-    value = (I32)getpgrp(pid);
+#ifdef BSD_GETPGRP
+    value = (I32)BSD_GETPGRP(pid);
 #else
     if (pid != 0)
 	DIE("POSIX getpgrp can't take an argument");
@@ -2933,8 +2933,8 @@ PP(pp_setpgrp)
     }
 
     TAINT_PROPER("setpgrp");
-#ifdef USE_BSDPGRP
-    SETi( setpgrp(pid, pgrp) >= 0 );
+#ifdef BSD_SETPGRP
+    SETi( BSD_SETPGRP(pid, pgrp) >= 0 );
 #else
     if ((pgrp != 0) || (pid != 0)) {
 	DIE("POSIX setpgrp can't take an argument");
EOPATCH
    }

    # _(( was the macro wrapper for hiding ANSI prototypes from K&R C compilers:
    if ($major == 3 && !extract_from_file('proto.h', qr/\bsafemalloc\s+_\(\(/)) {
        # This is part of commit bbce6d69784bf43b:
        # [inseparable changes from patch from perl5.003_08 to perl5.003_09]
        # This only affects a few versions, but without this safemalloc etc get
        # an implicit return type (of int), and that is truncating addresses on
        # 64 bit systems. (And these days, seems that x86_64 linux has a memory
        # map which causes malloc to return addresses >= 2**32)
        apply_patch(<<'EOPATCH');
diff --git a/proto.h b/proto.h
index 851567b340..e650c8b07d 100644
--- a/proto.h
+++ b/proto.h
@@ -479,6 +479,13 @@ Malloc_t realloc _((Malloc_t where, MEM_SIZE nbytes));
 Free_t   free _((Malloc_t where));
 #endif
 
+#ifndef MYMALLOC
+Malloc_t safemalloc _((MEM_SIZE nbytes));
+Malloc_t safecalloc _((MEM_SIZE elements, MEM_SIZE size));
+Malloc_t saferealloc _((Malloc_t where, MEM_SIZE nbytes));
+Free_t   safefree _((Malloc_t where));
+#endif
+
 #ifdef LEAKTEST
 Malloc_t safexmalloc _((I32 x, MEM_SIZE size));
 Malloc_t safexcalloc _((I32 x, MEM_SIZE elements, MEM_SIZE size));
EOPATCH
    }

    if ($major < 4 && $^O eq 'openbsd') {
        my $bad;
        # Need changes from commit a6e633defa583ad5.
        # Commits c07a80fdfe3926b5 and f82b3d4130164d5f changed the same part
        # of perl.h

        if (extract_from_file('perl.h',
                              qr/^#ifdef HAS_GETPGRP2$/)) {
            $bad = <<'EOBAD';
***************
*** 57,71 ****
  #define TAINT_PROPER(s)	if (tainting) taint_proper(no_security, s)
  #define TAINT_ENV()	if (tainting) taint_env()
  
! #ifdef HAS_GETPGRP2
! #   ifndef HAS_GETPGRP
! #	define HAS_GETPGRP
! #   endif
! #endif
! 
! #ifdef HAS_SETPGRP2
! #   ifndef HAS_SETPGRP
! #	define HAS_SETPGRP
! #   endif
  #endif
  
EOBAD
        } elsif (extract_from_file('perl.h',
                                   qr/Gack, you have one but not both of getpgrp2/)) {
            $bad = <<'EOBAD';
***************
*** 56,76 ****
  #define TAINT_PROPER(s)	if (tainting) taint_proper(no_security, s)
  #define TAINT_ENV()	if (tainting) taint_env()
  
! #if defined(HAS_GETPGRP2) && defined(HAS_SETPGRP2)
! #   define getpgrp getpgrp2
! #   define setpgrp setpgrp2
! #   ifndef HAS_GETPGRP
! #	define HAS_GETPGRP
! #   endif
! #   ifndef HAS_SETPGRP
! #	define HAS_SETPGRP
! #   endif
! #   ifndef USE_BSDPGRP
! #	define USE_BSDPGRP
! #   endif
! #else
! #   if defined(HAS_GETPGRP2) || defined(HAS_SETPGRP2)
! 	#include "Gack, you have one but not both of getpgrp2() and setpgrp2()."
! #   endif
  #endif
  
EOBAD
        } elsif (extract_from_file('perl.h',
                                   qr/^#ifdef USE_BSDPGRP$/)) {
            $bad = <<'EOBAD'
***************
*** 91,116 ****
  #define TAINT_PROPER(s)	if (tainting) taint_proper(no_security, s)
  #define TAINT_ENV()	if (tainting) taint_env()
  
! #ifdef USE_BSDPGRP
! #   ifdef HAS_GETPGRP
! #       define BSD_GETPGRP(pid) getpgrp((pid))
! #   endif
! #   ifdef HAS_SETPGRP
! #       define BSD_SETPGRP(pid, pgrp) setpgrp((pid), (pgrp))
! #   endif
! #else
! #   ifdef HAS_GETPGRP2
! #       define BSD_GETPGRP(pid) getpgrp2((pid))
! #       ifndef HAS_GETPGRP
! #    	    define HAS_GETPGRP
! #    	endif
! #   endif
! #   ifdef HAS_SETPGRP2
! #       define BSD_SETPGRP(pid, pgrp) setpgrp2((pid), (pgrp))
! #       ifndef HAS_SETPGRP
! #    	    define HAS_SETPGRP
! #    	endif
! #   endif
  #endif
  
  #ifndef _TYPES_		/* If types.h defines this it's easy. */
EOBAD
        }
        if ($bad) {
            apply_patch(<<"EOPATCH");
*** a/perl.h	2011-10-21 09:46:12.000000000 +0200
--- b/perl.h	2011-10-21 09:46:12.000000000 +0200
$bad--- 91,144 ----
  #define TAINT_PROPER(s)	if (tainting) taint_proper(no_security, s)
  #define TAINT_ENV()	if (tainting) taint_env()
  
! /* XXX All process group stuff is handled in pp_sys.c.  Should these 
!    defines move there?  If so, I could simplify this a lot. --AD  9/96.
! */
! /* Process group stuff changed from traditional BSD to POSIX.
!    perlfunc.pod documents the traditional BSD-style syntax, so we'll
!    try to preserve that, if possible.
! */
! #ifdef HAS_SETPGID
! #  define BSD_SETPGRP(pid, pgrp)	setpgid((pid), (pgrp))
! #else
! #  if defined(HAS_SETPGRP) && defined(USE_BSD_SETPGRP)
! #    define BSD_SETPGRP(pid, pgrp)	setpgrp((pid), (pgrp))
! #  else
! #    ifdef HAS_SETPGRP2  /* DG/UX */
! #      define BSD_SETPGRP(pid, pgrp)	setpgrp2((pid), (pgrp))
! #    endif
! #  endif
! #endif
! #if defined(BSD_SETPGRP) && !defined(HAS_SETPGRP)
! #  define HAS_SETPGRP  /* Well, effectively it does . . . */
! #endif
! 
! /* getpgid isn't POSIX, but at least Solaris and Linux have it, and it makes
!     our life easier :-) so we'll try it.
! */
! #ifdef HAS_GETPGID
! #  define BSD_GETPGRP(pid)		getpgid((pid))
! #else
! #  if defined(HAS_GETPGRP) && defined(USE_BSD_GETPGRP)
! #    define BSD_GETPGRP(pid)		getpgrp((pid))
! #  else
! #    ifdef HAS_GETPGRP2  /* DG/UX */
! #      define BSD_GETPGRP(pid)		getpgrp2((pid))
! #    endif
! #  endif
! #endif
! #if defined(BSD_GETPGRP) && !defined(HAS_GETPGRP)
! #  define HAS_GETPGRP  /* Well, effectively it does . . . */
! #endif
! 
! /* These are not exact synonyms, since setpgrp() and getpgrp() may 
!    have different behaviors, but perl.h used to define USE_BSDPGRP
!    (prior to 5.003_05) so some extension might depend on it.
! */
! #if defined(USE_BSD_SETPGRP) || defined(USE_BSD_GETPGRP)
! #  ifndef USE_BSDPGRP
! #    define USE_BSDPGRP
! #  endif
  #endif
  
  #ifndef _TYPES_		/* If types.h defines this it's easy. */
EOPATCH
        }
    }

    if ($major < 4 && $^O eq 'hpux'
        && extract_from_file('sv.c', qr/i = _filbuf\(/)) {
            apply_patch(<<'EOPATCH');
diff --git a/sv.c b/sv.c
index a1f1d60..0a806f1 100644
--- a/sv.c
+++ b/sv.c
@@ -2641,7 +2641,7 @@ I32 append;
 
 	FILE_cnt(fp) = cnt;		/* deregisterize cnt and ptr */
 	FILE_ptr(fp) = ptr;
-	i = _filbuf(fp);		/* get more characters */
+	i = __filbuf(fp);		/* get more characters */
 	cnt = FILE_cnt(fp);
 	ptr = FILE_ptr(fp);		/* reregisterize cnt and ptr */
 

EOPATCH
    }

    if ($major == 4 && extract_from_file('scope.c', qr/\(SV\*\)SSPOPINT/)) {
        # [PATCH] 5.004_04 +MAINT_TRIAL_1 broken when sizeof(int) != sizeof(void)
        # Fixes a bug introduced in 161b7d1635bc830b
        apply_commit('9002cb76ec83ef7f');
    }

    if ($major == 4 && extract_from_file('av.c', qr/AvARRAY\(av\) = 0;/)) {
        # Fixes a bug introduced in 1393e20655efb4bc
        apply_commit('e1c148c28bf3335b', 'av.c');
    }

    if ($major == 4) {
        my $rest = extract_from_file('perl.c', qr/delimcpy(.*)/);
        if (defined $rest and $rest !~ /,$/) {
            # delimcpy added in fc36a67e8855d031, perl.c refactored to use it.
            # bug introduced in 2a92aaa05aa1acbf, fixed in 8490252049bf42d3
            # code then moved to util.c in commit 491527d0220de34e
            apply_patch(<<'EOPATCH');
diff --git a/perl.c b/perl.c
index 4eb69e3..54bbb00 100644
--- a/perl.c
+++ b/perl.c
@@ -1735,7 +1735,7 @@ SV *sv;
 	    if (len < sizeof tokenbuf)
 		tokenbuf[len] = '\0';
 #else	/* ! (atarist || DOSISH) */
-	    s = delimcpy(tokenbuf, tokenbuf + sizeof tokenbuf, s, bufend
+	    s = delimcpy(tokenbuf, tokenbuf + sizeof tokenbuf, s, bufend,
 			 ':',
 			 &len);
 #endif	/* ! (atarist || DOSISH) */
EOPATCH
        }
    }

    if ($major == 4 && $^O eq 'linux') {
        # Whilst this is fixed properly in f0784f6a4c3e45e1 which provides the
        # Configure probe, it's easier to back out the problematic changes made
        # in these previous commits.

        # In maint-5.004, the simplest addition is to "correct" the file to
        # use the same pre-processor macros as blead had used. Whilst commit
        # 9b599b2a63d2324d (reverted below) is described as
        # [win32] merge change#887 from maintbranch
        # it uses __sun__ and __svr4__ instead of the __sun and __SVR4 of the
        # maint branch commit 6cdf74fe31f049dc

        edit_file('doio.c', sub {
                      my $code = shift;
                      $code =~ s{defined\(__sun\) && defined\(__SVR4\)}
                                {defined(__sun__) && defined(__svr4__)}g;
                      return $code;
                  });

        if (extract_from_file('doio.c',
                              qr!^/\* XXX REALLY need metaconfig test \*/$!)) {
            revert_commit('4682965a1447ea44', 'doio.c');
        }
        if (my $token = extract_from_file('doio.c',
                                          qr!^#if (defined\(__sun(?:__)?\)) && defined\(__svr4__\) /\* XXX Need metaconfig test \*/$!)) {
            my $patch = patch_from_commit('revert', '9b599b2a63d2324d', 'doio.c');
            $patch =~ s/defined\(__sun__\)/$token/g;
            apply_patch($patch);
        }
        if (extract_from_file('doio.c',
                              qr!^/\* linux \(and Solaris2\?\) uses :$!)) {
            revert_commit('8490252049bf42d3', 'doio.c');
        }
        if (extract_from_file('doio.c',
                              qr/^	    unsemds.buf = &semds;$/)) {
            revert_commit('8e591e46b4c6543e');
        }
        if (extract_from_file('doio.c',
                              qr!^#ifdef __linux__	/\* XXX Need metaconfig test \*/$!)) {
            # Reverts part of commit 3e3baf6d63945cb6
            apply_patch(<<'EOPATCH');
diff --git b/doio.c a/doio.c
index 62b7de9..0d57425 100644
--- b/doio.c
+++ a/doio.c
@@ -1333,9 +1331,6 @@ SV **sp;
     char *a;
     I32 id, n, cmd, infosize, getinfo;
     I32 ret = -1;
-#ifdef __linux__	/* XXX Need metaconfig test */
-    union semun unsemds;
-#endif
 
     id = SvIVx(*++mark);
     n = (optype == OP_SEMCTL) ? SvIVx(*++mark) : 0;
@@ -1364,29 +1359,11 @@ SV **sp;
 	    infosize = sizeof(struct semid_ds);
 	else if (cmd == GETALL || cmd == SETALL)
 	{
-#ifdef __linux__	/* XXX Need metaconfig test */
-/* linux uses :
-   int semctl (int semid, int semnun, int cmd, union semun arg)
-
-       union semun {
-            int val;
-            struct semid_ds *buf;
-            ushort *array;
-       };
-*/
-            union semun semds;
-	    if (semctl(id, 0, IPC_STAT, semds) == -1)
-#else
 	    struct semid_ds semds;
 	    if (semctl(id, 0, IPC_STAT, &semds) == -1)
-#endif
 		return -1;
 	    getinfo = (cmd == GETALL);
-#ifdef __linux__	/* XXX Need metaconfig test */
-	    infosize = semds.buf->sem_nsems * sizeof(short);
-#else
 	    infosize = semds.sem_nsems * sizeof(short);
-#endif
 		/* "short" is technically wrong but much more portable
 		   than guessing about u_?short(_t)? */
 	}
@@ -1429,12 +1406,7 @@ SV **sp;
 #endif
 #ifdef HAS_SEM
     case OP_SEMCTL:
-#ifdef __linux__	/* XXX Need metaconfig test */
-        unsemds.buf = (struct semid_ds *)a;
-	ret = semctl(id, n, cmd, unsemds);
-#else
 	ret = semctl(id, n, cmd, (struct semid_ds *)a);
-#endif
 	break;
 #endif
 #ifdef HAS_SHM
EOPATCH
        }
        # Incorrect prototype added as part of 8ac853655d9b7447, fixed as part
        # of commit dc45a647708b6c54, with at least one intermediate
        # modification. Correct prototype for gethostbyaddr has socklen_t
        # second. Linux has uint32_t first for getnetbyaddr.
        # Easiest just to remove, instead of attempting more complex patching.
        # Something similar may be needed on other platforms.
        edit_file('pp_sys.c', sub {
                      my $code = shift;
                      $code =~ s/^    struct hostent \*(?:PerlSock_)?gethostbyaddr\([^)]+\);$//m;
                      $code =~ s/^    struct netent \*getnetbyaddr\([^)]+\);$//m;
                      return $code;
                  });
    }

    if ($major < 5 && $^O eq 'aix'
        && !extract_from_file('pp_sys.c',
                              qr/defined\(HOST_NOT_FOUND\) && !defined\(h_errno\)/)) {
        # part of commit dc45a647708b6c54
        # Andy Dougherty's configuration patches (Config_63-01 up to 04).
        apply_patch(<<'EOPATCH')
diff --git a/pp_sys.c b/pp_sys.c
index c2fcb6f..efa39fb 100644
--- a/pp_sys.c
+++ b/pp_sys.c
@@ -54,7 +54,7 @@ extern "C" int syscall(unsigned long,...);
 #endif
 #endif
 
-#ifdef HOST_NOT_FOUND
+#if defined(HOST_NOT_FOUND) && !defined(h_errno)
 extern int h_errno;
 #endif
 
EOPATCH
    }

    if ($major == 5
        && `git rev-parse HEAD` eq "22c35a8c2392967a5ba6b5370695be464bd7012c\n") {
        # Commit 22c35a8c2392967a is significant,
        # "phase 1 of somewhat major rearrangement of PERL_OBJECT stuff"
        # but doesn't build due to 2 simple errors. blead in this broken state
        # was merged to the cfgperl branch, and then these were immediately
        # corrected there. cfgperl (with the fixes) was merged back to blead.
        # The resultant rather twisty maze of commits looks like this:

=begin comment

* | |   commit 137225782c183172f360c827424b9b9f8adbef0e
|\ \ \  Merge: 22c35a8 2a8ee23
| |/ /  Author: Gurusamy Sarathy <gsar@cpan.org>
| | |   Date:   Fri Oct 30 17:38:36 1998 +0000
| | |
| | |       integrate cfgperl tweaks into mainline
| | |
| | |       p4raw-id: //depot/perl@2144
| | |
| * | commit 2a8ee23279873759693fa83eca279355db2b665c
| | | Author: Jarkko Hietaniemi <jhi@iki.fi>
| | | Date:   Fri Oct 30 13:27:39 1998 +0000
| | |
| | |     There can be multiple yacc/bison errors.
| | |
| | |     p4raw-id: //depot/cfgperl@2143
| | |
| * | commit 93fb2ac393172fc3e2c14edb20b718309198abbc
| | | Author: Jarkko Hietaniemi <jhi@iki.fi>
| | | Date:   Fri Oct 30 13:18:43 1998 +0000
| | |
| | |     README.posix-bc update.
| | |
| | |     p4raw-id: //depot/cfgperl@2142
| | |
| * | commit 4ec43091e8e6657cb260b5e563df30aaa154effe
| | | Author: Jarkko Hietaniemi <jhi@iki.fi>
| | | Date:   Fri Oct 30 09:12:59 1998 +0000
| | |
| | |     #2133 fallout.
| | |
| | |     p4raw-id: //depot/cfgperl@2141
| | |
| * |   commit 134ca994cfefe0f613d43505a885e4fc2100b05c
| |\ \  Merge: 7093112 22c35a8
| |/ /  Author: Jarkko Hietaniemi <jhi@iki.fi>
|/| |   Date:   Fri Oct 30 08:43:18 1998 +0000
| | |
| | |       Integrate from mainperl.
| | |
| | |       p4raw-id: //depot/cfgperl@2140
| | |
* | | commit 22c35a8c2392967a5ba6b5370695be464bd7012c
| | | Author: Gurusamy Sarathy <gsar@cpan.org>
| | | Date:   Fri Oct 30 02:51:39 1998 +0000
| | |
| | |     phase 1 of somewhat major rearrangement of PERL_OBJECT stuff
| | |     (objpp.h is gone, embed.pl now does some of that); objXSUB.h
| | |     should soon be automated also; the global variables that
| | |     escaped the PL_foo conversion are now reined in; renamed
| | |     MAGIC in regcomp.h to REG_MAGIC to avoid collision with the
| | |     type of same name; duplicated lists of pp_things in various
| | |     places is now gone; result has only been tested on win32
| | |
| | |     p4raw-id: //depot/perl@2133

=end comment

=cut

        # and completely confuses git bisect (and at least me), causing it to
        # the bisect run to confidently return the wrong answer, an unrelated
        # commit on the cfgperl branch.

        apply_commit('4ec43091e8e6657c');
    }

    if ($major == 5
        && extract_from_file('pp_sys.c', qr/PERL_EFF_ACCESS_R_OK/)
        && !extract_from_file('pp_sys.c', qr/XXX Configure test needed for eaccess/)) {
        # Between 5ff3f7a4e03a6b10 and c955f1177b2e311d^
        # This is the meat of commit c955f1177b2e311d (without the other
        # indenting changes that would cause a conflict).
        # Without this 538 revisions won't build on (at least) Linux
        apply_patch(<<'EOPATCH');
diff --git a/pp_sys.c b/pp_sys.c
index d60c8dc..867dee4 100644
--- a/pp_sys.c
+++ b/pp_sys.c
@@ -198,9 +198,18 @@ static char zero_but_true[ZBTLEN + 1] = "0 but true";
 #   if defined(I_SYS_SECURITY)
 #       include <sys/security.h>
 #   endif
-#   define PERL_EFF_ACCESS_R_OK(p) (eaccess((p), R_OK, ACC_SELF))
-#   define PERL_EFF_ACCESS_W_OK(p) (eaccess((p), W_OK, ACC_SELF))
-#   define PERL_EFF_ACCESS_X_OK(p) (eaccess((p), X_OK, ACC_SELF))
+    /* XXX Configure test needed for eaccess */
+#   ifdef ACC_SELF
+        /* HP SecureWare */
+#       define PERL_EFF_ACCESS_R_OK(p) (eaccess((p), R_OK, ACC_SELF))
+#       define PERL_EFF_ACCESS_W_OK(p) (eaccess((p), W_OK, ACC_SELF))
+#       define PERL_EFF_ACCESS_X_OK(p) (eaccess((p), X_OK, ACC_SELF))
+#   else
+        /* SCO */
+#       define PERL_EFF_ACCESS_R_OK(p) (eaccess((p), R_OK))
+#       define PERL_EFF_ACCESS_W_OK(p) (eaccess((p), W_OK))
+#       define PERL_EFF_ACCESS_X_OK(p) (eaccess((p), X_OK))
+#   endif
 #endif
 
 #if !defined(PERL_EFF_ACCESS_R_OK) && defined(HAS_ACCESSX) && defined(ACC_SELF)
EOPATCH
    }

    if ($major == 5
        && extract_from_file('mg.c', qr/If we're still on top of the stack, pop us off/)
        && !extract_from_file('mg.c', qr/PL_savestack_ix -= popval/)) {
        # Fix up commit 455ece5e082708b1:
        # SSNEW() API for allocating memory on the savestack
        # Message-Id: <tqemtae338.fsf@puma.genscan.com>
        # Subject: [PATCH 5.005_51] (was: why SAVEDESTRUCTOR()...)
        apply_commit('3c8a44569607336e', 'mg.c');
    }

    if ($major == 5) {
        if (extract_from_file('doop.c', qr/croak\(no_modify\);/)
            && extract_from_file('doop.c', qr/croak\(PL_no_modify\);/)) {
            # Whilst the log suggests that this would only fix 5 commits, in
            # practice this area of history is a complete tarpit, and git bisect
            # gets very confused by the skips in the middle of the back and
            # forth merging between //depot/perl and //depot/cfgperl
            apply_commit('6393042b638dafd3');
        }

        # One error "fixed" with another:
        if (extract_from_file('pp_ctl.c',
                              qr/\Qstatic void *docatch_body _((void *o));\E/)) {
            apply_commit('5b51e982882955fe');
        }
        # Which is then fixed by this:
        if (extract_from_file('pp_ctl.c',
                              qr/\Qstatic void *docatch_body _((valist\E/)) {
            apply_commit('47aa779ee4c1a50e');
        }

        if (extract_from_file('thrdvar.h', qr/PERLVARI\(Tprotect/)
            && !extract_from_file('embedvar.h', qr/PL_protect/)) {
            # Commit 312caa8e97f1c7ee didn't update embedvar.h
            apply_commit('e0284a306d2de082', 'embedvar.h');
        }
    }

    if ($major == 5
        && extract_from_file('sv.c',
                             qr/PerlDir_close\(IoDIRP\((?:\(IO\*\))?sv\)\);/)
        && !(extract_from_file('toke.c',
                               qr/\QIoDIRP(FILTER_DATA(AvFILLp(PL_rsfp_filters))) = NULL\E/)
             || extract_from_file('toke.c',
                                  qr/\QIoDIRP(datasv) = (DIR*)NULL;\E/))) {
        # Commit 93578b34124e8a3b, //depot/perl@3298
        # close directory handles properly when localized,
        # tweaked slightly by commit 1236053a2c722e2b,
        # add test case for change#3298
        #
        # The fix is the last part of:
        #
        # various fixes for clean build and test on win32; configpm broken,
        # needed to open myconfig.SH rather than myconfig; sundry adjustments
        # to bytecode stuff; tweaks to DYNAMIC_ENV_FETCH code to make it
        # work under win32; getenv_sv() changed to getenv_len() since SVs
        # aren't visible in the lower echelons; remove bogus exports from
        # config.sym; PERL_OBJECT-ness for C++ exception support; null out
        # IoDIRP in filter_del() or sv_free() will attempt to close it
        #
        # The changed code is modified subsequently by commit e0c198038146b7a4
        apply_commit('a6c403648ecd5cc7', 'toke.c');
    }

    if ($major < 6 && $^O eq 'netbsd'
        && !extract_from_file('unixish.h',
                              qr/defined\(NSIG\).*defined\(__NetBSD__\)/)) {
        apply_patch(<<'EOPATCH')
diff --git a/unixish.h b/unixish.h
index 2a6cbcd..eab2de1 100644
--- a/unixish.h
+++ b/unixish.h
@@ -89,7 +89,7 @@
  */
 /* #define ALTERNATE_SHEBANG "#!" / **/
 
-#if !defined(NSIG) || defined(M_UNIX) || defined(M_XENIX)
+#if !defined(NSIG) || defined(M_UNIX) || defined(M_XENIX) || defined(__NetBSD__)
 # include <signal.h>
 #endif
 
EOPATCH
    }

    if ($major < 6 && extract_from_file('perl.h', qr/PL_uuemap\[\]/)) {
        # That [] needs to be [65]:
        apply_commit('7575fa06ca7baf15');
    }

    if ($major < 6 && $^O eq 'darwin'
            && !extract_from_file('perl.h', qr/ifdef I_FCNTL/)) {
        # This is part of commit 9a34ef1dede5fef4, but in a stable part of the
        # file:
        apply_patch(<<'EOPATCH')
diff --git a/perl.h b/perl.h
index 0d3f0b8333..19f6684894 100644
--- a/perl.h
+++ b/perl.h
@@ -310,6 +310,14 @@ register struct op *Perl_op asm(stringify(OP_IN_REGISTER));
 #   define BYTEORDER 0x1234
 #endif
 
+#ifdef I_FCNTL
+#  include <fcntl.h>
+#endif
+
+#ifdef I_SYS_FILE
+#  include <sys/file.h>
+#endif
+
 /* Overall memory policy? */
 #ifndef CONSERVATIVE
 #   define LIBERAL 1
EOPATCH
    }

    if ($major == 7 && $^O eq 'aix' && -f 'ext/List/Util/Util.xs'
        && extract_from_file('ext/List/Util/Util.xs', qr/PUSHBLOCK/)
        && !extract_from_file('makedef.pl', qr/^Perl_cxinc/)) {
        # Need this to get List::Utils 1.03 and later to compile.
        # 1.03 also expects to call Perl_pp_rand. Commit d3632a54487acc5f
        # fixes this (for the unthreaded case), but it's not until 1.05,
        # two days later, that this is fixed properly.
        apply_commit('cbb96eed3f175499');
    }

    if (($major >= 7 || $major <= 9) && $^O eq 'openbsd'
        && `uname -m` eq "sparc64\n"
        # added in 2000 by commit cb434fcc98ac25f5:
        && extract_from_file('regexec.c',
                             qr!/\* No need to save/restore up to this paren \*/!)
        # re-indented in 2006 by commit 95b2444054382532:
        && extract_from_file('regexec.c', qr/^\t\tCURCUR cc;$/)) {
        # Need to work around a bug in (at least) OpenBSD's 4.6's sparc64 #
        # compiler ["gcc (GCC) 3.3.5 (propolice)"]. Between commits
        # 3ec562b0bffb8b8b (2002) and 1a4fad37125bac3e^ (2005) the darling thing
        # fails to compile any code for the statement cc.oldcc = PL_regcc;
        #
        # If you refactor the code to "fix" that, or force the issue using set
        # in the debugger, the stack smashing detection code fires on return
        # from S_regmatch(). Turns out that the compiler doesn't allocate any
        # (or at least enough) space for cc.
        #
        # Restore the "uninitialised" value for cc before function exit, and the
        # stack smashing code is placated.  "Fix" 3ec562b0bffb8b8b (which
        # changes the size of auto variables used elsewhere in S_regmatch), and
        # the crash is visible back to bc517b45fdfb539b (which also changes
        # buffer sizes). "Unfix" 1a4fad37125bac3e and the crash is visible until
        # 5b47454deb66294b.  Problem goes away if you compile with -O, or hack
        # the code as below.
        #
        # Hence this turns out to be a bug in (old) gcc. Not a security bug we
        # still need to fix.
        apply_patch(<<'EOPATCH');
diff --git a/regexec.c b/regexec.c
index 900b491..6251a0b 100644
--- a/regexec.c
+++ b/regexec.c
@@ -2958,7 +2958,11 @@ S_regmatch(pTHX_ regnode *prog)
 				I,I
  *******************************************************************/
 	case CURLYX: {
-		CURCUR cc;
+	    union {
+		CURCUR hack_cc;
+		char hack_buff[sizeof(CURCUR) + 1];
+	    } hack;
+#define cc hack.hack_cc
 		CHECKPOINT cp = PL_savestack_ix;
 		/* No need to save/restore up to this paren */
 		I32 parenfloor = scan->flags;
@@ -2983,6 +2987,7 @@ S_regmatch(pTHX_ regnode *prog)
 		n = regmatch(PREVOPER(next));	/* start on the WHILEM */
 		regcpblow(cp);
 		PL_regcc = cc.oldcc;
+#undef cc
 		saySAME(n);
 	    }
 	    /* NOT REACHED */
EOPATCH
}

    if ($major < 8 && !extract_from_file('perl.h', qr/\bshort htovs\b/)) {
        # This is part of commit c623ac675720b314
        apply_patch(<<'EOPATCH');
diff --git a/perl.h b/perl.h
index 023b90b7ea..59a21faecd 100644
--- a/perl.h
+++ b/perl.h
@@ -2279,4 +2279,8 @@ struct ptr_tbl {
 # endif
 	/* otherwise default to functions in util.c */
+short htovs(short n);
+short vtohs(short n);
+long htovl(long n);
+long vtohl(long n);
 #endif
 
EOPATCH
    }

    if ($major < 8 && !extract_from_file('perl.h', qr/include <unistd\.h>/)) {
        # This is part of commit 3f270f98f9305540, applied at a slightly
        # different location in perl.h, where the context is stable back to
        # 5.000
        apply_patch(<<'EOPATCH');
diff --git a/perl.h b/perl.h
index 9418b52..b8b1a7c 100644
--- a/perl.h
+++ b/perl.h
@@ -496,6 +496,10 @@ register struct op *Perl_op asm(stringify(OP_IN_REGISTER));
 #   include <sys/param.h>
 #endif
 
+/* If this causes problems, set i_unistd=undef in the hint file.  */
+#ifdef I_UNISTD
+#   include <unistd.h>
+#endif
 
 /* Use all the "standard" definitions? */
 #if defined(STANDARD_C) && defined(I_STDLIB)
EOPATCH
    }

    if ($major < 10) {
        # This is commit 731e259481f36b35, but adapted to remove all the
        # variations of guards around the inclusion of <signal.h>
        # Whilst we only hit this as a problem on arm64 macOS (so far), because
        # it insists on prototypes for everything, I'm assuming that doing this
        # everywhere and unconditionally might solve similar problems on other
        # platforms. Certainly, it *ought* to be safe to include a C89 header
        # these days.
        for my $file (qw(doop.c mg.c mpeix/mpeixish.h plan9/plan9ish.h unixish.h util.c)) {
            next
                unless -f $file;
            edit_file($file, sub {
                          my $code = shift;
                          $code =~ s{
                                        \n
                                        \#if \s+ [^\n]+
                                        \n
                                        \# \s* include \s+ <signal\.h>
                                        \n
                                        \#endif
                                        \n
                                }
                                    {\n#include <signal.h>\n}x;
                          return $code;
                      });
        }
    }

    if ($major == 15) {
        # This affects a small range of commits around July 2011, but build
        # failures here get in the way of bisecting other problems:

        my $line = extract_from_file('embed.fnc', qr/^X?pR\t\|I32\t\|was_lvalue_sub$/);
        if ($line) {
            # Need to export Perl_was_lvalue_sub:
            apply_commit('7b70e8177801df4e')
                unless $line =~ /X/;

            # It needs to be 'ApR' not 'XpR', to be visible to List::Util
            # (arm64 macOS treats the missing prototypes as errors)
            apply_commit('c73b0699db4d0b8b');
        }
    }
}

sub patch_ext {
    #print "ZZZ: patch_ext\n";
    my ($major, $unfixable_db_file, $options) = @_;
    if (-f 'ext/POSIX/Makefile.PL'
        && extract_from_file('ext/POSIX/Makefile.PL',
                             qr/Explicitly avoid including/)) {
        # commit 6695a346c41138df, which effectively reverts 170888cff5e2ffb7

        # PERL5LIB is populated by make_ext.pl with paths to the modules we need
        # to run, don't override this with "../../lib" since that may not have
        # been populated yet in a parallel build.
        apply_commit('6695a346c41138df');
    }

    if (-f 'ext/Hash/Util/Makefile.PL'
        && extract_from_file('ext/Hash/Util/Makefile.PL',
                             qr/\bDIR\b.*'FieldHash'/)) {
        # ext/Hash/Util/Makefile.PL should not recurse to FieldHash's Makefile.PL
        # *nix, VMS and Win32 all know how to (and have to) call the latter directly.
        # As is, targets in ext/Hash/Util/FieldHash get called twice, which may result
        # in race conditions, and certainly messes up make clean; make distclean;
        apply_commit('550428fe486b1888');
    }

    if ($major < 8 && $^O eq 'darwin' && !-f 'ext/DynaLoader/dl_dyld.xs') {
        checkout_file({
            file => 'ext/DynaLoader/dl_dyld.xs',
            commit => 'f556e5b971932902',
            options => $options,
        });
        apply_patch(<<'EOPATCH');
diff -u a/ext/DynaLoader/dl_dyld.xs~ a/ext/DynaLoader/dl_dyld.xs
--- a/ext/DynaLoader/dl_dyld.xs	2011-10-11 21:41:27.000000000 +0100
+++ b/ext/DynaLoader/dl_dyld.xs	2011-10-11 21:42:20.000000000 +0100
@@ -41,6 +41,35 @@
 #include "perl.h"
 #include "XSUB.h"
 
+#ifndef pTHX
+#  define pTHX		void
+#  define pTHX_
+#endif
+#ifndef aTHX
+#  define aTHX
+#  define aTHX_
+#endif
+#ifndef dTHX
+#  define dTHXa(a)	extern int Perl___notused(void)
+#  define dTHX		extern int Perl___notused(void)
+#endif
+
+#ifndef Perl_form_nocontext
+#  define Perl_form_nocontext form
+#endif
+
+#ifndef Perl_warn_nocontext
+#  define Perl_warn_nocontext warn
+#endif
+
+#ifndef PTR2IV
+#  define PTR2IV(p)	(IV)(p)
+#endif
+
+#ifndef get_av
+#  define get_av perl_get_av
+#endif
+
 #define DL_LOADONCEONLY
 
 #include "dlutils.c"	/* SaveError() etc	*/
@@ -104,7 +145,7 @@
     dl_last_error = savepv(error);
 }
 
-static char *dlopen(char *path, int mode /* mode is ignored */)
+static char *dlopen(char *path)
 {
     int dyld_result;
     NSObjectFileImage ofile;
@@ -161,13 +202,11 @@
 dl_load_file(filename, flags=0)
     char *	filename
     int		flags
-    PREINIT:
-    int mode = 1;
     CODE:
     DLDEBUG(1,PerlIO_printf(Perl_debug_log, "dl_load_file(%s,%x):\n", filename,flags));
     if (flags & 0x01)
-	Perl_warn(aTHX_ "Can't make loaded symbols global on this platform while loading %s",filename);
-    RETVAL = dlopen(filename, mode) ;
+	Perl_warn_nocontext("Can't make loaded symbols global on this platform while loading %s",filename);
+    RETVAL = dlopen(filename);
     DLDEBUG(2,PerlIO_printf(Perl_debug_log, " libref=%x\n", RETVAL));
     ST(0) = sv_newmortal() ;
     if (RETVAL == NULL)
EOPATCH
        if ($major < 4 && !extract_from_file('util.c', qr/^form/m)) {
            apply_patch(<<'EOPATCH');
diff -u a/ext/DynaLoader/dl_dyld.xs~ a/ext/DynaLoader/dl_dyld.xs
--- a/ext/DynaLoader/dl_dyld.xs	2011-10-11 21:56:25.000000000 +0100
+++ b/ext/DynaLoader/dl_dyld.xs	2011-10-11 22:00:00.000000000 +0100
@@ -60,6 +60,18 @@
 #  define get_av perl_get_av
 #endif
 
+static char *
+form(char *pat, ...)
+{
+    char *retval;
+    va_list args;
+    va_start(args, pat);
+    vasprintf(&retval, pat, &args);
+    va_end(args);
+    SAVEFREEPV(retval);
+    return retval;
+}
+
 #define DL_LOADONCEONLY
 
 #include "dlutils.c"	/* SaveError() etc	*/
EOPATCH
        }
    }

    if ($major < 10) {
        if ($unfixable_db_file) {
            # Nothing we can do.
        } else {
            if (!extract_from_file('ext/DB_File/DB_File.xs',
                                   qr/^#ifdef AT_LEAST_DB_4_1$/)) {
                # This line is changed by commit 3245f0580c13b3ab
                my $line = extract_from_file('ext/DB_File/DB_File.xs',
                                             qr/^(        status = \(?RETVAL->dbp->open\)?\(RETVAL->dbp, name, NULL, RETVAL->type, $)/);
                apply_patch(<<"EOPATCH");
diff --git a/ext/DB_File/DB_File.xs b/ext/DB_File/DB_File.xs
index 489ba96..fba8ded 100644
--- a/ext/DB_File/DB_File.xs
+++ b/ext/DB_File/DB_File.xs
\@\@ -183,4 +187,8 \@\@
 #endif
 
+#if DB_VERSION_MAJOR > 4 || (DB_VERSION_MAJOR == 4 && DB_VERSION_MINOR >= 1)
+#    define AT_LEAST_DB_4_1
+#endif
+
 /* map version 2 features & constants onto their version 1 equivalent */
 
\@\@ -1334,7 +1419,12 \@\@ SV *   sv ;
 #endif
 
+#ifdef AT_LEAST_DB_4_1
+        status = (RETVAL->dbp->open)(RETVAL->dbp, NULL, name, NULL, RETVAL->type, 
+	    			Flags, mode) ; 
+#else
 $line
 	    			Flags, mode) ; 
+#endif
 	/* printf("open returned %d %s\\n", status, db_strerror(status)) ; */
 
EOPATCH
            }

            if (!extract_from_file('ext/DB_File/DB_File.xs',
                                   qr/\bextern void __getBerkeleyDBInfo\b/)) {
                # A prototype for __getBerkeleyDBInfo();
                apply_commit('b92372bcedd4cbc4');
            }
        }
    }

    if ($major < 10 and -f 'ext/IPC/SysV/SysV.xs') {
        edit_file('ext/IPC/SysV/SysV.xs', sub {
                      my $xs = shift;
                      my $fixed = <<'EOFIX';

#include <sys/types.h>
#if defined(HAS_MSG) || defined(HAS_SEM) || defined(HAS_SHM)
#ifndef HAS_SEM
#   include <sys/ipc.h>
#endif
#   ifdef HAS_MSG
#       include <sys/msg.h>
#   endif
#   ifdef HAS_SHM
#       if defined(PERL_SCO) || defined(PERL_ISC)
#           include <sys/sysmacros.h>	/* SHMLBA */
#       endif
#      include <sys/shm.h>
#      ifndef HAS_SHMAT_PROTOTYPE
           extern Shmat_t shmat (int, char *, int);
#      endif
#      if defined(HAS_SYSCONF) && defined(_SC_PAGESIZE)
#          undef  SHMLBA /* not static: determined at boot time */
#          define SHMLBA sysconf(_SC_PAGESIZE)
#      elif defined(HAS_GETPAGESIZE)
#          undef  SHMLBA /* not static: determined at boot time */
#          define SHMLBA getpagesize()
#      endif
#   endif
#endif
EOFIX
                      $xs =~ s!
#include <sys/types\.h>
.*
(#ifdef newCONSTSUB|/\* Required)!$fixed$1!ms;
                      return $xs;
                  });
    }

    if ($major < 10 and -f 'ext/Digest/MD5/MD5.xs') {
        require Digest::MD5;
        my ($was, $now);
        # The edit to the XS is commit 9ee8e69ab2318ba3, but the testcase fixup
        # needs to work for several earlier commits.
        edit_file('ext/Digest/MD5/MD5.xs', sub {
                      my $xs = shift;
                      $was = Digest::MD5::md5_hex($xs);
                      $xs =~ s{\Q#if PATCHLEVEL <= 4 && !defined(PL_dowarn)}
                              {#if PERL_VERSION <= 4 && !defined(PL_dowarn)};
                      $now = Digest::MD5::md5_hex($xs);
                      return $xs;
                  });

        edit_file('ext/Digest/MD5/t/files.t', sub {
                      my $testcase = shift;
                      $testcase =~ s/$was/$now/g;
                      return $testcase;
                  })
            if $was ne $now;
    }

    if ($major >= 10 && $major < 20
            && !extract_from_file('ext/SDBM_File/Makefile.PL', qr/MY::subdir_x/)) {
        # Parallel make fix for SDBM_File
        # Technically this is needed for pre v5.10.0, but we don't attempt
        # parallel makes on earlier versions because it's unreliable due to
        # other bugs.
        # So far, only AIX make has come acropper on this bug.
        apply_commit('4d106cc5d8fd328d', 'ext/SDBM_File/Makefile.PL');
    }

    if (-f 'ext/Errno/Errno_pm.PL') {
        if ($major < 22 && !extract_from_file('ext/Errno/Errno_pm.PL',
                                              qr/RT#123784/)) {
            my $gcc_major = extract_from_file('config.sh',
                                              qr/^gccversion='([0-9]+)\./,
                                              0);
            if ($gcc_major >= 5) {
                # This is the fix of commit 816b056ffb99ae54, but implemented in
                # a way that should work back to the earliest versions of Errno:
                edit_file('ext/Errno/Errno_pm.PL', sub {
                              my $code = shift;
                              $code =~ s/( \$Config\{cppflags\})/$1 -P/g;
                              return $code;
                          });
            }
        }
        if ($major < 8 && !extract_from_file('ext/Errno/Errno_pm.PL',
                                             qr/With the -dM option, gcc/)) {
            # This is the fix of commit 9ae2e8df64ee1443 re-ordered slightly so
            # that it should work back to the earliest versions of Errno:
            apply_patch(<<'EOPATCH');
diff --git a/ext/Errno/Errno_pm.PL b/ext/Errno/Errno_pm.PL
index b669790314..c00d6c1a86 100644
--- a/ext/Errno/Errno_pm.PL
+++ b/ext/Errno/Errno_pm.PL
@@ -30,6 +30,12 @@ sub process_file {
             warn "Cannot open '$file'";
             return;
 	}     
+    } elsif ($Config{gccversion} ne '') {
+	# With the -dM option, gcc outputs every #define it finds
+	unless(open(FH,"$Config{cc} -E -dM $file |")) {
+            warn "Cannot open '$file'";
+            return;
+	}
     } else {
 	unless(open(FH,"< $file")) {
             warn "Cannot open '$file'";
@@ -45,8 +51,12 @@ sub process_file {
 
 sub get_files {
     my %file = ();
-    # VMS keeps its include files in system libraries (well, except for Gcc)
-    if ($^O eq 'VMS') {
+    if ($^O eq 'linux') {
+	# Some Linuxes have weird errno.hs which generate
+	# no #file or #line directives
+	$file{'/usr/include/errno.h'} = 1;
+    } elsif ($^O eq 'VMS') {
+	# VMS keeps its include files in system libraries (well, except for Gcc)
 	if ($Config{vms_cc_type} eq 'decc') {
 	    $file{'Sys$Library:DECC$RTLDEF.TLB'} = 1;
 	} elsif ($Config{vms_cc_type} eq 'vaxc') {
EOPATCH
        }
    }
}

sub patch_t {
    #print "ZZZ: patch_t\n";
    my $aggressive_apple_security = shift;
    if ($^O eq 'darwin') {
        # This has # $x = `$^X -le "print 'hi there'"`;
        # and it needs to pass for the automated validation self-test:
        edit_file('t/base/term.t', sub {
                      my $code = shift;
                      $code =~ s/`(\$\^X )/`$aggressive_apple_security$1/;
                      return $code;
                  });
    }
}

sub apply_fixups {
    #print "ZZZ: apply_fixups\n";
    my $fixups = shift;
    return unless $fixups;
    foreach my $file (@$fixups) {
        my $fh = open_or_die($file);
        my $line = <$fh>;
        close_or_die($fh);
        if ($line =~ /^#!perl\b/) {
            system $^X, $file
                and die_255("$^X $file failed: \$!=$!, \$?=$?");
        } elsif ($line =~ /^#!(\/\S+)/) {
            system $file
                and die_255("$file failed: \$!=$!, \$?=$?");
        } else {
            if (my ($target, $action, $pattern)
                = $line =~ m#^(\S+) ([=!])~ /(.*)/#) {
                if (length $pattern) {
                    next unless -f $target;
                    if ($action eq '=') {
                        next unless extract_from_file($target, $pattern);
                    } else {
                        next if extract_from_file($target, $pattern);
                    }
                } else {
                    # Avoid the special case meaning of the empty pattern,
                    # and instead use this to simply test for the file being
                    # present or absent
                    if ($action eq '=') {
                        next unless -f $target;
                    } else {
                        next if -f $target;
                    }
                }
            }
            system_or_die("patch -p1 <$file");
        }
    }
}

1;
