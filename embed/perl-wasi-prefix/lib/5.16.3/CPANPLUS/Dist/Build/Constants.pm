package CPANPLUS::Dist::Build::Constants;

use strict;
use warnings;
use File::Spec;

BEGIN {

    require Exporter;
    use vars qw[$VERSION @ISA @EXPORT];

    $VERSION = '0.62';
    @ISA     = qw[Exporter];
    @EXPORT  = qw[ BUILD_DIR BUILD CPDB_PERL_WRAPPER];
}

use constant BUILD_DIR => sub {
    return @_
      ? File::Spec->catdir( $_[0], '_build' )
      : '_build';
};
use constant BUILD => sub {
    my $file =
      @_
      ? File::Spec->catfile( $_[0], 'Build' )
      : 'Build';

    $file .= '.com' if $^O eq 'VMS';

    return $file;
};

use constant CPDB_PERL_WRAPPER =>
'use strict; BEGIN { my $old = select STDERR; $|++; select $old; $|++; $0 = shift(@ARGV); my $rv = do($0); die $@ if $@; }';

1;


