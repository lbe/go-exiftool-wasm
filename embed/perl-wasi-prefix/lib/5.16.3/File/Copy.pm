
package File::Copy;

use 5.006;
use strict;
use warnings;
no warnings 'newline';
use File::Spec;
use Config;
my $Scalar_Util_loaded = eval q{ require Scalar::Util; require overload; 1 };
our ( @ISA, @EXPORT, @EXPORT_OK, $VERSION, $Too_Big, $Syscopy_is_copy );
sub copy;
sub syscopy;
sub cp;
sub mv;

$VERSION = '2.23';

require Exporter;
@ISA       = qw(Exporter);
@EXPORT    = qw(copy move);
@EXPORT_OK = qw(cp mv);

$Too_Big = 1024 * 1024 * 2;

sub croak {
    require Carp;
    goto &Carp::croak;
}

sub carp {
    require Carp;
    goto &Carp::carp;
}

my $use_vms_feature = 0;

BEGIN {
    if ( $^O eq 'VMS' ) {
        if ( eval { local $SIG{__DIE__}; require VMS::Feature; } ) {
            $use_vms_feature = 1;
        }
    }
}

sub _vms_unix_rpt {
    my $unix_rpt;
    if ($use_vms_feature) {
        $unix_rpt = VMS::Feature::current("filename_unix_report");
    }
    else {
        my $env_unix_rpt = $ENV{'DECC$FILENAME_UNIX_REPORT'} || '';
        $unix_rpt = $env_unix_rpt =~ /^[ET1]/i;
    }
    return $unix_rpt;
}

sub _vms_efs {
    my $efs;
    if ($use_vms_feature) {
        $efs = VMS::Feature::current("efs_charset");
    }
    else {
        my $env_efs = $ENV{'DECC$EFS_CHARSET'} || '';
        $efs = $env_efs =~ /^[ET1]/i;
    }
    return $efs;
}

sub _catname {
    my ( $from, $to ) = @_;
    if ( not defined &basename ) {
        require File::Basename;
        import File::Basename 'basename';
    }

    return File::Spec->catfile( $to, basename($from) );
}

sub _eq {
    my ( $from, $to ) = map {
             $Scalar_Util_loaded
          && Scalar::Util::blessed($_)
          && overload::Method( $_, q{""} )
          ? "$_"
          : $_
    } (@_);
    return '' if ( ( ref $from ) xor( ref $to ) );
    return $from == $to if ref $from;
    return $from eq $to;
}

