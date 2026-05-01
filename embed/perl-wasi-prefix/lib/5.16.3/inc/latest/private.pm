package inc::latest::private;
use strict;
use vars qw($VERSION);
$VERSION = '0.39_01';
$VERSION = eval $VERSION;

use File::Spec;
use IO::File;

sub import {
    my ( $package, $mod, @args ) = @_;
    my $file = $package->_mod2path($mod);

    if ( $INC{$file} ) {
        goto \&_load_module;
    }

    my ( $bundled, $bundled_dir ) = $package->_search_bundled($file)
      or die "No bundled copy of $mod found";

    my $from_inc = $package->_search_INC($file);
    unless ($from_inc) {
        unshift( @INC, $bundled_dir );
        goto \&_load_module;
    }

    if ( _version($from_inc) >= _version($bundled) ) {
        goto \&_load_module;
    }

    unshift( @INC, $bundled_dir );
    goto \&_load_module;
}

sub _version {
    require ExtUtils::MakeMaker;
    return ExtUtils::MM->parse_version(shift);
}

sub _load_module {
    my $package = shift;
    my ( $mod, @args ) = @_;
    eval "require $mod; 1" or die $@;
    if ( my $import = $mod->can('import') ) {
        goto $import;
    }
    return 1;
}

sub _search_bundled {
    my ( $self, $file ) = @_;

    my $mypath = 'inc';

    local *DH;
    opendir DH, $mypath or die "Can't open directory $mypath: $!";

    while ( defined( my $e = readdir DH ) ) {
        next unless $e =~ /^inc_/;
        my $try = File::Spec->catfile( $mypath, $e, $file );

        return ( $try, File::Spec->catdir( $mypath, $e ) ) if -e $try;
    }
    return;
}

sub _search_INC {
    my ( $self, $file ) = @_;

    foreach my $dir (@INC) {
        next if ref $dir;
        my $try = File::Spec->catfile( $dir, $file );
        return $try if -e $try;
    }

    return;
}

sub _mod2path {
    my ( $self, $mod ) = @_;
    my @parts = split /::/, $mod;
    $parts[-1] .= '.pm';
    return $parts[0] if @parts == 1;
    return File::Spec->catfile(@parts);
}

1;

