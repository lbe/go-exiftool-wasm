package PerlIO::via::QuotedPrint;

$VERSION = '0.06';
use strict;

use MIME::QuotedPrint ();

1;

sub PUSHED { bless \*PUSHED, $_[0] }

sub FILL {

    my $line = readline( $_[1] );
    ( defined $line ) ? MIME::QuotedPrint::decode_qp($line) : undef;
}

sub WRITE {

    ( print { $_[2] } MIME::QuotedPrint::encode_qp( $_[1] ) )
      ? length( $_[1] )
      : -1;
}

__END__