sub copy {
    croak("Usage: copy(FROM, TO [, BUFFERSIZE]) ")
      unless ( @_ == 2 || @_ == 3 );

    my $from = shift;
    my $to   = shift;

    my $size;
    if (@_) {
        $size = shift(@_) + 0;
        croak("Bad buffer size for copy: $size\n") unless ( $size > 0 );
    }

    my $from_a_handle = (
        ref($from)
        ? ( ref($from) eq 'GLOB'
              || UNIVERSAL::isa( $from, 'GLOB' )
              || UNIVERSAL::isa( $from, 'IO::Handle' ) )
        : ( ref( \$from ) eq 'GLOB' )
    );
    my $to_a_handle = (
        ref($to)
        ? ( ref($to) eq 'GLOB'
              || UNIVERSAL::isa( $to, 'GLOB' )
              || UNIVERSAL::isa( $to, 'IO::Handle' ) )
        : ( ref( \$to ) eq 'GLOB' )
    );

    if ( _eq( $from, $to ) )
    { carp("'$from' and '$to' are identical (not copied)");
        return 1;
    }

    if ( ( ( $Config{d_symlink} && $Config{d_readlink} ) || $Config{d_link} )
        && !( $^O eq 'MSWin32' || $^O eq 'os2' ) )
    {
        my @fs = stat($from);
        if (@fs) {
            my @ts = stat($to);
            if ( @ts && $fs[0] == $ts[0] && $fs[1] == $ts[1] && !-p $from ) {
                carp("'$from' and '$to' are identical (not copied)");
                return 0;
            }
        }
    }

    if ( !$from_a_handle && !$to_a_handle && -d $to && !-d $from ) {
        $to = _catname( $from, $to );
    }

    if (   defined &syscopy
        && !$Syscopy_is_copy
        && !$to_a_handle
        && !( $from_a_handle && $^O eq 'os2' ) &&
        !( $from_a_handle    && $^O eq 'mpeix' ) &&
        !( $from_a_handle    && $^O eq 'MSWin32' )
        && !( $from_a_handle && $^O eq 'NetWare' ) )
    {
        my $copy_to = $to;

        if ( $^O eq 'VMS' && -e $from ) {

            if ( !-d $to && !-d $from ) {

                my $vms_efs   = _vms_efs();
                my $unix_rpt  = _vms_unix_rpt();
                my $unix_mode = 0;
                my $from_unix = 0;
                $from_unix = 1 if ( $from =~ /^\.\.?$/ );
                my $from_vms = 0;
                $from_vms = 1 if ( $from =~ m#[\[<\]]# );

                if ( $from_vms == $from_unix ) {
                    $unix_mode = $unix_rpt;
                }
                else {
                    $unix_mode = $from_unix;
                }

                if ($vms_efs) {
                    $copy_to = $to;
                }
                else {
                    $copy_to = VMS::Filespec::vmsify($to);
                }
                my ( $vol, $dirs, $file ) = File::Spec->splitpath($copy_to);
                $file = $file . '.'
                  unless ( ( $file =~ /(?<!\^)\./ ) || $unix_rpt );
                $copy_to = File::Spec->catpath( $vol, $dirs, $file );

                1 while unlink $copy_to;
            }
        }

        return syscopy( $from, $copy_to ) || 0;
    }

    my $closefrom = 0;
    my $closeto   = 0;
    my ( $status, $r, $buf );
    local ($\) = '';

    my $from_h;
    if ($from_a_handle) {
        $from_h = $from;
    }
    else {
        open $from_h, "<", $from or goto fail_open1;
        binmode $from_h or die "($!,$^E)";
        $closefrom = 1;
    }

    unless ( defined $size ) {
        $size = tied(*$from_h) ? 0 : -s $from_h || 0;
        $size = 1024     if ( $size < 512 );
        $size = $Too_Big if ( $size > $Too_Big );
    }

    my $to_h;
    if ($to_a_handle) {
        $to_h = $to;
    }
    else {
        $to_h = \do { local *FH };
        open $to_h, ">", $to or goto fail_open2;
        binmode $to_h or die "($!,$^E)";
        $closeto = 1;
    }

    $! = 0;
    for ( ; ; ) {
        my ( $r, $w, $t );
        defined( $r = sysread( $from_h, $buf, $size ) )
          or goto fail_inner;
        last unless $r;
        for ( $w = 0 ; $w < $r ; $w += $t ) {
            $t = syswrite( $to_h, $buf, $r - $w, $w )
              or goto fail_inner;
        }
    }

    close($to_h)   || goto fail_open2 if $closeto;
    close($from_h) || goto fail_open1 if $closefrom;

    return 1;

  fail_inner:
    if ($closeto) {
        $status = $!;
        $!      = 0;
        close $to_h;
        $! = $status unless $!;
    }
  fail_open2:
    if ($closefrom) {
        $status = $!;
        $!      = 0;
        close $from_h;
        $! = $status unless $!;
    }
  fail_open1:
    return 0;
}

sub cp {
    my ( $from, $to ) = @_;
    my (@fromstat) = stat $from;
    my (@tostat)   = stat $to;
    my $perm;

    return 0 unless copy(@_) and @fromstat;

    if (@tostat) {
        $perm = $tostat[2];
    }
    else {
        $perm = $fromstat[2] & ~( umask || 0 );
        @tostat = stat $to;
    }
    $perm &= 07777;
    if ( $perm & 06000 ) {
        croak("Unable to check setuid/setgid permissions for $to: $!")
          unless @tostat;

        if (    $perm & 04000
            and $fromstat[4] != $tostat[4] )
        { $perm &= ~06000;
        }

        if ( $perm & 02000 && $> != 0 ) { my $ok = $fromstat[5] == $tostat[5];
            if ($ok) { $ok = grep { $_ == $fromstat[5] } split /\s+/, $);
            }
            $perm &= ~06000 unless $ok;
        }
    }
    return 0 unless @tostat;
    return 1 if $perm == ( $tostat[2] & 07777 );
    return eval { chmod $perm, $to; } ? 1 : 0;
}

