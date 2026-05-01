package Module::Build::Dumper;
use strict;
use vars qw($VERSION);
$VERSION = '0.39_01';

use Data::Dumper;

sub _data_dump {
    my ( $self, $data ) = @_;
    return ("do{ my "
          . Data::Dumper->new( [$data], ['x'] )->Purity(1)->Terse(0)->Dump()
          . '$x; }' );
}

1;
