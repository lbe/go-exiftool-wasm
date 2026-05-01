package inc::latest;
use strict;
use vars qw($VERSION);
$VERSION = '0.39_01';
$VERSION = eval $VERSION;

use Carp;
use File::Basename ();
use File::Spec     ();
use File::Path     ();
use IO::File       ();
use File::Copy     ();

my @loaded_modules;
sub loaded_modules { @loaded_modules }

sub import {
    my ( $package, $mod, @args ) = @_;
    return unless ( defined $mod );

    my $private_path = 'inc/latest/private.pm';
    if ( -e $private_path ) {
        require $private_path;
        splice( @_, 0, 1, 'inc::latest::private' );
        goto \&inc::latest::private::import;
    }

    push( @loaded_modules, $mod );
    require inc::latest::private;
    goto \&inc::latest::private::_load_module;
}

sub write {
    my $package = shift;
    my ( $where, @preload ) = @_;

    warn "should really be writing in inc/" unless $where =~ /inc$/;

    File::Path::mkpath($where);
    my $fh = IO::File->new( File::Spec->catfile( $where, 'latest.pm' ), "w" );
    print {$fh} "# This stub created by inc::latest $VERSION\n";
    print {$fh} <<'HERE';
package inc::latest;
use strict;
use vars '@ISA';
require inc::latest::private;
@ISA = qw/inc::latest::private/;
HERE
    if (@preload) {
        print {$fh} "\npackage inc::latest::preload;\n";
        for my $mod (@preload) {
            print {$fh} "inc::latest->import('$mod');\n";
        }
    }
    print {$fh} "\n1;\n";
    close $fh;

    require inc::latest::private;
    File::Path::mkpath( File::Spec->catdir( $where, 'latest' ) );
    my $from = $INC{'inc/latest/private.pm'};
    my $to = File::Spec->catfile( $where, 'latest', 'private.pm' );
    File::Copy::copy( $from, $to ) or die "Couldn't copy '$from' to '$to': $!";

    return 1;
}

sub bundle_module {
    my ( $package, $module, $where ) = @_;

    ( my $dist = $module ) =~ s{::}{-}g;
    my $inc_lib = File::Spec->catdir( $where, "inc_$dist" );
    File::Path::mkpath $inc_lib;

    require ExtUtils::Installed;
    my $inst = ExtUtils::Installed->new( extra_libs => [@INC] );
    my $packlist = $inst->packlist($module) or die "Couldn't find packlist";
    my @files = grep { /\.pm$/ } keys %$packlist;

    my $mod_path = quotemeta $package->_mod2path($module);
    my ($prefix) = grep { /$mod_path$/ } @files;
    $prefix =~ s{$mod_path$}{};

    for my $from (@files) {
        next unless $from =~ /\.pm$/;
        ( my $mod_path = $from ) =~ s{^\Q$prefix\E}{};
        my $to = File::Spec->catfile( $inc_lib, $mod_path );
        File::Path::mkpath( File::Basename::dirname($to) );
        File::Copy::copy( $from, $to )
          or die "Couldn't copy '$from' to '$to': $!";
    }
    return 1;
}

sub _mod2path {
    my ( $self, $mod ) = @_;
    my @parts = split /::/, $mod;
    $parts[-1] .= '.pm';
    return $parts[0] if @parts == 1;
    return File::Spec->catfile(@parts);
}

1;