sub _move {
    croak("Usage: move(FROM, TO) ") unless @_ == 3;

    my ( $from, $to, $fallback ) = @_;

    my ( $fromsz, $tosz1, $tomt1, $tosz2, $tomt2, $sts, $ossts );

    if ( -d $to && !-d $from ) {
        $to = _catname( $from, $to );
    }

    ( $tosz1, $tomt1 ) = ( stat($to) )[ 7, 9 ];
    $fromsz = -s $from;
    if ( $^O eq 'os2' and defined $tosz1 and defined $fromsz ) {
        unlink $to;
    }

    my $rename_to = $to;
    if ( -$^O eq 'VMS' && -e $from ) {

        if ( !-d $to && !-d $from ) {

            my $vms_efs   = _vms_efs();
            my $unix_rpt  = _vms_unix_rpt();
            my $unix_mode = 0;
            my $from_unix = 0;
            $from_unix = 1 if ( $from =~ /^\.\.?$/ );
            my $from_vms = 0;
            $from_vms = 1 if ( $from =~ m#[\[<\]]# );

            if ( $from_vms == $from_unix ) {
                $unix_mode = $unix_rpt;
            }
            else {
                $unix_mode = $from_unix;
            }

            if ($vms_efs) {
                $rename_to = $to;
            }
            else {
                $rename_to = VMS::Filespec::vmsify($to);
            }
            my ( $vol, $dirs, $file ) = File::Spec->splitpath($rename_to);
            $file = $file . '.'
              unless ( ( $file =~ /(?<!\^)\./ ) || $unix_rpt );
            $rename_to = File::Spec->catpath( $vol, $dirs, $file );

            1 while unlink $rename_to;
        }
    }

    return 1 if rename $from, $rename_to;

    return 1
      if defined($fromsz)
      && !-e $from
      && ( ( $tosz2, $tomt2 ) = ( stat($to) )[ 7, 9 ] )
      && ( ( !defined $tosz1 )
        || ( $tosz1 != $tosz2 or $tomt1 != $tomt2 ) )
      && $tosz2 == $fromsz;

    ( $tosz1, $tomt1 ) = ( stat($to) )[ 7, 9 ];

    {
        local $@;
        eval {
            local $SIG{__DIE__};
            $fallback->( $from, $to ) or die;
            my ( $atime, $mtime ) = ( stat($from) )[ 8, 9 ];
            utime( $atime, $mtime, $to );
            unlink($from) or die;
        };
        return 1 unless $@;
    }
    ( $sts, $ossts ) = ( $! + 0, $^E + 0 );

    ( $tosz2, $tomt2 ) = ( ( stat($to) )[ 7, 9 ], 0, 0 ) if defined $tomt1;
    unlink($to) if !defined($tomt1) or $tomt1 != $tomt2 or $tosz1 != $tosz2;
    ( $!, $^E ) = ( $sts, $ossts );
    return 0;
}

sub move { _move( @_, \&copy ); }
sub mv   { _move( @_, \&cp ); }

unless ( defined &syscopy ) {
    if ( $^O eq 'VMS' ) {
        *syscopy = \&rmscopy;
    }
    elsif ( $^O eq 'mpeix' ) {
        *syscopy = sub {
            return 0 unless @_ == 2;
            return system( '/bin/cp', '-f', $_[0], $_[1] ) == 0;
        };
    }
    elsif ( $^O eq 'MSWin32' && defined &DynaLoader::boot_DynaLoader ) {
        *syscopy = sub {
            return 0 unless @_ == 2;
            return Win32::CopyFile( @_, 1 );
        };
    }
    else {
        $Syscopy_is_copy = 1;
        *syscopy         = \&copy;
    }
}

1;

__END__


